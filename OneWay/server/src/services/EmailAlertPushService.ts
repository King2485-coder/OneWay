import { logger } from "../lib/logger";
import type { AlertPushTokenStore, AlertPreviewMode } from "./AlertPushTokenStore";
import { apnsTokenConfigFromEnv } from "./apnsCredentials";
import { APNsHTTP2Provider, type APNsNotification } from "./APNsHTTP2Provider";

export class EmailAlertPushService {
  private providers = new Map<"sandbox" | "production", APNsHTTP2Provider>();
  private bundleId = "";

  constructor(private readonly tokens: AlertPushTokenStore) { this.initialize(); }

  configured(): boolean { return Boolean(this.providers.size && this.bundleId); }

  async sendNewMail(input: { userId: string; threadId: string; messageId: string; sender: string; subject: string }): Promise<void> {
    if (!this.configured()) return;
    const records = await this.tokens.forUser(input.userId);
    for (const group of groupByPreview(records)) {
      if (group.previewMode === "none") continue;
      const provider = this.providers.get(group.environment);
      if (!provider) continue;
      const note: APNsNotification = {
        topic: this.bundleId, pushType: "alert", priority: 10, expiry: Math.floor(Date.now() / 1000) + 3600,
        payload: {
        aps: { alert: alertCopy(group.previewMode, input.sender, input.subject), ...(group.soundEnabled ? { sound: "default" } : {}), "thread-id": `email:${input.threadId}` },
        eventType: "email.message.received", threadId: input.threadId, messageId: input.messageId,
        deepLink: `oneway://email/thread/${input.threadId}`,
        },
      };
      try {
        const result = await provider.send(note, group.tokens);
        for (const failed of result.failed) {
          if (["BadDeviceToken", "Unregistered"].includes(failed.response?.reason || "")) await this.tokens.remove(failed.device);
        }
        logger.info({ userId: input.userId, sent: result.sent.length, failed: result.failed.length }, "[email:push] new mail alert processed");
      } catch (error) { logger.warn({ err: error, userId: input.userId }, "[email:push] alert failed"); }
    }
  }

  async sendNewMessage(input: { userId: string; conversationId: string; messageId: string; sender: string; body: string }): Promise<void> {
    await this.sendAlert({
      userId: input.userId,
      eventType: "chat.message.received",
      threadId: `chat:${input.conversationId}`,
      deepLink: "oneway://messages",
      messageId: input.messageId,
      copy: () => messageAlertCopy(),
    });
  }

  async sendInstant(input: {userId: string; instantId: string}): Promise<void> {
    await this.sendAlert({userId: input.userId, eventType: "instant.received", threadId: "instant:" + input.instantId,
      deepLink: "oneway://messages", messageId: input.instantId, expirySeconds: 3600,
      copy: () => ({title: "OneWay", body: "You received an instant photo. Open Messages to view it."})});
  }

  async sendRecordedChirp(input: {userId:string;chirpId:string;expiresAtMs:number|null}):Promise<void> {
    const remaining=input.expiresAtMs==null?3600:Math.floor((input.expiresAtMs-Date.now())/1000);
    if(remaining<=0)return;
    await this.sendAlert({userId:input.userId,eventType:"message.received",threadId:"chirp:"+input.chirpId,deepLink:"oneway://messages",messageId:input.chirpId,expirySeconds:Math.min(remaining,3600),copy:()=>({title:"OneWay",body:"New voice message or media. Open OneWay to view or play it."})});
  }

  async sendChirpInvitation(input: {userId: string; requestId: string; recordedMedia?: boolean}): Promise<void> {
    await this.sendAlert({userId: input.userId, eventType: input.recordedMedia ? "message.received" : "chirp.invitation.received", threadId: "chirp:" + input.requestId,
      deepLink: input.recordedMedia ? "oneway://messages" : "oneway://chirp", messageId: input.requestId, expirySeconds: 600,
      copy: () => ({title: "OneWay", body: input.recordedMedia ? "New voice-message or media request. Open OneWay to accept or decline." : "New Chirp invitation. Open OneWay to accept or decline."})});
  }

  private async sendAlert(input: {
    userId: string;
    eventType: string;
    expirySeconds?: number;
    threadId: string;
    deepLink: string;
    messageId: string;
    copy: (mode: AlertPreviewMode) => { title: string; body: string };
  }): Promise<void> {
    if (!this.configured()) return;
    const records = await this.tokens.forUser(input.userId);
    for (const group of groupByPreview(records)) {
      if (group.previewMode === "none") continue;
      const provider = this.providers.get(group.environment);
      if (!provider) continue;
      const note: APNsNotification = {
        topic: this.bundleId, pushType: "alert", priority: 10, expiry: Math.floor(Date.now() / 1000) + (input.expirySeconds ?? 3600),
        payload: {
        aps: { alert: input.copy(group.previewMode), ...(group.soundEnabled ? { sound: "default" } : {}), "thread-id": input.threadId },
        eventType: input.eventType,
        conversationId: input.threadId.replace(/^chat:/, ""),
        messageId: input.messageId,
        deepLink: input.deepLink,
        },
      };
      try {
        const result = await provider.send(note, group.tokens);
        for (const failed of result.failed) {
          if (["BadDeviceToken", "Unregistered"].includes(failed.response?.reason || "")) await this.tokens.remove(failed.device);
        }
        logger.info({ userId: input.userId, eventType: input.eventType, sent: result.sent.length, failed: result.failed.length }, "[alert:push] alert processed");
      } catch (error) {
        logger.warn({ err: error, userId: input.userId, eventType: input.eventType }, "[alert:push] alert failed");
      }
    }
  }

  private initialize(): void {
    const bundleId = process.env.APNS_BUNDLE_ID?.trim() || "";
    if (!bundleId) return;
    this.bundleId = bundleId;
    const token = apnsTokenConfigFromEnv();
    if (token) {
      for (const environment of ["sandbox", "production"] as const) {
        this.providers.set(environment, new APNsHTTP2Provider({ token, production: environment === "production" }));
      }
    } else if (process.env.APNS_CERT_PATH && process.env.APNS_KEY_PEM_PATH) {
      // Certificate credentials may be restricted to one Apple environment.
      const environment = process.env.APNS_ENVIRONMENT === "production" ? "production" : "sandbox";
      this.providers.set(environment, new APNsHTTP2Provider({ cert: process.env.APNS_CERT_PATH, key: process.env.APNS_KEY_PEM_PATH, production: environment === "production" }));
    }
  }
}
function groupByPreview(records: Array<{ token: string; environment: "sandbox" | "production"; previewMode: AlertPreviewMode; soundEnabled: boolean }>) {
  const groups = new Map<string, { environment: "sandbox" | "production"; previewMode: AlertPreviewMode; soundEnabled: boolean; tokens: string[] }>();
  for (const record of records) {
    const key = `${record.environment}:${record.previewMode}:${record.soundEnabled}`;
    const group = groups.get(key) ?? { environment: record.environment, previewMode: record.previewMode, soundEnabled: record.soundEnabled, tokens: [] };
    group.tokens.push(record.token);
    groups.set(key, group);
  }
  return Array.from(groups.values());
}
function alertCopy(mode: AlertPreviewMode, sender: string, subject: string) {
  if (mode === "generic") return { title: "OneWay Email", body: "New email" };
  if (mode === "sender") return { title: sender || "OneWay Email", body: "New email" };
  return { title: sender || "OneWay Email", body: subject || "New email" };
}
function messageAlertCopy() {
  return { title: "OneWay", body: "New message" };
}
