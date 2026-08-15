-- OneWay Ads Phase 2B: activation gate, moderation readiness, and pre-delivery certification.
-- Additive only. Existing funding, receipt, webhook, and protected-system tables are not changed.

ALTER TABLE "AdCampaign" ADD COLUMN "currentRevision" INTEGER NOT NULL DEFAULT 1;
ALTER TABLE "AdCampaign" ADD COLUMN "eligibilityStateJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdCampaign" ADD COLUMN "lastEligibilityAt" DATETIME;

ALTER TABLE "AdCreative" ADD COLUMN "revision" INTEGER NOT NULL DEFAULT 1;
ALTER TABLE "AdCreative" ADD COLUMN "approvedFingerprint" TEXT;
ALTER TABLE "AdCreative" ADD COLUMN "approvedAt" DATETIME;

ALTER TABLE "AdModerationReview" ADD COLUMN "updatedAt" DATETIME;
ALTER TABLE "AdModerationReview" ADD COLUMN "decidedAt" DATETIME;
ALTER TABLE "AdModerationReview" ADD COLUMN "campaignRevision" INTEGER NOT NULL DEFAULT 1;
ALTER TABLE "AdModerationReview" ADD COLUMN "creativeVersion" INTEGER;
ALTER TABLE "AdModerationReview" ADD COLUMN "destinationSnapshotJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdModerationReview" ADD COLUMN "automatedReviewJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdModerationReview" ADD COLUMN "manualReviewJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdModerationReview" ADD COLUMN "decision" TEXT;
ALTER TABLE "AdModerationReview" ADD COLUMN "publicReason" TEXT;
ALTER TABLE "AdModerationReview" ADD COLUMN "internalNotes" TEXT;
ALTER TABLE "AdModerationReview" ADD COLUMN "policyCodesJson" TEXT NOT NULL DEFAULT '[]';
ALTER TABLE "AdModerationReview" ADD COLUMN "reviewerActorId" TEXT;

CREATE INDEX IF NOT EXISTS "AdCampaign_status_eligibility_idx"
ON "AdCampaign" ("status", "lastEligibilityAt");
