import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { logger } from "../lib/logger";
import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord, loadPublicIdentity, normalizeOneWayId } from "../services/identity";
import { smsProvider } from "../services/sms/createSMSProvider";
import type { SMSProviderName } from "../services/sms/SMSProvider";
import { normalizeSMSDeliveryStatus, smsDeliveryFailureMessage } from "../services/sms/MessageDeliveryService";
import { resolveTwilioCampaignStatus } from "../services/sms/twilioCampaignStatus";
import { emailProvider } from "../services/email/createEmailProvider";
import type { EmailProviderName } from "../services/email/EmailProvider";
import { decryptIfEncrypted, encryptIfEnabled } from "../services/privacy/EncryptionService";
import {
  decryptExternalConversationTarget,
  encryptExternalConversationTarget,
  ensureExternalConversationPrivacyColumns,
  externalConversationTargetHash,
  type ExternalConversationType,
} from "../services/privacy/ConversationPrivacy";
import type { MessageRealtimeServer } from "../realtime/MessageRealtimeServer";
import { expireDueMessages } from "../services/MessageExpirationService";
import { twilioWebhookMiddleware } from "../services/twilio/TwilioSecurity";
import { recordSMSConsent } from "../services/sms/SMSOptOutStore";

const uuidSchema = z.string().uuid().transform((value) => value.toLowerCase());

const attachmentSchema = z.object({
  mediaType: z.enum(["photo", "video", "file"]),
  fileName: z.string().trim().min(1).max(180),
  byteCount: z.number().int().min(0).max(20 * 1024 * 1024),
  payloadBase64: z.string().min(1).max(30_000_000),
  mimeType: z.string().trim().max(120).nullable().optional(),
}).optional();

const directConversationSchema = z.object({
  participantUserId: z.string().trim().min(1).max(128).optional(),
  handle: z.string().trim().min(2).max(64).optional(),
}).refine((body) => Boolean(body.participantUserId || body.handle), {
  message: "participantUserId_or_handle_required",
});

const sendMessageSchema = z.object({
  body: z.string().max(4_000).default(""),
  attachment: attachmentSchema,
  replyToMessageId: z.string().uuid().nullable().optional(),
  clientMessageId: z.string().uuid().optional(),
  disappearing: z.enum(["inherit", "keep", "after_read"]).default("inherit"),
  expirationDurationSeconds: z.number().int().min(0).max(30 * 24 * 60 * 60).nullable().optional(),
}).refine((body) => body.body.trim().length > 0 || Boolean(body.attachment), {
  message: "message_body_or_attachment_required",
});

const externalConversationSchema = z.object({
  phoneNumber: z.string().trim().min(3).max(32).optional(),
  email: z.string().trim().email().max(254).optional(),
  target: z.string().trim().min(3).max(254).optional(),
}).refine((body) => Boolean(body.phoneNumber || body.email || body.target), {
  message: "external_target_required",
});

const externalSendSchema = z.object({
  toPhoneNumber: z.string().trim().min(3).max(32).optional(),
  toEmail: z.string().trim().email().max(254).optional(),
  target: z.string().trim().min(3).max(254).optional(),
  body: z.string().trim().min(1).max(1600),
  fromOneWayNumber: z.string().trim().min(2).max(32).optional(),
  mediaUrls: z.array(z.string().url()).max(10).optional(),
  clientMessageId: z.string().uuid().optional(),
  idempotencyKey: z.string().trim().min(8).max(128).optional(),
  smsConsentConfirmed: z.boolean().optional(),
  smsConsentSource: z.enum(["recipient_request", "existing_relationship", "account_transaction", "support_request"]).optional(),
  smsConsentAt: z.string().datetime().optional(),
}).refine((body) => Boolean(body.toPhoneNumber || body.toEmail || body.target), {
  message: "external_target_required",
});

const editMessageSchema = z.object({
  body: z.string().trim().min(1).max(4_000),
});

const readAcknowledgementSchema = z.object({
  visibleInForeground: z.literal(true),
});

const conversationPrivacySchema = z.object({
  expirationMode: z.enum(["off", "after_read"]),
  expirationDurationSeconds: z.number().int().min(0).max(30 * 24 * 60 * 60).nullable().optional(),
  allowForwarding: z.boolean().default(true),
  allowCopying: z.boolean().default(true),
  allowSavingAttachments: z.boolean().default(true),
}).superRefine((value, context) => {
  if (value.expirationMode === "after_read" && value.expirationDurationSeconds == null) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["expirationDurationSeconds"], message: "duration_required" });
  }
});

type StoredPayload = {
  body: string;
  attachment?: {
    mediaType: "photo" | "video" | "file";
    fileName: string;
    byteCount: number;
    payloadBase64: string;
    mimeType?: string | null;
  } | null;
  replyToMessageId?: string | null;
  editedAt?: string | null;
  systemNotice?: boolean;
  tombstone?: { version: number; reason: string } | null;
  external?: {
    networkType: "smsBridge" | "emailBridge";
    phoneNumber?: string | null;
    email?: string | null;
    provider: string;
    providerMessageId?: string | null;
    providerStatus?: string | null;
    idempotencyKey?: string | null;
    failureReason?: string | null;
    queuedAt?: string | null;
    sentAt?: string | null;
    deliveredAt?: string | null;
    latencyMs?: number | null;
    direction: "incoming" | "outgoing";
  } | null;
};

const smsRateLimits = new Map<string, { minuteStart: number; minuteCount: number; hourStart: number; hourCount: number }>();

