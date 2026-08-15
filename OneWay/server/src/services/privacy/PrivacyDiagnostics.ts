import type { PrismaClient } from "@prisma/client";
import { getEncryptionStatus, getEncryptedPayloadKid, isEncryptedPayload } from "./EncryptionService";
import { readPrivacyMaintenanceState } from "./PrivacyMaintenanceState";

type FieldCounts = {
  recordsScanned: number;
  encryptedValues: number;
  plaintextLegacyValues: number;
  encryptedByKid: Record<string, number>;
};

type ExternalConversationCounts = {
  recordsScanned: number;
  protected: number;
  plaintextLegacy: number;
  missingHash: number;
  missingCiphertext: number;
  encryptedByKid: Record<string, number>;
};

export type PrivacyStatus = {
  ok: true;
  encryption: {
    enabled: boolean;
    requested: boolean;
    currentKeyId: string;
    availableKeyCount: number;
    hashKeyConfigured: boolean;
    hashKeyRequired: boolean;
    invalidKeyCount: number;
    legacyMasterKeyConfigured: boolean;
  };
  sensitiveData: {
    storefrontInquiries: FieldCounts;
    storefrontOrders: FieldCounts;
    storeNotifications: FieldCounts;
    storeEmailMessages: FieldCounts;
    oneWayMessages: FieldCounts;
    externalConversations: ExternalConversationCounts;
  };
  lastPrivacyMaintenanceRun: Awaited<ReturnType<typeof readPrivacyMaintenanceState>>["lastRun"];
};

const inquiryFields = ["customerName", "customerEmail", "customerPhone", "productPaymentLinkUrl", "message", "ownerReply", "orderRequestNote"] as const;
const orderFields = ["customerName", "customerEmail", "customerPhone", "paymentLinkUrl", "message", "note", "sellerReply", "walletPaymentId", "buyerWalletUserId", "sellerWalletUserId"] as const;
const notificationFields = ["body"] as const;
const emailFields = ["fromEmail", "toEmail", "subject", "bodyText", "bodyHtml"] as const;

export async function buildPrivacyStatus(prisma: PrismaClient): Promise<PrivacyStatus> {
  const encryption = getEncryptionStatus();
  const [
    storefrontInquiries,
    storefrontOrders,
    storeNotifications,
    storeEmailMessages,
    oneWayMessages,
    externalConversations,
    state,
  ] = await Promise.all([
    countModelFields(prisma.storeInquiry.findMany({ select: selectFields(inquiryFields) as any }) as unknown as Promise<Array<Record<string, string | null | undefined>>>, inquiryFields),
    countModelFields(prisma.storeOrderRequest.findMany({ select: selectFields(orderFields) as any }) as unknown as Promise<Array<Record<string, string | null | undefined>>>, orderFields),
    countModelFields(prisma.storeNotification.findMany({ select: selectFields(notificationFields) as any }) as unknown as Promise<Array<Record<string, string | null | undefined>>>, notificationFields),
    countModelFields(prisma.storeEmailMessage.findMany({ select: selectFields(emailFields) as any }) as unknown as Promise<Array<Record<string, string | null | undefined>>>, emailFields),
    countMessagePayloads(prisma),
    countExternalConversations(prisma),
    readPrivacyMaintenanceState(),
  ]);

  return {
    ok: true,
    encryption: {
      enabled: encryption.enabled,
      requested: encryption.requested,
      currentKeyId: encryption.currentKeyId,
      availableKeyCount: encryption.availableKeyCount,
      hashKeyConfigured: encryption.hashKeyConfigured,
      hashKeyRequired: encryption.hashKeyRequired,
      invalidKeyCount: encryption.invalidKeyIds.length,
      legacyMasterKeyConfigured: encryption.legacyMasterKeyConfigured,
    },
    sensitiveData: {
      storefrontInquiries,
      storefrontOrders,
      storeNotifications,
      storeEmailMessages,
      oneWayMessages,
      externalConversations,
    },
    lastPrivacyMaintenanceRun: state.lastRun,
  };
}

