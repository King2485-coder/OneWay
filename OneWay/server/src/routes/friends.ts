import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Friendship, PrismaClient } from "@prisma/client";
import { addColumnIfMissing } from "../lib/runtimeSchemaPatch";
import { logger } from "../lib/logger";
import { shortId } from "../lib/privacy/redaction";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserChirpId, ensureUserRecord, loadPublicIdentity } from "../services/identity";
import type { FriendRealtimeServer } from "../realtime/FriendRealtimeServer";

type FriendshipStatus = "pending" | "accepted" | "declined" | "blocked" | "removed";

type FriendsRouterDeps = {
  prisma: PrismaClient;
  realtime?: FriendRealtimeServer;
};

type ContactProjectionClient = {
  oneWayContact: PrismaClient["oneWayContact"];
};

const requestSchema = z.object({
  recipientUserId: z.string().trim().min(1).max(128),
});

const emptySchema = z.object({}).passthrough();

export async function ensureFriendshipTable(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "Friendship" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "requesterUserId" TEXT NOT NULL,
      "recipientUserId" TEXT NOT NULL,
      "pairKey" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'pending',
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "acceptedAt" TIMESTAMP,
      "deniedAt" TIMESTAMP,
      "ignoredAt" TIMESTAMP,
      "declinedAt" TIMESTAMP,
      "blockedAt" TIMESTAMP,
      "removedAt" TIMESTAMP
    )
  `);
  await addColumnIfMissing(prisma, {
    table: "Friendship",
    columnDefinition: `"acceptedAt" TIMESTAMP`,
    logPrefix: "friendship schema patch",
  });
  await addColumnIfMissing(prisma, {
    table: "Friendship",
    columnDefinition: `"declinedAt" TIMESTAMP`,
    logPrefix: "friendship schema patch",
  });
  await addColumnIfMissing(prisma, {
    table: "Friendship",
    columnDefinition: `"deniedAt" TIMESTAMP`,
    logPrefix: "friendship schema patch",
  });
  await addColumnIfMissing(prisma, {
    table: "Friendship",
    columnDefinition: `"ignoredAt" TIMESTAMP`,
    logPrefix: "friendship schema patch",
  });
  await addColumnIfMissing(prisma, {
    table: "Friendship",
    columnDefinition: `"blockedAt" TIMESTAMP`,
    logPrefix: "friendship schema patch",
  });
  await addColumnIfMissing(prisma, {
    table: "Friendship",
    columnDefinition: `"removedAt" TIMESTAMP`,
    logPrefix: "friendship schema patch",
  });
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "Friendship_pairKey_key" ON "Friendship"("pairKey")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Friendship_requesterUserId_idx" ON "Friendship"("requesterUserId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Friendship_recipientUserId_idx" ON "Friendship"("recipientUserId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Friendship_status_idx" ON "Friendship"("status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Friendship_recipientUserId_status_idx" ON "Friendship"("recipientUserId", "status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Friendship_requesterUserId_status_idx" ON "Friendship"("requesterUserId", "status")`);
  await backfillFriendshipsFromContacts(prisma);
}

