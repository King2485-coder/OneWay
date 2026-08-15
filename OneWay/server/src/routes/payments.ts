import type { PrismaClient } from "@prisma/client";
import crypto from "node:crypto";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import { createStripeClient, stripeConfigured } from "../services/stripe";
import { ensurePaymentTables } from "../services/payments/PaymentTables";
import { calculateMarketplaceOrderLedger, marketplaceFeeConfiguration } from "../services/marketplaceFee";

const accountSchema = z.object({
  shopId: z.string().trim().min(1).max(120).optional(),
  country: z.string().trim().length(2).default("US"),
  businessType: z.enum(["individual", "company", "non_profit", "government_entity"]).default("individual"),
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
});

const linkSchema = z.object({
  refreshUrl: z.string().url().optional(),
  returnUrl: z.string().url().optional(),
});

const orderPaymentSchema = z.object({
  orderId: z.string().uuid(),
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
});

const refundSchema = z.object({
  orderId: z.string().uuid(),
  amountMinor: z.number().int().positive().optional(),
  reason: z.enum(["duplicate", "fraudulent", "requested_by_customer"]).optional(),
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
});

const autopaySchema = z.object({
  scope: z.enum(["SELLER_SUBSCRIPTION", "SHOP_SUBSCRIPTION", "STORAGE_UPGRADES", "ONEWAY_SERVICES"]),
  stripePaymentMethodId: z.string().trim().min(3).max(160),
  stripeCustomerId: z.string().trim().min(3).max(160).optional(),
  termsVersion: z.string().trim().min(1).max(80).default("2026-07"),
  billingFrequency: z.string().trim().min(1).max(80).default("provider_defined"),
  nextChargeAt: z.string().datetime().optional(),
  authorizationText: z.string().trim().min(12).max(2000),
});

const adminSearchSchema = z.object({
  q: z.string().trim().min(2).max(180),
  type: z.enum(["all", "orders", "payments", "refunds", "payouts", "disputes", "events", "accounts"]).default("all"),
});

