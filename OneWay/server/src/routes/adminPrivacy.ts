import type { PrismaClient } from "@prisma/client";
import express from "express";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";
import { buildPrivacyStatus } from "../services/privacy/PrivacyDiagnostics";

export function adminPrivacyRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(requirePrivacyAdmin);

  router.get("/status", async (req, res) => {
    const auth = req as AuthenticatedRequest;
    await recordAuditEventSafe(prisma, {
      actorId: auth.userId,
      actorType: "admin",
      action: "admin.privacy.status_accessed",
      resourceType: "privacy",
      metadata: { path: req.path, method: req.method },
    });
    try {
      res.json(await buildPrivacyStatus(prisma));
    } catch {
      res.status(500).json({ ok: false, error: "privacy_status_unavailable" });
    }
  });

  return router;
}

function requirePrivacyAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  const configuredToken = process.env.ONEWAY_PRIVACY_ADMIN_TOKEN?.trim() || process.env.ONEWAY_LEDGER_ADMIN_TOKEN?.trim();
  const header = req.headers["x-oneway-admin-token"];
  const headerToken = Array.isArray(header) ? header[0] : header;
  const adminTokenMatches = Boolean(configuredToken && headerToken === configuredToken);
  const auth = req as AuthenticatedRequest;
  const devAdmin = process.env.NODE_ENV !== "production" && auth.authMode === "dev";

  if (adminTokenMatches || devAdmin) {
    next();
    return;
  }

  res.status(403).json({ ok: false, error: "privacy_admin_required" });
}