async function countModelFields(recordsPromise: Promise<Array<Record<string, string | null | undefined>>>, fields: readonly string[]): Promise<FieldCounts> {
  try {
    const records = await recordsPromise;
    const counts = emptyFieldCounts(records.length);
    for (const record of records) {
      for (const field of fields) countSensitiveValue(record[field], counts);
    }
    return counts;
  } catch {
    return emptyFieldCounts(0);
  }
}

async function countMessagePayloads(prisma: PrismaClient): Promise<FieldCounts> {
  try {
    const messages = await prisma.message.findMany({ select: { ciphertext: true } });
    const counts = emptyFieldCounts(messages.length);
    for (const message of messages) countMessageValue(message.ciphertext, counts);
    return counts;
  } catch {
    return emptyFieldCounts(0);
  }
}

async function countExternalConversations(prisma: PrismaClient): Promise<ExternalConversationCounts> {
  try {
    const conversations = await prisma.conversation.findMany({
      where: { type: { in: ["external_sms", "external_email"] } },
      select: { title: true, externalTargetHash: true, externalTargetCiphertext: true },
    });
    const encryptedByKid: Record<string, number> = {};
    let protectedCount = 0;
    let plaintextLegacy = 0;
    let missingHash = 0;
    let missingCiphertext = 0;
    for (const conversation of conversations) {
      const encrypted = isEncryptedPayload(conversation.externalTargetCiphertext);
      if (!conversation.externalTargetHash) missingHash += 1;
      if (!conversation.externalTargetCiphertext) missingCiphertext += 1;
      if (conversation.externalTargetHash && encrypted) {
        protectedCount += 1;
        addKidCount(encryptedByKid, getEncryptedPayloadKid(conversation.externalTargetCiphertext));
      } else if (conversation.title && conversation.title !== "External line") {
        plaintextLegacy += 1;
      }
    }
    return {
      recordsScanned: conversations.length,
      protected: protectedCount,
      plaintextLegacy,
      missingHash,
      missingCiphertext,
      encryptedByKid,
    };
  } catch {
    return {
      recordsScanned: 0,
      protected: 0,
      plaintextLegacy: 0,
      missingHash: 0,
      missingCiphertext: 0,
      encryptedByKid: {},
    };
  }
}

function countMessageValue(value: unknown, counts: FieldCounts): void {
  if (typeof value !== "string" || value.length === 0) return;
  if (isEncryptedPayload(value)) {
    counts.encryptedValues += 1;
    addKidCount(counts.encryptedByKid, getEncryptedPayloadKid(value));
    return;
  }
  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    countSensitiveValue(parsed.body, counts);
    const attachment = parsed.attachment as Record<string, unknown> | null | undefined;
    if (attachment) {
      countSensitiveValue(attachment.fileName, counts);
      countSensitiveValue(attachment.payloadBase64, counts);
    }
    const external = parsed.external as Record<string, unknown> | null | undefined;
    if (external) {
      countSensitiveValue(external.phoneNumber, counts);
      countSensitiveValue(external.email, counts);
    }
  } catch {
    counts.plaintextLegacyValues += 1;
  }
}

function countSensitiveValue(value: unknown, counts: FieldCounts): void {
  if (typeof value !== "string" || value.length === 0) return;
  if (isEncryptedPayload(value)) {
    counts.encryptedValues += 1;
    addKidCount(counts.encryptedByKid, getEncryptedPayloadKid(value));
  } else {
    counts.plaintextLegacyValues += 1;
  }
}

function emptyFieldCounts(recordsScanned: number): FieldCounts {
  return {
    recordsScanned,
    encryptedValues: 0,
    plaintextLegacyValues: 0,
    encryptedByKid: {},
  };
}

function selectFields(fields: readonly string[]): Record<string, true> {
  return Object.fromEntries(fields.map((field) => [field, true]));
}

function addKidCount(counts: Record<string, number>, kid: string | null): void {
  const key = kid || "unknown";
  counts[key] = (counts[key] ?? 0) + 1;
}