export function paymentsRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(async (_req, _res, next) => {
    try {
      await ensurePaymentTables(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.post("/sellers/account", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = accountSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });

    const existing = await currentSellerAccount(prisma, userId, parsed.data.shopId);
    if (existing) {
      res.status(200).json({ ok: true, account: existing, idempotentReplay: true });
      return;
    }

    const stripe = createStripeClient();
    if (!stripe) {
      res.status(503).json({ ok: false, error: "stripe_not_configured", message: "Stripe Connect is not configured for this environment." });
      return;
    }

    const account = await stripe.accounts.create({
      type: "express",
      country: parsed.data.country,
      business_type: parsed.data.businessType,
      capabilities: {
        card_payments: { requested: true },
        transfers: { requested: true },
      },
      metadata: {
        oneWaySellerUserId: userId,
        oneWayShopId: parsed.data.shopId ?? "",
      },
    }, { idempotencyKey: parsed.data.idempotencyKey ?? `seller-account:${userId}:${parsed.data.shopId ?? "default"}` });

    const row = await upsertSellerAccount(prisma, userId, parsed.data.shopId, account);
    logger.info({ userId, shopId: parsed.data.shopId, sellerPaymentAccountId: row.id }, "PAYMENT_SELLER_ACCOUNT_CREATED");
    res.status(201).json({ ok: true, account: row });
  });

  router.get("/sellers/status", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const row = await currentSellerAccount(prisma, userId, stringQuery(req.query.shopId));
    res.json({ ok: true, account: row, stripeConfigured: stripeConfigured() });
  });

  router.get("/sellers/dashboard", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const shopId = stringQuery(req.query.shopId);
    const account = await currentSellerAccount(prisma, userId, shopId);
    const [earnings, payouts, transactions] = await Promise.all([
      sellerEarningsSummary(prisma, userId),
      sellerPayoutRows(prisma, account?.stripeAccountId ?? null, 10),
      sellerTransactionRows(prisma, userId, 20),
    ]);
    res.json({
      ok: true,
      stripeConfigured: stripeConfigured(),
      paymentStatus: account ? sellerPaymentStatus(account) : "not_started",
      verificationStatus: account?.onboardingStatus ?? "NOT_STARTED",
      account: account ? sellerAccountDTO(account) : null,
      earnings,
      payouts,
      recentTransactions: transactions,
      actions: {
        setUpPayments: !account,
        continueVerification: Boolean(account && !truthyDbBoolean(account.detailsSubmitted)),
        manageStripeAccount: Boolean(account),
        refreshStatus: Boolean(account),
      },
    });
  });

  router.post("/sellers/refresh-status", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const row = await currentSellerAccount(prisma, userId, stringQuery(req.query.shopId));
    if (!row) return res.status(404).json({ ok: false, error: "seller_payment_account_required" });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const account = await stripe.accounts.retrieve(row.stripeAccountId);
    await updateSellerAccountFromStripe(prisma, row.stripeAccountId, account);
    res.json({ ok: true, account: sellerAccountDTO(await currentSellerAccount(prisma, userId, row.shopId)) });
  });

  router.post("/sellers/onboarding-link", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = linkSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const row = await currentSellerAccount(prisma, userId, stringQuery(req.query.shopId));
    if (!row) return res.status(404).json({ ok: false, error: "seller_payment_account_required" });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });

    const link = await stripe.accountLinks.create({
      account: row.stripeAccountId,
      refresh_url: parsed.data.refreshUrl ?? process.env.STRIPE_CONNECT_REFRESH_URL ?? "https://oneway.is/payments/refresh",
      return_url: parsed.data.returnUrl ?? process.env.STRIPE_CONNECT_RETURN_URL ?? "https://oneway.is/payments/return",
      type: "account_onboarding",
    });
    await prisma.$executeRawUnsafe(`UPDATE "SellerPaymentAccount" SET "onboardingStatus" = 'ONBOARDING', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, row.id);
    logger.info({ userId, sellerPaymentAccountId: row.id }, "PAYMENT_SELLER_ONBOARDING_STARTED");
    res.json({ ok: true, url: link.url, expiresAt: link.expires_at ?? null });
  });

  router.post("/sellers/dashboard-link", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const row = await currentSellerAccount(prisma, userId, stringQuery(req.query.shopId));
    if (!row) return res.status(404).json({ ok: false, error: "seller_payment_account_required" });
    const stripe = createStripeClient();
    if (stripe?.loginLinks?.create) {
      const link = await stripe.loginLinks.create(row.stripeAccountId);
      return res.json({ ok: true, url: link.url ?? null });
    }
    res.json({
      ok: true,
      url: null,
      message: "Stripe Express dashboard links require live Connect configuration. Onboarding status remains available in OneWay.",
    });
  });

  router.get("/sellers/requirements", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const row = await currentSellerAccount(prisma, userId, stringQuery(req.query.shopId));
    if (!row) return res.status(404).json({ ok: false, error: "seller_payment_account_required" });
    res.json({
      ok: true,
      requirements: {
        currentlyDue: jsonArray(row.requirementsCurrentlyDue),
        eventuallyDue: jsonArray(row.requirementsEventuallyDue),
        pastDue: jsonArray(row.requirementsPastDue),
        disabledReason: row.disabledReason,
      },
    });
  });

  router.get("/sellers/earnings", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    res.json({ ok: true, earnings: await sellerEarningsSummary(prisma, userId), transactions: await sellerTransactionRows(prisma, userId, 100) });
  });

  router.get("/sellers/payouts", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const account = await currentSellerAccount(prisma, userId, stringQuery(req.query.shopId));
    res.json({ ok: true, payouts: await sellerPayoutRows(prisma, account?.stripeAccountId ?? null, 100), connectedAccountId: account?.stripeAccountId ?? null });
  });

  router.get("/transactions", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const limit = clampNumber(Number(req.query.limit ?? 50), 1, 100);
    const [buyer, seller] = await Promise.all([
      buyerPaymentRows(prisma, userId, limit),
      sellerTransactionRows(prisma, userId, limit),
    ]);
    res.json({ ok: true, transactions: [...buyer, ...seller].sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt)).slice(0, limit) });
  });

  router.get("/transactions/:transactionId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const transaction = await paymentTransactionDetail(prisma, userId, req.params.transactionId);
    if (!transaction) return res.status(404).json({ ok: false, error: "transaction_not_found" });
    res.json({ ok: true, transaction });
  });

  router.get("/config", (_req, res) => {
    res.json({
      ok: true,
      stripeConfigured: stripeConfigured(),
      publishableKeyConfigured: Boolean(process.env.STRIPE_PUBLISHABLE_KEY?.trim()),
      publishableKey: process.env.STRIPE_PUBLISHABLE_KEY?.trim() || null,
      environment: stripeEnvironment(),
      connectEnabled: Boolean(process.env.STRIPE_CONNECT_CLIENT_ID?.trim()) || stripeConfigured(),
      applePayReady: stripeConfigured(),
      googlePayFutureReady: true,
      webhookUrl: "https://api.oneway.is/api/stripe/webhooks",
    });
  });

  router.post("/customers/portal", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const stripe = createStripeClient();
    if (!stripe?.billingPortal?.sessions?.create) return res.status(503).json({ ok: false, error: "stripe_customer_portal_not_configured" });
    const customer = await ensureBillingCustomer(prisma, stripe, userId, stringBody(req.body?.email));
    const session = await stripe.billingPortal.sessions.create({
      customer: customer.stripeCustomerId,
      return_url: stringBody(req.body?.returnUrl) ?? process.env.STRIPE_PORTAL_RETURN_URL ?? "https://oneway.is/settings/billing",
    });
    res.json({ ok: true, url: session.url ?? null });
  });

  router.get("/payment-methods", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayBillingCustomer" WHERE "userId" = ? LIMIT 1`, userId);
    res.json({
      ok: true,
      customer: rows[0] ? {
        stripeCustomerId: rows[0].stripeCustomerId,
        defaultPaymentMethodId: rows[0].defaultPaymentMethodId,
        status: rows[0].status,
      } : null,
      cards: [],
      applePay: { supported: true, configuredThroughStripe: stripeConfigured() },
      note: "Card details are stored by Stripe. OneWay never stores card numbers.",
    });
  });

  router.get("/automatic-payments", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AutopayAuthorization" WHERE "userId" = ? ORDER BY "createdAt" DESC`, userId);
    res.json({ ok: true, automaticPayments: rows.map(autopayDTO), defaultState: "OFF" });
  });

  router.post("/automatic-payments", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = autopaySchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const id = crypto.randomUUID();
    await prisma.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "AutopayAuthorization" (
        "id", "userId", "stripeCustomerId", "stripePaymentMethodId", "scope", "status", "termsVersion", "consentedAt"
      ) VALUES (?, ?, ?, ?, ?, 'ACTIVE', ?, CURRENT_TIMESTAMP)`,
      id,
      userId,
      parsed.data.stripeCustomerId ?? null,
      parsed.data.stripePaymentMethodId,
      parsed.data.scope,
      parsed.data.termsVersion,
    );
    await enqueuePaymentNotification(prisma, userId, "wallet", "autopay.enabled", "Autopay Enabled", `${parsed.data.scope.replaceAll("_", " ")} automatic payments are enabled.`, "AutopayAuthorization", id, {
      billingFrequency: parsed.data.billingFrequency,
      nextChargeAt: parsed.data.nextChargeAt ?? null,
    });
    res.status(201).json({ ok: true, automaticPayment: (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AutopayAuthorization" WHERE "id" = ?`, id))[0] ?? null });
  });

  router.post("/automatic-payments/:authorizationId/disable", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await prisma.$executeRawUnsafe(
      `UPDATE "AutopayAuthorization" SET "status" = 'REVOKED', "revokedAt" = CURRENT_TIMESTAMP, "revokedReason" = 'user_disabled', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "userId" = ?`,
      req.params.authorizationId,
      userId,
    );
    await enqueuePaymentNotification(prisma, userId, "wallet", "autopay.disabled", "Autopay Disabled", "Automatic payments were disabled.", "AutopayAuthorization", req.params.authorizationId, {});
    res.json({ ok: true, authorizationId: req.params.authorizationId, status: "REVOKED" });
  });

  router.post("/marketplace/payment-intent", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = orderPaymentSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const order = await loadBuyerOrder(prisma, parsed.data.orderId, userId);
    if (!order) return res.status(404).json({ ok: false, error: "order_not_found" });
    if (order.paymentStatus === "paid") return res.status(409).json({ ok: false, error: "order_already_paid" });
    const sellerAccount = await sellerAccountForOrder(prisma, order);
    if (!sellerAccount || !truthyDbBoolean(sellerAccount.chargesEnabled)) {
      return res.status(409).json({ ok: false, error: "seller_payments_not_ready", onboardingStatus: sellerAccount?.onboardingStatus ?? "NOT_STARTED" });
    }

    const metadata = paymentMetadata(order, sellerAccount.stripeAccountId);
    const intent = await stripe.paymentIntents.create({
      amount: order.customerTotalMinor,
      currency: order.currency.toLowerCase(),
      automatic_payment_methods: { enabled: true },
      application_fee_amount: order.oneWayPlatformFeeMinor,
      transfer_data: { destination: sellerAccount.stripeAccountId },
      metadata,
    }, { idempotencyKey: parsed.data.idempotencyKey ?? `pi:${order.id}` });

    await prisma.order.update({
      where: { id: order.id },
      data: { paymentIntentId: String(intent.id ?? ""), paymentStatus: "requires_payment_method", status: "requires_payment_method", updatedAt: new Date() },
    });
    const payment = await upsertShopPayment(prisma, order, {
      stripePaymentIntentId: String(intent.id ?? ""),
      connectedAccountId: sellerAccount.stripeAccountId,
      status: String(intent.status ?? "requires_payment_method").toUpperCase(),
      stripeCustomerId: String(intent.customer ?? ""),
      paymentMethodTypes: JSON.stringify(intent.payment_method_types ?? ["card"]),
      metadataJson: JSON.stringify(metadata),
    });
    await upsertPlatformFee(prisma, order, payment.id, "PENDING");
    res.status(201).json({
      ok: true,
      paymentIntentId: intent.id,
      clientSecret: intent.client_secret ?? null,
      amountMinor: order.customerTotalMinor,
      currency: order.currency,
      payment,
    });
  });

  router.post("/marketplace/checkout-session", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = orderPaymentSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const order = await loadBuyerOrderWithItems(prisma, parsed.data.orderId, userId);
    if (!order) return res.status(404).json({ ok: false, error: "order_not_found" });
    if (order.paymentStatus === "paid") return res.status(409).json({ ok: false, error: "order_already_paid" });
    const sellerAccount = await sellerAccountForOrder(prisma, order);
    if (!sellerAccount || !truthyDbBoolean(sellerAccount.chargesEnabled)) {
      return res.status(409).json({ ok: false, error: "seller_payments_not_ready", onboardingStatus: sellerAccount?.onboardingStatus ?? "NOT_STARTED" });
    }
    const metadata = paymentMetadata(order, sellerAccount.stripeAccountId);
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      client_reference_id: order.id,
      metadata,
      payment_method_types: ["card"],
      payment_intent_data: {
        application_fee_amount: order.oneWayPlatformFeeMinor,
        transfer_data: { destination: sellerAccount.stripeAccountId },
        metadata,
      },
      line_items: order.items.map((item: any) => ({
        price_data: {
          currency: order.currency.toLowerCase(),
          product_data: { name: item.name, images: item.imageUrl ? [item.imageUrl] : [] },
          unit_amount: Math.max(1, Math.round(Number(item.unitPrice ?? 0) * 100)),
        },
        quantity: item.quantity,
      })),
      success_url: process.env.STRIPE_SUCCESS_URL ?? "https://oneway.is/success",
      cancel_url: process.env.STRIPE_CANCEL_URL ?? "https://oneway.is/cancel",
    }, { idempotencyKey: parsed.data.idempotencyKey ?? `checkout:${order.id}` });
    await prisma.order.update({
      where: { id: order.id },
      data: { stripeCheckoutId: String(session.id ?? ""), paymentStatus: "pending_payment", status: "pending_payment", updatedAt: new Date() },
    });
    const payment = await upsertShopPayment(prisma, order, {
      stripeCheckoutSessionId: String(session.id ?? ""),
      connectedAccountId: sellerAccount.stripeAccountId,
      status: "CHECKOUT_CREATED",
      metadataJson: JSON.stringify(metadata),
    });
    await upsertPlatformFee(prisma, order, payment.id, "PENDING");
    res.status(201).json({ ok: true, checkoutSessionId: session.id, checkoutUrl: session.url, payment });
  });

  router.post("/marketplace/refunds", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = refundSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const order = await loadSellerOrBuyerOrder(prisma, parsed.data.orderId, userId);
    if (!order) return res.status(404).json({ ok: false, error: "order_not_found" });
    if (!order.paymentIntentId) return res.status(409).json({ ok: false, error: "order_has_no_payment_intent" });
    const remaining = Math.max(0, order.customerTotalMinor - order.refundedAmountMinor);
    const amount = parsed.data.amountMinor ?? remaining;
    if (amount <= 0 || amount > remaining) return res.status(409).json({ ok: false, error: "invalid_refund_amount", remainingAmountMinor: remaining });
    const refund = await stripe.refunds.create({
      payment_intent: order.paymentIntentId,
      amount,
      reason: parsed.data.reason,
      metadata: {
        orderId: order.id,
        shopId: order.storeId ?? "",
        sellerId: order.sellerId ?? "",
        buyerId: order.userId,
        environment: stripeEnvironment(),
      },
    }, { idempotencyKey: parsed.data.idempotencyKey ?? `refund:${order.id}:${amount}` });
    await upsertRefund(prisma, order, refund, amount, parsed.data.reason ?? null);
    res.status(201).json({ ok: true, refundId: refund.id, status: refund.status ?? "pending", amountMinor: amount });
  });

  router.get("/orders/:orderId/receipt", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const order = await loadSellerOrBuyerOrder(prisma, req.params.orderId, userId);
    if (!order) return res.status(404).json({ ok: false, error: "order_not_found" });
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "ShopPayment" WHERE "orderId" = ? ORDER BY "createdAt" DESC LIMIT 1`, order.id);
    res.json({ ok: true, receipt: receiptDTO(order, rows[0] ?? null) });
  });

  router.get("/admin/search", async (req, res) => {
    const parsed = adminSearchSchema.safeParse(req.query ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    if (!adminAllowed(req as unknown as AuthenticatedRequest)) return res.status(403).json({ ok: false, error: "admin_required" });
    res.json({ ok: true, results: await adminPaymentSearch(prisma, parsed.data.q, parsed.data.type) });
  });

  router.post("/checkouts/quote", async (req, res) => {
    const parsed = z.object({
      subtotalMinor: z.number().int().positive(),
      shippingMinor: z.number().int().min(0).default(0),
      taxMinor: z.number().int().min(0).default(0),
      discountMinor: z.number().int().min(0).default(0),
      currency: z.string().trim().length(3).default("USD"),
    }).safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const ledger = calculateMarketplaceOrderLedger({
      currency: parsed.data.currency,
      subtotalMinor: parsed.data.subtotalMinor,
      shippingAmountMinor: parsed.data.shippingMinor,
      taxAmountMinor: parsed.data.taxMinor,
      discountAmountMinor: parsed.data.discountMinor,
      paymentProcessingFeeMinor: 0,
      paymentStatus: "paid",
    });
    res.json({ ok: true, ledger, marketplaceFee: marketplaceFeeConfiguration() });
  });

  return router;
}

export async function currentSellerAccount(prisma: PrismaClient, userId: string, shopId?: string | null): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "SellerPaymentAccount" WHERE "sellerUserId" = ? AND COALESCE("shopId", '') = COALESCE(?, '') LIMIT 1`,
    userId,
    shopId ?? null,
  );
  return rows[0] ?? null;
}

