import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";

import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import { shortId } from "../lib/privacy/redaction";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord, loadPublicIdentity } from "../services/identity";
import type { CommunityRealtimeServer } from "../realtime/CommunityRealtimeServer";

const uuidSchema = z.string().uuid().transform((value) => value.toLowerCase());
const visibilitySchema = z.enum(["public", "private", "hidden"]);

const createCommunitySchema = z.object({
  name: z.string().trim().min(1).max(80),
  description: z.string().trim().max(500).default(""),
  visibility: visibilitySchema.default("public"),
});

const updateCommunitySchema = z.object({
  name: z.string().trim().min(1).max(80).optional(),
  description: z.string().trim().max(500).optional(),
  visibility: visibilitySchema.optional(),
});

const sendCommunityMessageSchema = z.object({
  body: z.string().trim().min(1).max(4_000),
  clientMessageId: z.string().uuid().optional(),
});

const addMemberSchema = z.object({
  userId: z.string().trim().min(1).max(128).optional(),
  handle: z.string().trim().min(2).max(64).optional(),
  role: z.enum(["member", "moderator", "admin"]).default("member"),
}).refine((body) => Boolean(body.userId || body.handle), {
  message: "userId_or_handle_required",
});

const blockMemberSchema = z.object({
  userId: z.string().trim().min(1).max(128),
});

