import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";

export type SellerBillingType = "ONE_TIME" | "MONTHLY" | "ANNUAL";
export type SellerPackageType = "PRODUCT_SLOT" | "PRODUCT_BUNDLE" | "UNLIMITED_PRODUCTS" | "SHOP_SLOT" | "SHOP_BUNDLE" | "SELLER_PRO";
export type SellerEntitlementType = "PRODUCT_SLOT" | "UNLIMITED_PRODUCTS" | "SHOP_SLOT" | "SELLER_PRO" | "ADVANCED_ANALYTICS" | "AI_LISTING_TOOLS" | "FEATURED_SEARCH_CREDITS" | "TRANSACTION_FEE_DISCOUNT";
export type SellerEntitlementSource = "FREE_ALLOWANCE" | "ONE_TIME_PURCHASE" | "SUBSCRIPTION" | "ADMIN_GRANT" | "PROMOTION" | "MIGRATION" | "REFUND_REVERSAL";
export type SellerEntitlementStatus = "PENDING" | "ACTIVE" | "EXPIRED" | "REVOKED" | "REFUNDED" | "PAYMENT_FAILED";

export type SellerPackageCatalogItem = {
  id: string;
  code: string;
  displayName: string;
  description: string;
  packageType: SellerPackageType;
  billingType: SellerBillingType;
  quantity: number | null;
  priceAmount: number;
  currency: string;
  active: boolean;
  sortOrder: number;
  externalProductId?: string | null;
  externalPriceId?: string | null;
  appStoreProductId?: string | null;
  metadata?: Record<string, unknown>;
};

export type SellerCapacitySummary = {
  freeShopSlots: number;
  purchasedShopSlots: number;
  subscriptionShopSlots: number;
  totalShopCapacity: number;
  usedShopSlots: number;
  availableShopSlots: number;
  nextShopSlotPrice: number;
  freeProductSlots: number;
  purchasedProductSlots: number;
  subscriptionProductSlots: number;
  totalProductCapacity: number | null;
  activeProductCount: number;
  availableProductSlots: number | null;
  hasUnlimitedProducts: boolean;
  sellerProStatus: "inactive" | "active" | "canceled" | "expired";
  sellerProRenewsAt: string | null;
  sellerProEndsAt: string | null;
  isOverShopCapacity: boolean;
  isOverProductCapacity: boolean;
};

