/**
 * Express rate-limit factories — one per sensitive route. Backed by
 * `express-rate-limit` if installed, otherwise a no-op so the project still
 * boots cleanly. Keys are derived from authenticated userId when available,
 * falling back to IP. Production deployments should sit behind a trusted
 * proxy that sets `X-Forwarded-For`; configure `app.set("trust proxy", 1)`
 * in `index.ts` if you do.
 */

import type { Request, RequestHandler } from "express";

interface RateLimitOptions {
  windowMs: number;
  max: number;
  message?: object;
}

interface RateLimitModule {
  (opts: RateLimitOptions & {
    keyGenerator?: (req: Request) => string;
    standardHeaders?: boolean | "draft-7";
    legacyHeaders?: boolean;
    handler?: RequestHandler;
  }): RequestHandler;
}

let cache: RateLimitModule | null | undefined;
function load(): RateLimitModule | null {
  if (cache !== undefined) return cache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    cache = require("express-rate-limit") as RateLimitModule;
  } catch {
    cache = null;
  }
  return cache;
}

function userOrIp(req: Request): string {
  const userId = (req as Request & { userId?: string }).userId;
  if (userId) return `user:${userId}`;
  return `ip:${req.ip ?? "unknown"}`;
}

function make(opts: RateLimitOptions): RequestHandler {
  const sdk = load();
  if (!sdk) {
    // No-op fallback. Keeps semantics — rate limit is best-effort, not a
    // security boundary. Real production deploys MUST install the package
    // and ideally back it with Redis (`rate-limit-redis`).
    return (_req, _res, next) => next();
  }
  return sdk({
    windowMs: opts.windowMs,
    max: opts.max,
    standardHeaders: "draft-7",
    legacyHeaders: false,
    keyGenerator: userOrIp,
    handler: (_req, res) => {
      res.status(429).json(opts.message ?? { error: "rate_limited" });
    },
  });
}

// 5 invites / 30 s — generous for legit bursts, brutal for spammers.
export const inviteRateLimit = () => make({
  windowMs: 30_000, max: 5,
  message: { error: "rate_limited", message: "too many call invites" },
});

// 30 push registrations / 5 min — covers legit foreground/background cycles.
export const pushRegisterRateLimit = () => make({
  windowMs: 5 * 60_000, max: 30,
  message: { error: "rate_limited", message: "too many push token updates" },
});

// 10 voicemail uploads / 10 min.
export const voicemailUploadRateLimit = () => make({
  windowMs: 10 * 60_000, max: 10,
  message: { error: "rate_limited", message: "too many voicemail uploads" },
});

// 10 attempts / 15 min. Logged out → keyed by IP.
export const authRateLimit = () => make({
  windowMs: 15 * 60_000, max: 10,
  message: { error: "rate_limited", message: "too many auth attempts" },
});

// 60 token mints / min — tight for the LiveKit token endpoint since each
// mint is a JWT signing op.
export const liveKitTokenRateLimit = () => make({
  windowMs: 60_000, max: 60,
  message: { error: "rate_limited" },
});

// 60 TURN credential requests / min — credentials are 12h TTL, so callers
// only need one per call. This is mostly DOS-protection.
export const turnRateLimit = () => make({
  windowMs: 60_000, max: 60,
  message: { error: "rate_limited" },
});
