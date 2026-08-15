import express from "express";
import { z } from "zod";
import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import { authRateLimit } from "../lib/rateLimit";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { createInitialIdentity, normalizeOneWayId, sanitizeEmailAlias } from "../services/identity";
import { assignInitialNumber } from "../services/numbers";

/**
 * Email + password auth. Hashed with bcrypt, signed with HS256 JWT.
 * Tokens are stateless — no server-side session table.
 *
 * Required env:
 *   JWT_SECRET       a 32+ character random string
 *   JWT_TTL_SECONDS  optional, default 604800 (7 d)
 *
 * Without `JWT_SECRET` the routes still mount but return 503 — that way
 * the rest of the app boots and dev mode keeps working off `dev:<userId>`.
 */

interface BcryptModule {
  hash(plain: string, rounds: number): Promise<string>;
  compare(plain: string, hash: string): Promise<boolean>;
}
interface JwtModule {
  sign(
    payload: object,
    secret: string,
    options?: { expiresIn?: string | number; algorithm?: "HS256" }
  ): string;
}

let bcryptCache: BcryptModule | null | undefined;
let jwtCache: JwtModule | null | undefined;

function loadBcrypt(): BcryptModule | null {
  if (bcryptCache !== undefined) return bcryptCache;
  try {
    // bcryptjs (pure JS) — easier to install on Alpine images. Both APIs match.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    bcryptCache = require("bcryptjs") as BcryptModule;
  } catch {
    bcryptCache = null;
    logger.warn({}, "[auth] bcryptjs not installed — register/login will 503");
  }
  return bcryptCache;
}

function loadJwt(): JwtModule | null {
  if (jwtCache !== undefined) return jwtCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    jwtCache = require("jsonwebtoken") as JwtModule;
  } catch {
    jwtCache = null;
  }
  return jwtCache;
}

const credentialsSchema = z.object({
  email: z.string().email().max(254),
  password: z.string().min(6).max(200),
  displayName: z.string().min(1).max(64).optional(),
  walkieName: z.string().min(1).max(32).optional(),
  username: z.string().min(1).max(32).optional(),
  onewayId: z.string().min(2).max(32).optional(),
  emailAlias: z.string().min(1).max(64).optional(),
  usernameHidden: z.boolean().optional(),
});

const loginSchema = z.object({
  identifier: z.string().min(1).max(254).optional(),
  email: z.string().email().max(254).optional(),
  password: z.string().min(6).max(200),
});