export function friendsRouter({ prisma, realtime }: FriendsRouterDeps): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/overview", async (req, res) => {
    const startedAt = Date.now();
    const userId = currentUserId(req);
    await ensureUserRecord(userId);

    const [contacts, incoming, outgoing] = await Promise.all([
      prisma.oneWayContact.findMany({
        where: { userId, status: "connected" },
        orderBy: { updatedAt: "desc" },
        take: 250,
      }),
      prisma.friendship.findMany({
        where: { recipientUserId: userId, status: "pending" },
        orderBy: { createdAt: "desc" },
        take: 100,
      }),
      prisma.friendship.findMany({
        where: { requesterUserId: userId, status: "pending" },
        orderBy: { createdAt: "desc" },
        take: 100,
      }),
    ]);

    const [mappedContacts, incomingRequests, outgoingRequests] = await Promise.all([
      Promise.all(contacts.map((contact) => mapAcceptedFriend(prisma, contact.contactUserId, contact.id))),
      Promise.all(incoming.map((friendship) => mapRequest(prisma, friendship, userId))),
      Promise.all(outgoing.map((friendship) => mapRequest(prisma, friendship, userId))),
    ]);

    logger.info({
      userId: shortId(userId),
      contacts: mappedContacts.length,
      incoming: incomingRequests.length,
      outgoing: outgoingRequests.length,
      elapsedMs: Date.now() - startedAt,
    }, "[friends] overview");

    res.json({ contacts: mappedContacts, incomingRequests, outgoingRequests });
  });

  router.get("/", async (req, res) => {
    const userId = currentUserId(req);
    await ensureUserRecord(userId);
    const contacts = await prisma.oneWayContact.findMany({
      where: { userId, status: "connected" },
      orderBy: { updatedAt: "desc" },
    });
    res.json({ contacts: await Promise.all(contacts.map((contact) => mapAcceptedFriend(prisma, contact.contactUserId, contact.id))) });
  });

  router.get("/requests/incoming", async (req, res) => {
    const userId = currentUserId(req);
    await ensureUserRecord(userId);
    const requests = await prisma.friendship.findMany({
      where: {
        recipientUserId: userId,
        status: "pending",
      },
      orderBy: { createdAt: "desc" },
    });
    logger.info({
      receiverCurrentUserId: shortId(userId),
      requestStatus: "pending",
      uiItemCount: requests.length,
    }, "[friends] incoming pending query");
    res.json({ requests: await Promise.all(requests.map((friendship) => mapRequest(prisma, friendship, userId))) });
  });

  router.get("/requests/outgoing", async (req, res) => {
    const userId = currentUserId(req);
    await ensureUserRecord(userId);
    const requests = await prisma.friendship.findMany({
      where: {
        requesterUserId: userId,
        status: "pending",
      },
      orderBy: { createdAt: "desc" },
    });
    logger.info({
      requesterUserId: shortId(userId),
      requestStatus: "pending",
      uiItemCount: requests.length,
    }, "[friends] outgoing pending query");
    res.json({ requests: await Promise.all(requests.map((friendship) => mapRequest(prisma, friendship, userId))) });
  });

  router.post("/request", async (req, res) => {
    const requesterUserId = currentUserId(req);
    await ensureUserRecord(requesterUserId);

    const parsed = requestSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ success: false, code: "INVALID_BODY", issues: parsed.error.issues });
      return;
    }

    const recipientUserId = parsed.data.recipientUserId.trim();
    logger.info({
      requesterUserId: shortId(requesterUserId),
      recipientUserId: shortId(recipientUserId),
      currentUserId: shortId(requesterUserId),
      calculatedDirection: "outgoing",
      timestamp: new Date().toISOString(),
    }, "chirp.request.create.started");

    if (sameUser(requesterUserId, recipientUserId)) {
      res.status(400).json({ success: false, code: "SELF_REQUEST_FORBIDDEN" });
      return;
    }

    const recipient = await prisma.user.findUnique({
      where: { id: recipientUserId },
      select: { id: true },
    });
    if (!recipient) {
      res.status(404).json({ success: false, code: "RECIPIENT_NOT_FOUND" });
      return;
    }

    const pairKey = friendshipPairKey(requesterUserId, recipientUserId);
    const existing = await prisma.friendship.findUnique({ where: { pairKey } });
    const blocked = existing?.status === "blocked" || await isBlocked(prisma, requesterUserId, recipientUserId);
    if (blocked) {
      res.status(403).json({ success: false, code: "BLOCKED" });
      return;
    }

    if (existing?.status === "accepted") {
      res.status(200).json({ success: false, code: "ALREADY_FRIENDS", friendship: await mapFriendship(existing) });
      return;
    }

    if (existing?.status === "pending") {
      const code = sameUser(existing.requesterUserId, requesterUserId)
        ? "OUTGOING_REQUEST_ALREADY_EXISTS"
        : "INCOMING_REQUEST_ALREADY_EXISTS";
      await upsertPendingContacts(prisma, existing.requesterUserId, existing.recipientUserId);
      const request = await mapRequest(prisma, existing, requesterUserId);
      let deliveredSockets = 0;
      if (sameUser(existing.requesterUserId, requesterUserId)) {
        const eventPayload = await friendRequestPayload(prisma, existing);
        deliveredSockets = realtime?.sendToUser(existing.recipientUserId, "chirp.request.received", eventPayload) ?? 0;
        logger.info({
          requestId: existing.id,
          friendshipId: existing.id,
          requesterUserId: shortId(existing.requesterUserId),
          recipientUserId: shortId(existing.recipientUserId),
          currentUserId: shortId(requesterUserId),
          requestStatus: existing.status,
          httpResponseStatus: 200,
          socketEventName: "chirp.request.received",
          targetSocketUser: shortId(existing.recipientUserId),
          socketDestination: shortId(existing.recipientUserId),
          deliveredSockets,
          timestamp: new Date().toISOString(),
        }, "chirp.request.realtime.resent");
      }
      res.status(200).json({
        success: false,
        code,
        friendship: await mapFriendship(existing),
        request,
        resent: sameUser(existing.requesterUserId, requesterUserId),
        deliveredSockets,
      });
      return;
    }

    const friendship = await prisma.$transaction(async (tx) => {
      const row = await tx.friendship.upsert({
        where: { pairKey },
        update: {
          requesterUserId,
          recipientUserId,
          status: "pending",
          acceptedAt: null,
          deniedAt: null,
          ignoredAt: null,
          declinedAt: null,
          blockedAt: null,
          removedAt: null,
        },
        create: {
          id: randomUUID(),
          requesterUserId,
          recipientUserId,
          pairKey,
          status: "pending",
        },
      });
      await upsertPendingContacts(tx, requesterUserId, recipientUserId);
      return row;
    });

    const eventPayload = await friendRequestPayload(prisma, friendship);
    const deliveredSockets = realtime?.sendToUser(recipientUserId, "chirp.request.received", eventPayload) ?? 0;
    logger.info({
      requestId: friendship.id,
      requesterUserId: shortId(requesterUserId),
      recipientUserId: shortId(recipientUserId),
      currentUserId: shortId(requesterUserId),
      calculatedDirection: "outgoing",
      timestamp: new Date().toISOString(),
    }, "chirp.request.persisted");
    logger.info({
      requestId: friendship.id,
      friendshipId: friendship.id,
      requesterUserId: shortId(requesterUserId),
      recipientUserId: shortId(recipientUserId),
      currentUserId: shortId(requesterUserId),
      requestStatus: friendship.status,
      httpResponseStatus: 201,
      socketEventName: "chirp.request.received",
      targetSocketUser: shortId(recipientUserId),
      socketDestination: shortId(recipientUserId),
      deliveredSockets,
      timestamp: new Date().toISOString(),
    }, "chirp.request.realtime.sent");

    res.status(201).json({
      success: true,
      friendship: await mapFriendship(friendship),
      request: await mapRequest(prisma, friendship, requesterUserId),
    });
  });

  router.post("/:friendshipId/accept", async (req, res) => {
    const recipientUserId = currentUserId(req);
    const parsed = emptySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ success: false, code: "INVALID_BODY", issues: parsed.error.issues });
      return;
    }

    const friendship = await prisma.friendship.findUnique({ where: { id: req.params.friendshipId } });
    if (!friendship) {
      res.status(404).json({ success: false, code: "FRIENDSHIP_NOT_FOUND" });
      return;
    }
    if (!sameUser(friendship.recipientUserId, recipientUserId)) {
      res.status(403).json({ success: false, code: "ONLY_RECIPIENT_CAN_ACCEPT" });
      return;
    }
    if (friendship.status === "accepted") {
      res.json({ success: true, friendship: await mapFriendship(friendship) });
      return;
    }
    if (friendship.status !== "pending") {
      res.status(409).json({ success: false, code: "FRIENDSHIP_NOT_PENDING", friendship: await mapFriendship(friendship) });
      return;
    }

    const acceptedAt = new Date();
    const accepted = await prisma.$transaction(async (tx) => {
      const row = await tx.friendship.update({
        where: { id: friendship.id },
        data: {
          status: "accepted",
          acceptedAt,
          deniedAt: null,
          ignoredAt: null,
          declinedAt: null,
          blockedAt: null,
          removedAt: null,
        },
      });
      await connectContactPair(tx, friendship.requesterUserId, friendship.recipientUserId, acceptedAt);
      return row;
    });

    const payload = await friendAcceptedPayload(prisma, accepted);
    const deliveredRecipient = realtime?.sendToUser(accepted.recipientUserId, "chirp.request.accepted", payload) ?? 0;
    const deliveredRequester = realtime?.sendToUser(accepted.requesterUserId, "chirp.request.accepted", payload) ?? 0;
    logger.info({
      requestId: accepted.id,
      friendshipId: accepted.id,
      requesterUserId: shortId(accepted.requesterUserId),
      recipientUserId: shortId(accepted.recipientUserId),
      requestStatus: accepted.status,
      socketEventName: "chirp.request.accepted",
      deliveredSockets: deliveredRecipient + deliveredRequester,
      timestamp: new Date().toISOString(),
    }, "chirp.request.accepted");

    res.json({ success: true, friendship: await mapFriendship(accepted) });
  });

  router.post("/:friendshipId/decline", async (req, res) => {
    const recipientUserId = currentUserId(req);
    const parsed = emptySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ success: false, code: "INVALID_BODY", issues: parsed.error.issues });
      return;
    }

    const friendship = await prisma.friendship.findUnique({ where: { id: req.params.friendshipId } });
    if (!friendship) {
      res.status(404).json({ success: false, code: "FRIENDSHIP_NOT_FOUND" });
      return;
    }
    if (!sameUser(friendship.recipientUserId, recipientUserId)) {
      res.status(403).json({ success: false, code: "ONLY_RECIPIENT_CAN_DECLINE" });
      return;
    }
    if (friendship.status === "declined") {
      res.json({ success: true, friendship: await mapFriendship(friendship) });
      return;
    }
    if (friendship.status !== "pending") {
      res.status(409).json({ success: false, code: "FRIENDSHIP_NOT_PENDING", friendship: await mapFriendship(friendship) });
      return;
    }

    const deniedAt = new Date();
    const declined = await prisma.$transaction(async (tx) => {
      const row = await tx.friendship.update({
        where: { id: friendship.id },
        data: {
          status: "declined",
          deniedAt,
          declinedAt: deniedAt,
          removedAt: null,
        },
      });
      await tx.oneWayContact.updateMany({
        where: {
          OR: [
            { userId: friendship.requesterUserId, contactUserId: friendship.recipientUserId, status: "pending" },
            { userId: friendship.recipientUserId, contactUserId: friendship.requesterUserId, status: "pending" },
          ],
        },
        data: {
          status: "removed",
          direction: "removed",
          removedAt: deniedAt,
        },
      });
      return row;
    });

    const payload = { requestId: declined.id, friendshipId: declined.id, friendship: await mapFriendship(declined) };
    realtime?.sendToUser(declined.recipientUserId, "chirp.request.denied", payload);
    realtime?.sendToUser(declined.requesterUserId, "chirp.request.denied", payload);
    logger.info({
      requestId: declined.id,
      friendshipId: declined.id,
      requesterUserId: shortId(declined.requesterUserId),
      recipientUserId: shortId(declined.recipientUserId),
      requestStatus: declined.status,
      socketEventName: "chirp.request.denied",
      timestamp: new Date().toISOString(),
    }, "chirp.request.denied");

    res.json({ success: true, friendship: await mapFriendship(declined) });
  });

  router.post("/:friendshipId/ignore", async (req, res) => {
    const recipientUserId = currentUserId(req);
    const parsed = emptySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ success: false, code: "INVALID_BODY", issues: parsed.error.issues });
      return;
    }

    const friendship = await prisma.friendship.findUnique({ where: { id: req.params.friendshipId } });
    if (!friendship) {
      res.status(404).json({ success: false, code: "FRIENDSHIP_NOT_FOUND" });
      return;
    }
    if (!sameUser(friendship.recipientUserId, recipientUserId)) {
      res.status(403).json({ success: false, code: "ONLY_RECIPIENT_CAN_IGNORE" });
      return;
    }
    if (friendship.status !== "pending") {
      res.status(409).json({ success: false, code: "FRIENDSHIP_NOT_PENDING", friendship: await mapFriendship(friendship) });
      return;
    }

    const ignoredAt = new Date();
    const ignored = await prisma.friendship.update({
      where: { id: friendship.id },
      data: { ignoredAt },
    });
    const payload = {
      requestId: ignored.id,
      friendshipId: ignored.id,
      friendship: await mapFriendship(ignored),
    };
    realtime?.sendToUser(ignored.recipientUserId, "chirp.request.ignored", payload);
    logger.info({
      requestId: ignored.id,
      friendshipId: ignored.id,
      requesterUserId: shortId(ignored.requesterUserId),
      recipientUserId: shortId(ignored.recipientUserId),
      requestStatus: ignored.status,
      socketEventName: "chirp.request.ignored",
      timestamp: new Date().toISOString(),
    }, "chirp.request.ignored");

    res.json({ success: true, friendship: await mapFriendship(ignored) });
  });

  router.post("/:friendshipId/block", async (req, res) => {
    const actorUserId = currentUserId(req);
    const parsed = emptySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ success: false, code: "INVALID_BODY", issues: parsed.error.issues });
      return;
    }

    const friendship = await prisma.friendship.findUnique({ where: { id: req.params.friendshipId } });
    if (!friendship) {
      res.status(404).json({ success: false, code: "FRIENDSHIP_NOT_FOUND" });
      return;
    }
    if (!sameUser(friendship.requesterUserId, actorUserId) && !sameUser(friendship.recipientUserId, actorUserId)) {
      res.status(403).json({ success: false, code: "ONLY_PARTICIPANT_CAN_BLOCK" });
      return;
    }

    const blockedAt = new Date();
    const blocked = await prisma.$transaction(async (tx) => {
      const row = await tx.friendship.update({
        where: { id: friendship.id },
        data: {
          status: "blocked",
          blockedAt,
          removedAt: null,
        },
      });
      await blockContactPair(tx, friendship.requesterUserId, friendship.recipientUserId, blockedAt);
      return row;
    });

    const payload = {
      requestId: blocked.id,
      friendshipId: blocked.id,
      actorUserId,
      friendship: await mapFriendship(blocked),
    };
    realtime?.sendToUser(blocked.recipientUserId, "chirp.request.blocked", payload);
    realtime?.sendToUser(blocked.requesterUserId, "chirp.request.blocked", payload);
    logger.info({
      requestId: blocked.id,
      friendshipId: blocked.id,
      requesterUserId: shortId(blocked.requesterUserId),
      recipientUserId: shortId(blocked.recipientUserId),
      requestStatus: blocked.status,
      socketEventName: "chirp.request.blocked",
      timestamp: new Date().toISOString(),
    }, "chirp.request.blocked");

    res.json({ success: true, friendship: await mapFriendship(blocked) });
  });

  router.delete("/:friendshipId", async (req, res) => {
    const actorUserId = currentUserId(req);
    const friendship = await prisma.friendship.findUnique({ where: { id: req.params.friendshipId } });
    if (!friendship) {
      res.status(404).json({ success: false, code: "FRIENDSHIP_NOT_FOUND" });
      return;
    }
    if (!sameUser(friendship.requesterUserId, actorUserId)) {
      res.status(403).json({ success: false, code: "ONLY_REQUESTER_CAN_CANCEL" });
      return;
    }
    if (friendship.status !== "pending") {
      res.status(409).json({ success: false, code: "FRIENDSHIP_NOT_PENDING", friendship: await mapFriendship(friendship) });
      return;
    }

    const removedAt = new Date();
    const removed = await prisma.$transaction(async (tx) => {
      const row = await tx.friendship.update({
        where: { id: friendship.id },
        data: {
          status: "removed",
          removedAt,
        },
      });
      await removePendingContacts(tx, friendship.requesterUserId, friendship.recipientUserId, removedAt);
      return row;
    });

    const payload = { requestId: removed.id, friendshipId: removed.id, friendship: await mapFriendship(removed) };
    realtime?.sendToUser(removed.recipientUserId, "chirp.friend.removed", payload);
    realtime?.sendToUser(removed.requesterUserId, "chirp.friend.removed", payload);
    logger.info({
      requestId: removed.id,
      friendshipId: removed.id,
      requesterUserId: shortId(removed.requesterUserId),
      recipientUserId: shortId(removed.recipientUserId),
      requestStatus: removed.status,
      socketEventName: "chirp.friend.removed",
      timestamp: new Date().toISOString(),
    }, "chirp.request.cancelled");

    res.json({ success: true, friendship: await mapFriendship(removed) });
  });

  return router;
}

