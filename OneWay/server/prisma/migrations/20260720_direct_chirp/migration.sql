ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "allowDirectChirp" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "directChirpAudience" TEXT NOT NULL DEFAULT 'everyone';
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "askBeforeConnecting" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "allowRepeatChirps" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "silenceUnknownChirps" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "requireVerifiedAccount" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "hideProfilePhotoFromUnknownUsers" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "blockUnknownDuringDnd" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "WalkiePrivacySettings" ADD COLUMN "autoBlockRepeatedAbuse" BOOLEAN NOT NULL DEFAULT true;

CREATE TABLE "DirectChirpRequest" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "senderUserId" TEXT NOT NULL,
  "recipientUserId" TEXT NOT NULL,
  "senderChirpId" TEXT NOT NULL,
  "recipientChirpId" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'pending',
  "clientRequestId" TEXT NOT NULL,
  "sourceDeviceId" TEXT,
  "notificationSentAt" DATETIME,
  "pushNotificationId" TEXT,
  "channelId" TEXT,
  "abuseScore" INTEGER NOT NULL DEFAULT 0,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "expiresAt" DATETIME NOT NULL,
  "acceptedAt" DATETIME,
  "declinedAt" DATETIME,
  "ignoredAt" DATETIME,
  "blockedAt" DATETIME,
  "cancelledAt" DATETIME,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX "DirectChirpRequest_senderUserId_recipientUserId_clientRequestId_key"
ON "DirectChirpRequest"("senderUserId", "recipientUserId", "clientRequestId");
CREATE INDEX "DirectChirpRequest_recipientUserId_status_createdAt_idx"
ON "DirectChirpRequest"("recipientUserId", "status", "createdAt");
CREATE INDEX "DirectChirpRequest_senderUserId_status_createdAt_idx"
ON "DirectChirpRequest"("senderUserId", "status", "createdAt");
CREATE INDEX "DirectChirpRequest_channelId_idx"
ON "DirectChirpRequest"("channelId");

CREATE TABLE "ChirpTrustPermission" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "ownerUserId" TEXT NOT NULL,
  "permittedUserId" TEXT NOT NULL,
  "permission" TEXT NOT NULL DEFAULT 'oneTime',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX "ChirpTrustPermission_ownerUserId_permittedUserId_key"
ON "ChirpTrustPermission"("ownerUserId", "permittedUserId");
CREATE INDEX "ChirpTrustPermission_ownerUserId_permission_idx"
ON "ChirpTrustPermission"("ownerUserId", "permission");
CREATE INDEX "ChirpTrustPermission_permittedUserId_idx"
ON "ChirpTrustPermission"("permittedUserId");
