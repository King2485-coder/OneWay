import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import { shortId } from "../lib/privacy/redaction";
import { addColumnIfMissing } from "../lib/runtimeSchemaPatch";
import type { LiveKitTokenService } from "../services/LiveKitTokenService";
import {
  chirpLookupCandidates,
  ensureUserChirpId,
  ensureUserRecord,
  loadPublicIdentity,
  normalizeOneWayId,
  sanitizeEmailAlias,
} from "../services/identity";
import { sanitizeRoomName } from "../types/calls";

interface WalkieRouterDeps {
  prisma: PrismaClient;
  tokens: LiveKitTokenService;
  isUserOnline?: (userId: string) => boolean;
}

interface WalkieSession {
  id: string;
  channelId: string;
  roomName: string;
  callerUserId: string;
  caller: string;
  targetUserId?: string;
  target?: string;
  groupName?: string;
  isGroup?: boolean;
  transmitterUserId?: string;
  participants: WalkieParticipant[];
  startedAt: string;
  endedAt?: string;
}

interface WalkieParticipant {
  userId: string;
  displayName: string;
  onewayId?: string | null;
  chirpId?: string | null;
}

interface WalkieContactDTO {
  id: string;
  userId: string;
  contactId: string;
  displayName: string;
  handle: string;
  chirpId: string | null;
  status: "accepted";
  availability: "available" | "busy" | "doNotDisturb" | "offline" | "emergencyOnly";
  isOnline: boolean;
  isFavorite: boolean;
}

interface WalkiePrivacyDTO {
  allowFriends: boolean;
  allowFriendsOfFriends: boolean;
  allowAnyone: boolean;
  allowDirectChirp: boolean;
  directChirpAudience: string;
  askBeforeConnecting: boolean;
  allowRepeatChirps: boolean;
  silenceUnknownChirps: boolean;
  requireVerifiedAccount: boolean;
  hideProfilePhotoFromUnknownUsers: boolean;
  blockUnknownDuringDnd: boolean;
  autoBlockRepeatedAbuse: boolean;
}

interface WalkieIdentitySummary {
  userId?: string;
  onewayId?: string | null;
  walkieName?: string | null;
  displayName?: string | null;
  username?: string | null;
}

const sessions = new Map<string, WalkieSession>();

const FIXED_DEV_AUTH_USER_ID = "dev-user";
const FIXED_DEV_AUTH_ONEWAY_ID = "@devuser";
const FIXED_DEV_AUTH_DISPLAY_NAME = "OneWay Dev";

const sessionCreateSchema = z.object({
  target: z.string().trim().min(1).max(64).optional(),
  targets: z.array(z.string().trim().min(1).max(64)).min(1).max(12).optional(),
  groupName: z.string().trim().min(1).max(48).optional(),
}).refine((value) => Boolean(value.target) || Boolean(value.targets?.length), {
  message: "target or targets is required",
});

const privacyPatchSchema = z.object({
  allowFriends: z.boolean().optional(),
  allowFriendsOfFriends: z.boolean().optional(),
  allowAnyone: z.boolean().optional(),
  allowDirectChirp: z.boolean().optional(),
  directChirpAudience: z.enum(["everyone", "contacts", "friendsOfFriends", "verified", "nobody"]).optional(),
  askBeforeConnecting: z.boolean().optional(),
  allowRepeatChirps: z.boolean().optional(),
  silenceUnknownChirps: z.boolean().optional(),
  requireVerifiedAccount: z.boolean().optional(),
  hideProfilePhotoFromUnknownUsers: z.boolean().optional(),
  blockUnknownDuringDnd: z.boolean().optional(),
  autoBlockRepeatedAbuse: z.boolean().optional(),
});

const directLookupSchema = z.object({
  chirpId: z.string().trim().min(3).max(32),
});

const directRequestSchema = z.object({
  recipientChirpId: z.string().trim().min(3).max(32),
  clientRequestId: z.string().trim().min(6).max(96),
  mode: z.string().trim().max(32).optional(),
  sourceDeviceId: z.string().trim().max(96).optional(),
});

const emptyBodySchema = z.object({}).passthrough();

