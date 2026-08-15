import type { PrismaClient } from "@prisma/client";
import express from "express";

import { logger } from "../lib/logger";
import { authMiddleware } from "../middleware/auth";
import { LedgerBalanceService } from "../services/ledger/LedgerBalanceService";
import { ensurePaymentTables } from "../services/payments/PaymentTables";
import { createStripeClient } from "../services/stripe";
import { handleAdsPaymentIntentFailed, handleAdsPaymentIntentSucceeded, handleAdsRefundOrDispute } from "../services/ads/AdsBilling";
import { processServiceOrderStripeEvent } from "../services/billing/ServiceOrderWebhook";

type StripeEvent = Record<string, any>;

const supportedEvents = new Set([
  "payment_intent.created",
  "payment_intent.processing",
  "payment_intent.succeeded",
  "payment_intent.payment_failed",
  "payment_intent.canceled",
  "charge.succeeded",
  "charge.failed",
  "charge.refunded",
  "charge.refund.updated",
  "refund.created",
  "refund.updated",
  "refund.failed",
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
  "checkout.session.async_payment_failed",
  "account.updated",
  "account.application.deauthorized",
  "capability.updated",
  "person.created",
  "person.updated",
  "person.deleted",
  "transfer.created",
  "transfer.updated",
  "transfer.paid",
  "transfer.failed",
  "transfer.reversed",
  "application_fee.created",
  "application_fee.refunded",
  "application_fee.refund.updated",
  "payout.created",
  "payout.updated",
  "payout.paid",
  "payout.failed",
  "payout.canceled",
  "charge.dispute.created",
  "charge.dispute.updated",
  "charge.dispute.closed",
  "charge.dispute.funds_withdrawn",
  "charge.dispute.funds_reinstated",
  "customer.created",
  "customer.updated",
  "customer.deleted",
  "payment_method.attached",
  "payment_method.detached",
  "setup_intent.succeeded",
  "setup_intent.setup_failed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "customer.subscription.paused",
  "customer.subscription.resumed",
  "invoice.created",
  "invoice.finalized",
  "invoice.paid",
  "invoice.payment_failed",
  "invoice.payment_action_required",
  "invoice.voided",
]);

export function stripeWebhooksRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();

  router.get("/health", authMiddleware, async (_req, res) => {
    try {
      await ensurePaymentTables(prisma);
      const lastRows = await prisma.$queryRawUnsafe<Array<{ processedAt: string | Date | null }>>(
        `SELECT "processedAt" FROM "StripeWebhookEvent" WHERE "processedAt" IS NOT NULL ORDER BY "processedAt" DESC LIMIT 1`,
      );
      const failedRows = await prisma.$queryRawUnsafe<Array<{ count: number | bigint }>>(
        `SELECT COUNT(*) AS count FROM "StripeWebhookEvent" WHERE "status" = 'FAILED'`,
      );
      res.json({
        ok: true,
        configured: Boolean(process.env.STRIPE_SECRET_KEY?.trim() && process.env.STRIPE_WEBHOOK_SECRET?.trim()),
        environment: stripeEnvironment(),
        databaseConnectivity: true,
        lastProcessedEventAt: lastRows[0]?.processedAt ? new Date(lastRows[0].processedAt).toISOString() : null,
        failedEventCount: Number(failedRows[0]?.count ?? 0),
        webhookRoutePath: "/api/stripe/webhooks",
        receivesConnectedAccountEvents: true,
      });
    } catch (error) {
      res.status(500).json({
        ok: false,
        configured: Boolean(process.env.STRIPE_SECRET_KEY?.trim() && process.env.STRIPE_WEBHOOK_SECRET?.trim()),
        environment: stripeEnvironment(),
        databaseConnectivity: false,
        webhookRoutePath: "/api/stripe/webhooks",
      });
    }
  });

  router.post("/", async (req, res) => {
    await handleStripeWebhook(req, res, prisma);
  });

  // Compatibility with the earlier mount at /api/webhooks/stripe.
  router.post("/stripe", async (req, res) => {
    await handleStripeWebhook(req, res, prisma);
  });

  return router;
}

