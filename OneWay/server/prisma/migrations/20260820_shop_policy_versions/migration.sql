ALTER TABLE "StorePolicy" ADD COLUMN "draftJson" TEXT;
ALTER TABLE "StorePolicy" ADD COLUMN "publishedJson" TEXT;
ALTER TABLE "StorePolicy" ADD COLUMN "publishedVersion" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "StorePolicy" ADD COLUMN "publishedAt" DATETIME;

ALTER TABLE "Order" ADD COLUMN "policyVersion" INTEGER;
ALTER TABLE "Order" ADD COLUMN "policySnapshotJson" TEXT;
