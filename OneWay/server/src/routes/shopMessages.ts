import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";

import { prisma as defaultPrisma } from "../lib/db";
import { logger } from "../lib/logger";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";

const conversationTypes = [
  "generalShopQuestion",
  "productQuestion",
  "productInquiry",
  "orderSupport",
  "orderConversation",
  "customRequest",
  "shipping",
  "returnOrRefund",
] as const;

const conversationCreateSchema = z.object({
  shopId: z.string().trim().min(1),
  sellerUserId: z.string().trim().min(1).optional(),
  productId: z.string().trim().min(1).nullable().optional(),
  orderId: z.string().trim().min(1).nullable().optional(),
  customRequestId: z.string().trim().min(1).nullable().optional(),
  type: z.enum(conversationTypes).default("generalShopQuestion"),
});

const sendSchema = z.object({
  encryptedPayload: z.string().trim().min(1).max(12_000),
  recipientUserId: z.string().trim().min(1),
  messageType: z.enum(["userMessage", "orderSystemUpdate", "platformSupportMessage"]).default("userMessage"),
  attachmentMetadata: z.string().trim().max(24_000).nullable().optional(),
  clientMessageId: z.string().trim().min(8).max(128).optional(),
});

const settingsSchema = z.object({
  sellerPermission: z.string().trim().min(1).default("Anyone"),
  buyerPermission: z.string().trim().min(1).default("Sellers I contacted"),
  allowProductQuestions: z.boolean().default(true),
  allowCustomRequests: z.boolean().default(true),
  allowOrderOnlyMessages: z.boolean().default(true),
  allowPromotionalMessages: z.boolean().default(false),
  allowMessagesFromNewAccounts: z.boolean().default(true),
  sellerAllowAttachments: z.boolean().default(true),
  sellerAllowLinks: z.boolean().default(false),
  autoCloseInactive: z.boolean().default(false),
  requireOrderNumberForSupport: z.boolean().default(false),
  buyerAllowAttachments: z.boolean().default(true),
  buyerAllowLinks: z.boolean().default(false),
  showReadReceipts: z.boolean().default(false),
  showTypingIndicator: z.boolean().default(true),
  showActivityStatus: z.boolean().default(false),
});

type ShopMessagesDeps = {
  prisma?: any;
};

