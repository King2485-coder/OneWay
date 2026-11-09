import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import express from "express";
import rateLimit from "express-rate-limit";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import { createStripeClient } from "../services/stripe";
import { capacityForUser, grantEntitlement } from "../services/billing/EntitlementService";
import {
  isCorePlan,
  oneWayProductRegistry,
  publicProduct,
  resolveOneWayProduct,
  stripePriceForProduct,
  type OneWaySellableProduct,
} from "../services/billing/OneWayProductRegistry";
import { ensureServiceOrderTables } from "../services/billing/ServiceOrderTables";
import { ensurePaymentTables } from "../services/payments/PaymentTables";

const checkoutSchema = z.object({
  productId: z.string().trim().min(1).max(80),
  returnPath: z.string().trim().max(180).optional(),
  termsAccepted: z.literal(true),
  termsVersion: z.string().trim().min(1).max(80).default("2026-07-service-orders-v1"),
});

const changeSchema = z.object({
  productId: z.string().trim().min(1).max(80),
  confirmImmediateProration: z.boolean().default(false),
});

const orderRateLimit = rateLimit({
  windowMs: 60_000,
  limit: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { ok: false, error: "rate_limited" },
});

export function serviceOrdersRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();

  router.get("/products", (_req, res) => {
    res.json({ ok: true, effectiveDate: "2026-07-31", products: oneWayProductRegistry.map(publicProduct) });
  });

  router.use(authMiddleware);
  router.use(orderRateLimit);
  router.use(async (_req, _res, next) => {
    try {
      await Promise.all([ensureServiceOrderTables(prisma), ensurePaymentTables(prisma)]);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/review/:productId", async (req, res) => {
    const userId = authUserId(req);
    const product = resolveOneWayProduct(req.params.productId);
    if (!product) return res.status(404).json({ ok: false, error: "product_not_found" });
    const [capacity, activeCore, duplicate] = await Promise.all([
      capacityForUser(prisma, userId),
      currentCoreSubscription(prisma, userId),
      currentProductSubscription(prisma, userId, product.id),
    ]);
    res.json({
      ok: true,
      product: publicProduct(product),
      capacity,
      resultingCapacity: product.capacityDelta
        ? { productCapacity: capacity.productCapacity + product.capacityDelta, shopCapacity: capacity.shopCapacity }
        : product.shopDelta
          ? { productCapacity: capacity.productCapacity, shopCapacity: capacity.shopCapacity + product.shopDelta }
          : null,
      activeCorePlan: activeCore ? { productId: activeCore.productId, status: activeCore.status, currentPeriodEnd: activeCore.currentPeriodEnd } : null,
      requiresPlanChange: Boolean(isCorePlan(product) && activeCore && activeCore.productId !== product.id),
      duplicateSubscription: Boolean(duplicate),
      taxes: taxEnabled() ? "calculated_at_checkout" : "not_enabled",
    });
  });

  router.post("/free", async (req, res) => {
    const userId = authUserId(req);
    const product = resolveOneWayProduct("oneway_free")!;
    const activeCore = await currentCoreSubscription(prisma, userId);
    if (activeCore && activeCore.productId !== product.id) {
      return res.status(409).json({ ok: false, error: "paid_plan_active", message: "Manage the active paid plan instead of creating a Free entitlement." });
    }
    const existing = await prisma.$queryRawUnsafe<any[]>(
      `SELECT * FROM "BillingEntitlement" WHERE "userId" = ? AND "entitlementKey" = ? AND "status" = 'ACTIVE' LIMIT 1`,
      userId, product.entitlementKey,
    );
    if (existing[0]) return res.json({ ok: true, idempotentReplay: true, activationStatus: "ACTIVE" });
    const order = newOrder(userId, product, "free");
    await prisma.$executeRawUnsafe(
      `INSERT INTO "BillingOrder" (
        "id", "orderNumber", "userId", "productId", "orderType", "status", "currency",
        "subtotal", "tax", "total", "idempotencyKey", "termsVersion", "environment", "completedAt"
      ) VALUES (?, ?, ?, ?, 'free', 'ACTIVATED', 'USD', 0, 0, 0, ?, ?, ?, CURRENT_TIMESTAMP)`,
      order.id, order.orderNumber, userId, product.id, order.idempotencyKey, "2026-07-service-orders-v1", stripeEnvironment(),
    );
    await grantEntitlement(prisma, {
      userId, entitlementKey: product.entitlementKey, sourceOrderId: order.id, productId: product.id,
    });
    await audit(prisma, userId, order.id, "FREE_ENTITLEMENT_GRANTED", "USER", {});
    res.status(201).json({ ok: true, orderId: order.id, orderNumber: order.orderNumber, activationStatus: "ACTIVE" });
  });

  router.post("/checkout-session", async (req, res) => {
    const userId = authUserId(req);
    const parsed = checkoutSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const product = resolveOneWayProduct(parsed.data.productId);
    if (!product) return res.status(404).json({ ok: false, error: "product_not_found" });
    if (product.billingType === "free") return res.status(409).json({ ok: false, error: "free_plan_uses_no_checkout" });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const environmentError = validateStripeEnvironment();
    if (environmentError) return res.status(503).json({ ok: false, error: environmentError });

    const activeCore = isCorePlan(product) ? await currentCoreSubscription(prisma, userId) : null;
    if (activeCore && activeCore.productId !== product.id) {
      return res.status(409).json({
        ok: false, error: "plan_change_required", currentProductId: activeCore.productId,
        message: "Use the confirmed plan-change flow to prevent a second core subscription.",
      });
    }
    if (await currentProductSubscription(prisma, userId, product.id)) {
      return res.status(409).json({ ok: false, error: "subscription_already_active" });
    }

    const stripePriceId = stripePriceForProduct(product);
    if (!stripePriceId) {
      return res.status(503).json({ ok: false, error: "stripe_price_missing", productId: product.id, environmentVariable: product.stripePriceEnv });
    }
    const stripePrice = await stripe.prices.retrieve(stripePriceId);
    const priceProblem = validateStripePrice(product, stripePrice);
    if (priceProblem) return res.status(503).json({ ok: false, error: priceProblem, productId: product.id });

    const reusable = await reusableCheckout(prisma, stripe, userId, product.id);
    if (reusable) return res.json({ ok: true, idempotentReplay: true, ...reusable });

    const customer = await ensureBillingCustomer(prisma, stripe, userId);
    const order = newOrder(userId, product, product.billingType === "monthly" ? "subscription" : "payment");
    await prisma.$executeRawUnsafe(
      `INSERT INTO "BillingOrder" (
        "id", "orderNumber", "userId", "productId", "orderType", "status", "currency", "subtotal", "tax", "total",
        "stripeCustomerId", "idempotencyKey", "termsVersion", "environment", "metadataJson"
      ) VALUES (?, ?, ?, ?, ?, 'PENDING_CHECKOUT', 'USD', ?, 0, ?, ?, ?, ?, ?, ?)`,
      order.id, order.orderNumber, userId, product.id, order.orderType, product.amount, product.amount,
      customer.stripeCustomerId, order.idempotencyKey, parsed.data.termsVersion, stripeEnvironment(),
      JSON.stringify({ returnPath: safeReturnPath(parsed.data.returnPath), priceVersion: product.effectiveDate }),
    );

    const origin = process.env.ONEWAY_WEB_BASE_URL?.trim() || "https://oneway.is";
    const metadata = {
      oneway_user_id: userId,
      oneway_product_id: product.id,
      oneway_order_id: order.id,
      oneway_environment: stripeEnvironment(),
      oneway_checkout_type: order.orderType,
      oneway_entitlement_key: product.entitlementKey,
    };
    const session = await stripe.checkout.sessions.create({
      mode: product.billingType === "monthly" ? "subscription" : "payment",
      customer: customer.stripeCustomerId,
      line_items: [{ price: stripePriceId, quantity: 1 }],
      success_url: `${origin}/order/success?order_id=${encodeURIComponent(order.id)}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/order/cancelled?order_id=${encodeURIComponent(order.id)}`,
      client_reference_id: order.id,
      metadata,
      payment_intent_data: product.billingType === "one_time" ? { metadata } : undefined,
      subscription_data: product.billingType === "monthly" ? { metadata } : undefined,
      automatic_tax: { enabled: taxEnabled() },
      billing_address_collection: taxEnabled() ? "required" : "auto",
      tax_id_collection: product.id.startsWith("oneway_business") ? { enabled: true } : undefined,
      allow_promotion_codes: process.env.STRIPE_PROMOTION_CODES_ENABLED === "true",
    }, { idempotencyKey: order.idempotencyKey });

    if (!session.url) throw new Error("stripe_checkout_url_missing");
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingOrder" SET "status" = 'CHECKOUT_OPEN', "stripeCheckoutSessionId" = ?,
        "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      session.id, order.id,
    );
    await audit(prisma, userId, order.id, "CHECKOUT_STARTED", "USER", { productId: product.id });
    logger.info({ userId, orderId: order.id, productId: product.id }, "SERVICE_CHECKOUT_STARTED");
    res.status(201).json({ ok: true, orderId: order.id, orderNumber: order.orderNumber, checkoutUrl: session.url });
  });

  router.get("/orders/:orderId", async (req, res) => {
    const userId = authUserId(req);
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT * FROM "BillingOrder" WHERE "id" = ? AND "userId" = ? LIMIT 1`, req.params.orderId, userId,
    );
    if (!rows[0]) return res.status(404).json({ ok: false, error: "order_not_found" });
    const order = rows[0];
    const product = resolveOneWayProduct(order.productId);
    const subscription = order.stripeSubscriptionId
      ? (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingSubscription" WHERE "stripeSubscriptionId" = ? LIMIT 1`, order.stripeSubscriptionId))[0]
      : null;
    res.json({ ok: true, order: orderDTO(order, product, subscription) });
  });

  router.post("/orders/:orderId/cancelled", async (req, res) => {
    const userId = authUserId(req);
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingOrder" SET "status" = 'CANCELLED', "cancelledAt" = CURRENT_TIMESTAMP,
       "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "userId" = ? AND "status" IN ('DRAFT','PENDING_CHECKOUT','CHECKOUT_OPEN')`,
      req.params.orderId, userId,
    );
    await audit(prisma, userId, req.params.orderId, "CHECKOUT_CANCELLED", "USER", {});
    res.json({ ok: true });
  });

  router.get("/history", async (req, res) => {
    const userId = authUserId(req);
    const [orders, subscriptions, invoices, capacity] = await Promise.all([
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingOrder" WHERE "userId" = ? ORDER BY "createdAt" DESC LIMIT 100`, userId),
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingSubscription" WHERE "userId" = ? ORDER BY "createdAt" DESC`, userId),
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "Invoice" WHERE "userId" = ? ORDER BY "createdAt" DESC LIMIT 100`, userId),
      capacityForUser(prisma, userId),
    ]);
    res.json({
      ok: true,
      orders: orders.map((order) => orderDTO(order, resolveOneWayProduct(order.productId), null)),
      subscriptions,
      invoices: invoices.map((invoice) => ({
        id: invoice.id, stripeInvoiceId: invoice.stripeInvoiceId, amountDue: invoice.amountDueMinor,
        amountPaid: invoice.amountPaidMinor, currency: invoice.currency, status: invoice.status,
        hostedInvoiceUrl: invoice.hostedInvoiceUrl, createdAt: invoice.createdAt,
      })),
      capacity,
    });
  });

  router.post("/customer-portal", async (req, res) => {
    const userId = authUserId(req);
    const stripe = createStripeClient();
    if (!stripe?.billingPortal?.sessions?.create) return res.status(503).json({ ok: false, error: "stripe_customer_portal_not_configured" });
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingCustomerLink" WHERE "userId" = ? LIMIT 1`, userId);
    if (!rows[0]) return res.status(404).json({ ok: false, error: "billing_customer_not_found" });
    const returnUrl = `${process.env.ONEWAY_WEB_BASE_URL?.trim() || "https://oneway.is"}/account/billing`;
    const session = await stripe.billingPortal.sessions.create({ customer: rows[0].stripeCustomerId, return_url: returnUrl });
    await audit(prisma, userId, null, "CUSTOMER_PORTAL_OPENED", "USER", {});
    res.json({ ok: true, url: session.url });
  });

  router.post("/subscriptions/change", async (req, res) => {
    const userId = authUserId(req);
    const parsed = changeSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const target = resolveOneWayProduct(parsed.data.productId);
    if (!target || !isCorePlan(target) || target.billingType !== "monthly") return res.status(400).json({ ok: false, error: "invalid_core_plan" });
    const current = await currentCoreSubscription(prisma, userId);
    if (!current?.stripeSubscriptionId) return res.status(404).json({ ok: false, error: "active_core_subscription_not_found" });
    const source = resolveOneWayProduct(current.productId);
    if (!source || !isCorePlan(source)) return res.status(409).json({ ok: false, error: "current_plan_mapping_missing" });
    if (source.id === target.id) return res.json({ ok: true, unchanged: true });
    const stripePriceId = stripePriceForProduct(target);
    if (!stripePriceId) return res.status(503).json({ ok: false, error: "stripe_price_missing", productId: target.id });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const subscription: any = await stripe.subscriptions.retrieve(current.stripeSubscriptionId);
    const item = subscription.items?.data?.[0];
    if (!item?.id) return res.status(409).json({ ok: false, error: "subscription_item_missing" });
    const upgrade = (target.corePlanRank ?? 0) > (source.corePlanRank ?? 0);
    if (upgrade && !parsed.data.confirmImmediateProration) {
      return res.status(409).json({ ok: false, error: "proration_confirmation_required", effective: "immediate" });
    }
    if (upgrade) {
      await stripe.subscriptions.update(subscription.id, {
        items: [{ id: item.id, price: stripePriceId }],
        proration_behavior: "always_invoice",
        payment_behavior: "pending_if_incomplete",
        metadata: { ...subscription.metadata, oneway_product_id: target.id, oneway_entitlement_key: target.entitlementKey },
      });
      await prisma.$executeRawUnsafe(
        `UPDATE "BillingSubscription" SET "pendingProductId" = ?, "pendingChangeAt" = CURRENT_TIMESTAMP,
         "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
        target.id, subscription.id,
      );
      return res.json({ ok: true, changeType: "upgrade", effective: "immediate", productId: target.id });
    }
    const currentPeriodEnd = Number(subscription.current_period_end ?? 0);
    const schedule: any = subscription.schedule
      ? await stripe.subscriptionSchedules.retrieve(String(subscription.schedule))
      : await stripe.subscriptionSchedules.create({ from_subscription: subscription.id });
    await stripe.subscriptionSchedules.update(schedule.id, {
      end_behavior: "release",
      phases: [
        {
          start_date: Number(subscription.current_period_start),
          end_date: currentPeriodEnd,
          items: [{ price: String(item.price.id), quantity: item.quantity ?? 1 }],
        },
        {
          start_date: currentPeriodEnd,
          items: [{ price: stripePriceId, quantity: 1 }],
          metadata: { oneway_product_id: target.id, oneway_entitlement_key: target.entitlementKey },
        },
      ],
    } as any);
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingSubscription" SET "pendingProductId" = ?, "pendingChangeAt" = ?,
       "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
      target.id, new Date(currentPeriodEnd * 1000), subscription.id,
    );
    res.json({ ok: true, changeType: "downgrade", effective: new Date(currentPeriodEnd * 1000).toISOString(), productId: target.id });
  });

  return router;
}

function authUserId(req: express.Request): string {
  return (req as AuthenticatedRequest).userId;
}

function stripeEnvironment(): string {
  return (process.env.STRIPE_ENV ?? "sandbox").trim().toLowerCase();
}

function taxEnabled(): boolean {
  return process.env.STRIPE_TAX_ENABLED === "true";
}

function validateStripeEnvironment(): string | null {
  const key = process.env.STRIPE_SECRET_KEY?.trim() ?? "";
  const environment = stripeEnvironment();
  if ((environment === "sandbox" || environment === "test") && !/^(sk|rk)_test_/.test(key)) return "stripe_test_key_required";
  if ((environment === "production" || environment === "live") && !/^(sk|rk)_live_/.test(key)) return "stripe_live_key_required";
  if ((environment === "production" || environment === "live") && process.env.ONEWAY_LIVE_CHECKOUT_ENABLED !== "true") return "live_checkout_not_approved";
  return null;
}

function validateStripePrice(product: OneWaySellableProduct, price: any): string | null {
  if (!price?.active) return "stripe_price_inactive";
  if (Number(price.unit_amount) !== product.amount) return "stripe_price_amount_mismatch";
  if (String(price.currency).toLowerCase() !== product.currency) return "stripe_price_currency_mismatch";
  if (product.billingType === "monthly" && price.recurring?.interval !== "month") return "stripe_price_interval_mismatch";
  if (product.billingType === "one_time" && price.type !== "one_time") return "stripe_price_billing_type_mismatch";
  const mappedId = price.metadata?.oneway_product_id || (typeof price.product === "object" ? price.product?.metadata?.oneway_product_id : undefined);
  if (mappedId && mappedId !== product.id) return "stripe_price_metadata_mismatch";
  return null;
}

async function ensureBillingCustomer(prisma: PrismaClient, stripe: any, userId: string) {
  const existing = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingCustomerLink" WHERE "userId" = ? LIMIT 1`, userId);
  if (existing[0]) return existing[0];
  const user = await prisma.user.findUnique({ where: { id: userId }, select: { email: true } });
  const customer = await stripe.customers.create({
    email: user?.email ?? undefined,
    metadata: { oneway_user_id: userId },
  }, { idempotencyKey: `oneway-customer:${userId}` });
  const id = crypto.randomUUID();
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "BillingCustomerLink" ("id", "userId", "stripeCustomerId") VALUES (?, ?, ?)`,
    id, userId, customer.id,
  );
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "OneWayBillingCustomer" ("id", "userId", "stripeCustomerId", "billingEmail") VALUES (?, ?, ?, ?)`,
    crypto.randomUUID(), userId, customer.id, user?.email ?? null,
  );
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingCustomerLink" WHERE "userId" = ? LIMIT 1`, userId))[0];
}

async function currentCoreSubscription(prisma: PrismaClient, userId: string): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "BillingSubscription" WHERE "userId" = ? AND "productId" IN
      ('oneway_private','oneway_complete','oneway_business','oneway_business_pro')
      AND "status" IN ('ACTIVE','TRIALING','PAST_DUE','INCOMPLETE') ORDER BY "createdAt" DESC LIMIT 1`,
    userId,
  );
  return rows[0] ?? null;
}

async function currentProductSubscription(prisma: PrismaClient, userId: string, productId: string): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "BillingSubscription" WHERE "userId" = ? AND "productId" = ?
     AND "status" IN ('ACTIVE','TRIALING','PAST_DUE','INCOMPLETE') LIMIT 1`,
    userId, productId,
  );
  return rows[0] ?? null;
}

