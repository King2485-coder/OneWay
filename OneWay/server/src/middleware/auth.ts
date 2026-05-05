import type { Request, Response, NextFunction } from "express";
import { logger } from "../lib/logger";

/**
 * Auth middleware.
 *
 * Production: verifies a JWT in `Authorization: Bearer <jwt>`. The JWT is
 * minted by `/api/auth/login` and `/api/auth/register` with a configurable
 * TTL (default 7 d) and a single shared `JWT_SECRET`.
 *
 * Dev: when `JWT_AUTH_REQUIRED !== "true"`, also accepts:
 *   - `Authorization: Bearer dev:<userId>`
 *   - `X-Dev-User-Id: <userId>`
 *
 * The dev paths are gated on the env flag — flip `JWT_AUTH_REQUIRED=true`
 * in production and only real JWTs will be accepted.
 */

export interface AuthenticatedRequest extends Request {
  userId: string;
  authMode: "jwt" | "dev";
}

const UUID_LIKE = /^[A-Za-z0-9_\-:.]{1,64}$/;

interface JwtModule {
  verify(token: string, secret: string): unknown;
}

let jwtCache: JwtModule | null | undefined;
function loadJwt(): JwtModule | null {
  if (jwtCache !== undefined) return jwtCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    jwtCache = require("jsonwebtoken") as JwtModule;
  } catch {
    jwtCache = null;
    logger.warn({}, "[auth] jsonwebtoken not installed — JWT auth disabled");
  }
  return jwtCache;
}

export function authMiddleware(req: Request, res: Response, next: NextFunction): void {
  const result = resolveIdentity(req);
  if (!result) {
    res.status(401).json({ error: "unauthenticated" });
    return;
  }
  if (!UUID_LIKE.test(result.userId)) {
    res.status(401).json({ error: "invalid_identity" });
    return;
  }
  (req as AuthenticatedRequest).userId = result.userId;
  (req as AuthenticatedRequest).authMode = result.mode;
  next();
}

/** Same parsing logic for the WebSocket handshake. Returns the userId or null. */
export function parseAuthToken(token: string | undefined): string | null {
  if (!token) return null;
  const trimmed = token.trim();
  // Try JWT first.
  const fromJwt = verifyJwt(trimmed);
  if (fromJwt) return fromJwt;
  if (devAllowed()) {
    if (trimmed.startsWith("dev:")) {
      const id = trimmed.slice(4);
      return UUID_LIKE.test(id) ? id : null;
    }
    if (UUID_LIKE.test(trimmed)) return trimmed;
  }
  return null;
}

function resolveIdentity(req: Request): { userId: string; mode: "jwt" | "dev" } | null {
  const auth = req.headers.authorization;
  if (typeof auth === "string" && auth.startsWith("Bearer ")) {
    const token = auth.slice("Bearer ".length).trim();
    const fromJwt = verifyJwt(token);
    if (fromJwt) return { userId: fromJwt, mode: "jwt" };
    if (devAllowed()) {
      if (token.startsWith("dev:")) {
        const id = token.slice(4);
        if (UUID_LIKE.test(id)) return { userId: id, mode: "dev" };
      } else if (UUID_LIKE.test(token)) {
        return { userId: token, mode: "dev" };
      }
    }
  }
  if (devAllowed()) {
    const dev = req.headers["x-dev-user-id"];
    const value = Array.isArray(dev) ? dev[0] : dev;
    if (typeof value === "string" && UUID_LIKE.test(value)) {
      return { userId: value, mode: "dev" };
    }
  }
  return null;
}

function verifyJwt(token: string): string | null {
  // JWTs always have at least one period and aren't UUID-like.
  if (!token.includes(".")) return null;
  const secret = process.env.JWT_SECRET;
  if (!secret) return null;
  const jwt = loadJwt();
  if (!jwt) return null;
  try {
    const decoded = jwt.verify(token, secret) as Record<string, unknown> | string;
    if (typeof decoded === "string") return null;
    const sub = decoded.sub;
    if (typeof sub === "string" && UUID_LIKE.test(sub)) return sub;
    return null;
  } catch (err) {
    logger.debug({ err }, "[auth] jwt verify failed");
    return null;
  }
}

function devAllowed(): boolean {
  return process.env.JWT_AUTH_REQUIRED !== "true";
}
