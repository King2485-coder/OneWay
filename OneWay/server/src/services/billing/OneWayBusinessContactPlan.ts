import type { PrismaClient } from "@prisma/client";
export const BUSINESS_CONTACT_PRODUCT_ID = "oneway.business_number.monthly";
export const BUSINESS_CONTACT_MONTHLY_USD = 5;
export const BUSINESS_CONTACT_PLAN = {name: "OneWay Business Number", productId: BUSINESS_CONTACT_PRODUCT_ID, monthlyPrice: BUSINESS_CONTACT_MONTHLY_USD, currency: "USD", includedPersonalNumbers: 1, includedBusinessNumbers: 1, includesBusinessEmail: true} as const;
export async function hasBusinessContactPlan(db: Pick<PrismaClient, "subscription">, userId: string): Promise<boolean> {
  const active = await db.subscription.findFirst({where: {userId, productId: BUSINESS_CONTACT_PRODUCT_ID, status: "active", expiresAt: {gt: new Date()}}, select: {id: true}});
  return Boolean(active);
}
