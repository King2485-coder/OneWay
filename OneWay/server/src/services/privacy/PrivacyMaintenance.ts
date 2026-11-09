import type { PrismaClient } from "@prisma/client";
import {
  decryptIfEncrypted,
  encryptIfEnabled,
  getEncryptedPayloadKid,
  getEncryptionStatus,
  isEncryptedPayload,
  isFieldEncryptionEnabled,
  reencryptPayload,
} from "./EncryptionService";
import { backfillExternalConversationPrivacy } from "./ConversationPrivacy";

export type PrivacyMaintenanceOptions = {
  limit?: number;
  dryRun?: boolean;
  targetKid?: string;
};

export type PrivacyMaintenanceResult = {
  command: string;
  skipped?: boolean;
  reason?: string;
  scanned: number;
  updated: number;
  dryRun: boolean;
  targetKid: string;
  sections: Record<string, { scanned: number; updated: number }>;
};

const inquiryFields = ["customerName", "customerEmail", "customerPhone", "productPaymentLinkUrl", "message", "ownerReply", "orderRequestNote"] as const;
const orderFields = ["customerName", "customerEmail", "customerPhone", "paymentLinkUrl", "message", "note", "sellerReply", "walletPaymentId", "buyerWalletUserId", "sellerWalletUserId"] as const;
const notificationFields = ["body"] as const;
const emailFields = ["fromEmail", "toEmail", "subject", "bodyText", "bodyHtml"] as const;

export async function runPrivacyMaintenance(
  prisma: PrismaClient,
  command: "backfill-storefront-sensitive-fields" | "backfill-external-conversations" | "rotate-encrypted-fields" | "dry-run",
  options: PrivacyMaintenanceOptions = {},
): Promise<PrivacyMaintenanceResult> {
  const status = getEncryptionStatus();
  const targetKid = options.targetKid || status.currentKeyId;
  const dryRun = Boolean(options.dryRun || command === "dry-run");

  if (!isFieldEncryptionEnabled()) {
    return { command, skipped: true, reason: "field_encryption_not_enabled", scanned: 0, updated: 0, dryRun, targetKid, sections: {} };
  }

  const sections: Record<string, { scanned: number; updated: number }> = {};

  if (command === "backfill-storefront-sensitive-fields" || command === "rotate-encrypted-fields" || command === "dry-run") {
    sections.storefrontInquiries = await processModelFields(prisma.storeInquiry, inquiryFields, (row) => `store:${row.domain}:inquiry`, options.limit, dryRun, command === "rotate-encrypted-fields" ? targetKid : undefined);
    sections.storefrontOrders = await processModelFields(prisma.storeOrderRequest, orderFields, (row) => `store:${row.domain}:order`, options.limit, dryRun, command === "rotate-encrypted-fields" ? targetKid : undefined);
    sections.storeNotifications = await processModelFields(prisma.storeNotification, notificationFields, (row) => `store:${row.domain}:notification`, options.limit, dryRun, command === "rotate-encrypted-fields" ? targetKid : undefined);
    sections.storeEmailMessages = await processModelFields(prisma.storeEmailMessage, emailFields, (row) => `store-email:${row.domain}`, options.limit, dryRun, command === "rotate-encrypted-fields" ? targetKid : undefined);
    sections.oneWayMessages = await processMessagePayloads(prisma, options.limit, dryRun, command === "rotate-encrypted-fields" ? targetKid : undefined);
  }

  if (command === "backfill-external-conversations" || command === "rotate-encrypted-fields" || command === "dry-run") {
    const external = await backfillExternalConversationPrivacy(prisma, { limit: options.limit, dryRun, targetKid });
    sections.externalConversations = { scanned: external.scanned, updated: external.updated };
  }

  return summarize(command, dryRun, targetKid, sections);
}

