import crypto from "node:crypto";

export type AdsEventTokenPayload = {
  tokenVersion: 1;
  eventType: "impression" | "click";
  deliveryId: string;
  traceId: string;
  campaignId: string;
  advertiserId: string;
  creativeId: string;
  creativeVersion: number;
  placement: string;
  viewerHash: string;
  issuedAt: string;
  expiresAt: string;
  nonce: string;
  pricingSnapshotId: string;
  currency: string;
  internalTest: boolean;
  paidDeliveryEnabled: boolean;
};

export function signAdsEventToken(payload: AdsEventTokenPayload): string {
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${encodedPayload}.${sign(encodedPayload)}`;
}

export function verifyAdsEventToken(token: string, expectedEventType?: AdsEventTokenPayload["eventType"]): { ok: true; payload: AdsEventTokenPayload } | { ok: false; error: string; payload?: Partial<AdsEventTokenPayload> } {
  const parts = token.split(".");
  if (parts.length !== 2) return { ok: false, error: "malformed_event_token" };
  const [encodedPayload, signature] = parts;
  const expected = sign(encodedPayload);
  if (!safeEqual(signature, expected)) return { ok: false, error: "invalid_signature" };
  try {
    const payload = JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8")) as AdsEventTokenPayload;
    if (payload.tokenVersion !== 1) return { ok: false, error: "unsupported_event_token_version", payload };
    if (expectedEventType && payload.eventType !== expectedEventType) return { ok: false, error: "wrong_event_token_type", payload };
    if (new Date(payload.expiresAt).getTime() < Date.now()) return { ok: false, error: "expired_event_token", payload };
    return { ok: true, payload };
  } catch {
    return { ok: false, error: "invalid_payload" };
  }
}

export function adsTokenFingerprint(token: string): string {
  return crypto.createHash("sha256").update(token).digest("hex");
}

export function randomAdsId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}

function sign(encodedPayload: string): string {
  return crypto.createHmac("sha256", eventSecret()).update(encodedPayload).digest("base64url");
}

function eventSecret(): string {
  return process.env.ONEWAY_ADS_EVENT_TOKEN_SECRET
    || process.env.ONEWAY_ADS_DELIVERY_TOKEN_SECRET
    || process.env.JWT_SECRET
    || process.env.ONEWAY_JWT_SECRET
    || "dev-oneway-ads-event-secret";
}

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
