import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";

export type AlertPreviewMode = "sender_subject" | "sender" | "generic" | "none";
export type AlertPushToken = { token: string; environment: "sandbox" | "production"; previewMode: AlertPreviewMode };

export class AlertPushTokenStore {
  constructor(private readonly prisma: PrismaClient) {}

  async ensureTable(): Promise<void> {
    await this.prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AlertPushToken" (
      "id" TEXT NOT NULL PRIMARY KEY, "userId" TEXT NOT NULL, "token" TEXT NOT NULL UNIQUE, "environment" TEXT NOT NULL,
      "previewMode" TEXT NOT NULL DEFAULT 'sender_subject', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "AlertPushToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE
    )`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AlertPushToken_userId_updatedAt_idx" ON "AlertPushToken"("userId","updatedAt")`);
  }

  async set(userId: string, record: AlertPushToken): Promise<void> {
    if (!/^[0-9a-f]{32,200}$/i.test(record.token)) throw new Error("invalid_token_format");
    await this.ensureTable();
    await this.prisma.$executeRawUnsafe(`DELETE FROM "AlertPushToken" WHERE "token"=?`, record.token.toLowerCase());
    await this.prisma.$executeRawUnsafe(`INSERT INTO "AlertPushToken" ("id","userId","token","environment","previewMode") VALUES (?,?,?,?,?)`, randomUUID(), userId, record.token.toLowerCase(), record.environment, record.previewMode);
  }

  async forUser(userId: string): Promise<AlertPushToken[]> {
    await this.ensureTable();
    return this.prisma.$queryRawUnsafe<AlertPushToken[]>(`SELECT "token","environment","previewMode" FROM "AlertPushToken" WHERE "userId"=? ORDER BY "updatedAt" DESC LIMIT 20`, userId);
  }

  async remove(token: string): Promise<void> {
    await this.ensureTable();
    await this.prisma.$executeRawUnsafe(`DELETE FROM "AlertPushToken" WHERE "token"=?`, token.toLowerCase());
  }
}
