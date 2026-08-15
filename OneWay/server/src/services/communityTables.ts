import type { PrismaClient } from "@prisma/client";

import { addColumnIfMissing } from "../lib/runtimeSchemaPatch";
import { logger } from "../lib/logger";

export async function ensureCommunityTables(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "Community" (
      "id" TEXT PRIMARY KEY,
      "ownerId" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "normalizedName" TEXT NOT NULL DEFAULT '',
      "description" TEXT NOT NULL DEFAULT '',
      "creatorHandle" TEXT NOT NULL DEFAULT '@oneway',
      "visibility" TEXT NOT NULL DEFAULT 'public',
      "blockedUserIdsJson" TEXT NOT NULL DEFAULT '[]',
      "bannedUserIdsJson" TEXT NOT NULL DEFAULT '[]',
      "deletedAt" TIMESTAMP,
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  await addColumnIfMissing(prisma, { table: "Community", columnDefinition: `"normalizedName" TEXT NOT NULL DEFAULT ''`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "Community", columnDefinition: `"creatorHandle" TEXT NOT NULL DEFAULT '@oneway'`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "Community", columnDefinition: `"visibility" TEXT NOT NULL DEFAULT 'public'`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "Community", columnDefinition: `"blockedUserIdsJson" TEXT NOT NULL DEFAULT '[]'`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "Community", columnDefinition: `"bannedUserIdsJson" TEXT NOT NULL DEFAULT '[]'`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "Community", columnDefinition: `"deletedAt" TIMESTAMP`, logPrefix: "community schema patch" });

  await prisma.$executeRawUnsafe(`
    UPDATE "Community"
    SET "normalizedName" = LOWER(TRIM("name"))
    WHERE "normalizedName" IS NULL OR TRIM("normalizedName") = ''
  `);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "CommunityMember" (
      "id" TEXT PRIMARY KEY,
      "communityId" TEXT NOT NULL,
      "userId" TEXT NOT NULL,
      "displayName" TEXT NOT NULL DEFAULT 'OneWay User',
      "handle" TEXT NOT NULL DEFAULT '@oneway',
      "role" TEXT NOT NULL DEFAULT 'member',
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "CommunityMember_communityId_fkey" FOREIGN KEY ("communityId") REFERENCES "Community" ("id") ON DELETE CASCADE
    )
  `);
  await addColumnIfMissing(prisma, { table: "CommunityMember", columnDefinition: `"displayName" TEXT NOT NULL DEFAULT 'OneWay User'`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "CommunityMember", columnDefinition: `"handle" TEXT NOT NULL DEFAULT '@oneway'`, logPrefix: "community schema patch" });
  await addColumnIfMissing(prisma, { table: "CommunityMember", columnDefinition: `"createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`, logPrefix: "community schema patch" });

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "CommunityMessage" (
      "id" TEXT PRIMARY KEY,
      "communityId" TEXT NOT NULL,
      "senderId" TEXT NOT NULL,
      "senderHandle" TEXT NOT NULL,
      "senderDisplayName" TEXT NOT NULL,
      "body" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'sent',
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "CommunityMessage_communityId_fkey" FOREIGN KEY ("communityId") REFERENCES "Community" ("id") ON DELETE CASCADE
    )
  `);

  await prisma.$executeRawUnsafe(`
    UPDATE "Community"
    SET "deletedAt" = CURRENT_TIMESTAMP
    WHERE "id" IN (
      SELECT "id"
      FROM (
        SELECT
          "id",
          ROW_NUMBER() OVER (
            PARTITION BY "normalizedName"
            ORDER BY "createdAt" ASC, "id" ASC
          ) AS duplicateRank
        FROM "Community"
        WHERE "visibility" = 'public'
          AND "deletedAt" IS NULL
          AND TRIM("normalizedName") <> ''
      ) ranked
      WHERE duplicateRank > 1
    )
  `);

  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "Community_public_normalizedName_key" ON "Community"("normalizedName") WHERE "visibility" = 'public' AND "deletedAt" IS NULL`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Community_normalizedName_visibility_idx" ON "Community"("normalizedName", "visibility")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Community_visibility_deletedAt_idx" ON "Community"("visibility", "deletedAt")`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "CommunityMember_communityId_userId_key" ON "CommunityMember"("communityId", "userId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "CommunityMember_userId_idx" ON "CommunityMember"("userId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "CommunityMessage_communityId_createdAt_idx" ON "CommunityMessage"("communityId", "createdAt")`);

  logger.info({}, "[communities] tables ready");
}