export function messagesRouter(deps: { realtime?: MessageRealtimeServer } = {}): express.Router {
  const router = express.Router();

  router.post("/external/twilio/status", twilioWebhookMiddleware, async (req, res) => {
    logger.info({
      provider: "twilio",
      messageStatus: String(req.body?.MessageStatus ?? ""),
      hasError: Boolean(req.body?.ErrorCode || req.body?.ErrorMessage),
    }, "[sms:twilio] status webhook");
    await applyTwilioDeliveryCallback({
      providerMessageId: String(req.body?.MessageSid ?? ""),
      providerStatus: String(req.body?.MessageStatus ?? ""),
      failureReason: String(req.body?.ErrorCode ?? req.body?.ErrorMessage ?? ""),
    }, deps.realtime);
    res.json({ ok: true });
  });

  router.post("/external/twilio/inbound", twilioWebhookMiddleware, async (req, res) => {

    const from = normalizePhoneNumber(String(req.body?.From ?? ""));
    const to = normalizePhoneNumber(String(req.body?.To ?? ""));
    const body = String(req.body?.Body ?? "").slice(0, 4000);
    const providerMessageId = String(req.body?.MessageSid ?? "");

    if (!from || !to || !body.trim()) {
      res.type("text/xml").send("<Response></Response>");
      return;
    }

    const inbound = await storeInboundExternalMessage({
      provider: "twilio",
      providerMessageId,
      fromPhoneNumber: from,
      toPhoneNumber: to,
      body,
    });
    if (inbound) {
      deps.realtime?.broadcastMessageCreated([inbound.ownerUserId], mapMessage(inbound.message));
    }

    res.type("text/xml").send("<Response></Response>");
  });

  router.post("/external/telnyx/status", (req, res) => {
    if (!verifySMSWebhookAccess(req)) {
      res.status(403).json({ error: "sms_webhook_forbidden" });
      return;
    }
    logger.info({
      provider: "telnyx",
      eventType: String(req.body?.data?.event_type ?? req.body?.event_type ?? ""),
    }, "[sms:telnyx] status webhook");
    res.json({ ok: true });
  });

  router.post("/external/sinch/status", (req, res) => {
    if (!verifySMSWebhookAccess(req)) {
      res.status(403).json({ error: "sms_webhook_forbidden" });
      return;
    }
    logger.info({
      provider: "sinch",
      eventType: String(req.body?.event ?? req.body?.type ?? ""),
    }, "[sms:sinch] status webhook");
    res.json({ ok: true });
  });

  router.use(authMiddleware);

  router.get("/external/preflight", async (_req, res) => {
    res.json(await buildSMSPreflight());
  });

  router.get("/external/email/preflight", async (_req, res) => {
    res.json(buildEmailPreflight());
  });

  router.post("/external/conversations", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = externalConversationSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const target = resolveExternalTarget(parsed.data);
    if (!target) {
      res.status(400).json({
        error: "invalid_external_target",
        message: "Enter a reachable phone number or a valid email address.",
      });
      return;
    }

    const conversation = target.kind === "phone"
      ? await findOrCreateExternalSMSConversation(userId, target.value)
      : await findOrCreateExternalEmailConversation(userId, target.value);
    res.json({ conversation: await mapConversation(conversation, userId) });
  });

  router.post("/external/send", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = externalSendSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const target = resolveExternalTarget(parsed.data);
    if (!target) {
      res.status(400).json({
        error: "invalid_external_target",
        message: "Enter a reachable phone number or a valid email address.",
      });
      return;
    }

    const rateLimit = checkSMSRateLimit(userId);
    if (!rateLimit.ok) {
      res.status(429).json({
        error: "sms_rate_limited",
        message: "OneWay external messaging is rate limited. Try again shortly.",
        retryAfterSeconds: rateLimit.retryAfterSeconds,
      });
      return;
    }

    const sendResult = target.kind === "phone"
      ? await sendExternalSMS({
        userId,
        phoneNumber: target.value,
        body: parsed.data.body,
        fromOneWayNumber: parsed.data.fromOneWayNumber,
        mediaUrls: parsed.data.mediaUrls,
        idempotencyKey: parsed.data.idempotencyKey ?? parsed.data.clientMessageId,
        consent: parsed.data.smsConsentConfirmed === true && parsed.data.smsConsentSource
          ? {
            source: parsed.data.smsConsentSource,
            evidenceAt: parsed.data.smsConsentAt ? new Date(parsed.data.smsConsentAt) : new Date(),
          }
          : undefined,
      })
      : await sendExternalEmail({
        userId,
        email: target.value,
        body: parsed.data.body,
      });

    if (!sendResult.ok) {
      res.status(sendResult.statusCode ?? 502).json(sendResult.body);
      return;
    }

    res.status(201).json({
      ok: true,
      networkType: sendResult.networkType,
      provider: sendResult.provider,
      status: sendResult.status,
      providerMessageId: sendResult.providerMessageId,
      toPhoneNumber: target.kind === "phone" ? target.value : undefined,
      toEmail: target.kind === "email" ? target.value : undefined,
      message: sendResult.message,
      conversation: await mapConversation(sendResult.conversation, userId),
      storedMessage: mapMessage(sendResult.storedMessage),
    });
  });

  router.get("/conversations", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const conversations = await prisma.conversation.findMany({
      where: {
        participants: {
          some: { userId },
        },
      },
      include: {
        participants: {
          include: {
            user: {
              include: { identity: true },
            },
          },
        },
        messages: {
          orderBy: { createdAt: "desc" },
          take: 1,
        },
      },
      orderBy: { updatedAt: "desc" },
    });

    const mapped = await Promise.all(conversations.map((conversation) => mapConversation(conversation, userId)));
    res.json({ conversations: mapped.filter(Boolean) });
  });

  router.get("/conversations/:conversationId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = uuidSchema.safeParse(req.params.conversationId);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_conversation_id" });
      return;
    }

    const conversation = await prisma.conversation.findFirst({
      where: {
        id: parsed.data,
        participants: { some: { userId } },
      },
      include: {
        participants: {
          include: {
            user: {
              include: { identity: true },
            },
          },
        },
        messages: {
          orderBy: { createdAt: "desc" },
          take: 1,
        },
      },
    });

    if (!conversation) {
      res.status(404).json({ error: "conversation_not_found" });
      return;
    }

    res.json({ conversation: await mapConversation(conversation, userId) });
  });

  router.post("/conversations/direct", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = directConversationSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const participantUserId = await resolveDirectParticipant(userId, parsed.data);
    if (!participantUserId) {
      res.status(404).json({
        error: "oneway_contact_not_found",
        message: "That OneWay contact could not be found.",
      });
      return;
    }

    if (participantUserId === userId) {
      res.status(400).json({
        error: "self_conversation_forbidden",
        message: "You cannot message yourself.",
      });
      return;
    }

    const connected = await isConnectedContact(userId, participantUserId);
    if (!connected) {
      res.status(403).json({
        error: "contact_not_connected",
        message: "You can message this user after you are connected OneWay contacts.",
      });
      return;
    }

    const conversation = await findOrCreateDirectConversation(userId, participantUserId);
    res.json({ conversation: await mapConversation(conversation, userId) });
  });

  router.get("/conversations/:conversationId/messages", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = uuidSchema.safeParse(req.params.conversationId);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_conversation_id" });
      return;
    }

    const authorized = await isConversationParticipant(userId, parsed.data);
    if (!authorized) {
      res.status(404).json({ error: "conversation_not_found" });
      return;
    }

    await expireDueMessages(prisma, deps.realtime);
    const limit = clampNumber(Number(req.query.limit ?? 100), 1, 200);
    const messages = await prisma.message.findMany({
      where: { conversationId: parsed.data },
      orderBy: { createdAt: "asc" },
      take: limit,
    });

    res.json({ messages: messages.map(mapMessage) });
  });

  router.get("/conversations/:conversationId/privacy", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = uuidSchema.safeParse(req.params.conversationId);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_conversation_id" });
      return;
    }
    const conversation = await prisma.conversation.findFirst({
      where: { id: parsed.data, participants: { some: { userId } } },
    });
    if (!conversation) {
      res.status(404).json({ error: "conversation_not_found" });
      return;
    }
    res.json({ privacy: mapConversationPrivacy(conversation) });
  });

  router.put("/conversations/:conversationId/privacy", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const conversationId = uuidSchema.safeParse(req.params.conversationId);
    const body = conversationPrivacySchema.safeParse(req.body);
    if (!conversationId.success || !body.success) {
      res.status(400).json({ error: "invalid_privacy_settings", issues: body.success ? [] : body.error.issues });
      return;
    }
    const conversation = await prisma.conversation.findFirst({
      where: { id: conversationId.data, participants: { some: { userId } } },
      include: { participants: true },
    });
    if (!conversation) {
      res.status(404).json({ error: "conversation_not_found" });
      return;
    }
    if (conversation.type === "external_sms" || conversation.type === "external_email") {
      res.status(409).json({ error: "external_conversation_not_eligible" });
      return;
    }
    const duration = body.data.expirationMode === "after_read"
      ? body.data.expirationDurationSeconds ?? 0
      : null;
    const noticeText = privacyNoticeText(body.data.expirationMode, duration);
    const result = await prisma.$transaction(async (tx) => {
      const updated = await tx.conversation.update({
        where: { id: conversation.id },
        data: {
          expirationMode: body.data.expirationMode,
          expirationDurationSeconds: duration,
          allowForwarding: body.data.allowForwarding,
          allowCopying: body.data.allowCopying,
          allowSavingAttachments: body.data.allowSavingAttachments,
          privacySettingsVersion: { increment: 1 },
        },
      });
      const notice = await tx.message.create({
        data: {
          conversationId: conversation.id,
          senderId: userId,
          ciphertext: encodePayload({ body: noticeText, attachment: null, systemNotice: true }, conversation.id),
          expirationMode: "off",
          attachmentExpirationState: "none",
        },
      });
      const recipientIds = conversation.participants.map((item) => item.userId).filter((id) => id !== userId);
      if (recipientIds.length > 0) {
        await tx.messageReceipt.createMany({
          data: recipientIds.map((recipientId) => ({ messageId: notice.id, userId: recipientId, status: "delivered" })),
        });
      }
      return { updated, notice };
    });
    const mappedNotice = mapMessage(result.notice);
    deps.realtime?.broadcastMessageCreated(conversation.participants.map((item) => item.userId), mappedNotice);
    res.json({ privacy: mapConversationPrivacy(result.updated), notice: mappedNotice });
  });

  router.post("/conversations/:conversationId/messages", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsedConversation = uuidSchema.safeParse(req.params.conversationId);
    const parsedBody = sendMessageSchema.safeParse(req.body);
    if (!parsedConversation.success || !parsedBody.success) {
      res.status(400).json({
        error: "invalid_body",
        issues: parsedConversation.success ? parsedBody.error?.issues : parsedConversation.error.issues,
      });
      return;
    }

    const conversation = await prisma.conversation.findFirst({
      where: {
        id: parsedConversation.data,
        participants: { some: { userId } },
      },
      include: { participants: true },
    });

    if (!conversation) {
      res.status(404).json({ error: "conversation_not_found" });
      return;
    }

    if (conversation.type === "external_sms" || conversation.type === "external_email") {
      if (parsedBody.data.disappearing !== "inherit") {
        res.status(409).json({ error: "external_message_not_eligible_for_disappearing" });
        return;
      }
      const body = parsedBody.data.body.trim();
      if (!body || parsedBody.data.attachment) {
        res.status(400).json({
          error: "external_text_only",
          message: "External network messages currently support text only.",
        });
        return;
      }

      const targetValue = decryptExternalConversationTarget(conversation);
      const target = conversation.type === "external_sms"
        ? normalizePhoneNumber(targetValue ?? "")
        : normalizeEmail(targetValue ?? "");
      if (!target) {
        res.status(400).json({ error: "external_target_missing" });
        return;
      }

      const rateLimit = checkSMSRateLimit(userId);
      if (!rateLimit.ok) {
        res.status(429).json({
          error: "sms_rate_limited",
          message: "OneWay external messaging is rate limited. Try again shortly.",
          retryAfterSeconds: rateLimit.retryAfterSeconds,
        });
        return;
      }

      const sendResult = conversation.type === "external_sms"
        ? await sendExternalSMS({ userId, phoneNumber: target, body, idempotencyKey: parsedBody.data.clientMessageId })
        : await sendExternalEmail({ userId, email: target, body });

      if (!sendResult.ok) {
        res.status(sendResult.statusCode ?? 502).json({
          error: "external_provider_failed",
          ...sendResult.body,
        });
        return;
      }

      const mappedMessage = mapMessage(sendResult.storedMessage);
      deps.realtime?.broadcastMessageCreated(
        conversation.participants.map((participant) => participant.userId),
        mappedMessage
      );
      res.status(201).json({ message: mappedMessage });
      return;
    }

    const expiration = resolveMessageExpiration(conversation, parsedBody.data);
    const payload: StoredPayload = {
      body: parsedBody.data.body.trim(),
      attachment: parsedBody.data.attachment ?? null,
      replyToMessageId: parsedBody.data.replyToMessageId ?? null,
    };

    const recipientIds = conversation.participants
      .map((participant) => participant.userId)
      .filter((participantId) => participantId !== userId);

    const message = await prisma.$transaction(async (tx) => {
      const created = await tx.message.create({
        data: {
          conversationId: conversation.id,
          senderId: userId,
          ciphertext: encodePayload(payload, conversation.id),
          expirationMode: expiration.mode,
          expirationDurationSeconds: expiration.durationSeconds,
          attachmentExpirationState: parsedBody.data.attachment ? "active" : "none",
        },
      });

      if (recipientIds.length > 0) {
        await tx.messageReceipt.createMany({
          data: recipientIds.map((recipientId) => ({
            messageId: created.id,
            userId: recipientId,
            status: "delivered",
          })),
        });
      }

      await tx.conversation.update({
        where: { id: conversation.id },
        data: { updatedAt: new Date() },
      });

      return created;
    });

    const mappedMessage = mapMessage(message);
    deps.realtime?.broadcastMessageCreated(
      conversation.participants.map((participant) => participant.userId),
      mappedMessage
    );
    res.status(201).json({ message: mappedMessage });
  });

  router.patch("/conversations/:conversationId/read", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = uuidSchema.safeParse(req.params.conversationId);
    const acknowledgement = readAcknowledgementSchema.safeParse(req.body);
    if (!parsed.success || !acknowledgement.success || !(await isConversationParticipant(userId, parsed.data))) {
      res.status(404).json({ error: "conversation_not_found" });
      return;
    }

    const acknowledged = await acknowledgeVisibleReads(userId, parsed.data, new Date());
    const updatedMessages = await prisma.message.findMany({
      where: { id: { in: acknowledged } },
      include: { conversation: { include: { participants: { select: { userId: true } } } } },
    });
    for (const message of updatedMessages) {
      deps.realtime?.broadcastMessageUpdated(
        message.conversation.participants.map((participant) => participant.userId),
        mapMessage(message),
      );
    }
    const expired = await expireDueMessages(prisma, deps.realtime);
    res.json({ ok: true, acknowledged: acknowledged.length, expired });
  });

  router.patch("/conversations/:conversationId/messages/:messageId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const conversationId = uuidSchema.safeParse(req.params.conversationId);
    const messageId = uuidSchema.safeParse(req.params.messageId);
    const body = editMessageSchema.safeParse(req.body);
    if (!conversationId.success || !messageId.success || !body.success) {
      res.status(400).json({ error: "invalid_body" });
      return;
    }

    const message = await prisma.message.findFirst({
      where: {
        id: messageId.data,
        conversationId: conversationId.data,
        senderId: userId,
        deletedAt: null,
      },
    });

    if (!message) {
      res.status(404).json({ error: "message_not_found" });
      return;
    }

    const payload = decodePayload(message.ciphertext, message.conversationId);
    payload.body = body.data.body;
    payload.editedAt = new Date().toISOString();

    const updated = await prisma.message.update({
      where: { id: message.id },
      data: { ciphertext: encodePayload(payload, message.conversationId) },
    });

    res.json({ message: mapMessage(updated) });
  });

  router.delete("/conversations/:conversationId/messages/:messageId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const conversationId = uuidSchema.safeParse(req.params.conversationId);
    const messageId = uuidSchema.safeParse(req.params.messageId);
    if (!conversationId.success || !messageId.success) {
      res.status(400).json({ error: "invalid_message_id" });
      return;
    }

    const deleted = await prisma.message.deleteMany({
      where: {
        id: messageId.data,
        conversationId: conversationId.data,
        senderId: userId,
      },
    });

    if (deleted.count === 0) {
      res.status(404).json({ error: "message_not_found" });
      return;
    }

    res.json({ ok: true });
  });

  return router;
}

