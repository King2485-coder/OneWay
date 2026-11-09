import type { PrismaClient } from "@prisma/client";

interface BcryptModule {
  hash(plain: string, rounds: number): Promise<string>;
}

interface DevTestAccount {
  legacyUserId: string;
  email: string;
  displayName: string;
  walkieName: string;
  username: string;
  onewayId: string;
  emailAlias: string;
  oneWayNumber: string;
  businessNumber: string;
  businessName: string;
}

const devTestAccounts: DevTestAccount[] = [
  {
    legacyUserId: "king-dev-user",
    email: "antoniohoshaw6@gmail.com",
    displayName: "King",
    walkieName: "King",
    username: "king",
    onewayId: "@king",
    emailAlias: "king@oneway.app",
    oneWayNumber: "OW-123456",
    businessNumber: "+15205238383",
    businessName: "King",
  },
  {
    legacyUserId: "twinblixx-dev-user",
    email: "twinblixx@oneway.app",
    displayName: "TwinBlixx",
    walkieName: "TwinBlixx",
    username: "twinblixx",
    onewayId: "@twinblixx",
    emailAlias: "twinblixx@oneway.app",
    oneWayNumber: "OW-654321",
    businessNumber: "+15205238384",
    businessName: "TwinBlixx",
  },
];

let bcryptCache: BcryptModule | null | undefined;

function loadBcrypt(): BcryptModule | null {
  if (bcryptCache !== undefined) return bcryptCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    bcryptCache = require("bcryptjs") as BcryptModule;
  } catch {
    bcryptCache = null;
  }
  return bcryptCache;
}

async function devTestPasswordHash(bcrypt: BcryptModule | null): Promise<string | null> {
  const password = process.env.ONEWAY_DEV_TEST_PASSWORD?.trim();
  if (!password || !bcrypt) return null;
  return bcrypt.hash(password, 12);
}

function shouldSeedDevTestAccounts(): boolean {
  const override = process.env.ONEWAY_SEED_DEV_TEST_ACCOUNTS?.trim().toLowerCase();
  if (override === "0" || override === "false" || override === "no") return false;
  if (override === "1" || override === "true" || override === "yes") return true;
  return false;
}

export async function ensureDevTestAccounts(prisma: PrismaClient): Promise<void> {
  if (!shouldSeedDevTestAccounts()) return;

  const bcrypt = loadBcrypt();

  const userIds: string[] = [];
  for (const account of devTestAccounts) {
    userIds.push(await ensureDevTestAccount(prisma, bcrypt, account));
  }

  if (userIds.length >= 2) {
    await ensureConnectedContact(prisma, userIds[0], userIds[1]);
    await ensureConnectedContact(prisma, userIds[1], userIds[0]);
  }
}

async function ensureDevTestAccount(
  prisma: PrismaClient,
  bcrypt: BcryptModule | null,
  account: DevTestAccount
): Promise<string> {
  const existingByEmail = await prisma.user.findUnique({
    where: { email: account.email },
    select: { id: true },
  });
  const existingByIdentity = await prisma.oneWayIdentity.findFirst({
    where: {
      OR: [
        { onewayId: account.onewayId },
        { emailAlias: account.emailAlias },
        { username: account.username },
      ],
    },
    select: { userId: true },
  });
  const existingByFallbackId = await prisma.user.findUnique({
    where: { id: account.legacyUserId },
    select: { id: true },
  });

  const userId =
    existingByEmail?.id ??
    existingByIdentity?.userId ??
    existingByFallbackId?.id;
  const passwordHash = await devTestPasswordHash(bcrypt);
  const existingUser = userId
    ? await prisma.user.findUnique({
        where: { id: userId },
        select: { passwordHash: true },
      })
    : null;

  const user = userId
    ? await prisma.user.update({
        where: { id: userId },
        data: {
          email: account.email,
          displayName: account.displayName,
          ...(passwordHash ? { passwordHash } : {}),
        },
        select: { id: true },
      })
    : await prisma.user.create({
      data: {
      email: account.email,
      passwordHash,
      displayName: account.displayName,
    },
      select: { id: true },
    });
  const resolvedUserId = user.id;

  if (!passwordHash && !existingUser?.passwordHash) {
    console.warn(`[devTestAccounts] ${account.onewayId} has no passwordHash. Set ONEWAY_DEV_TEST_PASSWORD locally to enable password login.`);
  }

  await prisma.oneWayIdentity.deleteMany({
    where: {
      userId: { not: resolvedUserId },
      OR: [
        { onewayId: account.onewayId },
        { emailAlias: account.emailAlias },
      ],
    },
  });

  await prisma.oneWayIdentity.upsert({
    where: { userId: resolvedUserId },
    create: {
      userId: resolvedUserId,
      displayName: account.displayName,
      walkieName: account.walkieName,
      username: account.username,
      usernameHidden: true,
      onewayId: account.onewayId,
      emailAlias: account.emailAlias,
      showEmailAlias: true,
      showOneWayId: true,
      showNumbers: true,
      preferredCallerIdentity: "onewayId",
    },
    update: {
      displayName: account.displayName,
      walkieName: account.walkieName,
      username: account.username,
      usernameHidden: true,
      onewayId: account.onewayId,
      emailAlias: account.emailAlias,
      showEmailAlias: true,
      showOneWayId: true,
      showNumbers: true,
      preferredCallerIdentity: "onewayId",
    },
  });

  await prisma.userNumber.updateMany({
    where: { userId: resolvedUserId, number: { notIn: [account.oneWayNumber, account.businessNumber] } },
    data: { isPrimary: false },
  });
  await upsertUserNumber(prisma, resolvedUserId, account.oneWayNumber, "OneWay", true, false);
  await upsertUserNumber(prisma, resolvedUserId, account.businessNumber, "Business", false, true);

  await prisma.businessPresence.upsert({
    where: { userId: resolvedUserId },
    create: {
      userId: resolvedUserId,
      businessName: account.businessName,
      publicPhoneNumber: account.businessNumber,
      setupStep: "complete",
      onboardingProgress: 100,
    },
    update: {
      businessName: account.businessName,
      publicPhoneNumber: account.businessNumber,
      setupStep: "complete",
      onboardingProgress: 100,
    },
  });

  await prisma.walkiePrivacySettings.upsert({
    where: { userId: resolvedUserId },
    create: {
      userId: resolvedUserId,
      allowFriends: true,
      allowFriendsOfFriends: true,
      allowAnyone: true,
    },
    update: {
      allowFriends: true,
      allowFriendsOfFriends: true,
      allowAnyone: true,
    },
  });

  return resolvedUserId;
}

async function upsertUserNumber(
  prisma: PrismaClient,
  userId: string,
  number: string,
  label: string,
  isPrimary: boolean,
  isPaid: boolean
): Promise<void> {
  await prisma.userNumber.upsert({
    where: { number },
    create: {
      userId,
      number,
      label,
      isPrimary,
      isPaid,
    },
    update: {
      userId,
      label,
      isPrimary,
      isPaid,
    },
  });
}

async function ensureConnectedContact(
  prisma: PrismaClient,
  userId: string,
  contactUserId: string
): Promise<void> {
  await prisma.oneWayContact.upsert({
    where: {
      userId_contactUserId: {
        userId,
        contactUserId,
      },
    },
    create: {
      userId,
      contactUserId,
      status: "connected",
      direction: "outgoing",
    },
    update: {
      status: "connected",
      direction: "outgoing",
    },
  });
}