async function handleStripeWebhook(req: express.Request, res: express.Response, prisma: PrismaClient): Promise<void> {
  const startedAt = Date.now();
  await ensurePaymentTables(prisma);
  const stripe = createStripeClient();
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET?.trim();
  const signature = req.headers["stripe-signature"];

  if (typeof signature !== "string" || signature.trim() === "") {
    logger.warn({ event: "PAYMENT_WEBHOOK_SIGNATURE_REJECTED", reason: "missing_signature" }, "PAYMENT_WEBHOOK_SIGNATURE_REJECTED");
    res.status(400).json({ ok: false, error: "missing_stripe_signature" });
    return;
  }
  if (!stripe || !webhookSecret) {
    res.status(503).json({ ok: false, error: "stripe_webhook_not_configured" });
    return;
  }

  let event: StripeEvent;
  try {
    event = stripe.webhooks.constructEvent(rawBody(req), signature, webhookSecret);
  } catch (error) {
    logger.warn({ err: error }, "PAYMENT_WEBHOOK_SIGNATURE_REJECTED");
    res.status(400).json({ ok: false, error: "invalid_stripe_signature" });
    return;
  }

  const stripeEventId = String(event.id ?? "");
  const eventType = String(event.type ?? "unknown");
  const connectedAccountId = typeof event.account === "string" ? event.account : null;
  const object = event.data?.object ?? {};
  const objectId = typeof object.id === "string" ? object.id : null;

  if (!stripeEventId) {
    res.status(400).json({ ok: false, error: "missing_event_id" });
    return;
  }

  const livemode = Boolean(event.livemode);
  if (!eventMatchesEnvironment(livemode)) {
    logger.warn({ stripeEventId, eventType, livemode, environment: stripeEnvironment() }, "PAYMENT_WEBHOOK_ENVIRONMENT_REJECTED");
    res.status(400).json({ ok: false, error: "stripe_environment_mismatch" });
    return;
  }

  const persisted = await persistEvent(prisma, event, {
    stripeEventId,
    eventType,
    connectedAccountId,
    objectId,
    livemode,
  });
  if (persisted.duplicate) {
    logger.info({ stripeEventId, eventType, connectedAccountId }, "PAYMENT_WEBHOOK_DUPLICATE_IGNORED");
    res.json({ ok: true, duplicate: true });
    return;
  }

  logger.info({ stripeEventId, eventType, connectedAccountId, objectId }, "PAYMENT_WEBHOOK_RECEIVED");

  try {
    if (supportedEvents.has(eventType)) {
      await processStripeEvent(prisma, event);
      await markEvent(prisma, stripeEventId, "PROCESSED", null);
      logger.info({ stripeEventId, eventType, connectedAccountId, duration: Date.now() - startedAt }, "PAYMENT_WEBHOOK_PROCESSED");
    } else {
      await markEvent(prisma, stripeEventId, "IGNORED", null);
      logger.info({ stripeEventId, eventType, connectedAccountId }, "PAYMENT_WEBHOOK_IGNORED");
    }
    res.json({ ok: true, received: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : "webhook_processing_failed";
    await markEvent(prisma, stripeEventId, "FAILED", message.slice(0, 500));
    logger.error({ err: error, stripeEventId, eventType, connectedAccountId }, "PAYMENT_WEBHOOK_FAILED");
    // Event was durably accepted. Internal retry/reconciliation can process FAILED events.
    res.json({ ok: true, received: true, processingStatus: "FAILED" });
  }
}

async function processStripeEvent(prisma: PrismaClient, event: StripeEvent): Promise<void> {
  const type = String(event.type ?? "");
  const object = event.data?.object ?? {};
  if (await processServiceOrderStripeEvent(prisma, event)) return;
  switch (type) {
    case "account.updated":
      await handleAccountUpdated(prisma, object);
      return;
    case "account.application.deauthorized":
      await handleAccountDeauthorized(prisma, object);
      return;
    case "payment_intent.succeeded":
      await handlePaymentIntentSucceeded(prisma, event, object);
      return;
    case "payment_intent.created":
    case "payment_intent.processing":
      await handlePaymentIntentProgress(prisma, object, type);
      return;
    case "payment_intent.payment_failed":
    case "payment_intent.canceled":
      await handlePaymentIntentFailure(prisma, object, type);
      return;
    case "charge.succeeded":
    case "charge.failed":
      await handleChargeEvent(prisma, object, type);
      return;
    case "application_fee.created":
    case "application_fee.refunded":
    case "application_fee.refund.updated":
      await handleApplicationFeeEvent(prisma, object, type);
      return;
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded":
    case "checkout.session.async_payment_failed":
      await handleCheckoutSession(prisma, object, type);
      return;
    case "charge.refunded":
    case "refund.created":
    case "refund.updated":
    case "refund.failed":
      await handleRefundEvent(prisma, object, type);
      return;
    case "payout.created":
    case "payout.updated":
    case "payout.paid":
    case "payout.failed":
    case "payout.canceled":
      await handlePayoutEvent(prisma, event, object, type);
      return;
    case "transfer.created":
    case "transfer.updated":
    case "transfer.paid":
    case "transfer.failed":
    case "transfer.reversed":
      await handleTransferEvent(prisma, event, object, type);
      return;
    case "charge.dispute.created":
    case "charge.dispute.updated":
    case "charge.dispute.closed":
    case "charge.dispute.funds_withdrawn":
    case "charge.dispute.funds_reinstated":
      await handleDisputeEvent(prisma, object, type);
      return;
    case "invoice.paid":
    case "invoice.payment_failed":
    case "invoice.payment_action_required":
    case "invoice.voided":
    case "invoice.finalized":
    case "invoice.created":
      await handleInvoiceEvent(prisma, object, type);
      return;
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
    case "customer.subscription.paused":
    case "customer.subscription.resumed":
      await handleSubscriptionEvent(prisma, object, type);
      return;
    default:
      return;
  }
}

async function handleAccountUpdated(prisma: PrismaClient, account: Record<string, any>): Promise<void> {
  const stripeAccountId = String(account.id ?? "");
  if (!stripeAccountId) return;
  const onboardingStatus = sellerStatusFromAccount(account);
  await prisma.$executeRawUnsafe(
    `UPDATE "SellerPaymentAccount"
     SET "onboardingStatus" = ?, "chargesEnabled" = ?, "payoutsEnabled" = ?, "detailsSubmitted" = ?,
         "requirementsCurrentlyDue" = ?, "requirementsEventuallyDue" = ?, "requirementsPastDue" = ?,
         "disabledReason" = ?, "country" = ?, "defaultCurrency" = ?, "updatedAt" = CURRENT_TIMESTAMP
     WHERE "stripeAccountId" = ?`,
    onboardingStatus,
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
  logger.info({ stripeAccountId, onboardingStatus }, "PAYMENT_SELLER_STATUS_UPDATED");
}

async function handleAccountDeauthorized(prisma: PrismaClient, account: Record<string, any>): Promise<void> {
  const stripeAccountId = String(account.id ?? account.account ?? "");
  if (!stripeAccountId) return;
  await prisma.$executeRawUnsafe(
    `UPDATE "SellerPaymentAccount"
     SET "onboardingStatus" = 'DISABLED', "chargesEnabled" = false, "payoutsEnabled" = false, "disabledReason" = 'application_deauthorized', "updatedAt" = CURRENT_TIMESTAMP
     WHERE "stripeAccountId" = ?`,
    stripeAccountId,
  );
}

async function handlePaymentIntentSucceeded(prisma: PrismaClient, event: StripeEvent, intent: Record<string, any>): Promise<void> {
  if (await handleAdsPaymentIntentSucceeded(prisma, event, intent)) return;
  const orderId = safeMetadata(intent, "orderId");
  if (!orderId) return;
  const rows = await prisma.order.findMany({ where: { id: orderId }, take: 1 });
  const order = rows[0];
  if (!order) throw new Error("order_not_found");
  const amount = Number(intent.amount_received ?? intent.amount ?? 0);
  const currency = String(intent.currency ?? "").toUpperCase();
  if (amount !== order.customerTotalMinor || currency !== order.currency.toUpperCase()) {
    throw new Error("payment_intent_order_amount_mismatch");
  }
  if (["paid", "captured"].includes(order.paymentStatus)) return;

  await prisma.$transaction(async (tx) => {
    await tx.order.update({
      where: { id: order.id },
      data: {
        status: "paid",
        paymentStatus: "paid",
        payoutStatus: "pending",
        paymentIntentId: String(intent.id ?? order.paymentIntentId ?? ""),
        updatedAt: new Date(),
      },
    });
    await tx.$executeRawUnsafe(
      `UPDATE "ShopPayment"
       SET "status" = 'SUCCEEDED', "stripeChargeId" = COALESCE(?, "stripeChargeId"), "stripeCustomerId" = COALESCE(?, "stripeCustomerId"), "updatedAt" = CURRENT_TIMESTAMP
       WHERE "stripePaymentIntentId" = ? OR "orderId" = ?`,
      String(intent.latest_charge ?? ""),
      String(intent.customer ?? ""),
      String(intent.id ?? ""),
      order.id,
    );
    await tx.$executeRawUnsafe(
      `UPDATE "PlatformFee" SET "status" = 'EARNED', "updatedAt" = CURRENT_TIMESTAMP WHERE "orderId" = ?`,
      order.id,
    );
  });

  if (order.sellerId && order.sellerNetAmountMinor > 0) {
    const ledger = new LedgerBalanceService(prisma);
    await ledger.postLedgerTransaction({
      accountId: `wallet:${order.sellerId}:seller`,
      amountCents: order.sellerNetAmountMinor,
      type: "storefront_payment",
      direction: "credit",
      currency: order.currency,
      externalId: `stripe:${event.id}:seller:${order.id}`,
      metadata: {
        orderId: order.id,
        stripePaymentIntentId: intent.id,
        oneWayPlatformFeeMinor: order.oneWayPlatformFeeMinor,
        paymentProcessingFeeMinor: order.paymentProcessingFeeMinor,
      },
    });
  }
  logger.info({ orderId: order.id, stripePaymentIntentId: intent.id }, "PAYMENT_SUCCEEDED");
}

async function handlePaymentIntentProgress(prisma: PrismaClient, intent: Record<string, any>, type: string): Promise<void> {
  const orderId = safeMetadata(intent, "orderId");
  if (!orderId) return;
  await prisma.order.updateMany({
    where: { id: orderId, paymentStatus: { notIn: ["paid", "captured", "refunded"] } },
    data: {
      paymentIntentId: String(intent.id ?? ""),
      paymentStatus: type === "payment_intent.processing" ? "processing" : "created",
      status: type === "payment_intent.processing" ? "processing" : "created",
      updatedAt: new Date(),
    },
  });
  await prisma.$executeRawUnsafe(
    `UPDATE "ShopPayment" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripePaymentIntentId" = ? OR "orderId" = ?`,
    type === "payment_intent.processing" ? "PROCESSING" : "CREATED",
    String(intent.id ?? ""),
    orderId,
  );
}

async function handlePaymentIntentFailure(prisma: PrismaClient, intent: Record<string, any>, type: string): Promise<void> {
  if (await handleAdsPaymentIntentFailed(prisma, { id: `${type}:${String(intent.id ?? "")}`, type }, intent)) return;
  const orderId = safeMetadata(intent, "orderId");
  if (!orderId) return;
  await prisma.order.updateMany({
    where: { id: orderId, paymentStatus: { notIn: ["paid", "captured", "refunded"] } },
    data: {
      paymentStatus: type === "payment_intent.canceled" ? "canceled" : "failed",
      status: type === "payment_intent.canceled" ? "canceled" : "payment_failed",
      updatedAt: new Date(),
    },
  });
  await prisma.$executeRawUnsafe(
    `UPDATE "ShopPayment" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripePaymentIntentId" = ? OR "orderId" = ?`,
    type === "payment_intent.canceled" ? "CANCELED" : "FAILED",
    String(intent.id ?? ""),
    orderId,
  );
  logger.info({ orderId, stripePaymentIntentId: intent.id, type }, "PAYMENT_FAILED");
}

async function handleCheckoutSession(prisma: PrismaClient, session: Record<string, any>, type: string): Promise<void> {
  const orderId = safeMetadata(session, "orderId") ?? String(session.client_reference_id ?? "");
  if (!orderId) return;
  const paymentStatus = String(session.payment_status ?? "");
  const nextStatus = type.endsWith("failed") ? "failed" : paymentStatus === "paid" ? "paid" : "pending_payment";
  await prisma.order.updateMany({
    where: { id: orderId, paymentStatus: { notIn: ["paid", "captured", "refunded"] } },
    data: { paymentStatus: nextStatus, status: nextStatus, updatedAt: new Date() },
  });
  await prisma.$executeRawUnsafe(
    `UPDATE "ShopPayment" SET "status" = ?, "stripePaymentIntentId" = COALESCE(?, "stripePaymentIntentId"), "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeCheckoutSessionId" = ? OR "orderId" = ?`,
    nextStatus.toUpperCase(),
    String(session.payment_intent ?? "") || null,
    String(session.id ?? ""),
    orderId,
  );
}

async function handleChargeEvent(prisma: PrismaClient, charge: Record<string, any>, type: string): Promise<void> {
  const orderId = safeMetadata(charge, "orderId");
  const paymentIntentId = String(charge.payment_intent ?? "");
  await prisma.$executeRawUnsafe(
    `UPDATE "ShopPayment"
     SET "status" = ?, "stripeChargeId" = ?, "updatedAt" = CURRENT_TIMESTAMP
     WHERE ("stripePaymentIntentId" IS NOT NULL AND "stripePaymentIntentId" = ?) OR ("orderId" = ?)`,
    type === "charge.failed" ? "CHARGE_FAILED" : "CHARGE_SUCCEEDED",
    String(charge.id ?? ""),
    paymentIntentId,
    orderId ?? "",
  );
  await persistProviderEventMetadata(prisma, { id: charge.id, type }, "ShopPayment", orderId ?? paymentIntentId, type);
}

async function handleApplicationFeeEvent(prisma: PrismaClient, fee: Record<string, any>, type: string): Promise<void> {
  const orderId = safeMetadata(fee, "orderId");
  if (!orderId) {
    await persistProviderEventMetadata(prisma, { id: fee.id, type }, "PlatformFee", String(fee.id ?? ""), type);
    return;
  }
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "PlatformFee" (
      "id", "orderId", "shopPaymentId", "stripeApplicationFeeId", "amountMinor", "currency", "status", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    cryptoRandomId(),
    orderId,
    null,
    String(fee.id ?? ""),
    Number(fee.amount ?? 0),
    String(fee.currency ?? "usd").toUpperCase(),
    type === "application_fee.refunded" || type === "application_fee.refund.updated" ? "REFUNDED" : "EARNED",
    JSON.stringify(redactPayload(fee)),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "PlatformFee" SET "stripeApplicationFeeId" = ?, "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "orderId" = ?`,
    String(fee.id ?? ""),
    type === "application_fee.refunded" || type === "application_fee.refund.updated" ? "REFUNDED" : "EARNED",
    orderId,
  );
  await persistProviderEventMetadata(prisma, { id: fee.id, type }, "PlatformFee", String(fee.id ?? ""), type);
}

async function handleRefundEvent(prisma: PrismaClient, object: Record<string, any>, type: string): Promise<void> {
  if (await handleAdsRefundOrDispute(prisma, { id: `${type}:${String(object.id ?? "")}`, type }, object)) return;
  const orderId = safeMetadata(object, "orderId");
  const paymentIntentId = String(object.payment_intent ?? "");
  const amount = Number(object.amount ?? 0);
  if (!orderId && !paymentIntentId) return;
  const where = orderId ? { id: orderId } : { paymentIntentId };
  const rows = await prisma.order.findMany({ where, take: 1 });
  const order = rows[0];
  if (!order) return;
  const nextRefunded = Math.min(order.customerTotalMinor, Math.max(order.refundedAmountMinor, amount || order.refundedAmountMinor));
  await prisma.order.update({
    where: { id: order.id },
    data: {
      refundedAmountMinor: nextRefunded,
      paymentStatus: nextRefunded >= order.customerTotalMinor ? "refunded" : "partially_refunded",
      status: nextRefunded >= order.customerTotalMinor ? "refunded" : "partially_refunded",
      updatedAt: new Date(),
    },
  });
  const paymentRows = await prisma.$queryRawUnsafe<any[]>(`SELECT "id" FROM "ShopPayment" WHERE "orderId" = ? ORDER BY "createdAt" DESC LIMIT 1`, order.id);
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "Refund" (
      "id", "orderId", "shopPaymentId", "stripeRefundId", "stripePaymentIntentId", "amountMinor", "currency", "status", "reason", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    cryptoRandomId(),
    order.id,
    paymentRows[0]?.id ?? null,
    String(object.id ?? `refund:${type}:${order.id}`),
    paymentIntentId || order.paymentIntentId || null,
    amount || nextRefunded,
    order.currency,
    type === "refund.failed" ? "FAILED" : String(object.status ?? "SUCCEEDED").toUpperCase(),
    object.reason ?? null,
    JSON.stringify(redactPayload(object)),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "Refund" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeRefundId" = ?`,
    type === "refund.failed" ? "FAILED" : String(object.status ?? "SUCCEEDED").toUpperCase(),
    String(object.id ?? `refund:${type}:${order.id}`),
  );
  logger.info({ orderId: order.id, refundId: object.id, type, refundedAmountMinor: nextRefunded }, type === "refund.failed" ? "PAYMENT_REFUND_FAILED" : "PAYMENT_REFUND_COMPLETED");
}

async function handlePayoutEvent(prisma: PrismaClient, event: StripeEvent, payout: Record<string, any>, type: string): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "SellerPayout" (
      "id", "stripePayoutId", "connectedAccountId", "amountMinor", "currency", "arrivalDate", "status", "failureCode", "failureMessage", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    cryptoRandomId(),
    String(payout.id ?? ""),
    typeof event.account === "string" ? event.account : null,
    Number(payout.amount ?? 0),
    String(payout.currency ?? "usd").toUpperCase(),
    payout.arrival_date ? new Date(Number(payout.arrival_date) * 1000).toISOString() : null,
    String(payout.status ?? type).toUpperCase(),
    payout.failure_code ?? null,
    payout.failure_message ?? null,
    JSON.stringify(redactPayload(payout)),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "SellerPayout" SET "status" = ?, "failureCode" = ?, "failureMessage" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripePayoutId" = ?`,
    String(payout.status ?? type).toUpperCase(),
    payout.failure_code ?? null,
    payout.failure_message ?? null,
    String(payout.id ?? ""),
  );
  await persistProviderEventMetadata(prisma, event, "SellerPayout", String(payout.id ?? ""), type);
  logger.info({ payoutId: payout.id, connectedAccountId: event.account, type }, type === "payout.failed" ? "PAYMENT_PAYOUT_FAILED" : "PAYMENT_PAYOUT_COMPLETED");
}

async function handleTransferEvent(prisma: PrismaClient, event: StripeEvent, transfer: Record<string, any>, type: string): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "Transfer" (
      "id", "orderId", "shopPaymentId", "stripeTransferId", "connectedAccountId", "amountMinor", "currency", "status", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    cryptoRandomId(),
    safeMetadata(transfer, "orderId"),
    null,
    String(transfer.id ?? ""),
    String(transfer.destination ?? event.account ?? ""),
    Number(transfer.amount ?? 0),
    String(transfer.currency ?? "usd").toUpperCase(),
    String(transfer.reversed ? "REVERSED" : transfer.status ?? type).toUpperCase(),
    JSON.stringify(redactPayload(transfer)),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "Transfer" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeTransferId" = ?`,
    String(transfer.reversed ? "REVERSED" : transfer.status ?? type).toUpperCase(),
    String(transfer.id ?? ""),
  );
  await persistProviderEventMetadata(prisma, event, "SellerTransfer", String(transfer.id ?? ""), type);
  logger.info({ transferId: transfer.id, connectedAccountId: event.account, type }, "PAYMENT_TRANSFER_UPDATED");
}

async function handleDisputeEvent(prisma: PrismaClient, dispute: Record<string, any>, type: string): Promise<void> {
  if (await handleAdsRefundOrDispute(prisma, { id: `${type}:${String(dispute.id ?? "")}`, type }, dispute)) return;
  const orderId = safeMetadata(dispute, "orderId");
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "Dispute" (
      "id", "orderId", "stripeDisputeId", "stripeChargeId", "amountMinor", "currency", "status", "reason", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    cryptoRandomId(),
    orderId,
    String(dispute.id ?? ""),
    String(dispute.charge ?? ""),
    Number(dispute.amount ?? 0),
    String(dispute.currency ?? "usd").toUpperCase(),
    String(dispute.status ?? type).toUpperCase(),
    dispute.reason ?? null,
    JSON.stringify(redactPayload(dispute)),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "Dispute" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeDisputeId" = ?`,
    String(dispute.status ?? type).toUpperCase(),
    String(dispute.id ?? ""),
  );
  await persistProviderEventMetadata(prisma, { id: dispute.id, type }, "PaymentDispute", String(dispute.id ?? ""), type);
  logger.info({ disputeId: dispute.id, type, amount: dispute.amount, status: dispute.status }, "PAYMENT_DISPUTE_UPDATED");
}

async function handleInvoiceEvent(prisma: PrismaClient, invoice: Record<string, any>, type: string): Promise<void> {
  const subscriptionId = String(invoice.subscription ?? "");
  const stripeCustomerId = String(invoice.customer ?? "");
  const customerRows = stripeCustomerId
    ? await prisma.$queryRawUnsafe<any[]>(`SELECT "userId" FROM "OneWayBillingCustomer" WHERE "stripeCustomerId" = ? LIMIT 1`, stripeCustomerId)
    : [];
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "Invoice" (
      "id", "stripeInvoiceId", "stripeCustomerId", "stripeSubscriptionId", "userId", "amountDueMinor", "amountPaidMinor",
      "currency", "status", "hostedInvoiceUrl", "metadataJson"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    cryptoRandomId(),
    String(invoice.id ?? ""),
    stripeCustomerId || null,
    subscriptionId || null,
    customerRows[0]?.userId ?? null,
    Number(invoice.amount_due ?? 0),
    Number(invoice.amount_paid ?? 0),
    String(invoice.currency ?? "usd").toUpperCase(),
    String(invoice.status ?? type).toUpperCase(),
    invoice.hosted_invoice_url ?? null,
    JSON.stringify(redactPayload(invoice)),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "Invoice" SET "status" = ?, "amountPaidMinor" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeInvoiceId" = ?`,
    String(invoice.status ?? type).toUpperCase(),
    Number(invoice.amount_paid ?? 0),
    String(invoice.id ?? ""),
  );
  if (subscriptionId && type === "invoice.paid") {
    await prisma.$executeRawUnsafe(
      `UPDATE "OneWayServiceSubscription" SET "status" = 'ACTIVE', "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
      subscriptionId,
    );
  } else if (subscriptionId && type === "invoice.payment_failed") {
    await prisma.$executeRawUnsafe(
      `UPDATE "OneWayServiceSubscription" SET "status" = 'PAST_DUE', "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
      subscriptionId,
    );
  }
  logger.info({ invoiceId: invoice.id, subscriptionId, type }, type === "invoice.paid" ? "SERVICE_INVOICE_PAID" : "SERVICE_INVOICE_UPDATED");
}

async function handleSubscriptionEvent(prisma: PrismaClient, subscription: Record<string, any>, type: string): Promise<void> {
  const status = type === "customer.subscription.deleted" ? "CANCELED" : String(subscription.status ?? "UNKNOWN").toUpperCase();
  await prisma.$executeRawUnsafe(
    `UPDATE "OneWayServiceSubscription" SET "status" = ?, "cancelAtPeriodEnd" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
    status,
    Boolean(subscription.cancel_at_period_end),
    String(subscription.id ?? ""),
  );
}

async function persistEvent(
  prisma: PrismaClient,
  event: StripeEvent,
  metadata: { stripeEventId: string; eventType: string; connectedAccountId: string | null; objectId: string | null; livemode: boolean },
): Promise<{ duplicate: boolean }> {
  const safePayload = JSON.stringify(redactPayload(event)).slice(0, 200_000);
  const inserted = await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "StripeWebhookEvent" (
      "id", "stripeEventId", "stripeAccountId", "eventType", "apiVersion", "livemode", "objectId", "payloadJson", "status", "attemptCount"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'RECEIVED', 1)`,
    cryptoRandomId(),
    metadata.stripeEventId,
    metadata.connectedAccountId,
    metadata.eventType,
    event.api_version ?? null,
    metadata.livemode,
    metadata.objectId,
    safePayload,
  );
  if (Number(inserted) === 0) {
    await prisma.$executeRawUnsafe(
      `UPDATE "StripeWebhookEvent" SET "attemptCount" = "attemptCount" + 1, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeEventId" = ?`,
      metadata.stripeEventId,
    );
    return { duplicate: true };
  }
  return { duplicate: false };
}

async function markEvent(prisma: PrismaClient, stripeEventId: string, status: "PROCESSED" | "IGNORED" | "FAILED", lastError: string | null): Promise<void> {
  await prisma.$executeRawUnsafe(
    `UPDATE "StripeWebhookEvent" SET "status" = ?, "lastError" = ?, "processedAt" = CURRENT_TIMESTAMP, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeEventId" = ?`,
    status,
    lastError,
    stripeEventId,
  );
}

async function persistProviderEventMetadata(prisma: PrismaClient, event: StripeEvent, entityType: string, entityId: string, status: string): Promise<void> {
  const stripeEventId = String(event.id ?? `${entityType}:${entityId}:${status}`);
  await prisma.$executeRawUnsafe(
    `UPDATE "StripeWebhookEvent" SET "relatedEntityType" = ?, "relatedEntityId" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeEventId" = ?`,
    entityType,
    entityId || null,
    stripeEventId,
  );
}

function rawBody(req: express.Request): Buffer {
  if (Buffer.isBuffer(req.body)) return req.body;
  if (Buffer.isBuffer((req as any).rawBody)) return (req as any).rawBody;
  return Buffer.from(typeof req.body === "string" ? req.body : JSON.stringify(req.body ?? {}));
}

function eventMatchesEnvironment(livemode: boolean): boolean {
  const env = stripeEnvironment();
  if (env === "production" || env === "live") return livemode;
  if (env === "sandbox" || env === "test" || env === "development" || env === "local") return !livemode;
  return true;
}

function stripeEnvironment(): string {
  return (process.env.STRIPE_ENV ?? (process.env.NODE_ENV === "production" ? "production" : "sandbox")).trim().toLowerCase();
}

function sellerStatusFromAccount(account: Record<string, any>): string {
  if (account.charges_enabled && account.payouts_enabled) return "PAYOUTS_ENABLED";
  if (account.charges_enabled) return "PAYMENTS_ENABLED";
  if (account.requirements?.disabled_reason) return "RESTRICTED";
  if (account.requirements?.currently_due?.length) return "INFORMATION_REQUIRED";
  if (account.details_submitted) return "UNDER_REVIEW";
  return "ONBOARDING";
}

function safeMetadata(object: Record<string, any>, key: string): string | null {
  const value = object.metadata?.[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function redactPayload(value: any): any {
  if (Array.isArray(value)) return value.map(redactPayload);
  if (!value || typeof value !== "object") return value;
  const redacted: Record<string, any> = {};
  for (const [key, child] of Object.entries(value)) {
    const lower = key.toLowerCase();
    if (lower.includes("secret") || lower.includes("client_secret") || lower.includes("number") || lower === "cvc" || lower === "fingerprint") {
      redacted[key] = "[REDACTED]";
    } else {
      redacted[key] = redactPayload(child);
    }
  }
  return redacted;
}

function cryptoRandomId(): string {
  return `swe_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}
