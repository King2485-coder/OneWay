import express from "express";
import crypto from "crypto";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { turnRateLimit } from "../lib/rateLimit";

/**
 * Mints short-lived TURN credentials using the coturn REST-API auth scheme.
 *
 * coturn (with `use-auth-secret` + `static-auth-secret=$SECRET`) accepts any
 * credential pair where:
 *
 *   username  = "<unix_expiry>:<userId>"
 *   password  = base64( HMAC-SHA1(SECRET, username) )
 *
 * The server never persists these — the same secret is used to verify them
 * on every TURN allocation. Rotating the secret invalidates all outstanding
 * credentials, which is the whole point.
 *
 * Required env:
 *   TURN_SHARED_SECRET   — same value as turnserver.conf's static-auth-secret
 *   TURN_HOSTNAME        — e.g. turn.onewayapp.com
 *
 * Optional:
 *   TURN_TTL_SECONDS     — default 12h (43200). Must be ≤ stale-nonce window
 *                          AND ≤ what the iOS client refreshes at.
 */

interface TurnRouterDeps {
  // Future: pull userId from authenticated session. Today we accept an
  // optional `identity` query param so dev builds work without auth.
  resolveUserId?: (req: express.Request) => string | undefined;
}

const ALLOWED_IDENTITY = /^[A-Za-z0-9_\-:.]{1,64}$/;

export function turnRouter(_deps: TurnRouterDeps = {}): express.Router {
  const router = express.Router();
  // TURN credentials are tied to the authenticated user — that's the
  // identity the HMAC encodes. Auth-gating + rate-limit prevents abuse.
  router.use(authMiddleware);
  router.use(turnRateLimit());

  router.get("/", (req, res) => {
    const secret = process.env.TURN_SHARED_SECRET;
    const host = process.env.TURN_HOSTNAME;

    if (!secret || !host) {
      // 503 (not 500) — config is missing, not a runtime fault. The iOS
      // client treats 5xx as "skip TURN, try host candidates only".
      res.status(503).json({ error: "turn_not_configured" });
      return;
    }

    const ttl = clampTtl(Number(process.env.TURN_TTL_SECONDS ?? 43200));
    const now = Math.floor(Date.now() / 1000);
    const expiry = now + ttl;

    // Identity comes from the authenticated user — never trust the body
    // / query for this. Coturn logs see this string; sanitize defensively.
    const rawIdentity = (req as AuthenticatedRequest).userId;
    const identity = ALLOWED_IDENTITY.test(rawIdentity) ? rawIdentity : "anon";

    const username = `${expiry}:${identity}`;
    const credential = crypto
      .createHmac("sha1", secret)
      .update(username)
      .digest("base64");

    // The order matters: clients try urls top-down. STUN first (cheap),
    // then UDP TURN (best latency), then TCP TURN (firewalls), then TLS
    // (hotels / DPI).
    const iceServers = [
      {
        urls: [
          `stun:${host}:3478`,
          `turn:${host}:3478?transport=udp`,
          `turn:${host}:3478?transport=tcp`,
          `turns:${host}:5349?transport=tcp`,
        ],
        username,
        credential,
      },
    ];

    // Cache-Control: never cache. These tokens have no value to anyone but
    // the requesting client and would just confuse a CDN.
    res.set("Cache-Control", "no-store");
    res.json({
      iceServers,
      // Echo the TTL so the client knows when to re-fetch. We send the
      // remaining seconds, not the absolute expiry, so client clock drift
      // doesn't cause early refresh storms.
      ttl,
      expiresAt: expiry,
    });
  });

  return router;
}

function clampTtl(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 43200;
  // Hard ceiling: 24h. Anything longer outlives our threat model.
  return Math.min(value, 86400);
}
