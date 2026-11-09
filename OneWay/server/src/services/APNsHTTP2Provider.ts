import { readFileSync } from "node:fs";
import { connect, constants, type ClientHttp2Session } from "node:http2";
import { createPrivateKey, sign } from "node:crypto";

export interface APNsNotification {
  topic: string;
  pushType: "voip" | "alert";
  priority: number;
  expiry: number;
  payload: Record<string, unknown>;
  rawPayload?: Record<string, unknown>;
}

export interface APNsProviderOptions {
  token?: { key: string; keyId: string; teamId: string };
  cert?: string;
  key?: string;
  production?: boolean;
}

export interface APNsSendResult {
  sent: Array<{ device: string }>;
  failed: Array<{ device: string; status?: string; response?: { reason?: string } }>;
}

/**
 * Minimal APNs HTTP/2 client built only on supported Node APIs. It replaces the
 * abandoned `apn` dependency and deliberately exposes the narrow surface used
 * by OneWay. Payload values and credentials are never logged here.
 */
export class APNsHTTP2Provider {
  private readonly authority: string;
  private readonly connectOptions: Record<string, unknown>;
  private readonly tokenAuth: APNsProviderOptions["token"];
  private cachedToken: { value: string; issuedAt: number } | null = null;
  private closed = false;

  constructor(options: APNsProviderOptions) {
    this.authority = options.production
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    this.tokenAuth = options.token;
    this.connectOptions = options.cert && options.key
      ? { cert: readCredential(options.cert), key: readCredential(options.key) }
      : {};
    if (!this.tokenAuth && !(options.cert && options.key)) {
      throw new Error("apns_credentials_required");
    }
  }

  async send(notification: APNsNotification, recipients: string | string[]): Promise<APNsSendResult> {
    if (this.closed) throw new Error("apns_provider_closed");
    const devices = Array.isArray(recipients) ? recipients : [recipients];
    const payload = Buffer.from(JSON.stringify(notification.rawPayload ?? notification.payload), "utf8");
    if (payload.byteLength > 4_096) {
      return { sent: [], failed: devices.map((device) => ({ device, status: "413", response: { reason: "PayloadTooLarge" } })) };
    }

    const session = connect(this.authority, this.connectOptions);
    try {
      await waitForConnection(session);
      const results = await Promise.all(devices.map((device) => this.sendOne(session, notification, device, payload)));
      return {
        sent: results.filter((result) => result.ok).map((result) => ({ device: result.device })),
        failed: results.filter((result) => !result.ok).map((result) => ({
          device: result.device,
          status: result.status,
          response: { reason: result.reason },
        })),
      };
    } finally {
      session.close();
    }
  }

  shutdown(): void {
    this.closed = true;
    this.cachedToken = null;
  }

  private sendOne(
    session: ClientHttp2Session,
    notification: APNsNotification,
    device: string,
    payload: Buffer,
  ): Promise<{ ok: boolean; device: string; status: string; reason: string }> {
    return new Promise((resolve) => {
      const headers: Record<string, string | number> = {
        [constants.HTTP2_HEADER_METHOD]: "POST",
        [constants.HTTP2_HEADER_PATH]: `/3/device/${encodeURIComponent(device)}`,
        "apns-topic": notification.topic,
        "apns-push-type": notification.pushType,
        "apns-priority": String(notification.priority),
        "apns-expiration": String(notification.expiry),
        "content-type": "application/json",
      };
      const authorization = this.authorizationHeader();
      if (authorization) headers.authorization = authorization;

      const request = session.request(headers);
      let status = "0";
      const response: Buffer[] = [];
      request.setEncoding("utf8");
      request.on("response", (value) => { status = String(value[constants.HTTP2_HEADER_STATUS] ?? "0"); });
      request.on("data", (chunk: string) => response.push(Buffer.from(chunk, "utf8")));
      request.on("error", () => resolve({ ok: false, device, status, reason: "NetworkError" }));
      request.on("end", () => {
        const reason = parseReason(Buffer.concat(response).toString("utf8"));
        resolve({ ok: status === "200", device, status, reason: reason ?? (status === "200" ? "Success" : "Unknown") });
      });
      request.end(payload);
    });
  }

  private authorizationHeader(): string | null {
    if (!this.tokenAuth) return null;
    const now = Math.floor(Date.now() / 1000);
    if (this.cachedToken && now - this.cachedToken.issuedAt < 50 * 60) {
      return `bearer ${this.cachedToken.value}`;
    }
    const header = base64URL(JSON.stringify({ alg: "ES256", kid: this.tokenAuth.keyId }));
    const claims = base64URL(JSON.stringify({ iss: this.tokenAuth.teamId, iat: now }));
    const signingInput = `${header}.${claims}`;
    const signature = sign("sha256", Buffer.from(signingInput), {
      key: createPrivateKey(readCredential(this.tokenAuth.key)),
      dsaEncoding: "ieee-p1363",
    });
    const value = `${signingInput}.${base64URL(signature)}`;
    this.cachedToken = { value, issuedAt: now };
    return `bearer ${value}`;
  }
}

function waitForConnection(session: ClientHttp2Session): Promise<void> {
  return new Promise((resolve, reject) => {
    session.once("connect", resolve);
    session.once("error", reject);
  });
}

function readCredential(value: string): string {
  return value.includes("-----BEGIN") ? value : readFileSync(value, "utf8");
}

function base64URL(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

function parseReason(body: string): string | null {
  if (!body) return null;
  try {
    const parsed = JSON.parse(body) as { reason?: unknown };
    return typeof parsed.reason === "string" ? parsed.reason : null;
  } catch {
    return null;
  }
}