async function resolveDirectParticipant(
  userId: string,
  input: { participantUserId?: string; handle?: string },
): Promise<string | null> {
  const requestedUserId = input.participantUserId?.trim();
  if (requestedUserId) {
    const normalized = requestedUserId.toLowerCase();
    const user = await prisma.user.findUnique({
      where: { id: normalized },
      select: { id: true },
    });
    if (user) return user.id;

    const contact = await prisma.oneWayContact.findFirst({
      where: {
        userId,
        id: normalized,
      },
      select: { contactUserId: true },
    });
    if (contact) return contact.contactUserId;
  }

  const requestedHandle = input.handle?.trim();
  if (requestedHandle) {
    const identity = await prisma.oneWayIdentity.findUnique({
      where: { onewayId: normalizeOneWayId(requestedHandle) },
      select: { userId: true },
    });
    return identity?.userId ?? null;
  }

  return null;
}

async function isConnectedContact(userId: string, contactUserId: string): Promise<boolean> {
  const contact = await prisma.oneWayContact.findUnique({
    where: {
      userId_contactUserId: {
        userId,
        contactUserId,
      },
    },
    select: { status: true },
  });
  return contact?.status === "connected";
}

async function findOrCreateDirectConversation(userId: string, participantUserId: string) {
  const existing = await prisma.conversation.findFirst({
    where: {
      type: "direct",
      AND: [
        { participants: { some: { userId } } },
        { participants: { some: { userId: participantUserId } } },
      ],
    },
    include: {
      participants: {
        include: {
          user: {
            include: { identity: true },
          },
        },
      },
      messages: {
        orderBy: { createdAt: "desc" },
        take: 1,
      },
    },
  });
  if (existing) return existing;

  return prisma.conversation.create({
    data: {
      type: "direct",
      participants: {
        create: [
          { userId, role: "member" },
          { userId: participantUserId, role: "member" },
        ],
      },
    },
    include: {
      participants: {
        include: {
          user: {
            include: { identity: true },
          },
        },
      },
      messages: {
        orderBy: { createdAt: "desc" },
        take: 1,
      },
    },
  });
}

