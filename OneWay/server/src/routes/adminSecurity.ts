import type { PrismaClient } from "@prisma/client";
import express from "express";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";
import { buildAdminSecurityStatus } from "../services/security/SecurityCheckService";

export function adminSecurityRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(requireSecurityAdmin);

  router.get("/status", async (req, res) => {
    const auth = req as AuthenticatedRequest;
    await recordAuditEventSafe(prisma, {
      actorId: auth.userId,
      actorType: "admin",
      action: "admin.security.status_accessed",
      resourceType: "security",
      metadata: { path: req.path, method: req.method },
    });
    try {
      res.json(await buildAdminSecurityStatus(prisma));
    } catch {
      res.status(500).json({ ok: false, error: "security_status_unavailable" });
    }
  });

  return router;
}

function requireSecurityAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  const configuredToken = process.env.ONEWAY_SECURITY_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_AUDIT_ADMIN_TOKEN?.trim()
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

  res.status(403).json({ ok: false, error: "security_admin_required" });
}