export async function ensureWalkieFavoriteTable(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "WalkieFavorite" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "contactUserId" TEXT NOT NULL,
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE UNIQUE INDEX IF NOT EXISTS "WalkieFavorite_userId_contactUserId_key"
    ON "WalkieFavorite"("userId", "contactUserId")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "WalkieFavorite_userId_createdAt_idx"
    ON "WalkieFavorite"("userId", "createdAt")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "WalkieFavorite_contactUserId_idx"
    ON "WalkieFavorite"("contactUserId")
  `);
}

export async function ensureDirectChirpTables(prisma: PrismaClient): Promise<void> {
  const logPrefix = "direct chirp schema patch";
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"allowDirectChirp" BOOLEAN NOT NULL DEFAULT true`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"directChirpAudience" TEXT NOT NULL DEFAULT 'everyone'`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"askBeforeConnecting" BOOLEAN NOT NULL DEFAULT true`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"allowRepeatChirps" BOOLEAN NOT NULL DEFAULT false`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"silenceUnknownChirps" BOOLEAN NOT NULL DEFAULT true`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"requireVerifiedAccount" BOOLEAN NOT NULL DEFAULT false`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"hideProfilePhotoFromUnknownUsers" BOOLEAN NOT NULL DEFAULT false`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"blockUnknownDuringDnd" BOOLEAN NOT NULL DEFAULT true`, logPrefix });
  await addColumnIfMissing(prisma, { table: "WalkiePrivacySettings", columnDefinition: `"autoBlockRepeatedAbuse" BOOLEAN NOT NULL DEFAULT true`, logPrefix });

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "DirectChirpRequest" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "senderUserId" TEXT NOT NULL,
      "recipientUserId" TEXT NOT NULL,
      "senderChirpId" TEXT NOT NULL,
      "recipientChirpId" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'pending',
      "clientRequestId" TEXT NOT NULL,
      "sourceDeviceId" TEXT,
      "notificationSentAt" TIMESTAMP,
      "pushNotificationId" TEXT,
      "channelId" TEXT,
      "abuseScore" INTEGER NOT NULL DEFAULT 0,
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "expiresAt" TIMESTAMP NOT NULL,
      "acceptedAt" TIMESTAMP,
      "declinedAt" TIMESTAMP,
      "ignoredAt" TIMESTAMP,
      "blockedAt" TIMESTAMP,
      "cancelledAt" TIMESTAMP,
      "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE UNIQUE INDEX IF NOT EXISTS "DirectChirpRequest_senderUserId_recipientUserId_clientRequestId_key"
    ON "DirectChirpRequest"("senderUserId", "recipientUserId", "clientRequestId")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "DirectChirpRequest_recipientUserId_status_createdAt_idx"
    ON "DirectChirpRequest"("recipientUserId", "status", "createdAt")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "DirectChirpRequest_senderUserId_status_createdAt_idx"
    ON "DirectChirpRequest"("senderUserId", "status", "createdAt")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "DirectChirpRequest_channelId_idx"
    ON "DirectChirpRequest"("channelId")
  `);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "ChirpTrustPermission" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "ownerUserId" TEXT NOT NULL,
      "permittedUserId" TEXT NOT NULL,
      "permission" TEXT NOT NULL DEFAULT 'oneTime',
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`
    CREATE UNIQUE INDEX IF NOT EXISTS "ChirpTrustPermission_ownerUserId_permittedUserId_key"
    ON "ChirpTrustPermission"("ownerUserId", "permittedUserId")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "ChirpTrustPermission_ownerUserId_permission_idx"
    ON "ChirpTrustPermission"("ownerUserId", "permission")
  `);
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS "ChirpTrustPermission_permittedUserId_idx"
    ON "ChirpTrustPermission"("permittedUserId")
  `);
}

function walkieRoomName(userA: string, userB: string) {
  const [first, second] = [userA, userB].sort();
  return sanitizeRoomName(`ow-walkie-${first}-${second}`);
}

function walkieChannelId(userA: string, userB: string) {
  const [first, second] = [userA, userB].sort();
  return `walkie-${first}-${second}`;
}

function findActiveSessionForPair(userA: string, userB: string): WalkieSession | undefined {
  for (const session of sessions.values()) {
    if (session.endedAt || session.isGroup) continue;
    const matches =
      (session.callerUserId === userA && session.targetUserId === userB) ||
      (session.callerUserId === userB && session.targetUserId === userA);
    if (matches) return session;
  }
  return undefined;
}

function groupWalkieRoomName(sessionId: string) {
  return sanitizeRoomName(`ow-walkie-group-${sessionId}`);
}

function isSessionParticipant(session: WalkieSession, userId: string): boolean {
  return session.participants.some((participant) => participant.userId === userId);
}

function walkieDisplayName(identity: WalkieIdentitySummary | null | undefined): string {
  return identity?.walkieName?.trim()
    || identity?.displayName?.trim()
    || identity?.username?.trim()
    || identity?.onewayId?.replace(/^@/, "").trim()
    || "OneWay User";
}

function normalizePhoneTarget(value: string): string | null {
  const trimmed = value.trim();
  if (/^\+\d{10,15}$/.test(trimmed)) return trimmed;

  const digits = trimmed.replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}

function isFixedDevAuthRequest(req: express.Request, userId: string): boolean {
  const authReq = req as AuthenticatedRequest & { user?: { devAuth?: boolean } };
  return process.env.NODE_ENV !== "production" &&
    authReq.authMode === "dev" &&
    userId === FIXED_DEV_AUTH_USER_ID &&
    authReq.user?.devAuth === true;
}

async function ensureFixedDevWalkieIdentity(
  prisma: PrismaClient,
  req: express.Request,
  userId: string
): Promise<void> {
  if (!isFixedDevAuthRequest(req, userId)) return;

  await prisma.user.upsert({
    where: { id: userId },
    update: {},
    create: {
      id: userId,
      displayName: FIXED_DEV_AUTH_DISPLAY_NAME,
    },
  });

  await prisma.oneWayIdentity.upsert({
    where: { userId },
    update: {},
    create: {
      userId,
      displayName: FIXED_DEV_AUTH_DISPLAY_NAME,
      walkieName: FIXED_DEV_AUTH_DISPLAY_NAME,
      username: "devuser",
      usernameHidden: true,
      onewayId: FIXED_DEV_AUTH_ONEWAY_ID,
      emailAlias: "devuser@oneway.app",
      showEmailAlias: false,
      showOneWayId: true,
      showNumbers: false,
      preferredCallerIdentity: "onewayId",
    },
  });
}

async function loadRequesterWalkieIdentity(
  prisma: PrismaClient,
  req: express.Request,
  userId: string
): Promise<WalkieIdentitySummary | null> {
  await ensureFixedDevWalkieIdentity(prisma, req, userId);
  return prisma.oneWayIdentity.findUnique({
    where: { userId },
    select: {
      userId: true,
      onewayId: true,
      walkieName: true,
      displayName: true,
      username: true,
    },
  });
}

async function getWalkiePrivacy(prisma: PrismaClient, userId: string): Promise<WalkiePrivacyDTO> {
  const row = await prisma.walkiePrivacySettings.findUnique({
    where: { userId },
    select: {
      allowFriends: true,
      allowFriendsOfFriends: true,
      allowAnyone: true,
      allowDirectChirp: true,
      directChirpAudience: true,
      askBeforeConnecting: true,
      allowRepeatChirps: true,
      silenceUnknownChirps: true,
      requireVerifiedAccount: true,
      hideProfilePhotoFromUnknownUsers: true,
      blockUnknownDuringDnd: true,
      autoBlockRepeatedAbuse: true,
    },
  });
  return row ?? defaultWalkiePrivacy();
}

function defaultWalkiePrivacy(): WalkiePrivacyDTO {
  return {
    allowFriends: true,
    allowFriendsOfFriends: false,
    allowAnyone: true,
    allowDirectChirp: true,
    directChirpAudience: "everyone",
    askBeforeConnecting: true,
    allowRepeatChirps: false,
    silenceUnknownChirps: true,
    requireVerifiedAccount: false,
    hideProfilePhotoFromUnknownUsers: false,
    blockUnknownDuringDnd: true,
    autoBlockRepeatedAbuse: true,
  };
}

async function areFriends(prisma: PrismaClient, userA: string, userB: string): Promise<boolean> {
  const hit = await prisma.oneWayContact.findFirst({
    where: {
      userId: userA,
      contactUserId: userB,
      status: "connected",
    },
    select: { id: true },
  });
  return !!hit;
}

async function isBlockedBetween(prisma: PrismaClient, userA: string, userB: string): Promise<boolean> {
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

async function areFriendsOfFriends(prisma: PrismaClient, userA: string, userB: string): Promise<boolean> {
  // Friends-of-friends: A and B share at least one mutual connected OneWay contact.
  const [aEdges, bEdges] = await Promise.all([
    prisma.oneWayContact.findMany({
      where: {
        userId: userA,
        status: "connected",
      },
      select: { contactUserId: true },
    }),
    prisma.oneWayContact.findMany({
      where: {
        userId: userB,
        status: "connected",
      },
      select: { contactUserId: true },
    }),
  ]);

  const aSet = new Set(aEdges.map((row) => row.contactUserId).filter((id) => id && id !== userB));
  for (const row of bEdges) {
    if (row.contactUserId && row.contactUserId !== userA && aSet.has(row.contactUserId)) return true;
  }
  return false;
}

async function isWalkieAllowedByTargetPrivacy(
  prisma: PrismaClient,
  callerUserId: string,
  targetUserId: string
): Promise<boolean> {
  const privacy = await getWalkiePrivacy(prisma, targetUserId);
  if (privacy.allowAnyone) return true;

  // Evaluate relationships from the *target's* graph.
  // Otherwise, "Friends" becomes accidentally one-directional (caller -> target),
  // which is the opposite of "target allows caller".
  if (privacy.allowFriends) {
    if (await areFriends(prisma, targetUserId, callerUserId)) return true;
  }
  if (privacy.allowFriendsOfFriends) {
    if (await areFriendsOfFriends(prisma, targetUserId, callerUserId)) return true;
  }
  return false;
}

async function updateWalkiePrivacyFromBody(
  prisma: PrismaClient,
  userId: string,
  body: unknown,
  res: express.Response
): Promise<WalkiePrivacyDTO | null> {
  const parsed = privacyPatchSchema.safeParse(body ?? {});
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    return null;
  }

  const current = await getWalkiePrivacy(prisma, userId);
  const next: WalkiePrivacyDTO = {
    allowFriends: parsed.data.allowFriends ?? current.allowFriends,
    allowFriendsOfFriends: parsed.data.allowFriendsOfFriends ?? current.allowFriendsOfFriends,
    allowAnyone: parsed.data.allowAnyone ?? current.allowAnyone,
    allowDirectChirp: parsed.data.allowDirectChirp ?? current.allowDirectChirp,
    directChirpAudience: parsed.data.directChirpAudience ?? current.directChirpAudience,
    askBeforeConnecting: parsed.data.askBeforeConnecting ?? current.askBeforeConnecting,
    allowRepeatChirps: parsed.data.allowRepeatChirps ?? current.allowRepeatChirps,
    silenceUnknownChirps: parsed.data.silenceUnknownChirps ?? current.silenceUnknownChirps,
    requireVerifiedAccount: parsed.data.requireVerifiedAccount ?? current.requireVerifiedAccount,
    hideProfilePhotoFromUnknownUsers: parsed.data.hideProfilePhotoFromUnknownUsers ?? current.hideProfilePhotoFromUnknownUsers,
    blockUnknownDuringDnd: parsed.data.blockUnknownDuringDnd ?? current.blockUnknownDuringDnd,
    autoBlockRepeatedAbuse: parsed.data.autoBlockRepeatedAbuse ?? current.autoBlockRepeatedAbuse,
  };

  await prisma.walkiePrivacySettings.upsert({
    where: { userId },
    create: { userId, ...next },
    update: next,
  });

  return next;
}

async function isDirectChirpDiscoverable(
  prisma: PrismaClient,
  senderUserId: string,
  recipientUserId: string,
  privacy: WalkiePrivacyDTO
): Promise<boolean> {
  if (!privacy.allowDirectChirp || privacy.directChirpAudience === "nobody") return false;
  if (privacy.directChirpAudience === "everyone" || privacy.directChirpAudience === "verified") return true;
  if (privacy.directChirpAudience === "contacts") return areFriends(prisma, recipientUserId, senderUserId);
  if (privacy.directChirpAudience === "friendsOfFriends") {
    return (await areFriends(prisma, recipientUserId, senderUserId))
      || areFriendsOfFriends(prisma, recipientUserId, senderUserId);
  }
  return false;
}

type DirectChirpRequestRow = {
  id: string;
  senderUserId: string;
  recipientUserId: string;
  senderChirpId: string;
  recipientChirpId: string;
  status: string;
  clientRequestId: string;
  sourceDeviceId?: string | null;
  channelId?: string | null;
  createdAt: Date | string;
  expiresAt: Date | string;
  acceptedAt?: Date | string | null;
  declinedAt?: Date | string | null;
  ignoredAt?: Date | string | null;
  blockedAt?: Date | string | null;
  cancelledAt?: Date | string | null;
};

async function directRequestRows(
  prisma: PrismaClient,
  whereSql: string,
  values: unknown[]
): Promise<DirectChirpRequestRow[]> {
  return prisma.$queryRawUnsafe<DirectChirpRequestRow[]>(
    `SELECT * FROM "DirectChirpRequest" WHERE ${whereSql} ORDER BY "createdAt" DESC LIMIT 50`,
    ...values
  );
}

async function recentDirectChirpCount(prisma: PrismaClient, senderUserId: string, recipientUserId: string): Promise<number> {
  const rows = await prisma.$queryRawUnsafe<Array<{ count: bigint | number }>>(
    `SELECT COUNT(*) as count FROM "DirectChirpRequest"
     WHERE "senderUserId" = ? AND "recipientUserId" = ? AND "createdAt" >= datetime('now', '-1 hour')`,
    senderUserId,
    recipientUserId
  );
  return Number(rows[0]?.count ?? 0);
}

async function mapDirectChirpRequest(
  prisma: PrismaClient,
  row: DirectChirpRequestRow,
  viewerUserId: string
) {
  const peerUserId = row.senderUserId === viewerUserId ? row.recipientUserId : row.senderUserId;
  const identity = await loadPublicIdentity(peerUserId);
  return {
    id: row.id,
    requestId: row.id,
    senderUserId: row.senderUserId,
    recipientUserId: row.recipientUserId,
    senderChirpId: row.senderChirpId,
    recipientChirpId: row.recipientChirpId,
    status: row.status,
    direction: row.recipientUserId === viewerUserId ? "incoming" : "outgoing",
    displayName: walkieDisplayName(identity),
    handle: identity.onewayId,
    chirpId: row.senderUserId === viewerUserId ? row.recipientChirpId : row.senderChirpId,
    channelId: row.channelId,
    createdAt: toIso(row.createdAt),
    expiresAt: toIso(row.expiresAt),
    acceptedAt: toIso(row.acceptedAt),
    declinedAt: toIso(row.declinedAt),
    ignoredAt: toIso(row.ignoredAt),
    blockedAt: toIso(row.blockedAt),
    cancelledAt: toIso(row.cancelledAt),
  };
}

function toIso(value: Date | string | null | undefined): string | null {
  if (!value) return null;
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

async function handleDirectChirpAction(
  req: express.Request,
  res: express.Response,
  prisma: PrismaClient,
  tokens: LiveKitTokenService,
  status: "accepted" | "declined" | "ignored" | "blocked" | "cancelled"
): Promise<void> {
  const userId = (req as unknown as AuthenticatedRequest).userId;
  const rows = await directRequestRows(prisma, `id = ?`, [req.params.requestId]);
  const row = rows[0];
  if (!row) {
    res.status(404).json({ error: "direct_chirp_request_not_found" });
    return;
  }

  const isRecipient = row.recipientUserId === userId;
  const isSender = row.senderUserId === userId;
  if ((status === "cancelled" && !isSender) || (status !== "cancelled" && !isRecipient)) {
    res.status(403).json({ error: "direct_chirp_forbidden" });
    return;
  }
  if (row.status !== "pending" && row.status !== status) {
    res.status(409).json({ error: "direct_chirp_not_pending", request: await mapDirectChirpRequest(prisma, row, userId) });
    return;
  }

  const column = status === "cancelled" ? "cancelledAt" : `${status}At`;
  await prisma.$executeRawUnsafe(
    `UPDATE "DirectChirpRequest" SET "status" = ?, "${column}" = CURRENT_TIMESTAMP, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
    status,
    row.id
  );

  if (status === "blocked") {
    await prisma.oneWayContact.upsert({
      where: { userId_contactUserId: { userId: row.recipientUserId, contactUserId: row.senderUserId } },
      update: { status: "blocked", direction: "blocked", blockedAt: new Date() },
      create: {
        id: randomUUID(),
        userId: row.recipientUserId,
        contactUserId: row.senderUserId,
        status: "blocked",
        direction: "blocked",
        blockedAt: new Date(),
      },
    });
  }

  const updated = (await directRequestRows(prisma, `id = ?`, [row.id]))[0] ?? row;
  if (status !== "accepted") {
    res.json({ request: await mapDirectChirpRequest(prisma, updated, userId) });
    return;
  }

  const senderIdentity = await loadPublicIdentity(row.senderUserId);
  const recipientIdentity = await loadPublicIdentity(row.recipientUserId);
  const session: WalkieSession = findActiveSessionForPair(row.senderUserId, row.recipientUserId) ?? {
    id: randomUUID(),
    channelId: row.channelId ?? walkieChannelId(row.senderUserId, row.recipientUserId),
    roomName: walkieRoomName(row.senderUserId, row.recipientUserId),
    callerUserId: row.senderUserId,
    caller: walkieDisplayName(senderIdentity),
    targetUserId: row.recipientUserId,
    target: walkieDisplayName(recipientIdentity),
    isGroup: false,
    participants: [
      {
        userId: row.senderUserId,
        displayName: walkieDisplayName(senderIdentity),
        onewayId: senderIdentity.onewayId,
        chirpId: row.senderChirpId,
      },
      {
        userId: row.recipientUserId,
        displayName: walkieDisplayName(recipientIdentity),
        onewayId: recipientIdentity.onewayId,
        chirpId: row.recipientChirpId,
      },
    ],
    startedAt: new Date().toISOString(),
  };
  sessions.set(session.id, session);

  try {
    res.json({
      request: await mapDirectChirpRequest(prisma, updated, userId),
      session: await toSessionResponse({ session, userId, tokens }),
    });
  } catch (error) {
    logger.error({ err: error, requestId: shortId(row.id) }, "[chirp:direct] accepted but token issue failed");
    res.status(500).json({ error: "direct_chirp_token_failed" });
  }
}