async function findOrCreateExternalSMSConversation(userId: string, phoneNumber: string) {
  await ensureExternalConversationPrivacyColumns(prisma);
  const targetHash = externalConversationTargetHash("external_sms", phoneNumber);
  const existing = await prisma.conversation.findFirst({
    where: {
      type: "external_sms",
      ...(targetHash ? { externalTargetHash: targetHash } : { title: phoneNumber }),
      participants: { some: { userId } },
    },
    include: {
      participants: {
        include: {
          user: {
            include: { identity: true },
          },
        },
      },
      messages: {
        orderBy: { createdAt: "desc" },
        take: 1,
      },
    },
  });
  if (existing) return existing;

  if (targetHash) {
    const legacy = await prisma.conversation.findFirst({
      where: {
        type: "external_sms",
        title: phoneNumber,
        participants: { some: { userId } },
      },
      include: {
        participants: {
          include: {
            user: {
              include: { identity: true },
            },
          },
        },
        messages: {
          orderBy: { createdAt: "desc" },
          take: 1,
        },
      },
    });
    if (legacy) {
      await protectExternalConversationTarget(legacy.id, "external_sms", phoneNumber);
      return {
        ...legacy,
        title: "External line",
        externalTargetHash: targetHash,
        externalTargetCiphertext: encryptExternalConversationTarget("external_sms", phoneNumber),
      };
    }
  }

  return prisma.conversation.create({
    data: {
      type: "external_sms",
      title: targetHash ? "External line" : phoneNumber,
      externalTargetHash: targetHash,
      externalTargetCiphertext: encryptExternalConversationTarget("external_sms", phoneNumber),
      participants: {
        create: [{ userId, role: "owner" }],
      },
    },
    include: {
      participants: {
        include: {
          user: {
            include: { identity: true },
          },
        },
      },
      messages: {
        orderBy: { createdAt: "desc" },
        take: 1,
      },
    },
  });
}

async function findOrCreateExternalEmailConversation(userId: string, email: string) {
  await ensureExternalConversationPrivacyColumns(prisma);
  const targetHash = externalConversationTargetHash("external_email", email);
  const existing = await prisma.conversation.findFirst({
    where: {
      type: "external_email",
      ...(targetHash ? { externalTargetHash: targetHash } : { title: email }),
      participants: { some: { userId } },
    },
    include: {
      participants: {
        include: {
          user: {
            include: { identity: true },
          },
        },
      },
      messages: {
        orderBy: { createdAt: "desc" },
        take: 1,
      },
    },
  });
  if (existing) return existing;

  if (targetHash) {
    const legacy = await prisma.conversation.findFirst({
      where: {
        type: "external_email",
        title: email,
        participants: { some: { userId } },
      },
      include: {
        participants: {
          include: {
            user: {
              include: { identity: true },
            },
          },
        },
        messages: {
          orderBy: { createdAt: "desc" },
          take: 1,
        },
      },
    });
    if (legacy) {
      await protectExternalConversationTarget(legacy.id, "external_email", email);
      return {
        ...legacy,
        title: "External line",
        externalTargetHash: targetHash,
        externalTargetCiphertext: encryptExternalConversationTarget("external_email", email),
      };
    }
  }

  return prisma.conversation.create({
    data: {
      type: "external_email",
      title: targetHash ? "External line" : email,
      externalTargetHash: targetHash,
      externalTargetCiphertext: encryptExternalConversationTarget("external_email", email),
      participants: {
        create: [{ userId, role: "owner" }],
      },
    },
    include: {
      participants: {
        include: {
          user: {
            include: { identity: true },
          },
        },
      },
      messages: {
        orderBy: { createdAt: "desc" },
        take: 1,
      },
    },
  });
}

async function protectExternalConversationTarget(
  conversationId: string,
  type: ExternalConversationType,
  target: string,
): Promise<void> {
  const targetHash = externalConversationTargetHash(type, target);
  const targetCiphertext = encryptExternalConversationTarget(type, target);
  if (!targetHash || !targetCiphertext) return;
  await prisma.conversation.update({
    where: { id: conversationId },
    data: {
      title: "External line",
      externalTargetHash: targetHash,
      externalTargetCiphertext: targetCiphertext,
    },
  });
}

type ExternalSendSuccess = {
  ok: true;
  networkType: "smsBridge" | "emailBridge";
  provider: string;
  status: string;
  providerMessageId: string;
  message?: string;
  conversation: Awaited<ReturnType<typeof findOrCreateExternalSMSConversation>>;
  storedMessage: Awaited<ReturnType<typeof createExternalOutboundMessage>>;
};

type ExternalSendFailure = {
  ok: false;
  statusCode?: number;
  body: {
    ok: false;
    networkType: "smsBridge" | "emailBridge";
    error?: string;
    provider: string;
    status: "failed";
    providerMessageId: string;
    toPhoneNumber?: string;
    toEmail?: string;
    message: string;
  };
};

