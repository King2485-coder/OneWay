import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";
export const contactDisplayKey = "social.profile.contact";
export async function contactOptions(db: PrismaClient, owner: string) {
  const [identity, user, numbers] = await Promise.all([
    db.oneWayIdentity.findUnique({where: {userId: owner}}),
    db.user.findUnique({where: {id: owner}, select: {chirpId: true}}),
    db.userNumber.findMany({where: {userId: owner}, orderBy: [{isPrimary: "desc"},{createdAt: "asc"}]})
  ]);
  const result: {key: string; label: string; value: string | null}[] = [{key: "none", label: "Nothing", value: null}];
  if (identity?.onewayId) result.push({key: "onewayId", label: "OneWay handle", value: identity.onewayId});
  if (user?.chirpId) result.push({key: "chirpId", label: "Chirp ID", value: user.chirpId});
  if (identity?.emailAlias) result.push({key: "emailAlias", label: "OneWay email", value: identity.emailAlias});
  for (const number of numbers) result.push({key: `number:${number.id}`, label: "OneWay phone number", value: number.number});
  return result;
}
export async function selectedContact(db: PrismaClient, owner: string) {
  const rows = await db.$queryRawUnsafe<{value: string}[]>(`SELECT "value" FROM "PrivacySetting" WHERE "userId"=? AND "key"=? LIMIT 1`, owner, contactDisplayKey);
  const choice = (await contactOptions(db, owner)).find(o => o.key === rows[0]?.value);
  return choice && choice.key !== "none" ? {kind: choice.key.split(":")[0], label: choice.label, value: choice.value} : null;
}
export async function saveContactChoice(db: PrismaClient, owner: string, choice: string) {
  await db.$executeRawUnsafe(`INSERT INTO "PrivacySetting" ("id","userId","key","value","updatedAt") VALUES (?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT("userId","key") DO UPDATE SET "value"=excluded."value","updatedAt"=CURRENT_TIMESTAMP`, randomUUID(), owner, contactDisplayKey, choice);
}