async function mapAcceptedFriend(prisma: PrismaClient, userId: string, contactId: string) {
  const identity = await loadPublicIdentity(userId);
  return {
    id: userId,
    contactId,
    displayName: identity.displayName,
    handle: identity.onewayId,
    chirpId: await ensureUserChirpId(prisma, userId),
    status: "connected",
    isIncoming: false,
    nickname: null,
  };
}

async function mapRequest(prisma: PrismaClient, friendship: Friendship, currentUserId: string) {
  const isIncoming = sameUser(friendship.recipientUserId, currentUserId);
  const isOutgoing = sameUser(friendship.requesterUserId, currentUserId);
  if (!isIncoming && !isOutgoing) {
    throw new Error("request_not_visible_to_current_user");
  }
  const direction = isIncoming ? "incoming" : "outgoing";
  const peerUserId = isIncoming ? friendship.requesterUserId : friendship.recipientUserId;
  const identity = await loadPublicIdentity(peerUserId);
  const requester = await friendUserSummary(prisma, friendship.requesterUserId);
  const recipient = await friendUserSummary(prisma, friendship.recipientUserId);
  return {
    id: friendship.id,
    requestId: friendship.id,
    friendshipId: friendship.id,
    contactId: friendship.id,
    requesterUserId: friendship.requesterUserId,
    recipientUserId: friendship.recipientUserId,
    peerUserId,
    direction,
    displayName: identity.displayName,
    handle: identity.onewayId,
    chirpId: await ensureUserChirpId(prisma, peerUserId),
    status: "pending",
    isIncoming,
    requester,
    recipient,
    nickname: null,
    createdAt: friendship.createdAt.toISOString(),
  };
}