async function sendExternalSMS(input: {
  userId: string;
  phoneNumber: string;
  body: string;
  fromOneWayNumber?: string;
  mediaUrls?: string[];
  idempotencyKey?: string;
  consent?: { source: string; evidenceAt: Date };
}): Promise<ExternalSendSuccess | ExternalSendFailure> {
  if (input.consent) {
    await recordSMSConsent({
      phoneNumber: input.phoneNumber,
      userId: input.userId,
      granted: true,
      source: input.consent.source,
      evidenceAt: input.consent.evidenceAt,
    });
  }
  const fromOneWayNumber = await resolveSenderOneWayNumber(input.userId, input.fromOneWayNumber);
  if (input.fromOneWayNumber && !fromOneWayNumber) {
    return {
      ok: false,
      body: {
        ok: false,
        networkType: "smsBridge",
        provider: smsProvider.name,
        status: "failed",
        providerMessageId: "from_number_not_owned",
        toPhoneNumber: input.phoneNumber,
        message: "That OneWay number is not assigned to this account.",
      },
    };
  }

  const conversation = await findOrCreateExternalSMSConversation(input.userId, input.phoneNumber);
  const idempotencyKey = input.idempotencyKey ?? randomUUID();
  const existing = await findExternalMessageByIdempotencyKey(conversation.id, idempotencyKey);
  if (existing) {
    const payload = decodePayload(existing.ciphertext, existing.conversationId);
    return {
      ok: true,
      networkType: "smsBridge",
      provider: payload.external?.provider ?? smsProvider.name,
      status: payload.external?.providerStatus ?? "queued",
      providerMessageId: payload.external?.providerMessageId ?? `pending:${existing.id}`,
      message: payload.external?.failureReason ?? undefined,
      conversation,
      storedMessage: existing,
    };
  }

  const queuedAt = new Date();
  let storedMessage = await createExternalOutboundMessage({
    conversationId: conversation.id,
    userId: input.userId,
    networkType: "smsBridge",
    phoneNumber: input.phoneNumber,
    body: input.body,
    provider: smsProvider.name,
    providerMessageId: `pending:${idempotencyKey}`,
    providerStatus: "queued",
    idempotencyKey,
    queuedAt,
  });

  const result = await smsProvider.sendOutboundMessage({
    fromUserId: input.userId,
    fromOneWayNumber,
    toPhoneNumber: input.phoneNumber,
    body: input.body,
    mediaUrls: input.mediaUrls,
    messageSessionId: idempotencyKey,
  });

  if (result.status === "failed") {
    storedMessage = await updateExternalOutboundMessage(storedMessage.id, {
      provider: result.provider,
      providerMessageId: result.providerMessageId,
      providerStatus: "failed",
      failureReason: result.message ?? "The SMS provider could not send this message.",
      latencyMs: Date.now() - queuedAt.getTime(),
    });
  } else {
    storedMessage = await updateExternalOutboundMessage(storedMessage.id, {
      provider: result.provider,
      providerMessageId: result.providerMessageId,
      providerStatus: result.status,
      sentAt: new Date(),
      latencyMs: Date.now() - queuedAt.getTime(),
    });
  }

  return {
    ok: true,
    networkType: "smsBridge",
    provider: result.provider,
    status: result.status,
    providerMessageId: result.providerMessageId,
    message: result.message,
    conversation,
    storedMessage,
  };
}

async function sendExternalEmail(input: {
  userId: string;
  email: string;
  body: string;
}): Promise<ExternalSendSuccess | ExternalSendFailure> {
  const result = await emailProvider.sendOutboundMessage({
    fromUserId: input.userId,
    toEmail: input.email,
    body: input.body,
    messageSessionId: randomUUID(),
  });

  if (result.status === "failed") {
    return {
      ok: false,
      body: {
        ok: false,
        networkType: "emailBridge",
        provider: result.provider,
        status: result.status,
        providerMessageId: result.providerMessageId,
        toEmail: input.email,
        message: result.message ?? "The email provider could not send this message.",
      },
    };
  }

  const conversation = await findOrCreateExternalEmailConversation(input.userId, input.email);
  const storedMessage = await createExternalOutboundMessage({
    conversationId: conversation.id,
    userId: input.userId,
    networkType: "emailBridge",
    email: input.email,
    body: input.body,
    provider: result.provider,
    providerMessageId: result.providerMessageId,
    providerStatus: result.status,
  });

  return {
    ok: true,
    networkType: "emailBridge",
    provider: result.provider,
    status: result.status,
    providerMessageId: result.providerMessageId,
    message: result.message,
    conversation,
    storedMessage,
  };
}

async function createExternalOutboundMessage(input: {
  conversationId: string;
  userId: string;
  networkType: "smsBridge" | "emailBridge";
  phoneNumber?: string;
  email?: string;
  body: string;
  provider: string;
  providerMessageId: string;
  providerStatus: string;
  idempotencyKey?: string;
  queuedAt?: Date;
}) {
  const payload: StoredPayload = {
    body: input.body,
    attachment: null,
    replyToMessageId: null,
    external: {
      networkType: input.networkType,
      phoneNumber: input.phoneNumber ?? null,
      email: input.email ?? null,
      provider: input.provider,
      providerMessageId: input.providerMessageId,
      providerStatus: input.providerStatus,
      idempotencyKey: input.idempotencyKey ?? null,
      queuedAt: (input.queuedAt ?? new Date()).toISOString(),
      failureReason: null,
      sentAt: null,
      deliveredAt: null,
      latencyMs: null,
      direction: "outgoing",
    },
  };

  const message = await prisma.message.create({
    data: {
      conversationId: input.conversationId,
      senderId: input.userId,
      ciphertext: encodePayload(payload, input.conversationId),
    },
  });

  await prisma.conversation.update({
    where: { id: input.conversationId },
    data: { updatedAt: new Date() },
  });

  return message;
}

async function findExternalMessageByIdempotencyKey(conversationId: string, idempotencyKey: string) {
  const messages = await prisma.message.findMany({
    where: {
      conversationId,
      ciphertext: { contains: idempotencyKey },
    },
    orderBy: { createdAt: "desc" },
    take: 10,
  });

  return messages.find((message) => {
    const payload = decodePayload(message.ciphertext, message.conversationId);
    return payload.external?.idempotencyKey === idempotencyKey;
  }) ?? null;
}

async function updateExternalOutboundMessage(
  messageId: string,
  patch: {
    provider?: string;
    providerMessageId?: string;
    providerStatus?: string;
    failureReason?: string | null;
    sentAt?: Date;
    deliveredAt?: Date;
    latencyMs?: number;
  },
) {
  const message = await prisma.message.findUnique({ where: { id: messageId } });
  if (!message) throw new Error("external_message_not_found");

  const payload = decodePayload(message.ciphertext, message.conversationId);
  if (!payload.external) throw new Error("external_payload_missing");

  payload.external = {
    ...payload.external,
    provider: patch.provider ?? payload.external.provider,
    providerMessageId: patch.providerMessageId ?? payload.external.providerMessageId,
    providerStatus: patch.providerStatus ?? payload.external.providerStatus,
    failureReason: patch.failureReason === undefined ? payload.external.failureReason ?? null : patch.failureReason,
    sentAt: patch.sentAt?.toISOString() ?? payload.external.sentAt ?? null,
    deliveredAt: patch.deliveredAt?.toISOString() ?? payload.external.deliveredAt ?? null,
    latencyMs: patch.latencyMs ?? payload.external.latencyMs ?? null,
  };

  return prisma.message.update({
    where: { id: message.id },
    data: { ciphertext: encodePayload(payload, message.conversationId) },
  });
}

async function isConversationParticipant(userId: string, conversationId: string): Promise<boolean> {
  const participant = await prisma.conversationParticipant.findUnique({
    where: {
      userId_conversationId: {
        userId,
        conversationId,
      },
    },
    select: { userId: true },
  });
  return Boolean(participant);
}

function mapConversationPrivacy(conversation: any) {
  return {
    expirationMode: conversation.expirationMode ?? "off",
    expirationDurationSeconds: conversation.expirationDurationSeconds ?? null,
    allowForwarding: conversation.allowForwarding ?? true,
    allowCopying: conversation.allowCopying ?? true,
    allowSavingAttachments: conversation.allowSavingAttachments ?? true,
    version: conversation.privacySettingsVersion ?? 1,
  };
}

function privacyNoticeText(mode: "off" | "after_read", durationSeconds: number | null): string {
  if (mode === "off") return "Disappearing messages were turned off.";
  if (durationSeconds === 0) return "Messages will disappear after everyone has read them.";
  const duration = durationSeconds ?? 0;
  if (duration % 86_400 === 0) return `Messages will disappear ${duration / 86_400} day(s) after everyone has read them.`;
  if (duration % 3_600 === 0) return `Messages will disappear ${duration / 3_600} hour(s) after everyone has read them.`;
  if (duration % 60 === 0) return `Messages will disappear ${duration / 60} minute(s) after everyone has read them.`;
  return `Messages will disappear ${duration} second(s) after everyone has read them.`;
}

