import express from "express";
import { prisma } from "../lib/db";
import { chirpLookupRateLimit, userSearchRateLimit } from "../lib/rateLimit";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import {
  chirpLookupCandidates,
  ensureUserChirpId,
  loadPublicIdentity,
  normalizeChirpId,
} from "../services/identity";

export function usersRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/search", userSearchRateLimit(), async (req, res) => {
    const requesterId = (req as AuthenticatedRequest).userId;
    const q = typeof req.query.q === "string" ? req.query.q.trim() : "";
    if (!q) {
      res.json({ users: [] });
      return;
    }

    const normalizedQuery = q.toLowerCase();
    const chirpCandidates = chirpLookupCandidates(q);
    const users = await prisma.user.findMany({
      where: {
        OR: [
          { id: { contains: q } },
          { displayName: { contains: q } },
          { chirpIdNormalized: { in: chirpCandidates } },
          { identity: { is: { displayName: { contains: q } } } },
          { identity: { is: { onewayId: { contains: q.toLowerCase() } } } },
          {
            identity: {
              is: {
                showEmailAlias: true,
                emailAlias: { contains: normalizedQuery },
              },
            },
          },
          {
            identity: {
              is: {
                usernameHidden: false,
                username: { contains: q },
              },
            },
          },
          {
            AND: [
              { numbers: { some: { number: { contains: q } } } },
              { identity: { is: { showNumbers: true } } },
            ],
          },
        ],
        NOT: { id: requesterId },
      },
      select: {
        id: true,
        displayName: true,
        chirpId: true,
        chirpIdNormalized: true,
        identity: {
          select: {
            displayName: true,
            username: true,
            usernameHidden: true,
            onewayId: true,
            emailAlias: true,
            showEmailAlias: true,
            showOneWayId: true,
            showNumbers: true,
            preferredCallerIdentity: true,
          },
        },
        numbers: {
          orderBy: [{ isPrimary: "desc" }, { createdAt: "asc" }],
          take: 3,
          select: {
            id: true,
            number: true,
            isPrimary: true,
            label: true,
          },
        },
      },
      take: 20,
    });

    res.json({
      users: await Promise.all(users.map(async (user) => {
        const identity = user.identity ?? await loadPublicIdentity(user.id);
        const chirpId = user.chirpId?.trim() || await ensureUserChirpId(prisma, user.id);
        const friendshipState = await friendshipStateFor(requesterId, user.id);
        return {
          id: user.id,
          displayName: identity.displayName ?? user.displayName,
          onewayId: identity.showOneWayId ? identity.onewayId : null,
          chirpId,
          emailAlias: identity.showEmailAlias ? identity.emailAlias : null,
          username: !identity.usernameHidden || user.id == requesterId ? identity.username : null,
          primaryNumber: identity.showNumbers ? user.numbers[0]?.number ?? null : null,
          isOneWayReachable: Boolean(identity.showOneWayId ? identity.onewayId : user.numbers[0]?.number),
          friendshipState,
        };
      })),
    });
  });

  router.get("/by-chirp-id/:chirpId", chirpLookupRateLimit(), async (req, res) => {
    const requesterId = (req as AuthenticatedRequest).userId;
    const rawChirpId = Array.isArray(req.params.chirpId) ? req.params.chirpId[0] : req.params.chirpId;
    const candidates = chirpLookupCandidates(rawChirpId ?? "");
    if (candidates.length === 0 || !candidates.some((candidate) => /^OW[0-9]{6,9}$/.test(candidate))) {
      res.status(400).json({
        error: "invalid_chirp_id",
        message: "Enter a valid OneWay Chirp ID.",
      });
      return;
    }

    const user = await prisma.user.findFirst({
      where: {
        chirpIdNormalized: { in: candidates.map(normalizeChirpId) },
        NOT: { id: requesterId },
      },
      select: {
        id: true,
        displayName: true,
        chirpId: true,
        identity: {
          select: {
            displayName: true,
            username: true,
            usernameHidden: true,
            onewayId: true,
            emailAlias: true,
            showEmailAlias: true,
            showOneWayId: true,
            showNumbers: true,
            preferredCallerIdentity: true,
          },
        },
      },
    });

    if (!user) {
      res.status(404).json({ error: "user_not_found" });
      return;
    }

    const identity = user.identity ?? await loadPublicIdentity(user.id);
    const chirpId = user.chirpId?.trim() || await ensureUserChirpId(prisma, user.id);
    res.json({
      user: {
        id: user.id,
        displayName: identity.displayName ?? user.displayName,
        onewayId: identity.showOneWayId ? identity.onewayId : null,
        chirpId,
        emailAlias: identity.showEmailAlias ? identity.emailAlias : null,
        username: !identity.usernameHidden ? identity.username : null,
        primaryNumber: null,
        isOneWayReachable: true,
        friendshipState: await friendshipStateFor(requesterId, user.id),
      },
    });
  });

  return router;
}

async function friendshipStateFor(requesterId: string, targetUserId: string): Promise<string> {
  const contact = await prisma.oneWayContact.findUnique({
    where: {
      userId_contactUserId: {
        userId: requesterId,
        contactUserId: targetUserId,
      },
    },
    select: {
      status: true,
      direction: true,
    },
  });

  if (!contact || contact.status === "removed") return "none";
  if (contact.status === "connected") return "accepted";
  if (contact.status === "blocked") return "blocked";
  if (contact.status === "pending" && contact.direction === "incoming") return "pendingIncoming";
  if (contact.status === "pending") return "pendingOutgoing";
  return contact.status;
}