export function walkieRouter({
  prisma,
  tokens,
  isUserOnline = () => false,
}: WalkieRouterDeps): express.Router {
  const router = express.Router();

  router.get("/health", (_req, res) => {
    res.json({
      status: "ok",
      ok: true,
      service: "walkie",
      liveKitConfigured: tokens.isConfigured(),
    });
  });

  router.use(authMiddleware);

  router.get("/privacy", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    res.json(await getWalkiePrivacy(prisma, userId));
  });

  router.patch("/privacy", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const next = await updateWalkiePrivacyFromBody(prisma, userId, req.body ?? {}, res);
    if (next) res.json(next);
  });

  router.get("/direct/settings", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    res.json(await getWalkiePrivacy(prisma, userId));
  });

  router.put("/direct/settings", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const next = await updateWalkiePrivacyFromBody(prisma, userId, req.body ?? {}, res);
    if (next) res.json(next);
  });

  router.post("/direct/lookup", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = directLookupSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const target = await resolveWalkieTarget(prisma, parsed.data.chirpId);
    if (!target || target.userId === userId) {
      res.json({ found: false });
      return;
    }
    if (await isBlockedBetween(prisma, userId, target.userId)) {
      res.json({ found: false });
      return;
    }

    const privacy = await getWalkiePrivacy(prisma, target.userId);
    if (!await isDirectChirpDiscoverable(prisma, userId, target.userId, privacy)) {
      res.json({ found: false });
      return;
    }

    res.json({
      found: true,
      user: {
        userId: target.userId,
        displayName: target.display,
        handle: target.onewayId,
        chirpId: await ensureUserChirpId(prisma, target.userId),
        avatarURL: null,
        verified: false,
        directChirpAvailability: privacy.askBeforeConnecting ? "request_required" : "available",
      },
    });
  });

  router.post("/direct/request", async (req, res) => {
    const senderUserId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = directRequestSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const target = await resolveWalkieTarget(prisma, parsed.data.recipientChirpId);
    if (!target || target.userId === senderUserId) {
      res.status(404).json({ found: false, error: "direct_chirp_unavailable" });
      return;
    }
    if (await isBlockedBetween(prisma, senderUserId, target.userId)) {
      res.status(404).json({ found: false, error: "direct_chirp_unavailable" });
      return;
    }

    const privacy = await getWalkiePrivacy(prisma, target.userId);
    if (!await isDirectChirpDiscoverable(prisma, senderUserId, target.userId, privacy)) {
      res.status(404).json({ found: false, error: "direct_chirp_unavailable" });
      return;
    }

    const recent = await recentDirectChirpCount(prisma, senderUserId, target.userId);
    if (recent > 4) {
      res.status(429).json({ error: "direct_chirp_rate_limited", message: "Try again later." });
      return;
    }

    const senderChirpId = await ensureUserChirpId(prisma, senderUserId);
    const recipientChirpId = await ensureUserChirpId(prisma, target.userId);
    const requestId = randomUUID();
    const channelId = walkieChannelId(senderUserId, target.userId);
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

    await prisma.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "DirectChirpRequest"
       ("id", "senderUserId", "recipientUserId", "senderChirpId", "recipientChirpId", "status", "clientRequestId", "sourceDeviceId", "channelId", "expiresAt")
       VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)`,
      requestId,
      senderUserId,
      target.userId,
      senderChirpId,
      recipientChirpId,
      parsed.data.clientRequestId,
      parsed.data.sourceDeviceId ?? null,
      channelId,
      expiresAt
    );

    const rows = await directRequestRows(prisma, `senderUserId = ? AND recipientUserId = ? AND clientRequestId = ?`, [
      senderUserId,
      target.userId,
      parsed.data.clientRequestId,
    ]);
    const request = rows[0];
    if (!request) {
      res.status(500).json({ error: "direct_chirp_request_failed" });
      return;
    }

    logger.info({
      requestId: shortId(request.id),
      senderUserId: shortId(senderUserId),
      recipientUserId: shortId(target.userId),
    }, "[chirp:direct] request created");

    res.status(201).json({ request: await mapDirectChirpRequest(prisma, request, senderUserId) });
  });

  router.get("/direct/incoming", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await directRequestRows(prisma, `recipientUserId = ? AND status = 'pending'`, [userId]);
    res.json({ requests: await Promise.all(rows.map((row) => mapDirectChirpRequest(prisma, row, userId))) });
  });

  router.get("/direct/outgoing", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await directRequestRows(prisma, `senderUserId = ? AND status = 'pending'`, [userId]);
    res.json({ requests: await Promise.all(rows.map((row) => mapDirectChirpRequest(prisma, row, userId))) });
  });

  router.post("/direct/:requestId/accept", async (req, res) => {
    await handleDirectChirpAction(req, res, prisma, tokens, "accepted");
  });

  router.post("/direct/:requestId/decline", async (req, res) => {
    await handleDirectChirpAction(req, res, prisma, tokens, "declined");
  });

  router.post("/direct/:requestId/ignore", async (req, res) => {
    await handleDirectChirpAction(req, res, prisma, tokens, "ignored");
  });

  router.post("/direct/:requestId/block", async (req, res) => {
    await handleDirectChirpAction(req, res, prisma, tokens, "blocked");
  });

  router.delete("/direct/:requestId", async (req, res) => {
    await handleDirectChirpAction(req, res, prisma, tokens, "cancelled");
  });

  router.get("/contacts", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    res.json({ contacts: await loadWalkieContacts(prisma, userId, isUserOnline) });
  });

  router.get("/contacts/online", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const contacts = await loadWalkieContacts(prisma, userId, isUserOnline);
    res.json({ contacts: contacts.filter((contact) => contact.isOnline) });
  });

  router.post("/favorites/:userId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = emptyBodySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const contactUserId = req.params.userId;
    if (contactUserId === userId) {
      res.status(400).json({ error: "self_favorite_forbidden" });
      return;
    }
    if (!await areFriends(prisma, userId, contactUserId)) {
      res.status(403).json({
        error: "not_walkie_contact",
        message: "Only accepted OneWay contacts can be favorited for Walkie.",
      });
      return;
    }

    await prisma.walkieFavorite.upsert({
      where: {
        userId_contactUserId: {
          userId,
          contactUserId,
        },
      },
      update: {},
      create: {
        id: randomUUID(),
        userId,
        contactUserId,
      },
    });

    res.json({ ok: true, contacts: await loadWalkieContacts(prisma, userId, isUserOnline) });
  });

  router.delete("/favorites/:userId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await prisma.walkieFavorite.deleteMany({
      where: {
        userId,
        contactUserId: req.params.userId,
      },
    });
    res.json({ ok: true, contacts: await loadWalkieContacts(prisma, userId, isUserOnline) });
  });

  router.get("/channels", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const identity = await loadRequesterWalkieIdentity(prisma, req, userId);
    if (!identity?.onewayId) {
      res.status(403).json({
        error: "identity_required",
        message: "OneWay ID is required for Walkie.",
      });
      return;
    }

    const active = Array.from(sessions.values()).filter((session) =>
      !session.endedAt && isSessionParticipant(session, userId)
    );

    const channels = await Promise.all(active.map(async (session) => {
      const incoming = !session.isGroup && session.targetUserId === userId;
      const peerUserId = session.isGroup
        ? session.callerUserId
        : (incoming ? session.callerUserId : session.targetUserId);
      const peerIdentity = await prisma.oneWayIdentity.findUnique({
        where: { userId: peerUserId ?? session.callerUserId },
        select: {
          onewayId: true,
          walkieName: true,
          displayName: true,
          username: true,
        },
      });
      const [primaryNumber, anyNumber] = await Promise.all([
        prisma.userNumber.findFirst({
          where: { userId: peerUserId ?? session.callerUserId, isPrimary: true },
          select: { number: true },
        }),
        prisma.userNumber.findFirst({
          where: { userId: peerUserId ?? session.callerUserId },
          orderBy: { createdAt: "asc" },
          select: { number: true },
        }),
      ]);

      const base = toChannelDTO(session, userId);
      const fromOneWayId = peerIdentity?.onewayId ?? undefined;
      const fromWalkieName = walkieDisplayName(peerIdentity);
      const fromDisplayName =
        peerIdentity?.displayName ??
        fromWalkieName ??
        fromOneWayId ??
        "OneWay User";
      const fromNumber =
        primaryNumber?.number ??
        anyNumber?.number ??
        fromOneWayId ??
        undefined;
      return {
        ...base,
        isIncoming: incoming,
        fromWalkieName,
        fromDisplayName,
        fromOneWayId,
        fromNumber,
      };
    }));

    res.json({
      channels,
      liveKitConfigured: tokens.isConfigured(),
    });
  });

  router.post("/sessions", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = sessionCreateSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const caller = await loadRequesterWalkieIdentity(prisma, req, userId);
    if (!caller?.onewayId) {
      res.status(403).json({
        error: "identity_required",
        message: "OneWay ID is required for Walkie.",
      });
      return;
    }

    const requestedTargets = parsed.data.targets?.length
      ? parsed.data.targets
      : (parsed.data.target ? [parsed.data.target] : []);

    const resolvedTargets: WalkieParticipant[] = [];
    for (const rawTarget of requestedTargets) {
      logger.info({
        event: "CHIRP_SERVER_TARGET_RESOLVE_STARTED",
        senderUserId: shortId(userId),
        displayedHandle: shortId(rawTarget),
      }, "[chirp] target resolve started");
      const target = await resolveWalkieTarget(prisma, rawTarget);
      if (!target) {
        logger.warn({
          event: "CHIRP_SERVER_PACKET_REJECTED",
          stage: "target_resolution",
          senderUserId: shortId(userId),
          displayedHandle: shortId(rawTarget),
          reason: "target_unreachable",
        }, "[chirp] target unreachable");
        res.status(404).json({
          error: "target_unreachable",
          message: `No current OneWay account matches ${rawTarget}. Confirm the recipient's current Chirp ID and try again.`,
        });
        return;
      }
      logger.info({
        event: "CHIRP_SERVER_RECIPIENT_RESOLVED",
        senderUserId: shortId(userId),
        recipientUserId: shortId(target.userId),
        displayedHandle: shortId(rawTarget),
        recipientUserIdIsDifferentFromCurrentUser: target.userId !== userId,
      }, "[chirp] recipient resolved");
      if (target.userId === userId) continue;
      if (!resolvedTargets.some((participant) => participant.userId === target.userId)) {
        resolvedTargets.push({
          userId: target.userId,
          displayName: target.display,
          onewayId: target.onewayId,
          chirpId: target.chirpId ?? await ensureUserChirpId(prisma, target.userId),
        });
      }
    }

    const isGroup = resolvedTargets.length > 1 || Boolean(parsed.data.targets?.length);
    if (!isGroup && resolvedTargets.length !== 1) {
      res.status(400).json({ error: "target_required" });
      return;
    }
    if (isGroup && resolvedTargets.length < 2) {
      res.status(400).json({
        error: "group_requires_two_targets",
        message: "Add at least two other people to start a group walkie.",
      });
      return;
    }

    for (const target of resolvedTargets) {
      if (await isBlockedBetween(prisma, userId, target.userId)) {
        logger.warn({
          event: "CHIRP_SERVER_PACKET_REJECTED",
          stage: "session_create",
          senderUserId: shortId(userId),
          recipientUserId: shortId(target.userId),
          reason: "blocked",
        }, "[chirp] blocked target rejected");
        res.status(403).json({
          error: "walkie_blocked",
          message: `${target.displayName} is unavailable for Walkie right now.`,
        });
        return;
      }

      const allowed = await isWalkieAllowedByTargetPrivacy(prisma, userId, target.userId);
      if (!allowed) {
        logger.warn({
          event: "CHIRP_SERVER_PACKET_REJECTED",
          stage: "session_create",
          senderUserId: shortId(userId),
          recipientUserId: shortId(target.userId),
          reason: "privacy_not_allowed",
        }, "[chirp] privacy rejected");
        res.status(403).json({
          error: "walkie_not_allowed",
          message: `${target.displayName} is not accepting Walkie requests from you.`,
        });
        return;
      }
    }

    const callerParticipant: WalkieParticipant = {
      userId,
      displayName: walkieDisplayName(caller),
      onewayId: caller.onewayId,
      chirpId: await ensureUserChirpId(prisma, userId),
    };

    if (isGroup) {
      const id = randomUUID();
      const groupName = parsed.data.groupName?.trim() || "Crew Walkie";
      const session: WalkieSession = {
        id,
        channelId: `walkie-group-${id}`,
        roomName: groupWalkieRoomName(id),
        callerUserId: userId,
        caller: walkieDisplayName(caller),
        groupName,
        isGroup: true,
        participants: [callerParticipant, ...resolvedTargets],
        startedAt: new Date().toISOString(),
      };

      sessions.set(session.id, session);
      logger.info({
        userId: shortId(userId),
        roomName: shortId(session.roomName),
        participantCount: session.participants.length,
      }, "[walkie] group session start");

      try {
        res.status(201).json(await toSessionResponse({ session, userId, tokens }));
      } catch (error) {
        res.status(500).json({ error: "walkie_token_failed" });
      }
      return;
    }

    const target = resolvedTargets[0];
    if (!target) {
      res.status(404).json({
        error: "target_unreachable",
        message: "This person is not reachable on OneWay Walkie yet.",
      });
      return;
    }
    // Ensure both devices always join the same LiveKit room for a given user pair.
    // We reuse an existing active session (half-duplex is handled client-side for now).
    const existing = findActiveSessionForPair(userId, target.userId);
    const session: WalkieSession = existing ?? {
      id: randomUUID(),
      channelId: walkieChannelId(userId, target.userId),
      roomName: walkieRoomName(userId, target.userId),
      callerUserId: userId,
      caller: walkieDisplayName(caller),
      targetUserId: target.userId,
      target: target.displayName,
      isGroup: false,
      participants: [callerParticipant, target],
      startedAt: new Date().toISOString(),
    };

    if (!existing) {
      sessions.set(session.id, session);
      logger.info({
        event: "CHIRP_SERVER_SESSION_CREATED",
        userId: shortId(userId),
        targetUserId: shortId(target.userId),
        recipientUserId: shortId(target.userId),
        sessionId: shortId(session.id),
        channelId: shortId(session.channelId),
        roomName: shortId(session.roomName),
      }, "[walkie] session start");
    } else {
      logger.info({
        event: "CHIRP_SERVER_SESSION_REUSED",
        userId: shortId(userId),
        targetUserId: shortId(target.userId),
        recipientUserId: shortId(target.userId),
        roomName: shortId(session.roomName),
        sessionId: shortId(session.id),
        channelId: shortId(session.channelId),
      }, "[walkie] session reuse");
    }
    try {
      res.status(201).json(await toSessionResponse({ session, userId, tokens }));
    } catch (error) {
      res.status(500).json({ error: "walkie_token_failed" });
    }
  });

  router.post("/sessions/:sessionId/join", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const session = sessions.get(req.params.sessionId);
    if (!session) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (session.endedAt) {
      res.status(410).json({ error: "ended" });
      return;
    }
    if (!isSessionParticipant(session, userId)) {
      logger.warn({
        event: "CHIRP_SERVER_PACKET_REJECTED",
        stage: "join",
        userId: shortId(userId),
        sessionId: shortId(session.id),
        reason: "not_participant",
      }, "[chirp] join rejected");
      res.status(403).json({ error: "not_participant" });
      return;
    }

    try {
      logger.info({
        event: "CHIRP_SERVER_RECEIVER_JOINED",
        userId: shortId(userId),
        sessionId: shortId(session.id),
        channelId: shortId(session.channelId),
        roomName: shortId(session.roomName),
      }, "[chirp] receiver joined");
      res.json(await toSessionResponse({ session, userId, tokens }));
    } catch (error) {
      res.status(500).json({ error: "walkie_token_failed" });
    }
  });

  router.post("/sessions/:sessionId/transmit/start", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const session = sessions.get(req.params.sessionId);
    logger.info({
      event: "CHIRP_SERVER_PACKET_RECEIVED",
      stage: "transmit_start",
      userId: shortId(userId),
      sessionId: shortId(req.params.sessionId),
    }, "[chirp] transmit start requested");
    if (!session) {
      logger.warn({
        event: "CHIRP_SERVER_PACKET_REJECTED",
        stage: "transmit_start",
        userId: shortId(userId),
        sessionId: shortId(req.params.sessionId),
        reason: "not_found",
      }, "[chirp] transmit start rejected");
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (session.endedAt) {
      res.status(410).json({ error: "ended" });
      return;
    }
    if (!isSessionParticipant(session, userId)) {
      logger.warn({
        event: "CHIRP_SERVER_PACKET_REJECTED",
        stage: "transmit_start",
        userId: shortId(userId),
        sessionId: shortId(session.id),
        reason: "not_participant",
      }, "[chirp] transmit start rejected");
      res.status(403).json({ error: "not_participant" });
      return;
    }
    if (session.transmitterUserId && session.transmitterUserId !== userId) {
      logger.warn({
        event: "CHIRP_SERVER_PACKET_REJECTED",
        stage: "transmit_start",
        userId: shortId(userId),
        sessionId: shortId(session.id),
        transmitterUserId: shortId(session.transmitterUserId),
        reason: "channel_busy",
      }, "[chirp] transmit busy");
      res.status(409).json({
        error: "channel_busy",
        message: "Another participant is talking.",
        transmitterUserId: session.transmitterUserId,
      });
      return;
    }

    session.transmitterUserId = userId;
    sessions.set(session.id, session);
    logger.info({
      event: "CHIRP_SERVER_PACKET_ACKNOWLEDGED",
      chirpEvent: "chirp.channel.granted",
      userId: shortId(userId),
      sessionId: shortId(session.id),
      channelId: shortId(session.channelId),
      roomName: shortId(session.roomName),
      participantCount: session.participants.length,
    }, "[walkie] transmit granted");
    logger.info({
      event: "CHIRP_SERVER_PACKET_FORWARDED",
      stage: "livekit_audio_room",
      senderUserId: shortId(userId),
      recipientUserIds: session.participants.filter((participant) => participant.userId !== userId).map((participant) => shortId(participant.userId)),
      sessionId: shortId(session.id),
      channelId: shortId(session.channelId),
      roomName: shortId(session.roomName),
    }, "[chirp] livekit room ready for forwarding");
    res.json({ status: "granted", sessionId: session.id, transmitterUserId: userId });
  });

  router.post("/sessions/:sessionId/transmit/end", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const session = sessions.get(req.params.sessionId);
    logger.info({
      event: "CHIRP_SERVER_PACKET_RECEIVED",
      stage: "transmit_end",
      userId: shortId(userId),
      sessionId: shortId(req.params.sessionId),
    }, "[chirp] transmit end requested");
    if (!session) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isSessionParticipant(session, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }

    if (session.transmitterUserId === userId) {
      session.transmitterUserId = undefined;
      sessions.set(session.id, session);
    }
    logger.info({
      event: "chirp.channel.released",
      userId: shortId(userId),
      sessionId: shortId(session.id),
      channelId: shortId(session.channelId),
      roomName: shortId(session.roomName),
    }, "[walkie] transmit released");
    res.json({ status: "released", sessionId: session.id });
  });

  router.post("/sessions/:sessionId/end", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const session = sessions.get(req.params.sessionId);
    if (!session) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isSessionParticipant(session, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }
    session.endedAt = session.endedAt ?? new Date().toISOString();
    sessions.set(session.id, session);

    logger.info({
      userId: shortId(userId),
      sessionId: shortId(session.id),
    }, "[walkie] session end");
    res.json({ sessionId: session.id, status: "ended" });
  });

  return router;
}

