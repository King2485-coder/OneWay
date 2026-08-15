import type { PrismaClient } from "@prisma/client";
import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import type { ObjectStorage } from "../../lib/storage/ObjectStorage";
import { decryptIfEncrypted, encryptIfEnabled, hmacLookupIfEnabled } from "../privacy/EncryptionService";
import type { EmailProvider } from "./EmailProvider";
import { normalizeEmail, sanitizeEmailHtml, sanitizeEmailText } from "../storeEmailMessages";
import type { EmailAlertPushService } from "../EmailAlertPushService";

export type MailFolder = "inbox" | "starred" | "sent" | "drafts" | "archive" | "trash" | "spam" | "all";
type MutableMailFolder = Exclude<MailFolder, "starred" | "all">;

type MailboxRow = { id: string; userId: string; address: string; status: string; createdAt: string | Date; updatedAt: string | Date };
type MessageRow = {
  id: string; threadId: string; mailboxId: string; providerMessageId: string | null; direction: string; folder: string;
  fromJson: string; toJson: string; ccJson: string; bccJson: string; subject: string; bodyText: string; bodyHtml: string | null;
  status: string; isRead: number | boolean; isStarred: number | boolean; spamScore: number | null; headersJson: string | null;
  sentAt: string | Date | null; receivedAt: string | Date | null; createdAt: string | Date; updatedAt: string | Date;
};
type AttachmentRow = { id: string; messageId: string; filename: string; contentType: string; storageKey: string; bytes: number; createdAt: string | Date };

const MAILBOX_DOMAIN = () => (process.env.ONEWAY_EMAIL_DOMAIN?.trim() || "oneway.is").toLowerCase();
const RESERVED = new Set(["admin", "administrator", "abuse", "billing", "contact", "help", "hostmaster", "legal", "mailer-daemon", "noreply", "notifications", "oneway", "postmaster", "privacy", "root", "sales", "security", "support", "webmaster"]);
const DISALLOWED = ["fuck", "shit", "nigger", "cunt"];
const ADDRESS_LOCAL_RE = /^[a-z0-9](?:[a-z0-9._-]{1,30}[a-z0-9])?$/;

export class MailboxError extends Error {
  constructor(public readonly code: string, public readonly status = 400, message = code) {
    super(message);
  }
}

