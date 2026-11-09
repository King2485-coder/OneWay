import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { createStripeClient } from "../services/stripe";
import { parsePrice } from "../services/catalog";
import {
  calculateMarketplaceOrderLedger,
  dollarsToMinorUnits,
  marketplaceFeeConfiguration,
  minorUnitsToDollars,
} from "../services/marketplaceFee";
import { ensurePaymentTables } from "../services/payments/PaymentTables";

const createOrderSchema = z.object({
  idempotencyKey: z.string().trim().min(8).max(120).optional(),
  items: z.array(
    z.object({
      productId: z.string().uuid(),
      quantity: z.number().int().positive().max(20).default(1),
    })
  ).min(1),
});

export function ordersRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();
  router.use(authMiddleware);

  router.post("/", async (req, res) => {
    const parsed = createOrderSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    await prisma.user.upsert({
      where: { id: userId },
      update: {},
      create: { id: userId, displayName: "OneWay Shopper" },
    });
    if (parsed.data.idempotencyKey) {
      const existingOrder = await prisma.order.findFirst({
        where: { userId, idempotencyKey: parsed.data.idempotencyKey },
        include: { items: true },
      });
      if (existingOrder) {
        res.status(200).json({ order: existingOrder, checkoutUrl: null, idempotentReplay: true });
        return;
      }
    }

    const ids = parsed.data.items.map((item) => item.productId);
    const products = await prisma.storefrontProduct.findMany({
      where: {
        id: { in: ids },
        published: true,
        storefront: { status: "published", published: true, searchable: true, publicVisible: true },
      },
      include: { storefront: true },
    });

    if (products.length !== ids.length) {
      res.status(400).json({ error: "product_not_found" });
      return;
    }

    const productById = new Map(products.map((product) => [product.id, product]));
    const storeId = products[0]?.storefrontId ?? null;
    const shopIds = new Set(products.map((product) => product.storefrontId));
    if (shopIds.size !== 1 || !storeId) {
      res.status(400).json({ error: "single_shop_checkout_required" });
      return;
    }

    const sellerId = products[0]?.storefront.ownerId ?? null;
    const currency = (products[0]?.currency ?? "USD").toUpperCase();
    const lineItems = parsed.data.items.map((item) => {
      const product = productById.get(item.productId)!;
      const unitPrice = parsePrice(product.price);
      const unitPriceMinor = dollarsToMinorUnits(unitPrice);
      return {
        product,
        quantity: item.quantity,
        unitPrice,
        unitPriceMinor,
        totalMinor: unitPriceMinor * item.quantity,
      };
    });

    const unavailable = lineItems.find(({ product, quantity }) => product.trackInventory && product.inventory < quantity);
    if (unavailable) {
      res.status(409).json({
        error: "insufficient_inventory",
        productId: unavailable.product.id,
        available: unavailable.product.inventory,
      });
      return;
    }

    const subtotalMinor = lineItems.reduce((sum, item) => sum + item.totalMinor, 0);
    const stripe = createStripeClient();
    await ensurePaymentTables(prisma);
    const sellerPaymentAccount = sellerId
      ? await prisma.$queryRawUnsafe<Array<{ stripeAccountId: string; chargesEnabled: number | boolean; payoutsEnabled: number | boolean; onboardingStatus: string }>>(
        `SELECT "stripeAccountId", "chargesEnabled", "payoutsEnabled", "onboardingStatus"
         FROM "SellerPaymentAccount"
         WHERE "sellerUserId" = ? AND COALESCE("shopId", '') IN (COALESCE(?, ''), '')
         ORDER BY CASE WHEN "shopId" IS NULL THEN 1 ELSE 0 END ASC
         LIMIT 1`,
        sellerId,
        storeId,
      )
      : [];
    if (stripe && (!sellerPaymentAccount[0] || !truthyDbBoolean(sellerPaymentAccount[0].chargesEnabled))) {
      res.status(409).json({
        error: "seller_payments_not_ready",
        message: "Seller payments are not available yet.",
        onboardingStatus: sellerPaymentAccount[0]?.onboardingStatus ?? "NOT_STARTED",
      });
      return;
    }
    const testCheckoutPaid = !stripe && process.env.NODE_ENV !== "production";
    const paymentStatus = testCheckoutPaid ? "paid" : "pending_payment";
    const ledger = calculateMarketplaceOrderLedger({
      currency,
      subtotalMinor,
      discountAmountMinor: 0,
      shippingAmountMinor: 0,
      taxAmountMinor: 0,
      paymentProcessingFeeMinor: 0,
      paymentStatus,
    });

    let stripeCheckoutId: string | undefined;
    let checkoutUrl: string | null = null;
    const orderId = randomUUID();
    const activePolicy = storeId
      ? await prisma.storePolicy.findUnique({ where: { storefrontId: storeId } })
      : null;
    const activePolicyVersion = activePolicy?.publishedJson ? activePolicy.publishedVersion : null;
    const activePolicySnapshot = activePolicy?.publishedJson ?? null;
    if (stripe) {
      const connectedAccountId = sellerPaymentAccount[0]!.stripeAccountId;
      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        client_reference_id: orderId,
        metadata: {
          onewayOrderIntent: "shop_checkout",
          orderId,
          storeId,
          sellerId: sellerId ?? "",
          oneWayPlatformFeeMinor: String(marketplaceFeeConfiguration().feeAmountMinor),
          feeType: marketplaceFeeConfiguration().feeType,
        },
        payment_intent_data: {
          application_fee_amount: ledger.oneWayPlatformFeeMinor,
          transfer_data: {
            destination: connectedAccountId,
          },
          metadata: {
            onewayOrderIntent: "shop_checkout",
            orderId,
            storeId,
            sellerId: sellerId ?? "",
            connectedAccountId,
            oneWayPlatformFeeMinor: String(ledger.oneWayPlatformFeeMinor),
          },
        },
        line_items: lineItems.map((item) => ({
          price_data: {
            currency: currency.toLowerCase(),
            product_data: {
              name: item.product.name,
              description: item.product.description,
              images: item.product.imageUrl ? [item.product.imageUrl] : [],
            },
            unit_amount: Math.round(item.unitPrice * 100),
          },
          quantity: item.quantity,
        })),
        success_url: process.env.STRIPE_SUCCESS_URL ?? "https://oneway.is/success",
        cancel_url: process.env.STRIPE_CANCEL_URL ?? "https://oneway.is/cancel",
      });
      stripeCheckoutId = session.id;
      checkoutUrl = session.url;
    }

    const order = await prisma.$transaction(async (tx) => {
      const createdOrder = await tx.order.create({
      data: {
        id: orderId,
        userId,
        storeId,
        sellerId,
        currency,
        total: minorUnitsToDollars(ledger.customerTotalMinor),
        status: paymentStatus,
        paymentStatus,
        payoutStatus: ledger.payoutStatus,
        subtotalMinor: ledger.subtotalMinor,
        discountAmountMinor: ledger.discountAmountMinor,
        shippingAmountMinor: ledger.shippingAmountMinor,
        taxAmountMinor: ledger.taxAmountMinor,
        customerTotalMinor: ledger.customerTotalMinor,
        paymentProcessingFeeMinor: ledger.paymentProcessingFeeMinor,
        oneWayPlatformFeeMinor: ledger.oneWayPlatformFeeMinor,
        sellerGrossAmountMinor: ledger.sellerGrossAmountMinor,
        sellerNetAmountMinor: ledger.sellerNetAmountMinor,
        refundedAmountMinor: ledger.refundedAmountMinor,
        disputedAmountMinor: ledger.disputedAmountMinor,
        payoutAmountMinor: ledger.payoutAmountMinor,
        feeConfigSnapshotJson: JSON.stringify(ledger.feeConfigSnapshot),
        policyVersion: activePolicyVersion,
        policySnapshotJson: activePolicySnapshot,
        idempotencyKey: parsed.data.idempotencyKey,
        stripeCheckoutId,
        items: {
          create: lineItems.map((item) => ({
            productId: item.product.id,
            name: item.product.name,
            quantity: item.quantity,
            unitPrice: minorUnitsToDollars(item.unitPriceMinor),
            imageUrl: item.product.imageUrl,
          })),
        },
      },
      include: { items: true },
      });

      // The development safe-test path has no Stripe webhook, so it performs
      // the same inventory transition atomically with order creation. An
      // idempotent replay returns above and cannot decrement it twice.
      if (testCheckoutPaid) {
        for (const item of lineItems) {
          if (!item.product.trackInventory) continue;
          const updated = await tx.storefrontProduct.updateMany({
            where: { id: item.product.id, inventory: { gte: item.quantity } },
            data: { inventory: { decrement: item.quantity } },
          });
          if (updated.count !== 1) throw new Error(`inventory_changed:${item.product.id}`);
        }
      }
      return createdOrder;
    });

    res.status(201).json({
      order,
      checkoutUrl,
    });
  });

  router.get("/marketplace-fee", (_req, res) => {
    res.json(marketplaceFeeConfiguration());
  });

  router.get("/", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const orders = await prisma.order.findMany({
      where: { OR: [{ userId }, { sellerId: userId }] },
      include: { items: true },
      orderBy: { createdAt: "desc" },
    });
    res.json(orders);
  });

  return router;
}

function truthyDbBoolean(value: boolean | number): boolean {
  return value === true || value === 1;
}