async function resolveWalkieTarget(
  prisma: PrismaClient,
  rawTarget: string
): Promise<{ userId: string; display: string; onewayId?: string | null; chirpId?: string | null } | null> {
  const target = rawTarget.trim();
  if (!target) return null;

  const chirpCandidates = chirpLookupCandidates(target);
  if (chirpCandidates.some((candidate) => /^OW[0-9]{6,9}$/.test(candidate))) {
    const user = await prisma.user.findFirst({
      where: { chirpIdNormalized: { in: chirpCandidates } },
      select: {
        id: true,
        chirpId: true,
        identity: {
          select: {
            userId: true,
            onewayId: true,
            walkieName: true,
            displayName: true,
            username: true,
          },
        },
      },
    });
    if (user) {
      const identity = user.identity ?? await loadPublicIdentity(user.id);
      return {
        userId: user.id,
        display: walkieDisplayName(identity),
        onewayId: identity.onewayId,
        chirpId: await ensureUserChirpId(prisma, user.id),
      };
    }
  }

  if (target.startsWith("@")) {
    const onewayId = normalizeOneWayId(target);
    const identity = await prisma.oneWayIdentity.findUnique({
      where: { onewayId },
      select: {
        userId: true,
        onewayId: true,
        walkieName: true,
        displayName: true,
        username: true,
      },
    });
    return identity ? { userId: identity.userId, display: walkieDisplayName(identity), onewayId: identity.onewayId } : null;
  }

  if (target.includes("@")) {
    const normalizedEmail = target.toLowerCase();
    const emailAlias = normalizedEmail.endsWith("@oneway.app")
      ? normalizedEmail
      : sanitizeEmailAlias(normalizedEmail);
    const identity = await prisma.oneWayIdentity.findUnique({
      where: { emailAlias },
      select: {
        userId: true,
        onewayId: true,
        walkieName: true,
        displayName: true,
        username: true,
      },
    });
    if (identity) {
      return { userId: identity.userId, display: walkieDisplayName(identity), onewayId: identity.onewayId };
    }

    const user = await prisma.user.findUnique({
      where: { email: normalizedEmail },
      select: {
        id: true,
        identity: {
          select: {
            userId: true,
            onewayId: true,
            walkieName: true,
            displayName: true,
            username: true,
          },
        },
      },
    });
    return user?.identity
      ? { userId: user.id, display: walkieDisplayName(user.identity), onewayId: user.identity.onewayId }
      : null;
  }

  const normalizedNumber = target.toUpperCase();
  if (/^OW-[0-9]{3,}$/.test(normalizedNumber)) {
    const number = await prisma.userNumber.findUnique({
      where: { number: normalizedNumber },
      select: { userId: true, number: true },
    });
    return number ? { userId: number.userId, display: number.number, onewayId: null } : null;
  }

  const phoneTarget = normalizePhoneTarget(target);
  if (phoneTarget) {
    const number = await prisma.userNumber.findUnique({
      where: { number: phoneTarget },
      select: { userId: true, number: true },
    });
    if (number) {
      const identity = await prisma.oneWayIdentity.findUnique({
        where: { userId: number.userId },
        select: {
          userId: true,
          onewayId: true,
          walkieName: true,
          displayName: true,
          username: true,
        },
      });
      return {
        userId: number.userId,
        display: identity ? walkieDisplayName(identity) : number.number,
        onewayId: identity?.onewayId,
      };
    }

    const business = await prisma.businessPresence.findFirst({
      where: { publicPhoneNumber: phoneTarget },
      select: {
        userId: true,
        publicPhoneNumber: true,
        user: {
          select: {
            identity: {
              select: {
                userId: true,
                onewayId: true,
                walkieName: true,
                displayName: true,
                username: true,
              },
            },
          },
        },
      },
    });
    return business
      ? {
          userId: business.userId,
          display: business.user.identity
            ? walkieDisplayName(business.user.identity)
            : business.publicPhoneNumber,
          onewayId: business.user.identity?.onewayId,
        }
      : null;
  }

  // Allow targeting by bare OneWay handle without the leading "@"
  // (e.g. "King" or "twinblixx"). This makes reachability less brittle
  // across clients and avoids one-way failures caused by UI stripping "@".
  if (!target.includes("@") && /^[A-Za-z0-9_.-]{2,64}$/.test(target)) {
    const onewayId = normalizeOneWayId(`@${target}`);
    const identity = await prisma.oneWayIdentity.findUnique({
      where: { onewayId },
      select: {
        userId: true,
        onewayId: true,
        walkieName: true,
        displayName: true,
        username: true,
      },
    });
    if (identity) {
      return { userId: identity.userId, display: walkieDisplayName(identity), onewayId: identity.onewayId };
    }
  }

  if (!target.includes("@") && /^[A-Za-z0-9_.\-\s]{2,64}$/.test(target)) {
    const byWalkieNameOrUsername = await prisma.oneWayIdentity.findFirst({
      where: {
        OR: [
          { username: target },
          { walkieName: target },
          { displayName: target },
        ],
      },
      select: {
        userId: true,
        onewayId: true,
        walkieName: true,
        displayName: true,
        username: true,
      },
    });
    return byWalkieNameOrUsername
      ? {
          userId: byWalkieNameOrUsername.userId,
          display: walkieDisplayName(byWalkieNameOrUsername),
          onewayId: byWalkieNameOrUsername.onewayId,
        }
      : null;
  }

  return null;
}

