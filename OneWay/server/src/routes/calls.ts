import express from "express";
import { z } from "zod";
import type { ICallRegistry } from "../services/CallRegistry";
import { RegistryError, isTerminal } from "../services/CallRegistry";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { isParticipant } from "../types/calls";
import { inviteRateLimit } from "../lib/rateLimit";
import { logger } from "../lib/logger";

/**
 * REST counterpart to the WebSocket layer. Every call lifecycle action has a
 * REST endpoint *and* a WS event — they share the same `CallRegistry` so a
 * client can mix and match (REST-only as fallback, WS-only for low latency,
 * or both for resilience).
 */

interface CallsRouterDeps {
  registry: ICallRegistry;
  /** Hook the WebSocket server provides so we can fan-out REST-driven
   *  changes to any other connected sockets the user owns. */
  onCallChanged?: (call: ReturnType<ICallRegistry["get"]>) => void;
  /** Sends a VoIP push to wake the callee's app if it's backgrounded /
   *  killed. Optional — when missing, only the WS path notifies. */
  onCallInvited?: (callerId: string, calleeId: string, call: NonNullable<ReturnType<ICallRegistry["get"]>>) => void;
  inviteRateLimit?: RateLimitConfig;
}

interface RateLimitConfig {
  windowMs: number;
  max: number; // max invites per user per window
}

const inviteSchema = z.object({
  calleeId: z.string().min(1).max(64),
  hasVideo: z.boolean().optional().default(false),
});

const callIdSchema = z.object({
  callId: z.string().uuid(),
});

export function callsRouter(deps: CallsRouterDeps): express.Router {
  const router = express.Router();
  const limiter = makeLimiter(deps.inviteRateLimit ?? { windowMs: 60_000, max: 20 });

  // Every route below requires auth.
  router.use(authMiddleware);

  // POST /api/calls/invite ---------------------------------------------------
  router.post("/invite", inviteRateLimit(), (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    if (!limiter.consume(userId)) {
      res.status(429).json({ error: "rate_limited", message: "too many invites" });
      return;
    }
    const parsed = inviteSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    if (parsed.data.calleeId === userId) {
      res.status(400).json({ error: "self_invite_forbidden" });
      return;
    }
    const call = deps.registry.createCall({
      callerId: userId,
      calleeId: parsed.data.calleeId,
      hasVideo: parsed.data.hasVideo,
      turnEnabled: true,
    });
    deps.onCallChanged?.(call);
    // Fire VoIP push (best-effort — push fan-out runs alongside the WS one).
    deps.onCallInvited?.(userId, parsed.data.calleeId, call);
    res.status(201).json({ call });
  });

  // POST /api/calls/accept ---------------------------------------------------
  router.post("/accept", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = callIdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const call = deps.registry.get(parsed.data.callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    // Only the callee may accept.
    if (call.calleeId !== userId) {
      res.status(403).json({ error: "not_callee" });
      return;
    }
    if (call.status !== "ringing") {
      res.status(409).json({ error: "wrong_state", state: call.status });
      return;
    }
    try {
      const updated = deps.registry.updateStatus(call.callId, "accepted", (c) => {
        if (!c.participants.includes(userId)) c.participants.push(userId);
      });
      deps.onCallChanged?.(updated);
      res.json({ call: updated });
    } catch (err) {
      respondRegistryError(res, err);
    }
  });

  // POST /api/calls/decline --------------------------------------------------
  router.post("/decline", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = callIdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const call = deps.registry.get(parsed.data.callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (call.calleeId !== userId) {
      res.status(403).json({ error: "not_callee" });
      return;
    }
    if (isTerminal(call.status)) {
      res.json({ call });
      return;
    }
    try {
      const updated = deps.registry.updateStatus(call.callId, "declined");
      deps.onCallChanged?.(updated);
      res.json({ call: updated });
    } catch (err) {
      respondRegistryError(res, err);
    }
  });

  // POST /api/calls/hangup ---------------------------------------------------
  router.post("/hangup", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = callIdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const call = deps.registry.get(parsed.data.callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isParticipant(call, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }
    if (isTerminal(call.status)) {
      res.json({ call });
      return;
    }
    try {
      const updated = deps.registry.updateStatus(call.callId, "ended");
      deps.onCallChanged?.(updated);
      res.json({ call: updated });
    } catch (err) {
      respondRegistryError(res, err);
    }
  });

  // GET /api/calls/active ----------------------------------------------------
  // Note: this MUST come before the /:callId route so Express doesn't
  // capture "active" as a UUID.
  router.get("/active", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    res.json({ calls: deps.registry.activeForUser(userId) });
  });

  // GET /api/calls/:callId ---------------------------------------------------
  router.get("/:callId", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const callId = req.params.callId;
    if (!/^[0-9a-fA-F-]{36}$/.test(callId)) {
      res.status(400).json({ error: "invalid_call_id" });
      return;
    }
    const call = deps.registry.get(callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isParticipant(call, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }
    res.json({ call });
  });

  return router;
}

// ---- Helpers ---------------------------------------------------------------

function respondRegistryError(res: express.Response, err: unknown): void {
  if (err instanceof RegistryError) {
    const status = err.code === "not_found" ? 404 : 409;
    res.status(status).json({ error: err.code, message: err.message });
    return;
  }
  logger.error({ err }, "[calls] unexpected error");
  res.status(500).json({ error: "internal_error" });
}

interface Limiter {
  consume(userId: string): boolean;
}

/** Token-bucket-ish per-user invite limiter. Memory-only; per-process. */
function makeLimiter(cfg: RateLimitConfig): Limiter {
  const buckets = new Map<string, { count: number; resetAt: number }>();
  return {
    consume(userId: string): boolean {
      const now = Date.now();
      let b = buckets.get(userId);
      if (!b || b.resetAt < now) {
        b = { count: 0, resetAt: now + cfg.windowMs };
        buckets.set(userId, b);
      }
      if (b.count >= cfg.max) return false;
      b.count += 1;
      return true;
    },
  };
}
