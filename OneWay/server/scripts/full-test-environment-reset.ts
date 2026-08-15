import "dotenv/config";
import { PrismaClient } from "@prisma/client";
import fs from "fs/promises";
import path from "path";
import { redis } from "../src/lib/redis";

const prisma = new PrismaClient();
const execute = process.argv.includes("--execute");

type RowCounts = Record<string, number>;

const systemTables = new Set([
  "_prisma_migrations",
  "PlatformCapabilityState",
  "SecurityCheckRun",
  "AuditEvent",
  "PublicWebPage",
  "PublicWebCrawlJob",
  "Recording",
]);

const deleteOrder = [
  "MessageReceipt",
  "MessageAttachment",
  "Message",
  "ConversationParticipant",
  "Conversation",
  "CommunityMessage",
  "CommunityMember",
  "CommunityGroup",
  "Community",
  "Friendship",
  "OneWayContact",
  "WalkieFavorite",
  "CallHistoryEntry",
  "Voicemail",
  "Call",
  "CallSession",
  "PushToken",
  "StoreEmailMessage",
  "StoreAnalyticsEvent",
  "StoreNotification",
  "StoreOrderRequest",
  "StoreInquiry",
  "StorePolicy",
  "StorefrontGeneratedContent",
  "StorefrontAsset",
  "StorefrontTheme",
  "StorefrontCollection",
  "OrderItem",
  "Order",
  "Ad",
  "AIAvatarContent",
  "ScheduledLive",
  "StorefrontProduct",
  "Storefront",
  "Site",
  "BusinessPresence",
  "PrivacySetting",
  "AILog",
  "CloudFile",
  "ScheduledMessage",
  "ChannelPost",
  "WorkspaceItem",
  "OneWayNetworkEvent",
  "UserNumber",
  "Subscription",
  "WalkiePrivacySettings",
  "ledger_reconciliations",
  "ledger_entries",
  "ledger_transactions",
  "accounts",
  "OneWayIdentity",
  "User",
];

function dbUrl(): string {
  return process.env.DATABASE_URL ?? "";
}

function redactedDbUrl(): string {
  const value = dbUrl();
  return value.replace(/:\/\/([^:]+):([^@]+)@/, "://$1:***@");
}

function environmentName(): string {
  return process.env.NODE_ENV ?? "development";
}

function assertEnvironment(): void {
  if (process.env.ALLOW_FULL_PROFILE_RESET !== "true") {
    throw new Error("Refusing full reset: set ALLOW_FULL_PROFILE_RESET=true for this command.");
  }
  if (!dbUrl().startsWith("file:")) {
    throw new Error(`Refusing full reset outside local SQLite dev DB. DATABASE_URL=${redactedDbUrl()}`);
  }
  if (environmentName() === "production") {
    throw new Error("Refusing full reset with NODE_ENV=production.");
  }
}

async function existingTables(): Promise<Set<string>> {
  const rows = await prisma.$queryRawUnsafe<Array<{ name: string }>>(
    "SELECT name FROM sqlite_master WHERE type='table'"
  );
  return new Set(rows.map((row) => row.name));
}

async function rowCount(table: string): Promise<number> {
  const rows = await prisma.$queryRawUnsafe<Array<{ count: bigint | number }>>(
    `SELECT COUNT(*) AS count FROM "${table}"`
  );
  return Number(rows[0]?.count ?? 0);
}

async function tableCounts(tables: Iterable<string>): Promise<RowCounts> {
  const counts: RowCounts = {};
  for (const table of tables) {
    if (systemTables.has(table)) continue;
    try {
      counts[table] = await rowCount(table);
    } catch {
      counts[table] = -1;
    }
  }
  return counts;
}