async function loadWalkieContacts(
  prisma: PrismaClient,
  userId: string,
  isUserOnline: (userId: string) => boolean
): Promise<WalkieContactDTO[]> {
  const [contacts, favorites] = await Promise.all([
    prisma.oneWayContact.findMany({
      where: {
        userId,
        status: "connected",
      },
      orderBy: { updatedAt: "desc" },
    }),
    prisma.walkieFavorite.findMany({
      where: { userId },
      select: { contactUserId: true },
    }),
  ]);

  const favoriteIds = new Set(favorites.map((favorite) => favorite.contactUserId));
  const mapped = await Promise.all(contacts.map(async (contact) => {
    const identity = await loadPublicIdentity(contact.contactUserId);
    const chirpId = await ensureUserChirpId(prisma, contact.contactUserId);
    return {
      id: contact.contactUserId,
      userId: contact.contactUserId,
      contactId: contact.id,
      displayName: contact.nickname?.trim() || identity.walkieName || identity.displayName,
      handle: identity.onewayId,
      chirpId,
      status: "accepted" as const,
      availability: "available" as const,
      // App presence comes from authenticated realtime sockets. An active
      // Walkie session is an additional positive signal, not the sole
      // definition of online; otherwise every contact appears offline until
      // after a channel has already been created.
      isOnline: isUserOnline(contact.contactUserId) || hasActiveWalkiePresence(contact.contactUserId),
      isFavorite: favoriteIds.has(contact.contactUserId),
    };
  }));

  return mapped.sort((left, right) => {
    if (left.isFavorite !== right.isFavorite) return left.isFavorite ? -1 : 1;
    if (left.isOnline !== right.isOnline) return left.isOnline ? -1 : 1;
    return left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" });
  });
}

