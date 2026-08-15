import type { PrismaClient } from "@prisma/client";
import { addColumnIfMissing } from "../../lib/runtimeSchemaPatch";

export async function ensurePrivacyLifecycleSchema(prisma: PrismaClient): Promise<void> {
  const additions: Array<[string, string]> = [
    ["User", '"accountStatus" TEXT NOT NULL DEFAULT \'active\''],
    ["User", '"loginDisabledAt" TIMESTAMP'],
    ["User", '"publicProfileHiddenAt" TIMESTAMP'],
    ["Conversation", '"expirationMode" TEXT NOT NULL DEFAULT \'off\''],
    ["Conversation", '"expirationDurationSeconds" INTEGER'],
    ["Conversation", '"allowForwarding" BOOLEAN NOT NULL DEFAULT true'],
    ["Conversation", '"allowCopying" BOOLEAN NOT NULL DEFAULT true'],
    ["Conversation", '"allowSavingAttachments" BOOLEAN NOT NULL DEFAULT true'],
    ["Conversation", '"privacySettingsVersion" INTEGER NOT NULL DEFAULT 1'],
    ["Message", '"expirationMode" TEXT NOT NULL DEFAULT \'off\''],
    ["Message", '"expirationDurationSeconds" INTEGER'],
    ["Message", '"readAt" TIMESTAMP'],
    ["Message", '"expiresAt" TIMESTAMP'],
    ["Message", '"deletedAt" TIMESTAMP'],
    ["Message", '"deletionReason" TEXT'],
    ["Message", '"tombstoneVersion" INTEGER NOT NULL DEFAULT 0'],
    ["Message", '"attachmentExpirationState" TEXT NOT NULL DEFAULT \'active\''],
    ["MessageReceipt", '"readAt" TIMESTAMP'],
    ["MessageReceipt", '"expiresAt" TIMESTAMP'],
    ["MessageReceipt", '"deletedAt" TIMESTAMP'],
  ];
  for (const [table, columnDefinition] of additions) {
    await addColumnIfMissing(prisma, { table, columnDefinition, logPrefix: "privacy lifecycle schema patch" });
  }

  await prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AccountBurnRequest" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "userId" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'requested',
    "requestedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "scheduledFor" TIMESTAMP NOT NULL,
    "authenticationMethod" TEXT NOT NULL,
    "immediateBurn" BOOLEAN NOT NULL DEFAULT false,
    "exportRequested" BOOLEAN NOT NULL DEFAULT false,
    "completedAt" TIMESTAMP,
    "failureSummary" TEXT,
    "legalHoldStatus" TEXT NOT NULL DEFAULT 'none',
    "cancelledAt" TIMESTAMP,
    "recoveryTokenHash" TEXT,
    "backupDeletionScheduledFor" TIMESTAMP
  )`);
  await prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AccountBurnStep" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "burnRequestId" TEXT NOT NULL,
    "subsystem" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'pending',
    "startedAt" TIMESTAMP,
    "completedAt" TIMESTAMP,
    "retryCount" INTEGER NOT NULL DEFAULT 0,
    "errorCode" TEXT,
    "errorSummary" TEXT,
    FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest"("id") ON DELETE CASCADE
  )`);
  await prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AccountBurnRetentionRecord" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "burnRequestId" TEXT NOT NULL,
    "subsystem" TEXT NOT NULL,
    "recordType" TEXT NOT NULL,
    "legalBasis" TEXT NOT NULL,
    "retainUntil" TIMESTAMP,
    "restrictedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest"("id") ON DELETE CASCADE
  )`);
  await prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AccountBurnAuditLog" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "burnRequestId" TEXT NOT NULL,
    "event" TEXT NOT NULL,
    "detailsJson" TEXT NOT NULL DEFAULT '{}',
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest"("id") ON DELETE CASCADE
  )`);
  await prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AccountBurnExport" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "burnRequestId" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'not_requested',
    "storageKey" TEXT,
    "expiresAt" TIMESTAMP,
    "completedAt" TIMESTAMP,
    FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest"("id") ON DELETE CASCADE
  )`);

  const indexes = [
    'CREATE INDEX IF NOT EXISTS "Message_expiresAt_deletedAt_idx" ON "Message"("expiresAt", "deletedAt")',
    'CREATE INDEX IF NOT EXISTS "MessageReceipt_messageId_readAt_idx" ON "MessageReceipt"("messageId", "readAt")',
    'CREATE INDEX IF NOT EXISTS "MessageReceipt_userId_status_idx" ON "MessageReceipt"("userId", "status")',
    'CREATE INDEX IF NOT EXISTS "AccountBurnRequest_userId_status_idx" ON "AccountBurnRequest"("userId", "status")',
    'CREATE INDEX IF NOT EXISTS "AccountBurnRequest_status_scheduledFor_idx" ON "AccountBurnRequest"("status", "scheduledFor")',
    'CREATE UNIQUE INDEX IF NOT EXISTS "AccountBurnStep_burnRequestId_subsystem_key" ON "AccountBurnStep"("burnRequestId", "subsystem")',
    'CREATE INDEX IF NOT EXISTS "AccountBurnStep_status_startedAt_idx" ON "AccountBurnStep"("status", "startedAt")',
    'CREATE INDEX IF NOT EXISTS "AccountBurnRetentionRecord_burnRequestId_subsystem_idx" ON "AccountBurnRetentionRecord"("burnRequestId", "subsystem")',
    'CREATE INDEX IF NOT EXISTS "AccountBurnAuditLog_burnRequestId_createdAt_idx" ON "AccountBurnAuditLog"("burnRequestId", "createdAt")',
    'CREATE INDEX IF NOT EXISTS "AccountBurnExport_burnRequestId_status_idx" ON "AccountBurnExport"("burnRequestId", "status")',
  ];
  for (const sql of indexes) await prisma.$executeRawUnsafe(sql);
}
