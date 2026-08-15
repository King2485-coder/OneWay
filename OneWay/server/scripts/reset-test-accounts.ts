import "dotenv/config";
import { PrismaClient } from "@prisma/client";
import bcrypt from "bcryptjs";
import crypto from "crypto";
import fs from "fs/promises";
import path from "path";

const prisma = new PrismaClient();
type DbClient = PrismaClient | Parameters<Parameters<PrismaClient["$transaction"]>[0]>[0];

type TargetHandle = "king" | "twinblixx";

interface TargetAccount {
  handle: TargetHandle;
  displayName: string;
  email: string;
  username: string;
  onewayId: string;
  emailAlias: string;
  oneWayNumber: string;
  businessNumber: string;
  businessName: string;
}

interface TargetUser {
  handle: TargetHandle;
  id: string;
  email: string | null;
  displayName: string;
  chirpId: string | null;
  createdAt: Date;
  identity: {
    id: string;
    userId: string;
    displayName: string | null;
    username: string | null;
    onewayId: string;
    emailAlias: string;
  } | null;
}

const targets: TargetAccount[] = [
  {
    handle: "king",
    displayName: "King",
    email: "king@oneway.app",
    username: "king",
    onewayId: "@king",
    emailAlias: "king@oneway.app",
    oneWayNumber: "OW-123456",
    businessNumber: "+15205238383",
    businessName: "King",
  },
  {
    handle: "twinblixx",
    displayName: "TwinBlixx",
    email: "twinblixx@oneway.app",
    username: "twinblixx",
    onewayId: "@twinblixx",
    emailAlias: "twinblixx@oneway.app",
    oneWayNumber: "OW-654321",
    businessNumber: "+15205238384",
    businessName: "TwinBlixx",
  },
];

const execute = process.argv.includes("--execute");

function redactId(id: string | null | undefined): string {
  if (!id) return "none";
  if (id.length <= 12) return `${id.slice(0, 4)}…`;
  return `${id.slice(0, 8)}…${id.slice(-4)}`;
}

function normalizeHandle(value: string | null | undefined): string {
  return (value ?? "").trim().replace(/^@+/, "").toLowerCase();
}

function assertLocalDatabase(): void {
  const url = process.env.DATABASE_URL ?? "";
  if (!url.startsWith("file:")) {
    throw new Error(`Refusing test-account reset outside local SQLite dev database. DATABASE_URL=${url.replace(/\/\/.*@/, "//***@")}`);
  }
}

async function findTargets(): Promise<TargetUser[]> {
  const users = await prisma.user.findMany({
    where: {
      OR: targets.flatMap((target) => [
        { email: target.email },
        { identity: { username: target.username } },
        { identity: { onewayId: target.onewayId } },
        { identity: { emailAlias: target.emailAlias } },
      ]),
    },
    select: {
      id: true,
      email: true,
      displayName: true,
      chirpId: true,
      createdAt: true,
      identity: {
        select: {
          id: true,
          userId: true,
          displayName: true,
          username: true,
          onewayId: true,
          emailAlias: true,
        },
      },
    },
  });

  const tagged = users.map((user) => {
    const handle = normalizeHandle(user.identity?.onewayId ?? user.identity?.username ?? user.email);
    if (handle !== "king" && handle !== "twinblixx") {
      throw new Error(`Refusing to touch unexpected resolved account ${redactId(user.id)} handle=${handle}`);
    }
    return { ...user, handle } as TargetUser;
  });

  for (const handle of ["king", "twinblixx"] as const) {
    const matches = tagged.filter((user) => user.handle === handle);
    if (matches.length !== 1) {
      throw new Error(`Abort: handle ${handle} resolved to ${matches.length} users. Expected exactly 1.`);
    }
  }

  if (tagged.length !== 2) {
    throw new Error(`Abort: target query resolved ${tagged.length} users. Expected exactly 2.`);
  }

  return tagged.sort((a, b) => a.handle.localeCompare(b.handle));
}