async function ensureBillingCustomer(prisma: PrismaClient, stripe: any, userId: string, email?: string | null): Promise<any> {
  const existing = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayBillingCustomer" WHERE "userId" = ? LIMIT 1`, userId);
  if (existing[0]) return existing[0];
  const customer = await stripe.customers.create({
    email: email ?? undefined,
    metadata: { oneWayUserId: userId, environment: stripeEnvironment() },
  }, { idempotencyKey: `customer:${userId}` });
  const id = crypto.randomUUID();
  await prisma.$executeRawUnsafe(
    `INSERT INTO "OneWayBillingCustomer" ("id", "userId", "stripeCustomerId", "billingEmail") VALUES (?, ?, ?, ?)`,
    id,
    userId,
    customer.id,
    email ?? null,
  );
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayBillingCustomer" WHERE "id" = ?`, id))[0];
}

async function updateSellerAccountFromStripe(prisma: PrismaClient, stripeAccountId: string, account: Record<string, any>): Promise<void> {
  await prisma.$executeRawUnsafe(
    `UPDATE "SellerPaymentAccount"
     SET "onboardingStatus" = ?, "chargesEnabled" = ?, "payoutsEnabled" = ?, "detailsSubmitted" = ?,
         "requirementsCurrentlyDue" = ?, "requirementsEventuallyDue" = ?, "requirementsPastDue" = ?,
         "disabledReason" = ?, "country" = ?, "defaultCurrency" = ?, "updatedAt" = CURRENT_TIMESTAMP
     WHERE "stripeAccountId" = ?`,
    statusFromStripeAccount(account),
    Boolean(account.charges_enabled),
    Boolean(account.payouts_enabled),
    Boolean(account.details_submitted),
    JSON.stringify(account.requirements?.currently_due ?? []),
    JSON.stringify(account.requirements?.eventually_due ?? []),
    JSON.stringify(account.requirements?.past_due ?? []),
    account.requirements?.disabled_reason ?? null,
    account.country ?? null,
    account.default_currency ?? null,
    stripeAccountId,
  );
}

