import { prisma } from "../lib/db";
import { logger } from "../lib/logger";

/**
 * Prisma-backed `userId → voipToken` store. The previous version was JSON
 * on disk; this one survives across instances and replicates naturally.
 *
 * Public surface is async — every callsite already awaited even when the
 * impl was synchronous, so the swap is a non-event for consumers.
 */
export interface PushTokenRecord {
  userId: string;
  voipToken: string;
  environment: "sandbox" | "production";
  updatedAt: number;
}

export class PushTokenStore {
  async set(record: PushTokenRecord): Promise<void> {
    if (!/^[0-9a-fA-F]{32,200}$/.test(record.voipToken)) {
      throw new Error("invalid_token_format");
    }
    // Apple recycles tokens after uninstall+reinstall under a different
    // account. Drop any prior owner before claiming.
    await prisma.pushToken.deleteMany({ where: { voipToken: record.voipToken } });
    await prisma.pushToken.upsert({
      where: { voipToken: record.voipToken },
      create: {
        userId: record.userId,
        voipToken: record.voipToken,
        environment: record.environment,
      },
      update: {
        userId: record.userId,
        environment: record.environment,
      },
    });
  }

  async get(userId: string): Promise<PushTokenRecord | undefined> {
    // A user may have multiple devices; return the most recent for now.
    // Future: send to all of them.
    const row = await prisma.pushToken.findFirst({
      where: { userId },
      orderBy: { updatedAt: "desc" },
    });
    if (!row) return undefined;
    return {
      userId: row.userId,
      voipToken: row.voipToken,
      environment: (row.environment === "production" ? "production" : "sandbox") as "sandbox" | "production",
      updatedAt: row.updatedAt.getTime(),
    };
  }

  async remove(token: string): Promise<void> {
    try {
      await prisma.pushToken.deleteMany({ where: { voipToken: token } });
    } catch (err) {
      logger.warn({ err }, "[push-tokens] remove failed");
    }
  }
}
