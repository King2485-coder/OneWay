/**
 * Sends VoIP pushes through APNs HTTP/2 with retry. Uses the `apn` package
 * if available; degrades to a no-op otherwise.
 *
 * Retry policy: 3 attempts with exponential backoff (1s, 4s, 16s). Apple's
 * documented "soft failures" (5xx, network) are retried. Hard failures
 * (BadDeviceToken, Unregistered, BadTopic) are not — they're terminal,
 * we drop the token instead.
 *
 * Required env (token-auth, preferred):
 *   APNS_BUNDLE_ID, APNS_KEY_ID, APNS_TEAM_ID, and either
 *   APNS_KEY_P8_BASE64 (preferred on Railway) or APNS_KEY_PATH
 *   APNS_ENVIRONMENT  ("sandbox" | "production", default sandbox)
 *
 * Or cert-auth: APNS_CERT_PATH + APNS_KEY_PEM_PATH.
 */

import type { PushTokenStore } from "./PushTokenStore";
import { logger } from "../lib/logger";
import { apnsTokenConfigFromEnv } from "./apnsCredentials";

interface ApnSdk {
  Provider: new (opts: ApnProviderOptions) => ApnProviderInstance;
  Notification: new () => ApnNotification;
}
interface ApnProviderOptions {
  token?: { key: string; keyId: string; teamId: string };
  cert?: string;
  key?: string;
  production?: boolean;
}
interface ApnProviderInstance {
  send(notification: ApnNotification, recipients: string | string[]): Promise<{
    sent: { device: string }[];
    failed: { device: string; status?: string; response?: { reason?: string } }[];
  }>;
  shutdown(): void;
}
interface ApnNotification {
  topic: string;
  pushType: "voip" | "alert";
  priority: number;
  expiry: number;
  payload: Record<string, unknown>;
  rawPayload?: Record<string, unknown>;
}

let sdkCache: ApnSdk | null | undefined;
function loadSdk(): ApnSdk | null {
  if (sdkCache !== undefined) return sdkCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    sdkCache = require("apn") as ApnSdk;
  } catch {
    sdkCache = null;
    logger.warn({}, "[apn] `apn` package not installed; VoIP pushes disabled");
  }
  return sdkCache;
}

const TERMINAL_REASONS = new Set([
  "BadDeviceToken",
  "Unregistered",
  "BadTopic",
  "BadCertificate",
  "BadCertificateEnvironment",
]);

const MAX_ATTEMPTS = 3;
const RETRY_DELAYS_MS = [1_000, 4_000, 16_000];

export interface VoIPPushArgs {
  userId: string;
  callId: string;
  callerId: string;
  hasVideo: boolean;
  displayName?: string;
  roomName?: string;
  callerName?: string;
  callerNumber?: string;
}

export interface CommunityMessagePushArgs {
  userId: string;
  communityId: string;
  communityName: string;
  messageId: string;
  senderHandle: string;
  senderDisplayName: string;
  body: string;
}

type QueueItem = ({
  kind: "call";
} & VoIPPushArgs | {
  kind: "communityMessage";
} & CommunityMessagePushArgs) & {
  attempt: number;
};

export class VoIPPushService {
  private provider: ApnProviderInstance | null = null;
  private bundleId: string | null = null;
  private queue: QueueItem[] = [];
  private timer: NodeJS.Timeout | null = null;
  private draining = false;

  constructor(private readonly tokens: PushTokenStore) {
    this.init();
  }

  /** Enqueue a push — `send` is fire-and-forget from the caller's POV. */
  async send(args: VoIPPushArgs): Promise<void> {
    logger.info({
      eventType: "incoming_oneway_call",
      callSessionId: args.callId,
      actorRole: "oneway_user",
      targetUserId: args.userId,
      initiatorUserId: args.callerId,
      sourceFunction: "VoIPPushService.send",
      reason: this.provider ? "queued" : "apns_provider_not_configured",
    }, "[apn] incoming call push attempt");
    if (!this.provider) return;
    this.queue.push({ kind: "call", ...args, attempt: 0 });
    this.kick();
  }

  async sendCommunityMessage(args: CommunityMessagePushArgs): Promise<void> {
    if (!this.provider) return;
    this.queue.push({ kind: "communityMessage", ...args, attempt: 0 });
    this.kick();
  }

  shutdown(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.provider?.shutdown();
    this.provider = null;
  }

  // ---- internals --------------------------------------------------------

  private kick(): void {
    if (this.draining || this.queue.length === 0) return;
    this.draining = true;
    Promise.resolve().then(() => this.drain()).finally(() => { this.draining = false; });
  }