export function authRouter(): express.Router {
  const router = express.Router();

  router.get("/me", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    try {
      const user = await prisma.user.findUnique({
        where: { id: userId },
        select: {
          id: true,
          email: true,
          displayName: true,
          chirpId: true,
          identity: {
            select: {
              displayName: true,
              username: true,
              onewayId: true,
            },
          },
        },
      });

      if (!user) {
        res.status(404).json({ error: "user_not_found" });
        return;
      }

      res.json({
        userId: user.id,
        email: user.email,
        displayName: user.identity?.displayName ?? user.displayName,
        handle: user.identity?.onewayId ?? null,
        username: user.identity?.username ?? null,
        chirpId: user.chirpId ?? null,
      });
    } catch (err) {
      logger.error({ err, userId }, "[auth] me failed");
      res.status(500).json({ error: "internal_error" });
    }
  });

  router.post("/register", authRateLimit(), async (req, res) => {
    const bcrypt = loadBcrypt();
    const jwt = loadJwt();
    const secret = process.env.JWT_SECRET;
    if (!bcrypt || !jwt || !secret) {
      res.status(503).json({ error: "auth_disabled" });
      return;
    }
    const parsed = credentialsSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const email = parsed.data.email.toLowerCase();
    try {
      const existing = await prisma.user.findUnique({ where: { email } });
      if (existing) {
        res.status(409).json({ error: "email_taken" });
        return;
      }
      const hash = await bcrypt.hash(parsed.data.password, 12);
      const user = await prisma.user.create({
        data: {
          email,
          passwordHash: hash,
          displayName: parsed.data.displayName ?? email.split("@")[0],
        },
      });
      await createInitialIdentity({
        userId: user.id,
        displayName: parsed.data.displayName ?? user.displayName,
        walkieName: parsed.data.walkieName ?? parsed.data.displayName ?? user.displayName,
        username: parsed.data.username ?? email.split("@")[0],
        onewayId: parsed.data.onewayId ? normalizeOneWayId(parsed.data.onewayId) : undefined,
        emailAlias: parsed.data.emailAlias ? sanitizeEmailAlias(parsed.data.emailAlias) : undefined,
        usernameHidden: parsed.data.usernameHidden ?? true,
      });
      await assignInitialNumber(user.id);
      const token = signToken(jwt, secret, user.id);
      const identity = await prisma.oneWayIdentity.findUnique({
        where: { userId: user.id },
        select: {
          displayName: true,
          walkieName: true,
          username: true,
          usernameHidden: true,
          onewayId: true,
          emailAlias: true,
          showEmailAlias: true,
          showOneWayId: true,
          showNumbers: true,
          preferredCallerIdentity: true,
        },
      });
      logger.info({ userId: user.id }, "[auth] registered");
      res.status(201).json({
        token,
        user: {
          id: user.id,
          email: user.email,
          displayName: user.displayName,
          identity,
        },
      });
    } catch (err) {
      logger.error({ err }, "[auth] register failed");
      res.status(500).json({ error: "internal_error" });
    }
  });

  router.post("/login", authRateLimit(), async (req, res) => {
    const bcrypt = loadBcrypt();
    const jwt = loadJwt();
    const secret = process.env.JWT_SECRET;
    if (!bcrypt || !jwt || !secret) {
      res.status(503).json({ error: "auth_disabled" });
      return;
    }
    const parsed = loginSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const identifier = (parsed.data.identifier ?? parsed.data.email ?? "").trim();
    if (!identifier) {
      res.status(400).json({ error: "identifier_required" });
      return;
    }
    logger.info({
      event: "auth.login.request",
      identifier: redactIdentifier(identifier),
      source: req.headers["x-oneway-auth-source"] ?? "unknown",
      retryCount: req.headers["x-oneway-auth-retry-count"] ?? "0",
    }, "[auth] login request received");
    try {
      const emailLike = identifier.includes("@") && identifier.includes(".");
      const byEmail = emailLike
        ? await prisma.user.findUnique({ where: { email: identifier.toLowerCase() } })
        : null;
      const byOnewayId = identifier.startsWith("@")
        ? await prisma.oneWayIdentity.findUnique({
            where: { onewayId: normalizeOneWayId(identifier) },
            select: { userId: true },
          })
        : null;
      const byUsername = !identifier.startsWith("@") && !emailLike
        ? await prisma.oneWayIdentity.findFirst({
            where: { username: identifier },
            select: { userId: true },
          })
        : null;

      const userId = byEmail?.id ?? byOnewayId?.userId ?? byUsername?.userId ?? null;
      const user = userId ? await prisma.user.findUnique({ where: { id: userId } }) : null;
      // Same response on missing user vs. wrong password — we do NOT leak
      // whether the email is registered.
      if (!user || !user.passwordHash || user.accountStatus !== "active") {
        await timingPad();
        logger.warn({
          event: "auth.login.failed",
          identifier: redactIdentifier(identifier),
          statusCode: 401,
          reason: "invalid_credentials",
        }, "[auth] login failed");
        res.status(401).json({ error: "invalid_credentials" });
        return;
      }
      const ok = await bcrypt.compare(parsed.data.password, user.passwordHash);
      if (!ok) {
        logger.warn({
          event: "auth.login.failed",
          identifier: redactIdentifier(identifier),
          statusCode: 401,
          reason: "invalid_credentials",
        }, "[auth] login failed");
        res.status(401).json({ error: "invalid_credentials" });
        return;
      }
      const token = signToken(jwt, secret, user.id);
      const identity = await prisma.oneWayIdentity.findUnique({
        where: { userId: user.id },
        select: {
          displayName: true,
          walkieName: true,
          username: true,
          usernameHidden: true,
          onewayId: true,
          emailAlias: true,
          showEmailAlias: true,
          showOneWayId: true,
          showNumbers: true,
          preferredCallerIdentity: true,
        },
      });
      res.json({
        token,
        user: {
          id: user.id,
          email: user.email,
          displayName: user.displayName,
          identity,
        },
      });
      logger.info({
        event: "auth.login.succeeded",
        userId: user.id,
        statusCode: 200,
      }, "[auth] login succeeded");
    } catch (err) {
      logger.error({ err }, "[auth] login failed");
      res.status(500).json({ error: "internal_error" });
    }
  });

  return router;
}

function signToken(jwt: JwtModule, secret: string, userId: string): string {
  const ttl = clampTtl(Number(process.env.JWT_TTL_SECONDS ?? 604800));
  return jwt.sign({ sub: userId }, secret, { algorithm: "HS256", expiresIn: ttl });
}

function clampTtl(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 604800;
  return Math.min(value, 60 * 60 * 24 * 30);
}

function redactIdentifier(identifier: string): string {
  const trimmed = identifier.trim();
  if (trimmed.includes("@") && trimmed.includes(".")) {
    const [local, domain] = trimmed.split("@");
    return `${local.slice(0, 2)}…@${domain}`;
  }
  if (trimmed.length <= 4) return trimmed;
  return `${trimmed.slice(0, 2)}…${trimmed.slice(-2)}`;
}

/** Constant-ish delay so login attempts on missing users take similar
 *  wall-clock time to attempts on real users. Roughly bcrypt cost. */
async function timingPad(): Promise<void> {
  await new Promise((r) => setTimeout(r, 100));
}
