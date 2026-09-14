import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";

export const growthEventNames = [
  "app_open",
  "signup_started",
  "signup_completed",
  "profile_created",
  "login_completed",
  "session_started",
  "session_ended",
  "first_message_sent",
  "first_message_received",
  "first_chirp_sent",
  "first_chirp_received",
  "first_call_started",
  "first_call_completed",
  "community_joined",
  "community_created",
  "shop_created",
  "site_created",
  "invite_created",
  "invite_clicked",
  "referral_signup",
  "referral_activated",
  "activation_completed",
  "account_deleted",
  "web_page_view",
  "feature_page_view",
  "pricing_page_view",
  "learn_more_click",
  "download_cta_click",
  "app_store_cta_click",
] as const;

export type GrowthEventName = (typeof growthEventNames)[number];

export const firstEventNames = new Set<GrowthEventName>([
  "first_message_sent",
  "first_message_received",
  "first_chirp_sent",
  "first_chirp_received",
  "first_call_started",
  "first_call_completed",
]);

export const qualifyingActivationEvents = new Set<GrowthEventName>([
  "first_message_sent",
  "first_chirp_sent",
  "first_call_completed",
  "community_joined",
  "invite_created",
]);

const sensitiveKeyPatterns = [
  /message.*(body|content|preview|text)/i,
  /body/i,
  /content/i,
  /preview/i,
  /chirp.*(audio|transcript|content)/i,
  /call.*(audio|video|recording)/i,
  /contact/i,
  /phone/i,
  /email/i,
  /password/i,
  /token/i,
  /secret/i,
  /api[_-]?key/i,
  /encryption.*key/i,
  /payment|card|bank/i,
  /customer/i,
  /private.*url|history/i,
  /user.*agent/i,
  /ip/i,
];

export type GrowthEventInput = {
  eventId: string;
  eventName: GrowthEventName;
  subjectKey: string;
  sessionKey?: string | null;
  occurredAt: Date;
  sourcePlatform: string;
  appVersion?: string | null;
  build?: string | null;
  schemaVersion: string;
  metadata: Record<string, string | number | boolean>;
  attribution: Record<string, string>;
  isTest: boolean;
};

