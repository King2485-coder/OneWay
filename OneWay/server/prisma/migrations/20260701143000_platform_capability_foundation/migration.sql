-- OneWay platform capability foundation.
-- Idempotent by design so local/dev databases can safely receive it more than once.

CREATE TABLE IF NOT EXISTS "PlatformCapabilityState" (
  "id" TEXT PRIMARY KEY,
  "groupName" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "privacyLevel" TEXT NOT NULL,
  "routeHint" TEXT,
  "notes" TEXT,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "PlatformCapabilityState_group_status_idx"
  ON "PlatformCapabilityState"("groupName", "status");

CREATE TABLE IF NOT EXISTS "PrivacySetting" (
  "id" TEXT PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "key" TEXT NOT NULL,
  "value" TEXT NOT NULL,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "PrivacySetting_user_key_unique"
  ON "PrivacySetting"("userId", "key");

CREATE TABLE IF NOT EXISTS "AILog" (
  "id" TEXT PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "action" TEXT NOT NULL,
  "contentScope" TEXT NOT NULL,
  "requiresDecryptedContent" BOOLEAN NOT NULL DEFAULT false,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "AILog_user_created_idx"
  ON "AILog"("userId", "createdAt");

CREATE TABLE IF NOT EXISTS "CloudFile" (
  "id" TEXT PRIMARY KEY,
  "ownerId" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "mimeType" TEXT,
  "byteCount" INTEGER NOT NULL DEFAULT 0,
  "storageKey" TEXT NOT NULL,
  "encrypted" BOOLEAN NOT NULL DEFAULT true,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "CloudFile_owner_updated_idx"
  ON "CloudFile"("ownerId", "updatedAt");

CREATE TABLE IF NOT EXISTS "ScheduledMessage" (
  "id" TEXT PRIMARY KEY,
  "conversationId" TEXT NOT NULL,
  "senderId" TEXT NOT NULL,
  "body" TEXT NOT NULL,
  "scheduledFor" DATETIME NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'scheduled',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "ScheduledMessage_sender_status_idx"
  ON "ScheduledMessage"("senderId", "status", "scheduledFor");

CREATE TABLE IF NOT EXISTS "ChannelPost" (
  "id" TEXT PRIMARY KEY,
  "channelId" TEXT NOT NULL,
  "authorId" TEXT NOT NULL,
  "body" TEXT NOT NULL,
  "reactionCount" INTEGER NOT NULL DEFAULT 0,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "ChannelPost_channel_created_idx"
  ON "ChannelPost"("channelId", "createdAt");

CREATE TABLE IF NOT EXISTS "WorkspaceItem" (
  "id" TEXT PRIMARY KEY,
  "workspaceId" TEXT NOT NULL,
  "type" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'open',
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "WorkspaceItem_workspace_type_idx"
  ON "WorkspaceItem"("workspaceId", "type", "updatedAt");
