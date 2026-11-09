import type { PrismaClient } from "@prisma/client";
import express from "express";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { auditStatus, recentAuditEvents, recordAuditEventSafe } from "../services/audit/AuditEventService";

export function adminAuditRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(requireAuditAdmin);

  router.get("/status", async (req, res) => {
    const auth = req as AuthenticatedRequest;
    await recordAuditEventSafe(prisma, {
      actorId: auth.userId,
      actorType: auth.authMode === "dev" ? "admin" : "admin",
      action: "admin.audit.status_accessed",
      resourceType: "audit",
      metadata: { path: req.path, method: req.method },
    });
    try {
      res.json(await auditStatus(prisma));
    } catch {
      res.status(500).json({ ok: false, error: "audit_status_unavailable" });
    }
  });

  router.get("/recent", async (req, res) => {
    const auth = req as AuthenticatedRequest;
    const limit = Number.parseInt(String(req.query.limit ?? "50"), 10);
    await recordAuditEventSafe(prisma, {
      actorId: auth.userId,
      actorType: "admin",
      action: "admin.audit.recent_accessed",
      resourceType: "audit",
      metadata: { limit: Number.isFinite(limit) ? limit : 50 },
    });
    try {
      res.json({ ok: true, events: await recentAuditEvents(prisma, limit) });
    } catch {
      res.status(500).json({ ok: false, error: "audit_recent_unavailable" });
    }
  });

  return router;
}

function requireAuditAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  const configuredToken = process.env.ONEWAY_AUDIT_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_PRIVACY_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_LEDGER_ADMIN_TOKEN?.trim();
  const header = req.headers["x-oneway-admin-token"];
  const headerToken = Array.isArray(header) ? header[0] : header;
  const adminTokenMatches = Boolean(configuredToken && headerToken === configuredToken);
  const auth = req as AuthenticatedRequest;
  const devAdmin = process.env.NODE_ENV !== "production" && auth.authMode === "dev";

  if (adminTokenMatches || devAdmin) {
    next();
    return;
  }

  res.status(403).json({ ok: false, error: "audit_admin_required" });
}
