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
 *   APNS_BUNDLE_ID, APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_PATH
 *   APNS_ENVIRONMENT  ("sandbox" | "production", default sandbox)
 *
 * Or cert-auth: APNS_CERT_PATH + APNS_KEY_PEM_PATH.
 */

import type { PushTokenStore } from "./PushTokenStore";
import { logger } from "../lib/logger";

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
  pushType: "voip";
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
}

interface QueueItem extends VoIPPushArgs {
  attempt: number;
}

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
    if (!this.provider) return;
    this.queue.push({ ...args, attempt: 0 });
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
        logger.warn({ callId: item.callId, attempt: item.attempt }, "[apn] retrying push");
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
    note.topic = `${this.bundleId}.voip`;
    note.pushType = "voip";
    note.priority = 10;
    note.expiry = Math.floor(Date.now() / 1000) + 30;
    note.payload = this.buildPayload(item);
    note.rawPayload = note.payload;

    try {
      const result = await this.provider.send(note, record.voipToken);
      if (result.sent.length > 0) {
        logger.info({ callId: item.callId, userId: item.userId }, "[apn] push sent");
        return true;
      }
      const failure = result.failed[0];
      const reason = failure?.response?.reason ?? failure?.status ?? "unknown";
      logger.warn({ reason, userId: item.userId, callId: item.callId }, "[apn] push failed");
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

    const keyId = process.env.APNS_KEY_ID;
    const teamId = process.env.APNS_TEAM_ID;
    const keyPath = process.env.APNS_KEY_PATH;
    if (keyId && teamId && keyPath) {
      this.provider = new sdk.Provider({ token: { key: keyPath, keyId, teamId }, production });
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
    return {
      aps: { alert: "Incoming Call", "content-available": 1 },
      callId: args.callId,
      callerId: args.callerId,
      hasVideo: args.hasVideo,
      displayName: args.displayName ?? args.callerId,
      roomName: args.roomName,
    };
  }
}
