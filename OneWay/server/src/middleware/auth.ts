import type { Request, Response, NextFunction } from "express";
import { logger } from "../lib/logger";

/**
 * Auth middleware.
 *
 * Production: verifies a JWT in `Authorization: Bearer <jwt>`. The JWT is
 * minted by `/api/auth/login` and `/api/auth/register` with a configurable
 * TTL (default 7 d) and a single shared `JWT_SECRET`.
 *
 * Dev: when `NODE_ENV !== "production"` and `JWT_AUTH_REQUIRED !== "true"`, also accepts:
 *   - `Authorization: Bearer dev:<userId>`
 *   - `X-Dev-User-Id: <userId>`
 *
 * The dev paths are gated on NODE_ENV so production only accepts real JWTs.
 */

export interface AuthenticatedRequest extends Request {
  userId: string;
  authMode: "jwt" | "dev";
}

const UUID_LIKE = /^[A-Za-z0-9_\-:.]{1,64}$/;
const UUID_CANONICAL =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

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

export async function authMiddleware(req: Request, res: Response, next: NextFunction): Promise<void> {
  const authHeader = req.headers.authorization || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");

  if (
    process.env.NODE_ENV !== "production" &&
    process.env.ONEWAY_DEV_AUTH_TOKEN &&
    token === process.env.ONEWAY_DEV_AUTH_TOKEN
  ) {
    (req as any).user = {
      uid: "dev-user",
      email: "dev@oneway.local",
      devAuth: true,
    };
    (req as AuthenticatedRequest).userId = "dev-user";
    (req as AuthenticatedRequest).authMode = "dev";

    next();
    return;
  }

  const result = resolveIdentity(req);
  if (!result) {
    auditAuthFailure(req, "unauthenticated");
    res.status(401).json({ error: "unauthenticated" });
    return;
  }
  if (!UUID_LIKE.test(result.userId)) {
    auditAuthFailure(req, "invalid_identity");
    res.status(401).json({ error: "invalid_identity" });
    return;
  }
  if (result.mode === "jwt") {
    try {
      // JWTs are stateless, so a previously issued token would otherwise keep
      // working after account deletion. Requiring the subject to still exist
      // makes deletion revoke every outstanding token immediately.
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const { prisma } = require("../lib/db");
      const activeUser = await prisma.user.findUnique({
        where: { id: canonicalUserId(result.userId) },
        select: { id: true, accountStatus: true },
      });
      if (!activeUser || activeUser.accountStatus !== "active") {
        auditAuthFailure(req, "deleted_or_missing_account");
        res.status(401).json({ error: "account_not_active" });
        return;
      }
    } catch (error) {
      logger.error({ err: error }, "[auth] account status lookup failed");
      res.status(503).json({ error: "authentication_temporarily_unavailable" });
      return;
    }
  }
  (req as AuthenticatedRequest).userId = canonicalUserId(result.userId);
  (req as AuthenticatedRequest).authMode = result.mode;
  next();
}

/** Same parsing logic for the WebSocket handshake. Returns the userId or null. */
export function parseAuthToken(token: string | undefined): string | null {
  if (!token) return null;
  const trimmed = token.trim();
  if (
    process.env.NODE_ENV !== "production" &&
    process.env.ONEWAY_DEV_AUTH_TOKEN &&
    trimmed === process.env.ONEWAY_DEV_AUTH_TOKEN
  ) {
    return "dev-user";
  }
  // Try JWT first.
  const fromJwt = verifyJwt(trimmed);
  if (fromJwt) return fromJwt;
  if (devAllowed()) {
    if (trimmed.startsWith("dev:")) {
      const id = trimmed.slice(4);
      return UUID_LIKE.test(id) ? canonicalUserId(id) : null;
    }
    if (UUID_LIKE.test(trimmed)) return canonicalUserId(trimmed);
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
        if (UUID_LIKE.test(id)) return { userId: canonicalUserId(id), mode: "dev" };
      } else if (UUID_LIKE.test(token)) {
        return { userId: canonicalUserId(token), mode: "dev" };
      }
    }
  }
  if (devAllowed()) {
    const dev = req.headers["x-dev-user-id"];
    const value = Array.isArray(dev) ? dev[0] : dev;
    if (typeof value === "string" && UUID_LIKE.test(value)) {
      return { userId: canonicalUserId(value), mode: "dev" };
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
    if (typeof sub === "string" && UUID_LIKE.test(sub)) return canonicalUserId(sub);
    return null;
  } catch (err) {
    logger.debug({ err }, "[auth] jwt verify failed");
    return null;
  }
}

function devAllowed(): boolean {
  return process.env.NODE_ENV !== "production" && process.env.JWT_AUTH_REQUIRED !== "true";
}

function canonicalUserId(value: string): string {
  return UUID_CANONICAL.test(value) ? value.toLowerCase() : value;
}

function auditAuthFailure(req: Request, reason: string): void {
  try {
    // Lazy-load to keep middleware usable in auth-only/unit contexts and avoid
    // creating a database client before normal server startup.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { prisma } = require("../lib/db");
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { recordAuditEventSafe } = require("../services/audit/AuditEventService");
    void recordAuditEventSafe(prisma, {
      actorType: "public",
      action: "auth.failure",
      resourceType: "auth",
      metadata: {
        reason,
        method: req.method,
        path: req.path,
        hasAuthorization: Boolean(req.headers.authorization),
      },
    });
  } catch {
    // Auth failure handling must never fail the response path.
  }
}
