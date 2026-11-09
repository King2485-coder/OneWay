-- OneWay Ads Phase 3A: internal-only delivery engine foundation.
-- Additive only. Public paid delivery remains feature-flag locked.

ALTER TABLE "AdDeliveryToken" ADD COLUMN "deliveryId" TEXT;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "traceId" TEXT;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "creativeVersion" INTEGER NOT NULL DEFAULT 1;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "signature" TEXT;
ALTER TABLE "AdDeliveryToken" ADD COLUMN "status" TEXT NOT NULL DEFAULT 'issued';
ALTER TABLE "AdDeliveryToken" ADD COLUMN "metadataJson" TEXT NOT NULL DEFAULT '{}';

CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryToken_delivery_key"
ON "AdDeliveryToken" ("deliveryId")
WHERE "deliveryId" IS NOT NULL;

CREATE TABLE IF NOT EXISTS "AdDeliveryAttempt" (
  "id" TEXT PRIMARY KEY,
  "traceId" TEXT NOT NULL,
  "campaignId" TEXT,
  "advertiserId" TEXT,
  "creativeId" TEXT,
  "creativeVersion" INTEGER,
  "viewerHash" TEXT NOT NULL,
  "placement" TEXT NOT NULL,
  "decision" TEXT NOT NULL,
  "reason" TEXT,
  "country" TEXT,
  "deviceClass" TEXT,
  "pacingScore" REAL NOT NULL DEFAULT 0,
  "frequencySnapshotJson" TEXT NOT NULL DEFAULT '{}',
  "eligibilitySnapshotJson" TEXT NOT NULL DEFAULT '{}',
  "metadataJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "AdDeliveryAttempt_viewer_placement_idx"
ON "AdDeliveryAttempt" ("viewerHash", "placement", "createdAt");

CREATE INDEX IF NOT EXISTS "AdDeliveryAttempt_campaign_viewer_idx"
ON "AdDeliveryAttempt" ("campaignId", "viewerHash", "createdAt");

CREATE INDEX IF NOT EXISTS "AdDeliveryAttempt_advertiser_viewer_idx"
ON "AdDeliveryAttempt" ("advertiserId", "viewerHash", "createdAt");
