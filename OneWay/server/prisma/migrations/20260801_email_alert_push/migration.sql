CREATE TABLE IF NOT EXISTS "AlertPushToken" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "token" TEXT NOT NULL UNIQUE,
  "environment" TEXT NOT NULL,
  "previewMode" TEXT NOT NULL DEFAULT 'sender_subject',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "AlertPushToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX IF NOT EXISTS "AlertPushToken_userId_updatedAt_idx" ON "AlertPushToken"("userId", "updatedAt");
