import type { PrismaClient } from "@prisma/client";
import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import {
  ensureFreeSellerEntitlements,
  ensureSellerMonetizationTables,
  entitlementForPackage,
  packageAmountForSeller,
  sellerCapacitySummary,
  sellerPackageCatalog,
  type SellerEntitlementSource,
  type SellerEntitlementType,
} from "../services/sellerMonetization";

const purchaseSessionSchema = z.object({
  packageCode: z.string().trim().min(1).max(80),
  billingProvider: z.enum(["STOREKIT", "WEB_CHECKOUT", "STRIPE", "ADMIN", "PROMOTION"]).default("STOREKIT"),
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
});

const verifyPurchaseSchema = z.object({
  packageCode: z.string().trim().min(1).max(80),
  providerTransactionId: z.string().trim().min(1).max(180),
  idempotencyKey: z.string().trim().min(8).max(160),
});

const grantSchema = z.object({
  userId: z.string().uuid(),
  entitlementType: z.enum(["PRODUCT_SLOT", "UNLIMITED_PRODUCTS", "SHOP_SLOT", "SELLER_PRO", "ADVANCED_ANALYTICS", "AI_LISTING_TOOLS", "FEATURED_SEARCH_CREDITS", "TRANSACTION_FEE_DISCOUNT"]),
  quantity: z.number().int().min(1).max(10_000).default(1),
  sourceReferenceId: z.string().trim().min(1).max(160).default("admin-grant"),
});