async function countRaw(table: string, whereClause: string, ids: string[]): Promise<number> {
  const placeholders = ids.map(() => "?").join(",");
  const occurrenceCount = whereClause.match(/__IDS__/g)?.length ?? 1;
  const args = Array.from({ length: occurrenceCount }, () => ids).flat();
  const rows = await prisma.$queryRawUnsafe<Array<{ count: bigint | number }>>(
    `SELECT COUNT(*) AS count FROM "${table}" WHERE ${whereClause.replaceAll("__IDS__", placeholders)}`,
    ...args
  );
  return Number(rows[0]?.count ?? 0);
}

async function exportSafetySnapshot(users: TargetUser[], ids: string[]): Promise<string> {
  const relationshipCounts: Record<string, number> = {};
  const tables: Array<[string, string]> = [
    ["User", "id IN (__IDS__)"],
    ["OneWayIdentity", "userId IN (__IDS__)"],
    ["UserNumber", "userId IN (__IDS__)"],
    ["PushToken", "userId IN (__IDS__)"],
    ["OneWayContact", "userId IN (__IDS__) OR contactUserId IN (__IDS__)"],
    ["Friendship", "requesterUserId IN (__IDS__) OR recipientUserId IN (__IDS__)"],
    ["WalkieFavorite", "userId IN (__IDS__) OR contactUserId IN (__IDS__)"],
    ["ConversationParticipant", "userId IN (__IDS__)"],
    ["Message", "senderId IN (__IDS__)"],
    ["CommunityMember", "userId IN (__IDS__)"],
    ["CommunityMessage", "senderId IN (__IDS__)"],
    ["CallSession", "callerUserId IN (__IDS__) OR calleeUserId IN (__IDS__)"],
    ["Call", "callerId IN (__IDS__) OR calleeId IN (__IDS__)"],
    ["CallHistoryEntry", "userId IN (__IDS__)"],
    ["Voicemail", "callerId IN (__IDS__) OR calleeId IN (__IDS__)"],
    ["BusinessPresence", "userId IN (__IDS__)"],
    ["Site", "userId IN (__IDS__)"],
    ["Storefront", "ownerId IN (__IDS__)"],
    ["Order", "userId IN (__IDS__)"],
    ["accounts", "user_id IN (__IDS__)"],
    ["PrivacySetting", "userId IN (__IDS__)"],
    ["AILog", "userId IN (__IDS__)"],
    ["CloudFile", "ownerId IN (__IDS__)"],
    ["ScheduledMessage", "senderId IN (__IDS__)"],
    ["ChannelPost", "authorId IN (__IDS__)"],
  ];

  for (const [table, whereClause] of tables) {
    try {
      relationshipCounts[table] = await countRaw(table, whereClause, ids);
    } catch {
      relationshipCounts[table] = -1;
    }
  }

  const snapshot = {
    exportedAt: new Date().toISOString(),
    databaseUrl: "file:./dev.db",
    users: users.map((user) => ({
      handle: user.handle,
      userId: user.id,
      email: user.email,
      displayName: user.displayName,
      chirpId: user.chirpId,
      createdAt: user.createdAt,
      profile: user.identity
        ? {
            id: user.identity.id,
            userId: user.identity.userId,
            displayName: user.identity.displayName,
            username: user.identity.username,
            onewayId: user.identity.onewayId,
            emailAlias: user.identity.emailAlias,
          }
        : null,
    })),
    relationshipCounts,
  };

  const exportDir = path.resolve(process.cwd(), "tmp", "test-account-reset");
  await fs.mkdir(exportDir, { recursive: true, mode: 0o700 });
  const filePath = path.join(exportDir, `king-twinblixx-${Date.now()}.json`);
  await fs.writeFile(filePath, JSON.stringify(snapshot, null, 2), { mode: 0o600 });
  return filePath;
}

