CREATE TABLE IF NOT EXISTS "CommunicationHubRead" ("userId" TEXT NOT NULL, "communityId" TEXT NOT NULL, "lastReadAtMs" BIGINT NOT NULL DEFAULT 0, PRIMARY KEY ("userId", "communityId"));
