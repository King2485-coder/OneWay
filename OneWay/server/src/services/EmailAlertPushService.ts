import { logger } from "../lib/logger";
import type { AlertPushTokenStore, AlertPreviewMode } from "./AlertPushTokenStore";
import { apnsTokenConfigFromEnv } from "./apnsCredentials";

interface ApnNotification { topic: string; pushType: "alert"; priority: number; expiry: number; payload: Record<string, unknown>; rawPayload?: Record<string, unknown> }
interface ApnProvider { send(note: ApnNotification, tokens: string[]): Promise<{ sent: Array<{ device: string }>; failed: Array<{ device: string; response?: { reason?: string } }> }>; shutdown(): void }
interface ApnSdk { Provider: new (options: Record<string, unknown>) => ApnProvider; Notification: new () => ApnNotification }

export class EmailAlertPushService {
  private provider: ApnProvider | null = null;
  private bundleId = "";

  constructor(private readonly tokens: AlertPushTokenStore) { this.initialize(); }

  configured(): boolean { return Boolean(this.provider && this.bundleId); }

  async sendNewMail(input: { userId: string; threadId: string; messageId: string; sender: string; subject: string }): Promise<void> {
    if (!this.provider) return;
    const records = await this.tokens.forUser(input.userId);
    for (const group of groupByPreview(records)) {
      if (group.previewMode === "none") continue;
      const note = new (loadApn()!.Notification)();
      note.topic = this.bundleId;
      note.pushType = "alert";
      note.priority = 10;
      note.expiry = Math.floor(Date.now() / 1000) + 3600;
      note.payload = {
        aps: { alert: alertCopy(group.previewMode, input.sender, input.subject), sound: "default", "thread-id": `email:${input.threadId}` },
        eventType: "email.message.received", threadId: input.threadId, messageId: input.messageId,
        deepLink: `oneway://email/thread/${input.threadId}`,
      };
      note.rawPayload = note.payload;
      try {
        const result = await this.provider.send(note, group.tokens);
        for (const failed of result.failed) {
          if (["BadDeviceToken", "Unregistered"].includes(failed.response?.reason || "")) await this.tokens.remove(failed.device);
        }
        logger.info({ userId: input.userId, sent: result.sent.length, failed: result.failed.length }, "[email:push] new mail alert processed");
      } catch (error) { logger.warn({ err: error, userId: input.userId }, "[email:push] alert failed"); }
    }
  }

  private initialize(): void {
    const sdk = loadApn();
    const bundleId = process.env.APNS_BUNDLE_ID?.trim() || "";
    if (!sdk || !bundleId) return;
    this.bundleId = bundleId;
    const production = process.env.APNS_ENVIRONMENT === "production";
    const token = apnsTokenConfigFromEnv();
    if (token) {
      this.provider = new sdk.Provider({ token, production });
    } else if (process.env.APNS_CERT_PATH && process.env.APNS_KEY_PEM_PATH) {
      this.provider = new sdk.Provider({ cert: process.env.APNS_CERT_PATH, key: process.env.APNS_KEY_PEM_PATH, production });
    }
  }
}

let cached: ApnSdk | null | undefined;
function loadApn(): ApnSdk | null {
  if (cached !== undefined) return cached;
  try { cached = require("apn") as ApnSdk; } catch { cached = null; }
  return cached;
}
function groupByPreview(records: Array<{ token: string; previewMode: AlertPreviewMode }>) {
  const groups = new Map<AlertPreviewMode, string[]>();
  for (const record of records) groups.set(record.previewMode, [...(groups.get(record.previewMode) || []), record.token]);
  return Array.from(groups, ([previewMode, tokens]) => ({ previewMode, tokens }));
}
function alertCopy(mode: AlertPreviewMode, sender: string, subject: string) {
  if (mode === "generic") return { title: "OneWay Email", body: "New email" };
  if (mode === "sender") return { title: sender || "OneWay Email", body: "New email" };
  return { title: sender || "OneWay Email", body: subject || "New email" };
}