async function deleteConversationData(db: DbClient, ids: string[], counts: Record<string, number>): Promise<void> {
  const targetConversationRows = await db.$queryRawUnsafe<Array<{ conversationId: string }>>(
    `
    SELECT cp.conversationId
    FROM "ConversationParticipant" cp
    GROUP BY cp.conversationId
    HAVING
      SUM(CASE WHEN cp.userId IN (${ids.map(() => "?").join(",")}) THEN 1 ELSE 0 END) > 0
      AND SUM(CASE WHEN cp.userId NOT IN (${ids.map(() => "?").join(",")}) THEN 1 ELSE 0 END) = 0
    `,
    ...ids,
    ...ids
  );
  const conversationIds = targetConversationRows.map((row) => row.conversationId);
  if (conversationIds.length === 0) return;

  counts.MessageReceipt = await db.messageReceipt.deleteMany({
    where: { message: { conversationId: { in: conversationIds } } },
  }).then((r) => r.count);
  counts.MessageAttachment = await db.messageAttachment.deleteMany({
    where: { message: { conversationId: { in: conversationIds } } },
  }).then((r) => r.count);
  counts.Message = await db.message.deleteMany({
    where: { conversationId: { in: conversationIds } },
  }).then((r) => r.count);
  counts.ConversationParticipant = await db.conversationParticipant.deleteMany({
    where: { conversationId: { in: conversationIds } },
  }).then((r) => r.count);
  counts.Conversation = await db.conversation.deleteMany({
    where: { id: { in: conversationIds } },
  }).then((r) => r.count);
}

async function deleteRaw(db: DbClient, table: string, whereClause: string, ids: string[]): Promise<number> {
  const placeholders = ids.map(() => "?").join(",");
  const occurrenceCount = whereClause.match(/__IDS__/g)?.length ?? 1;
  const args = Array.from({ length: occurrenceCount }, () => ids).flat();
  return db.$executeRawUnsafe(
    `DELETE FROM "${table}" WHERE ${whereClause.replaceAll("__IDS__", placeholders)}`,
    ...args
  );
}

async function safeDelete(label: string, operation: () => Promise<{ count: number }>): Promise<number> {
  try {
    return (await operation()).count;
  } catch (error) {
    if (isMissingTableError(error)) return 0;
    throw error;
  }
}

function isMissingTableError(error: unknown): boolean {
  return Boolean(
    error &&
      typeof error === "object" &&
      "code" in error &&
      (error as { code?: string }).code === "P2021"
  );
}