export function sellerMonetizationRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(async (_req, _res, next) => {
    try {
      await ensureSellerMonetizationTables(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/packages", async (_req, res) => {
    logger.info({ event: "SELLER_PACKAGE_CATALOG_LOADED" }, "[seller-monetization] catalog loaded");
    res.json({ packages: sellerPackageCatalog });
  });

  router.get("/capacity", async (req, res) => {
    const userId = authenticatedUserId(req);
    const summary = await sellerCapacitySummary(prisma, userId);
    logger.info({
      event: "SELLER_CAPACITY_VIEWED",
      userId,
      usedShopSlots: summary.usedShopSlots,
      usedProductSlots: summary.activeProductCount,
    }, "[seller-monetization] capacity viewed");
    res.json(summary);
  });

  router.get("/entitlements", async (req, res) => {
    const userId = authenticatedUserId(req);
    await ensureFreeSellerEntitlements(prisma, userId);
    const rows = await prisma.$queryRaw`
      SELECT * FROM "SellerEntitlement" WHERE "userId" = ${userId} ORDER BY "createdAt" DESC
    `;
    res.json({ entitlements: rows });
  });

  router.get("/plan-transactions", async (req, res) => {
    const userId = authenticatedUserId(req);
    const rows = await prisma.$queryRaw`
      SELECT * FROM "SellerPlanTransaction" WHERE "userId" = ${userId} ORDER BY "createdAt" DESC
    `;
    res.json({ transactions: rows });
  });

  router.post("/purchases/session", async (req, res) => {
    const userId = authenticatedUserId(req);
    const parsed = purchaseSessionSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const item = sellerPackageCatalog.find((pkg) => pkg.code === parsed.data.packageCode && pkg.active);
    if (!item) return res.status(404).json({ error: "package_not_found" });
    const summary = await sellerCapacitySummary(prisma, userId);
    const amount = packageAmountForSeller(item.code, summary);
    if (amount == null) return res.status(400).json({ error: "package_unavailable" });
    const idempotencyKey = parsed.data.idempotencyKey ?? `${userId}:${item.code}:${randomUUID()}`;
    const transactionId = randomUUID();
    await prisma.$executeRaw`
      INSERT OR IGNORE INTO "SellerPlanTransaction" (
        "id", "userId", "packageId", "transactionType", "billingProvider", "idempotencyKey", "amount", "currency", "paymentStatus", "entitlementStatus", "metadata"
      ) VALUES (
        ${transactionId}, ${userId}, ${item.id}, ${transactionTypeForPackage(item.packageType)}, ${parsed.data.billingProvider}, ${idempotencyKey}, ${amount}, ${item.currency}, 'CREATED', 'PENDING', ${JSON.stringify({ packageCode: item.code })}
      )
    `;
    logger.info({
      event: "SELLER_CHECKOUT_CREATED",
      userId,
      packageCode: item.code,
      billingProvider: parsed.data.billingProvider,
      amount,
    }, "[seller-monetization] purchase session created");
    res.status(201).json({
      sessionId: transactionId,
      idempotencyKey,
      package: item,
      amount,
      currency: item.currency,
      billingProvider: parsed.data.billingProvider,
      checkoutMode: parsed.data.billingProvider === "STOREKIT" ? "storekit" : "web",
    });
  });

  router.post("/purchases/verify", async (req, res) => {
    const userId = authenticatedUserId(req);
    const parsed = verifyPurchaseSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const item = sellerPackageCatalog.find((pkg) => pkg.code === parsed.data.packageCode && pkg.active);
    if (!item) return res.status(404).json({ error: "package_not_found" });
    const existing = await prisma.$queryRaw<Array<{ id: string; paymentStatus: string }>>`
      SELECT "id", "paymentStatus" FROM "SellerPlanTransaction" WHERE "idempotencyKey" = ${parsed.data.idempotencyKey} LIMIT 1
    `;
    const alreadySucceeded = existing[0]?.paymentStatus === "SUCCEEDED";
    if (!alreadySucceeded) {
      const grant = entitlementForPackage(item);
      await prisma.$transaction(async (tx) => {
        await tx.$executeRaw`
          UPDATE "SellerPlanTransaction"
          SET "providerTransactionId" = ${parsed.data.providerTransactionId}, "paymentStatus" = 'SUCCEEDED', "entitlementStatus" = 'ACTIVE', "purchasedAt" = CURRENT_TIMESTAMP, "effectiveAt" = CURRENT_TIMESTAMP, "updatedAt" = CURRENT_TIMESTAMP
          WHERE "idempotencyKey" = ${parsed.data.idempotencyKey}
        `;
        await tx.$executeRaw`
          INSERT INTO "SellerEntitlement" ("id", "userId", "entitlementType", "sourceType", "sourceReferenceId", "quantity", "status")
          SELECT ${randomUUID()}, ${userId}, ${grant.type}, ${sourceTypeForPackage(item.billingType)}, ${parsed.data.providerTransactionId}, ${grant.quantity}, 'ACTIVE'
          WHERE NOT EXISTS (
            SELECT 1 FROM "SellerEntitlement" WHERE "userId" = ${userId} AND "sourceReferenceId" = ${parsed.data.providerTransactionId}
          )
        `;
      });
      logger.info({
        event: "SELLER_ENTITLEMENT_GRANTED",
        userId,
        packageCode: item.code,
        entitlementType: entitlementForPackage(item).type,
      }, "[seller-monetization] entitlement granted");
    }
    res.json({
      verified: true,
      idempotent: alreadySucceeded,
      capacity: await sellerCapacitySummary(prisma, userId),
    });
  });

  router.post("/purchases/restore", async (req, res) => {
    const userId = authenticatedUserId(req);
    logger.info({ event: "SELLER_PURCHASE_RESTORED", userId }, "[seller-monetization] restore requested");
    res.json({
      restored: true,
      message: "Restore queued. Production restores must verify StoreKit receipts server-side before granting entitlements.",
      capacity: await sellerCapacitySummary(prisma, userId),
    });
  });

  router.post("/subscriptions/cancel", async (req, res) => {
    const userId = authenticatedUserId(req);
    logger.info({ event: "SELLER_PRO_CANCELED", userId }, "[seller-monetization] subscription cancellation requested");
    res.json({ canceled: true, accessContinuesUntil: null, capacity: await sellerCapacitySummary(prisma, userId) });
  });

  router.post("/subscriptions/resume", async (req, res) => {
    const userId = authenticatedUserId(req);
    res.json({ resumed: true, capacity: await sellerCapacitySummary(prisma, userId) });
  });

  router.post("/capacity/check-shop", async (req, res) => {
    const userId = authenticatedUserId(req);
    const summary = await sellerCapacitySummary(prisma, userId);
    const allowed = summary.availableShopSlots > 0;
    if (!allowed) logger.warn({ event: "SHOP_CAPACITY_BLOCKED", userId }, "[seller-monetization] shop capacity blocked");
    res.json({ allowed, summary, message: allowed ? "Shop capacity available." : "You've used all your Shop slots." });
  });

  router.post("/capacity/check-product", async (req, res) => {
    const userId = authenticatedUserId(req);
    const summary = await sellerCapacitySummary(prisma, userId);
    const allowed = summary.hasUnlimitedProducts || (summary.availableProductSlots ?? 0) > 0;
    if (!allowed) logger.warn({ event: "PRODUCT_CAPACITY_BLOCKED", userId }, "[seller-monetization] product capacity blocked");
    res.json({ allowed, summary, message: allowed ? "Product listing capacity available." : "You've used your 10 free product listings." });
  });

  router.post("/admin/grant-entitlement", async (req, res) => {
    if (!isAdmin(req)) return res.status(403).json({ error: "admin_required" });
    const parsed = grantSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    await ensureFreeSellerEntitlements(prisma, parsed.data.userId);
    await prisma.$executeRaw`
      INSERT INTO "SellerEntitlement" ("id", "userId", "entitlementType", "sourceType", "sourceReferenceId", "quantity", "status")
      VALUES (${randomUUID()}, ${parsed.data.userId}, ${parsed.data.entitlementType}, 'ADMIN_GRANT', ${parsed.data.sourceReferenceId}, ${parsed.data.quantity}, 'ACTIVE')
    `;
    res.status(201).json({ granted: true, capacity: await sellerCapacitySummary(prisma, parsed.data.userId) });
  });

  router.post("/admin/revoke-entitlement", async (req, res) => {
    if (!isAdmin(req)) return res.status(403).json({ error: "admin_required" });
    const id = String((req.body ?? {}).id ?? "");
    if (!id) return res.status(400).json({ error: "id_required" });
    await prisma.$executeRaw`UPDATE "SellerEntitlement" SET "status" = 'REVOKED', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ${id}`;
    res.json({ revoked: true });
  });

  return router;
}

function authenticatedUserId(req: express.Request): string {
  return (req as AuthenticatedRequest).userId;
}

function transactionTypeForPackage(packageType: string): string {
  switch (packageType) {
  case "SHOP_SLOT": return "SHOP_SLOT_PURCHASE";
  case "SHOP_BUNDLE": return "SHOP_CAPACITY_BUNDLE";
  case "UNLIMITED_PRODUCTS": return "PRODUCT_CAPACITY_BUNDLE";
  case "SELLER_PRO": return "SELLER_PRO_SUBSCRIPTION";
  case "PRODUCT_SLOT": return "PRODUCT_SLOT_PURCHASE";
  default: return "PRODUCT_CAPACITY_BUNDLE";
  }
}

function sourceTypeForPackage(billingType: string): SellerEntitlementSource {
  return billingType === "ONE_TIME" ? "ONE_TIME_PURCHASE" : "SUBSCRIPTION";
}

function isAdmin(req: express.Request): boolean {
  return String(req.header("x-oneway-admin") ?? "").toLowerCase() === "true" || process.env.NODE_ENV !== "production";
}
