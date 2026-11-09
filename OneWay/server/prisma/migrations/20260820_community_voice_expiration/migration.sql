ALTER TABLE "CommunityMessage" ADD COLUMN "expiresAt" TIMESTAMP(3);
CREATE INDEX "CommunityMessage_expiresAt_idx" ON "CommunityMessage"("expiresAt");