async function cleanupUsers(users: TargetUser[]): Promise<Record<string, number>> {
  const ids = users.map((user) => user.id);
  const counts: Record<string, number> = {};

  await prisma.$transaction(async (scoped) => {

    counts.MessageReceiptByUser = await safeDelete("MessageReceiptByUser", () => scoped.messageReceipt.deleteMany({ where: { userId: { in: ids } } }));
    await deleteConversationData(scoped, ids, counts);
    counts.MessageFromTargets = await safeDelete("MessageFromTargets", () => scoped.message.deleteMany({ where: { senderId: { in: ids } } }));
    counts.ConversationParticipantFromTargets = await safeDelete("ConversationParticipantFromTargets", () => scoped.conversationParticipant.deleteMany({ where: { userId: { in: ids } } }));

    counts.CommunityMessage = await safeDelete("CommunityMessage", () => scoped.communityMessage.deleteMany({ where: { senderId: { in: ids } } }));
    counts.CommunityMember = await safeDelete("CommunityMember", () => scoped.communityMember.deleteMany({ where: { userId: { in: ids } } }));
    counts.CommunityOwnedSoftDelete = await safeDelete("CommunityOwnedSoftDelete", () => scoped.community.updateMany({
      where: { ownerId: { in: ids }, deletedAt: null },
      data: { deletedAt: new Date() },
    }));

    counts.OneWayContact = await safeDelete("OneWayContact", () => scoped.oneWayContact.deleteMany({
      where: { OR: [{ userId: { in: ids } }, { contactUserId: { in: ids } }] },
    }));
    counts.Friendship = await safeDelete("Friendship", () => scoped.friendship.deleteMany({
      where: { OR: [{ requesterUserId: { in: ids } }, { recipientUserId: { in: ids } }] },
    }));
    counts.WalkieFavorite = await safeDelete("WalkieFavorite", () => scoped.walkieFavorite.deleteMany({
      where: { OR: [{ userId: { in: ids } }, { contactUserId: { in: ids } }] },
    }));

    counts.CallHistoryEntry = await safeDelete("CallHistoryEntry", () => scoped.callHistoryEntry.deleteMany({ where: { userId: { in: ids } } }));
    counts.Voicemail = await safeDelete("Voicemail", () => scoped.voicemail.deleteMany({
      where: { OR: [{ callerId: { in: ids } }, { calleeId: { in: ids } }] },
    }));
    counts.Call = await safeDelete("Call", () => scoped.call.deleteMany({
      where: { OR: [{ callerId: { in: ids } }, { calleeId: { in: ids } }] },
    }));
    counts.CallSession = await safeDelete("CallSession", () => scoped.callSession.deleteMany({
      where: { OR: [{ callerUserId: { in: ids } }, { calleeUserId: { in: ids } }] },
    }));

    counts.PushToken = await safeDelete("PushToken", () => scoped.pushToken.deleteMany({ where: { userId: { in: ids } } }));
    counts.BusinessPresence = await safeDelete("BusinessPresence", () => scoped.businessPresence.deleteMany({ where: { userId: { in: ids } } }));
    counts.Site = await safeDelete("Site", () => scoped.site.deleteMany({ where: { userId: { in: ids } } }));
    counts.StoreInquiry = await safeDelete("StoreInquiry", () => scoped.storeInquiry.deleteMany({ where: { userId: { in: ids } } }));
    counts.StoreNotification = await safeDelete("StoreNotification", () => scoped.storeNotification.deleteMany({ where: { userId: { in: ids } } }));
    counts.StoreOrderRequest = await safeDelete("StoreOrderRequest", () => scoped.storeOrderRequest.deleteMany({
      where: {
        OR: [
          { userId: { in: ids } },
          { buyerWalletUserId: { in: ids } },
          { sellerWalletUserId: { in: ids } },
        ],
      },
    }));
    counts.StoreEmailMessage = await safeDelete("StoreEmailMessage", () => scoped.storeEmailMessage.deleteMany({ where: { userId: { in: ids } } }));
    counts.StoreAnalyticsEvent = await safeDelete("StoreAnalyticsEvent", () => scoped.storeAnalyticsEvent.deleteMany({ where: { userId: { in: ids } } }));
    counts.Order = await safeDelete("Order", () => scoped.order.deleteMany({ where: { userId: { in: ids } } }));
    counts.ProductImage = await safeDelete("ProductImage", () => scoped.productImage.deleteMany({ where: { sellerId: { in: ids } } }));
    counts.Storefront = await safeDelete("Storefront", () => scoped.storefront.deleteMany({ where: { ownerId: { in: ids } } }));

    counts.UserNumber = await safeDelete("UserNumber", () => scoped.userNumber.deleteMany({ where: { userId: { in: ids } } }));
    counts.Subscription = await safeDelete("Subscription", () => scoped.subscription.deleteMany({ where: { userId: { in: ids } } }));
    counts.WalkiePrivacySettings = await safeDelete("WalkiePrivacySettings", () => scoped.walkiePrivacySettings.deleteMany({ where: { userId: { in: ids } } }));
    counts.OneWayIdentity = await safeDelete("OneWayIdentity", () => scoped.oneWayIdentity.deleteMany({ where: { userId: { in: ids } } }));
    counts.OneWayNetworkEvent = await safeDelete("OneWayNetworkEvent", () => scoped.oneWayNetworkEvent.deleteMany({ where: { userId: { in: ids } } }));

    counts.PrivacySetting = await deleteRaw(scoped, "PrivacySetting", "userId IN (__IDS__)", ids).catch(() => 0);
    counts.AILog = await deleteRaw(scoped, "AILog", "userId IN (__IDS__)", ids).catch(() => 0);
    counts.CloudFile = await deleteRaw(scoped, "CloudFile", "ownerId IN (__IDS__)", ids).catch(() => 0);
    counts.ScheduledMessage = await deleteRaw(scoped, "ScheduledMessage", "senderId IN (__IDS__)", ids).catch(() => 0);
    counts.ChannelPost = await deleteRaw(scoped, "ChannelPost", "authorId IN (__IDS__)", ids).catch(() => 0);
    counts.accounts = await deleteLedgerAccounts(scoped, ids).catch(() => 0);

    counts.User = await safeDelete("User", () => scoped.user.deleteMany({ where: { id: { in: ids } } }));
  });

  return counts;
}

