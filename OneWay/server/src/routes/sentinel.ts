import { Router, type Request, type Response } from "express";
import { z } from "zod";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";

const signalSchema = z.object({
  kind: z.enum([
    "newDevice",
    "impossibleTravel",
    "failedLoginBurst",
    "simSwapIndicator",
    "recoveryChange",
    "stolenToken",
    "automatedAccount",
    "sessionHijacking",
    "maliciousLink",
    "impersonation",
    "dangerousFile",
    "harassmentCampaign",
    "maliciousInvitation",
    "unsolicitedMessaging",
    "accountFarming",
    "childSafetyRisk",
    "chargebackPattern",
    "deliveryComplaintPattern",
    "reusedProductImage",
    "apiAbuse",
    "credentialStuffing",
    "ddos",
    "databaseAnomaly",
    "privilegeEscalation",
    "secretLeak",
    "maliciousBuild",
    "suspiciousAdministrator",
    "vulnerableDependency",
  ]),
  weight: z.number().int().min(0).max(100),
  occurredAt: z.string().datetime().optional(),
  source: z.enum(["device", "server", "user_report"]),
});

const assessSchema = z.object({
  deviceIdHash: z.string().min(16).max(256),
  sessionIdHash: z.string().min(16).max(256).optional(),
  signals: z.array(signalSchema).max(50),
  clientVersion: z.string().max(64).optional(),
});

const reportSchema = z.object({
  category: z.enum([
    "scam",
    "phishing",
    "impersonation",
    "dangerous_file",
    "harassment",
    "child_safety",
    "fraudulent_shop",
  ]),
  encryptedEvidenceEnvelope: z.string().min(1).max(2_000_000),
  consentVersion: z.string().min(1).max(32),
});

function chooseAction(score: number) {
  if (score >= 85) return "humanReview";
  if (score >= 65) return "temporarilySuspend";
  if (score >= 40) return "requireTrustedDeviceApproval";
  if (score >= 20) return "warn";
  return "allow";
}

function levelFor(score: number) {
  if (score >= 85) return "critical";
  if (score >= 65) return "high";
  if (score >= 40) return "elevated";
  if (score >= 20) return "low";
  return "safe";
}

export function sentinelRouter() {
  const router = Router();

  router.post("/assess", authMiddleware, (req: Request, res: Response) => {
    const parsed = assessSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_sentinel_event", details: parsed.error.flatten() });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    const score = Math.min(
      100,
      parsed.data.signals.reduce((total, signal) => total + signal.weight, 0),
    );

    logger.info(
      {
        userId,
        deviceIdHash: parsed.data.deviceIdHash,
        signalKinds: parsed.data.signals.map((signal) => signal.kind),
        score,
      },
      "[sentinel] privacy-preserving risk assessment",
    );

    res.json({
      riskScore: score,
      riskLevel: levelFor(score),
      recommendedAction: chooseAction(score),
      evaluatedAt: new Date().toISOString(),
      privacyMode: "metadata-only",
    });
  });

  router.post("/reports", authMiddleware, (req: Request, res: Response) => {
    const parsed = reportSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_sentinel_report", details: parsed.error.flatten() });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    const reportId = crypto.randomUUID();

    logger.warn(
      {
        reportId,
        userId,
        category: parsed.data.category,
        consentVersion: parsed.data.consentVersion,
      },
      "[sentinel] user-authorized report received",
    );

    res.status(202).json({ reportId, status: "accepted" });
  });

  return router;
}