function resolveMessageExpiration(
  conversation: any,
  input: { disappearing: "inherit" | "keep" | "after_read"; expirationDurationSeconds?: number | null },
): { mode: "off" | "after_read"; durationSeconds: number | null } {
  if (input.disappearing === "keep") return { mode: "off", durationSeconds: null };
  if (input.disappearing === "after_read") {
    return {
      mode: "after_read",
      durationSeconds: input.expirationDurationSeconds ?? conversation.expirationDurationSeconds ?? 0,
    };
  }
  if (conversation.expirationMode === "after_read") {
    return { mode: "after_read", durationSeconds: conversation.expirationDurationSeconds ?? 0 };
  }
  return { mode: "off", durationSeconds: null };
}

async function acknowledgeVisibleReads(userId: string, conversationId: string, now: Date): Promise<string[]> {
  return prisma.$transaction(async (tx) => {
    const unreadReceipts = await tx.messageReceipt.findMany({
      where: {
        userId,
        readAt: null,
        message: { conversationId, senderId: { not: userId }, deletedAt: null },
      },
      include: { message: true },
    });
    if (unreadReceipts.length === 0) return [];

    for (const receipt of unreadReceipts) {
      const durationSeconds = receipt.message.expirationMode === "after_read"
        ? receipt.message.expirationDurationSeconds ?? 0
        : null;
      await tx.messageReceipt.updateMany({
        where: { id: receipt.id, readAt: null },
        data: {
          status: "read",
          readAt: now,
          expiresAt: durationSeconds == null ? null : new Date(now.getTime() + durationSeconds * 1_000),
        },
      });
    }

    const messageIds = [...new Set(unreadReceipts.map((receipt) => receipt.messageId))];
    for (const messageId of messageIds) {
      const message = unreadReceipts.find((receipt) => receipt.messageId === messageId)?.message;
      if (!message || message.expirationMode !== "after_read") continue;
      const receipts = await tx.messageReceipt.findMany({ where: { messageId } });
      if (receipts.length === 0 || receipts.some((receipt) => !receipt.readAt)) continue;
      const lastReadAt = new Date(Math.max(...receipts.map((receipt) => receipt.readAt!.getTime())));
      const expiresAt = new Date(lastReadAt.getTime() + (message.expirationDurationSeconds ?? 0) * 1_000);
      await tx.message.updateMany({
        where: { id: messageId, readAt: null, deletedAt: null },
        data: { readAt: lastReadAt, expiresAt },
      });
    }
    return messageIds;
  });
}

async function mapConversation(conversation: any, userId: string) {
  if (conversation.type === "external_sms" || conversation.type === "external_email") {
    const targetValue = decryptExternalConversationTarget(conversation);
    const target = conversation.type === "external_sms"
      ? normalizePhoneNumber(targetValue ?? "")
      : normalizeEmail(targetValue ?? "");
    const displayTarget = target ?? String(targetValue ?? "External line");
    const lastMessage = conversation.messages?.[0] ? mapMessage(conversation.messages[0]) : null;
    return {
      id: conversation.id,
      type: conversation.type,
      title: displayTarget,
      peer: {
        id: conversation.id,
        displayName: displayTarget,
        handle: conversation.type === "external_sms" ? "External SMS" : "External Email",
      },
      lastMessage,
      unreadCount: 0,
      privacy: mapConversationPrivacy(conversation),
      updatedAt: conversation.updatedAt.toISOString(),
    };
  }

  const peer = conversation.participants.find((participant: any) => participant.userId !== userId)
    ?? conversation.participants[0];
  if (!peer) return null;

  const identity = peer.user.identity ?? await loadPublicIdentity(peer.userId);
  const lastMessage = conversation.messages?.[0] ? mapMessage(conversation.messages[0]) : null;
  const unreadCount = await prisma.messageReceipt.count({
    where: {
      userId,
      status: { not: "read" },
      message: {
        conversationId: conversation.id,
        senderId: { not: userId },
      },
    },
  });

  return {
    id: conversation.id,
    type: conversation.type,
    title: conversation.title,
    peer: {
      id: peer.userId,
      displayName: identity.displayName ?? peer.user.displayName,
      handle: identity.onewayId ?? peer.userId,
    },
    lastMessage,
    unreadCount,
    privacy: mapConversationPrivacy(conversation),
    updatedAt: conversation.updatedAt.toISOString(),
  };
}

function mapMessage(message: any) {
  const payload = decodePayload(message.ciphertext, message.conversationId);
  const isTombstone = Boolean(message.deletedAt || payload.tombstone);
  return {
    id: message.id,
    conversationId: message.conversationId,
    senderId: message.senderId,
    body: isTombstone ? "" : payload.body,
    attachment: isTombstone ? null : payload.attachment ?? null,
    replyToMessageId: isTombstone ? null : payload.replyToMessageId ?? null,
    editedAt: payload.editedAt ?? null,
    external: isTombstone ? null : payload.external ?? null,
    isSystemNotice: payload.systemNotice ?? false,
    expirationMode: message.expirationMode ?? "off",
    expirationDurationSeconds: message.expirationDurationSeconds ?? null,
    readAt: message.readAt?.toISOString() ?? null,
    expiresAt: message.expiresAt?.toISOString() ?? null,
    deletedAt: message.deletedAt?.toISOString() ?? null,
    deletionReason: message.deletionReason ?? null,
    tombstoneVersion: message.tombstoneVersion ?? payload.tombstone?.version ?? 0,
    attachmentExpirationState: message.attachmentExpirationState ?? "none",
    isTombstone,
    createdAt: message.createdAt.toISOString(),
    updatedAt: message.updatedAt.toISOString(),
  };
}

function encodePayload(payload: StoredPayload, conversationId: string): string {
  const encoded: StoredPayload = {
    ...payload,
    body: encryptIfEnabled(payload.body, messageEncryptionContext(conversationId, "body")),
    attachment: payload.attachment
      ? {
          ...payload.attachment,
          fileName: encryptIfEnabled(payload.attachment.fileName, messageEncryptionContext(conversationId, "attachment.fileName")),
          payloadBase64: encryptIfEnabled(payload.attachment.payloadBase64, messageEncryptionContext(conversationId, "attachment.payloadBase64")),
        }
      : payload.attachment ?? null,
    external: payload.external
      ? {
          ...payload.external,
          phoneNumber: payload.external.phoneNumber
            ? encryptIfEnabled(payload.external.phoneNumber, messageEncryptionContext(conversationId, "external.phoneNumber"))
            : payload.external.phoneNumber ?? null,
          email: payload.external.email
            ? encryptIfEnabled(payload.external.email, messageEncryptionContext(conversationId, "external.email"))
            : payload.external.email ?? null,
        }
      : payload.external ?? null,
  };
  return JSON.stringify(encoded);
}

function decodePayload(ciphertext: string, conversationId?: string): StoredPayload {
  try {
    const parsed = JSON.parse(ciphertext) as StoredPayload;
    return {
      body: typeof parsed.body === "string" ? decryptMessageField(conversationId, "body", parsed.body) : "",
      attachment: parsed.attachment
        ? {
            ...parsed.attachment,
            fileName: decryptMessageField(conversationId, "attachment.fileName", parsed.attachment.fileName),
            payloadBase64: decryptMessageField(conversationId, "attachment.payloadBase64", parsed.attachment.payloadBase64),
          }
        : parsed.attachment ?? null,
      replyToMessageId: parsed.replyToMessageId ?? null,
      editedAt: parsed.editedAt ?? null,
      systemNotice: parsed.systemNotice ?? false,
      tombstone: parsed.tombstone ?? null,
      external: parsed.external
        ? {
            ...parsed.external,
            phoneNumber: parsed.external.phoneNumber
              ? decryptMessageField(conversationId, "external.phoneNumber", parsed.external.phoneNumber)
              : parsed.external.phoneNumber ?? null,
            email: parsed.external.email
              ? decryptMessageField(conversationId, "external.email", parsed.external.email)
              : parsed.external.email ?? null,
          }
        : parsed.external ?? null,
    };
  } catch {
    return { body: ciphertext };
  }
}

