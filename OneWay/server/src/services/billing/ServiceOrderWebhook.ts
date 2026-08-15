import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { logger } from "../../lib/logger";
import { grantEntitlement, revokeOrderEntitlements } from "./EntitlementService";
import { resolveOneWayProduct } from "./OneWayProductRegistry";
import { ensureServiceOrderTables } from "./ServiceOrderTables";

type StripeEvent = Record<string, any>;

export async function processServiceOrderStripeEvent(prisma: PrismaClient, event: StripeEvent): Promise<boolean> {
  await ensureServiceOrderTables(prisma);
  const type = String(event.type ?? "");
  const object = event.data?.object ?? {};
  const orderId = metadata(object, "oneway_order_id") || await orderIdForObject(prisma, object);
  const subscriptionId = stripeId(object.subscription) || stripeId(object.parent?.subscription_details?.subscription) || stripeId(object.id, "sub_");
  const knownSubscription = subscriptionId ? await subscriptionRow(prisma, subscriptionId) : null;
  const serviceEvent = Boolean(orderId || knownSubscription);
  if (!serviceEvent) return false;

  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "BillingWebhookEvent" ("stripeEventId", "eventType", "status", "orderId")
     VALUES (?, ?, 'PROCESSING', ?)`,
    String(event.id), type, orderId,
  );

  try {
    switch (type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded":
        if (!orderId) return false;
        await completeCheckout(prisma, orderId, object, type);
        break;
      case "checkout.session.async_payment_failed":
        if (!orderId) return false;
        await failOrder(prisma, orderId, "ASYNC_PAYMENT_FAILED");
        break;
      case "invoice.paid":
        await invoicePaid(prisma, object, knownSubscription);
        break;
      case "invoice.payment_failed":
        await invoiceFailed(prisma, object, knownSubscription);
        break;
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await subscriptionChanged(prisma, object, type, knownSubscription);
        break;
      case "charge.refunded":
      case "refund.created":
      case "refund.updated":
        if (orderId) await refundOrder(prisma, orderId, object);
        break;
      case "charge.dispute.created":
      case "charge.dispute.updated":
      case "charge.dispute.closed":
        if (orderId) await disputeOrder(prisma, orderId, object, type);
        break;
      default:
        return false;
    }
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingWebhookEvent" SET "status" = 'PROCESSED', "processedAt" = CURRENT_TIMESTAMP WHERE "stripeEventId" = ?`,
      String(event.id),
    );
    return true;
  } catch (error) {
    const code = error instanceof Error ? error.message.slice(0, 160) : "service_order_webhook_failed";
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingWebhookEvent" SET "status" = 'FAILED', "failureCode" = ?, "processedAt" = CURRENT_TIMESTAMP WHERE "stripeEventId" = ?`,
      code, String(event.id),
    );
    throw error;
  }
}

async function completeCheckout(prisma: PrismaClient, orderId: string, session: any, type: string): Promise<void> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "BillingOrder" WHERE "id" = ? LIMIT 1`, orderId);
  const order = rows[0];
  if (!order) throw new Error("service_order_not_found");
  if (order.status === "ACTIVATED") return;
  const product = resolveOneWayProduct(order.productId);
  if (!product) throw new Error("service_order_product_not_found");
  const paymentSuccessful = type === "checkout.session.async_payment_succeeded"
    || String(session.payment_status) === "paid"
    || (product.billingType === "monthly" && String(session.status) === "complete");
  if (!paymentSuccessful) {
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingOrder" SET "status" = 'PROCESSING', "stripePaymentIntentId" = ?,
       "stripeSubscriptionId" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      stripeId(session.payment_intent), stripeId(session.subscription), orderId,
    );
    return;
  }
  const amountTotal = Number(session.amount_total ?? product.amount);
  if (amountTotal < product.amount) throw new Error("service_order_amount_mismatch");
  const customerId = stripeId(session.customer);
  const subscriptionId = stripeId(session.subscription);
  const paymentIntentId = stripeId(session.payment_intent);
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingOrder" SET "status" = 'PAID', "tax" = ?, "total" = ?,
     "stripeCustomerId" = ?, "stripePaymentIntentId" = ?, "stripeSubscriptionId" = ?,
     "completedAt" = CURRENT_TIMESTAMP, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
    Math.max(0, amountTotal - Number(order.subtotal)), amountTotal, customerId, paymentIntentId, subscriptionId, orderId,
  );
  if (product.billingType === "monthly" && subscriptionId && customerId) {
    await upsertSubscription(prisma, {
      userId: order.userId, productId: product.id, entitlementKey: product.entitlementKey,
      stripeCustomerId: customerId, stripeSubscriptionId: subscriptionId,
      stripePriceId: metadata(session, "stripe_price_id") || null, status: "ACTIVE",
    });
    await prisma.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "OneWayServiceSubscription" (
        "id", "userId", "planCode", "stripeCustomerId", "stripeSubscriptionId", "stripePriceId", "status", "autoRenew"
      ) VALUES (?, ?, ?, ?, ?, ?, 'ACTIVE', true)`,
      crypto.randomUUID(), order.userId, product.id, customerId, subscriptionId, null,
    );
  }
  await grantEntitlement(prisma, {
    userId: order.userId, entitlementKey: product.entitlementKey, sourceOrderId: orderId,
    productId: product.id, stripeCustomerId: customerId, stripeSubscriptionId: subscriptionId,
    stripePriceId: null,
  });
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingOrder" SET "status" = 'ACTIVATED', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
    orderId,
  );
  await audit(prisma, order.userId, orderId, "ENTITLEMENT_ACTIVATED", { productId: product.id });
  await notify(prisma, order.userId, "activation.completed", "OneWay service activated",
    `${product.name} is active. Order ${order.orderNumber}.`, "BillingOrder", orderId,
    { productId: product.id, amount: amountTotal, currency: order.currency });
  logger.info({ orderId, userId: order.userId, productId: product.id }, "SERVICE_ORDER_ACTIVATED");
}

