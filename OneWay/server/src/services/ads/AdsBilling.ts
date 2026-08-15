import type { PrismaClient } from "@prisma/client";

import { ensureAdsTables } from "./AdsTables";

type StripeObject = Record<string, any>;

export function isAdsPaymentIntent(intent: StripeObject): boolean {
  return String(intent.metadata?.paymentDomain ?? intent.metadata?.oneWayPaymentDomain ?? "").toLowerCase() === "ads";
}

export async function handleAdsPaymentIntentSucceeded(
  prisma: PrismaClient,
  event: Record<string, any>,
  intent: StripeObject,
): Promise<boolean> {
  if (!isAdsPaymentIntent(intent)) return false;
  await ensureAdsTables(prisma);

  const paymentId = stringMetadata(intent, "adsPaymentId");
  const campaignId = stringMetadata(intent, "campaignId");
  const advertiserId = stringMetadata(intent, "advertiserId");
  if (!paymentId || !campaignId || !advertiserId) {
    throw new Error("ads_payment_metadata_missing");
  }

  const amountMinor = Number(intent.amount_received ?? intent.amount ?? 0);
  const currency = String(intent.currency ?? "usd").toUpperCase();
  if (!Number.isInteger(amountMinor) || amountMinor <= 0) {
    throw new Error("ads_payment_amount_invalid");
  }

  const paymentRows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "AdPayment" WHERE "id" = ? AND "campaignId" = ? AND "advertiserId" = ? LIMIT 1`,
    paymentId,
    campaignId,
    advertiserId,
  );
  const payment = paymentRows[0];
  if (!payment) throw new Error("ads_payment_not_found");
  if (Number(payment.amountMinor) !== amountMinor || String(payment.currency).toUpperCase() !== currency) {
    throw new Error("ads_payment_amount_mismatch");
  }

  const idempotencyKey = `stripe:${String(event.id ?? intent.id)}:ads:${paymentId}:funding`;
  const existingLedger = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "AdLedgerEntry" WHERE "idempotencyKey" = ? OR ("stripeEventId" = ? AND "entryType" = 'campaignFunding' AND "campaignId" = ?) LIMIT 1`,
    idempotencyKey,
    String(event.id ?? ""),
    campaignId,
  );
  if (existingLedger[0]) {
    await prisma.$executeRawUnsafe(
      `UPDATE "AdPayment" SET "status" = 'paid', "stripePaymentIntentId" = COALESCE(?, "stripePaymentIntentId"), "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      String(intent.id ?? ""),
      paymentId,
    );
    return true;
  }

  const receiptId = randomId("adreceipt");
  const receiptNumber = receiptNumberFor(campaignId);
  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(
      `UPDATE "AdPayment"
       SET "status" = 'paid', "stripePaymentIntentId" = ?, "updatedAt" = CURRENT_TIMESTAMP
       WHERE "id" = ? AND "status" != 'paid'`,
      String(intent.id ?? ""),
      paymentId,
    );
    await tx.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "AdLedgerEntry" (
        "id", "campaignId", "advertiserId", "entryType", "amountMinor", "currency", "status", "idempotencyKey", "stripeEventId", "stripePaymentIntentId", "metadataJson"
      ) VALUES (?, ?, ?, 'campaignFunding', ?, ?, 'posted', ?, ?, ?, ?)`,
      randomId("adledger"),
      campaignId,
      advertiserId,
      amountMinor,
      currency,
      idempotencyKey,
      String(event.id ?? ""),
      String(intent.id ?? ""),
      JSON.stringify({ stripeEventId: String(event.id ?? ""), adsPaymentId: paymentId }),
    );
    await tx.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "AdReceipt" ("id", "receiptNumber", "campaignId", "advertiserId", "ownerUserId", "paymentId", "stripePaymentIntentId", "stripeEventId", "amountMinor", "currency", "status", "metadataJson")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'issued', ?)`,
      receiptId,
      receiptNumber,
      campaignId,
      advertiserId,
      payment.ownerUserId,
      paymentId,
      String(intent.id ?? ""),
      String(event.id ?? ""),
      amountMinor,
      currency,
      JSON.stringify({ adsPaymentId: paymentId }),
    );
    await tx.$executeRawUnsafe(`UPDATE "AdPayment" SET "receiptId" = COALESCE("receiptId", ?), "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, receiptId, paymentId);
    await tx.$executeRawUnsafe(
      `UPDATE "AdBudget"
       SET "fundedMinor" = "fundedMinor" + ?,
           "remainingMinor" = "remainingMinor" + ?,
           "updatedAt" = CURRENT_TIMESTAMP
       WHERE "campaignId" = ?`,
      amountMinor,
      amountMinor,
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `UPDATE "AdCampaign"
       SET "fundedMinor" = "fundedMinor" + ?,
           "status" = CASE WHEN "status" = 'paymentPending' AND "moderationStatus" = 'approved' THEN 'readyForActivation' ELSE "status" END,
           "updatedAt" = CURRENT_TIMESTAMP
       WHERE "id" = ?`,
      amountMinor,
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdAuditLog" ("id", "actorType", "action", "resourceType", "resourceId", "metadataJson")
       VALUES (?, 'stripe_webhook', 'ads.payment.succeeded', 'AdCampaign', ?, ?)`,
      randomId("adaudit"),
      campaignId,
      JSON.stringify({ stripePaymentIntentId: String(intent.id ?? ""), amountMinor, currency }),
    );
  });

  return true;
}

export async function handleAdsPaymentIntentFailed(
  prisma: PrismaClient,
  event: Record<string, any>,
  intent: StripeObject,
): Promise<boolean> {
  if (!isAdsPaymentIntent(intent)) return false;
  await ensureAdsTables(prisma);
  const paymentId = stringMetadata(intent, "adsPaymentId");
  const campaignId = stringMetadata(intent, "campaignId");
  if (!paymentId || !campaignId) throw new Error("ads_payment_metadata_missing");
  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(
      `UPDATE "AdPayment" SET "status" = ?, "failureCode" = COALESCE(?, "failureCode"), "failureMessage" = COALESCE(?, "failureMessage"), "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      String(event.type ?? "").includes("canceled") ? "canceled" : "failed",
      String(intent.last_payment_error?.code ?? "") || null,
      String(intent.last_payment_error?.message ?? "") || null,
      paymentId,
    );
    await tx.$executeRawUnsafe(
      `UPDATE "AdCampaign" SET "status" = 'fundingRequired', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "status" NOT IN ('canceled','suspended','completed','readyForActivation')`,
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdAuditLog" ("id", "actorType", "action", "resourceType", "resourceId", "metadataJson")
       VALUES (?, 'stripe_webhook', 'ads.payment.failed', 'AdCampaign', ?, ?)`,
      randomId("adaudit"),
      campaignId,
      JSON.stringify({ stripeEventId: String(event.id ?? ""), stripePaymentIntentId: String(intent.id ?? "") }),
    );
  });
  return true;
}

export async function handleAdsRefundOrDispute(
  prisma: PrismaClient,
  event: Record<string, any>,
  object: StripeObject,
): Promise<boolean> {
  const paymentIntentId = String(object.payment_intent ?? object.payment_intent_id ?? "");
  const metadataDomain = String(object.metadata?.paymentDomain ?? object.metadata?.oneWayPaymentDomain ?? "").toLowerCase();
  if (!paymentIntentId && metadataDomain !== "ads") return false;
  await ensureAdsTables(prisma);
  const paymentRows = paymentIntentId
    ? await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "stripePaymentIntentId" = ? LIMIT 1`, paymentIntentId)
    : [];
  const payment = paymentRows[0];
  if (!payment && metadataDomain !== "ads") return false;

  const campaignId = payment?.campaignId ?? stringMetadata(object, "campaignId");
  const advertiserId = payment?.advertiserId ?? stringMetadata(object, "advertiserId");
  if (!campaignId || !advertiserId) return true;
  const amountMinor = Math.max(0, Number(object.amount ?? object.amount_refunded ?? 0));
  const action = String(event.type ?? "").includes("dispute") ? "ads.payment.dispute" : "ads.payment.refund";
  const entryType = String(event.type ?? "").includes("dispute") ? "disputeHold" : "refund";
  const idempotencyKey = `stripe:${String(event.id ?? object.id)}:ads:${entryType}:${campaignId}`;

  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "AdLedgerEntry" ("id", "campaignId", "advertiserId", "entryType", "amountMinor", "currency", "status", "idempotencyKey", "stripeEventId", "stripePaymentIntentId", "metadataJson")
       VALUES (?, ?, ?, ?, ?, ?, 'posted', ?, ?, ?, ?)`,
      randomId("adledger"),
      campaignId,
      advertiserId,
      entryType,
      -Math.abs(amountMinor),
      String(object.currency ?? payment?.currency ?? "usd").toUpperCase(),
      idempotencyKey,
      String(event.id ?? ""),
      paymentIntentId || null,
      JSON.stringify({ stripeEventId: String(event.id ?? ""), stripeObjectId: String(object.id ?? "") }),
    );
    await tx.$executeRawUnsafe(
      `UPDATE "AdCampaign" SET "fundedMinor" = MAX("fundedMinor" - ?, 0), "status" = CASE WHEN "status" = 'readyForActivation' THEN 'fundingRequired' ELSE "status" END, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      Math.abs(amountMinor),
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `UPDATE "AdBudget" SET "fundedMinor" = MAX("fundedMinor" - ?, 0), "remainingMinor" = MAX("remainingMinor" - ?, 0), "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ?`,
      Math.abs(amountMinor),
      Math.abs(amountMinor),
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdAuditLog" ("id", "actorType", "action", "resourceType", "resourceId", "metadataJson")
       VALUES (?, 'stripe_webhook', ?, 'AdCampaign', ?, ?)`,
      randomId("adaudit"),
      action,
      campaignId,
      JSON.stringify({ stripeEventId: String(event.id ?? ""), amountMinor }),
    );
  });
  return true;
}

function stringMetadata(object: StripeObject, key: string): string | null {
  const value = object.metadata?.[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function randomId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}

function receiptNumberFor(campaignId: string): string {
  return `OWADS-${Date.now().toString(36).toUpperCase()}-${campaignId.slice(-6).toUpperCase()}`;
}
