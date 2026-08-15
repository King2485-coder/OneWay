import type { PrismaClient } from "@prisma/client";
import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { buildPlatformReadinessPayload } from "../services/platformCapabilities";

const privacySchema = z.record(z.union([z.string(), z.boolean(), z.number()]));
const aiLogSchema = z.object({
  action: z.string().trim().min(1).max(120),
  contentScope: z.string().trim().min(1).max(120).default("manual"),
  requiresDecryptedContent: z.boolean().default(false),
});
const cloudFileSchema = z.object({
  name: z.string().trim().min(1).max(180),
  mimeType: z.string().trim().max(120).optional().nullable(),
  byteCount: z.number().int().min(0).default(0),
  storageKey: z.string().trim().min(1).max(260).optional(),
});
const workspaceItemSchema = z.object({
  workspaceId: z.string().trim().min(1).max(120).default("personal"),
  type: z.string().trim().min(1).max(80),
  title: z.string().trim().min(1).max(180),
  status: z.string().trim().min(1).max(60).default("open"),
  metadataJson: z.string().max(4000).optional().nullable(),
});
const workspacePatchSchema = z.object({
  status: z.string().trim().min(1).max(60),
});
const channelPostSchema = z.object({
  channelId: z.string().trim().min(1).max(120).default("personal-channel"),
  body: z.string().trim().min(1).max(4000),
});
const scheduledMessageSchema = z.object({
  conversationId: z.string().trim().min(1).max(120).default("personal-draft"),
  body: z.string().trim().min(1).max(4000),
  scheduledFor: z.string().datetime().optional(),
});

export function platformRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();

  router.use(authMiddleware);

  router.get("/capabilities", (_req, res) => {
    res.json(buildPlatformReadinessPayload());
  });

  router.get("/privacy", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<Array<{ key: string; value: string; updatedAt: Date | string }>>(
      `SELECT "key", "value", "updatedAt" FROM "PrivacySetting" WHERE "userId" = ? ORDER BY "key" ASC`,
      userId,
    );
    res.json({ settings: rowsToPrivacySettings(rows), updatedAt: new Date().toISOString() });
  });

  router.put("/privacy", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = privacySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_privacy_settings", details: parsed.error.flatten() });
      return;
    }
    for (const [key, value] of Object.entries(parsed.data)) {
      await prisma.$executeRawUnsafe(
        `
        INSERT INTO "PrivacySetting" ("id", "userId", "key", "value", "updatedAt")
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT("userId", "key") DO UPDATE SET
          "value" = excluded."value",
          "updatedAt" = CURRENT_TIMESTAMP
        `,
        randomUUID(),
        userId,
        key,
        JSON.stringify(value),
      );
    }
    res.json({ ok: true, settings: parsed.data, updatedAt: new Date().toISOString() });
  });

  router.get("/ai/logs", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "action", "contentScope", "requiresDecryptedContent", "createdAt" FROM "AILog" WHERE "userId" = ? ORDER BY "createdAt" DESC LIMIT 50`,
      userId,
    );
    res.json({ logs: rows.map(mapAI) });
  });

  router.post("/ai/logs", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = aiLogSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_ai_log", details: parsed.error.flatten() });
      return;
    }
    const id = randomUUID();
    await prisma.$executeRawUnsafe(
      `INSERT INTO "AILog" ("id", "userId", "action", "contentScope", "requiresDecryptedContent", "createdAt") VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
      id,
      userId,
      parsed.data.action,
      parsed.data.contentScope,
      parsed.data.requiresDecryptedContent ? 1 : 0,
    );
    res.status(201).json({ log: { id, ...parsed.data, createdAt: new Date().toISOString() } });
  });

  router.get("/cloud/files", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "name", "mimeType", "byteCount", "storageKey", "encrypted", "createdAt", "updatedAt" FROM "CloudFile" WHERE "ownerId" = ? ORDER BY "updatedAt" DESC LIMIT 100`,
      userId,
    );
    res.json({ files: rows.map(mapCloudFile) });
  });

  router.post("/cloud/files", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = cloudFileSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_cloud_file", details: parsed.error.flatten() });
      return;
    }
    const id = randomUUID();
    const storageKey = parsed.data.storageKey ?? `cloud/${userId}/${id}`;
    await prisma.$executeRawUnsafe(
      `INSERT INTO "CloudFile" ("id", "ownerId", "name", "mimeType", "byteCount", "storageKey", "encrypted", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, ?, ?, true, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`,
      id,
      userId,
      parsed.data.name,
      parsed.data.mimeType ?? null,
      parsed.data.byteCount,
      storageKey,
    );
    res.status(201).json({ file: { id, ...parsed.data, storageKey, encrypted: true, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } });
  });

  router.get("/workspace/items", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const workspaceId = typeof req.query.workspaceId === "string" ? req.query.workspaceId : "personal";
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "workspaceId", "type", "title", "status", "metadataJson", "createdAt", "updatedAt" FROM "WorkspaceItem" WHERE "workspaceId" = ? OR "workspaceId" = ? ORDER BY "updatedAt" DESC LIMIT 100`,
      workspaceId,
      `${userId}:${workspaceId}`,
    );
    res.json({ items: rows.map(mapWorkspaceItem) });
  });

  router.post("/workspace/items", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = workspaceItemSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_workspace_item", details: parsed.error.flatten() });
      return;
    }
    const id = randomUUID();
    const workspaceId = `${userId}:${parsed.data.workspaceId}`;
    await prisma.$executeRawUnsafe(
      `INSERT INTO "WorkspaceItem" ("id", "workspaceId", "type", "title", "status", "metadataJson", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`,
      id,
      workspaceId,
      parsed.data.type,
      parsed.data.title,
      parsed.data.status,
      parsed.data.metadataJson ?? null,
    );
    res.status(201).json({ item: { id, ...parsed.data, workspaceId, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } });
  });

  router.patch("/workspace/items/:id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = workspacePatchSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_workspace_status", details: parsed.error.flatten() });
      return;
    }
    await prisma.$executeRawUnsafe(
      `UPDATE "WorkspaceItem" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "workspaceId" LIKE ?`,
      parsed.data.status,
      req.params.id,
      `${userId}:%`,
    );
    res.json({ ok: true, id: req.params.id, status: parsed.data.status });
  });

  router.get("/channels/posts", async (_req, res) => {
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "channelId", "authorId", "body", "reactionCount", "createdAt", "updatedAt" FROM "ChannelPost" ORDER BY "createdAt" DESC LIMIT 100`,
    );
    res.json({ posts: rows.map(mapChannelPost) });
  });

  router.post("/channels/posts", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = channelPostSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_channel_post", details: parsed.error.flatten() });
      return;
    }
    const id = randomUUID();
    await prisma.$executeRawUnsafe(
      `INSERT INTO "ChannelPost" ("id", "channelId", "authorId", "body", "reactionCount", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`,
      id,
      parsed.data.channelId,
      userId,
      parsed.data.body,
    );
    res.status(201).json({ post: { id, ...parsed.data, authorId: userId, reactionCount: 0, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } });
  });

  router.get("/messages/scheduled", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "conversationId", "senderId", "body", "scheduledFor", "status", "createdAt" FROM "ScheduledMessage" WHERE "senderId" = ? ORDER BY "scheduledFor" ASC LIMIT 100`,
      userId,
    );
    res.json({ messages: rows.map(mapScheduledMessage) });
  });

  router.post("/messages/scheduled", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = scheduledMessageSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_scheduled_message", details: parsed.error.flatten() });
      return;
    }
    const id = randomUUID();
    const scheduledFor = parsed.data.scheduledFor ?? new Date(Date.now() + 60 * 60 * 1000).toISOString();
    await prisma.$executeRawUnsafe(
      `INSERT INTO "ScheduledMessage" ("id", "conversationId", "senderId", "body", "scheduledFor", "status", "createdAt") VALUES (?, ?, ?, ?, ?, 'scheduled', CURRENT_TIMESTAMP)`,
      id,
      parsed.data.conversationId,
      userId,
      parsed.data.body,
      scheduledFor,
    );
    res.status(201).json({ message: { id, ...parsed.data, senderId: userId, scheduledFor, status: "scheduled", createdAt: new Date().toISOString() } });
  });

  return router;
}

