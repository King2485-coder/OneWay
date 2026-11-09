import { prisma } from "../lib/db";
import { addColumnIfMissing } from "../lib/runtimeSchemaPatch";
import type { PrismaClient } from "@prisma/client";
import { randomInt } from "node:crypto";

const RESERVED_EMAIL_ALIASES = new Set([
  "admin",
  "support",
  "billing",
  "security",
  "oneway",
  "root",
]);

export interface PublicIdentity {
  displayName: string;
  walkieName: string;
  onewayId: string;
  chirpId: string;
  emailAlias: string;
  username: string | null;
  usernameHidden: boolean;
  showEmailAlias: boolean;
  showOneWayId: boolean;
  showNumbers: boolean;
  preferredCallerIdentity: "onewayId" | "number";
}

export async function ensureIdentityWalkieNameColumn(client: PrismaClient): Promise<void> {
  await addColumnIfMissing(client, {
    table: "OneWayIdentity",
    columnDefinition: `"walkieName" TEXT`,
    logPrefix: "identity schema patch",
  });

  await client.$executeRawUnsafe(`
    UPDATE "OneWayIdentity"
    SET "walkieName" = COALESCE(
      NULLIF(TRIM("displayName"), ''),
      NULLIF(TRIM("username"), ''),
      NULLIF(TRIM(REPLACE("onewayId", '@', '')), ''),
      'OneWay User'
    )
    WHERE "walkieName" IS NULL OR TRIM("walkieName") = ''
  `);

  await addColumnIfMissing(client, {
    table: "User",
    columnDefinition: `"chirpId" TEXT`,
    logPrefix: "chirp identity schema patch",
  });
  await addColumnIfMissing(client, {
    table: "User",
    columnDefinition: `"chirpIdNormalized" TEXT`,
    logPrefix: "chirp identity schema patch",
  });
  await addColumnIfMissing(client, {
    table: "User",
    columnDefinition: `"chirpIdCreatedAt" TIMESTAMP`,
    logPrefix: "chirp identity schema patch",
  });

  await client.$executeRawUnsafe(`
    CREATE UNIQUE INDEX IF NOT EXISTS "User_chirpId_key" ON "User"("chirpId")
  `);
  await client.$executeRawUnsafe(`
    CREATE UNIQUE INDEX IF NOT EXISTS "User_chirpIdNormalized_key" ON "User"("chirpIdNormalized")
  `);

  await backfillMissingChirpIds(client);
}

export async function ensureUserRecord(userId: string): Promise<void> {
  const fallbackName = `OneWay ${userId.slice(0, 6)}`;
  await prisma.user.upsert({
    where: { id: userId },
    update: {},
    create: {
      id: userId,
      displayName: fallbackName,
    },
  });
  await ensureUserChirpId(prisma, userId);
}

export function normalizeOneWayId(value: string): string {
  const trimmed = value.trim().toLowerCase().replace(/^@+/, "");
  return `@${trimmed}`;
}

export function normalizeEmailAlias(value: string): string {
  return sanitizeEmailAlias(value);
}

function toLower(value: string): string {
  return value.trim().toLowerCase();
}

export function sanitizeEmailAlias(value: string): string {
  const trimmed = toLower(value);
  return trimmed.endsWith("@oneway.app") ? trimmed : `${trimmed}@oneway.app`;
}

export function sanitizeWalkieName(value: string | null | undefined): string {
  const trimmed = String(value ?? "")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, 32);
  return trimmed || "OneWay User";
}

export function normalizeChirpId(value: string): string {
  const compact = String(value ?? "")
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");

  if (/^[0-9]{6,9}$/.test(compact)) return `OW${compact}`;
  return compact;
}

export function chirpLookupCandidates(value: string): string[] {
  const normalized = normalizeChirpId(value);
  if (!normalized) return [];
  const candidates = new Set([normalized]);
  if (/^OW[0-9]{6,9}$/.test(normalized)) {
    candidates.add(normalized.replace(/^OW/, ""));
  } else if (/^[0-9]{6,9}$/.test(normalized)) {
    candidates.add(`OW${normalized}`);
  }
  return Array.from(candidates);
}

export function isReservedAlias(localPart: string): boolean {
  return RESERVED_EMAIL_ALIASES.has(localPart);
}

function slugifySegment(value: string): string {
  const slug = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "")
    .slice(0, 24);
  return slug || "user";
}

async function generateUniqueOneWayId(seed: string): Promise<string> {
  const base = slugifySegment(seed);
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    const suffix = attempt === 0 ? "" : `${Math.floor(100 + Math.random() * 900)}`;
    const onewayId = normalizeOneWayId(`${base}${suffix}`);
    const existing = await prisma.oneWayIdentity.findUnique({
      where: { onewayId },
      select: { id: true },
    });
    if (!existing) return onewayId;
  }
  throw new Error("Unable to generate a unique OneWay ID");
}

async function generateUniqueEmailAlias(seed: string): Promise<string> {
  const base = slugifySegment(seed);
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    const suffix = attempt === 0 ? "" : `${Math.floor(100 + Math.random() * 900)}`;
    const localPart = `${base}${suffix}`;
    if (isReservedAlias(localPart)) continue;
    const emailAlias = sanitizeEmailAlias(localPart);
    const existing = await prisma.oneWayIdentity.findUnique({
      where: { emailAlias },
      select: { id: true },
    });
    if (!existing) return emailAlias;
  }
  throw new Error("Unable to generate a unique OneWay email alias");
}

