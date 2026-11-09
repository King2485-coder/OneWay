PRAGMA defer_foreign_keys=ON;
PRAGMA foreign_keys=OFF;

CREATE TABLE "new_CommunityMessage" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "clientMessageId" TEXT,
    "communityId" TEXT NOT NULL,
    "senderId" TEXT NOT NULL,
    "senderHandle" TEXT NOT NULL,
    "senderDisplayName" TEXT NOT NULL,
    "contentMode" TEXT NOT NULL DEFAULT 'LEGACY_COMMUNITY_PLAINTEXT',
    "protocolVersion" INTEGER NOT NULL DEFAULT 0,
    "groupEpoch" INTEGER,
    "ciphertext" TEXT,
    "senderDeviceId" TEXT,
    "contentType" TEXT NOT NULL DEFAULT 'message',
    "body" TEXT,
    "status" TEXT NOT NULL DEFAULT 'sent',
    "expiresAt" DATETIME,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "CommunityMessage_communityId_fkey" FOREIGN KEY ("communityId") REFERENCES "Community" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "CommunityMessage_content_boundary" CHECK (
      ("contentMode" = 'LEGACY_COMMUNITY_PLAINTEXT' AND "protocolVersion" = 0 AND "body" IS NOT NULL AND "ciphertext" IS NULL)
      OR
      ("contentMode" = 'GROUP_E2EE_V1' AND "protocolVersion" = 1 AND "body" IS NULL AND "ciphertext" IS NOT NULL AND "senderDeviceId" IS NOT NULL AND "groupEpoch" IS NOT NULL)
    )
);

INSERT INTO "new_CommunityMessage" (
  "id", "clientMessageId", "communityId", "senderId", "senderHandle", "senderDisplayName",
  "contentMode", "protocolVersion", "contentType", "body", "status", "expiresAt", "createdAt", "updatedAt"
)
SELECT
  "id", "clientMessageId", "communityId", "senderId", "senderHandle", "senderDisplayName",
  'LEGACY_COMMUNITY_PLAINTEXT', 0, 'message', "body", "status", "expiresAt", "createdAt", "updatedAt"
FROM "CommunityMessage";

DROP TABLE "CommunityMessage";
ALTER TABLE "new_CommunityMessage" RENAME TO "CommunityMessage";
CREATE UNIQUE INDEX "CommunityMessage_clientMessageId_key" ON "CommunityMessage"("clientMessageId");
CREATE INDEX "CommunityMessage_communityId_idx" ON "CommunityMessage"("communityId");
CREATE INDEX "CommunityMessage_communityId_createdAt_idx" ON "CommunityMessage"("communityId", "createdAt");
CREATE INDEX "CommunityMessage_createdAt_idx" ON "CommunityMessage"("createdAt");
CREATE INDEX "CommunityMessage_expiresAt_idx" ON "CommunityMessage"("expiresAt");
CREATE INDEX "CommunityMessage_senderId_idx" ON "CommunityMessage"("senderId");
CREATE INDEX "CommunityMessage_communityId_contentMode_protocolVersion_idx" ON "CommunityMessage"("communityId", "contentMode", "protocolVersion");

PRAGMA foreign_keys=ON;
PRAGMA defer_foreign_keys=OFF;
