CREATE TABLE IF NOT EXISTS "EmailMailbox" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "userId" TEXT NOT NULL UNIQUE,
  "address" TEXT NOT NULL UNIQUE,
  "status" TEXT NOT NULL DEFAULT 'active',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailMailbox_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailThread" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "mailboxId" TEXT NOT NULL,
  "subjectPreview" TEXT NOT NULL DEFAULT '',
  "lastMessageAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailThread_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailMessage" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "threadId" TEXT NOT NULL,
  "mailboxId" TEXT NOT NULL,
  "providerMessageId" TEXT,
  "direction" TEXT NOT NULL,
  "folder" TEXT NOT NULL,
  "fromJson" TEXT NOT NULL,
  "toJson" TEXT NOT NULL,
  "ccJson" TEXT NOT NULL DEFAULT '[]',
  "bccJson" TEXT NOT NULL DEFAULT '[]',
  "subject" TEXT NOT NULL DEFAULT '',
  "bodyText" TEXT NOT NULL DEFAULT '',
  "bodyHtml" TEXT,
  "status" TEXT NOT NULL,
  "isRead" BOOLEAN NOT NULL DEFAULT false,
  "isStarred" BOOLEAN NOT NULL DEFAULT false,
  "spamScore" REAL,
  "headersJson" TEXT,
  "sentAt" DATETIME,
  "receivedAt" DATETIME,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailMessage_threadId_fkey" FOREIGN KEY ("threadId") REFERENCES "EmailThread"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT "EmailMessage_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailAttachment" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "messageId" TEXT NOT NULL,
  "filename" TEXT NOT NULL,
  "contentType" TEXT NOT NULL,
  "storageKey" TEXT NOT NULL UNIQUE,
  "bytes" INTEGER NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailAttachment_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "EmailMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailBlockedSender" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "mailboxId" TEXT NOT NULL,
  "senderHash" TEXT NOT NULL,
  "senderEncrypted" TEXT NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailBlockedSender_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailWebhookReceipt" (
  "token" TEXT NOT NULL PRIMARY KEY,
  "provider" TEXT NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "EmailDeliveryEvent" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "messageId" TEXT,
  "provider" TEXT NOT NULL,
  "eventType" TEXT NOT NULL,
  "recipientHash" TEXT,
  "detailsEncrypted" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailDeliveryEvent_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "EmailMessage"("id") ON DELETE SET NULL ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailSuppressionEntry" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "recipientHash" TEXT NOT NULL UNIQUE,
  "recipientEncrypted" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "EmailLabel" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "mailboxId" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "color" TEXT NOT NULL DEFAULT 'purple',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "EmailLabel_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "EmailMessageLabel" (
  "messageId" TEXT NOT NULL,
  "labelId" TEXT NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("messageId", "labelId"),
  CONSTRAINT "EmailMessageLabel_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "EmailMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT "EmailMessageLabel_labelId_fkey" FOREIGN KEY ("labelId") REFERENCES "EmailLabel"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS "EmailThread_mailboxId_lastMessageAt_idx" ON "EmailThread"("mailboxId", "lastMessageAt");
CREATE INDEX IF NOT EXISTS "EmailMessage_mailboxId_folder_createdAt_idx" ON "EmailMessage"("mailboxId", "folder", "createdAt");
CREATE UNIQUE INDEX IF NOT EXISTS "EmailMessage_mailboxId_providerMessageId_key" ON "EmailMessage"("mailboxId", "providerMessageId") WHERE "providerMessageId" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "EmailBlockedSender_mailboxId_senderHash_key" ON "EmailBlockedSender"("mailboxId", "senderHash");
CREATE UNIQUE INDEX IF NOT EXISTS "EmailLabel_mailboxId_name_key" ON "EmailLabel"("mailboxId", "name");
