import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";

export type AlertPreviewMode = "sender_subject" | "sender" | "generic" | "none";
export type AlertPushToken = { token: string; environment: "sandbox" | "production"; previewMode: AlertPreviewMode; soundEnabled: boolean };

export class AlertPushTokenStore {
  private ready: Promise<void> | null = null;
  constructor(private readonly prisma: PrismaClient) {}

  ensureTable(): Promise<void> {
    this.ready ??= this.initializeTable().catch(error => { this.ready = null; throw error; });
    return this.ready;
  }

  private async initializeTable(): Promise<void> {
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AlertPushToken" (
      "id" TEXT NOT NULL PRIMARY KEY, "userId" TEXT NOT NULL, "token" TEXT NOT NULL UNIQUE, "environment" TEXT NOT NULL,
      "previewMode" TEXT NOT NULL DEFAULT 'sender_subject', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "soundEnabled" BOOLEAN NOT NULL DEFAULT true,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "AlertPushToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    const columns = await this.prisma.$queryRawUnsafe<Array<{name: string}>>(`PRAGMA table_info("AlertPushToken")`);
    if (!columns.some(column => column.name === "soundEnabled")) {
      await this.prisma.$executeRawUnsafe(`ALTER TABLE "AlertPushToken" ADD COLUMN "soundEnabled" BOOLEAN NOT NULL DEFAULT true`);
    }
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AlertPushToken_userId_updatedAt_idx" ON "AlertPushToken"("userId","updatedAt")`);
  }

  async set(userId: string, record: AlertPushToken): Promise<void> {
    if (!/^[0-9a-f]{32,200}$/i.test(record.token)) throw new Error("invalid_token_format");
    await this.ensureTable();
    await this.prisma.$executeRawUnsafe(`INSERT INTO "AlertPushToken" ("id","userId","token","environment","previewMode","soundEnabled","createdAt","updatedAt") VALUES (?,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT("token") DO UPDATE SET "userId"=excluded."userId", "environment"=excluded."environment", "previewMode"=excluded."previewMode", "soundEnabled"=excluded."soundEnabled", "updatedAt"=CURRENT_TIMESTAMP`, randomUUID(), userId, record.token.toLowerCase(), record.environment, record.previewMode, record.soundEnabled);
  }

  async forUser(userId: string): Promise<AlertPushToken[]> {
    await this.ensureTable();
    return this.prisma.$queryRawUnsafe<AlertPushToken[]>(`SELECT "token","environment","previewMode","soundEnabled" FROM "AlertPushToken" WHERE "userId"=? ORDER BY "updatedAt" DESC LIMIT 20`, userId);
  }

  async remove(token: string, userId?: string): Promise<void> {
    await this.ensureTable();
    if (userId) await this.prisma.$executeRawUnsafe(`DELETE FROM "AlertPushToken" WHERE "token"=? AND "userId"=?`, token.toLowerCase(), userId);
    else await this.prisma.$executeRawUnsafe(`DELETE FROM "AlertPushToken" WHERE "token"=?`, token.toLowerCase());
  }
}