async function invoicePaid(prisma: PrismaClient, invoice: any, known: any): Promise<void> {
  const subscriptionId = stripeId(invoice.subscription) || stripeId(invoice.parent?.subscription_details?.subscription);
  if (!subscriptionId || !known) return;
  const periodEnd = invoice.lines?.data?.[0]?.period?.end;
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingSubscription" SET "status" = 'ACTIVE', "gracePeriodEnd" = NULL,
     "currentPeriodEnd" = COALESCE(?, "currentPeriodEnd"), "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
    periodEnd ? new Date(Number(periodEnd) * 1000) : null, subscriptionId,
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingOrder" SET "stripeInvoiceId" = ?, "updatedAt" = CURRENT_TIMESTAMP
     WHERE "stripeSubscriptionId" = ?`,
    String(invoice.id ?? ""), subscriptionId,
  );
}

async function invoiceFailed(prisma: PrismaClient, invoice: any, known: any): Promise<void> {
  const subscriptionId = stripeId(invoice.subscription) || stripeId(invoice.parent?.subscription_details?.subscription);
  if (!subscriptionId || !known) return;
  const graceDays = Math.max(0, Math.min(30, Number(process.env.ONEWAY_BILLING_GRACE_DAYS ?? 7)));
  const graceEnd = new Date(Date.now() + graceDays * 86_400_000);
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingSubscription" SET "status" = 'PAST_DUE', "gracePeriodEnd" = ?,
     "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
    graceEnd, subscriptionId,
  );
  await notify(prisma, known.userId, "payment.failed", "Payment needs attention",
    "Your payment failed. Update your payment method in Billing before the grace period ends.",
    "BillingSubscription", known.id, { gracePeriodEnd: graceEnd.toISOString() });
}

async function subscriptionChanged(prisma: PrismaClient, subscription: any, type: string, known: any): Promise<void> {
  if (!known) return;
  const status = type === "customer.subscription.deleted"
    ? "CANCELLED"
    : String(subscription.status ?? "INCOMPLETE").toUpperCase();
  const productId = metadata(subscription, "oneway_product_id") || known.productId;
  const product = resolveOneWayProduct(productId);
  const periodStart = timestamp(subscription.current_period_start);
  const periodEnd = timestamp(subscription.current_period_end);
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingSubscription" SET "productId" = ?, "entitlementKey" = ?, "status" = ?,
     "cancelAtPeriodEnd" = ?, "currentPeriodStart" = ?, "currentPeriodEnd" = ?,
     "pendingProductId" = CASE WHEN ? = 'ACTIVE' THEN NULL ELSE "pendingProductId" END,
     "pendingChangeAt" = CASE WHEN ? = 'ACTIVE' THEN NULL ELSE "pendingChangeAt" END,
     "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
    productId, product?.entitlementKey ?? known.entitlementKey, status,
    Boolean(subscription.cancel_at_period_end), periodStart, periodEnd, status, status, String(subscription.id),
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "OneWayServiceSubscription" SET "planCode" = ?, "status" = ?, "cancelAtPeriodEnd" = ?,
     "currentPeriodStart" = ?, "currentPeriodEnd" = ?, "updatedAt" = CURRENT_TIMESTAMP
     WHERE "stripeSubscriptionId" = ?`,
    productId, status, Boolean(subscription.cancel_at_period_end), periodStart, periodEnd, String(subscription.id),
  );
  if (type === "customer.subscription.deleted") {
    await prisma.$executeRawUnsafe(
      `UPDATE "BillingEntitlement" SET "status" = 'REVOKED', "revokedAt" = CURRENT_TIMESTAMP,
       "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ? AND "status" = 'ACTIVE'`,
      String(subscription.id),
    );
    await notify(prisma, known.userId, "subscription.cancelled", "Subscription cancelled",
      "Your paid access ended after Stripe confirmed the subscription cancellation.",
      "BillingSubscription", known.id, { productId });
  }
}