async function friendRequestPayload(prisma: PrismaClient, friendship: Friendship) {
  const requester = await loadPublicIdentity(friendship.requesterUserId);
  return {
    requestId: friendship.id,
    friendshipId: friendship.id,
    requesterUserId: friendship.requesterUserId,
    recipientUserId: friendship.recipientUserId,
    status: "pending",
    requester: {
      userId: friendship.requesterUserId,
      displayName: requester.displayName,
      handle: requester.onewayId,
      avatarURL: null,
      chirpId: await ensureUserChirpId(prisma, friendship.requesterUserId),
    },
    createdAt: friendship.createdAt.toISOString(),
  };
}

async function friendAcceptedPayload(prisma: PrismaClient, friendship: Friendship) {
  return {
    friendshipId: friendship.id,
    friendship: await mapFriendship(friendship),
    requester: await friendUserSummary(prisma, friendship.requesterUserId),
    recipient: await friendUserSummary(prisma, friendship.recipientUserId),
  };
}

async function friendUserSummary(prisma: PrismaClient, userId: string) {
  const identity = await loadPublicIdentity(userId);
  return {
    userId,
    displayName: identity.displayName,
    handle: identity.onewayId,
    avatarURL: null,
    chirpId: await ensureUserChirpId(prisma, userId),
  };
}