async function exportSafetySnapshot(tables: Set<string>): Promise<string> {
  const users = tables.has("User")
    ? await prisma.user.findMany({
        select: {
          id: true,
          email: true,
          displayName: true,
          chirpId: true,
          chirpIdNormalized: true,
          createdAt: true,
          identity: {
            select: {
              displayName: true,
              username: true,
              onewayId: true,
              emailAlias: true,
            },
          },
        },
        orderBy: { createdAt: "asc" },
      })
    : [];
  const counts = await tableCounts(tables);
  const exportDir = path.resolve(process.cwd(), "tmp", "full-test-reset");
  await fs.mkdir(exportDir, { recursive: true, mode: 0o700 });
  const filePath = path.join(exportDir, `snapshot-${Date.now()}.json`);
  await fs.writeFile(
    filePath,
    JSON.stringify(
      {
        exportedAt: new Date().toISOString(),
        environment: environmentName(),
        database: redactedDbUrl(),
        projectId: path.basename(path.resolve(process.cwd(), "..")),
        appBundleEnvironment: "$(PRODUCT_BUNDLE_IDENTIFIER)",
        users,
        rowCounts: counts,
      },
      null,
      2
    ),
    { mode: 0o600 }
  );
  return filePath;
}

async function deleteAllUserOwnedData(tables: Set<string>): Promise<RowCounts> {
  const deleted: RowCounts = {};
  await prisma.$transaction(async (tx) => {
    for (const table of deleteOrder) {
      if (!tables.has(table)) continue;
      const beforeRows = await tx.$queryRawUnsafe<Array<{ count: bigint | number }>>(
        `SELECT COUNT(*) AS count FROM "${table}"`
      );
      const before = Number(beforeRows[0]?.count ?? 0);
      await tx.$executeRawUnsafe(`DELETE FROM "${table}"`);
      deleted[table] = before;
    }
  });
  return deleted;
}

async function clearRedisKeys(): Promise<number> {
  const client = redis();
  if (!client) return 0;
  // ioredis exposes scan/del but the shared interface only promises del.
  // Keep this deliberately conservative so global Redis databases are not flushed.
  const keys = [
    "oneway:presence",
    "oneway:sockets",
    "oneway:notifications",
    "oneway:push",
    "oneway:calls",
    "oneway:walkie",
  ];
  await client.del(...keys);
  return keys.length;
}

async function verifyEmpty(tables: Set<string>): Promise<RowCounts> {
  const checks: RowCounts = {};
  for (const table of deleteOrder) {
    if (!tables.has(table)) continue;
    checks[table] = await rowCount(table);
  }
  return checks;
}

async function main(): Promise<void> {
  const tables = await existingTables();
  console.log("Environment confirmation:");
  console.log({
    environment: environmentName(),
    databaseHost: dbUrl().startsWith("file:") ? "local-sqlite-file" : "external-db",
    database: redactedDbUrl(),
    projectId: path.basename(path.resolve(process.cwd(), "..")),
    appBundleEnvironment: "$(PRODUCT_BUNDLE_IDENTIFIER)",
    mode: execute ? "execute" : "dry-run",
  });

  const exportPath = await exportSafetySnapshot(tables);
  console.log(`Safety snapshot written: ${exportPath}`);

  if (!execute) {
    console.log("Dry run complete. Execution requires ALLOW_FULL_PROFILE_RESET=true and --execute.");
    return;
  }

  assertEnvironment();
  const deleted = await deleteAllUserOwnedData(tables);
  const redisKeys = await clearRedisKeys();
  const remaining = await verifyEmpty(tables);

  console.log("Deleted row counts:");
  console.log(JSON.stringify(deleted, null, 2));
  console.log("External cleanup:");
  console.log(JSON.stringify({
    authUsersDeleted: deleted.User ?? 0,
    redisKeysDeleted: redisKeys,
    storageObjectsDeleted: 0,
    liveKitAccountRecordsDeleted: 0,
    twilioAccountRecordsDeleted: 0,
    note: "Local dev uses stateless JWT auth and no configured file-storage/auth-provider deletion API.",
  }, null, 2));
  console.log("Post-reset row counts:");
  console.log(JSON.stringify(remaining, null, 2));
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
