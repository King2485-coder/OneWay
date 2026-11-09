ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "mediaType" TEXT NOT NULL DEFAULT 'IMAGE';
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "originalStorageKey" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "processedStorageKey" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "thumbnailStorageKey" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "playbackManifestKey" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "sourceMimeType" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "outputMimeType" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "durationMilliseconds" INTEGER;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "uploadStatus" TEXT NOT NULL DEFAULT 'UPLOADED';
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "failureCode" TEXT;
ALTER TABLE "SiteMediaAsset" ADD COLUMN IF NOT EXISTS "failureMessage" TEXT;

CREATE INDEX IF NOT EXISTS "SiteMediaAsset_siteId_mediaType_idx" ON "SiteMediaAsset"("siteId", "mediaType");
CREATE INDEX IF NOT EXISTS "SiteMediaAsset_uploadStatus_idx" ON "SiteMediaAsset"("uploadStatus");
