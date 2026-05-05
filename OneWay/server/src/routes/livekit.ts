import express from "express";
import { z } from "zod";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { liveKitTokenRateLimit } from "../lib/rateLimit";
import { logger } from "../lib/logger";
import { sanitizeRoomName } from "../types/calls";
import type { ICallRegistry } from "../services/CallRegistry";
import { isParticipant } from "../types/calls";
import type { LiveKitTokenService } from "../services/LiveKitTokenService";

/**
 * POST /api/livekit/token
 *
 * Mint a short-lived LiveKit JWT for a specific room. The roomName is
 * sanitized server-side; whatever the client sent is treated as a hint, not
 * an authority. We also cross-check the room against the CallRegistry: if a
 * call with this room exists, only declared participants may mint a token
 * for it. That stops a curious user from joining anyone's room by guessing
 * the name.
 *
 * If the registry doesn't know the room (ad-hoc test rooms, dev), we still
 * issue a token so internal tooling works — but only for the requesting
 * user's own identity. Either way the token's `identity` matches `req.userId`,
 * never an arbitrary string from the body.
 */

interface LiveKitRouterDeps {
  registry: ICallRegistry;
  tokens: LiveKitTokenService;
}

const tokenSchema = z.object({
  roomName: z.string().min(1).max(128),
  identity: z.string().min(1).max(64).optional(),
  displayName: z.string().min(1).max(64).optional(),
});

export function liveKitRouter(deps: LiveKitRouterDeps): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(liveKitTokenRateLimit());

  router.post("/token", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    if (!deps.tokens.isConfigured()) {
      res.status(503).json({ error: "livekit_not_configured" });
      return;
    }
    const parsed = tokenSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const roomName = sanitizeRoomName(parsed.data.roomName);

    // The identity baked into the JWT is *always* the authenticated user.
    // We accept it on the body for parity with the LiveKit examples but
    // ignore any value other than the auth'd userId.
    const identity = userId;
    const displayName = parsed.data.displayName?.slice(0, 64);

    // Authorization check: if this room belongs to a known call, the user
    // must be a participant.
    const knownCall = deps.registry.findByRoom(roomName);
    if (knownCall && !isParticipant(knownCall, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }

    try {
      const result = await deps.tokens.issue({
        roomName,
        identity,
        displayName,
        ttlSeconds: 3600,
      });
      // Mark the user as a participant on the underlying call so future
      // /api/livekit/token requests for the same room from the same user
      // don't trip the not-participant guard if they reconnect.
      if (knownCall && !knownCall.participants.includes(userId)) {
        deps.registry.addParticipant(knownCall.callId, userId);
      }
      res.json(result);
    } catch (err) {
      logger.error({ err }, "[livekit] token issue failed");
      res.status(500).json({ error: "token_issue_failed" });
    }
  });

  return router;
}