export const sellerPackageCatalog: SellerPackageCatalogItem[] = [
  { id: "pkg_product_1", code: "PRODUCT_SLOT_1", displayName: "+1 product slot", description: "Adds one permanent active product listing slot.", packageType: "PRODUCT_SLOT", billingType: "ONE_TIME", quantity: 1, priceAmount: 0.99, currency: "USD", active: true, sortOrder: 10, appStoreProductId: "oneway.seller.product_slot_1" },
  { id: "pkg_product_10", code: "PRODUCT_BUNDLE_10", displayName: "+10 product slots", description: "Adds ten permanent active product listing slots.", packageType: "PRODUCT_BUNDLE", billingType: "ONE_TIME", quantity: 10, priceAmount: 5, currency: "USD", active: true, sortOrder: 20, appStoreProductId: "oneway.seller.product_slots_10" },
  { id: "pkg_product_25", code: "PRODUCT_BUNDLE_25", displayName: "+25 product slots", description: "Adds twenty-five permanent active product listing slots.", packageType: "PRODUCT_BUNDLE", billingType: "ONE_TIME", quantity: 25, priceAmount: 10, currency: "USD", active: true, sortOrder: 30, appStoreProductId: "oneway.seller.product_slots_25" },
  { id: "pkg_product_50", code: "PRODUCT_BUNDLE_50", displayName: "+50 product slots", description: "Adds fifty permanent active product listing slots.", packageType: "PRODUCT_BUNDLE", billingType: "ONE_TIME", quantity: 50, priceAmount: 18, currency: "USD", active: true, sortOrder: 40, appStoreProductId: "oneway.seller.product_slots_50" },
  { id: "pkg_product_100", code: "PRODUCT_BUNDLE_100", displayName: "+100 product slots", description: "Adds one hundred permanent active product listing slots.", packageType: "PRODUCT_BUNDLE", billingType: "ONE_TIME", quantity: 100, priceAmount: 30, currency: "USD", active: true, sortOrder: 50, appStoreProductId: "oneway.seller.product_slots_100" },
  { id: "pkg_product_unlimited", code: "UNLIMITED_PRODUCTS", displayName: "Unlimited product listings", description: "Unlocks unlimited active product listings permanently.", packageType: "UNLIMITED_PRODUCTS", billingType: "ONE_TIME", quantity: null, priceAmount: 99, currency: "USD", active: true, sortOrder: 60, appStoreProductId: "oneway.seller.unlimited_products" },
  { id: "pkg_product_10_monthly", code: "PRODUCT_BUNDLE_10_MONTHLY", displayName: "+10 product slots monthly", description: "Adds ten active listing slots while subscription is active.", packageType: "PRODUCT_BUNDLE", billingType: "MONTHLY", quantity: 10, priceAmount: 0.99, currency: "USD", active: true, sortOrder: 70, appStoreProductId: "oneway.seller.product_slots_10_monthly" },
  { id: "pkg_product_25_monthly", code: "PRODUCT_BUNDLE_25_MONTHLY", displayName: "+25 product slots monthly", description: "Adds twenty-five active listing slots while subscription is active.", packageType: "PRODUCT_BUNDLE", billingType: "MONTHLY", quantity: 25, priceAmount: 1.99, currency: "USD", active: true, sortOrder: 80, appStoreProductId: "oneway.seller.product_slots_25_monthly" },
  { id: "pkg_product_50_monthly", code: "PRODUCT_BUNDLE_50_MONTHLY", displayName: "+50 product slots monthly", description: "Adds fifty active listing slots while subscription is active.", packageType: "PRODUCT_BUNDLE", billingType: "MONTHLY", quantity: 50, priceAmount: 2.99, currency: "USD", active: true, sortOrder: 90, appStoreProductId: "oneway.seller.product_slots_50_monthly" },
  { id: "pkg_shop_next", code: "SHOP_SLOT_NEXT", displayName: "Next Shop slot", description: "Unlocks the next permanent Shop slot. Price is calculated from current capacity.", packageType: "SHOP_SLOT", billingType: "ONE_TIME", quantity: 1, priceAmount: 1, currency: "USD", active: true, sortOrder: 100, appStoreProductId: "oneway.seller.shop_slot_next" },
  { id: "pkg_shop_3", code: "SHOP_BUNDLE_3", displayName: "3 additional Shop slots", description: "Adds three permanent Shop slots.", packageType: "SHOP_BUNDLE", billingType: "ONE_TIME", quantity: 3, priceAmount: 7, currency: "USD", active: true, sortOrder: 110, appStoreProductId: "oneway.seller.shop_slots_3" },
  { id: "pkg_shop_5", code: "SHOP_BUNDLE_5", displayName: "5 additional Shop slots", description: "Adds five permanent Shop slots.", packageType: "SHOP_BUNDLE", billingType: "ONE_TIME", quantity: 5, priceAmount: 12, currency: "USD", active: true, sortOrder: 120, appStoreProductId: "oneway.seller.shop_slots_5" },
  { id: "pkg_shop_10", code: "SHOP_BUNDLE_10", displayName: "10 additional Shop slots", description: "Adds ten permanent Shop slots.", packageType: "SHOP_BUNDLE", billingType: "ONE_TIME", quantity: 10, priceAmount: 20, currency: "USD", active: true, sortOrder: 130, appStoreProductId: "oneway.seller.shop_slots_10" },
  { id: "pkg_seller_pro", code: "SELLER_PRO_MONTHLY", displayName: "Seller Pro", description: "Unlimited product listings, up to 10 Shops, advanced analytics, future AI listing tools, and priority seller support when available.", packageType: "SELLER_PRO", billingType: "MONTHLY", quantity: 1, priceAmount: 14.99, currency: "USD", active: true, sortOrder: 140, appStoreProductId: "oneway.seller.pro.monthly", metadata: { advancedAnalytics: true, aiToolsFuture: true, searchBoostFuture: true, prioritySupportFuture: true } },
];