function hasActiveWalkiePresence(userId: string): boolean {
  for (const session of sessions.values()) {
    if (!session.endedAt && isSessionParticipant(session, userId)) return true;
  }
  return false;
}

async function toSessionResponse({
  session,
  userId,
  tokens,
}: {
  session: WalkieSession;
  userId: string;
  tokens: LiveKitTokenService;
}) {
  const liveKitConfigured = tokens.isConfigured();
  const base = {
    sessionId: session.id,
    channelId: session.channelId,
    roomName: session.roomName,
    target: peerDisplay(session, userId),
    groupName: session.groupName,
    participants: session.participants,
    participantCount: session.participants.length,
    isGroup: Boolean(session.isGroup),
    status: liveKitConfigured ? "ready" : "unavailable",
    liveKitConfigured,
    message: liveKitConfigured ? undefined : "LiveKit is unavailable for Walkie.",
  };

  if (!liveKitConfigured) return base;

  const participantIdentity = `chirp-user-${userId}`;
  const issued = await tokens.issue({
    roomName: session.roomName,
    identity: participantIdentity,
    displayName: session.participants.find((participant) => participant.userId === userId)?.displayName ?? userId,
    ttlSeconds: 1800,
    metadata: JSON.stringify({
      userId,
      participantIdentity,
      walkieSessionId: session.id,
      roomName: session.roomName,
    }),
  });

  logger.info({
    event: "chirp.media.token.issued",
    userId: shortId(userId),
    participantIdentity: shortId(participantIdentity),
    sessionId: shortId(session.id),
    channelId: shortId(session.channelId),
    roomName: shortId(session.roomName),
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
  }, "[walkie] media token issued");

  return {
    ...base,
    liveKitUrl: issued.url,
    token: issued.token,
  };
}

function toChannelDTO(session: WalkieSession, userId: string) {
  return {
    id: session.id,
    sessionId: session.id,
    channelId: session.channelId,
    roomName: session.roomName,
    target: peerDisplay(session, userId),
    groupName: session.groupName,
    participants: session.participants,
    participantCount: session.participants.length,
    isGroup: Boolean(session.isGroup),
    startedAt: session.startedAt,
    status: session.endedAt ? "ended" : "active",
  };
}

function peerDisplay(session: WalkieSession, userId: string): string {
  if (session.isGroup) return session.groupName ?? "Crew Walkie";
  return session.callerUserId === userId ? (session.target ?? "OneWay User") : session.caller;
}
