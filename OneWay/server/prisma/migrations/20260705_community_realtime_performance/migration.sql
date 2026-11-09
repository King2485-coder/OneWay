-- Add optimistic-send dedupe and realtime performance indexes for communities.
ALTER TABLE "CommunityMessage" ADD COLUMN IF NOT EXISTS "clientMessageId" TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS "CommunityMessage_clientMessageId_key"
ON "CommunityMessage"("clientMessageId")
WHERE "clientMessageId" IS NOT NULL;

CREATE INDEX IF NOT EXISTS "CommunityMember_communityId_idx"
ON "CommunityMember"("communityId");

CREATE INDEX IF NOT EXISTS "CommunityMember_userId_idx"
ON "CommunityMember"("userId");

CREATE INDEX IF NOT EXISTS "CommunityMessage_communityId_idx"
ON "CommunityMessage"("communityId");

CREATE INDEX IF NOT EXISTS "CommunityMessage_createdAt_idx"
ON "CommunityMessage"("createdAt");

CREATE INDEX IF NOT EXISTS "CommunityMessage_clientMessageId_idx"
ON "CommunityMessage"("clientMessageId");