export function shopMessagesRouter(deps: ShopMessagesDeps = {}): express.Router {
  const db = deps.prisma ?? defaultPrisma;
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/conversations", async (req, res) => {
    const userId = currentUserId(req);
    const conversations = await db.shopConversation.findMany({
      where: {
        OR: [{ buyerId: userId }, { sellerId: userId }],
      },
      orderBy: [{ lastMessageAt: "desc" }, { updatedAt: "desc" }],
      take: 100,
    });
    res.json({
      conversations: conversations
        .filter((conversation: any) => !jsonArray(conversation.deletedByJson).includes(userId))
        .map(mapConversation),
    });
  });

  router.post("/conversations", async (req, res) => {
    const started = Date.now();
    const userId = currentUserId(req);
    const parsed = conversationCreateSchema.safeParse(req.body);
    logger.info({ event: "SHOP_MESSAGE_CONVERSATION_CREATE_REQUESTED", userId: redact(userId) }, "[shops:messages]");
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const sellerUserId = parsed.data.sellerUserId ?? `seller:${parsed.data.shopId}`;
    if (await isBlocked(db, userId, sellerUserId) || await isBlocked(db, sellerUserId, userId)) {
      logger.warn({ event: "SHOP_MESSAGE_PERMISSION_DENIED", errorCode: "blocked_by_recipient" }, "[shops:messages]");
      res.status(403).json({ error: "blocked_by_recipient" });
      return;
    }

    const type = normalizeConversationType(parsed.data.type);
    const existing = await db.shopConversation.findFirst({
      where: {
        shopId: parsed.data.shopId,
        buyerId: userId,
        sellerId: sellerUserId,
        productId: parsed.data.productId ?? null,
        orderId: parsed.data.orderId ?? null,
        customRequestId: parsed.data.customRequestId ?? null,
        conversationType: type,
        status: { in: ["open", "resolved"] },
      },
    });
    if (existing) {
      res.json({ conversation: mapConversation(existing) });
      return;
    }

    const conversation = await db.shopConversation.create({
      data: {
        shopId: parsed.data.shopId,
        buyerId: userId,
        sellerId: sellerUserId,
        productId: parsed.data.productId ?? null,
        orderId: parsed.data.orderId ?? null,
        customRequestId: parsed.data.customRequestId ?? null,
        conversationType: type,
        status: "open",
      },
    });
    logger.info({
      event: "SHOP_MESSAGE_CONVERSATION_CREATED",
      conversationId: conversation.id,
      shopId: conversation.shopId,
      productId: conversation.productId,
      orderId: conversation.orderId,
      duration: Date.now() - started,
    }, "[shops:messages]");
    res.status(201).json({ conversation: mapConversation(conversation) });
  });

  router.get("/conversations/:conversationId", async (req, res) => {
    const userId = currentUserId(req);
    const conversation = await findAuthorizedConversation(db, param(req.params.conversationId), userId);
    if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
    const shopMessages = await db.shopMessage.findMany({
      where: { conversationId: conversation.id },
      orderBy: { createdAt: "asc" },
      take: 500,
    });
    res.json({
      conversation: mapConversation(conversation),
      messages: shopMessages.map(mapMessage),
    });
  });

  router.post("/conversations/:conversationId/messages", async (req, res) => {
    const userId = currentUserId(req);
    const conversationId = param(req.params.conversationId);
    const parsed = sendSchema.safeParse(req.body);
    logger.info({ event: "SHOP_MESSAGE_SEND_REQUESTED", conversationId }, "[shops:messages]");
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });

    const conversation = await findAuthorizedConversation(db, conversationId, userId);
    if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
    if (conversation.status === "blocked" && parsed.data.messageType === "userMessage") {
      return res.status(403).json({ error: "blocked_by_recipient" });
    }

    const clientMessageId = parsed.data.clientMessageId ?? randomUUID();
    const existing = await db.shopMessage.findFirst({
      where: { conversationId: conversation.id, clientMessageId },
    });
    if (existing) return res.status(200).json({ message: mapMessage(existing), duplicate: true });

    const senderRole = conversation.sellerId === userId ? "seller" : "buyer";
    const message = await db.$transaction(async (tx: any) => {
      const created = await tx.shopMessage.create({
        data: {
          conversationId: conversation.id,
          senderId: userId,
          senderRole,
          recipientId: parsed.data.recipientUserId,
          bodyEncrypted: parsed.data.encryptedPayload,
          messageType: parsed.data.messageType,
          attachmentMetadata: parsed.data.attachmentMetadata ?? null,
          clientMessageId,
        },
      });
      await tx.shopConversation.update({
        where: { id: conversation.id },
        data: {
          updatedAt: new Date(),
          lastMessageAt: created.createdAt,
          status: conversation.status === "closed" ? "open" : conversation.status,
        },
      });
      return created;
    });

    logger.info({
      event: "SHOP_MESSAGE_SENT",
      topic: `shop:conversation:${conversation.id}`,
      realtimeEvent: "shop.message.created",
      conversationId: conversation.id,
      messageId: message.id,
    }, "[shops:messages]");
    res.status(201).json({ message: mapMessage(message) });
  });

  router.patch("/conversations/:conversationId/read", async (req, res) => {
    const userId = currentUserId(req);
    const conversation = await findAuthorizedConversation(db, param(req.params.conversationId), userId);
    if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
    const lastMessage = await db.shopMessage.findFirst({
      where: { conversationId: conversation.id },
      orderBy: { createdAt: "desc" },
    });
    await db.shopConversationRead.upsert({
      where: { conversationId_userId: { conversationId: conversation.id, userId } },
      create: {
        conversationId: conversation.id,
        userId,
        lastReadMessageId: lastMessage?.id ?? null,
      },
      update: {
        lastReadMessageId: lastMessage?.id ?? null,
        lastReadAt: new Date(),
      },
    });
    logger.info({ event: "SHOP_MESSAGE_READ", conversationId: conversation.id }, "[shops:messages]");
    res.json({ ok: true });
  });

  router.patch("/conversations/:conversationId/mute", (req, res) =>
    updateConversationList(db, req, res, "SHOP_MESSAGE_CONVERSATION_MUTED", "mutedByJson", toggleValue)
  );
  router.patch("/conversations/:conversationId/archive", (req, res) =>
    updateConversationList(db, req, res, "SHOP_MESSAGE_CONVERSATION_ARCHIVED", "archivedByJson", addValue)
  );
  router.delete("/conversations/:conversationId", (req, res) =>
    updateConversationList(db, req, res, "SHOP_MESSAGE_CONVERSATION_DELETED", "deletedByJson", addValue)
  );
  router.post("/conversations/:conversationId/close", async (req, res) => {
    const userId = currentUserId(req);
    const conversation = await findAuthorizedConversation(db, param(req.params.conversationId), userId);
    if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
    const updated = await db.shopConversation.update({
      where: { id: conversation.id },
      data: { status: "closed", closedAt: new Date() },
    });
    res.json({ conversation: mapConversation(updated) });
  });
  router.post("/conversations/:conversationId/block", async (req, res) => {
    const userId = currentUserId(req);
    const conversation = await findAuthorizedConversation(db, param(req.params.conversationId), userId);
    if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
    const target = conversation.buyerId === userId ? conversation.sellerId : conversation.buyerId;
    await db.shopBlockedUser.upsert({
      where: { userId_blockedUserId: { userId, blockedUserId: target } },
      create: { userId, blockedUserId: target, scope: "shop" },
      update: { scope: "shop", blockedAt: new Date() },
    });
    const updated = await db.shopConversation.update({
      where: { id: conversation.id },
      data: { status: "blocked" },
    });
    res.json({ conversation: mapConversation(updated) });
  });

  router.post("/users/:userId/block", async (req, res) => {
    const userId = currentUserId(req);
    const target = param(req.params.userId);
    await db.shopBlockedUser.upsert({
      where: { userId_blockedUserId: { userId, blockedUserId: target } },
      create: { userId, blockedUserId: target, scope: "shop" },
      update: { scope: "shop", blockedAt: new Date() },
    });
    logger.info({ event: "SHOP_MESSAGE_USER_BLOCKED", userId: redact(userId), target: redact(target) }, "[shops:messages]");
    res.status(201).json({ blocked: await blockedForUser(db, userId) });
  });

  router.delete("/users/:userId/block", async (req, res) => {
    const userId = currentUserId(req);
    await db.shopBlockedUser.deleteMany({ where: { userId, blockedUserId: param(req.params.userId) } });
    res.status(204).end();
  });

  router.get("/blocked", async (req, res) => {
    res.json({ blocked: await blockedForUser(db, currentUserId(req)) });
  });

  router.get("/settings", async (req, res) => {
    res.json({ settings: mapSettings(await settingsFor(db, currentUserId(req))) });
  });

  router.patch("/settings", async (req, res) => {
    const userId = currentUserId(req);
    const parsed = settingsSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const settings = await db.shopMessageSettings.upsert({
      where: { userId },
      create: { userId, ...parsed.data },
      update: parsed.data,
    });
    res.json({ settings: mapSettings(settings) });
  });

  router.post("/conversations/:conversationId/report", async (req, res) => {
    const userId = currentUserId(req);
    const conversation = await findAuthorizedConversation(db, param(req.params.conversationId), userId);
    if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
    logger.info({ event: "SHOP_MESSAGE_REPORT_SUBMITTED", conversationId: conversation.id, reason: String(req.body?.reason ?? "other") }, "[shops:messages]");
    res.status(201).json({ ok: true });
  });

  return router;
}

