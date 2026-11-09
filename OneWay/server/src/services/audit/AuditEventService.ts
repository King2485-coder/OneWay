import type { PrismaClient } from "@prisma/client";
import { createHash, randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import { redactSensitiveObject, shortId } from "../../lib/privacy/redaction";

export type AuditActorType = "user" | "system" | "admin" | "public";

export type AuditEventInput = {
  actorId?: string | null;
  actorType: AuditActorType;
  action: string;
  resourceType: string;
  resourceId?: string | null;
  metadata?: Record<string, unknown>;
};

export type AuditVerificationResult = {
  ok: boolean;
  checked: number;
  total?: number;
  firstBrokenEventId?: string | null;
  firstBrokenEventCreatedAt?: string | null;
  reason?: string | null;
  lastEventHash?: string | null;
};

type AuditEventRow = {
  id: string;
  actorId: string | null;
  actorType: string;
  action: string;
  resourceType: string;
  resourceId: string | null;
  metadataJson: string;
  prevHash: string | null;
  eventHash: string;
  createdAt: Date;
};

let auditTableReady = false;

export async function ensureAuditEventTable(prisma: PrismaClient): Promise<void> {
  if (auditTableReady) return;
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AuditEvent" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "actorId" TEXT,
      "actorType" TEXT NOT NULL,
      "action" TEXT NOT NULL,
      "resourceType" TEXT NOT NULL,
      "resourceId" TEXT,
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "prevHash" TEXT,
      "eventHash" TEXT NOT NULL UNIQUE,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AuditEvent_createdAt_idx" ON "AuditEvent"("createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AuditEvent_actorType_action_createdAt_idx" ON "AuditEvent"("actorType", "action", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AuditEvent_resourceType_resourceId_idx" ON "AuditEvent"("resourceType", "resourceId")`);
  auditTableReady = true;
}

export async function recordAuditEvent(prisma: PrismaClient, input: AuditEventInput): Promise<AuditEventRow> {
  await ensureAuditEventTable(prisma);
  const id = randomUUID();
  const createdAt = new Date();
  const metadata = sanitizeAuditMetadata(input.metadata ?? {});
  const actorId = safeId(input.actorId ?? null);
  const resourceId = safeId(input.resourceId ?? null);
  const previous = await prisma.auditEvent.findFirst({ orderBy: { createdAt: "desc" } });
  const prevHash = previous?.eventHash ?? null;
  const eventFields = {
    id,
    actorId,
    actorType: input.actorType,
    action: clampLabel(input.action, 160),
    resourceType: clampLabel(input.resourceType, 160),
    resourceId,
    metadata,
    createdAt: createdAt.toISOString(),
  };
  const eventHash = computeAuditEventHash(eventFields, prevHash);
  const created = await prisma.auditEvent.create({
    data: {
      id,
      actorId,
      actorType: eventFields.actorType,
      action: eventFields.action,
      resourceType: eventFields.resourceType,
      resourceId,
      metadataJson: JSON.stringify(metadata),
      prevHash,
      eventHash,
      createdAt,
    },
  });
  return created;
}

export async function recordAuditEventSafe(prisma: PrismaClient, input: AuditEventInput): Promise<void> {
  try {
    await recordAuditEvent(prisma, input);
  } catch (error) {
    logger.warn({ err: error, action: input.action, resourceType: input.resourceType }, "[audit] event write failed");
  }
}

export async function verifyAuditLog(prisma: PrismaClient, options: { limit?: number } = {}): Promise<AuditVerificationResult> {
  await ensureAuditEventTable(prisma);
  const limit = options.limit && options.limit > 0 ? options.limit : undefined;
  const events = await prisma.auditEvent.findMany({
    orderBy: { createdAt: "asc" },
    take: limit,
  });
  let expectedPrevHash: string | null = null;
  for (const event of events) {
    if (event.prevHash !== expectedPrevHash) {
      return broken(event, events.length, "prev_hash_mismatch");
    }
    const metadata = parseMetadata(event.metadataJson);
    const expectedHash = computeAuditEventHash({
      id: event.id,
      actorId: event.actorId,
      actorType: event.actorType,
      action: event.action,
      resourceType: event.resourceType,
      resourceId: event.resourceId,
      metadata,
      createdAt: event.createdAt.toISOString(),
    }, event.prevHash);
    if (event.eventHash !== expectedHash) {
      return broken(event, events.length, "event_hash_mismatch");
    }
    expectedPrevHash = event.eventHash;
  }
  return {
    ok: true,
    checked: events.length,
    firstBrokenEventId: null,
    firstBrokenEventCreatedAt: null,
    reason: null,
    lastEventHash: expectedPrevHash,
  };
}

export async function auditStatus(prisma: PrismaClient): Promise<{ ok: true; totalEvents: number; verification: AuditVerificationResult; latestEventAt: string | null }> {
  await ensureAuditEventTable(prisma);
  const [totalEvents, latest, verification] = await Promise.all([
    prisma.auditEvent.count(),
    prisma.auditEvent.findFirst({ orderBy: { createdAt: "desc" }, select: { createdAt: true } }),
    verifyAuditLog(prisma, { limit: 10_000 }),
  ]);
  return {
    ok: true,
    totalEvents,
    latestEventAt: latest?.createdAt.toISOString() ?? null,
    verification: { ...verification, total: totalEvents },
  };
}

export async function recentAuditEvents(prisma: PrismaClient, limit = 50): Promise<Array<Record<string, unknown>>> {
  await ensureAuditEventTable(prisma);
  const safeLimit = Math.min(Math.max(Math.floor(limit || 50), 1), 100);
  const events = await prisma.auditEvent.findMany({ orderBy: { createdAt: "desc" }, take: safeLimit });
  return events.map((event) => ({
    id: safeId(event.id),
    actorId: event.actorId,
    actorType: event.actorType,
    action: event.action,
    resourceType: event.resourceType,
    resourceId: event.resourceId,
    metadata: parseMetadata(event.metadataJson),
    prevHash: shortHash(event.prevHash),
    eventHash: shortHash(event.eventHash),
    createdAt: event.createdAt.toISOString(),
  }));
}

export function computeAuditEventHash(eventFields: Record<string, unknown>, prevHash: string | null): string {
  return createHash("sha256")
    .update(canonicalJson({ event: eventFields, prevHash }))
    .digest("hex");
}

function sanitizeAuditMetadata(metadata: Record<string, unknown>): Record<string, unknown> {
  return redactSensitiveObject(metadata) as Record<string, unknown>;
}

function parseMetadata(value: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    return redactSensitiveObject(parsed) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function safeId(value: string | null): string | null {
  if (!value) return null;
  return shortId(value, 8) ?? null;
}

function shortHash(value: string | null): string | null {
  if (!value) return null;
  return shortId(value, 10);
}

function clampLabel(value: string, max: number): string {
  return String(value || "unknown").trim().slice(0, max) || "unknown";
}

function broken(event: AuditEventRow, checked: number, reason: string): AuditVerificationResult {
  return {
    ok: false,
    checked,
    firstBrokenEventId: safeId(event.id),
    firstBrokenEventCreatedAt: event.createdAt.toISOString(),
    reason,
    lastEventHash: shortHash(event.eventHash),
  };
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const objectValue = value as Record<string, unknown>;
  return `{${Object.keys(objectValue).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(objectValue[key])}`).join(",")}}`;
}