export class OneWayMailboxService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly storage: ObjectStorage,
    private readonly provider: EmailProvider,
    private readonly alerts?: EmailAlertPushService,
  ) {}

  async ensureTables(): Promise<void> {
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailMailbox" (
      "id" TEXT NOT NULL PRIMARY KEY, "userId" TEXT NOT NULL UNIQUE, "address" TEXT NOT NULL UNIQUE,
      "status" TEXT NOT NULL DEFAULT 'active', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailMailbox_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailThread" (
      "id" TEXT NOT NULL PRIMARY KEY, "mailboxId" TEXT NOT NULL, "subjectPreview" TEXT NOT NULL DEFAULT '',
      "lastMessageAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailThread_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailMessage" (
      "id" TEXT NOT NULL PRIMARY KEY, "threadId" TEXT NOT NULL, "mailboxId" TEXT NOT NULL, "providerMessageId" TEXT,
      "direction" TEXT NOT NULL, "folder" TEXT NOT NULL, "fromJson" TEXT NOT NULL, "toJson" TEXT NOT NULL,
      "ccJson" TEXT NOT NULL DEFAULT '[]', "bccJson" TEXT NOT NULL DEFAULT '[]', "subject" TEXT NOT NULL DEFAULT '',
      "bodyText" TEXT NOT NULL DEFAULT '', "bodyHtml" TEXT, "status" TEXT NOT NULL, "isRead" BOOLEAN NOT NULL DEFAULT false,
      "isStarred" BOOLEAN NOT NULL DEFAULT false, "spamScore" REAL, "headersJson" TEXT, "sentAt" DATETIME,
      "receivedAt" DATETIME, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailMessage_threadId_fkey" FOREIGN KEY ("threadId") REFERENCES "EmailThread"("id") ON DELETE CASCADE ON UPDATE CASCADE,
      CONSTRAINT "EmailMessage_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailAttachment" (
      "id" TEXT NOT NULL PRIMARY KEY, "messageId" TEXT NOT NULL, "filename" TEXT NOT NULL, "contentType" TEXT NOT NULL,
      "storageKey" TEXT NOT NULL UNIQUE, "bytes" INTEGER NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailAttachment_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "EmailMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailBlockedSender" (
      "id" TEXT NOT NULL PRIMARY KEY, "mailboxId" TEXT NOT NULL, "senderHash" TEXT NOT NULL, "senderEncrypted" TEXT NOT NULL,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailBlockedSender_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailWebhookReceipt" (
      "token" TEXT NOT NULL PRIMARY KEY, "provider" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailDeliveryEvent" (
      "id" TEXT NOT NULL PRIMARY KEY, "messageId" TEXT, "provider" TEXT NOT NULL, "eventType" TEXT NOT NULL,
      "recipientHash" TEXT, "detailsEncrypted" TEXT, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailDeliveryEvent_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "EmailMessage"("id") ON DELETE SET NULL ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailSuppressionEntry" (
      "id" TEXT NOT NULL PRIMARY KEY, "recipientHash" TEXT NOT NULL UNIQUE, "recipientEncrypted" TEXT NOT NULL,
      "reason" TEXT NOT NULL, "provider" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailLabel" (
      "id" TEXT NOT NULL PRIMARY KEY, "mailboxId" TEXT NOT NULL, "name" TEXT NOT NULL, "color" TEXT NOT NULL DEFAULT 'purple',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "EmailLabel_mailboxId_fkey" FOREIGN KEY ("mailboxId") REFERENCES "EmailMailbox"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "EmailMessageLabel" (
      "messageId" TEXT NOT NULL, "labelId" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY ("messageId","labelId"),
      CONSTRAINT "EmailMessageLabel_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "EmailMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE,
      CONSTRAINT "EmailMessageLabel_labelId_fkey" FOREIGN KEY ("labelId") REFERENCES "EmailLabel"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "EmailThread_mailboxId_lastMessageAt_idx" ON "EmailThread"("mailboxId", "lastMessageAt")`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "EmailMessage_mailboxId_folder_createdAt_idx" ON "EmailMessage"("mailboxId", "folder", "createdAt")`);
    await this.prisma.$executeRawUnsafe(`DROP INDEX IF EXISTS "EmailMessage_providerMessageId_key"`);
    await this.prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "EmailMessage_mailboxId_providerMessageId_key" ON "EmailMessage"("mailboxId", "providerMessageId") WHERE "providerMessageId" IS NOT NULL`);
    await this.prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "EmailBlockedSender_mailboxId_senderHash_key" ON "EmailBlockedSender"("mailboxId", "senderHash")`);
    await this.prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "EmailLabel_mailboxId_name_key" ON "EmailLabel"("mailboxId","name")`);
  }

  readiness() {
    const missing: string[] = [];
    if (this.provider.name !== "mailgun") missing.push("EMAIL_PROVIDER=mailgun");
    for (const key of ["MAILGUN_API_KEY", "MAILGUN_WEBHOOK_SIGNING_KEY", "ONEWAY_EMAIL_DOMAIN"]) {
      if (!process.env[key]?.trim()) missing.push(key);
    }
    if (process.env.FIELD_ENCRYPTION_ENABLED !== "true") missing.push("FIELD_ENCRYPTION_ENABLED=true");
    if (!process.env.FIELD_HASH_KEY_BASE64?.trim()) missing.push("FIELD_HASH_KEY_BASE64");
    const launchAttestations = [
      "ONEWAY_EMAIL_DNS_VERIFIED", "ONEWAY_EMAIL_INBOUND_VERIFIED", "ONEWAY_EMAIL_GMAIL_DELIVERY_VERIFIED",
      "ONEWAY_EMAIL_OUTLOOK_DELIVERY_VERIFIED", "ONEWAY_EMAIL_BOUNCE_VERIFIED", "ONEWAY_EMAIL_COMPLAINT_VERIFIED",
      "ONEWAY_EMAIL_MALWARE_SCANNER_ENABLED", "ONEWAY_EMAIL_PUSH_ENABLED", "ONEWAY_EMAIL_TERMS_PUBLISHED",
      "ONEWAY_EMAIL_SUPPORT_READY", "ONEWAY_EMAIL_PRICING_COSTS_APPROVED",
    ];
    for (const key of launchAttestations) if (process.env[key] !== "true") missing.push(`${key}=true`);
    return {
      ready: missing.length === 0,
      liveDeliveryEnabled: missing.length === 0 && process.env.ONEWAY_EMAIL_LIVE_DELIVERY_ENABLED === "true",
      verificationModeEnabled: this.verificationModeReady(),
      provider: this.provider.name,
      domain: MAILBOX_DOMAIN(),
      missing,
      dnsRequired: ["MX", "SPF", "DKIM", "DMARC"],
    };
  }

  async claim(userId: string, requested?: string): Promise<Record<string, unknown>> {
    await this.ensureTables();
    const existing = await this.mailboxForUser(userId);
    if (existing) return this.publicMailbox(existing);

    const identity = await this.prisma.oneWayIdentity.findUnique({ where: { userId }, select: { emailAlias: true } });
    const identityLocalPart = identity?.emailAlias?.split("@")[0] || "";
    const address = this.validateAddress(requested || (identityLocalPart ? `${identityLocalPart}@${MAILBOX_DOMAIN()}` : ""));
    try {
      await this.prisma.$executeRawUnsafe(
        `INSERT INTO "EmailMailbox" ("id", "userId", "address", "status") VALUES (?, ?, ?, 'active')`,
        randomUUID(), userId, address,
      );
    } catch (error) {
      if (String(error).toLowerCase().includes("unique")) throw new MailboxError("address_unavailable", 409);
      throw error;
    }
    const mailbox = await this.mailboxForUser(userId);
    if (!mailbox) throw new MailboxError("mailbox_create_failed", 500);
    return this.publicMailbox(mailbox);
  }

  async getMailbox(userId: string): Promise<Record<string, unknown> | null> {
    await this.ensureTables();
    const mailbox = await this.mailboxForUser(userId);
    return mailbox ? this.publicMailbox(mailbox) : null;
  }

  async list(userId: string, folder: MailFolder, cursor?: string, limit = 40, query?: string) {
    const mailbox = await this.requireMailbox(userId);
    const bounded = Math.min(Math.max(limit, 1), 100);
    const folderClause = folder === "starred"
      ? `"isStarred" = true AND "folder" != 'trash'`
      : folder === "all"
        ? `"folder" NOT IN ('drafts','trash','spam')`
        : `"folder" = ?`;
    const rows = await this.prisma.$queryRawUnsafe<MessageRow[]>(
      `SELECT * FROM "EmailMessage" WHERE "mailboxId" = ? AND ${folderClause} ${cursor ? `AND "createdAt" < ?` : ""} ORDER BY "createdAt" DESC LIMIT ?`,
      ...[mailbox.id, ...(folder === "starred" || folder === "all" ? [] : [folder]), ...(cursor ? [cursor] : []), query ? 250 : bounded],
    );
    const decoded = await Promise.all(rows.map((row) => this.publicMessage(row, false)));
    const normalizedQuery = query?.trim().toLowerCase();
    const filtered = normalizedQuery
      ? decoded.filter((message) => JSON.stringify(message).toLowerCase().includes(normalizedQuery)).slice(0, bounded)
      : decoded;
    return { messages: filtered, nextCursor: filtered.length === bounded ? String(filtered.at(-1)?.createdAt || "") : null };
  }

  async thread(userId: string, threadId: string) {
    const mailbox = await this.requireMailbox(userId);
    const rows = await this.prisma.$queryRawUnsafe<MessageRow[]>(
      `SELECT * FROM "EmailMessage" WHERE "mailboxId" = ? AND "threadId" = ? ORDER BY "createdAt" ASC`, mailbox.id, threadId,
    );
    if (!rows.length) throw new MailboxError("thread_not_found", 404);
    await this.prisma.$executeRawUnsafe(`UPDATE "EmailMessage" SET "isRead" = true, "updatedAt" = CURRENT_TIMESTAMP WHERE "mailboxId" = ? AND "threadId" = ?`, mailbox.id, threadId);
    return { id: threadId, messages: await Promise.all(rows.map((row) => this.publicMessage({ ...row, isRead: true }, true))) };
  }

  async saveDraft(userId: string, input: MailInput & { id?: string; threadId?: string }) {
    const mailbox = await this.requireMailbox(userId);
    const id = input.id || randomUUID();
    const threadId = input.threadId || randomUUID();
    this.validateRecipients(input, false);
    await this.ensureThread(mailbox.id, threadId, input.subject || "");
    const fields = this.protectedFields(id, mailbox.address, input);
    const prior = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailMessage" WHERE "id" = ? AND "mailboxId" = ? AND "folder" = 'drafts'`, id, mailbox.id);
    if (prior.length) {
      await this.prisma.$executeRawUnsafe(`UPDATE "EmailMessage" SET "toJson"=?, "ccJson"=?, "bccJson"=?, "subject"=?, "bodyText"=?, "bodyHtml"=?, "updatedAt"=CURRENT_TIMESTAMP WHERE "id"=? AND "mailboxId"=?`, fields.to, fields.cc, fields.bcc, fields.subject, fields.text, fields.html, id, mailbox.id);
    } else {
      await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailMessage" ("id","threadId","mailboxId","direction","folder","fromJson","toJson","ccJson","bccJson","subject","bodyText","bodyHtml","status","isRead") VALUES (?,?,?,'outbound','drafts',?,?,?,?,?,?,?,'draft',true)`, id, threadId, mailbox.id, fields.from, fields.to, fields.cc, fields.bcc, fields.subject, fields.text, fields.html);
    }
    return this.messageById(mailbox.id, id);
  }

  async send(userId: string, input: MailInput & { draftId?: string; threadId?: string; inReplyTo?: string; references?: string[] }) {
    const mailbox = await this.requireMailbox(userId);
    this.validateRecipients(input, true);
    const readiness = this.readiness();
    const verificationMode = !readiness.liveDeliveryEnabled && readiness.verificationModeEnabled;
    if (!readiness.liveDeliveryEnabled && !verificationMode) {
      throw new MailboxError(
        "email_delivery_not_ready",
        503,
        "OneWay Email is still being activated. Your message was not sent; save it as a draft and try again soon.",
      );
    }
    if (verificationMode) {
      const allowedRecipients = this.verificationRecipients();
      const requestedRecipients = [...input.to, ...(input.cc || []), ...(input.bcc || [])]
        .map((value) => normalizeEmail(value))
        .filter((value): value is string => Boolean(value));
      if (requestedRecipients.some((recipient) => !allowedRecipients.has(recipient))) {
        throw new MailboxError(
          "email_verification_recipient_not_allowed",
          403,
          "Email verification is currently limited to approved test addresses.",
        );
      }
      if ((input.attachments || []).length > 0) {
        throw new MailboxError(
          "email_verification_attachments_disabled",
          403,
          "Attachments are disabled during email verification.",
        );
      }
    }
    const sentToday = await this.prisma.$queryRawUnsafe<Array<{ count: bigint | number }>>(`SELECT COUNT(*) AS count FROM "EmailMessage" WHERE "mailboxId"=? AND "direction"='outbound' AND "folder"='sent' AND "createdAt" >= datetime('now','-1 day')`, mailbox.id);
    const dailyLimit = Number(process.env.ONEWAY_EMAIL_DAILY_SEND_LIMIT || 100);
    if (Number(sentToday[0]?.count || 0) >= dailyLimit) throw new MailboxError("daily_send_limit_reached", 429);

    const messageId = input.draftId || randomUUID();
    const threadId = input.threadId || randomUUID();
    const attachments = input.attachments ?? [];
    const totalBytes = attachments.reduce((sum, item) => sum + item.data.length, 0);
    if (attachments.length > 10 || totalBytes > Number(process.env.ONEWAY_EMAIL_MAX_ATTACHMENT_BYTES || 25_000_000)) throw new MailboxError("attachment_limit_exceeded", 413);
    this.validateAttachments(attachments);
    const suppressed: string[] = [];
    for (const recipient of [...input.to, ...(input.cc || []), ...(input.bcc || [])]) {
      const normalized = normalizeEmail(recipient)!;
      const hash = this.suppressionHash(normalized);
      const rows = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailSuppressionEntry" WHERE "recipientHash"=? LIMIT 1`, hash);
      if (rows.length) suppressed.push(normalized);
    }
    if (suppressed.length) throw new MailboxError("recipient_suppressed", 409, "One or more recipients are suppressed after a bounce or complaint.");
    const result = await this.provider.sendOutboundMessage({
      fromUserId: userId, fromEmail: mailbox.address, toEmail: input.to[0], toEmails: input.to, ccEmails: input.cc, bccEmails: input.bcc,
      subject: input.subject, body: input.bodyText, htmlBody: input.bodyHtml, messageSessionId: messageId,
      inReplyTo: input.inReplyTo, references: input.references, attachments,
    });
    if (result.status === "failed") throw new MailboxError("provider_send_failed", 502, result.message);
    await this.ensureThread(mailbox.id, threadId, input.subject || "");
    const fields = this.protectedFields(messageId, mailbox.address, input);
    if (input.draftId) await this.prisma.$executeRawUnsafe(`DELETE FROM "EmailMessage" WHERE "id"=? AND "mailboxId"=? AND "folder"='drafts'`, input.draftId, mailbox.id);
    await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailMessage" ("id","threadId","mailboxId","providerMessageId","direction","folder","fromJson","toJson","ccJson","bccJson","subject","bodyText","bodyHtml","status","isRead","sentAt") VALUES (?,?,?,?,'outbound','sent',?,?,?,?,?,?,?,'queued',true,CURRENT_TIMESTAMP)`, messageId, threadId, mailbox.id, result.providerMessageId, fields.from, fields.to, fields.cc, fields.bcc, fields.subject, fields.text, fields.html);
    await this.storeAttachments(messageId, attachments);
    await this.touchThread(threadId);
    return this.messageById(mailbox.id, messageId);
  }

  async update(userId: string, messageId: string, input: { folder?: MutableMailFolder; isRead?: boolean; isStarred?: boolean }) {
    const mailbox = await this.requireMailbox(userId);
    const allowed = new Set<MutableMailFolder>(["inbox", "sent", "drafts", "archive", "trash", "spam"]);
    if (input.folder && !allowed.has(input.folder)) throw new MailboxError("invalid_folder");
    const current = await this.messageRow(mailbox.id, messageId);
    if (!current) throw new MailboxError("message_not_found", 404);
    await this.prisma.$executeRawUnsafe(`UPDATE "EmailMessage" SET "folder"=?, "isRead"=?, "isStarred"=?, "updatedAt"=CURRENT_TIMESTAMP WHERE "id"=? AND "mailboxId"=?`, input.folder ?? current.folder, input.isRead ?? Boolean(current.isRead), input.isStarred ?? Boolean(current.isStarred), messageId, mailbox.id);
    return this.messageById(mailbox.id, messageId);
  }

  async blockSender(userId: string, sender: string) {
    const mailbox = await this.requireMailbox(userId);
    const normalized = normalizeEmail(sender);
    if (!normalized) throw new MailboxError("invalid_sender");
    const hash = hmacLookupIfEnabled(normalized, `email-block:${mailbox.id}`) || createHmac("sha256", mailbox.id).update(normalized).digest("hex");
    await this.prisma.$executeRawUnsafe(`INSERT OR IGNORE INTO "EmailBlockedSender" ("id","mailboxId","senderHash","senderEncrypted") VALUES (?,?,?,?)`, randomUUID(), mailbox.id, hash, encryptIfEnabled(normalized, `email-block:${mailbox.id}:sender`));
    const inbound = await this.prisma.$queryRawUnsafe<MessageRow[]>(`SELECT * FROM "EmailMessage" WHERE "mailboxId"=? AND "direction"='inbound'`, mailbox.id);
    for (const message of inbound) {
      const from = JSON.parse(decryptIfEncrypted(message.fromJson, `email-message:${message.id}:from`) || "[]") as string[];
      if (from.some((value) => normalizeEmail(value) === normalized)) {
        await this.prisma.$executeRawUnsafe(`UPDATE "EmailMessage" SET "folder"='spam', "updatedAt"=CURRENT_TIMESTAMP WHERE "id"=? AND "mailboxId"=?`, message.id, mailbox.id);
      }
    }
    return { blocked: true, sender: normalized };
  }

  async labels(userId: string) {
    const mailbox = await this.requireMailbox(userId);
    return this.prisma.$queryRawUnsafe<Array<{ id: string; name: string; color: string }>>(`SELECT "id","name","color" FROM "EmailLabel" WHERE "mailboxId"=? ORDER BY "name" ASC`, mailbox.id);
  }

  async createLabel(userId: string, name: string, color: string) {
    const mailbox = await this.requireMailbox(userId);
    const cleanName = sanitizeEmailText(name).replace(/\s+/g, " ").slice(0, 40);
    if (!cleanName) throw new MailboxError("label_name_required");
    const id = randomUUID();
    try { await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailLabel" ("id","mailboxId","name","color") VALUES (?,?,?,?)`, id, mailbox.id, cleanName, color.slice(0, 20)); }
    catch (error) { if (String(error).toLowerCase().includes("unique")) throw new MailboxError("label_exists", 409); throw error; }
    return { id, name: cleanName, color: color.slice(0, 20) };
  }

  async deleteLabel(userId: string, labelId: string) {
    const mailbox = await this.requireMailbox(userId);
    await this.prisma.$executeRawUnsafe(`DELETE FROM "EmailLabel" WHERE "id"=? AND "mailboxId"=?`, labelId, mailbox.id);
  }

  async setMessageLabels(userId: string, messageId: string, labelIds: string[]) {
    const mailbox = await this.requireMailbox(userId);
    if (!await this.messageRow(mailbox.id, messageId)) throw new MailboxError("message_not_found", 404);
    const valid = labelIds.length
      ? await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailLabel" WHERE "mailboxId"=? AND "id" IN (${labelIds.map(() => "?").join(",")})`, mailbox.id, ...labelIds)
      : [];
    if (valid.length !== new Set(labelIds).size) throw new MailboxError("invalid_label");
    await this.prisma.$executeRawUnsafe(`DELETE FROM "EmailMessageLabel" WHERE "messageId"=?`, messageId);
    for (const label of valid) await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailMessageLabel" ("messageId","labelId") VALUES (?,?)`, messageId, label.id);
    return this.messageById(mailbox.id, messageId);
  }

  async ingestMailgun(input: InboundMail, files: Express.Multer.File[]) {
    await this.ensureTables();
    this.verifyMailgun(input.timestamp, input.token, input.signature);
    this.validateAttachments(files.map((file) => ({ filename: file.originalname, contentType: file.mimetype, data: file.buffer })));
    const address = normalizeEmail(input.recipient);
    if (!address) throw new MailboxError("invalid_recipient");
    const mailboxes = await this.prisma.$queryRawUnsafe<MailboxRow[]>(`SELECT * FROM "EmailMailbox" WHERE "address"=? AND "status"='active' LIMIT 1`, address);
    const mailbox = mailboxes[0];
    if (!mailbox) throw new MailboxError("unknown_recipient", 406);
    const providerId = input.messageId || `mailgun:${input.token}`;
    const duplicate = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailMessage" WHERE "providerMessageId"=? LIMIT 1`, providerId);
    if (duplicate.length) return { accepted: true, duplicate: true, messageId: duplicate[0].id };
    await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailWebhookReceipt" ("token","provider") VALUES (?,'mailgun')`, input.token);

    const sender = normalizeEmail(input.sender) || input.sender.trim().toLowerCase();
    const senderHash = hmacLookupIfEnabled(sender, `email-block:${mailbox.id}`) || createHmac("sha256", mailbox.id).update(sender).digest("hex");
    const blocked = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailBlockedSender" WHERE "mailboxId"=? AND "senderHash"=? LIMIT 1`, mailbox.id, senderHash);
    const spam = input.spam === true || (input.spamScore ?? 0) >= Number(process.env.ONEWAY_EMAIL_SPAM_SCORE_THRESHOLD || 5);
    const messageId = randomUUID();
    const threadId = input.threadId || await this.resolveInboundThread(mailbox.id, input.headers) || randomUUID();
    await this.ensureThread(mailbox.id, threadId, input.subject || "");
    const data: MailInput = { to: [address], cc: input.cc, bcc: [], subject: input.subject, bodyText: input.bodyText, bodyHtml: input.bodyHtml };
    const fields = this.protectedFields(messageId, sender, data);
    const folder: MailFolder = blocked.length || spam ? "spam" : "inbox";
    await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailMessage" ("id","threadId","mailboxId","providerMessageId","direction","folder","fromJson","toJson","ccJson","bccJson","subject","bodyText","bodyHtml","status","isRead","spamScore","headersJson","receivedAt") VALUES (?,?,?,?,'inbound',?,?,?,?,?,?,?,?,'received',false,?,?,CURRENT_TIMESTAMP)`, messageId, threadId, mailbox.id, providerId, folder, fields.from, fields.to, fields.cc, fields.bcc, fields.subject, fields.text, fields.html, input.spamScore ?? null, encryptIfEnabled(JSON.stringify(input.headers || {}), `email-message:${messageId}:headers`));
    await this.storeAttachments(messageId, files.map((file) => ({ filename: file.originalname, contentType: file.mimetype, data: file.buffer })));
    await this.touchThread(threadId);
    if (folder === "inbox") {
      await this.alerts?.sendNewMail({ userId: mailbox.userId, threadId, messageId, sender, subject: input.subject || "New email" });
    }
    return { accepted: true, duplicate: false, messageId, mailboxUserId: mailbox.userId, folder };
  }

  async ingestMailgunEvent(input: MailgunEvent) {
    await this.ensureTables();
    this.verifyMailgun(input.timestamp, input.token, input.signature);
    const seen = await this.prisma.$queryRawUnsafe<Array<{ token: string }>>(`SELECT "token" FROM "EmailWebhookReceipt" WHERE "token"=? LIMIT 1`, input.token);
    if (seen.length) return { accepted: true, duplicate: true };
    await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailWebhookReceipt" ("token","provider") VALUES (?,'mailgun')`, input.token);
    const messageRows = input.oneWayMessageId
      ? await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailMessage" WHERE "id"=? LIMIT 1`, input.oneWayMessageId)
      : await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(`SELECT "id" FROM "EmailMessage" WHERE "providerMessageId"=? LIMIT 1`, input.providerMessageId || "");
    const messageId = messageRows[0]?.id || null;
    const status = deliveryStatus(input.eventType);
    if (messageId && status) await this.prisma.$executeRawUnsafe(`UPDATE "EmailMessage" SET "status"=?, "updatedAt"=CURRENT_TIMESTAMP WHERE "id"=?`, status, messageId);
    const recipient = normalizeEmail(input.recipient || "");
    const recipientHash = recipient ? (hmacLookupIfEnabled(recipient, "email-suppression:recipient") || createHmac("sha256", MAILBOX_DOMAIN()).update(recipient).digest("hex")) : null;
    await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailDeliveryEvent" ("id","messageId","provider","eventType","recipientHash","detailsEncrypted") VALUES (?,?, 'mailgun', ?, ?, ?)`, input.eventId || randomUUID(), messageId, input.eventType, recipientHash, encryptIfEnabled(JSON.stringify(input.safeDetails || {}), `email-delivery:${input.eventId}:details`));
    if (recipient && recipientHash && ["permanent_fail", "complained", "rejected"].includes(input.eventType)) {
      await this.prisma.$executeRawUnsafe(`INSERT OR IGNORE INTO "EmailSuppressionEntry" ("id","recipientHash","recipientEncrypted","reason","provider") VALUES (?,?,?,?, 'mailgun')`, randomUUID(), recipientHash, encryptIfEnabled(recipient, `email-suppression:${recipientHash}:recipient`), input.eventType);
    }
    return { accepted: true, duplicate: false, messageId, status };
  }

  async attachment(userId: string, attachmentId: string) {
    const mailbox = await this.requireMailbox(userId);
    const rows = await this.prisma.$queryRawUnsafe<AttachmentRow[]>(`SELECT a.* FROM "EmailAttachment" a JOIN "EmailMessage" m ON m."id"=a."messageId" WHERE a."id"=? AND m."mailboxId"=? LIMIT 1`, attachmentId, mailbox.id);
    const row = rows[0];
    if (!row) throw new MailboxError("attachment_not_found", 404);
    const object = await this.storage.read(row.storageKey);
    if (!object) throw new MailboxError("attachment_not_found", 404);
    return { ...object, filename: decryptIfEncrypted(row.filename, `email-attachment:${row.id}:filename`) };
  }

  private async mailboxForUser(userId: string) {
    return (await this.prisma.$queryRawUnsafe<MailboxRow[]>(`SELECT * FROM "EmailMailbox" WHERE "userId"=? LIMIT 1`, userId))[0] || null;
  }
  private async requireMailbox(userId: string) {
    await this.ensureTables();
    const row = await this.mailboxForUser(userId);
    if (!row) throw new MailboxError("mailbox_not_claimed", 404);
    return row;
  }
  private publicMailbox(row: MailboxRow) { return { id: row.id, address: row.address, status: row.status, createdAt: iso(row.createdAt), readiness: this.readiness() }; }
  private validateAddress(raw: string) {
    const candidate = raw.includes("@") ? raw.toLowerCase() : `${raw.toLowerCase()}@${MAILBOX_DOMAIN()}`;
    const [local, domain, extra] = candidate.split("@");
    if (extra || domain !== MAILBOX_DOMAIN() || local.length < 3 || local.length > 30 || !ADDRESS_LOCAL_RE.test(local || "") || /[._-]{2}/.test(local) || RESERVED.has(local) || DISALLOWED.some((word) => local.includes(word))) throw new MailboxError("invalid_or_reserved_address");
    return candidate;
  }
  private validateRecipients(input: MailInput, required: boolean) {
    if (required && !input.to?.length) throw new MailboxError("recipient_required");
    const recipients = [...(input.to || []), ...(input.cc || []), ...(input.bcc || [])];
    if (recipients.length > 50 || recipients.some((value) => !normalizeEmail(value))) throw new MailboxError("invalid_recipient");
    if ((input.subject || "").length > 998 || input.bodyText.length > 1_000_000 || (input.bodyHtml || "").length > 2_000_000) throw new MailboxError("message_too_large", 413);
  }
  private verificationRecipients(): Set<string> {
    return new Set(
      (process.env.ONEWAY_EMAIL_VERIFICATION_RECIPIENTS || "")
        .split(",")
        .map((value) => normalizeEmail(value))
        .filter((value): value is string => Boolean(value)),
    );
  }
  private verificationModeReady(): boolean {
    return process.env.ONEWAY_EMAIL_VERIFICATION_MODE === "true"
      && this.provider.name === "mailgun"
      && Boolean(process.env.MAILGUN_API_KEY?.trim())
      && Boolean(process.env.MAILGUN_WEBHOOK_SIGNING_KEY?.trim())
      && Boolean(process.env.ONEWAY_EMAIL_DOMAIN?.trim())
      && process.env.FIELD_ENCRYPTION_ENABLED === "true"
      && Boolean(process.env.FIELD_HASH_KEY_BASE64?.trim())
      && process.env.ONEWAY_EMAIL_DNS_VERIFIED === "true"
      && this.verificationRecipients().size > 0;
  }
  private protectedFields(id: string, from: string, input: MailInput) {
    const protect = (field: string, value: string) => encryptIfEnabled(value, `email-message:${id}:${field}`);
    return {
      from: protect("from", JSON.stringify([from])), to: protect("to", JSON.stringify(input.to.map((x) => normalizeEmail(x) || x))),
      cc: protect("cc", JSON.stringify((input.cc || []).map((x) => normalizeEmail(x) || x))), bcc: protect("bcc", JSON.stringify((input.bcc || []).map((x) => normalizeEmail(x) || x))),
      subject: protect("subject", sanitizeEmailText(input.subject || "")), text: protect("bodyText", sanitizeEmailText(input.bodyText)),
      html: input.bodyHtml ? protect("bodyHtml", sanitizeEmailHtml(input.bodyHtml)) : null,
    };
  }
  private async ensureThread(mailboxId: string, id: string, subject: string) {
    const protectedSubject = encryptIfEnabled(sanitizeEmailText(subject).slice(0, 300), `email-thread:${id}:subject`);
    await this.prisma.$executeRawUnsafe(`INSERT OR IGNORE INTO "EmailThread" ("id","mailboxId","subjectPreview") VALUES (?,?,?)`, id, mailboxId, protectedSubject);
  }
  private async touchThread(id: string) { await this.prisma.$executeRawUnsafe(`UPDATE "EmailThread" SET "lastMessageAt"=CURRENT_TIMESTAMP,"updatedAt"=CURRENT_TIMESTAMP WHERE "id"=?`, id); }
  private async storeAttachments(messageId: string, attachments: Array<{ filename: string; contentType: string; data: Buffer }>) {
    for (const item of attachments) {
      const id = randomUUID();
      const key = `email/${messageId}/${id}`;
      await this.storage.put(key, item.data, item.contentType || "application/octet-stream");
      await this.prisma.$executeRawUnsafe(`INSERT INTO "EmailAttachment" ("id","messageId","filename","contentType","storageKey","bytes") VALUES (?,?,?,?,?,?)`, id, messageId, encryptIfEnabled(item.filename.slice(0, 255), `email-attachment:${id}:filename`), item.contentType || "application/octet-stream", key, item.data.length);
    }
  }
  private async messageRow(mailboxId: string, id: string) { return (await this.prisma.$queryRawUnsafe<MessageRow[]>(`SELECT * FROM "EmailMessage" WHERE "id"=? AND "mailboxId"=? LIMIT 1`, id, mailboxId))[0] || null; }
  private async resolveInboundThread(mailboxId: string, headers?: Record<string, string>): Promise<string | null> {
    const ids = [headers?.["in-reply-to"], ...(headers?.references || "").split(/\s+/)].map((value) => value?.trim()).filter((value): value is string => Boolean(value));
    for (const id of ids) {
      const rows = await this.prisma.$queryRawUnsafe<Array<{ threadId: string }>>(`SELECT "threadId" FROM "EmailMessage" WHERE "mailboxId"=? AND "providerMessageId"=? LIMIT 1`, mailboxId, id);
      if (rows[0]) return rows[0].threadId;
    }
    return null;
  }
  private suppressionHash(recipient: string): string {
    return hmacLookupIfEnabled(recipient, "email-suppression:recipient") || createHmac("sha256", MAILBOX_DOMAIN()).update(recipient).digest("hex");
  }
  private validateAttachments(attachments: Array<{ filename: string; contentType: string; data: Buffer }>): void {
    if (!attachments.length) return;
    if (process.env.ONEWAY_EMAIL_MALWARE_SCANNER_ENABLED !== "true") throw new MailboxError("attachment_scanner_unavailable", 503);
    const forbidden = /\.(?:app|bat|cmd|com|cpl|dll|dmg|exe|hta|iso|jar|js|jse|msi|ps1|scr|vbs|vbe|wsf)$/i;
    const allowed = /^(?:image\/(?:jpeg|png|gif|webp|heic)|text\/(?:plain|csv)|application\/(?:pdf|json|zip|msword|vnd\.openxmlformats-officedocument\.[a-z.]+|vnd\.ms-(?:excel|powerpoint)))$/i;
    for (const attachment of attachments) {
      if (!attachment.data.length || forbidden.test(attachment.filename) || !allowed.test(attachment.contentType)) throw new MailboxError("unsafe_attachment_type", 415);
    }
  }
  private async messageById(mailboxId: string, id: string) { const row = await this.messageRow(mailboxId, id); if (!row) throw new MailboxError("message_not_found", 404); return this.publicMessage(row, true); }
  private async publicMessage(row: MessageRow, includeBody: boolean) {
    const reveal = (field: string, value: string | null) => value == null ? "" : decryptIfEncrypted(value, `email-message:${row.id}:${field}`);
    const attachments = await this.prisma.$queryRawUnsafe<AttachmentRow[]>(`SELECT * FROM "EmailAttachment" WHERE "messageId"=? ORDER BY "createdAt" ASC`, row.id);
    const labels = await this.prisma.$queryRawUnsafe<Array<{ id: string; name: string; color: string }>>(`SELECT l."id",l."name",l."color" FROM "EmailLabel" l JOIN "EmailMessageLabel" ml ON ml."labelId"=l."id" WHERE ml."messageId"=? ORDER BY l."name"`, row.id);
    return {
      id: row.id, threadId: row.threadId, providerMessageId: row.providerMessageId, direction: row.direction, folder: row.folder,
      from: JSON.parse(reveal("from", row.fromJson) || "[]"), to: JSON.parse(reveal("to", row.toJson) || "[]"), cc: JSON.parse(reveal("cc", row.ccJson) || "[]"),
      subject: reveal("subject", row.subject), bodyText: includeBody ? reveal("bodyText", row.bodyText) : "", bodyHtml: includeBody ? reveal("bodyHtml", row.bodyHtml) || null : null,
      status: row.status, isRead: Boolean(row.isRead), isStarred: Boolean(row.isStarred), spamScore: row.spamScore,
      sentAt: isoOrNull(row.sentAt), receivedAt: isoOrNull(row.receivedAt), createdAt: iso(row.createdAt), updatedAt: iso(row.updatedAt),
      attachments: attachments.map((a) => ({ id: a.id, filename: decryptIfEncrypted(a.filename, `email-attachment:${a.id}:filename`), contentType: a.contentType, bytes: a.bytes })),
      labels,
    };
  }
  private verifyMailgun(timestamp: string, token: string, signature: string) {
    const key = process.env.MAILGUN_WEBHOOK_SIGNING_KEY?.trim() || "";
    if (!key || !timestamp || !token || !signature) throw new MailboxError("webhook_unauthorized", 401);
    if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) throw new MailboxError("webhook_expired", 401);
    const expected = createHmac("sha256", key).update(timestamp + token).digest("hex");
    if (expected.length !== signature.length || !timingSafeEqual(Buffer.from(expected), Buffer.from(signature))) throw new MailboxError("webhook_unauthorized", 401);
  }
}

export type MailInput = {
  to: string[]; cc?: string[]; bcc?: string[]; subject?: string; bodyText: string; bodyHtml?: string;
  attachments?: Array<{ filename: string; contentType: string; data: Buffer }>;
};
export type InboundMail = {
  timestamp: string; token: string; signature: string; recipient: string; sender: string; subject?: string; bodyText: string;
  bodyHtml?: string; cc?: string[]; messageId?: string; threadId?: string; spam?: boolean; spamScore?: number; headers?: Record<string, string>;
};
export type MailgunEvent = {
  timestamp: string; token: string; signature: string; eventId: string; eventType: string; recipient?: string;
  providerMessageId?: string; oneWayMessageId?: string; safeDetails?: Record<string, unknown>;
};
function deliveryStatus(event: string): string | null {
  switch (event) {
    case "accepted": return "queued";
    case "delivered": return "delivered";
    case "temporary_fail": return "deferred";
    case "permanent_fail": case "rejected": return "bounced";
    case "complained": return "complained";
    default: return null;
  }
}
function iso(value: string | Date) { return new Date(value).toISOString(); }
function isoOrNull(value: string | Date | null) { return value ? iso(value) : null; }