function sellerAccountDTO(account: any): Record<string, any> {
  return {
    id: account.id,
    shopId: account.shopId,
    stripeAccountId: account.stripeAccountId,
    chargesEnabled: truthyDbBoolean(account.chargesEnabled),
    payoutsEnabled: truthyDbBoolean(account.payoutsEnabled),
    detailsSubmitted: truthyDbBoolean(account.detailsSubmitted),
    onboardingStatus: account.onboardingStatus,
    onboardingCompleted: truthyDbBoolean(account.chargesEnabled) && truthyDbBoolean(account.payoutsEnabled),
    requirements: {
      currentlyDue: jsonArray(account.requirementsCurrentlyDue),
      eventuallyDue: jsonArray(account.requirementsEventuallyDue),
      pastDue: jsonArray(account.requirementsPastDue),
      disabledReason: account.disabledReason,
    },
    country: account.country,
    currency: String(account.defaultCurrency ?? "usd").toUpperCase(),
    currentBank: truthyDbBoolean(account.payoutsEnabled) ? "Managed by Stripe Express" : null,
    updatedAt: account.updatedAt,
  };
}

function sellerPaymentStatus(account: any): string {
  if (truthyDbBoolean(account.chargesEnabled) && truthyDbBoolean(account.payoutsEnabled)) return "ready";
  if (account.disabledReason) return "restricted";
  if (truthyDbBoolean(account.detailsSubmitted)) return "under_review";
  return "setup_required";
}