function messageEncryptionContext(conversationId: string, field: string): string {
  return `message:${conversationId}:${field}`;
}

function decryptMessageField(conversationId: string | undefined, field: string, value: string): string {
  if (!conversationId) return value;
  return decryptIfEncrypted(value, messageEncryptionContext(conversationId, field));
}

function clampNumber(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return max;
  return Math.max(min, Math.min(max, Math.floor(value)));
}

function normalizePhoneNumber(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  const hadPlus = trimmed.startsWith("+");
  const digits = trimmed.replace(/\D/g, "");
  if (digits.length < 7 || digits.length > 15) return null;

  if (hadPlus) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return `+${digits}`;
}

function normalizeEmail(raw: string): string | null {
  const trimmed = raw.trim().toLowerCase();
  if (trimmed.length < 3 || trimmed.length > 254) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed)) return null;
  return trimmed;
}

function resolveExternalTarget(input: {
  phoneNumber?: string;
  email?: string;
  toPhoneNumber?: string;
  toEmail?: string;
  target?: string;
}): { kind: "phone" | "email"; value: string } | null {
  const email = normalizeEmail(input.email ?? input.toEmail ?? input.target ?? "");
  if (email) return { kind: "email", value: email };

  const phone = normalizePhoneNumber(input.phoneNumber ?? input.toPhoneNumber ?? input.target ?? "");
  if (phone) return { kind: "phone", value: phone };

  return null;
}

async function resolveSenderOneWayNumber(userId: string, requested?: string): Promise<string | undefined> {
  if (requested) {
    const normalized = requested.trim();
    const owned = await prisma.userNumber.findFirst({
      where: {
        userId,
        number: normalized,
      },
      select: { number: true },
    });
    return owned?.number;
  }

  const primary = await prisma.userNumber.findFirst({
    where: { userId },
    orderBy: [
      { isPrimary: "desc" },
      { createdAt: "asc" },
    ],
    select: { number: true },
  });
  return primary?.number;
}

function checkSMSRateLimit(userId: string): { ok: true } | { ok: false; retryAfterSeconds: number } {
  const now = Date.now();
  const minuteMs = 60_000;
  const hourMs = 60 * minuteMs;
  const current = smsRateLimits.get(userId) ?? {
    minuteStart: now,
    minuteCount: 0,
    hourStart: now,
    hourCount: 0,
  };

  if (now - current.minuteStart >= minuteMs) {
    current.minuteStart = now;
    current.minuteCount = 0;
  }
  if (now - current.hourStart >= hourMs) {
    current.hourStart = now;
    current.hourCount = 0;
  }

  current.minuteCount += 1;
  current.hourCount += 1;
  smsRateLimits.set(userId, current);

  if (current.minuteCount > 10) {
    return { ok: false, retryAfterSeconds: Math.ceil((current.minuteStart + minuteMs - now) / 1000) };
  }
  if (current.hourCount > 100) {
    return { ok: false, retryAfterSeconds: Math.ceil((current.hourStart + hourMs - now) / 1000) };
  }
  return { ok: true };
}

const SMS_REGISTRATION_REQUIRED_MESSAGE = "Your Twilio number is SMS-capable, but US carriers require A2P 10DLC approval before app-sent texts can deliver from a +1 long-code number. Complete Twilio A2P registration, attach this number to the approved Messaging Service, then set TWILIO_MESSAGING_SERVICE_SID=MG..., or use a verified toll-free/short-code sender.";
const SMS_A2P_CAMPAIGN_NOT_READY_MESSAGE = "OneWay Messaging is connected and your Twilio number is attached, but Twilio has not verified an A2P 10DLC campaign for this Messaging Service yet. In Twilio Console, finish A2P registration until the Campaign Use Case status is Verified.";
function isRawUSLongCode(value: string): boolean {
  return /^\+1\d{10}$/.test(value.trim());
}

function isSMSRegistrationRequiredMessage(message?: string): boolean {
  const normalized = message?.toLowerCase() ?? "";
  return normalized.includes("a2p")
    || normalized.includes("10dlc")
    || normalized.includes("registered twilio messaging service")
    || normalized.includes("unregistered us");
}

async function buildSMSPreflight() {
  const provider = smsProvider.name;
  const missing: string[] = [];
  const warnings: string[] = [];
  let registrationRequired = false;
  let setupRequiredReason: string | undefined;
  let a2pCampaignStatus: string | null = null;

  if (provider === "twilio") {
    if (!process.env.TWILIO_ACCOUNT_SID?.trim()) missing.push("TWILIO_ACCOUNT_SID");
    if (!process.env.TWILIO_AUTH_TOKEN?.trim()) missing.push("TWILIO_AUTH_TOKEN");
    if (!process.env.TWILIO_MESSAGING_SERVICE_SID?.trim()
      && !process.env.SMS_FROM_NUMBER?.trim()
      && !process.env.TWILIO_FROM_NUMBER?.trim()
      && !process.env.PSTN_FROM_NUMBER?.trim()) {
      missing.push("TWILIO_MESSAGING_SERVICE_SID or SMS_FROM_NUMBER");
    }
    const rawSender = process.env.SMS_FROM_NUMBER?.trim()
      || process.env.TWILIO_FROM_NUMBER?.trim()
      || process.env.PSTN_FROM_NUMBER?.trim()
      || "";
    const messagingServiceSid = process.env.TWILIO_MESSAGING_SERVICE_SID?.trim() ?? "";
    if (!messagingServiceSid && isRawUSLongCode(rawSender)) {
      registrationRequired = true;
      setupRequiredReason = SMS_REGISTRATION_REQUIRED_MESSAGE;
      warnings.push("This Twilio number is SMS-capable, but US carrier delivery from app-sent +1 long-code traffic requires A2P 10DLC registration and an approved Messaging Service sender pool.");
    }
    if (messagingServiceSid && missing.length === 0) {
      const campaign = await resolveTwilioCampaignStatus(messagingServiceSid);
      a2pCampaignStatus = campaign.campaignStatus ?? null;
      if (campaign.campaignStatus !== "VERIFIED") {
        registrationRequired = true;
        setupRequiredReason = campaign.campaignStatus
          ? `${SMS_A2P_CAMPAIGN_NOT_READY_MESSAGE} Current Twilio campaign status: ${campaign.campaignStatus}.`
          : SMS_A2P_CAMPAIGN_NOT_READY_MESSAGE;
        warnings.push(campaign.error === "campaign_not_found"
          ? "No Twilio A2P 10DLC campaign is attached to this Messaging Service yet."
          : `Twilio A2P 10DLC campaign status is ${campaign.campaignStatus ?? "unknown"}.`);
      }
    }
  }

  if (provider === "telnyx") {
    if (!process.env.TELNYX_API_KEY?.trim()) missing.push("TELNYX_API_KEY");
    if (!process.env.TELNYX_MESSAGING_PROFILE_ID?.trim()
      && !process.env.TELNYX_MESSAGING_FROM_NUMBER?.trim()
      && !process.env.SMS_FROM_NUMBER?.trim()
      && !process.env.TELNYX_FROM_NUMBER?.trim()
      && !process.env.PSTN_FROM_NUMBER?.trim()) {
      missing.push("TELNYX_MESSAGING_PROFILE_ID or TELNYX_MESSAGING_FROM_NUMBER");
    }
  }

  if (provider === "sinch") {
    if (!process.env.SINCH_SERVICE_PLAN_ID?.trim()) missing.push("SINCH_SERVICE_PLAN_ID");
    if (!process.env.SINCH_API_TOKEN?.trim()) missing.push("SINCH_API_TOKEN");
    if (!process.env.SINCH_SMS_FROM_NUMBER?.trim()
      && !process.env.SMS_FROM_NUMBER?.trim()
      && !process.env.SINCH_FROM_NUMBER?.trim()
      && !process.env.PSTN_FROM_NUMBER?.trim()) {
      missing.push("SINCH_SMS_FROM_NUMBER or SMS_FROM_NUMBER");
    }
  }

  if (provider !== "stub" && !process.env.SMS_WEBHOOK_BASE_URL?.trim() && !process.env.PSTN_WEBHOOK_BASE_URL?.trim()) {
    warnings.push("Set SMS_WEBHOOK_BASE_URL to receive provider delivery callbacks and inbound SMS replies.");
  }
  if (provider === "twilio" && process.env.NODE_ENV === "production" && !process.env.TWILIO_AUTH_TOKEN?.trim()) {
    warnings.push("Set TWILIO_AUTH_TOKEN so inbound and status webhook signatures can be validated.");
  } else if (provider !== "stub" && provider !== "twilio" && process.env.NODE_ENV === "production" && !process.env.SMS_WEBHOOK_SECRET?.trim()) {
    warnings.push("Set SMS_WEBHOOK_SECRET before enabling public inbound/status webhook URLs in production.");
  }

  const providerConfigured = provider === "stub" || missing.length === 0;
  const ok = providerConfigured && !registrationRequired;
  return {
    ok,
    provider,
    mode: provider === "stub" ? "stub" : registrationRequired ? "registration_required" : providerConfigured ? "live" : "not_configured",
    providerConfigured,
    fromNumberConfigured: provider === "stub" || !missing.some((item) => item.includes("FROM_NUMBER") || item.includes("MESSAGING")),
    webhookBaseUrlConfigured: Boolean(process.env.SMS_WEBHOOK_BASE_URL?.trim() || process.env.PSTN_WEBHOOK_BASE_URL?.trim()),
    registrationRequired,
    setupRequiredReason,
    a2pCampaignStatus,
    missing,
    warnings,
  };
}