async function updateConversationList(
  db: any,
  req: express.Request,
  res: express.Response,
  event: string,
  field: "mutedByJson" | "archivedByJson" | "deletedByJson",
  mutate: (values: string[], value: string) => string[]
) {
  const userId = currentUserId(req);
  const conversation = await findAuthorizedConversation(db, param(req.params.conversationId), userId);
  if (!conversation) return res.status(404).json({ error: "conversation_not_found" });
  const values = mutate(jsonArray(conversation[field]), userId);
  const updated = await db.shopConversation.update({
    where: { id: conversation.id },
    data: { [field]: JSON.stringify(values) },
  });
  logger.info({ event, conversationId: conversation.id }, "[shops:messages]");
  res.json({ conversation: mapConversation(updated) });
}

async function findAuthorizedConversation(db: any, conversationId: string, userId: string) {
  return db.shopConversation.findFirst({
    where: {
      id: conversationId,
      OR: [{ buyerId: userId }, { sellerId: userId }],
    },
  });
}

async function isBlocked(db: any, userId: string, target: string): Promise<boolean> {
  const count = await db.shopBlockedUser.count({ where: { userId, blockedUserId: target } });
  return count > 0;
}

async function blockedForUser(db: any, userId: string) {
  const blocked = await db.shopBlockedUser.findMany({
    where: { userId },
    orderBy: { blockedAt: "desc" },
  });
  return blocked.map((entry: any) => ({
    userId: entry.userId,
    blockedUserId: entry.blockedUserId,
    scope: entry.scope,
    blockedAt: toIso(entry.blockedAt),
  }));
}

