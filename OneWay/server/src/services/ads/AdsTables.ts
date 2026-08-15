import type { PrismaClient } from "@prisma/client";

let ensured = false;

export async function ensureAdsTables(prisma: PrismaClient): Promise<void> {
  if (ensured) return;

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdvertiserProfile" (
      "id" TEXT PRIMARY KEY,
      "ownerUserId" TEXT NOT NULL,
      "businessName" TEXT NOT NULL,
      "displayName" TEXT NOT NULL,
      "businessType" TEXT NOT NULL DEFAULT 'creator',
      "websiteURL" TEXT,
      "oneWaySiteId" TEXT,
      "oneWayShopId" TEXT,
      "contactEmail" TEXT NOT NULL,
      "country" TEXT NOT NULL DEFAULT 'US',
      "state" TEXT,
      "city" TEXT,
      "billingCustomerId" TEXT,
      "status" TEXT NOT NULL DEFAULT 'draft',
      "verificationStatus" TEXT NOT NULL DEFAULT 'not_started',
      "moderationRiskLevel" TEXT NOT NULL DEFAULT 'low',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "deletedAt" DATETIME
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdvertiserProfile_owner_shop_active_key" ON "AdvertiserProfile" ("ownerUserId", "oneWayShopId") WHERE "oneWayShopId" IS NOT NULL AND "deletedAt" IS NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdvertiserProfile_owner_site_active_key" ON "AdvertiserProfile" ("ownerUserId", "oneWaySiteId") WHERE "oneWaySiteId" IS NOT NULL AND "deletedAt" IS NULL`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdvertiserProfile_owner_status_idx" ON "AdvertiserProfile" ("ownerUserId", "status")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdCampaign" (
      "id" TEXT PRIMARY KEY,
      "advertiserId" TEXT NOT NULL,
      "ownerUserId" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "objective" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'draft',
      "moderationStatus" TEXT NOT NULL DEFAULT 'notSubmitted',
      "destinationType" TEXT,
      "destinationId" TEXT,
      "destinationURL" TEXT,
      "internalNotes" TEXT,
      "startAt" DATETIME,
      "endAt" DATETIME,
      "dailyBudgetMinor" INTEGER NOT NULL DEFAULT 0,
      "lifetimeBudgetMinor" INTEGER NOT NULL DEFAULT 0,
      "maxSpendMinor" INTEGER NOT NULL DEFAULT 0,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "spentMinor" INTEGER NOT NULL DEFAULT 0,
      "fundedMinor" INTEGER NOT NULL DEFAULT 0,
      "billingModel" TEXT NOT NULL DEFAULT 'PREPAID_CPM',
      "pacingMode" TEXT NOT NULL DEFAULT 'standard',
      "estimatedDeliveryJson" TEXT NOT NULL DEFAULT '{}',
      "policySummaryJson" TEXT NOT NULL DEFAULT '{}',
      "submittedAt" DATETIME,
      "approvedAt" DATETIME,
      "activatedAt" DATETIME,
      "pausedAt" DATETIME,
      "completedAt" DATETIME,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "deletedAt" DATETIME,
      FOREIGN KEY ("advertiserId") REFERENCES "AdvertiserProfile" ("id") ON DELETE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdCampaign_owner_status_idx" ON "AdCampaign" ("ownerUserId", "status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdCampaign_advertiser_status_idx" ON "AdCampaign" ("advertiserId", "status")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdCreative" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "ownerUserId" TEXT NOT NULL,
      "version" INTEGER NOT NULL DEFAULT 1,
      "status" TEXT NOT NULL DEFAULT 'draft',
      "moderationStatus" TEXT NOT NULL DEFAULT 'notSubmitted',
      "headline" TEXT NOT NULL,
      "bodyText" TEXT NOT NULL,
      "cta" TEXT NOT NULL,
      "logoURL" TEXT,
      "imageURL" TEXT,
      "videoURL" TEXT,
      "thumbnailURL" TEXT,
      "destinationPreviewJson" TEXT NOT NULL DEFAULT '{}',
      "policyFlagsJson" TEXT NOT NULL DEFAULT '[]',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "deletedAt" DATETIME,
      FOREIGN KEY ("campaignId") REFERENCES "AdCampaign" ("id") ON DELETE CASCADE,
      FOREIGN KEY ("advertiserId") REFERENCES "AdvertiserProfile" ("id") ON DELETE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdCreative_campaign_status_idx" ON "AdCreative" ("campaignId", "status")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdPlacementSelection" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "placement" TEXT NOT NULL,
      "enabled" BOOLEAN NOT NULL DEFAULT 1,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE ("campaignId", "placement")
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdAudienceRule" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "ruleType" TEXT NOT NULL,
      "ruleValue" TEXT NOT NULL,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdAudienceRule_campaign_idx" ON "AdAudienceRule" ("campaignId")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdModerationReview" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "creativeId" TEXT,
      "reviewType" TEXT NOT NULL DEFAULT 'automated',
      "status" TEXT NOT NULL,
      "riskLevel" TEXT NOT NULL DEFAULT 'low',
      "rejectionReason" TEXT,
      "reviewerNotes" TEXT,
      "appealState" TEXT NOT NULL DEFAULT 'not_appealed',
      "createdBy" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdModerationReview_campaign_idx" ON "AdModerationReview" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdBudget" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL UNIQUE,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "dailyBudgetMinor" INTEGER NOT NULL DEFAULT 0,
      "lifetimeBudgetMinor" INTEGER NOT NULL DEFAULT 0,
      "fundedMinor" INTEGER NOT NULL DEFAULT 0,
      "reservedMinor" INTEGER NOT NULL DEFAULT 0,
      "spentMinor" INTEGER NOT NULL DEFAULT 0,
      "remainingMinor" INTEGER NOT NULL DEFAULT 0,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdLedgerEntry" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "entryType" TEXT NOT NULL,
      "amountMinor" INTEGER NOT NULL,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "status" TEXT NOT NULL DEFAULT 'posted',
      "idempotencyKey" TEXT NOT NULL UNIQUE,
      "stripeEventId" TEXT,
      "stripePaymentIntentId" TEXT,
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdLedgerEntry_campaign_idx" ON "AdLedgerEntry" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdPayment" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "ownerUserId" TEXT NOT NULL,
      "stripePaymentIntentId" TEXT UNIQUE,
      "stripeCustomerId" TEXT,
      "amountMinor" INTEGER NOT NULL,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "status" TEXT NOT NULL DEFAULT 'requires_payment',
      "idempotencyKey" TEXT NOT NULL UNIQUE,
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdPayment_campaign_status_idx" ON "AdPayment" ("campaignId", "status")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdReceipt" (
      "id" TEXT PRIMARY KEY,
      "receiptNumber" TEXT NOT NULL UNIQUE,
      "campaignId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "ownerUserId" TEXT NOT NULL,
      "paymentId" TEXT,
      "stripePaymentIntentId" TEXT,
      "stripeEventId" TEXT,
      "amountMinor" INTEGER NOT NULL,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "status" TEXT NOT NULL DEFAULT 'issued',
      "issuedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "metadataJson" TEXT NOT NULL DEFAULT '{}'
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdReceipt_owner_issued_idx" ON "AdReceipt" ("ownerUserId", "issuedAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdDeliveryToken" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "creativeId" TEXT NOT NULL,
      "viewerHash" TEXT NOT NULL,
      "placement" TEXT NOT NULL,
      "tokenHash" TEXT NOT NULL UNIQUE,
      "expiresAt" DATETIME NOT NULL,
      "impressionId" TEXT,
      "clickId" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdDeliveryToken_campaign_viewer_idx" ON "AdDeliveryToken" ("campaignId", "viewerHash", "createdAt")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdDeliveryAttempt_viewer_placement_idx" ON "AdDeliveryAttempt" ("viewerHash", "placement", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdDeliveryAttempt_campaign_viewer_idx" ON "AdDeliveryAttempt" ("campaignId", "viewerHash", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdDeliveryAttempt_advertiser_viewer_idx" ON "AdDeliveryAttempt" ("advertiserId", "viewerHash", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdImpression" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "creativeId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "placement" TEXT NOT NULL,
      "viewerHash" TEXT NOT NULL,
      "tokenHash" TEXT NOT NULL UNIQUE,
      "billableStatus" TEXT NOT NULL DEFAULT 'billable',
      "deviceClass" TEXT,
      "contextualCategory" TEXT,
      "fraudStatus" TEXT NOT NULL DEFAULT 'clean',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdImpression_campaign_created_idx" ON "AdImpression" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdClick" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "creativeId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "impressionId" TEXT,
      "placement" TEXT NOT NULL,
      "viewerHash" TEXT NOT NULL,
      "destinationType" TEXT NOT NULL,
      "destinationURL" TEXT,
      "billableStatus" TEXT NOT NULL DEFAULT 'not_billable_cpc_disabled',
      "fraudStatus" TEXT NOT NULL DEFAULT 'clean',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdClick_campaign_created_idx" ON "AdClick" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdPricingSnapshot_campaign_idx" ON "AdPricingSnapshot" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryEvent_idempotency_key" ON "AdDeliveryEvent" ("idempotencyKey") WHERE "idempotencyKey" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryEvent_event_token_key" ON "AdDeliveryEvent" ("eventTokenFingerprint") WHERE "eventTokenFingerprint" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryEvent_delivery_event_key" ON "AdDeliveryEvent" ("deliveryId", "eventType") WHERE "deliveryId" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdDeliveryEvent_campaign_created_idx" ON "AdDeliveryEvent" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdConversionEvent" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT,
      "advertiserId" TEXT,
      "sourceEventId" TEXT,
      "conversionType" TEXT NOT NULL,
      "verificationStatus" TEXT NOT NULL DEFAULT 'not_billable_phase3b',
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdConversion" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "creativeId" TEXT,
      "advertiserId" TEXT NOT NULL,
      "conversionType" TEXT NOT NULL,
      "sourceEntityType" TEXT,
      "sourceEntityId" TEXT,
      "amountMinor" INTEGER NOT NULL DEFAULT 0,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "verified" BOOLEAN NOT NULL DEFAULT 0,
      "attributionWindow" TEXT NOT NULL DEFAULT 'click_7d_view_1d',
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdConversion_campaign_created_idx" ON "AdConversion" ("campaignId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdUserPreference" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL UNIQUE,
      "contextualCategoriesJson" TEXT NOT NULL DEFAULT '[]',
      "locationBasedAdsEnabled" BOOLEAN NOT NULL DEFAULT 0,
      "reducedRepetitionEnabled" BOOLEAN NOT NULL DEFAULT 1,
      "minorContextualOnly" BOOLEAN NOT NULL DEFAULT 0,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdAdvertiserBlock" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "reason" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE ("userId", "advertiserId")
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdReport" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT,
      "campaignId" TEXT NOT NULL,
      "creativeId" TEXT,
      "advertiserId" TEXT NOT NULL,
      "placement" TEXT,
      "reason" TEXT NOT NULL,
      "details" TEXT,
      "campaignSnapshotJson" TEXT NOT NULL DEFAULT '{}',
      "creativeSnapshotJson" TEXT NOT NULL DEFAULT '{}',
      "status" TEXT NOT NULL DEFAULT 'open',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdReport_status_created_idx" ON "AdReport" ("status", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdAuditLog" (
      "id" TEXT PRIMARY KEY,
      "actorUserId" TEXT,
      "actorType" TEXT NOT NULL DEFAULT 'system',
      "action" TEXT NOT NULL,
      "resourceType" TEXT NOT NULL,
      "resourceId" TEXT NOT NULL,
      "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AdAuditLog_resource_idx" ON "AdAuditLog" ("resourceType", "resourceId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AdDailyMetric" (
      "id" TEXT PRIMARY KEY,
      "campaignId" TEXT NOT NULL,
      "advertiserId" TEXT NOT NULL,
      "metricDate" TEXT NOT NULL,
      "placement" TEXT,
      "impressions" INTEGER NOT NULL DEFAULT 0,
      "clicks" INTEGER NOT NULL DEFAULT 0,
      "conversions" INTEGER NOT NULL DEFAULT 0,
      "spendMinor" INTEGER NOT NULL DEFAULT 0,
      "salesAttributedMinor" INTEGER NOT NULL DEFAULT 0,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE ("campaignId", "metricDate", "placement")
    )
  `);

  await ensureColumn(prisma, "AdvertiserProfile", "associatedProfileId", "TEXT");
  await ensureColumn(prisma, "AdvertiserProfile", "associatedCommunityId", "TEXT");
  await ensureColumn(prisma, "AdvertiserProfile", "billingStatus", "TEXT NOT NULL DEFAULT 'not_started'");
  await ensureColumn(prisma, "AdvertiserProfile", "version", "INTEGER NOT NULL DEFAULT 1");
  await ensureColumn(prisma, "AdCampaign", "currentBuilderStep", "TEXT NOT NULL DEFAULT 'profile'");
  await ensureColumn(prisma, "AdCampaign", "draftCompletionStateJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdCampaign", "clientSubmissionId", "TEXT");
  await ensureColumn(prisma, "AdCampaign", "submittedSnapshotJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdCampaign", "scheduleTimezone", "TEXT");
  await ensureColumn(prisma, "AdCampaign", "version", "INTEGER NOT NULL DEFAULT 1");
  await ensureColumn(prisma, "AdCampaign", "currentRevision", "INTEGER NOT NULL DEFAULT 1");
  await ensureColumn(prisma, "AdCampaign", "eligibilityStateJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdCampaign", "lastEligibilityAt", "DATETIME");
  await ensureColumn(prisma, "AdCreative", "accessibilityDescription", "TEXT");
  await ensureColumn(prisma, "AdCreative", "revision", "INTEGER NOT NULL DEFAULT 1");
  await ensureColumn(prisma, "AdCreative", "approvedFingerprint", "TEXT");
  await ensureColumn(prisma, "AdCreative", "approvedAt", "DATETIME");
  await ensureColumn(prisma, "AdModerationReview", "updatedAt", "DATETIME");
  await ensureColumn(prisma, "AdModerationReview", "decidedAt", "DATETIME");
  await ensureColumn(prisma, "AdModerationReview", "campaignRevision", "INTEGER NOT NULL DEFAULT 1");
  await ensureColumn(prisma, "AdModerationReview", "creativeVersion", "INTEGER");
  await ensureColumn(prisma, "AdModerationReview", "destinationSnapshotJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdModerationReview", "automatedReviewJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdModerationReview", "manualReviewJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdModerationReview", "decision", "TEXT");
  await ensureColumn(prisma, "AdModerationReview", "publicReason", "TEXT");
  await ensureColumn(prisma, "AdModerationReview", "internalNotes", "TEXT");
  await ensureColumn(prisma, "AdModerationReview", "policyCodesJson", "TEXT NOT NULL DEFAULT '[]'");
  await ensureColumn(prisma, "AdModerationReview", "reviewerActorId", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "deliveryId", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "traceId", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "creativeVersion", "INTEGER NOT NULL DEFAULT 1");
  await ensureColumn(prisma, "AdDeliveryToken", "signature", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "status", "TEXT NOT NULL DEFAULT 'issued'");
  await ensureColumn(prisma, "AdDeliveryToken", "metadataJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdDeliveryToken", "impressionTokenHash", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "clickTokenHash", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "pricingSnapshotId", "TEXT");
  await ensureColumn(prisma, "AdDeliveryToken", "eventTokensJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdImpression", "deliveryId", "TEXT");
  await ensureColumn(prisma, "AdImpression", "traceId", "TEXT");
  await ensureColumn(prisma, "AdImpression", "creativeVersion", "INTEGER");
  await ensureColumn(prisma, "AdImpression", "sessionHash", "TEXT");
  await ensureColumn(prisma, "AdImpression", "country", "TEXT");
  await ensureColumn(prisma, "AdImpression", "occurredAtClient", "DATETIME");
  await ensureColumn(prisma, "AdImpression", "receivedAtServer", "DATETIME");
  await ensureColumn(prisma, "AdImpression", "verifiedAt", "DATETIME");
  await ensureColumn(prisma, "AdImpression", "verificationStatus", "TEXT NOT NULL DEFAULT 'verified'");
  await ensureColumn(prisma, "AdImpression", "failureReasonCode", "TEXT");
  await ensureColumn(prisma, "AdImpression", "deliveryTokenFingerprint", "TEXT");
  await ensureColumn(prisma, "AdImpression", "eventTokenFingerprint", "TEXT");
  await ensureColumn(prisma, "AdImpression", "idempotencyKey", "TEXT");
  await ensureColumn(prisma, "AdImpression", "costMinor", "INTEGER NOT NULL DEFAULT 0");
  await ensureColumn(prisma, "AdImpression", "currency", "TEXT NOT NULL DEFAULT 'USD'");
  await ensureColumn(prisma, "AdImpression", "ledgerEntryId", "TEXT");
  await ensureColumn(prisma, "AdImpression", "billingModel", "TEXT");
  await ensureColumn(prisma, "AdImpression", "metadataJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdImpression", "updatedAt", "DATETIME");
  await ensureColumn(prisma, "AdClick", "deliveryId", "TEXT");
  await ensureColumn(prisma, "AdClick", "traceId", "TEXT");
  await ensureColumn(prisma, "AdClick", "creativeVersion", "INTEGER");
  await ensureColumn(prisma, "AdClick", "sessionHash", "TEXT");
  await ensureColumn(prisma, "AdClick", "country", "TEXT");
  await ensureColumn(prisma, "AdClick", "deviceClass", "TEXT");
  await ensureColumn(prisma, "AdClick", "occurredAtClient", "DATETIME");
  await ensureColumn(prisma, "AdClick", "receivedAtServer", "DATETIME");
  await ensureColumn(prisma, "AdClick", "verifiedAt", "DATETIME");
  await ensureColumn(prisma, "AdClick", "verificationStatus", "TEXT NOT NULL DEFAULT 'verified'");
  await ensureColumn(prisma, "AdClick", "failureReasonCode", "TEXT");
  await ensureColumn(prisma, "AdClick", "deliveryTokenFingerprint", "TEXT");
  await ensureColumn(prisma, "AdClick", "eventTokenFingerprint", "TEXT");
  await ensureColumn(prisma, "AdClick", "idempotencyKey", "TEXT");
  await ensureColumn(prisma, "AdClick", "costMinor", "INTEGER NOT NULL DEFAULT 0");
  await ensureColumn(prisma, "AdClick", "currency", "TEXT NOT NULL DEFAULT 'USD'");
  await ensureColumn(prisma, "AdClick", "ledgerEntryId", "TEXT");
  await ensureColumn(prisma, "AdClick", "billingModel", "TEXT");
  await ensureColumn(prisma, "AdClick", "destinationSnapshotJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdClick", "metadataJson", "TEXT NOT NULL DEFAULT '{}'");
  await ensureColumn(prisma, "AdClick", "updatedAt", "DATETIME");
  await ensureColumn(prisma, "AdLedgerEntry", "status", "TEXT NOT NULL DEFAULT 'posted'");
  await ensureColumn(prisma, "AdLedgerEntry", "stripeEventId", "TEXT");
  await ensureColumn(prisma, "AdPayment", "receiptId", "TEXT");
  await ensureColumn(prisma, "AdPayment", "failureCode", "TEXT");
  await ensureColumn(prisma, "AdPayment", "failureMessage", "TEXT");
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdCampaign_owner_client_submission_key" ON "AdCampaign" ("ownerUserId", "clientSubmissionId") WHERE "clientSubmissionId" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdLedgerEntry_stripe_event_entry_key" ON "AdLedgerEntry" ("stripeEventId", "entryType", "campaignId") WHERE "stripeEventId" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryToken_delivery_key" ON "AdDeliveryToken" ("deliveryId") WHERE "deliveryId" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryToken_impression_token_key" ON "AdDeliveryToken" ("impressionTokenHash") WHERE "impressionTokenHash" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdDeliveryToken_click_token_key" ON "AdDeliveryToken" ("clickTokenHash") WHERE "clickTokenHash" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdImpression_idempotency_key" ON "AdImpression" ("idempotencyKey") WHERE "idempotencyKey" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AdClick_idempotency_key" ON "AdClick" ("idempotencyKey") WHERE "idempotencyKey" IS NOT NULL`);

  ensured = true;
}

async function ensureColumn(prisma: PrismaClient, table: string, column: string, definition: string): Promise<void> {
  const columns = await prisma.$queryRawUnsafe<Array<{ name: string }>>(`PRAGMA table_info("${table}")`);
  if (columns.some((row) => row.name === column)) return;
  await prisma.$executeRawUnsafe(`ALTER TABLE "${table}" ADD COLUMN "${column}" ${definition}`);
}
