import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { resolveOneWayProduct } from "./OneWayProductRegistry";
import { ensureServiceOrderTables } from "./ServiceOrderTables";

export type EntitlementGrant = {
  userId: string;
  entitlementKey: string;
  sourceOrderId: string;
  productId: string;
  stripeCustomerId?: string | null;
  stripeSubscriptionId?: string | null;
  stripePriceId?: string | null;
};

export async function grantEntitlement(prisma: PrismaClient, input: EntitlementGrant): Promise<void> {
  await ensureServiceOrderTables(prisma);
  const product = resolveOneWayProduct(input.productId);
  if (!product || product.entitlementKey !== input.entitlementKey) throw new Error("invalid_entitlement_product");
  const quantity = product.capacityDelta ?? product.shopDelta ?? 1;
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "BillingEntitlement" (
      "id", "userId", "entitlementKey", "sourceOrderId", "productId", "status", "quantity",
      "stripeCustomerId", "stripeSubscriptionId", "stripePriceId"
    ) VALUES (?, ?, ?, ?, ?, 'ACTIVE', ?, ?, ?, ?)`,
    crypto.randomUUID(), input.userId, input.entitlementKey, input.sourceOrderId, input.productId, quantity,
    input.stripeCustomerId ?? null, input.stripeSubscriptionId ?? null, input.stripePriceId ?? null,
  );
}

export async function revokeOrderEntitlements(prisma: PrismaClient, sourceOrderId: string): Promise<void> {
  await ensureServiceOrderTables(prisma);
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingEntitlement" SET "status" = 'REVOKED', "revokedAt" = CURRENT_TIMESTAMP,
      "updatedAt" = CURRENT_TIMESTAMP WHERE "sourceOrderId" = ? AND "status" = 'ACTIVE'`,
    sourceOrderId,
  );
}

export async function capacityForUser(prisma: PrismaClient, userId: string) {
  await ensureServiceOrderTables(prisma);
  const rows = await prisma.$queryRawUnsafe<Array<{ productSlots: number | bigint; shops: number | bigint }>>(
    `SELECT
      COALESCE(SUM(CASE WHEN "entitlementKey" LIKE 'shop.product_slots.%' THEN "quantity" ELSE 0 END), 0) AS "productSlots",
      COALESCE(SUM(CASE WHEN "entitlementKey" = 'shop.additional' THEN "quantity" ELSE 0 END), 0) AS "shops"
     FROM "BillingEntitlement" WHERE "userId" = ? AND "status" = 'ACTIVE'`,
    userId,
  );
  return {
    baseProductCapacity: 12,
    purchasedProductCapacity: Number(rows[0]?.productSlots ?? 0),
    productCapacity: 12 + Number(rows[0]?.productSlots ?? 0),
    baseShops: 1,
    purchasedShops: Number(rows[0]?.shops ?? 0),
    shopCapacity: 1 + Number(rows[0]?.shops ?? 0),
  };
}
