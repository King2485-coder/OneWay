import { createHash, randomInt } from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { logger } from "../../lib/logger";
import { emailProvider } from "../email/createEmailProvider";
import { normalizeOneWayId } from "../identity";

const ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const MAX_ATTEMPTS = 5;
const TTL_MS = 15 * 60_000;

export async function ensurePasswordResetSchema(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "PasswordResetToken" (
    "id" TEXT NOT NULL PRIMARY KEY, "userId" TEXT NOT NULL, "codeHash" TEXT NOT NULL,
    "expiresAt" DATETIME NOT NULL, "consumedAt" DATETIME, "attempts" INTEGER NOT NULL DEFAULT 0,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "PasswordResetToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE)`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "PasswordResetToken_codeHash_key" ON "PasswordResetToken"("codeHash")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "PasswordResetToken_userId_createdAt_idx" ON "PasswordResetToken"("userId", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "PasswordResetToken_expiresAt_idx" ON "PasswordResetToken"("expiresAt")`);
  const columns = await prisma.$queryRawUnsafe<Array<{ name?: string }>>(`PRAGMA table_info("User")`);
  if (!columns.some((column) => column.name === "passwordChangedAt")) {
    await prisma.$executeRawUnsafe(`ALTER TABLE "User" ADD COLUMN "passwordChangedAt" DATETIME`);
  }
}

export async function resolvePasswordUser(prisma: PrismaClient, raw: string) {
  const identifier = raw.trim();
  const emailLike = identifier.includes("@") && identifier.includes(".");
  const byEmail = emailLike ? await prisma.user.findUnique({ where: { email: identifier.toLowerCase() } }) : null;
  const byId = identifier.startsWith("@") ? await prisma.oneWayIdentity.findUnique({ where: { onewayId: normalizeOneWayId(identifier) }, select: { userId: true } }) : null;
  const byUsername = !identifier.startsWith("@") && !emailLike ? await prisma.oneWayIdentity.findFirst({ where: { username: identifier }, select: { userId: true } }) : null;
  const userId = byEmail?.id ?? byId?.userId ?? byUsername?.userId;
  return userId ? prisma.user.findUnique({ where: { id: userId } }) : null;
}

export async function issuePasswordReset(prisma: PrismaClient, identifier: string): Promise<void> {
  const user = await resolvePasswordUser(prisma, identifier);
  if (!user?.email || user.accountStatus !== "active") return;
  const code = Array.from({ length: 8 }, () => ALPHABET[randomInt(ALPHABET.length)]).join("");
  const now = new Date();
  await prisma.$transaction([
    prisma.passwordResetToken.updateMany({ where: { userId: user.id, consumedAt: null }, data: { consumedAt: now } }),
    prisma.passwordResetToken.create({ data: { userId: user.id, codeHash: hash(user.id, code), expiresAt: new Date(now.getTime() + TTL_MS) } }),
  ]);
  const result = await emailProvider.sendOutboundMessage({
    fromUserId: "system:password-reset", toEmail: user.email, subject: "Your OneWay password reset code",
    body: `Your OneWay password reset code is ${code}.\n\nIt expires in 15 minutes. If you didn't request this, you can ignore this email.`,
    htmlBody: `<p>Your OneWay password reset code is:</p><p style="font-size:28px;font-weight:700;letter-spacing:3px">${code}</p><p>It expires in 15 minutes. If you didn't request this, you can ignore this email.</p>`,
  });
  if (result.status === "failed") logger.error({ userId: user.id, provider: result.provider }, "[auth] password reset email delivery failed");
}

export async function consumePasswordReset(prisma: PrismaClient, userId: string, code: string, passwordHash: string): Promise<boolean> {
  const now = new Date();
  const token = await prisma.passwordResetToken.findFirst({ where: { userId, codeHash: hash(userId, normalize(code)), consumedAt: null, expiresAt: { gt: now }, attempts: { lt: MAX_ATTEMPTS } }, orderBy: { createdAt: "desc" } });
  if (!token) {
    await prisma.passwordResetToken.updateMany({ where: { userId, consumedAt: null, expiresAt: { gt: now }, attempts: { lt: MAX_ATTEMPTS } }, data: { attempts: { increment: 1 } } });
    return false;
  }
  await prisma.$transaction([
    prisma.user.update({ where: { id: userId }, data: { passwordHash, passwordChangedAt: now } }),
    prisma.passwordResetToken.updateMany({ where: { userId, consumedAt: null }, data: { consumedAt: now } }),
  ]);
  return true;
}

function normalize(value: string): string { return value.replace(/[\s-]/g, "").toUpperCase(); }
function hash(userId: string, code: string): string { return createHash("sha256").update(`${process.env.JWT_SECRET ?? ""}:${userId}:${code}`).digest("hex"); }