function formatChirpId(normalized: string): string {
  const digits = normalized.replace(/^OW/, "");
  if (digits.length === 6) {
    return `OW-${digits.slice(0, 3)}-${digits.slice(3)}`;
  }
  return `OW-${digits}`;
}

async function generateUniqueChirpId(client: PrismaClient): Promise<{ chirpId: string; normalized: string }> {
  for (let attempt = 0; attempt < 250; attempt += 1) {
    const digits = String(randomInt(100_000, 1_000_000));
    const normalized = `OW${digits}`;
    const existing = await client.user.findUnique({
      where: { chirpIdNormalized: normalized },
      select: { id: true },
    });
    if (!existing) return { chirpId: formatChirpId(normalized), normalized };
  }
  throw new Error("Unable to generate a unique OneWay Chirp ID");
}

export async function ensureUserChirpId(client: PrismaClient, userId: string): Promise<string> {
  const current = await client.user.findUnique({
    where: { id: userId },
    select: {
      chirpId: true,
      chirpIdNormalized: true,
    },
  });
  if (!current) {
    throw new Error("user_not_found");
  }

  const currentChirp = current.chirpId?.trim() ?? "";
  const currentNormalized = current.chirpIdNormalized?.trim() ?? "";
  if (currentChirp && currentNormalized) return currentChirp;

  for (let attempt = 0; attempt < 10; attempt += 1) {
    const generated = await generateUniqueChirpId(client);
    try {
      const updated = await client.user.update({
        where: { id: userId },
        data: {
          chirpId: generated.chirpId,
          chirpIdNormalized: generated.normalized,
          chirpIdCreatedAt: new Date(),
        },
        select: { chirpId: true },
      });
      return updated.chirpId ?? generated.chirpId;
    } catch (error) {
      if (attempt === 9) throw error;
    }
  }

  throw new Error("Unable to assign OneWay Chirp ID");
}

export async function backfillMissingChirpIds(client: PrismaClient): Promise<void> {
  const users = await client.user.findMany({
    where: {
      OR: [
        { chirpId: null },
        { chirpIdNormalized: null },
      ],
    },
    select: { id: true },
    take: 1000,
  });

  for (const user of users) {
    await ensureUserChirpId(client, user.id);
  }
}

export async function createInitialIdentity(args: {
  userId: string;
  displayName?: string | null;
  walkieName?: string | null;
  username?: string | null;
  onewayId?: string | null;
  emailAlias?: string | null;
  usernameHidden?: boolean;
}): Promise<void> {
  await ensureUserRecord(args.userId);
  const existing = await prisma.oneWayIdentity.findUnique({
    where: { userId: args.userId },
    select: { id: true },
  });
  if (existing) return;

  const displayName = args.displayName?.trim() || null;
  const username = args.username?.trim() || null;

  const onewayId = args.onewayId?.trim()
    ? normalizeOneWayId(args.onewayId)
    : await generateUniqueOneWayId(displayName ?? username ?? args.userId);

  const requestedAlias = args.emailAlias?.trim()
    ? sanitizeEmailAlias(args.emailAlias)
    : await generateUniqueEmailAlias(displayName ?? username ?? args.userId);
  const localPart = requestedAlias.split("@")[0] ?? "";
  if (isReservedAlias(localPart)) {
    throw new Error("reserved_email_alias");
  }

  await prisma.oneWayIdentity.create({
    data: {
      userId: args.userId,
      displayName,
      walkieName: sanitizeWalkieName(args.walkieName ?? displayName ?? username ?? onewayId),
      username,
      usernameHidden: args.usernameHidden ?? true,
      onewayId,
      emailAlias: requestedAlias,
    },
  });
}

export async function loadPublicIdentity(userId: string): Promise<PublicIdentity> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: {
      displayName: true,
      email: true,
      accountStatus: true,
      identity: true,
    },
  });

  if (!user) {
    throw new Error("user_not_found");
  }

  if (user.accountStatus !== "active") {
    return {
      displayName: "Unavailable account",
      walkieName: "Unavailable account",
      onewayId: "@unavailable",
      chirpId: "",
      emailAlias: "unavailable@oneway.app",
      username: null,
      usernameHidden: true,
      showEmailAlias: false,
      showOneWayId: false,
      showNumbers: false,
      preferredCallerIdentity: "onewayId",
    };
  }

  if (!user.identity) {
    await createInitialIdentity({
      userId,
      displayName: user.displayName,
      username: user.email?.split("@")[0] ?? user.displayName,
    });
    return loadPublicIdentity(userId);
  }

  const chirpId = await ensureUserChirpId(prisma, userId);

  return {
    displayName: user.identity.displayName?.trim() || user.displayName || "OneWay User",
    walkieName: sanitizeWalkieName(
      user.identity.walkieName ??
      user.identity.displayName ??
      user.displayName ??
      user.identity.username ??
      user.identity.onewayId
    ),
    onewayId: user.identity.onewayId,
    chirpId,
    emailAlias: user.identity.emailAlias,
    username: user.identity.username,
    usernameHidden: user.identity.usernameHidden,
    showEmailAlias: user.identity.showEmailAlias,
    showOneWayId: user.identity.showOneWayId,
    showNumbers: user.identity.showNumbers,
    preferredCallerIdentity:
      user.identity.preferredCallerIdentity === "number" ? "number" : "onewayId",
  };
}