async function sellerEarningsSummary(prisma: PrismaClient, userId: string): Promise<Record<string, any>> {
  const orderRows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "sellerGrossAmountMinor" ELSE 0 END), 0) AS gross,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "oneWayPlatformFeeMinor" ELSE 0 END), 0) AS oneWayFee,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "paymentProcessingFeeMinor" ELSE 0 END), 0) AS stripeFee,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "sellerNetAmountMinor" ELSE 0 END), 0) AS net,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') AND "payoutStatus" IN ('pending','in_transit') THEN "sellerNetAmountMinor" ELSE 0 END), 0) AS pending,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') AND "payoutStatus" = 'paid' THEN "sellerNetAmountMinor" ELSE 0 END), 0) AS paid,
       COUNT(*) AS orderCount
     FROM "Order" WHERE "sellerId" = ?`,
    userId,
  );
  const row = orderRows[0] ?? {};
  return {
    currency: "USD",
    grossAmountMinor: Number(row.gross ?? 0),
    stripeFeeMinor: Number(row.stripeFee ?? 0),
    oneWayFeeMinor: Number(row.oneWayFee ?? 0),
    netEarningsMinor: Number(row.net ?? 0),
    pendingBalanceMinor: Number(row.pending ?? 0),
    availableBalanceMinor: Math.max(0, Number(row.net ?? 0) - Number(row.pending ?? 0)),
    completedPayoutsMinor: Number(row.paid ?? 0),
    orderCount: Number(row.orderCount ?? 0),
  };
}

async function sellerPayoutRows(prisma: PrismaClient, connectedAccountId: string | null, limit: number): Promise<any[]> {
  if (!connectedAccountId) return [];
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "SellerPayout" WHERE "connectedAccountId" = ? ORDER BY "createdAt" DESC LIMIT ?`,
    connectedAccountId,
    limit,
  );
  return rows.map((row) => ({
    id: row.id,
    stripePayoutId: row.stripePayoutId,
    amountMinor: Number(row.amountMinor ?? 0),
    currency: row.currency,
    status: row.status,
    bank: "Stripe Express payout account",
    estimatedArrival: row.arrivalDate,
    failureCode: row.failureCode,
    failureMessage: row.failureMessage,
    createdAt: row.createdAt,
  }));
}

async function sellerTransactionRows(prisma: PrismaClient, userId: string, limit: number): Promise<any[]> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT o.*, sp."stripePaymentIntentId", sp."stripeCheckoutSessionId", sp."stripeChargeId", sp."status" AS "shopPaymentStatus"
     FROM "Order" o
     LEFT JOIN "ShopPayment" sp ON sp."orderId" = o."id"
     WHERE o."sellerId" = ?
     ORDER BY o."createdAt" DESC LIMIT ?`,
    userId,
    limit,
  );
  return rows.map(paymentOrderDTO);
}

async function buyerPaymentRows(prisma: PrismaClient, userId: string, limit: number): Promise<any[]> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT o.*, sp."stripePaymentIntentId", sp."stripeCheckoutSessionId", sp."stripeChargeId", sp."status" AS "shopPaymentStatus"
     FROM "Order" o
     LEFT JOIN "ShopPayment" sp ON sp."orderId" = o."id"
     WHERE o."userId" = ?
     ORDER BY o."createdAt" DESC LIMIT ?`,
    userId,
    limit,
  );
  return rows.map(paymentOrderDTO);
}

