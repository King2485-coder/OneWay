import type { PrismaClient, StoreEmailMessage } from "@prisma/client";
import { randomUUID } from "node:crypto";
import { decryptIfEncrypted, encryptIfEnabled } from "./privacy/EncryptionService";

export type StoreEmailDirection = "outbound" | "inbound";
export type StoreEmailStatus = "queued" | "sent" | "failed" | "stubbed" | "received";
export type StoreReplyKind = "orders" | "inquiries";

export type StoreEmailMessageDTO = {
  id: string;
  domain: string;
  orderRequestId: string | null;
  inquiryId: string | null;
  direction: StoreEmailDirection | string;
  fromEmail: string;
  toEmail: string;
  subject: string;
  bodyText: string;
  provider: string;
  providerMessageId: string | null;
  status: StoreEmailStatus | string;
  createdAt: string;
};

export async function ensureStoreEmailMessageTable(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "StoreEmailMessage" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "domain" TEXT NOT NULL,
      "orderRequestId" TEXT,
      "inquiryId" TEXT,
      "direction" TEXT NOT NULL,
      "fromEmail" TEXT NOT NULL,
      "toEmail" TEXT NOT NULL,
      "subject" TEXT NOT NULL DEFAULT '',
      "bodyText" TEXT NOT NULL,
      "bodyHtml" TEXT,
      "provider" TEXT NOT NULL,
      "providerMessageId" TEXT,
      "status" TEXT NOT NULL,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "StoreEmailMessage_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreEmailMessage_userId_domain_createdAt_idx" ON "StoreEmailMessage"("userId", "domain", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreEmailMessage_orderRequestId_createdAt_idx" ON "StoreEmailMessage"("orderRequestId", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreEmailMessage_inquiryId_createdAt_idx" ON "StoreEmailMessage"("inquiryId", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreEmailMessage_providerMessageId_idx" ON "StoreEmailMessage"("providerMessageId")`);
}

export async function createStoreEmailMessage(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  orderRequestId?: string | null;
  inquiryId?: string | null;
  direction: StoreEmailDirection;
  fromEmail: string;
  toEmail: string;
  subject?: string;
  bodyText: string;
  bodyHtml?: string | null;
  provider: string;
  providerMessageId?: string | null;
  status: StoreEmailStatus | string;
}): Promise<StoreEmailMessageDTO> {
  await ensureStoreEmailMessageTable(prisma);
  const created = await prisma.storeEmailMessage.create({
    data: {
      userId: input.userId,
      domain: input.domain,
      orderRequestId: input.orderRequestId ?? null,
      inquiryId: input.inquiryId ?? null,
      direction: input.direction,
      fromEmail: encryptEmailField(input.domain, "fromEmail", normalizeEmail(input.fromEmail) || input.fromEmail.trim()),
      toEmail: encryptEmailField(input.domain, "toEmail", normalizeEmail(input.toEmail) || input.toEmail.trim()),
      subject: encryptEmailField(input.domain, "subject", sanitizeEmailText(input.subject ?? "").slice(0, 500)),
      bodyText: encryptEmailField(input.domain, "bodyText", sanitizeEmailText(input.bodyText).slice(0, 20_000)),
      bodyHtml: input.bodyHtml ? encryptEmailField(input.domain, "bodyHtml", sanitizeEmailHtml(input.bodyHtml).slice(0, 50_000)) : null,
      provider: input.provider,
      providerMessageId: input.providerMessageId ?? null,
      status: input.status,
    },
  });
  return toStoreEmailMessageDTO(created);
}

export async function listStoreEmailMessages(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  orderRequestId?: string | null;
  inquiryId?: string | null;
}): Promise<StoreEmailMessageDTO[]> {
  await ensureStoreEmailMessageTable(prisma);
  const filters = [
    input.orderRequestId ? { orderRequestId: input.orderRequestId } : null,
    input.inquiryId ? { inquiryId: input.inquiryId } : null,
  ].filter(Boolean) as Array<{ orderRequestId: string } | { inquiryId: string }>;

  if (filters.length === 0) return [];

  const messages = await prisma.storeEmailMessage.findMany({
    where: {
      userId: input.userId,
      domain: input.domain,
      OR: filters,
    },
    orderBy: { createdAt: "asc" },
    take: 100,
  });
  return messages.map(toStoreEmailMessageDTO);
}

export function toStoreEmailMessageDTO(message: StoreEmailMessage): StoreEmailMessageDTO {
  return {
    id: message.id,
    domain: message.domain,
    orderRequestId: message.orderRequestId ?? null,
    inquiryId: message.inquiryId ?? null,
    direction: message.direction,
    fromEmail: decryptEmailField(message.domain, "fromEmail", message.fromEmail),
    toEmail: decryptEmailField(message.domain, "toEmail", message.toEmail),
    subject: decryptEmailField(message.domain, "subject", message.subject),
    bodyText: decryptEmailField(message.domain, "bodyText", message.bodyText),
    provider: message.provider,
    providerMessageId: message.providerMessageId ?? null,
    status: message.status,
    createdAt: message.createdAt.toISOString(),
  };
}

export function buildStoreReplyAddress(kind: StoreReplyKind, id: string): string {
  const replyDomain = process.env.EMAIL_REPLY_DOMAIN?.trim()
    || process.env.ONEWAY_EMAIL_REPLY_DOMAIN?.trim()
    || process.env.EMAIL_REPLY_TO?.split("@")[1]?.trim()
    || "oneway.app";
  const token = `${kind}+${id}`;
  const template = process.env.EMAIL_REPLY_TO?.trim() || "";
  if (template.includes("{token}")) {
    return template.replaceAll("{token}", token);
  }
  return `${token}@${replyDomain}`;
}

export function extractStoreReplyTarget(values: Array<string | undefined | null>): { kind: StoreReplyKind; id: string } | null {
  const joined = values.filter(Boolean).join(" ");
  const match = joined.match(/\b(orders|inquiries)\+([A-Za-z0-9_-]+)@/i);
  if (!match) return null;
  return {
    kind: match[1].toLowerCase() as StoreReplyKind,
    id: match[2],
  };
}

export function normalizeEmail(value: string | null | undefined): string | null {
  const trimmed = String(value ?? "").trim().toLowerCase();
  if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(trimmed)) return null;
  return trimmed;
}

export function sanitizeEmailText(value: string): string {
  return String(value ?? "")
    .replace(/\u0000/g, "")
    .replace(/\r\n/g, "\n")
    .trim();
}

export function sanitizeEmailHtml(value: string): string {
  return String(value ?? "")
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "")
    .replace(/\son\w+="[^"]*"/gi, "")
    .replace(/\son\w+='[^']*'/gi, "")
    .replace(/\sjavascript:/gi, "");
}

export function fallbackProviderMessageId(prefix: string): string {
  return `${prefix}_${randomUUID()}`;
}

function emailEncryptionContext(domain: string, field: string): string {
  return `store-email:${domain}:${field}`;
}

function encryptEmailField(domain: string, field: string, value: string): string {
  return encryptIfEnabled(value, emailEncryptionContext(domain, field));
}

function decryptEmailField(domain: string, field: string, value: string): string {
  return decryptIfEncrypted(value, emailEncryptionContext(domain, field));
}
