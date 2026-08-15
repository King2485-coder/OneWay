import express from "express";
import { z } from "zod";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import type { PushTokenStore } from "../services/PushTokenStore";
import { pushRegisterRateLimit } from "../lib/rateLimit";
import type { AlertPushTokenStore } from "../services/AlertPushTokenStore";

interface PushRouterDeps {
  tokens: PushTokenStore;
  alertTokens: AlertPushTokenStore;
}

const registerSchema = z.object({
  voipToken: z.string().min(32).max(200).regex(/^[0-9a-fA-F]+$/),
  environment: z.enum(["sandbox", "production"]).optional().default("sandbox"),
});
const alertRegisterSchema = z.object({
  token: z.string().min(32).max(200).regex(/^[0-9a-fA-F]+$/),
  environment: z.enum(["sandbox", "production"]).optional().default("sandbox"),
  previewMode: z.enum(["sender_subject", "sender", "generic", "none"]).optional().default("sender_subject"),
});

export function pushRouter(deps: PushRouterDeps): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(pushRegisterRateLimit());

  // POST /api/push/register --------------------------------------------------
  router.post("/register", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = registerSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    try {
      await deps.tokens.set({
        userId,
        voipToken: parsed.data.voipToken.toLowerCase(),
        environment: parsed.data.environment,
        updatedAt: Date.now(),
      });
      res.status(204).end();
    } catch (err) {
      const message = err instanceof Error ? err.message : "unknown";
      if (message === "invalid_token_format") {
        res.status(400).json({ error: "invalid_token_format" });
        return;
      }
      res.status(500).json({ error: "internal_error" });
    }
  });

  // DELETE /api/push/register ------------------------------------------------
  // Sign-out path — drops whatever token is registered for the user.
  router.delete("/register", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const record = await deps.tokens.get(userId);
    if (record) await deps.tokens.remove(record.voipToken);
    res.status(204).end();
  });

  router.post("/alerts/register", async (req, res) => {
    const parsed = alertRegisterSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ error: "invalid_body", issues: parsed.error.issues }); return; }
    await deps.alertTokens.set((req as AuthenticatedRequest).userId, {
      token: parsed.data.token, environment: parsed.data.environment, previewMode: parsed.data.previewMode,
    });
    res.status(204).end();
  });

  router.delete("/alerts/register/:token", async (req, res) => {
    await deps.alertTokens.remove(req.params.token);
    res.status(204).end();
  });

  return router;
}