function rowsToPrivacySettings(rows: Array<{ key: string; value: string }>): Record<string, unknown> {
  const defaults: Record<string, unknown> = {
    endToEndEncryptionEnabled: true,
    chatLockEnabled: false,
    hideOnlineStatus: false,
    hideLastSeen: true,
    hideReadReceipts: false,
    hideTypingIndicators: false,
    hidePhoneNumber: true,
    disappearingMessageTimer: "Off",
  };
  for (const row of rows) {
    try {
      defaults[row.key] = JSON.parse(row.value);
    } catch {
      defaults[row.key] = row.value;
    }
  }
  return defaults;
}

function iso(value: unknown): string {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string") return value;
  return new Date().toISOString();
}

function mapAI(row: any) {
  return {
    id: String(row.id),
    action: String(row.action),
    contentScope: String(row.contentScope),
    requiresDecryptedContent: Boolean(row.requiresDecryptedContent),
    createdAt: iso(row.createdAt),
  };
}

function mapCloudFile(row: any) {
  return {
    id: String(row.id),
    name: String(row.name),
    mimeType: row.mimeType ? String(row.mimeType) : null,
    byteCount: Number(row.byteCount ?? 0),
    storageKey: String(row.storageKey),
    encrypted: Boolean(row.encrypted),
    createdAt: iso(row.createdAt),
    updatedAt: iso(row.updatedAt),
  };
}

function mapWorkspaceItem(row: any) {
  return {
    id: String(row.id),
    workspaceId: String(row.workspaceId),
    type: String(row.type),
    title: String(row.title),
    status: String(row.status),
    metadataJson: row.metadataJson ? String(row.metadataJson) : null,
    createdAt: iso(row.createdAt),
    updatedAt: iso(row.updatedAt),
  };
}

function mapChannelPost(row: any) {
  return {
    id: String(row.id),
    channelId: String(row.channelId),
    authorId: String(row.authorId),
    body: String(row.body),
    reactionCount: Number(row.reactionCount ?? 0),
    createdAt: iso(row.createdAt),
    updatedAt: iso(row.updatedAt),
  };
}

function mapScheduledMessage(row: any) {
  return {
    id: String(row.id),
    conversationId: String(row.conversationId),
    senderId: String(row.senderId),
    body: String(row.body),
    scheduledFor: iso(row.scheduledFor),
    status: String(row.status),
    createdAt: iso(row.createdAt),
  };
}
