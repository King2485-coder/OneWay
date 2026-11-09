CREATE TABLE "Friendship" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "requesterUserId" TEXT NOT NULL,
  "recipientUserId" TEXT NOT NULL,
  "pairKey" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'pending',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "acceptedAt" DATETIME,
  "deniedAt" DATETIME,
  "ignoredAt" DATETIME,
  "declinedAt" DATETIME,
  "blockedAt" DATETIME,
  "removedAt" DATETIME
);

CREATE UNIQUE INDEX "Friendship_pairKey_key" ON "Friendship"("pairKey");
CREATE INDEX "Friendship_requesterUserId_idx" ON "Friendship"("requesterUserId");
CREATE INDEX "Friendship_recipientUserId_idx" ON "Friendship"("recipientUserId");
CREATE INDEX "Friendship_status_idx" ON "Friendship"("status");
CREATE INDEX "Friendship_recipientUserId_status_idx" ON "Friendship"("recipientUserId", "status");
CREATE INDEX "Friendship_requesterUserId_status_idx" ON "Friendship"("requesterUserId", "status");
