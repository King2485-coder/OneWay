/**
 * Express rate-limit factories — one per sensitive route. Backed by
 * `express-rate-limit` if installed, otherwise a no-op so the project still
 * boots cleanly. Keys are derived from authenticated userId when available,
 * falling back to IP. Production deployments should sit behind a trusted
 * proxy that sets `X-Forwarded-For`; configure `app.set("trust proxy", 1)`
 * in `index.ts` if you do.
 */

import type { Request, RequestHandler } from "express";
import { logger } from "./logger";

interface RateLimitOptions {
  windowMs: number;
  max: number;
  message?: object;
  keyGenerator?: (req: Request) => string;
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

function authIdentifierOrIp(req: Request): string {
  const body = req.body as { identifier?: unknown; email?: unknown } | undefined;
  const raw = typeof body?.identifier === "string"
    ? body.identifier
    : typeof body?.email === "string"
      ? body.email
      : "";
  const identifier = raw.trim().toLowerCase();
  return identifier.length === 0
    ? userOrIp(req)
    : `${userOrIp(req)}:identifier:${identifier}`;
}

function envInt(name: string, fallback: number): number {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
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
    keyGenerator: opts.keyGenerator ?? userOrIp,
    handler: (req, res) => {
      const rateLimit = (req as any).rateLimit as {
        limit?: number;
        used?: number;
        remaining?: number;
        resetTime?: Date;
      } | undefined;
      const retryAfterSeconds = rateLimit?.resetTime
        ? Math.max(1, Math.ceil((rateLimit.resetTime.getTime() - Date.now()) / 1000))
        : undefined;

      if (retryAfterSeconds) {
        res.setHeader("Retry-After", String(retryAfterSeconds));
      }

      logger.warn({
        method: req.method,
        path: req.originalUrl ?? req.path,
        limit: rateLimit?.limit,
        used: rateLimit?.used,
        remaining: rateLimit?.remaining,
        retryAfterSeconds,
      }, "[rate-limit] request blocked");

      res.status(429).json({
        error: "rate_limited",
        message: "Too many login attempts. Please wait a moment before trying again.",
        retryAfterSeconds,
        ...(opts.message ?? {}),
      });
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

// Production defaults to 10 attempts / 15 min. Development is deliberately
// looser because physical-device QA repeatedly switches between test users.
export const authRateLimit = () => make({
  windowMs: envInt(
    "ONEWAY_AUTH_RATE_LIMIT_WINDOW_MS",
    process.env.NODE_ENV === "production" ? 15 * 60_000 : 60_000
  ),
  max: envInt(
    "ONEWAY_AUTH_RATE_LIMIT_MAX",
    process.env.NODE_ENV === "production" ? 10 : 120
  ),
  keyGenerator: authIdentifierOrIp,
  message: {
    code: "AUTH_RATE_LIMITED",
  },
});

// Authenticated people search and Chirp ID lookup. This limits contact
// enumeration while still allowing normal add-contact flows.
export const userSearchRateLimit = () => make({
  windowMs: 60_000, max: 60,
  message: { error: "rate_limited", message: "too many user search attempts" },
});

export const chirpLookupRateLimit = () => make({
  windowMs: 60_000, max: 30,
  message: { error: "rate_limited", message: "too many Chirp ID lookup attempts" },
});

export const emailSendRateLimit = () => make({
  windowMs: 60 * 60_000,
  max: envInt("ONEWAY_EMAIL_HOURLY_SEND_LIMIT", 25),
  message: { error: "email_rate_limited", message: "Email sending limit reached. Try again later." },
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