async function mapFriendship(friendship: Friendship) {
  return {
    id: friendship.id,
    requestId: friendship.id,
    requesterUserId: friendship.requesterUserId,
    recipientUserId: friendship.recipientUserId,
    status: statusForWire(friendship.status),
    createdAt: friendship.createdAt.toISOString(),
    updatedAt: friendship.updatedAt.toISOString(),
    acceptedAt: friendship.acceptedAt?.toISOString() ?? null,
    deniedAt: friendship.deniedAt?.toISOString() ?? friendship.declinedAt?.toISOString() ?? null,
    ignoredAt: friendship.ignoredAt?.toISOString() ?? null,
    declinedAt: friendship.declinedAt?.toISOString() ?? null,
    blockedAt: friendship.blockedAt?.toISOString() ?? null,
    removedAt: friendship.removedAt?.toISOString() ?? null,
  };
}

function statusForWire(value: string): FriendshipStatus {
  switch (value) {
  case "accepted":
  case "declined":
  case "blocked":
  case "removed":
  case "pending":
    return value;
  default:
    return "pending";
  }
}

async function upsertPendingContacts(prisma: ContactProjectionClient, requesterUserId: string, recipientUserId: string) {
  await prisma.oneWayContact.upsert({
    where: { userId_contactUserId: { userId: requesterUserId, contactUserId: recipientUserId } },
    update: {
      status: "pending",
      direction: "outgoing",
      acceptedAt: null,
      removedAt: null,
      blockedAt: null,
    },
    create: {
      userId: requesterUserId,
      contactUserId: recipientUserId,
      status: "pending",
      direction: "outgoing",
    },
  });
  await prisma.oneWayContact.upsert({
    where: { userId_contactUserId: { userId: recipientUserId, contactUserId: requesterUserId } },
    update: {
      status: "pending",
      direction: "incoming",
      acceptedAt: null,
      removedAt: null,
      blockedAt: null,
    },
    create: {
      userId: recipientUserId,
      contactUserId: requesterUserId,
      status: "pending",
      direction: "incoming",
    },
  });
}

