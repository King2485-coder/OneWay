import type { PrismaClient } from "@prisma/client";
import crypto from "node:crypto";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import { createStripeClient } from "../services/stripe";
import { decidePaymentPolicy } from "../services/payments/PaymentPolicy";
import { ensurePaymentTables } from "../services/payments/PaymentTables";

const setupSchema = z.object({
  scopes: z.array(z.enum(["SELLER_SUBSCRIPTION", "SHOP_CAPACITY", "PRODUCT_CAPACITY", "MONTHLY_SERVICE_FEES", "FAILED_BALANCE_RECOVERY"])).min(1),
  termsVersion: z.string().trim().min(1).max(80).default("2026-07-wallet-autopay-v1"),
  billingEmail: z.string().email().optional(),
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
});

export function billingRouter({ prisma }: { prisma: PrismaClient }): express.Router {
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

  router.get("/service-fees", async (_req, res) => {
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "ServiceFeeDefinition" ORDER BY "createdAt" DESC`);
    res.json({
      ok: true,
      fees: rows.map((row) => ({
        ...row,
        policy: decidePaymentPolicy(row.code),
      })),
    });
  });

  router.get("/invoices", (_req, res) => {
    res.json({ ok: true, invoices: [], message: "Service-fee invoices appear after approved fee definitions generate charges." });
  });

  router.get("/invoices/:invoiceId", (req, res) => {
    res.status(404).json({ ok: false, error: "invoice_not_found", invoiceId: req.params.invoiceId });
  });

  router.post("/invoices/:invoiceId/pay", (_req, res) => {
    res.status(503).json({ ok: false, error: "manual_service_fee_payment_disabled", message: "Manual service-fee payment requires an approved fee and Stripe payment method." });
  });

  router.get("/autopay", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AutopayAuthorization" WHERE "userId" = ? ORDER BY "createdAt" DESC`, userId);
    res.json({ ok: true, autopay: rows, enabled: rows.some((row) => row.status === "ACTIVE") });
  });

  router.post("/autopay/setup", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = setupSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const disallowed = parsed.data.scopes.map((scope) => decidePaymentPolicy(scope)).filter((decision) => decision.appleIAPRequired || !decision.externalCheckoutAllowed);
    if (disallowed.length) {
      res.status(409).json({ ok: false, error: "apple_payment_policy_review_required", decisions: disallowed });
      return;
    }

    const stripe = createStripeClient();
    if (!stripe) return res.status(503).json({ ok: false, error: "stripe_not_configured" });
    const customer = await ensureBillingCustomer(prisma, userId, parsed.data.billingEmail, parsed.data.idempotencyKey);
    const setupIntent = await stripe.setupIntents.create({
      customer: customer.stripeCustomerId,
      usage: "off_session",
      metadata: { oneWayUserId: userId, autopayScopes: parsed.data.scopes.join(",") },
    }, { idempotencyKey: parsed.data.idempotencyKey ?? `autopay-setup:${userId}:${parsed.data.scopes.sort().join(":")}` });

    logger.info({ userId, scopes: parsed.data.scopes }, "AUTOPAY_SETUP_STARTED");
    res.status(201).json({
      ok: true,
      setupIntentId: setupIntent.id,
      clientSecret: setupIntent.client_secret,
      customerId: customer.id,
      scopes: parsed.data.scopes,
      termsVersion: parsed.data.termsVersion,
    });
  });

  router.post("/autopay/confirm", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = z.object({
      stripeCustomerId: z.string().trim().min(1),
      stripePaymentMethodId: z.string().trim().min(1),
      scopes: z.array(z.string().trim().min(1)).min(1),
      termsVersion: z.string().trim().min(1),
    }).safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    for (const scope of parsed.data.scopes) {
      const id = crypto.randomUUID();
      await prisma.$executeRawUnsafe(
        `INSERT INTO "AutopayAuthorization" (
          "id", "userId", "stripeCustomerId", "stripePaymentMethodId", "scope", "status", "termsVersion", "consentedAt"
        ) VALUES (?, ?, ?, ?, ?, 'ACTIVE', ?, CURRENT_TIMESTAMP)`,
        id,
        userId,
        parsed.data.stripeCustomerId,
        parsed.data.stripePaymentMethodId,
        scope,
        parsed.data.termsVersion,
      );
    }
    logger.info({ userId, scopes: parsed.data.scopes }, "AUTOPAY_ENABLED");
    res.json({ ok: true, status: "ACTIVE" });
  });

  router.patch("/autopay/preferences", (_req, res) => {
    res.json({ ok: true, message: "Autopay preferences update endpoint is ready; pass scoped authorizations after SetupIntent confirmation." });
  });

  router.post("/autopay/pause", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await prisma.$executeRawUnsafe(`UPDATE "AutopayAuthorization" SET "status" = 'PAUSED', "updatedAt" = CURRENT_TIMESTAMP WHERE "userId" = ? AND "status" = 'ACTIVE'`, userId);
    logger.info({ userId }, "AUTOPAY_PAUSED");
    res.json({ ok: true, status: "PAUSED" });
  });

  router.post("/autopay/resume", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await prisma.$executeRawUnsafe(`UPDATE "AutopayAuthorization" SET "status" = 'ACTIVE', "updatedAt" = CURRENT_TIMESTAMP WHERE "userId" = ? AND "status" = 'PAUSED'`, userId);
    logger.info({ userId }, "AUTOPAY_RESUMED");
    res.json({ ok: true, status: "ACTIVE" });
  });

  router.delete("/autopay", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await prisma.$executeRawUnsafe(`UPDATE "AutopayAuthorization" SET "status" = 'REVOKED', "revokedAt" = CURRENT_TIMESTAMP, "revokedReason" = 'user_disabled', "updatedAt" = CURRENT_TIMESTAMP WHERE "userId" = ? AND "status" IN ('ACTIVE', 'PAUSED', 'PAYMENT_METHOD_REQUIRED')`, userId);
    logger.info({ userId }, "AUTOPAY_DISABLED");
    res.json({ ok: true, status: "REVOKED" });
  });

  router.get("/subscriptions", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayServiceSubscription" WHERE "userId" = ? ORDER BY "createdAt" DESC`, userId);
    res.json({ ok: true, subscriptions: rows });
  });

  router.post("/subscriptions", (_req, res) => {
    res.status(409).json({ ok: false, error: "apple_payment_policy_review_required", message: "Digital seller subscriptions are gated until Apple payment-policy review is complete." });
  });

  router.patch("/subscriptions/:subscriptionId", (req, res) => {
    res.json({ ok: true, subscriptionId: req.params.subscriptionId, message: "Subscription updates require provider subscription state." });
  });

  router.post("/subscriptions/:subscriptionId/cancel", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await prisma.$executeRawUnsafe(
      `UPDATE "OneWayServiceSubscription" SET "cancelAtPeriodEnd" = true, "updatedAt" = CURRENT_TIMESTAMP WHERE "userId" = ? AND "id" = ?`,
      userId,
      req.params.subscriptionId,
    );
    res.json({ ok: true, subscriptionId: req.params.subscriptionId, cancelAtPeriodEnd: true });
  });

  return router;
}

async function ensureBillingCustomer(prisma: PrismaClient, userId: string, billingEmail?: string, idempotencyKey?: string): Promise<any> {
  const existing = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayBillingCustomer" WHERE "userId" = ? LIMIT 1`, userId);
  if (existing[0]) return existing[0];
  const stripe = createStripeClient();
  if (!stripe) throw new Error("stripe_not_configured");
  const customer = await stripe.customers.create({
    email: billingEmail,
    metadata: { oneWayUserId: userId },
  }, { idempotencyKey: idempotencyKey ?? `billing-customer:${userId}` });
  const id = crypto.randomUUID();
  await prisma.$executeRawUnsafe(
    `INSERT INTO "OneWayBillingCustomer" ("id", "userId", "stripeCustomerId", "billingEmail") VALUES (?, ?, ?, ?)`,
    id,
    userId,
    customer.id,
    billingEmail ?? null,
  );
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayBillingCustomer" WHERE "id" = ?`, id))[0];
}
