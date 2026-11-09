import { z } from "zod";

export const LEGACY_MESSAGE_CONTENT = "LEGACY_NOT_E2EE" as const;
export const FUTURE_E2EE_CONTENT = "E2EE_V1" as const;
export const LEGACY_COMMUNITY_CONTENT = "LEGACY_COMMUNITY_PLAINTEXT" as const;
export const FUTURE_GROUP_E2EE_CONTENT = "GROUP_E2EE_V1" as const;
export const MAX_LEGACY_INLINE_ATTACHMENT_BYTES = 20 * 1024 * 1024;
export const MAX_ENCRYPTED_ATTACHMENT_OBJECT_BYTES = 2 * 1024 * 1024 * 1024;

/**
 * Storage seam for the future attachment pipeline. Implementations receive
 * ciphertext only; plaintext, thumbnails, filenames, and content keys are not
 * valid inputs to this boundary.
 */
export interface OpaqueAttachmentObjectStore {
  putCiphertext(input: { objectId: string; bytes: Uint8Array; sha256: string }): Promise<void>;
  getCiphertext(objectId: string): Promise<Uint8Array>;
  deleteCiphertext(objectId: string): Promise<void>;
}

export const legacyInlineAttachmentSchema = z.object({
  mediaType: z.enum(["photo", "video", "audio", "file"]),
  fileName: z.string().trim().min(1).max(180),
  byteCount: z.number().int().min(0).max(MAX_LEGACY_INLINE_ATTACHMENT_BYTES),
  payloadBase64: z.string().min(1).max(30_000_000),
  mimeType: z.string().trim().max(120).nullable().optional(),
}).strict();

export const encryptedAttachmentManifestV1Schema = z.object({
  version: z.literal(1),
  objectId: z.string().uuid(),
  ciphertextByteCount: z.number().int().positive().max(MAX_ENCRYPTED_ATTACHMENT_OBJECT_BYTES),
  ciphertextSHA256: z.string().regex(/^[a-f0-9]{64}$/),
  encryptedManifest: z.string().min(24).max(32_768),
}).strict();

const legacyDirectMessageObjectSchema = z.object({
  contentMode: z.literal(LEGACY_MESSAGE_CONTENT).default(LEGACY_MESSAGE_CONTENT),
  body: z.string().max(4_000).default(""),
  attachment: legacyInlineAttachmentSchema.optional(),
  replyToMessageId: z.string().uuid().nullable().optional(),
  clientMessageId: z.string().uuid().optional(),
  disappearing: z.enum(["inherit", "keep", "after_read"]).default("inherit"),
  expirationDurationSeconds: z.number().int().min(0).max(30 * 24 * 60 * 60).nullable().optional(),
}).strict();

export const legacyDirectMessageRequestSchema = legacyDirectMessageObjectSchema.refine((value) => value.body.trim().length > 0 || Boolean(value.attachment), {
  message: "message_body_or_attachment_required",
});

/** Canonical field order for the future opaque envelope. No plaintext field exists. */
export const encryptedMessageEnvelopeV1Schema = z.object({
  contentMode: z.literal(FUTURE_E2EE_CONTENT),
  protocolVersion: z.literal(1),
  messageId: z.string().uuid(),
  conversationId: z.string().uuid().optional(),
  groupId: z.string().uuid().optional(),
  senderUserId: z.string().min(1).max(128),
  senderDeviceId: z.string().uuid(),
  recipientDeviceIds: z.array(z.string().uuid()).max(100),
  ciphertext: z.string().min(24).max(4_000_000),
  attachmentManifests: z.array(encryptedAttachmentManifestV1Schema).max(10).default([]),
  createdAt: z.string().datetime(),
  contentType: z.enum(["message", "reaction", "receipt", "edit", "delete", "system"]),
  protocolMetadata: z.record(z.string(), z.string().max(4_096)).default({}),
  replayId: z.string().min(16).max(128),
}).strict().refine((value) => Boolean(value.conversationId) !== Boolean(value.groupId), {
  message: "exactly_one_conversation_or_group_id_required",
});

export const directMessageRequestSchema = z.union([
  legacyDirectMessageObjectSchema,
  encryptedMessageEnvelopeV1Schema,
]);

const legacyCommunityMessageObjectSchema = z.object({
  contentMode: z.literal(LEGACY_COMMUNITY_CONTENT),
  body: z.string().trim().min(1).max(2_000_000),
  clientMessageId: z.string().uuid().optional(),
}).strict();

export const encryptedCommunityEnvelopeV1Schema = z.object({
  contentMode: z.literal(FUTURE_GROUP_E2EE_CONTENT),
  protocolVersion: z.literal(1),
  groupId: z.string().uuid(),
  groupEpoch: z.number().int().nonnegative(),
  messageId: z.string().uuid(),
  senderUserId: z.string().min(1).max(128),
  senderDeviceId: z.string().uuid(),
  ciphertext: z.string().min(24).max(4_000_000),
  createdAt: z.string().datetime(),
  contentType: z.enum(["message", "reaction", "receipt", "edit", "delete", "membership"]),
  protocolMetadata: z.record(z.string(), z.string().max(4_096)).default({}),
  replayId: z.string().min(16).max(128),
  encryptedAttachmentManifests: z.array(encryptedAttachmentManifestV1Schema).max(10).default([]),
}).strict();

export const communityMessageRequestSchema = z.discriminatedUnion("contentMode", [
  legacyCommunityMessageObjectSchema,
  encryptedCommunityEnvelopeV1Schema,
]);

export class LegacyDecryptIsolationError extends Error {
  constructor() {
    super("future_e2ee_envelope_cannot_use_legacy_decrypt");
    this.name = "LegacyDecryptIsolationError";
  }
}

export function assertLegacyDecryptable(value: unknown): asserts value is { contentMode?: typeof LEGACY_MESSAGE_CONTENT } {
  if (value && typeof value === "object" && "contentMode" in value) {
    const mode = (value as { contentMode?: unknown }).contentMode;
    if (mode !== LEGACY_MESSAGE_CONTENT) throw new LegacyDecryptIsolationError();
  }
}

