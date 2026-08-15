-- OneWay Ads Phase 3B: verified delivery events, pricing snapshots, and spend accrual.
-- Additive only. Public delivery remains controlled by feature flags.

CREATE TABLE IF NOT EXISTS "AdPricingSnapshot" (
  "id" TEXT PRIMARY KEY,
  "campaignId" TEXT NOT NULL,
  "advertiserId" TEXT NOT NULL,
  "creativeVersion" INTEGER NOT NULL DEFAULT 1,
  "billingModel" TEXT NOT NULL,
  "rateMinor" INTEGER NOT NULL DEFAULT 0,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "pricingUnit" TEXT NOT NULL,
  "effectiveVersion" INTEGER NOT NULL DEFAULT 1,
  "approvedAt" DATETIME,
  "metadataJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE ("campaignId", "creativeVersion", "billingModel", "effectiveVersion")
);

CREATE INDEX IF NOT EXISTS "AdPricingSnapshot_campaign_idx" ON "AdPricingSnapshot" ("campaignId", "createdAt");

CREATE TABLE IF NOT EXISTS "AdSpendAccrual" (
  "id" TEXT PRIMARY KEY,
  "campaignId" TEXT NOT NULL,
  "advertiserId" TEXT NOT NULL,
  "pricingSnapshotId" TEXT,
  "billingModel" TEXT NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "accruedMicros" INTEGER NOT NULL DEFAULT 0,
  "debitedMinor" INTEGER NOT NULL DEFAULT 0,
  "remainderMicros" INTEGER NOT NULL DEFAULT 0,
  "eventCount" INTEGER NOT NULL DEFAULT 0,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE ("campaignId", "billingModel", "pricingSnapshotId")
);

CREATE TABLE IF NOT EXISTS "AdDeliveryEvent" (
  "id" TEXT PRIMARY KEY,
  "eventType" TEXT NOT NULL,
  "deliveryId" TEXT,
  "traceId" TEXT,
  "campaignId" TEXT,
  "advertiserId" TEXT,
  "creativeId" TEXT,
  "creativeVersion" INTEGER,
  "placement" TEXT,
  "viewerHash" TEXT,
  "sessionHash" TEXT,
  "country" TEXT,
  "deviceClass" TEXT,
  "occurredAtClient" DATETIME,
  "receivedAtServer" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "verifiedAt" DATETIME,
  "verificationStatus" TEXT NOT NULL DEFAULT 'pending',
  "failureReasonCode" TEXT,
  "deliveryTokenFingerprint" TEXT,
  "eventTokenFingerprint" TEXT,
  "idempotencyKey" TEXT,
  "costMinor" INTEGER NOT NULL DEFAULT 0,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "ledgerEntryId" TEXT,
  "billingModel" TEXT,
  "metadataJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryEvent_idempotency_key" ON "AdDeliveryEvent" ("idempotencyKey") WHERE "idempotencyKey" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryEvent_event_token_key" ON "AdDeliveryEvent" ("eventTokenFingerprint") WHERE "eventTokenFingerprint" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryEvent_delivery_event_key" ON "AdDeliveryEvent" ("deliveryId", "eventType") WHERE "deliveryId" IS NOT NULL;
CREATE INDEX IF NOT EXISTS "AdDeliveryEvent_campaign_created_idx" ON "AdDeliveryEvent" ("campaignId", "createdAt");

CREATE TABLE IF NOT EXISTS "AdConversionEvent" (
  "id" TEXT PRIMARY KEY,
  "campaignId" TEXT,
  "advertiserId" TEXT,
  "sourceEventId" TEXT,
  "conversionType" TEXT NOT NULL,
  "verificationStatus" TEXT NOT NULL DEFAULT 'not_billable_phase3b',
  "metadataJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE "AdDeliveryToken" ADD COLUMN "impressionTokenHash" TEXT;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "clickTokenHash" TEXT;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "pricingSnapshotId" TEXT;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "eventTokensJson" TEXT NOT NULL DEFAULT '{}';

ALTER TABLE "AdImpression" ADD COLUMN "deliveryId" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "traceId" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "creativeVersion" INTEGER;
ALTER TABLE "AdImpression" ADD COLUMN "sessionHash" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "country" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "occurredAtClient" DATETIME;
ALTER TABLE "AdImpression" ADD COLUMN "receivedAtServer" DATETIME;
ALTER TABLE "AdImpression" ADD COLUMN "verifiedAt" DATETIME;
ALTER TABLE "AdImpression" ADD COLUMN "verificationStatus" TEXT NOT NULL DEFAULT 'verified';
ALTER TABLE "AdImpression" ADD COLUMN "failureReasonCode" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "deliveryTokenFingerprint" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "eventTokenFingerprint" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "idempotencyKey" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "costMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "AdImpression" ADD COLUMN "currency" TEXT NOT NULL DEFAULT 'USD';
ALTER TABLE "AdImpression" ADD COLUMN "ledgerEntryId" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "billingModel" TEXT;
ALTER TABLE "AdImpression" ADD COLUMN "metadataJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdImpression" ADD COLUMN "updatedAt" DATETIME;

ALTER TABLE "AdClick" ADD COLUMN "deliveryId" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "traceId" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "creativeVersion" INTEGER;
ALTER TABLE "AdClick" ADD COLUMN "sessionHash" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "country" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "deviceClass" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "occurredAtClient" DATETIME;
ALTER TABLE "AdClick" ADD COLUMN "receivedAtServer" DATETIME;
ALTER TABLE "AdClick" ADD COLUMN "verifiedAt" DATETIME;
ALTER TABLE "AdClick" ADD COLUMN "verificationStatus" TEXT NOT NULL DEFAULT 'verified';
ALTER TABLE "AdClick" ADD COLUMN "failureReasonCode" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "deliveryTokenFingerprint" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "eventTokenFingerprint" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "idempotencyKey" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "costMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "AdClick" ADD COLUMN "currency" TEXT NOT NULL DEFAULT 'USD';
ALTER TABLE "AdClick" ADD COLUMN "ledgerEntryId" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "billingModel" TEXT;
ALTER TABLE "AdClick" ADD COLUMN "destinationSnapshotJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdClick" ADD COLUMN "metadataJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdClick" ADD COLUMN "updatedAt" DATETIME;

CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryToken_impression_token_key" ON "AdDeliveryToken" ("impressionTokenHash") WHERE "impressionTokenHash" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryToken_click_token_key" ON "AdDeliveryToken" ("clickTokenHash") WHERE "clickTokenHash" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "AdImpression_idempotency_key" ON "AdImpression" ("idempotencyKey") WHERE "idempotencyKey" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "AdClick_idempotency_key" ON "AdClick" ("idempotencyKey") WHERE "idempotencyKey" IS NOT NULL;