async function deleteLedgerAccounts(db: DbClient, ids: string[]): Promise<number> {
  const placeholders = ids.map(() => "?").join(",");
  const accounts = await db.$queryRawUnsafe<Array<{ id: string }>>(
    `SELECT id FROM "accounts" WHERE user_id IN (${placeholders})`,
    ...ids
  );
  const accountIds = accounts.map((account) => account.id);
  if (accountIds.length === 0) return 0;
  const accountPlaceholders = accountIds.map(() => "?").join(",");
  const transactionIds = await db.$queryRawUnsafe<Array<{ id: string }>>(
    `SELECT DISTINCT transaction_id AS id FROM "ledger_entries" WHERE account_id IN (${accountPlaceholders})`,
    ...accountIds
  );
  await db.$executeRawUnsafe(`DELETE FROM "ledger_reconciliations" WHERE account_id IN (${accountPlaceholders})`, ...accountIds);
  await db.$executeRawUnsafe(`DELETE FROM "ledger_entries" WHERE account_id IN (${accountPlaceholders})`, ...accountIds);
  if (transactionIds.length > 0) {
    const txIds = transactionIds.map((tx) => tx.id);
    const txPlaceholders = txIds.map(() => "?").join(",");
    await db.$executeRawUnsafe(`DELETE FROM "ledger_transactions" WHERE id IN (${txPlaceholders})`, ...txIds);
  }
  return db.$executeRawUnsafe(`DELETE FROM "accounts" WHERE id IN (${accountPlaceholders})`, ...accountIds);
}

async function createFreshAccounts(): Promise<Record<TargetHandle, string>> {
  const password = process.env.ONEWAY_DEV_TEST_PASSWORD?.trim();
  if (!password) {
    throw new Error("ONEWAY_DEV_TEST_PASSWORD is required to recreate password-login test accounts. It was not printed or stored.");
  }
  const passwordHash = await bcrypt.hash(password, 12);
  const created: Partial<Record<TargetHandle, string>> = {};

  for (const target of targets) {
    const user = await prisma.user.create({
      data: {
        email: target.email,
        passwordHash,
        displayName: target.displayName,
        chirpId: nextChirpId(),
        chirpIdNormalized: "",
        chirpIdCreatedAt: new Date(),
      },
      select: { id: true, chirpId: true },
    });
    await prisma.user.update({
      where: { id: user.id },
      data: { chirpIdNormalized: user.chirpId?.replace(/-/g, "") ?? null },
    });
    await prisma.oneWayIdentity.create({
      data: {
        userId: user.id,
        displayName: target.displayName,
        walkieName: target.displayName,
        username: target.username,
        usernameHidden: true,
        onewayId: target.onewayId,
        emailAlias: target.emailAlias,
        showEmailAlias: true,
        showOneWayId: true,
        showNumbers: true,
        preferredCallerIdentity: "onewayId",
      },
    });
    await prisma.userNumber.createMany({
      data: [
        { userId: user.id, number: target.oneWayNumber, label: "OneWay", isPrimary: true, isPaid: false },
        { userId: user.id, number: target.businessNumber, label: "Business", isPrimary: false, isPaid: true },
      ],
    });
    await prisma.businessPresence.create({
      data: {
        userId: user.id,
        businessName: target.businessName,
        publicPhoneNumber: target.businessNumber,
        setupStep: "complete",
        onboardingProgress: 100,
      },
    });
    await prisma.walkiePrivacySettings.create({
      data: {
        userId: user.id,
        allowFriends: true,
        allowFriendsOfFriends: true,
        allowAnyone: true,
      },
    });
    created[target.handle] = user.id;
  }

  if (!created.king || !created.twinblixx || created.king === created.twinblixx) {
    throw new Error("Fresh account assertion failed: King UUID must differ from TwinBlixx UUID.");
  }

  await prisma.oneWayContact.createMany({
    data: [
      { userId: created.king, contactUserId: created.twinblixx, status: "connected", direction: "outgoing", acceptedAt: new Date() },
      { userId: created.twinblixx, contactUserId: created.king, status: "connected", direction: "outgoing", acceptedAt: new Date() },
    ],
  });

  return created as Record<TargetHandle, string>;
}

