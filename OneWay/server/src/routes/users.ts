import express, {type RequestHandler} from "express";
import type {PrismaClient} from "@prisma/client";
import { ghostUsers, approvedContacts, matchesExactContact, ghostMode } from "../services/AccountVisibility";
import { prisma } from "../lib/db";
import { chirpLookupRateLimit, userSearchRateLimit } from "../lib/rateLimit";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import {
  chirpLookupCandidates,
  ensureUserChirpId,
  loadPublicIdentity,
  normalizeChirpId,
} from "../services/identity";

export function usersRouter(deps?: {db: PrismaClient; authenticate: RequestHandler}): express.Router {
  const client = deps?.db ?? prisma;
  const router = express.Router();
  const wrap = (action: (req: express.Request, res: express.Response) => Promise<unknown>): RequestHandler => (req, res, next) => { void action(req, res).catch(next); };
  router.use(deps?.authenticate ?? authMiddleware);

  router.get("/search", userSearchRateLimit(), wrap(async (req, res) => {
    const requesterId = (req as AuthenticatedRequest).userId;
    const q = typeof req.query.q === "string" ? req.query.q.trim() : "";
    if (!q) {
      res.json({ users: [] });
      return;
    }

    const normalizedQuery = q.toLowerCase();
    const chirpCandidates = chirpLookupCandidates(q);
    const hidden = new Set(await ghostUsers(client));
    const approved = new Set(await approvedContacts(client, requesterId));
    const users = await client.user.findMany({
      where: {
        OR: [
          {AND: [{id: {notIn: [...hidden]}}, {OR: [
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
        ]}]},
          {AND: [{id: {in: [...hidden]}}, {OR: [
            {identity: {is: {onewayId: "@" + normalizedQuery.replace(/^@/, "")}}},
            {chirpIdNormalized: normalizedQuery.toUpperCase()},
            {identity: {is: {emailAlias: normalizedQuery}}},
            {numbers: {some: {number: q.startsWith("+") ? "+" + q.replace(/[^0-9]/g, "") : q.replace(/[^0-9]/g, "").length === 10 ? "+1" + q.replace(/[^0-9]/g, "") : "+" + q.replace(/[^0-9]/g, "")}}}
          ]}]}
        ],
        accountStatus: "active", publicProfileHiddenAt: null,
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
      users: await Promise.all(users.filter(user => !hidden.has(user.id) || approved.has(user.id) || matchesExactContact(q, user)).map(async (user) => {
        const identity = user.identity ?? await loadPublicIdentity(user.id);
        if (hidden.has(user.id) && !approved.has(user.id)) return {id: user.id, displayName: "Private OneWay account", matchedIdentifier: q, onewayId: user.identity?.onewayId?.toLowerCase().replace(/^@/, "") === normalizedQuery.replace(/^@/, "") ? user.identity.onewayId : null, chirpId: user.chirpId?.toLowerCase() === normalizedQuery ? user.chirpId : null, emailAlias: user.identity?.emailAlias?.toLowerCase() === normalizedQuery ? user.identity.emailAlias : null, username: null, primaryNumber: null, isOneWayReachable: false, friendshipState: await friendshipStateFor(requesterId, user.id, client)};
        const chirpId = user.chirpId?.trim() || await ensureUserChirpId(client, user.id);
        const friendshipState = await friendshipStateFor(requesterId, user.id, client);
        return {
          id: user.id,
          matchedIdentifier: matchesExactContact(q, user) ? q : null,
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
  }));

  router.get("/by-chirp-id/:chirpId", chirpLookupRateLimit(), wrap(async (req, res) => {
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

    const user = await client.user.findFirst({
      where: {
        chirpIdNormalized: { in: candidates.map(normalizeChirpId) },
        accountStatus: "active", publicProfileHiddenAt: null,
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

    if (await ghostMode(client, user.id) && !(await approvedContacts(client, requesterId)).includes(user.id)) { res.json({user: {id: user.id, displayName: "Private OneWay account", onewayId: null, chirpId: rawChirpId, emailAlias: null, username: null, primaryNumber: null, isOneWayReachable: false, friendshipState: await friendshipStateFor(requesterId, user.id, client)}}); return; }
    const identity = user.identity ?? await loadPublicIdentity(user.id);
    const chirpId = user.chirpId?.trim() || await ensureUserChirpId(client, user.id);
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
        friendshipState: await friendshipStateFor(requesterId, user.id, client),
      },
    });
  }));

  return router;
}

async function friendshipStateFor(requesterId: string, targetUserId: string, client: PrismaClient = prisma): Promise<string> {
  const contact = await client.oneWayContact.findUnique({
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
