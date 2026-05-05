import express from "express";
import { z } from "zod";
import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import { authRateLimit } from "../lib/rateLimit";

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
  password: z.string().min(8).max(200),
  displayName: z.string().min(1).max(64).optional(),
});

const loginSchema = credentialsSchema.pick({ email: true, password: true });

export function authRouter(): express.Router {
  const router = express.Router();
  router.use(authRateLimit());

  router.post("/register", async (req, res) => {
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
      const token = signToken(jwt, secret, user.id);
      logger.info({ userId: user.id }, "[auth] registered");
      res.status(201).json({
        token,
        user: { id: user.id, email: user.email, displayName: user.displayName },
      });
    } catch (err) {
      logger.error({ err }, "[auth] register failed");
      res.status(500).json({ error: "internal_error" });
    }
  });

  router.post("/login", async (req, res) => {
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
    const email = parsed.data.email.toLowerCase();
    try {
      const user = await prisma.user.findUnique({ where: { email } });
      // Same response on missing user vs. wrong password — we do NOT leak
      // whether the email is registered.
      if (!user || !user.passwordHash) {
        await timingPad();
        res.status(401).json({ error: "invalid_credentials" });
        return;
      }
      const ok = await bcrypt.compare(parsed.data.password, user.passwordHash);
      if (!ok) {
        res.status(401).json({ error: "invalid_credentials" });
        return;
      }
      const token = signToken(jwt, secret, user.id);
      res.json({
        token,
        user: { id: user.id, email: user.email, displayName: user.displayName },
      });
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

/** Constant-ish delay so login attempts on missing users take similar
 *  wall-clock time to attempts on real users. Roughly bcrypt cost. */
async function timingPad(): Promise<void> {
  await new Promise((r) => setTimeout(r, 100));
}