export function nextShopSlotPrice(totalShopCapacity: number): number {
  if (totalShopCapacity < 4) return 1;
  return 3;
}

export async function ensureSellerMonetizationTables(prisma: PrismaClient): Promise<void> {
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "SellerEntitlement" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "entitlementType" TEXT NOT NULL,
      "sourceType" TEXT NOT NULL,
      "sourceReferenceId" TEXT,
      "quantity" INTEGER NOT NULL DEFAULT 0,
      "startsAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "expiresAt" DATETIME,
      "status" TEXT NOT NULL DEFAULT 'ACTIVE',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SellerEntitlement_user_status_idx" ON "SellerEntitlement" ("userId", "status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SellerEntitlement_type_idx" ON "SellerEntitlement" ("entitlementType")`);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "SellerPlanTransaction" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "packageId" TEXT NOT NULL,
      "transactionType" TEXT NOT NULL,
      "billingProvider" TEXT NOT NULL,
      "providerTransactionId" TEXT,
      "providerCustomerId" TEXT,
      "idempotencyKey" TEXT NOT NULL,
      "amount" REAL NOT NULL,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "paymentStatus" TEXT NOT NULL DEFAULT 'CREATED',
      "entitlementStatus" TEXT NOT NULL DEFAULT 'PENDING',
      "refundedAmount" REAL NOT NULL DEFAULT 0,
      "purchasedAt" DATETIME,
      "effectiveAt" DATETIME,
      "expiresAt" DATETIME,
      "metadata" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "SellerPlanTransaction_idempotency_idx" ON "SellerPlanTransaction" ("idempotencyKey")`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "SellerPlanTransaction_provider_idx" ON "SellerPlanTransaction" ("providerTransactionId") WHERE "providerTransactionId" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SellerPlanTransaction_user_idx" ON "SellerPlanTransaction" ("userId", "createdAt")`);
}

export async function ensureFreeSellerEntitlements(prisma: PrismaClient, userId: string): Promise<void> {
  await ensureSellerMonetizationTables(prisma);
  await grantEntitlementIfMissing(prisma, userId, "SHOP_SLOT", "FREE_ALLOWANCE", "free-shop-slot", 1);
  await grantEntitlementIfMissing(prisma, userId, "PRODUCT_SLOT", "FREE_ALLOWANCE", "free-product-slots", 10);
}

export async function grantEntitlementIfMissing(
  prisma: PrismaClient,
  userId: string,
  entitlementType: SellerEntitlementType,
  sourceType: SellerEntitlementSource,
  sourceReferenceId: string,
  quantity: number
): Promise<void> {
  const existing = await prisma.$queryRaw<Array<{ id: string }>>`
    SELECT "id" FROM "SellerEntitlement"
    WHERE "userId" = ${userId} AND "entitlementType" = ${entitlementType} AND "sourceType" = ${sourceType} AND "sourceReferenceId" = ${sourceReferenceId}
    LIMIT 1
  `;
  if (existing.length > 0) return;
  await prisma.$executeRaw`
    INSERT INTO "SellerEntitlement" ("id", "userId", "entitlementType", "sourceType", "sourceReferenceId", "quantity", "status")
    VALUES (${randomUUID()}, ${userId}, ${entitlementType}, ${sourceType}, ${sourceReferenceId}, ${quantity}, 'ACTIVE')
  `;
}