async function refundOrder(prisma: PrismaClient, orderId: string, object: any): Promise<void> {
  const refundStatus = String(object.status ?? "succeeded").toLowerCase();
  if (!["succeeded", "refunded"].includes(refundStatus) && object.refunded !== true) return;
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT "total" FROM "BillingOrder" WHERE "id" = ? LIMIT 1`, orderId);
  const orderTotal = Number(rows[0]?.total ?? 0);
  const refundedAmount = Number(object.amount_refunded ?? object.amount ?? 0);
  const fullRefund = object.refunded === true || (orderTotal > 0 && refundedAmount >= orderTotal);
  if (!fullRefund) {
    await audit(prisma, null, orderId, "PARTIAL_REFUND_RECORDED", {
      stripeObjectId: object.id,
      refundedAmount,
      orderTotal,
    });
    return;
  }
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingOrder" SET "status" = 'REFUNDED', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
    orderId,
  );
  await revokeOrderEntitlements(prisma, orderId);
  await audit(prisma, null, orderId, "REFUND_RECONCILED", { stripeObjectId: object.id });
}

async function disputeOrder(prisma: PrismaClient, orderId: string, dispute: any, type: string): Promise<void> {
  const closedWon = type === "charge.dispute.closed" && String(dispute.status) === "won";
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingOrder" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
    closedWon ? "ACTIVATED" : "DISPUTED", orderId,
  );
  await audit(prisma, null, orderId, closedWon ? "DISPUTE_WON" : "DISPUTE_OPENED", { stripeDisputeId: dispute.id });
}

async function failOrder(prisma: PrismaClient, orderId: string, code: string): Promise<void> {
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingOrder" SET "status" = 'FAILED', "failureCode" = ?,
     "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "status" <> 'ACTIVATED'`,
    code, orderId,
  );
}

async function orderIdForObject(prisma: PrismaClient, object: any): Promise<string | null> {
  const paymentIntentId = stripeId(object.payment_intent) || stripeId(object.id, "pi_");
  if (!paymentIntentId) return null;
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT "id" FROM "BillingOrder" WHERE "stripePaymentIntentId" = ? LIMIT 1`, paymentIntentId,
  );
  return rows[0]?.id ?? null;
}

async function subscriptionRow(prisma: PrismaClient, stripeSubscriptionId: string): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "BillingSubscription" WHERE "stripeSubscriptionId" = ? LIMIT 1`, stripeSubscriptionId,
  );
  return rows[0] ?? null;
}

async function upsertSubscription(prisma: PrismaClient, input: any): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "BillingSubscription" (
      "id", "userId", "productId", "entitlementKey", "stripeCustomerId", "stripeSubscriptionId", "stripePriceId", "status"
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    crypto.randomUUID(), input.userId, input.productId, input.entitlementKey,
    input.stripeCustomerId, input.stripeSubscriptionId, input.stripePriceId, input.status,
  );
  await prisma.$executeRawUnsafe(
    `UPDATE "BillingSubscription" SET "productId" = ?, "entitlementKey" = ?, "status" = ?,
     "updatedAt" = CURRENT_TIMESTAMP WHERE "stripeSubscriptionId" = ?`,
    input.productId, input.entitlementKey, input.status, input.stripeSubscriptionId,
  );
}

function metadata(object: any, key: string): string | null {
  const value = object?.metadata?.[key];
  return typeof value === "string" && value ? value : null;
}

function stripeId(value: any, prefix?: string): string | null {
  const id = typeof value === "string" ? value : value?.id;
  return typeof id === "string" && (!prefix || id.startsWith(prefix)) ? id : null;
}

function timestamp(value: any): Date | null {
  const seconds = Number(value ?? 0);
  return seconds > 0 ? new Date(seconds * 1000) : null;
}

async function audit(prisma: PrismaClient, userId: string | null, orderId: string, action: string, metadataJson: Record<string, unknown>) {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "BillingAuditLog" ("id", "userId", "orderId", "action", "actorType", "metadataJson")
     VALUES (?, ?, ?, ?, 'STRIPE_WEBHOOK', ?)`,
    crypto.randomUUID(), userId, orderId, action, JSON.stringify(metadataJson),
  );
}

async function notify(
  prisma: PrismaClient, userId: string, eventType: string, title: string, body: string,
  relatedEntityType: string, relatedEntityId: string, metadataJson: Record<string, unknown>,
) {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "PaymentNotificationOutbox" (
      "id", "userId", "audience", "eventType", "title", "body", "relatedEntityType", "relatedEntityId", "metadataJson"
    ) VALUES (?, ?, 'customer', ?, ?, ?, ?, ?, ?)`,
    crypto.randomUUID(), userId, eventType, title, body, relatedEntityType, relatedEntityId, JSON.stringify(metadataJson),
  );
}
