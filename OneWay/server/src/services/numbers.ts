import { prisma } from "../lib/db";
import type { PrismaClient } from "@prisma/client";
import { hasBusinessContactPlan } from "./billing/OneWayBusinessContactPlan";
import { loadPublicIdentity } from "./identity";

export const EXTRA_NUMBERS_PRODUCT_ID = "oneway.extra_numbers.monthly";

export interface CallerIdentity {
  callerName: string;
  callerNumber: string;
  callerDisplay: string;
}

export async function generateUniqueOneWayNumber(db: Pick<PrismaClient, "userNumber"> = prisma): Promise<string> {
  while (true) {
    const number = `OW-${Math.floor(100000 + Math.random() * 900000)}`;
    const existing = await db.userNumber.findUnique({
      where: { number },
      select: { id: true },
    });
    if (!existing) {
      return number;
    }
  }
}

export async function assignInitialFreeNumbers(userId: string, _legacyTargetCount = 1, db: PrismaClient = prisma): Promise<void> {
  // Serialized allocation is idempotent; existing legacy free numbers are preserved.
  await db.$transaction(async tx => {
    const existing = await tx.userNumber.count({where: {userId, isPaid: false}});
    if (existing) return;
    const total = await tx.userNumber.count({where: {userId}});
    const number = await generateUniqueOneWayNumber(tx);
    await tx.userNumber.create({data: {userId, number, label: "Personal", isPrimary: total === 0, isPaid: false}});
  });
}
export async function assignInitialNumber(userId: string): Promise<void> { await assignInitialFreeNumbers(userId); }
export async function userHasExtraNumberSubscription(userId: string): Promise<boolean> { return hasBusinessContactPlan(prisma, userId); }

export class NumberAllocationError extends Error { constructor(public code: string, public status: number) { super(code); } }
export async function allocateInternalNumber(db: PrismaClient, userId: string, label?: string) {
  return db.$transaction(async tx => {
    const freeCount = await tx.userNumber.count({where: {userId,isPaid:false}});
    const total = await tx.userNumber.count({where:{userId}});
    const business = freeCount >= 1;
    if (business) {
      if (!await hasBusinessContactPlan(tx,userId)) throw new NumberAllocationError("subscription_required",402);
      if (await tx.userNumber.count({where:{userId,isPaid:true,number:{startsWith:"OW-"}}})) throw new NumberAllocationError("business_number_already_owned",409);
    }
    const number = await generateUniqueOneWayNumber(tx);
    return tx.userNumber.create({data:{userId,number,label:business ? "OneWay Business Number" : "Personal",isPaid:business,isPrimary:total===0}});
  });
}

export async function loadCallerIdentity(userId: string): Promise<CallerIdentity> {
  const [identity, user] = await Promise.all([
    loadPublicIdentity(userId),
    prisma.user.findUnique({
    where: { id: userId },
    select: {
      numbers: {
        where: { isPrimary: true },
        orderBy: { createdAt: "asc" },
        take: 1,
        select: { number: true },
      },
    },
  }),
  ]);

  const primaryNumber = user?.numbers[0]?.number ?? userId;
  const preferredIdentity =
    identity.preferredCallerIdentity == "number" && primaryNumber
      ? primaryNumber
      : identity.onewayId || primaryNumber;

  return {
    callerName: identity.displayName,
    callerNumber: preferredIdentity,
    callerDisplay: ["OneWay", identity.displayName, preferredIdentity].join("\n"),
  };
}
