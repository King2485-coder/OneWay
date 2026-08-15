ALTER TABLE "Site" ADD COLUMN "slug" TEXT;
ALTER TABLE "Site" ADD COLUMN "publicAddress" TEXT;
ALTER TABLE "Site" ADD COLUMN "visibility" TEXT NOT NULL DEFAULT 'PUBLIC';
ALTER TABLE "Site" ADD COLUMN "status" TEXT NOT NULL DEFAULT 'DRAFT';
ALTER TABLE "Site" ADD COLUMN "activePublicationId" TEXT;
ALTER TABLE "Site" ADD COLUMN "draftVersion" INTEGER NOT NULL DEFAULT 1;

CREATE UNIQUE INDEX "Site_slug_key" ON "Site"("slug");
CREATE INDEX "Site_status_visibility_idx" ON "Site"("status", "visibility");

CREATE TABLE "SiteMediaAsset" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "siteId" TEXT NOT NULL,
  "ownerId" TEXT NOT NULL,
  "storageKey" TEXT NOT NULL,
  "originalFileName" TEXT NOT NULL,
  "mimeType" TEXT NOT NULL,
  "width" INTEGER,
  "height" INTEGER,
  "fileSizeBytes" INTEGER NOT NULL,
  "checksum" TEXT NOT NULL,
  "processingStatus" TEXT NOT NULL DEFAULT 'READY',
  "publicStatus" TEXT NOT NULL DEFAULT 'PRIVATE',
  "altText" TEXT NOT NULL DEFAULT '',
  "caption" TEXT NOT NULL DEFAULT '',
  "focalPointX" REAL NOT NULL DEFAULT 0.5,
  "focalPointY" REAL NOT NULL DEFAULT 0.5,
  "variantsJson" TEXT NOT NULL DEFAULT '{}',
  "usageCount" INTEGER NOT NULL DEFAULT 0,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "deletedAt" DATETIME,
  CONSTRAINT "SiteMediaAsset_siteId_fkey" FOREIGN KEY ("siteId") REFERENCES "Site" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT "SiteMediaAsset_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "SiteMediaAsset_siteId_processingStatus_idx" ON "SiteMediaAsset"("siteId", "processingStatus");
CREATE INDEX "SiteMediaAsset_ownerId_createdAt_idx" ON "SiteMediaAsset"("ownerId", "createdAt");
CREATE INDEX "SiteMediaAsset_publicStatus_idx" ON "SiteMediaAsset"("publicStatus");

CREATE TABLE "SitePublication" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "siteId" TEXT NOT NULL,
  "versionNumber" INTEGER NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'BUILDING',
  "publishedBy" TEXT NOT NULL,
  "publishedAt" DATETIME,
  "sourceDraftVersion" INTEGER NOT NULL DEFAULT 1,
  "contentManifest" TEXT NOT NULL,
  "assetManifest" TEXT NOT NULL,
  "publicAddress" TEXT NOT NULL,
  "buildStartedAt" DATETIME,
  "buildCompletedAt" DATETIME,
  "failureCode" TEXT,
  "failureMessage" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "SitePublication_siteId_fkey" FOREIGN KEY ("siteId") REFERENCES "Site" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT "SitePublication_publishedBy_fkey" FOREIGN KEY ("publishedBy") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE UNIQUE INDEX "SitePublication_siteId_versionNumber_key" ON "SitePublication"("siteId", "versionNumber");
CREATE INDEX "SitePublication_siteId_status_idx" ON "SitePublication"("siteId", "status");
CREATE INDEX "SitePublication_publicAddress_idx" ON "SitePublication"("publicAddress");
