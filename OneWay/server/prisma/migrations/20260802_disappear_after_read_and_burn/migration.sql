ALTER TABLE "Conversation" ADD COLUMN "expirationMode" TEXT NOT NULL DEFAULT 'off';
ALTER TABLE "Conversation" ADD COLUMN "expirationDurationSeconds" INTEGER;
ALTER TABLE "Conversation" ADD COLUMN "allowForwarding" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "Conversation" ADD COLUMN "allowCopying" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "Conversation" ADD COLUMN "allowSavingAttachments" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "Conversation" ADD COLUMN "privacySettingsVersion" INTEGER NOT NULL DEFAULT 1;

ALTER TABLE "Message" ADD COLUMN "expirationMode" TEXT NOT NULL DEFAULT 'off';
ALTER TABLE "Message" ADD COLUMN "expirationDurationSeconds" INTEGER;
ALTER TABLE "Message" ADD COLUMN "readAt" DATETIME;
ALTER TABLE "Message" ADD COLUMN "expiresAt" DATETIME;
ALTER TABLE "Message" ADD COLUMN "deletedAt" DATETIME;
ALTER TABLE "Message" ADD COLUMN "deletionReason" TEXT;
ALTER TABLE "Message" ADD COLUMN "tombstoneVersion" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Message" ADD COLUMN "attachmentExpirationState" TEXT NOT NULL DEFAULT 'active';

ALTER TABLE "MessageReceipt" ADD COLUMN "readAt" DATETIME;
ALTER TABLE "MessageReceipt" ADD COLUMN "expiresAt" DATETIME;
ALTER TABLE "MessageReceipt" ADD COLUMN "deletedAt" DATETIME;

ALTER TABLE "User" ADD COLUMN "accountStatus" TEXT NOT NULL DEFAULT 'active';
ALTER TABLE "User" ADD COLUMN "loginDisabledAt" DATETIME;
ALTER TABLE "User" ADD COLUMN "publicProfileHiddenAt" DATETIME;

CREATE INDEX "Message_expiresAt_deletedAt_idx" ON "Message"("expiresAt", "deletedAt");
CREATE INDEX "MessageReceipt_messageId_readAt_idx" ON "MessageReceipt"("messageId", "readAt");
CREATE INDEX "MessageReceipt_userId_status_idx" ON "MessageReceipt"("userId", "status");

CREATE TABLE "AccountBurnRequest" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'requested',
  "requestedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "scheduledFor" DATETIME NOT NULL,
  "authenticationMethod" TEXT NOT NULL,
  "immediateBurn" BOOLEAN NOT NULL DEFAULT false,
  "exportRequested" BOOLEAN NOT NULL DEFAULT false,
  "completedAt" DATETIME,
  "failureSummary" TEXT,
  "legalHoldStatus" TEXT NOT NULL DEFAULT 'none',
  "cancelledAt" DATETIME,
  "recoveryTokenHash" TEXT,
  "backupDeletionScheduledFor" DATETIME
);

CREATE TABLE "AccountBurnStep" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "burnRequestId" TEXT NOT NULL,
  "subsystem" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'pending',
  "startedAt" DATETIME,
  "completedAt" DATETIME,
  "retryCount" INTEGER NOT NULL DEFAULT 0,
  "errorCode" TEXT,
  "errorSummary" TEXT,
  CONSTRAINT "AccountBurnStep_burnRequestId_fkey" FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE "AccountBurnRetentionRecord" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "burnRequestId" TEXT NOT NULL,
  "subsystem" TEXT NOT NULL,
  "recordType" TEXT NOT NULL,
  "legalBasis" TEXT NOT NULL,
  "retainUntil" DATETIME,
  "restrictedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "AccountBurnRetentionRecord_burnRequestId_fkey" FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE "AccountBurnAuditLog" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "burnRequestId" TEXT NOT NULL,
  "event" TEXT NOT NULL,
  "detailsJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "AccountBurnAuditLog_burnRequestId_fkey" FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE "AccountBurnExport" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "burnRequestId" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'not_requested',
  "storageKey" TEXT,
  "expiresAt" DATETIME,
  "completedAt" DATETIME,
  CONSTRAINT "AccountBurnExport_burnRequestId_fkey" FOREIGN KEY ("burnRequestId") REFERENCES "AccountBurnRequest" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "AccountBurnRequest_userId_status_idx" ON "AccountBurnRequest"("userId", "status");
CREATE INDEX "AccountBurnRequest_status_scheduledFor_idx" ON "AccountBurnRequest"("status", "scheduledFor");
CREATE UNIQUE INDEX "AccountBurnStep_burnRequestId_subsystem_key" ON "AccountBurnStep"("burnRequestId", "subsystem");
CREATE INDEX "AccountBurnStep_status_startedAt_idx" ON "AccountBurnStep"("status", "startedAt");
CREATE INDEX "AccountBurnRetentionRecord_burnRequestId_subsystem_idx" ON "AccountBurnRetentionRecord"("burnRequestId", "subsystem");
CREATE INDEX "AccountBurnAuditLog_burnRequestId_createdAt_idx" ON "AccountBurnAuditLog"("burnRequestId", "createdAt");
CREATE INDEX "AccountBurnExport_burnRequestId_status_idx" ON "AccountBurnExport"("burnRequestId", "status");