export function communitiesRouter(deps: { realtime?: CommunityRealtimeServer } = {}): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const query = typeof req.query.q === "string" ? normalizeName(req.query.q) : "";
    const requestedLimit = Number.parseInt(String(req.query.limit ?? "50"), 10);
    const limit = Number.isFinite(requestedLimit) ? Math.min(Math.max(requestedLimit, 1), 100) : 50;
    const communities = await prisma.community.findMany({
      where: {
        deletedAt: null,
        AND: [
          query
            ? {
              OR: [
                { normalizedName: { contains: query } },
                { name: { contains: req.query.q as string } },
              ],
            }
            : {},
          {
            OR: [
              { visibility: "public" },
              { ownerId: userId },
              { members: { some: { userId } } },
            ],
          },
        ],
      },
      include: { _count: { select: { members: true } } },
      orderBy: [{ updatedAt: "desc" }, { createdAt: "desc" }],
      take: limit,
    });

    res.json({ communities: communities.map(mapCommunity) });
  });

  router.get("/me/memberships", async (req, res) => {
    const startedAt = Date.now();
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    logger.info({ userId: shortId(userId), tsMs: startedAt }, "[communities] membership fetch start");

    const memberships = await prisma.communityMember.findMany({
      where: {
        userId,
        community: { deletedAt: null },
      },
      include: { community: { include: { _count: { select: { members: true } } } } },
      orderBy: { createdAt: "desc" },
    });

    logger.info({
      userId: shortId(userId),
      count: memberships.length,
      elapsedMs: Date.now() - startedAt,
    }, "[communities] membership fetch end");

    res.json({
      memberships: memberships.map((membership) => ({
        communityId: membership.communityId,
        memberId: membership.id,
        role: membership.role,
        joinedAt: toISOString(membership.createdAt),
        community: mapCommunity(membership.community),
      })),
    });
  });

  router.get("/:id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(String(req.params.id), res);
    if (!communityId) return;

    const community = await prisma.community.findFirst({
      where: visibleCommunityWhere(communityId, userId),
      include: { members: true },
    });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    res.json({ community: mapCommunity(community) });
  });

  router.post("/", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const identity = await loadPublicIdentity(userId);

    const parsed = createCommunitySchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const normalizedName = normalizeName(parsed.data.name);
    if (parsed.data.visibility === "public") {
      const existing = await prisma.community.findFirst({
        where: { normalizedName, visibility: "public", deletedAt: null },
        include: { members: true },
      });
      if (existing) {
        res.status(409).json({
          error: "community_already_exists",
          message: "Community already exists",
          community: mapCommunity(existing),
          actions: ["view", "join"],
        });
        return;
      }
    }

    try {
	      const community = await prisma.$transaction(async (tx) => {
	        const created = await tx.community.create({
          data: {
            id: randomUUID(),
            ownerId: userId,
            name: parsed.data.name.trim(),
            normalizedName,
            description: parsed.data.description.trim(),
            creatorHandle: identity.onewayId,
            visibility: parsed.data.visibility,
            members: {
              create: {
                id: randomUUID(),
                userId,
                displayName: identity.displayName || identity.onewayId,
                handle: identity.onewayId,
                role: "admin",
              },
            },
          },
          include: { members: true },
        });
	        return created;
	      });
	      res.status(201).json({ community: mapCommunity(community) });
	      deps.realtime?.broadcastCommunityCreated(community);
	    } catch (error) {
      logger.error({ err: error }, "[communities] create failed");
      res.status(500).json({ error: "community_create_failed" });
    }
  });

  router.patch("/:id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    const parsed = updateCommunitySchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const current = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!current) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    if (current.ownerId !== userId) {
      res.status(403).json({ error: "community_owner_required" });
      return;
    }

    const nextName = parsed.data.name?.trim();
    const nextVisibility = parsed.data.visibility ?? current.visibility;
    const nextNormalizedName = nextName ? normalizeName(nextName) : current.normalizedName;
    if (nextVisibility === "public") {
      const duplicate = await prisma.community.findFirst({
        where: {
          id: { not: communityId },
          normalizedName: nextNormalizedName,
          visibility: "public",
          deletedAt: null,
        },
      });
      if (duplicate) {
        res.status(409).json({
          error: "community_already_exists",
          message: "Community already exists",
          communityId: duplicate.id,
        });
        return;
      }
    }

    const community = await prisma.community.update({
      where: { id: communityId },
      data: {
        ...(nextName ? { name: nextName, normalizedName: nextNormalizedName } : {}),
        ...(parsed.data.description !== undefined ? { description: parsed.data.description.trim() } : {}),
        ...(parsed.data.visibility ? { visibility: parsed.data.visibility } : {}),
      },
      include: { members: true },
    });
    res.json({ community: mapCommunity(community) });
  });

  router.delete("/:id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    const community = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    if (community.ownerId !== userId) {
      res.status(403).json({ error: "community_owner_required" });
      return;
    }

    await prisma.community.update({ where: { id: communityId }, data: { deletedAt: new Date() } });
    res.json({ ok: true });
  });

  router.post("/:id/join", async (req, res) => {
    const startedAt = Date.now();
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;
    logger.info({ userId: shortId(userId), communityId, tsMs: startedAt }, "[communities] join request start");

    const community = await prisma.community.findFirst({
      where: { id: communityId, deletedAt: null },
      include: { members: true },
    });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    if (community.visibility !== "public" && community.ownerId !== userId) {
      res.status(403).json({ error: "community_invite_required" });
      return;
    }
    if (jsonListIncludes(community.bannedUserIdsJson, userId) || jsonListIncludes(community.blockedUserIdsJson, userId)) {
      res.status(403).json({ error: "community_access_blocked" });
      return;
    }

    const identity = await loadPublicIdentity(userId);
    const beforeMemberCount = community.members.length;
    await prisma.communityMember.upsert({
      where: { communityId_userId: { communityId, userId } },
      update: {
        displayName: identity.displayName || identity.onewayId,
        handle: identity.onewayId,
      },
      create: {
        id: randomUUID(),
        communityId,
        userId,
        displayName: identity.displayName || identity.onewayId,
        handle: identity.onewayId,
        role: community.ownerId === userId ? "admin" : "member",
      },
    });

    const updated = await prisma.community.findUniqueOrThrow({
      where: { id: communityId },
      include: { members: true },
    });
    logger.info({
      userId: shortId(userId),
      communityId,
      idempotent: updated.members.length === beforeMemberCount,
      elapsedMs: Date.now() - startedAt,
    }, "[communities] join request end");
    res.json({ community: mapCommunity(updated) });
    if (updated.members.length !== beforeMemberCount) {
      deps.realtime?.broadcastMemberJoined(updated, userId).catch((error) => {
        logger.warn({ err: error, communityId, userId: shortId(userId) }, "[communities] realtime member join broadcast failed");
      });
    } else {
      deps.realtime?.broadcastCommunityUpdated(updated);
    }
  });

  async function leaveCommunity(req: express.Request, res: express.Response): Promise<void> {
    const startedAt = Date.now();
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(String(req.params.id), res);
    if (!communityId) return;
    logger.info({ userId: shortId(userId), communityId, tsMs: startedAt }, "[communities] leave request start");

    const community = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    if (community.ownerId === userId) {
      res.status(400).json({ error: "creator_cannot_leave" });
      return;
    }

    await prisma.communityMember.deleteMany({ where: { communityId, userId } });
    logger.info({ userId: shortId(userId), communityId, elapsedMs: Date.now() - startedAt }, "[communities] leave request end");
    res.json({ ok: true });
  }

  router.post("/:id/leave", leaveCommunity);
  router.delete("/:id/leave", leaveCommunity);

  router.get("/:id/members", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    const community = await prisma.community.findFirst({ where: visibleCommunityWhere(communityId, userId) });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }

    const members = await prisma.communityMember.findMany({
      where: { communityId },
      orderBy: [{ role: "asc" }, { createdAt: "asc" }],
    });
    res.json({ members: members.map(mapMember) });
  });

  router.post("/:id/members", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    const parsed = addMemberSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const community = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    const requester = await prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
    });
    if (community.ownerId !== userId && requester?.role !== "admin" && requester?.role !== "moderator") {
      res.status(403).json({ error: "community_member_manage_forbidden" });
      return;
    }

    const targetUserId = parsed.data.userId ?? await userIdForHandle(parsed.data.handle ?? "");
    if (!targetUserId) {
      res.status(404).json({ error: "oneway_user_not_found" });
      return;
    }
    const member = await ensureMember(communityId, targetUserId, parsed.data.role);
    res.json({ member: mapMember(member) });
  });

  router.delete("/:id/members/:memberId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    const community = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    if (community.ownerId !== userId) {
      res.status(403).json({ error: "community_owner_required" });
      return;
    }

    await prisma.communityMember.deleteMany({ where: { communityId, id: req.params.memberId } });
    res.json({ ok: true });
  });

  router.post("/:id/blocks", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;
    const parsed = blockMemberSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const community = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    const requester = await prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
    });
    if (community.ownerId !== userId && requester?.role !== "admin" && requester?.role !== "moderator") {
      res.status(403).json({ error: "community_member_manage_forbidden" });
      return;
    }

    const targetUserId = await resolveMemberUserId(communityId, parsed.data.userId);
    if (!targetUserId || targetUserId === community.ownerId) {
      res.status(400).json({ error: "invalid_block_target" });
      return;
    }
    const blockedIds = new Set(parseJsonArray(community.blockedUserIdsJson));
    blockedIds.add(targetUserId);
    const updated = await prisma.$transaction(async (tx) => {
      await tx.communityMember.deleteMany({ where: { communityId, userId: targetUserId } });
      return tx.community.update({
        where: { id: communityId },
        data: { blockedUserIdsJson: JSON.stringify([...blockedIds].sort()) },
        include: { members: true },
      });
    });
    res.json({ ok: true, community: mapCommunity(updated) });
  });

  router.delete("/:id/blocks/:target", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;
    const community = await prisma.community.findFirst({ where: { id: communityId, deletedAt: null } });
    if (!community) {
      res.status(404).json({ error: "community_not_found" });
      return;
    }
    const requester = await prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
    });
    if (community.ownerId !== userId && requester?.role !== "admin" && requester?.role !== "moderator") {
      res.status(403).json({ error: "community_member_manage_forbidden" });
      return;
    }
    const targetUserId = await resolveMemberUserId(communityId, String(req.params.target));
    if (!targetUserId) {
      res.status(404).json({ error: "oneway_user_not_found" });
      return;
    }
    const blockedIds = parseJsonArray(community.blockedUserIdsJson).filter((id) => id !== targetUserId);
    const updated = await prisma.community.update({
      where: { id: communityId },
      data: { blockedUserIdsJson: JSON.stringify(blockedIds) },
      include: { members: true },
    });
    res.json({ ok: true, community: mapCommunity(updated) });
  });

  router.get("/:id/messages", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    if (!await isCommunityMember(communityId, userId)) {
      res.status(403).json({ error: "community_membership_required" });
      return;
    }

    let since: Date | undefined;
    if (typeof req.query.since === "string" && req.query.since.trim()) {
      since = new Date(req.query.since);
      if (Number.isNaN(since.getTime())) {
        res.status(400).json({ error: "invalid_since" });
        return;
      }
    }

    const messages = await prisma.communityMessage.findMany({
      where: {
        communityId,
        ...(since ? { createdAt: { gt: since } } : {}),
      },
      orderBy: { createdAt: "asc" },
      take: 200,
    });
    res.json({ messages: messages.map(mapMessage) });
  });

  router.post("/:id/messages", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const communityId = parseCommunityId(req.params.id, res);
    if (!communityId) return;

    const parsed = sendCommunityMessageSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    if (!await isCommunityMember(communityId, userId)) {
      res.status(403).json({ error: "community_membership_required" });
      return;
    }

    const identity = await loadPublicIdentity(userId);
    const communityMessageDelegate = prisma.communityMessage as any;
    const existingMessage = parsed.data.clientMessageId
      ? await communityMessageDelegate.findFirst({
        where: {
          communityId,
          senderId: userId,
          clientMessageId: parsed.data.clientMessageId,
        },
      })
      : null;
    const message = existingMessage ?? await communityMessageDelegate.create({
      data: {
        id: randomUUID(),
        clientMessageId: parsed.data.clientMessageId,
        communityId,
        senderId: userId,
        senderHandle: identity.onewayId,
        senderDisplayName: identity.displayName || identity.onewayId,
        body: parsed.data.body,
        status: "sent",
      },
    });
    await prisma.community.update({ where: { id: communityId }, data: { updatedAt: new Date() } });
    res.status(201).json({ message: mapMessage(message) });
    deps.realtime?.broadcastMessageCreated(message).catch((error) => {
      logger.warn({ err: error, communityId }, "[communities] realtime broadcast failed");
    });
  });

  return router;
}