function nextChirpId(): string {
  const digits = crypto.randomInt(100000, 999999).toString();
  return `OW-${digits.slice(0, 3)}-${digits.slice(3)}`;
}

async function verifyNoOldRows(oldIds: string[]): Promise<Record<string, number>> {
  const checks: Record<string, number> = {};
  checks.User = await countRaw("User", "id IN (__IDS__)", oldIds);
  checks.OneWayIdentity = await countRaw("OneWayIdentity", "userId IN (__IDS__)", oldIds);
  checks.UserNumber = await countRaw("UserNumber", "userId IN (__IDS__)", oldIds);
  checks.OneWayContact = await countRaw("OneWayContact", "userId IN (__IDS__) OR contactUserId IN (__IDS__)", oldIds);
  checks.Friendship = await countRaw("Friendship", "requesterUserId IN (__IDS__) OR recipientUserId IN (__IDS__)", oldIds);
  checks.CallSession = await countRaw("CallSession", "callerUserId IN (__IDS__) OR calleeUserId IN (__IDS__)", oldIds);
  checks.CommunityMember = await countRaw("CommunityMember", "userId IN (__IDS__)", oldIds);
  return checks;
}

async function main(): Promise<void> {
  assertLocalDatabase();
  let users: TargetUser[];
  try {
    users = await findTargets();
  } catch (error) {
    const existingTargetCount = await prisma.user.count({
      where: {
        OR: targets.flatMap((target) => [
          { email: target.email },
          { identity: { username: target.username } },
          { identity: { onewayId: target.onewayId } },
          { identity: { emailAlias: target.emailAlias } },
        ]),
      },
    });
    if (!execute || existingTargetCount !== 0) {
      throw error;
    }
    const newIds = await createFreshAccounts();
    const freshUsers = await findTargets();
    console.log("No existing @king/@twinblixx rows found. Recreated fresh accounts:");
    console.log(JSON.stringify({
      king: redactId(newIds.king),
      twinblixx: redactId(newIds.twinblixx),
      uuidAssertion: newIds.king !== newIds.twinblixx,
      records: freshUsers.map((user) => ({
        handle: user.handle,
        userUUID: redactId(user.id),
        chirpId: user.chirpId,
        profileRowExists: Boolean(user.identity),
      })),
    }, null, 2));
    return;
  }
  const oldIds = users.map((user) => user.id);

  console.log("Target confirmation:");
  for (const user of users) {
    console.log({
      handle: user.handle,
      userUUID: redactId(user.id),
      displayName: user.identity?.displayName ?? user.displayName,
      authProviderId: user.email ? user.email.replace(/^(.{2}).*(@.*)$/, "$1…$2") : "local-jwt",
      chirpId: user.chirpId ?? "none",
      createdAt: user.createdAt,
      profileRowExists: Boolean(user.identity),
    });
  }

  const exportPath = await exportSafetySnapshot(users, oldIds);
  console.log(`Safety export written: ${exportPath}`);

  if (!execute) {
    console.log("Dry run complete. Re-run with --execute to delete and recreate only @king and @twinblixx.");
    return;
  }

  const deletedCounts = await cleanupUsers(users);
  const oldRowChecks = await verifyNoOldRows(oldIds);
  const newIds = await createFreshAccounts();
  const freshUsers = await findTargets();

  console.log("Deleted row counts:");
  console.log(JSON.stringify(deletedCounts, null, 2));
  console.log("Old row verification:");
  console.log(JSON.stringify(oldRowChecks, null, 2));
  console.log("Fresh accounts:");
  console.log(JSON.stringify({
    king: redactId(newIds.king),
    twinblixx: redactId(newIds.twinblixx),
    uuidAssertion: newIds.king !== newIds.twinblixx,
    records: freshUsers.map((user) => ({
      handle: user.handle,
      userUUID: redactId(user.id),
      chirpId: user.chirpId,
      profileRowExists: Boolean(user.identity),
    })),
  }, null, 2));
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
