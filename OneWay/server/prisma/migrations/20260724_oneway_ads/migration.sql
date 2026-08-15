-- OneWay Ads production foundation.
-- The application also calls ensureAdsTables() at route startup so legacy
-- environments self-heal without resetting existing Shop, Site, Wallet,
-- payment, Stripe, messaging, Quantum, call, LiveKit, CallKit, or Chirp data.

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
);

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
  "deletedAt" DATETIME
);

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
  "deletedAt" DATETIME
);

CREATE TABLE IF NOT EXISTS "AdPlacementSelection" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "placement" TEXT NOT NULL, "enabled" BOOLEAN NOT NULL DEFAULT 1, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE ("campaignId", "placement"));
CREATE TABLE IF NOT EXISTS "AdAudienceRule" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "ruleType" TEXT NOT NULL, "ruleValue" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdModerationReview" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "creativeId" TEXT, "reviewType" TEXT NOT NULL DEFAULT 'automated', "status" TEXT NOT NULL, "riskLevel" TEXT NOT NULL DEFAULT 'low', "rejectionReason" TEXT, "reviewerNotes" TEXT, "appealState" TEXT NOT NULL DEFAULT 'not_appealed', "createdBy" TEXT, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdBudget" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL UNIQUE, "currency" TEXT NOT NULL DEFAULT 'USD', "dailyBudgetMinor" INTEGER NOT NULL DEFAULT 0, "lifetimeBudgetMinor" INTEGER NOT NULL DEFAULT 0, "fundedMinor" INTEGER NOT NULL DEFAULT 0, "reservedMinor" INTEGER NOT NULL DEFAULT 0, "spentMinor" INTEGER NOT NULL DEFAULT 0, "remainingMinor" INTEGER NOT NULL DEFAULT 0, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdLedgerEntry" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "advertiserId" TEXT NOT NULL, "entryType" TEXT NOT NULL, "amountMinor" INTEGER NOT NULL, "currency" TEXT NOT NULL DEFAULT 'USD', "idempotencyKey" TEXT NOT NULL UNIQUE, "stripePaymentIntentId" TEXT, "metadataJson" TEXT NOT NULL DEFAULT '{}', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdPayment" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "advertiserId" TEXT NOT NULL, "ownerUserId" TEXT NOT NULL, "stripePaymentIntentId" TEXT UNIQUE, "stripeCustomerId" TEXT, "amountMinor" INTEGER NOT NULL, "currency" TEXT NOT NULL DEFAULT 'USD', "status" TEXT NOT NULL DEFAULT 'requires_payment', "idempotencyKey" TEXT NOT NULL UNIQUE, "metadataJson" TEXT NOT NULL DEFAULT '{}', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdDeliveryToken" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "creativeId" TEXT NOT NULL, "viewerHash" TEXT NOT NULL, "placement" TEXT NOT NULL, "tokenHash" TEXT NOT NULL UNIQUE, "expiresAt" DATETIME NOT NULL, "impressionId" TEXT, "clickId" TEXT, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdImpression" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "creativeId" TEXT NOT NULL, "advertiserId" TEXT NOT NULL, "placement" TEXT NOT NULL, "viewerHash" TEXT NOT NULL, "tokenHash" TEXT NOT NULL UNIQUE, "billableStatus" TEXT NOT NULL DEFAULT 'billable', "deviceClass" TEXT, "contextualCategory" TEXT, "fraudStatus" TEXT NOT NULL DEFAULT 'clean', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdClick" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "creativeId" TEXT NOT NULL, "advertiserId" TEXT NOT NULL, "impressionId" TEXT, "placement" TEXT NOT NULL, "viewerHash" TEXT NOT NULL, "destinationType" TEXT NOT NULL, "destinationURL" TEXT, "billableStatus" TEXT NOT NULL DEFAULT 'not_billable_cpc_disabled', "fraudStatus" TEXT NOT NULL DEFAULT 'clean', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdConversion" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "creativeId" TEXT, "advertiserId" TEXT NOT NULL, "conversionType" TEXT NOT NULL, "sourceEntityType" TEXT, "sourceEntityId" TEXT, "amountMinor" INTEGER NOT NULL DEFAULT 0, "currency" TEXT NOT NULL DEFAULT 'USD', "verified" BOOLEAN NOT NULL DEFAULT 0, "attributionWindow" TEXT NOT NULL DEFAULT 'click_7d_view_1d', "metadataJson" TEXT NOT NULL DEFAULT '{}', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdUserPreference" ("id" TEXT PRIMARY KEY, "userId" TEXT NOT NULL UNIQUE, "contextualCategoriesJson" TEXT NOT NULL DEFAULT '[]', "locationBasedAdsEnabled" BOOLEAN NOT NULL DEFAULT 0, "reducedRepetitionEnabled" BOOLEAN NOT NULL DEFAULT 1, "minorContextualOnly" BOOLEAN NOT NULL DEFAULT 0, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdAdvertiserBlock" ("id" TEXT PRIMARY KEY, "userId" TEXT NOT NULL, "advertiserId" TEXT NOT NULL, "reason" TEXT, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE ("userId", "advertiserId"));
CREATE TABLE IF NOT EXISTS "AdReport" ("id" TEXT PRIMARY KEY, "userId" TEXT, "campaignId" TEXT NOT NULL, "creativeId" TEXT, "advertiserId" TEXT NOT NULL, "placement" TEXT, "reason" TEXT NOT NULL, "details" TEXT, "campaignSnapshotJson" TEXT NOT NULL DEFAULT '{}', "creativeSnapshotJson" TEXT NOT NULL DEFAULT '{}', "status" TEXT NOT NULL DEFAULT 'open', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdAuditLog" ("id" TEXT PRIMARY KEY, "actorUserId" TEXT, "actorType" TEXT NOT NULL DEFAULT 'system', "action" TEXT NOT NULL, "resourceType" TEXT NOT NULL, "resourceId" TEXT NOT NULL, "metadataJson" TEXT NOT NULL DEFAULT '{}', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS "AdDailyMetric" ("id" TEXT PRIMARY KEY, "campaignId" TEXT NOT NULL, "advertiserId" TEXT NOT NULL, "metricDate" TEXT NOT NULL, "placement" TEXT, "impressions" INTEGER NOT NULL DEFAULT 0, "clicks" INTEGER NOT NULL DEFAULT 0, "conversions" INTEGER NOT NULL DEFAULT 0, "spendMinor" INTEGER NOT NULL DEFAULT 0, "salesAttributedMinor" INTEGER NOT NULL DEFAULT 0, "currency" TEXT NOT NULL DEFAULT 'USD', "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE ("campaignId", "metricDate", "placement"));

CREATE INDEX IF NOT EXISTS "AdvertiserProfile_owner_status_idx" ON "AdvertiserProfile" ("ownerUserId", "status");
CREATE INDEX IF NOT EXISTS "AdCampaign_owner_status_idx" ON "AdCampaign" ("ownerUserId", "status");
CREATE INDEX IF NOT EXISTS "AdCreative_campaign_status_idx" ON "AdCreative" ("campaignId", "status");
CREATE INDEX IF NOT EXISTS "AdImpression_campaign_created_idx" ON "AdImpression" ("campaignId", "createdAt");
CREATE INDEX IF NOT EXISTS "AdClick_campaign_created_idx" ON "AdClick" ("campaignId", "createdAt");
