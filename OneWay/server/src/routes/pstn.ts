import crypto from "node:crypto";
import express from "express";
import { z } from "zod";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import type { PSTNProvider } from "../services/pstn/PSTNProvider";

const bodySchema = z.object({
  toPhoneNumber: z.string().min(1),
  fromOneWayNumber: z.string().optional(),
});

export function pstnRouter(provider: PSTNProvider): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.post("/calls/start", async (req, res) => {
    const parsed = bodySchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    const digits = parsed.data.toPhoneNumber.replace(/[^\d+]/g, "");
    const numericCount = digits.replace(/\D/g, "").length;
    if (numericCount < 7) {
      res.status(400).json({ error: "invalid_phone_number" });
      return;
    }

    const callSessionId = crypto.randomUUID();
    const providerResult = await provider.startOutboundCall({
      fromUserId: userId,
      fromOneWayNumber: parsed.data.fromOneWayNumber,
      toPhoneNumber: digits,
      callSessionId,
    });

    res.json({
      callSessionId,
      networkType: "pstnBridge",
      status: providerResult.status,
      providerCallId: providerResult.providerCallId,
      provider: process.env.PSTN_PROVIDER ?? "stub",
      externalPhoneNumber: digits,
    });
  });

  return router;
}
