import express from "express";
import rateLimit from "express-rate-limit";
import type { PrismaClient } from "@prisma/client";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureGrowthEventTables, storeGrowthEvent, validateGrowthEventPayload, validateWebAnalyticsPayload } from "../services/growthEvents";

const relayLimiter = rateLimit({
  windowMs: 60_000,
  limit: 120,
  standardHeaders: true,
  legacyHeaders: false,
});

export function growthEventsRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();

  router.post("/", relayLimiter, authMiddleware, async (req, res) => {
    if (JSON.stringify(req.body ?? {}).length > 8_192) {
      res.status(413).json({ error: "payload_too_large" });
      return;
    }
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = validateGrowthEventPayload(req.body, userId);
    if (!parsed.ok) {
      res.status(parsed.status).json({ error: parsed.error });
      return;
    }
    try {
      const result = await storeGrowthEvent(prisma, parsed.event);
      res.status(200).json({ status: result.status, activationCreated: result.activationCreated });
    } catch {
      res.status(500).json({ error: "growth_event_store_failed" });
    }
  });

  router.post("/web", relayLimiter, async (req, res) => {
    if (JSON.stringify(req.body ?? {}).length > 6_144) {
      res.status(413).json({ error: "payload_too_large" });
      return;
    }
    const parsed = validateWebAnalyticsPayload(req.body);
    if (!parsed.ok) {
      res.status(parsed.status).json({ error: parsed.error });
      return;
    }
    try {
      const result = await storeGrowthEvent(prisma, parsed.event);
      res.status(200).json({ status: result.status, activationCreated: false });
    } catch {
      res.status(500).json({ error: "web_analytics_store_failed" });
    }
  });

  router.get("/export", async (req, res) => {
    if (!hasExportAccess(req)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    await ensureGrowthEventTables(prisma);
    const cursor = typeof req.query.cursor === "string" ? req.query.cursor : "";
    const limit = Math.min(500, Math.max(1, Number(req.query.limit ?? 100) || 100));
    const rows = cursor
      ? await prisma.$queryRawUnsafe<any[]>(
          `SELECT * FROM "GrowthEvent" WHERE "receivedAt" > ? ORDER BY "receivedAt" ASC LIMIT ?`,
          cursor,
          limit,
        )
      : await prisma.$queryRawUnsafe<any[]>(
          `SELECT * FROM "GrowthEvent" ORDER BY "receivedAt" ASC LIMIT ?`,
          limit,
        );
    const nextCursor = rows.length ? new Date(rows[rows.length - 1].receivedAt).toISOString() : cursor || null;
    res.json({
      events: rows.map((row) => ({
        eventId: row.eventId,
        eventName: row.eventName,
        subjectKey: row.subjectKey,
        sessionKey: row.sessionKey,
        occurredAt: new Date(row.occurredAt).toISOString(),
        sourcePlatform: row.sourcePlatform,
        appVersion: row.appVersion,
        build: row.build,
        schemaVersion: row.schemaVersion,
        metadata: safeJson(row.metadataJson),
        attribution: safeJson(row.attributionJson),
        isTest: !!row.isTest,
        receivedAt: new Date(row.receivedAt).toISOString(),
      })),
      nextCursor,
      hasMore: rows.length === limit,
    });
  });

  router.get("/status", async (req, res) => {
    if (!hasExportAccess(req)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    await ensureGrowthEventTables(prisma);
    const count = await prisma.$queryRawUnsafe<Array<{ count: number }>>(`SELECT COUNT(*) as count FROM "GrowthEvent"`);
    res.json({ status: "ok", eventCount: Number(count[0]?.count ?? 0), relay: "api/growth/events" });
  });

  return router;
}

function hasExportAccess(req: express.Request): boolean {
  const expected = process.env.GROWTH_EVENTS_EXPORT_TOKEN?.trim();
  const provided = (req.headers.authorization || "").replace(/^Bearer\s+/i, "").trim();
  return !!expected && provided === expected;
}

function safeJson(value: unknown) {
  try { return JSON.parse(String(value ?? "{}")); } catch { return {}; }
}
