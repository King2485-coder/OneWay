ALTER TABLE "User" ADD COLUMN "chirpId" TEXT;
ALTER TABLE "User" ADD COLUMN "chirpIdNormalized" TEXT;
ALTER TABLE "User" ADD COLUMN "chirpIdCreatedAt" DATETIME;

CREATE UNIQUE INDEX "User_chirpId_key" ON "User"("chirpId");
CREATE UNIQUE INDEX "User_chirpIdNormalized_key" ON "User"("chirpIdNormalized");

ALTER TABLE "OneWayContact" ADD COLUMN "acceptedAt" DATETIME;
ALTER TABLE "OneWayContact" ADD COLUMN "removedAt" DATETIME;
ALTER TABLE "OneWayContact" ADD COLUMN "blockedAt" DATETIME;

CREATE TABLE "WalkieFavorite" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "contactUserId" TEXT NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX "WalkieFavorite_userId_contactUserId_key" ON "WalkieFavorite"("userId", "contactUserId");
CREATE INDEX "WalkieFavorite_userId_createdAt_idx" ON "WalkieFavorite"("userId", "createdAt");
CREATE INDEX "WalkieFavorite_contactUserId_idx" ON "WalkieFavorite"("contactUserId");