async function connectContactPair(prisma: ContactProjectionClient, requesterUserId: string, recipientUserId: string, acceptedAt: Date) {
  await prisma.oneWayContact.upsert({
    where: { userId_contactUserId: { userId: requesterUserId, contactUserId: recipientUserId } },
    update: {
      status: "connected",
      direction: "connected",
      acceptedAt,
      removedAt: null,
      blockedAt: null,
    },
    create: {
      userId: requesterUserId,
      contactUserId: recipientUserId,
      status: "connected",
      direction: "connected",
      acceptedAt,
    },
  });
  await prisma.oneWayContact.upsert({
    where: { userId_contactUserId: { userId: recipientUserId, contactUserId: requesterUserId } },
    update: {
      status: "connected",
      direction: "connected",
      acceptedAt,
      removedAt: null,
      blockedAt: null,
    },
    create: {
      userId: recipientUserId,
      contactUserId: requesterUserId,
      status: "connected",
      direction: "connected",
      acceptedAt,
    },
  });
}

async function removePendingContacts(prisma: ContactProjectionClient, requesterUserId: string, recipientUserId: string, removedAt: Date) {
  await prisma.oneWayContact.updateMany({
    where: {
      OR: [
        { userId: requesterUserId, contactUserId: recipientUserId, status: "pending" },
        { userId: recipientUserId, contactUserId: requesterUserId, status: "pending" },
      ],
    },
    data: {
      status: "removed",
      direction: "removed",
      removedAt,
    },
  });
}