export async function sellerCapacitySummary(prisma: PrismaClient, userId: string): Promise<SellerCapacitySummary> {
  await ensureFreeSellerEntitlements(prisma, userId);
  const entitlements = await prisma.$queryRaw<Array<{ entitlementType: string; sourceType: string; quantity: number; expiresAt: Date | null; status: string }>>`
    SELECT "entitlementType", "sourceType", "quantity", "expiresAt", "status"
    FROM "SellerEntitlement"
    WHERE "userId" = ${userId} AND "status" = 'ACTIVE' AND ("expiresAt" IS NULL OR "expiresAt" > CURRENT_TIMESTAMP)
  `;
  const stores = await prisma.storefront.findMany({
    where: { ownerId: userId, status: { not: "archived" } as any },
    include: { products: true },
  });
  const usedShopSlots = stores.length;
  const activeProductCount = stores.reduce((sum, store) => {
    return sum + store.products.filter((product) => {
      const status = String((product as any).status ?? (product.published ? "active" : "draft"));
      return status === "active" || status === "paused" || product.published;
    }).length;
  }, 0);
  const sellerPro = entitlements.some((item) => item.entitlementType === "SELLER_PRO");
  const freeShopSlots = sum(entitlements, "SHOP_SLOT", "FREE_ALLOWANCE");
  const purchasedShopSlots = sum(entitlements, "SHOP_SLOT", "ONE_TIME_PURCHASE") + sum(entitlements, "SHOP_SLOT", "MIGRATION") + sum(entitlements, "SHOP_SLOT", "ADMIN_GRANT");
  const subscriptionShopSlots = sellerPro ? Math.max(0, 10 - freeShopSlots - purchasedShopSlots) : sum(entitlements, "SHOP_SLOT", "SUBSCRIPTION");
  const totalShopCapacity = freeShopSlots + purchasedShopSlots + subscriptionShopSlots;
  const freeProductSlots = sum(entitlements, "PRODUCT_SLOT", "FREE_ALLOWANCE");
  const purchasedProductSlots = sum(entitlements, "PRODUCT_SLOT", "ONE_TIME_PURCHASE") + sum(entitlements, "PRODUCT_SLOT", "MIGRATION") + sum(entitlements, "PRODUCT_SLOT", "ADMIN_GRANT");
  const subscriptionProductSlots = sellerPro ? 0 : sum(entitlements, "PRODUCT_SLOT", "SUBSCRIPTION");
  const hasUnlimitedProducts = sellerPro || entitlements.some((item) => item.entitlementType === "UNLIMITED_PRODUCTS");
  const numericProductCapacity = freeProductSlots + purchasedProductSlots + subscriptionProductSlots;
  return {
    freeShopSlots,
    purchasedShopSlots,
    subscriptionShopSlots,
    totalShopCapacity,
    usedShopSlots,
    availableShopSlots: Math.max(0, totalShopCapacity - usedShopSlots),
    nextShopSlotPrice: nextShopSlotPrice(totalShopCapacity),
    freeProductSlots,
    purchasedProductSlots,
    subscriptionProductSlots,
    totalProductCapacity: hasUnlimitedProducts ? null : numericProductCapacity,
    activeProductCount,
    availableProductSlots: hasUnlimitedProducts ? null : Math.max(0, numericProductCapacity - activeProductCount),
    hasUnlimitedProducts,
    sellerProStatus: sellerPro ? "active" : "inactive",
    sellerProRenewsAt: null,
    sellerProEndsAt: null,
    isOverShopCapacity: usedShopSlots > totalShopCapacity,
    isOverProductCapacity: !hasUnlimitedProducts && activeProductCount > numericProductCapacity,
  };
}

function sum(rows: Array<{ entitlementType: string; sourceType: string; quantity: number }>, type: string, source: string): number {
  return rows.filter((row) => row.entitlementType === type && row.sourceType === source).reduce((total, row) => total + Number(row.quantity || 0), 0);
}

export function packageAmountForSeller(packageCode: string, summary: SellerCapacitySummary): number | null {
  if (packageCode === "SHOP_SLOT_NEXT") return summary.nextShopSlotPrice;
  return sellerPackageCatalog.find((item) => item.code === packageCode && item.active)?.priceAmount ?? null;
}

export function entitlementForPackage(item: SellerPackageCatalogItem): { type: SellerEntitlementType; quantity: number } {
  switch (item.packageType) {
  case "SHOP_SLOT":
  case "SHOP_BUNDLE":
    return { type: "SHOP_SLOT", quantity: item.quantity ?? 1 };
  case "UNLIMITED_PRODUCTS":
    return { type: "UNLIMITED_PRODUCTS", quantity: 1 };
  case "SELLER_PRO":
    return { type: "SELLER_PRO", quantity: 1 };
  case "PRODUCT_SLOT":
  case "PRODUCT_BUNDLE":
  default:
    return { type: "PRODUCT_SLOT", quantity: item.quantity ?? 1 };
  }
}
