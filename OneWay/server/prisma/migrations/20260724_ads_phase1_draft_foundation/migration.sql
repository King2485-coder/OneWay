-- OneWay Ads Phase 1 draft foundation.
-- Safe additive fields used by the guided builder, advertiser ownership checks,
-- idempotent moderation submission, and future admin review snapshots.

ALTER TABLE "AdvertiserProfile" ADD COLUMN "associatedProfileId" TEXT;
ALTER TABLE "AdvertiserProfile" ADD COLUMN "associatedCommunityId" TEXT;
ALTER TABLE "AdvertiserProfile" ADD COLUMN "billingStatus" TEXT NOT NULL DEFAULT 'not_started';
ALTER TABLE "AdvertiserProfile" ADD COLUMN "version" INTEGER NOT NULL DEFAULT 1;

ALTER TABLE "AdCampaign" ADD COLUMN "currentBuilderStep" TEXT NOT NULL DEFAULT 'profile';
ALTER TABLE "AdCampaign" ADD COLUMN "draftCompletionStateJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdCampaign" ADD COLUMN "clientSubmissionId" TEXT;
ALTER TABLE "AdCampaign" ADD COLUMN "submittedSnapshotJson" TEXT NOT NULL DEFAULT '{}';
ALTER TABLE "AdCampaign" ADD COLUMN "scheduleTimezone" TEXT;
ALTER TABLE "AdCampaign" ADD COLUMN "version" INTEGER NOT NULL DEFAULT 1;

ALTER TABLE "AdCreative" ADD COLUMN "accessibilityDescription" TEXT;

CREATE UNIQUE INDEX "AdCampaign_owner_client_submission_key"
ON "AdCampaign" ("ownerUserId", "clientSubmissionId")
WHERE "clientSubmissionId" IS NOT NULL;
