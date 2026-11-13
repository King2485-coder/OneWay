CREATE TABLE IF NOT EXISTS "SocialStory" ("id" TEXT PRIMARY KEY NOT NULL,"ownerId" TEXT NOT NULL,"visibility" TEXT NOT NULL,"storageKey" TEXT NOT NULL,"fingerprint" TEXT NOT NULL,"mediaType" TEXT,"mimeType" TEXT,"byteCount" INTEGER NOT NULL,"createdAtMs" BIGINT NOT NULL,"expiresAtMs" BIGINT NOT NULL);
CREATE INDEX IF NOT EXISTS "SocialStory_ownerId_expiresAtMs_idx" ON "SocialStory"("ownerId","expiresAtMs");
CREATE INDEX IF NOT EXISTS "SocialStory_expiresAtMs_idx" ON "SocialStory"("expiresAtMs");
CREATE TABLE IF NOT EXISTS "LiveStorySession" ("id" TEXT PRIMARY KEY NOT NULL,"activeOwnerId" TEXT,"ownerId" TEXT NOT NULL,"titleCiphertext" TEXT NOT NULL,"visibility" TEXT NOT NULL,"state" TEXT NOT NULL,"startedAtMs" BIGINT NOT NULL,"leaseUntilMs" BIGINT NOT NULL,"endedAtMs" BIGINT);
CREATE INDEX IF NOT EXISTS "LiveStorySession_ownerId_state_idx" ON "LiveStorySession"("ownerId","state");
CREATE INDEX IF NOT EXISTS "LiveStorySession_state_leaseUntilMs_idx" ON "LiveStorySession"("state","leaseUntilMs");
CREATE TABLE IF NOT EXISTS "LiveStoryViewer" ("sessionId" TEXT NOT NULL,"userId" TEXT NOT NULL,"identity" TEXT NOT NULL,"lastSeenMs" BIGINT NOT NULL,PRIMARY KEY("sessionId","userId"),FOREIGN KEY("sessionId") REFERENCES "LiveStorySession"("id") ON DELETE CASCADE ON UPDATE CASCADE);
CREATE UNIQUE INDEX IF NOT EXISTS "LiveStorySession_activeOwnerId_key" ON "LiveStorySession"("activeOwnerId");