function paymentOrderDTO(row: any): Record<string, any> {
  return {
    id: `payment:${row.id}`,
    orderId: row.id,
    shopId: row.storeId,
    sellerId: row.sellerId,
    buyerId: row.userId,
    grossAmountMinor: Number(row.sellerGrossAmountMinor ?? 0),
    customerTotalMinor: Number(row.customerTotalMinor ?? 0),
    stripeFeeMinor: Number(row.paymentProcessingFeeMinor ?? 0),
    oneWayFeeMinor: Number(row.oneWayPlatformFeeMinor ?? 0),
    netEarningsMinor: Number(row.sellerNetAmountMinor ?? 0),
    refundedAmountMinor: Number(row.refundedAmountMinor ?? 0),
    disputedAmountMinor: Number(row.disputedAmountMinor ?? 0),
    payoutAmountMinor: Number(row.payoutAmountMinor ?? 0),
    currency: row.currency,
    status: row.paymentStatus,
    payoutStatus: row.payoutStatus,
    stripePaymentIntentId: row.stripePaymentIntentId ?? row.paymentIntentId ?? null,
    stripeCheckoutSessionId: row.stripeCheckoutSessionId ?? row.stripeCheckoutId ?? null,
    stripeChargeId: row.stripeChargeId ?? null,
    createdAt: dateString(row.createdAt),
    updatedAt: dateString(row.updatedAt),
  };
}

async function paymentTransactionDetail(prisma: PrismaClient, userId: string, transactionId: string): Promise<Record<string, any> | null> {
  const orderId = transactionId.replace(/^payment:/, "").replace(/^order:/, "").replace(/^seller:/, "");
  const order = await loadSellerOrBuyerOrder(prisma, orderId, userId);
  if (!order) return null;
  const [paymentRows, refundRows, feeRows, disputeRows] = await Promise.all([
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "ShopPayment" WHERE "orderId" = ? ORDER BY "createdAt" DESC`, order.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "Refund" WHERE "orderId" = ? ORDER BY "createdAt" DESC`, order.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "PlatformFee" WHERE "orderId" = ? ORDER BY "createdAt" DESC`, order.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "Dispute" WHERE "orderId" = ? ORDER BY "createdAt" DESC`, order.id),
  ]);
  return {
    ...paymentOrderDTO(order),
    payments: paymentRows.map(redactedPaymentRow),
    refunds: refundRows.map(redactedPaymentRow),
    platformFees: feeRows.map(redactedPaymentRow),
    disputes: disputeRows.map(redactedPaymentRow),
    receipt: receiptDTO(order, paymentRows[0] ?? null),
  };
}

function redactedPaymentRow(row: any): Record<string, any> {
  const copy: Record<string, any> = {};
  for (const [key, value] of Object.entries(row)) {
    if (/secret|clientSecret|card|bank|payloadJson/i.test(key)) continue;
    copy[key] = value instanceof Date ? value.toISOString() : value;
  }
  return copy;
}

function receiptDTO(order: any, payment: any): Record<string, any> {
  return {
    orderId: order.id,
    shopId: order.storeId,
    sellerId: order.sellerId,
    buyerId: order.userId,
    currency: order.currency,
    subtotalMinor: order.subtotalMinor,
    shippingAmountMinor: order.shippingAmountMinor,
    taxAmountMinor: order.taxAmountMinor,
    customerTotalMinor: order.customerTotalMinor,
    grossAmountMinor: order.sellerGrossAmountMinor,
    stripeFeeMinor: order.paymentProcessingFeeMinor,
    oneWayFeeMinor: order.oneWayPlatformFeeMinor,
    sellerNetAmountMinor: order.sellerNetAmountMinor,
    status: order.paymentStatus,
    payoutStatus: order.payoutStatus,
    stripePaymentIntentId: payment?.stripePaymentIntentId ?? order.paymentIntentId ?? null,
    stripeCheckoutSessionId: payment?.stripeCheckoutSessionId ?? order.stripeCheckoutId ?? null,
    issuedAt: dateString(order.updatedAt ?? order.createdAt),
  };
}

function autopayDTO(row: any): Record<string, any> {
  return {
    id: row.id,
    scope: row.scope,
    status: row.status,
    termsVersion: row.termsVersion,
    consentedAt: row.consentedAt,
    revokedAt: row.revokedAt,
    lastUsedAt: row.lastUsedAt,
  };
}

async function enqueuePaymentNotification(
  prisma: PrismaClient,
  userId: string,
  audience: string,
  eventType: string,
  title: string,
  body: string,
  relatedEntityType: string,
  relatedEntityId: string,
  metadata: Record<string, any>,
): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "PaymentNotificationOutbox" ("id", "userId", "audience", "eventType", "title", "body", "relatedEntityType", "relatedEntityId", "metadataJson")
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    crypto.randomUUID(),
    userId,
    audience,
    eventType,
    title,
    body,
    relatedEntityType,
    relatedEntityId,
    JSON.stringify(metadata),
  );
}