async function reusableCheckout(prisma: PrismaClient, stripe: any, userId: string, productId: string) {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "BillingOrder" WHERE "userId" = ? AND "productId" = ? AND "status" = 'CHECKOUT_OPEN'
     ORDER BY "createdAt" DESC LIMIT 1`, userId, productId,
  );
  if (!rows[0]?.stripeCheckoutSessionId) return null;
  const session = await stripe.checkout.sessions.retrieve(rows[0].stripeCheckoutSessionId);
  if (session.status !== "open" || !session.url) return null;
  return { orderId: rows[0].id, orderNumber: rows[0].orderNumber, checkoutUrl: session.url };
}

function newOrder(userId: string, product: OneWaySellableProduct, orderType: string) {
  const id = crypto.randomUUID();
  return {
    id,
    orderNumber: `OW-${Date.now().toString(36).toUpperCase()}-${id.slice(0, 6).toUpperCase()}`,
    idempotencyKey: `checkout:${userId}:${id}`,
    orderType,
    product,
  };
}

function safeReturnPath(value?: string): string | null {
  return value && value.startsWith("/") && !value.startsWith("//") ? value : null;
}

function orderDTO(order: any, product: OneWaySellableProduct | undefined, subscription: any) {
  return {
    id: order.id, orderNumber: order.orderNumber, productId: order.productId,
    productName: product?.name ?? order.productId, orderType: order.orderType,
    status: String(order.status).toLowerCase(), currency: order.currency,
    subtotal: Number(order.subtotal), tax: Number(order.tax), total: Number(order.total),
    billingInterval: product?.billingType === "monthly" ? "month" : product?.billingType,
    activationStatus: String(order.status).toUpperCase() === "ACTIVATED" ? "active" : "pending",
    nextBillingDate: subscription?.currentPeriodEnd ?? null,
    createdAt: order.createdAt, completedAt: order.completedAt, failureCode: order.failureCode,
  };
}

async function audit(prisma: PrismaClient, userId: string | null, orderId: string | null, action: string, actorType: string, metadata: Record<string, unknown>) {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "BillingAuditLog" ("id", "userId", "orderId", "action", "actorType", "metadataJson")
     VALUES (?, ?, ?, ?, ?, ?)`,
    crypto.randomUUID(), userId, orderId, action, actorType, JSON.stringify(metadata),
  );
}
