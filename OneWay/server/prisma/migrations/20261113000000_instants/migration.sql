CREATE TABLE IF NOT EXISTS "InstantPhoto" (
 "id" TEXT NOT NULL PRIMARY KEY, "senderId" TEXT NOT NULL, "ciphertext" TEXT, "fingerprint" TEXT NOT NULL,
 "createdAtMs" BIGINT NOT NULL, "expiresAtMs" BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS "InstantRecipient" (
 "instantId" TEXT NOT NULL, "userId" TEXT NOT NULL, "openedAtMs" BIGINT,
 PRIMARY KEY ("instantId","userId"), FOREIGN KEY ("instantId") REFERENCES "InstantPhoto"("id") ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX IF NOT EXISTS "InstantPhoto_senderId_expiresAtMs_idx" ON "InstantPhoto"("senderId","expiresAtMs");
CREATE INDEX IF NOT EXISTS "InstantPhoto_expiresAtMs_idx" ON "InstantPhoto"("expiresAtMs");
CREATE INDEX IF NOT EXISTS "InstantRecipient_userId_openedAtMs_idx" ON "InstantRecipient"("userId","openedAtMs");