async function adminPaymentSearch(prisma: PrismaClient, q: string, type: string): Promise<Record<string, any>> {
  const like = `%${q}%`;
  const include = (name: string) => type === "all" || type === name;
  const results: Record<string, any> = {};
  if (include("orders")) {
    results.orders = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "userId", "sellerId", "storeId", "paymentIntentId", "stripeCheckoutId", "paymentStatus", "payoutStatus", "customerTotalMinor", "currency", "createdAt"
       FROM "Order" WHERE "id" LIKE ? OR "paymentIntentId" LIKE ? OR "stripeCheckoutId" LIKE ? OR "sellerId" LIKE ? LIMIT 25`,
      like, like, like, like,
    );
  }
  if (include("payments")) {
    results.payments = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "orderId", "shopId", "sellerId", "buyerId", "stripePaymentIntentId", "stripeCheckoutSessionId", "stripeChargeId", "connectedAccountId", "amountMinor", "currency", "status", "createdAt"
       FROM "ShopPayment" WHERE "orderId" LIKE ? OR "stripePaymentIntentId" LIKE ? OR "stripeCheckoutSessionId" LIKE ? OR "stripeChargeId" LIKE ? OR "connectedAccountId" LIKE ? LIMIT 25`,
      like, like, like, like, like,
    );
  }
  if (include("refunds")) {
    results.refunds = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "Refund" WHERE "orderId" LIKE ? OR "stripeRefundId" LIKE ? OR "stripePaymentIntentId" LIKE ? LIMIT 25`, like, like, like);
  }
  if (include("payouts")) {
    results.payouts = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "SellerPayout" WHERE "stripePayoutId" LIKE ? OR "connectedAccountId" LIKE ? LIMIT 25`, like, like);
  }
  if (include("disputes")) {
    results.disputes = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "Dispute" WHERE "orderId" LIKE ? OR "stripeDisputeId" LIKE ? OR "stripeChargeId" LIKE ? LIMIT 25`, like, like, like);
  }
  if (include("events")) {
    results.events = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "stripeEventId", "stripeAccountId", "eventType", "livemode", "objectId", "status", "attemptCount", "receivedAt", "processedAt"
       FROM "StripeWebhookEvent" WHERE "stripeEventId" LIKE ? OR "stripeAccountId" LIKE ? OR "objectId" LIKE ? OR "eventType" LIKE ? LIMIT 25`,
      like, like, like, like,
    );
  }
  if (include("accounts")) {
    results.accounts = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id", "sellerUserId", "shopId", "stripeAccountId", "onboardingStatus", "chargesEnabled", "payoutsEnabled", "detailsSubmitted", "country", "defaultCurrency", "updatedAt"
       FROM "SellerPaymentAccount" WHERE "sellerUserId" LIKE ? OR "stripeAccountId" LIKE ? OR "shopId" LIKE ? LIMIT 25`,
      like, like, like,
    );
  }
  return results;
}

async function loadBuyerOrder(prisma: PrismaClient, orderId: string, userId: string): Promise<any | null> {
  return prisma.order.findFirst({ where: { id: orderId, userId } });
}

async function loadBuyerOrderWithItems(prisma: PrismaClient, orderId: string, userId: string): Promise<any | null> {
  return prisma.order.findFirst({ where: { id: orderId, userId }, include: { items: true } });
}

async function loadSellerOrBuyerOrder(prisma: PrismaClient, orderId: string, userId: string): Promise<any | null> {
  return prisma.order.findFirst({
    where: {
      id: orderId,
      OR: [{ userId }, { sellerId: userId }],
    },
  });
}

async function sellerAccountForOrder(prisma: PrismaClient, order: any): Promise<any | null> {
  if (!order.sellerId) return null;
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "SellerPaymentAccount"
     WHERE "sellerUserId" = ? AND COALESCE("shopId", '') IN (COALESCE(?, ''), '')
     ORDER BY CASE WHEN "shopId" IS NULL THEN 1 ELSE 0 END ASC
     LIMIT 1`,
    order.sellerId,
    order.storeId ?? null,
  );
  return rows[0] ?? null;
}

function paymentMetadata(order: any, connectedAccountId: string): Record<string, string> {
  return {
    orderId: order.id,
    shopId: order.storeId ?? "",
    sellerId: order.sellerId ?? "",
    buyerId: order.userId,
    connectedAccountId,
    environment: stripeEnvironment(),
    oneWayPlatformFeeMinor: String(order.oneWayPlatformFeeMinor ?? 0),
  };
}

async function upsertShopPayment(prisma: PrismaClient, order: any, input: {
  stripePaymentIntentId?: string;
  stripeCheckoutSessionId?: string;
  stripeChargeId?: string;
  stripeCustomerId?: string;
  connectedAccountId?: string;
  status: string;
  paymentMethodTypes?: string;
  metadataJson?: string;
}): Promise<any> {
  const id = crypto.randomUUID();
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "ShopPayment" (
      "id", "orderId", "shopId", "sellerId", "buyerId", "stripePaymentIntentId", "stripeCheckoutSessionId",
      "stripeChargeId", "stripeCustomerId", "connectedAccountId", "amountMinor", "currency", "status",
      "paymentMethodTypes", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    id,
    order.id,
    order.storeId ?? null,
    order.sellerId ?? null,
    order.userId,
    input.stripePaymentIntentId || null,
    input.stripeCheckoutSessionId || null,
    input.stripeChargeId || null,
    input.stripeCustomerId || null,
    input.connectedAccountId || null,
    order.customerTotalMinor,
    order.currency,
    input.status,
    input.paymentMethodTypes || null,
    input.metadataJson || null,
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "ShopPayment"
     SET "status" = ?, "stripeChargeId" = COALESCE(?, "stripeChargeId"), "stripeCustomerId" = COALESCE(?, "stripeCustomerId"),
         "connectedAccountId" = COALESCE(?, "connectedAccountId"), "paymentMethodTypes" = COALESCE(?, "paymentMethodTypes"),
         "metadataJson" = COALESCE(?, "metadataJson"), "updatedAt" = CURRENT_TIMESTAMP
     WHERE ("stripePaymentIntentId" IS NOT NULL AND "stripePaymentIntentId" = ?)
        OR ("stripeCheckoutSessionId" IS NOT NULL AND "stripeCheckoutSessionId" = ?)
        OR ("orderId" = ? AND "stripePaymentIntentId" IS NULL AND "stripeCheckoutSessionId" IS NULL)`,
    input.status,
    input.stripeChargeId || null,
    input.stripeCustomerId || null,
    input.connectedAccountId || null,
    input.paymentMethodTypes || null,
    input.metadataJson || null,
    input.stripePaymentIntentId || "",
    input.stripeCheckoutSessionId || "",
    order.id,
  );
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "ShopPayment"
     WHERE ("stripePaymentIntentId" IS NOT NULL AND "stripePaymentIntentId" = ?)
        OR ("stripeCheckoutSessionId" IS NOT NULL AND "stripeCheckoutSessionId" = ?)
        OR "orderId" = ?
     ORDER BY "createdAt" DESC LIMIT 1`,
    input.stripePaymentIntentId || "",
    input.stripeCheckoutSessionId || "",
    order.id,
  );
  return rows[0];
}

