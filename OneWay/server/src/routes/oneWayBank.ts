import express from "express";

import { prisma } from "../lib/db";
import { authMiddleware } from "../middleware/auth";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";

type ComplianceArea = "ledger" | "disputes";

const DISABLED_MESSAGE = "OneWay Bank is not active yet. Storefront payments currently use Stripe/payment links.";

export function oneWayBankRouter(area: ComplianceArea): express.Router {
  const router = express.Router();

  router.use((req, res, next) => {
    if (!isAreaEnabled(area)) {
      void recordAuditEventSafe(prisma, {
        actorType: "public",
        action: "oneway_bank.disabled_route_access",
        resourceType: "oneway_bank",
        resourceId: area,
        metadata: { method: req.method, path: req.path, area },
      });
      res.status(503).json(disabledPayload(area));
      return;
    }
    authMiddleware(req, res, next);
  });

  router.use((req, res, next) => {
    try {
      // The compliance modules are CommonJS and intentionally loaded only
      // after flags prove the dormant OneWay Bank surface has been enabled.
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const compliance = require("../services/compliance/complianceService");
      const mountedRouter = area === "ledger" ? compliance.ledger?.router : compliance.disputes?.router;
      if (!mountedRouter) {
        res.status(503).json(disabledPayload(area));
        return;
      }
      mountedRouter(req, res, next);
    } catch (error) {
      next(error);
    }
  });

  return router;
}

export function disabledPayload(area: ComplianceArea): {
  error: string;
  message: string;
  area: ComplianceArea;
  stripePrimary: boolean;
} {
  return {
    error: "oneway_bank_disabled",
    message: DISABLED_MESSAGE,
    area,
    stripePrimary: true,
  };
}

export function isComplianceLayerEnabled(): boolean {
  return envFlag("COMPLIANCE_LAYER_ENABLED", false);
}

export function isAreaEnabled(area: ComplianceArea): boolean {
  if (!isComplianceLayerEnabled()) return false;
  if (!envFlag("ONEWAY_BANK_ENABLED", false)) return false;
  if (area === "ledger") return envFlag("LEDGER_ENABLED", false);
  return envFlag("DISPUTES_ENABLED", false);
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}