export async function ensureGrowthEventTables(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "GrowthEvent" (
      "id" TEXT PRIMARY KEY,
      "eventId" TEXT NOT NULL UNIQUE,
      "eventName" TEXT NOT NULL,
      "subjectKey" TEXT NOT NULL,
      "sessionKey" TEXT,
      "occurredAt" DATETIME NOT NULL,
      "sourcePlatform" TEXT NOT NULL DEFAULT 'ios',
      "appVersion" TEXT,
      "build" TEXT,
      "schemaVersion" TEXT NOT NULL DEFAULT '1',
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "attributionJson" TEXT NOT NULL DEFAULT '{}',
      "isTest" BOOLEAN NOT NULL DEFAULT false,
      "receivedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "GrowthEvent_subject_event_idx" ON "GrowthEvent"("subjectKey", "eventName", "occurredAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "GrowthEvent_receivedAt_idx" ON "GrowthEvent"("receivedAt")`);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "GrowthEventSyncCheckpoint" (
      "id" TEXT PRIMARY KEY,
      "consumer" TEXT NOT NULL UNIQUE,
      "cursor" TEXT,
      "lastSuccessfulSyncAt" DATETIME,
      "eventCount" INTEGER NOT NULL DEFAULT 0,
      "duplicateCount" INTEGER NOT NULL DEFAULT 0,
      "rejectedCount" INTEGER NOT NULL DEFAULT 0,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
}

export function sanitizeGrowthMetadata(input: unknown): { metadata: Record<string, string | number | boolean>; rejectedKeys: string[] } {
  const metadata: Record<string, string | number | boolean> = {};
  const rejectedKeys: string[] = [];
  if (!input || typeof input !== "object" || Array.isArray(input)) return { metadata, rejectedKeys };
  for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
    if (sensitiveKeyPatterns.some((pattern) => pattern.test(key))) {
      rejectedKeys.push(key);
      continue;
    }
    if (typeof value === "string") metadata[key] = value.slice(0, 180);
    else if (typeof value === "number" && Number.isFinite(value)) metadata[key] = value;
    else if (typeof value === "boolean") metadata[key] = value;
  }
  return { metadata, rejectedKeys };
}

export function validateGrowthEventPayload(body: unknown, authenticatedSubjectKey: string): { ok: true; event: GrowthEventInput } | { ok: false; status: number; error: string } {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { ok: false, status: 400, error: "invalid_schema" };
  const input = body as Record<string, unknown>;
  const eventId = String(input.eventId ?? "").trim();
  const eventName = String(input.eventName ?? "").trim() as GrowthEventName;
  const occurredAt = input.occurredAt ? new Date(String(input.occurredAt)) : new Date();
  if (!/^[A-Za-z0-9:_-]{8,160}$/.test(eventId)) return { ok: false, status: 400, error: "invalid_event_id" };
  if (!growthEventNames.includes(eventName)) return { ok: false, status: 400, error: "unknown_event_name" };
  if (Number.isNaN(occurredAt.getTime())) return { ok: false, status: 400, error: "invalid_timestamp" };
  const ageMs = Math.abs(Date.now() - occurredAt.getTime());
  if (ageMs > 45 * 86_400_000) return { ok: false, status: 400, error: "timestamp_out_of_range" };
  const { metadata, rejectedKeys } = sanitizeGrowthMetadata(input.metadata);
  if (rejectedKeys.length) return { ok: false, status: 400, error: "sensitive_metadata_rejected" };
  const attribution = sanitizeAttribution(input.attribution ?? input.metadata);
  return {
    ok: true,
    event: {
      eventId,
      eventName,
      subjectKey: authenticatedSubjectKey,
      sessionKey: typeof input.sessionKey === "string" ? input.sessionKey.slice(0, 128) : null,
      occurredAt,
      sourcePlatform: typeof input.sourcePlatform === "string" ? input.sourcePlatform.slice(0, 32) : typeof input.platform === "string" ? input.platform.slice(0, 32) : "ios",
      appVersion: typeof input.appVersion === "string" ? input.appVersion.slice(0, 64) : null,
      build: typeof input.build === "string" ? input.build.slice(0, 64) : null,
      schemaVersion: typeof input.schemaVersion === "string" ? input.schemaVersion.slice(0, 16) : "1",
      metadata,
      attribution,
      isTest: input.isTest === true || metadata.is_test === true || metadata.test === true,
    },
  };
}

export function validateWebAnalyticsPayload(body: unknown): { ok: true; event: GrowthEventInput } | { ok: false; status: number; error: string } {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { ok: false, status: 400, error: "invalid_schema" };
  const input = body as Record<string, unknown>;
  const eventId = String(input.eventId ?? "").trim();
  const eventName = String(input.eventName ?? "").trim() as GrowthEventName;
  const occurredAt = input.occurredAt ? new Date(String(input.occurredAt)) : new Date();
  const webEventNames = new Set<GrowthEventName>(["web_page_view", "feature_page_view", "pricing_page_view", "learn_more_click", "download_cta_click", "app_store_cta_click"]);
  const subjectKey = String(input.subjectKey ?? input.anonymousUserKey ?? "").trim();
  if (!/^[A-Za-z0-9:_-]{8,180}$/.test(eventId)) return { ok: false, status: 400, error: "invalid_event_id" };
  if (!webEventNames.has(eventName)) return { ok: false, status: 400, error: "unknown_web_event_name" };
  if (!/^[A-Za-z0-9:_-]{8,160}$/.test(subjectKey) || /@|\+?\d{7,}/.test(subjectKey)) return { ok: false, status: 400, error: "invalid_subject_key" };
  if (Number.isNaN(occurredAt.getTime())) return { ok: false, status: 400, error: "invalid_timestamp" };
  const ageMs = Math.abs(Date.now() - occurredAt.getTime());
  if (ageMs > 7 * 86_400_000) return { ok: false, status: 400, error: "timestamp_out_of_range" };
  const { metadata, rejectedKeys } = sanitizeGrowthMetadata(input.metadata);
  if (rejectedKeys.length) return { ok: false, status: 400, error: "sensitive_metadata_rejected" };
  return {
    ok: true,
    event: {
      eventId,
      eventName,
      subjectKey,
      sessionKey: typeof input.sessionKey === "string" ? input.sessionKey.slice(0, 128) : null,
      occurredAt,
      sourcePlatform: "web",
      appVersion: null,
      build: null,
      schemaVersion: "web_analytics_v1",
      metadata,
      attribution: sanitizeAttribution(input.attribution ?? input.metadata),
      isTest: input.isTest === true || metadata.is_test === true || metadata.test === true,
    },
  };
}

function sanitizeAttribution(input: unknown): Record<string, string> {
  if (!input || typeof input !== "object" || Array.isArray(input)) return {};
  const output: Record<string, string> = {};
  for (const key of ["utm_source", "utm_medium", "utm_campaign", "referral_code", "creator_code"]) {
    const value = (input as Record<string, unknown>)[key];
    if (typeof value === "string" && /^[A-Za-z0-9_.:-]{1,120}$/.test(value)) output[key] = value;
  }
  return output;
}

export async function storeGrowthEvent(prisma: PrismaClient, event: GrowthEventInput): Promise<{ status: "stored" | "duplicate" | "first_duplicate" | "activated"; activationCreated: boolean }> {
  await ensureGrowthEventTables(prisma);
  if (firstEventNames.has(event.eventName)) {
    const existing = await prisma.$queryRawUnsafe<Array<{ id: string }>>(
      `SELECT "id" FROM "GrowthEvent" WHERE "subjectKey" = ? AND "eventName" = ? LIMIT 1`,
      event.subjectKey,
      event.eventName,
    );
    if (existing[0]) return { status: "first_duplicate", activationCreated: false };
  }
  try {
    await insertGrowthEvent(prisma, event);
  } catch (error: any) {
    if (String(error?.message ?? error).includes("Unique constraint") || String(error?.code) === "P2002" || String(error?.message ?? error).includes("UNIQUE")) {
      return { status: "duplicate", activationCreated: false };
    }
    throw error;
  }
  const activationCreated = event.eventName === "activation_completed" ? false : await maybeCreateActivation(prisma, event.subjectKey, event.isTest);
  return { status: activationCreated ? "activated" : "stored", activationCreated };
}

async function insertGrowthEvent(prisma: PrismaClient, event: GrowthEventInput): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "GrowthEvent" ("id", "eventId", "eventName", "subjectKey", "sessionKey", "occurredAt", "sourcePlatform", "appVersion", "build", "schemaVersion", "metadataJson", "attributionJson", "isTest", "receivedAt")
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
    randomUUID(),
    event.eventId,
    event.eventName,
    event.subjectKey,
    event.sessionKey,
    event.occurredAt,
    event.sourcePlatform,
    event.appVersion,
    event.build,
    event.schemaVersion,
    JSON.stringify(event.metadata),
    JSON.stringify(event.attribution),
    event.isTest ? 1 : 0,
  );
}

async function maybeCreateActivation(prisma: PrismaClient, subjectKey: string, isTest: boolean): Promise<boolean> {
  const already = await prisma.$queryRawUnsafe<Array<{ id: string }>>(
    `SELECT "id" FROM "GrowthEvent" WHERE "subjectKey" = ? AND "eventName" = 'activation_completed' LIMIT 1`,
    subjectKey,
  );
  if (already[0]) return false;
  const rows = await prisma.$queryRawUnsafe<Array<{ eventName: string; occurredAt: Date | string }>>(
    `SELECT "eventName", "occurredAt" FROM "GrowthEvent" WHERE "subjectKey" = ? ORDER BY "occurredAt" ASC`,
    subjectKey,
  );
  const signup = rows.find((row) => row.eventName === "signup_completed" || row.eventName === "referral_signup");
  const signupAt = signup ? new Date(signup.occurredAt) : null;
  if (!signupAt) return false;
  const qualifying = rows.filter((row) => qualifyingActivationEvents.has(row.eventName as GrowthEventName));
  const distinct = new Set<string>();
  for (const row of qualifying) {
    const at = new Date(row.occurredAt);
    if (signupAt && at.getTime() - signupAt.getTime() > 7 * 86_400_000) continue;
    distinct.add(row.eventName);
  }
  if (distinct.size < 2) return false;
  const activationAt = new Date();
  const ageDays = signupAt ? Math.max(0, Math.floor((activationAt.getTime() - signupAt.getTime()) / 86_400_000)) : null;
  const ageBucket = ageDays === null ? "NO_SIGNUP" : ageDays <= 1 ? "D0_D1" : ageDays <= 7 ? "D2_D7" : "D8_PLUS";
  await insertGrowthEvent(prisma, {
    eventId: `${subjectKey}:activation_rule_v1`,
    eventName: "activation_completed",
    subjectKey,
    sessionKey: null,
    occurredAt: activationAt,
    sourcePlatform: "server",
    appVersion: null,
    build: null,
    schemaVersion: "1",
    metadata: { activation_rule_version: "activation_rule_v1", signup_age_bucket: ageBucket, qualifying_action_count: distinct.size, is_test: isTest },
    attribution: {},
    isTest,
  });
  return true;
}