async function settingsFor(db: any, userId: string) {
  return db.shopMessageSettings.findUnique({ where: { userId } }) ?? defaultSettings(userId);
}

function defaultSettings(userId: string) {
  return {
    userId,
    sellerPermission: "Anyone",
    buyerPermission: "Sellers I contacted",
    allowProductQuestions: true,
    allowCustomRequests: true,
    allowOrderOnlyMessages: true,
    allowPromotionalMessages: false,
    allowMessagesFromNewAccounts: true,
    sellerAllowAttachments: true,
    sellerAllowLinks: false,
    autoCloseInactive: false,
    requireOrderNumberForSupport: false,
    buyerAllowAttachments: true,
    buyerAllowLinks: false,
    showReadReceipts: false,
    showTypingIndicator: true,
    showActivityStatus: false,
  };
}

function currentUserId(req: express.Request): string {
  return (req as AuthenticatedRequest).userId;
}

function param(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

function normalizeConversationType(type: string): string {
  switch (type) {
    case "productInquiry":
      return "productQuestion";
    case "orderConversation":
      return "orderSupport";
    default:
      return type;
  }
}

function legacyConversationType(type: string): string {
  switch (type) {
    case "productQuestion":
      return "productInquiry";
    case "orderSupport":
      return "orderConversation";
    default:
      return type;
  }
}

function mapConversation(conversation: any) {
  return {
    id: conversation.id,
    shopId: conversation.shopId,
    buyerUserId: conversation.buyerId,
    sellerUserId: conversation.sellerId,
    productId: conversation.productId,
    orderId: conversation.orderId,
    customRequestId: conversation.customRequestId,
    type: legacyConversationType(conversation.conversationType),
    conversationType: conversation.conversationType,
    state: conversation.status,
    status: conversation.status,
    mutedBy: jsonArray(conversation.mutedByJson),
    archivedBy: jsonArray(conversation.archivedByJson),
    deletedBy: jsonArray(conversation.deletedByJson),
    createdAt: toIso(conversation.createdAt),
    updatedAt: toIso(conversation.updatedAt),
    lastMessageAt: toIso(conversation.lastMessageAt),
    closedAt: conversation.closedAt ? toIso(conversation.closedAt) : null,
  };
}

function mapMessage(message: any) {
  return {
    id: message.id,
    conversationId: message.conversationId,
    senderUserId: message.senderId,
    senderRole: message.senderRole,
    recipientUserId: message.recipientId,
    encryptedPayload: message.bodyEncrypted,
    messageType: message.messageType,
    attachmentMetadata: message.attachmentMetadata,
    clientMessageId: message.clientMessageId,
    sentAt: toIso(message.createdAt),
    createdAt: toIso(message.createdAt),
    editedAt: message.editedAt ? toIso(message.editedAt) : null,
    deletedAt: message.deletedAt ? toIso(message.deletedAt) : null,
  };
}

function mapSettings(settings: any) {
  return {
    sellerPermission: settings.sellerPermission,
    buyerPermission: settings.buyerPermission,
    allowProductQuestions: settings.allowProductQuestions,
    allowCustomRequests: settings.allowCustomRequests,
    allowOrderOnlyMessages: settings.allowOrderOnlyMessages,
    allowPromotionalMessages: settings.allowPromotionalMessages,
    allowMessagesFromNewAccounts: settings.allowMessagesFromNewAccounts,
    sellerAllowAttachments: settings.sellerAllowAttachments,
    sellerAllowLinks: settings.sellerAllowLinks,
    autoCloseInactive: settings.autoCloseInactive,
    requireOrderNumberForSupport: settings.requireOrderNumberForSupport,
    buyerAllowAttachments: settings.buyerAllowAttachments,
    buyerAllowLinks: settings.buyerAllowLinks,
    showReadReceipts: settings.showReadReceipts,
    showTypingIndicator: settings.showTypingIndicator,
    showActivityStatus: settings.showActivityStatus,
  };
}

function jsonArray(value: string | null | undefined): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item) => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function addValue(values: string[], value: string): string[] {
  return values.includes(value) ? values : [...values, value];
}

function toggleValue(values: string[], value: string): string[] {
  return values.includes(value) ? values.filter((item) => item !== value) : [...values, value];
}

function toIso(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function redact(value: string): string {
  return value.length <= 8 ? "redacted" : `${value.slice(0, 4)}…${value.slice(-4)}`;
}
