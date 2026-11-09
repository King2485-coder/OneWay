import type { PrismaClient } from "@prisma/client";
import {
  decryptIfEncrypted,
  encryptIfEnabled,
  getEncryptedPayloadKid,
  getEncryptionStatus,
  hmacLookupIfEnabled,
  isEncryptedPayload,
  reencryptPayload,
} from "./EncryptionService";

let columnsReady = false;

export type ExternalConversationType = "external_sms" | "external_email";

export async function ensureExternalConversationPrivacyColumns(prisma: PrismaClient): Promise<void> {
  if (columnsReady) return;
  await addColumnIfMissing(prisma, "Conversation", `"externalTargetHash" TEXT`);
  await addColumnIfMissing(prisma, "Conversation", `"externalTargetCiphertext" TEXT`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Conversation_type_externalTargetHash_idx" ON "Conversation"("type", "externalTargetHash")`);
  columnsReady = true;
}

export function externalConversationTargetHash(type: ExternalConversationType, target: string): string | null {
  return hmacLookupIfEnabled(normalizeTargetForHash(type, target), externalConversationContext(type, "target"));
}

export function encryptExternalConversationTarget(type: ExternalConversationType, target: string): string | null {
  return encryptIfEnabled(normalizeTargetForHash(type, target), externalConversationContext(type, "target"));
}

export function decryptExternalConversationTarget(conversation: {
  type: string;
  title?: string | null;
  externalTargetCiphertext?: string | null;
}): string | null {
  if (conversation.type !== "external_sms" && conversation.type !== "external_email") return null;
  const type = conversation.type as ExternalConversationType;
  const encrypted = conversation.externalTargetCiphertext;
  if (encrypted) {
    return decryptIfEncrypted(encrypted, externalConversationContext(type, "target"));
  }
  return conversation.title ?? null;
}

export async function backfillExternalConversationPrivacy(
  prisma: PrismaClient,
  options: { limit?: number; dryRun?: boolean; targetKid?: string } = {},
): Promise<{ scanned: number; updated: number; dryRun: boolean; targetKid: string }> {
  await ensureExternalConversationPrivacyColumns(prisma);
  const targetKid = options.targetKid || getEncryptionStatus().currentKeyId;
  const conversations = await prisma.conversation.findMany({
    where: {
      type: { in: ["external_sms", "external_email"] },
    },
    take: options.limit && options.limit > 0 ? options.limit : undefined,
    select: {
      id: true,
      type: true,
      title: true,
      externalTargetHash: true,
      externalTargetCiphertext: true,
    },
  });

  let updated = 0;
  for (const conversation of conversations) {
    if (conversation.type !== "external_sms" && conversation.type !== "external_email") continue;
    const target = decryptExternalConversationTarget(conversation);
    if (!target) continue;
    const type = conversation.type as ExternalConversationType;
    const hash = externalConversationTargetHash(type, target);
    const ciphertext = encryptExternalConversationTarget(type, target);
    if (!hash || !ciphertext) continue;

    const existingKid = getEncryptedPayloadKid(conversation.externalTargetCiphertext);
    const alreadyProtected = conversation.externalTargetHash === hash
      && Boolean(conversation.externalTargetCiphertext)
      && isEncryptedPayload(conversation.externalTargetCiphertext)
      && existingKid === targetKid;
    if (alreadyProtected) continue;

    const nextCiphertext = conversation.externalTargetCiphertext && isEncryptedPayload(conversation.externalTargetCiphertext)
      ? reencryptPayload(conversation.externalTargetCiphertext, targetKid, externalConversationContext(type, "target"))
      : reencryptPayload(target, targetKid, externalConversationContext(type, "target"));

    if (!options.dryRun) await prisma.conversation.update({
      where: { id: conversation.id },
      data: {
        title: "External line",
        externalTargetHash: hash,
        externalTargetCiphertext: nextCiphertext,
      },
    });
    updated += 1;
  }

  return { scanned: conversations.length, updated, dryRun: Boolean(options.dryRun), targetKid };
}

function externalConversationContext(type: ExternalConversationType, field: string): string {
  return `conversation:${type}:${field}`;
}

function normalizeTargetForHash(type: ExternalConversationType, target: string): string {
  return type === "external_email" ? target.trim().toLowerCase() : target.trim();
}

async function addColumnIfMissing(prisma: PrismaClient, table: string, columnDefinition: string): Promise<void> {
  const columnName = columnDefinition.match(/^"([^"]+)"/)?.[1];
  if (columnName && String(process.env.DATABASE_URL ?? "").startsWith("file:")) {
    const columns = await prisma.$queryRawUnsafe<Array<{ name?: string }>>(`PRAGMA table_info("${table}")`);
    if (columns.some((column) => column.name === columnName)) return;
  }

  try {
    const ifNotExists = String(process.env.DATABASE_URL ?? "").startsWith("file:")
      ? ""
      : "IF NOT EXISTS ";
    await prisma.$executeRawUnsafe(`ALTER TABLE "${table}" ADD COLUMN ${ifNotExists}${columnDefinition}`);
  } catch (error) {
    const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
    if (!message.includes("duplicate column") && !message.includes("already exists")) {
      throw error;
    }
  }
}
