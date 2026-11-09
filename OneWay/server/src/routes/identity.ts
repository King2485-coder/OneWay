import express from "express";
import { z } from "zod";
import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import {
  ensureUserRecord,
  isReservedAlias,
  loadPublicIdentity,
  normalizeOneWayId,
  sanitizeEmailAlias,
  sanitizeWalkieName,
} from "../services/identity";

const updateIdentitySchema = z.object({
  displayName: z.string().trim().min(1).max(64).nullable().optional(),
  walkieName: z.string().trim().min(1).max(32).nullable().optional(),
  username: z.string().trim().min(1).max(32).nullable().optional(),
  usernameHidden: z.boolean().optional(),
  onewayId: z.string().trim().min(2).max(32).optional(),
  emailAlias: z.string().trim().min(1).max(64).optional(),
  showEmailAlias: z.boolean().optional(),
  showOneWayId: z.boolean().optional(),
  showNumbers: z.boolean().optional(),
  preferredCallerIdentity: z.enum(["onewayId", "number"]).optional(),
});

export function identityRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/me", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    try {
      await ensureUserRecord(userId);
      const identity = await loadPublicIdentity(userId);
      res.json(identity);
    } catch (error) {
      logger.error({ err: error, userId }, "[identity] fetch failed");
      res.status(500).json({
        error: "identity_fetch_failed",
        message: "We couldn't load your OneWay identity right now.",
      });
    }
  });

  router.patch("/me", async (req, res) => {
    try {
      const userId = (req as unknown as AuthenticatedRequest).userId;
      if (!userId) {
        res.status(401).json({
          error: "missing_user_id",
          message: "Missing authenticated user id.",
        });
        return;
      }

      const parsed = updateIdentitySchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
        return;
      }

      await ensureUserRecord(userId);
      const data = parsed.data;
      const normalizedOneWayId = data.onewayId !== undefined ? normalizeOneWayId(data.onewayId) : undefined;
      const normalizedEmailAlias = data.emailAlias !== undefined ? sanitizeEmailAlias(data.emailAlias) : undefined;

      if (!normalizedOneWayId || !normalizedEmailAlias) {
        res.status(400).json({
          error: "missing_identity_fields",
          message: "OneWay ID and email alias are required.",
        });
        return;
      }

      const emailLocalPart = normalizedEmailAlias.split("@")[0] ?? "";
      if (!/^[a-z0-9._-]+$/.test(emailLocalPart)) {
        res.status(400).json({
          error: "invalid_email_alias",
          message: "Email alias may only contain lowercase letters, numbers, dots, dashes, and underscores.",
        });
        return;
      }
      if (isReservedAlias(emailLocalPart)) {
        res.status(400).json({
          error: "reserved_email_alias",
          message: "That OneWay email alias is reserved.",
        });
        return;
      }

      const existingId = await prisma.oneWayIdentity.findFirst({
        where: {
          onewayId: normalizedOneWayId,
          NOT: { userId },
        },
        select: { id: true },
      });
      if (existingId) {
        res.status(409).json({
          error: "oneway_id_taken",
          message: "That OneWay ID is already taken.",
        });
        return;
      }

      const existingEmail = await prisma.oneWayIdentity.findFirst({
        where: {
          emailAlias: normalizedEmailAlias,
          NOT: { userId },
        },
        select: { id: true },
      });
      if (existingEmail) {
        res.status(409).json({
          error: "email_alias_taken",
          message: "That OneWay email is already taken.",
        });
        return;
      }

      const displayName = data.displayName?.trim() || `OneWay ${userId.slice(0, 6)}`;
      const walkieName = sanitizeWalkieName(data.walkieName ?? displayName);
      const username = data.username?.trim() || normalizedEmailAlias.split("@")[0] || `user_${userId.slice(0, 6)}`;

      await prisma.user.upsert({
        where: { id: userId },
        update: { displayName },
        create: {
          id: userId,
          displayName,
        },
      });

      await prisma.oneWayIdentity.upsert({
        where: { userId },
        update: {
          displayName,
          walkieName,
          username,
          usernameHidden: data.usernameHidden ?? true,
          onewayId: normalizedOneWayId,
          emailAlias: normalizedEmailAlias,
          showEmailAlias: data.showEmailAlias ?? false,
          showOneWayId: data.showOneWayId ?? true,
          showNumbers: data.showNumbers ?? true,
          preferredCallerIdentity: data.preferredCallerIdentity ?? "onewayId",
        },
        create: {
          userId,
          displayName,
          walkieName,
          username,
          usernameHidden: data.usernameHidden ?? true,
          onewayId: normalizedOneWayId,
          emailAlias: normalizedEmailAlias,
          showEmailAlias: data.showEmailAlias ?? false,
          showOneWayId: data.showOneWayId ?? true,
          showNumbers: data.showNumbers ?? true,
          preferredCallerIdentity: data.preferredCallerIdentity ?? "onewayId",
        },
      });

      const identity = await loadPublicIdentity(userId);
      res.json(identity);
    } catch (error) {
      logger.error({ err: error }, "[identity] update failed");
      res.status(500).json({
        error: "identity_creation_failed",
        message: "We couldn't save your OneWay identity right now.",
      });
    }
  });

  return router;
}