function parseCommunityId(value: string, res: express.Response): string | null {
  const parsed = uuidSchema.safeParse(value);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_community_id" });
    return null;
  }
  return parsed.data;
}

function normalizeName(value: string): string {
  return value.trim().toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

function visibleCommunityWhere(id: string, userId: string) {
  return {
    id,
    deletedAt: null,
    OR: [
      { visibility: "public" },
      { ownerId: userId },
      { members: { some: { userId } } },
    ],
  };
}

async function isCommunityMember(communityId: string, userId: string): Promise<boolean> {
  const member = await prisma.communityMember.findUnique({
    where: { communityId_userId: { communityId, userId } },
    select: { id: true },
  });
  return Boolean(member);
}

async function userIdForHandle(handle: string): Promise<string | null> {
  const normalized = handle.trim().toLowerCase().replace(/^@?/, "@");
  const identity = await prisma.oneWayIdentity.findUnique({
    where: { onewayId: normalized },
    select: { userId: true },
  });
  return identity?.userId ?? null;
}

async function resolveMemberUserId(communityId: string, identifier: string): Promise<string | null> {
  const direct = await prisma.communityMember.findFirst({
    where: {
      communityId,
      OR: [{ userId: identifier }, { id: identifier }, { handle: identifier }],
    },
    select: { userId: true },
  });
  return direct?.userId ?? await userIdForHandle(identifier);
}

async function ensureMember(communityId: string, userId: string, role: string) {
  const identity = await loadPublicIdentity(userId);
  return prisma.communityMember.upsert({
    where: { communityId_userId: { communityId, userId } },
    update: {
      displayName: identity.displayName || identity.onewayId,
      handle: identity.onewayId,
    },
    create: {
      id: randomUUID(),
      communityId,
      userId,
      displayName: identity.displayName || identity.onewayId,
      handle: identity.onewayId,
      role,
    },
  });
}

function jsonListIncludes(json: string | null | undefined, value: string): boolean {
  try {
    const list = JSON.parse(json || "[]");
    return Array.isArray(list) && list.includes(value);
  } catch {
    return false;
  }
}

function mapCommunity(community: any) {
  const members = Array.isArray(community.members) ? community.members.map(mapMember) : [];
  return {
    id: community.id,
    name: community.name,
    normalizedName: community.normalizedName || normalizeName(community.name),
    description: community.description ?? "",
    creatorUserId: community.ownerId,
    creatorHandle: community.creatorHandle ?? "@oneway",
    visibility: community.visibility ?? "public",
    blockedUserIds: parseJsonArray(community.blockedUserIdsJson),
    bannedUserIds: parseJsonArray(community.bannedUserIdsJson),
    memberCount: typeof community._count?.members === "number" ? community._count.members : members.length,
    members,
    createdAt: toISOString(community.createdAt),
    updatedAt: toISOString(community.updatedAt),
    deletedAt: community.deletedAt ? toISOString(community.deletedAt) : null,
  };
}

function mapMember(member: any) {
  return {
    id: member.id,
    userId: member.userId,
    displayName: member.displayName ?? "OneWay User",
    handle: member.handle ?? "@oneway",
    role: member.role ?? "member",
    createdAt: toISOString(member.createdAt),
  };
}

function mapMessage(message: any) {
  return {
    id: message.id,
    clientMessageId: message.clientMessageId ?? null,
    communityId: message.communityId,
    senderId: message.senderId,
    senderHandle: message.senderHandle,
    senderDisplayName: message.senderDisplayName,
    body: message.body,
    status: message.status ?? "sent",
    createdAt: toISOString(message.createdAt),
  };
}

function parseJsonArray(value: string | null | undefined): string[] {
  try {
    const parsed = JSON.parse(value ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((item) => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function toISOString(value: Date | string | null | undefined): string {
  if (!value) return new Date().toISOString();
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}