async function processModelFields(
  model: { findMany: Function; update: Function },
  fields: readonly string[],
  contextPrefix: (row: Record<string, any>) => string,
  limit: number | undefined,
  dryRun: boolean,
  rotateToKid: string | undefined,
): Promise<{ scanned: number; updated: number }> {
  const rows = await model.findMany({
    take: limit && limit > 0 ? limit : undefined,
    select: { id: true, domain: true, ...Object.fromEntries(fields.map((field) => [field, true])) },
  });

  let updated = 0;
  for (const row of rows as Array<Record<string, any>>) {
    const data: Record<string, string | null> = {};
    for (const field of fields) {
      const nextValue = protectValue(row[field], `${contextPrefix(row)}:${field}`, rotateToKid);
      if (nextValue !== row[field]) data[field] = nextValue;
    }
    if (Object.keys(data).length === 0) continue;
    updated += 1;
    if (!dryRun) await model.update({ where: { id: row.id }, data });
  }
  return { scanned: rows.length, updated };
}

async function processMessagePayloads(
  prisma: PrismaClient,
  limit: number | undefined,
  dryRun: boolean,
  rotateToKid: string | undefined,
): Promise<{ scanned: number; updated: number }> {
  const messages = await prisma.message.findMany({
    take: limit && limit > 0 ? limit : undefined,
    select: { id: true, conversationId: true, ciphertext: true },
  });

  let updated = 0;
  for (const message of messages) {
    const next = protectMessagePayload(message.ciphertext, message.conversationId, rotateToKid);
    if (next === message.ciphertext) continue;
    updated += 1;
    if (!dryRun) await prisma.message.update({ where: { id: message.id }, data: { ciphertext: next } });
  }
  return { scanned: messages.length, updated };
}

function protectMessagePayload(ciphertext: string, conversationId: string, rotateToKid: string | undefined): string {
  try {
    const parsed = JSON.parse(ciphertext) as Record<string, any>;
    const next = { ...parsed };
    next.body = protectValue(next.body, `message:${conversationId}:body`, rotateToKid);
    if (next.attachment) {
      next.attachment = {
        ...next.attachment,
        fileName: protectValue(next.attachment.fileName, `message:${conversationId}:attachment.fileName`, rotateToKid),
        payloadBase64: protectValue(next.attachment.payloadBase64, `message:${conversationId}:attachment.payloadBase64`, rotateToKid),
      };
    }
    if (next.external) {
      next.external = {
        ...next.external,
        phoneNumber: protectValue(next.external.phoneNumber, `message:${conversationId}:external.phoneNumber`, rotateToKid),
        email: protectValue(next.external.email, `message:${conversationId}:external.email`, rotateToKid),
      };
    }
    const encoded = JSON.stringify(next);
    return encoded === ciphertext ? ciphertext : encoded;
  } catch {
    return JSON.stringify({
      body: protectValue(ciphertext, `message:${conversationId}:body`, rotateToKid),
    });
  }
}

function protectValue(value: unknown, context: string, rotateToKid: string | undefined): string | null {
  if (value == null) return null;
  const normalized = String(value);
  if (!normalized) return normalized;
  if (rotateToKid && isEncryptedPayload(normalized)) {
    return getEncryptedPayloadKid(normalized) === rotateToKid ? normalized : reencryptPayload(normalized, rotateToKid, context);
  }
  if (rotateToKid && !isEncryptedPayload(normalized)) return reencryptPayload(normalized, rotateToKid, context);
  return isEncryptedPayload(normalized) ? normalized : encryptIfEnabled(decryptIfEncrypted(normalized, context), context);
}

function summarize(command: string, dryRun: boolean, targetKid: string, sections: Record<string, { scanned: number; updated: number }>): PrivacyMaintenanceResult {
  return {
    command,
    scanned: Object.values(sections).reduce((sum, section) => sum + section.scanned, 0),
    updated: Object.values(sections).reduce((sum, section) => sum + section.updated, 0),
    dryRun,
    targetKid,
    sections,
  };
}