  private async drain(): Promise<void> {
    while (this.queue.length > 0 && this.provider) {
      const item = this.queue.shift()!;
      const ok = await this.attempt(item);
      if (!ok && item.attempt + 1 < MAX_ATTEMPTS) {
        const delay = RETRY_DELAYS_MS[item.attempt];
        logger.warn({ kind: item.kind, attempt: item.attempt }, "[apn] retrying push");
        setTimeout(() => {
          this.queue.push({ ...item, attempt: item.attempt + 1 });
          this.kick();
        }, delay).unref();
      }
    }
  }

  /** Returns true on success or terminal failure (caller should not retry). */
  private async attempt(item: QueueItem): Promise<boolean> {
    const sdk = loadSdk();
    if (!sdk || !this.provider || !this.bundleId) return true;
    const record = await this.tokens.get(item.userId);
    if (!record) {
      logger.info({ userId: item.userId }, "[apn] no registered token");
      return true; // terminal — nothing to retry against
    }
    const note = new sdk.Notification();
    note.topic = item.kind === "call" ? `${this.bundleId}.voip` : this.bundleId;
    note.pushType = item.kind === "call" ? "voip" : "alert";
    note.priority = 10;
    note.expiry = Math.floor(Date.now() / 1000) + (item.kind === "call" ? 30 : 3600);
    note.payload = item.kind === "call" ? this.buildPayload(item) : this.buildCommunityPayload(item);
    note.rawPayload = note.payload;

    try {
      const result = await this.provider.send(note, record.voipToken);
      if (result.sent.length > 0) {
        logger.info({ kind: item.kind, userId: item.userId }, "[apn] push sent");
        return true;
      }
      const failure = result.failed[0];
      const reason = failure?.response?.reason ?? failure?.status ?? "unknown";
      logger.warn({ reason, userId: item.userId, kind: item.kind }, "[apn] push failed");
      if (TERMINAL_REASONS.has(reason)) {
        await this.tokens.remove(record.voipToken);
        return true; // terminal
      }
      return false; // soft failure — retry
    } catch (err) {
      logger.error({ err }, "[apn] provider.send threw");
      return false;
    }
  }

  private init(): void {
    const sdk = loadSdk();
    if (!sdk) return;
    const bundleId = process.env.APNS_BUNDLE_ID;
    if (!bundleId) {
      logger.warn({}, "[apn] APNS_BUNDLE_ID not set — VoIP pushes disabled");
      return;
    }
    this.bundleId = bundleId;
    const production = process.env.APNS_ENVIRONMENT === "production";

    const token = apnsTokenConfigFromEnv();
    if (token) {
      this.provider = new sdk.Provider({ token, production });
      logger.info({ production }, "[apn] provider initialized (token auth)");
      return;
    }
    const certPath = process.env.APNS_CERT_PATH;
    const keyPemPath = process.env.APNS_KEY_PEM_PATH;
    if (certPath && keyPemPath) {
      this.provider = new sdk.Provider({ cert: certPath, key: keyPemPath, production });
      logger.info({ production }, "[apn] provider initialized (cert auth)");
      return;
    }
    logger.warn({}, "[apn] no auth credentials set — VoIP pushes disabled");
  }

  private buildPayload(args: VoIPPushArgs): Record<string, unknown> {
    logger.info({
      eventType: "incoming_oneway_call",
      sound: null,
      usesCallKit: true,
      callId: args.callId,
      hasVideo: args.hasVideo,
      sourceFunction: "VoIPPushService.buildPayload",
    }, "CALL_PUSH_SOUND_POLICY");
    return {
      aps: { alert: "Incoming Call", "content-available": 1 },
      eventType: "incoming_oneway_call",
      callId: args.callId,
      callerId: args.callerId,
      hasVideo: args.hasVideo,
      displayName: args.displayName ?? args.callerId,
      callerName: args.callerName ?? args.callerId,
      callerNumber: args.callerNumber,
      roomName: args.roomName,
    };
  }

  private buildCommunityPayload(args: CommunityMessagePushArgs): Record<string, unknown> {
    const body = args.body.length > 140 ? `${args.body.slice(0, 137)}...` : args.body;
    logger.info({
      eventType: "community.message.created",
      sound: "default",
      usesCallKit: false,
      communityId: args.communityId,
      sourceFunction: "VoIPPushService.buildCommunityPayload",
    }, "CALL_PUSH_SOUND_POLICY");
    return {
      aps: {
        alert: {
          title: args.communityName,
          subtitle: args.senderDisplayName || args.senderHandle,
          body,
        },
        sound: "default",
        category: "COMMUNITY_MESSAGE",
        "thread-id": `community:${args.communityId}`,
      },
      type: "community.message.created",
      communityId: args.communityId,
      messageId: args.messageId,
      senderHandle: args.senderHandle,
      route: `oneway://community/${args.communityId}`,
    };
  }
}
