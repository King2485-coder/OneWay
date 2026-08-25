ALTER TABLE "User" ADD COLUMN "passwordChangedAt" DATETIME;
CREATE TABLE "PasswordResetToken" (
  "id" TEXT NOT NULL PRIMARY KEY, "userId" TEXT NOT NULL, "codeHash" TEXT NOT NULL,
  "expiresAt" DATETIME NOT NULL, "consumedAt" DATETIME, "attempts" INTEGER NOT NULL DEFAULT 0,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "PasswordResetToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX "PasswordResetToken_codeHash_key" ON "PasswordResetToken"("codeHash");
CREATE INDEX "PasswordResetToken_userId_createdAt_idx" ON "PasswordResetToken"("userId", "createdAt");
CREATE INDEX "PasswordResetToken_expiresAt_idx" ON "PasswordResetToken"("expiresAt");