async function blockContactPair(prisma: ContactProjectionClient, requesterUserId: string, recipientUserId: string, blockedAt: Date) {
  await prisma.oneWayContact.upsert({
    where: { userId_contactUserId: { userId: requesterUserId, contactUserId: recipientUserId } },
    update: {
      status: "blocked",
      direction: "blocked",
      blockedAt,
      removedAt: null,
    },
    create: {
      userId: requesterUserId,
      contactUserId: recipientUserId,
      status: "blocked",
      direction: "blocked",
      blockedAt,
    },
  });
  await prisma.oneWayContact.upsert({
    where: { userId_contactUserId: { userId: recipientUserId, contactUserId: requesterUserId } },
    update: {
      status: "blocked",
      direction: "blocked",
      blockedAt,
      removedAt: null,
    },
    create: {
      userId: recipientUserId,
      contactUserId: requesterUserId,
      status: "blocked",
      direction: "blocked",
      blockedAt,
    },
  });
}

async function isBlocked(prisma: PrismaClient, userA: string, userB: string): Promise<boolean> {
  const hit = await prisma.oneWayContact.findFirst({
    where: {
      OR: [
        { userId: userA, contactUserId: userB, status: "blocked" },
        { userId: userB, contactUserId: userA, status: "blocked" },
      ],
    },
    select: { id: true },
  });
  return !!hit;
}

async function backfillFriendshipsFromContacts(prisma: PrismaClient): Promise<void> {
  const contacts = await prisma.oneWayContact.findMany({
    where: {
      OR: [
        { status: "connected" },
        { status: "pending", direction: "outgoing" },
      ],
    },
    select: {
      userId: true,
      contactUserId: true,
      status: true,
      direction: true,
      createdAt: true,
      acceptedAt: true,
      updatedAt: true,
    },
    take: 5000,
  });

  let inserted = 0;
  for (const contact of contacts) {
    const pairKey = friendshipPairKey(contact.userId, contact.contactUserId);
    const status = contact.status === "connected" ? "accepted" : "pending";
    const existing = await prisma.friendship.findUnique({ where: { pairKey }, select: { id: true } });
    if (existing) continue;
    await prisma.friendship.create({
      data: {
        id: randomUUID(),
        requesterUserId: contact.userId,
        recipientUserId: contact.contactUserId,
        pairKey,
        status,
        createdAt: contact.createdAt,
        acceptedAt: status === "accepted" ? contact.acceptedAt ?? contact.updatedAt : null,
      },
    });
    inserted += 1;
  }

  if (inserted > 0) {
    logger.info({ inserted }, "[friends] backfilled friendship request rows from contacts");
  }
}

function friendshipPairKey(userA: string, userB: string): string {
  return [userA, userB].map((value) => value.toLowerCase()).sort().join(":");
}

function sameUser(userA: string, userB: string): boolean {
  return userA.toLowerCase() === userB.toLowerCase();
}

function currentUserId(req: express.Request): string {
  return (req as AuthenticatedRequest).userId;
}
