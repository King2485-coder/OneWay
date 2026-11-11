import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";
const canonical = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value) ? value.toLowerCase() : value;
export const ghostKey = "account.ghostMode";
export async function ghostMode(db: PrismaClient, userId: string): Promise<boolean> {
  userId = canonical(userId);
  const rows = await db.$queryRawUnsafe<{value: string}[]>(`SELECT "value" FROM "PrivacySetting" WHERE "userId" = ? AND "key" = ? LIMIT 1`, userId, ghostKey);
  return rows[0]?.value === "true";
}
export async function ghostUsers(db: PrismaClient): Promise<string[]> {
  const rows = await db.$queryRawUnsafe<{userId: string}[]>(`SELECT "userId" FROM "PrivacySetting" WHERE "key" = ? AND "value" = 'true'`, ghostKey);
  return rows.map(r => r.userId);
}
export async function setGhostMode(db: PrismaClient, userId: string, enabled: boolean) {
  userId = canonical(userId);
  await db.$executeRawUnsafe(`INSERT INTO "PrivacySetting" ("id","userId","key","value","updatedAt") VALUES (?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT("userId","key") DO UPDATE SET "value"=excluded."value","updatedAt"=CURRENT_TIMESTAMP`, randomUUID(), userId, ghostKey, String(enabled));
}
export async function approvedContacts(db: PrismaClient, userId: string): Promise<string[]> {
  userId = canonical(userId);
  const rows = await db.oneWayContact.findMany({where: {userId, status: "connected"}, select: {contactUserId: true}});
  const reverse = await db.oneWayContact.findMany({where: {contactUserId: userId, status: "connected", userId: {in: rows.map(r => r.contactUserId)}}, select: {userId: true}});
  return reverse.map(r => r.userId);
}
export async function mayCommunicate(db: PrismaClient, sender: string, recipient: string): Promise<boolean> {
  sender = canonical(sender); recipient = canonical(recipient);
  try {
  const blocked = await db.oneWayContact.findFirst({where: {status: "blocked", OR: [{userId: sender, contactUserId: recipient}, {userId: recipient, contactUserId: sender}]}, select: {id: true}});
  if (blocked) return false;
  if (!await ghostMode(db, sender) && !await ghostMode(db, recipient)) return true;
  return (await approvedContacts(db, recipient)).includes(sender);
  } catch { return false; } // Privacy storage unavailable: never authorize a new call or message.
}
/** Exact knowledge permits a request, never reveals other identifiers or grants approval. */
export function matchesExactContact(query: string, user: {chirpId?: string | null; chirpIdNormalized?: string | null; identity?: {onewayId?: string | null; emailAlias?: string | null} | null; numbers?: {number: string}[]}): boolean {
  const q = query.trim().toLowerCase(); const bare = q.replace(/^@/, "");
  if (user.identity?.onewayId?.toLowerCase().replace(/^@/, "") === bare) return true;
  if ([user.chirpId, user.chirpIdNormalized, user.identity?.emailAlias].some(v => v && v.toLowerCase() === q)) return true;
  const normalizePhone = (v: string) => { const digits = v.replace(/[^0-9]/g, ""); return digits.length === 10 ? "1" + digits : digits; };
  const phone = normalizePhone(q);
  return phone.length >= 10 && Boolean(user.numbers?.some(n => normalizePhone(n.number) === phone));
}