async function upsertPlatformFee(prisma: PrismaClient, order: any, shopPaymentId: string | null, status: string, stripeApplicationFeeId?: string | null): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "PlatformFee" ("id", "orderId", "shopPaymentId", "stripeApplicationFeeId", "amountMinor", "currency", "status", "metadataJson")
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    crypto.randomUUID(),
    order.id,
    shopPaymentId,
    stripeApplicationFeeId ?? null,
    order.oneWayPlatformFeeMinor ?? 0,
    order.currency ?? "USD",
    status,
    JSON.stringify({ feeType: marketplaceFeeConfiguration().feeType, feeAmountMinor: marketplaceFeeConfiguration().feeAmountMinor }),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "PlatformFee" SET "shopPaymentId" = COALESCE(?, "shopPaymentId"), "stripeApplicationFeeId" = COALESCE(?, "stripeApplicationFeeId"), "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "orderId" = ? AND "feeType" = 'MARKETPLACE_ORDER_FLAT'`,
    shopPaymentId,
    stripeApplicationFeeId ?? null,
    status,
    order.id,
  );
}

async function upsertRefund(prisma: PrismaClient, order: any, refund: any, amountMinor: number, reason: string | null): Promise<void> {
  const paymentRows = await prisma.$queryRawUnsafe<any[]>(`SELECT "id" FROM "ShopPayment" WHERE "orderId" = ? ORDER BY "createdAt" DESC LIMIT 1`, order.id);
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "Refund" (
      "id", "orderId", "shopPaymentId", "stripeRefundId", "stripePaymentIntentId", "amountMinor", "currency", "status", "reason", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    crypto.randomUUID(),
    order.id,
    paymentRows[0]?.id ?? null,
    refund.id,
    refund.payment_intent ?? order.paymentIntentId ?? null,
    amountMinor,
    order.currency,
    String(refund.status ?? "pending").toUpperCase(),
    reason,
    JSON.stringify({ reason, stripeStatus: refund.status ?? null }),
  );
}

async function upsertSellerAccount(prisma: PrismaClient, userId: string, shopId: string | undefined, account: Record<string, any>): Promise<any> {
  const id = crypto.randomUUID();
  const status = statusFromStripeAccount(account);
  await prisma.$executeRawUnsafe(
    `INSERT INTO "SellerPaymentAccount" (
      "id", "sellerUserId", "shopId", "stripeAccountId", "accountConfiguration", "onboardingStatus",
      "chargesEnabled", "payoutsEnabled", "detailsSubmitted", "requirementsCurrentlyDue",
      "requirementsEventuallyDue", "requirementsPastDue", "disabledReason", "country", "defaultCurrency"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    id,
    userId,
    shopId ?? null,
    account.id,
    JSON.stringify({ type: account.type, businessType: account.business_type }),
    status,
    Boolean(account.charges_enabled),
    Boolean(account.payouts_enabled),
    Boolean(account.details_submitted),
    JSON.stringify(account.requirements?.currently_due ?? []),
    JSON.stringify(account.requirements?.eventually_due ?? []),
    JSON.stringify(account.requirements?.past_due ?? []),
    account.requirements?.disabled_reason ?? null,
    account.country ?? "US",
    account.default_currency ?? "usd",
  );
  return currentSellerAccount(prisma, userId, shopId);
}

function statusFromStripeAccount(account: Record<string, any>): string {
  if (account.charges_enabled && account.payouts_enabled) return "PAYOUTS_ENABLED";
  if (account.charges_enabled) return "PAYMENTS_ENABLED";
  if (account.requirements?.disabled_reason) return "RESTRICTED";
  if (account.requirements?.currently_due?.length) return "INFORMATION_REQUIRED";
  if (account.details_submitted) return "UNDER_REVIEW";
  return "ONBOARDING";
}

function stringQuery(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function jsonArray(value: string | null): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

function truthyDbBoolean(value: boolean | number): boolean {
  return value === true || value === 1;
}

function stringBody(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function stripeEnvironment(): string {
  return (process.env.STRIPE_ENV ?? process.env.STRIPE_ENVIRONMENT ?? (process.env.NODE_ENV === "production" ? "production" : "sandbox")).trim().toLowerCase();
}

function clampNumber(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.min(Math.max(Math.trunc(value), min), max);
}

function dateString(value: unknown): string {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string" && value.trim()) return new Date(value).toISOString();
  return new Date().toISOString();
}

function adminAllowed(req: AuthenticatedRequest): boolean {
  const adminToken = process.env.ONEWAY_PAYMENT_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_LEDGER_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_AUDIT_ADMIN_TOKEN?.trim();
  const header = String((req as any).headers?.authorization ?? "");
  if (adminToken && header === `Bearer ${adminToken}`) return true;
  return process.env.NODE_ENV !== "production";
}