function buildEmailPreflight() {
  const provider = emailProvider.name;
  const missing: string[] = [];
  const warnings: string[] = [];

  if (provider === "sendgrid") {
    if (!process.env.SENDGRID_API_KEY?.trim()) missing.push("SENDGRID_API_KEY");
    if (!process.env.EMAIL_FROM_ADDRESS?.trim()
      && !process.env.EMAIL_FROM?.trim()
      && !process.env.SENDGRID_FROM_EMAIL?.trim()) {
      missing.push("EMAIL_FROM_ADDRESS or SENDGRID_FROM_EMAIL");
    }
  }

  if (provider === "stub") {
    warnings.push("Email bridge is in stub mode. Configure SendGrid to deliver real email.");
  }

  const providerConfigured = provider === "stub" || missing.length === 0;
  return {
    ok: providerConfigured,
    provider,
    mode: provider === "stub" ? "stub" : providerConfigured ? "live" : "not_configured",
    providerConfigured,
    fromAddressConfigured: provider === "stub" || !missing.some((item) => item.includes("EMAIL_FROM")),
    missing,
    warnings,
  };
}

function verifySMSWebhookAccess(req: express.Request): boolean {
  const secret = process.env.SMS_WEBHOOK_SECRET?.trim() ?? "";
  if (!secret) {
    return process.env.NODE_ENV !== "production";
  }
  const received = String(req.query.secret ?? req.body?.secret ?? "");
  return received === secret;
}

async function storeInboundExternalMessage(input: {
  provider: SMSProviderName;
  providerMessageId: string;
  fromPhoneNumber: string;
  toPhoneNumber: string;
  body: string;
}): Promise<{ ownerUserId: string; message: Awaited<ReturnType<typeof prisma.message.create>> } | null> {
  const owner = await prisma.userNumber.findUnique({
    where: { number: input.toPhoneNumber },
    select: { userId: true },
  });

  if (!owner) {
    logger.warn({
      toPhoneNumber: input.toPhoneNumber,
      fromPhoneNumber: input.fromPhoneNumber,
      provider: input.provider,
    }, "[sms] inbound message dropped because no OneWay number owner was found");
    return null;
  }

  const conversation = await findOrCreateExternalSMSConversation(owner.userId, input.fromPhoneNumber);
  const payload: StoredPayload = {
    body: input.body.trim(),
    attachment: null,
    replyToMessageId: null,
    external: {
      networkType: "smsBridge",
      phoneNumber: input.fromPhoneNumber,
      provider: input.provider,
      providerMessageId: input.providerMessageId || null,
      providerStatus: "received",
      direction: "incoming",
    },
  };

  const message = await prisma.message.create({
    data: {
      conversationId: conversation.id,
      senderId: `external:${input.fromPhoneNumber}`,
      ciphertext: encodePayload(payload, conversation.id),
    },
  });
  await prisma.conversation.update({
    where: { id: conversation.id },
    data: { updatedAt: new Date() },
  });
  return { ownerUserId: owner.userId, message };
}

async function updateExternalMessageStatus(input: {
  providerMessageId: string;
  providerStatus: string;
  failureReason?: string;
}, realtime?: MessageRealtimeServer) {
  if (!input.providerMessageId || !input.providerStatus) return;

  const messages = await prisma.message.findMany({
    where: {
      ciphertext: {
        contains: input.providerMessageId,
      },
    },
    take: 10,
  });

  for (const message of messages) {
    const payload = decodePayload(message.ciphertext, message.conversationId);
    if (payload.external?.providerMessageId !== input.providerMessageId) continue;

    const blocked = smsDeliveryFailureMessage("twilio", input.failureReason);
    if (blocked && !payload.body.includes(blocked)) {
      payload.body = `${payload.body}\n\n[Delivery failed: ${blocked}]`;
    }

    const now = new Date();
    const normalizedStatus = normalizeSMSDeliveryStatus(input.providerStatus);
    payload.external.providerStatus = normalizedStatus;
    payload.external.failureReason = blocked ?? input.failureReason ?? payload.external.failureReason ?? null;
    if (normalizedStatus === "sent" && !payload.external.sentAt) {
      payload.external.sentAt = now.toISOString();
    }
    if (normalizedStatus === "delivered" && !payload.external.deliveredAt) {
      payload.external.deliveredAt = now.toISOString();
    }
    if ((normalizedStatus === "failed" || normalizedStatus === "undelivered") && !payload.external.failureReason) {
      payload.external.failureReason = "Carrier delivery failed.";
    }
    if (payload.external.queuedAt) {
      const queuedMs = Date.parse(payload.external.queuedAt);
      if (Number.isFinite(queuedMs)) payload.external.latencyMs = Date.now() - queuedMs;
    }

    const updated = await prisma.message.update({
      where: { id: message.id },
      data: { ciphertext: encodePayload(payload, message.conversationId) },
    });
    const participants = await prisma.conversationParticipant.findMany({
      where: { conversationId: message.conversationId },
      select: { userId: true },
    });
    realtime?.broadcastMessageUpdated(participants.map((participant) => participant.userId), mapMessage(updated));
  }
}

export async function applyTwilioDeliveryCallback(input: {
  providerMessageId: string;
  providerStatus: string;
  failureReason?: string;
}, realtime?: MessageRealtimeServer): Promise<void> {
  if (!input.providerMessageId) return;
  await updateExternalMessageStatus(input, realtime);
}
