import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";

import { ensureAdsTables } from "./AdsTables";
import { adsTokenFingerprint, randomAdsId, verifyAdsEventToken } from "./AdsEventTokens";
import { getAdsSpendSnapshot, reconcileAdsSpend, recordAdsSpend } from "./AdsSpendEngine";

type VerifiedEventType = "impression" | "click";

type VerifyEventRequest = {
  eventType: VerifiedEventType;
  token: string;
  clientEventId?: string;
  occurredAt?: string;
  visibleAreaPercent?: number;
  durationMs?: number;
  sessionReference?: string;
  country?: string;
  deviceClass?: string;
  metadata?: Record<string, any>;
};

export async function verifyAndRecordAdEvent(prisma: PrismaClient, request: VerifyEventRequest): Promise<any> {
  await ensureAdsTables(prisma);
  const receivedAt = new Date();
  const config = eventConfig();
  if (request.eventType === "impression" && !config.impressionVerificationEnabled) return rejected("impression_verification_disabled", request.eventType);
  if (request.eventType === "click" && !config.clickVerificationEnabled) return rejected("click_verification_disabled", request.eventType);
  if (request.eventType === "impression" && ((request.visibleAreaPercent ?? 0) < 50 || (request.durationMs ?? 0) < 1000)) {
    return { ok: true, counted: false, verificationStatus: "rejected", failureReasonCode: "visibility_threshold_not_met" };
  }

  const tokenFingerprint = adsTokenFingerprint(request.token);
  const parsed = verifyAdsEventToken(request.token, request.eventType);
  if (!parsed.ok) {
    await persistRejectedIfPossible(prisma, request, parsed.payload ?? {}, tokenFingerprint, parsed.error, receivedAt);
    return rejected(parsed.error, request.eventType);
  }

  const payload = parsed.payload;
  if (!payload.internalTest && !payload.paidDeliveryEnabled) {
    await persistRejectedIfPossible(prisma, request, payload, tokenFingerprint, "public_delivery_disabled", receivedAt);
    return rejected("public_delivery_disabled", request.eventType);
  }

  const idempotencyKey = request.clientEventId
    ? `ads:${request.eventType}:${payload.deliveryId}:${request.clientEventId}`
    : `ads:${request.eventType}:token:${tokenFingerprint}`;
  const duplicate = await findExistingEvent(prisma, idempotencyKey, tokenFingerprint);
  if (duplicate) return eventResponse(duplicate, { duplicate: true });

  const delivery = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdDeliveryToken" WHERE "deliveryId" = ? LIMIT 1`, payload.deliveryId))[0];
  if (!delivery) return rejected("unknown_delivery", request.eventType);
  if (delivery.campaignId !== payload.campaignId || delivery.creativeId !== payload.creativeId || delivery.placement !== payload.placement) {
    await persistRejectedIfPossible(prisma, request, payload, tokenFingerprint, "delivery_token_mismatch", receivedAt);
    return rejected("delivery_token_mismatch", request.eventType);
  }
  if (request.eventType === "impression" && delivery.impressionId) return eventResponse(await existingDeliveryEvent(prisma, payload.deliveryId, "impression"), { duplicate: true });
  if (request.eventType === "click" && delivery.clickId) return eventResponse(await existingDeliveryEvent(prisma, payload.deliveryId, "click"), { duplicate: true });

  const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, payload.campaignId))[0];
  if (!campaign || !campaignEligibleNow(campaign)) {
    await persistRejectedIfPossible(prisma, request, payload, tokenFingerprint, "campaign_not_eligible", receivedAt);
    return rejected("campaign_not_eligible", request.eventType);
  }

  const eventId = randomAdsId(request.eventType === "click" ? "adclk_evt" : "adimp_evt");
  const legacyEventId = randomAdsId(request.eventType === "click" ? "adclk" : "adimp");
  const sessionHash = request.sessionReference ? hash(`ads-session:${request.sessionReference}`) : null;
  let result: any = null;

  await prisma.$transaction(async (tx) => {
    const txClient = tx as unknown as PrismaClient;
    const duplicateInsideTx = await findExistingEvent(txClient, idempotencyKey, tokenFingerprint);
    if (duplicateInsideTx) {
      result = eventResponse(duplicateInsideTx, { duplicate: true });
      return;
    }

    await tx.$executeRawUnsafe(
      `INSERT INTO "AdDeliveryEvent" ("id", "eventType", "deliveryId", "traceId", "campaignId", "advertiserId", "creativeId", "creativeVersion", "placement", "viewerHash", "sessionHash", "country", "deviceClass", "occurredAtClient", "receivedAtServer", "verifiedAt", "verificationStatus", "deliveryTokenFingerprint", "eventTokenFingerprint", "idempotencyKey", "currency", "billingModel", "metadataJson")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'verified', ?, ?, ?, ?, ?, ?)`,
      eventId,
      request.eventType,
      payload.deliveryId,
      payload.traceId,
      payload.campaignId,
      payload.advertiserId,
      payload.creativeId,
      payload.creativeVersion,
      payload.placement,
      payload.viewerHash,
      sessionHash,
      request.country?.toUpperCase() ?? null,
      request.deviceClass ?? null,
      request.occurredAt ?? receivedAt.toISOString(),
      receivedAt.toISOString(),
      receivedAt.toISOString(),
      adsTokenFingerprint(String(delivery.tokenHash ?? payload.deliveryId)),
      tokenFingerprint,
      idempotencyKey,
      payload.currency,
      request.eventType === "click" ? "CPC_OR_NON_BILLABLE" : "CPM",
      JSON.stringify({ ...request.metadata, phase: "3B", visibleAreaPercent: request.visibleAreaPercent, durationMs: request.durationMs }),
    );

    if (request.eventType === "impression") {
      await tx.$executeRawUnsafe(
        `INSERT INTO "AdImpression" ("id", "campaignId", "creativeId", "advertiserId", "placement", "viewerHash", "tokenHash", "billableStatus", "deviceClass", "deliveryId", "traceId", "creativeVersion", "sessionHash", "country", "occurredAtClient", "receivedAtServer", "verifiedAt", "verificationStatus", "deliveryTokenFingerprint", "eventTokenFingerprint", "idempotencyKey", "currency", "metadataJson", "updatedAt")
         VALUES (?, ?, ?, ?, ?, ?, ?, 'billable', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'verified', ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
        legacyEventId,
        payload.campaignId,
        payload.creativeId,
        payload.advertiserId,
        payload.placement,
        payload.viewerHash,
        tokenFingerprint,
        request.deviceClass ?? null,
        payload.deliveryId,
        payload.traceId,
        payload.creativeVersion,
        sessionHash,
        request.country?.toUpperCase() ?? null,
        request.occurredAt ?? receivedAt.toISOString(),
        receivedAt.toISOString(),
        receivedAt.toISOString(),
        adsTokenFingerprint(String(delivery.tokenHash ?? payload.deliveryId)),
        tokenFingerprint,
        idempotencyKey,
        payload.currency,
        JSON.stringify({ deliveryEventId: eventId, phase: "3B" }),
      );
      await tx.$executeRawUnsafe(`UPDATE "AdDeliveryToken" SET "impressionId" = ?, "status" = CASE WHEN "clickId" IS NULL THEN 'impression_verified' ELSE 'consumed' END WHERE "deliveryId" = ?`, legacyEventId, payload.deliveryId);
    } else {
      await tx.$executeRawUnsafe(
        `INSERT INTO "AdClick" ("id", "campaignId", "creativeId", "advertiserId", "impressionId", "placement", "viewerHash", "destinationType", "destinationURL", "deliveryId", "traceId", "creativeVersion", "sessionHash", "country", "deviceClass", "occurredAtClient", "receivedAtServer", "verifiedAt", "verificationStatus", "deliveryTokenFingerprint", "eventTokenFingerprint", "idempotencyKey", "currency", "destinationSnapshotJson", "metadataJson", "updatedAt")
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'verified', ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
        legacyEventId,
        payload.campaignId,
        payload.creativeId,
        payload.advertiserId,
        delivery.impressionId ?? null,
        payload.placement,
        payload.viewerHash,
        String(campaign.destinationType ?? "unknown"),
        campaign.destinationURL ?? null,
        payload.deliveryId,
        payload.traceId,
        payload.creativeVersion,
        sessionHash,
        request.country?.toUpperCase() ?? null,
        request.deviceClass ?? null,
        request.occurredAt ?? receivedAt.toISOString(),
        receivedAt.toISOString(),
        receivedAt.toISOString(),
        adsTokenFingerprint(String(delivery.tokenHash ?? payload.deliveryId)),
        tokenFingerprint,
        idempotencyKey,
        payload.currency,
        JSON.stringify(safeDestination(campaign)),
        JSON.stringify({ deliveryEventId: eventId, phase: "3B" }),
      );
      await tx.$executeRawUnsafe(`UPDATE "AdDeliveryToken" SET "clickId" = ?, "status" = CASE WHEN "impressionId" IS NULL THEN 'click_verified' ELSE 'consumed' END WHERE "deliveryId" = ?`, legacyEventId, payload.deliveryId);
    }

    await tx.$executeRawUnsafe(`INSERT OR IGNORE INTO "AdDailyMetric" ("id", "campaignId", "advertiserId", "metricDate", "placement", "currency") VALUES (?, ?, ?, ?, ?, ?)`, randomAdsId("admetric"), payload.campaignId, payload.advertiserId, today(), payload.placement, payload.currency);
    await tx.$executeRawUnsafe(
      `UPDATE "AdDailyMetric" SET "${request.eventType === "click" ? "clicks" : "impressions"}" = "${request.eventType === "click" ? "clicks" : "impressions"}" + 1, "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ? AND "metricDate" = ? AND "placement" = ?`,
      payload.campaignId,
      today(),
      payload.placement,
    );

    const spend = await recordAdsSpend(txClient, {
      eventId,
      eventType: request.eventType,
      campaign,
      pricingSnapshotId: payload.pricingSnapshotId,
      placement: payload.placement,
      currency: payload.currency,
      now: receivedAt,
    });
    await tx.$executeRawUnsafe(`UPDATE "AdDailyMetric" SET "spendMinor" = "spendMinor" + ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ? AND "metricDate" = ? AND "placement" = ?`, spend.costMinor, payload.campaignId, today(), payload.placement);
    if (request.eventType === "impression") {
      await tx.$executeRawUnsafe(`UPDATE "AdImpression" SET "costMinor" = ?, "ledgerEntryId" = ?, "billingModel" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, spend.costMinor, spend.ledgerEntryId, spend.billingModel, legacyEventId);
    } else {
      await tx.$executeRawUnsafe(`UPDATE "AdClick" SET "costMinor" = ?, "ledgerEntryId" = ?, "billingModel" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, spend.costMinor, spend.ledgerEntryId, spend.billingModel, legacyEventId);
    }

    const saved = await existingDeliveryEvent(txClient, payload.deliveryId, request.eventType);
    result = eventResponse(saved, { duplicate: false, spend, legacyEventId });
  });

  return result;
}

export async function getAdsEventSummary(prisma: PrismaClient, campaignId: string, ownerUserId?: string): Promise<any> {
  await ensureAdsTables(prisma);
  const ownerFilter = ownerUserId ? `AND c."ownerUserId" = ?` : "";
  const params = ownerUserId ? [campaignId, ownerUserId] : [campaignId];
  const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT c.* FROM "AdCampaign" c WHERE c."id" = ? ${ownerFilter} LIMIT 1`, ...params))[0];
  if (!campaign) return null;
  const byType = await prisma.$queryRawUnsafe<any[]>(`SELECT "eventType", "verificationStatus", COUNT(*) AS count, COALESCE(SUM("costMinor"),0) AS costMinor FROM "AdDeliveryEvent" WHERE "campaignId" = ? GROUP BY "eventType", "verificationStatus"`, campaignId);
  const latest = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdDeliveryEvent" WHERE "campaignId" = ? ORDER BY "createdAt" DESC LIMIT 20`, campaignId);
  return { campaignId, byType, latest };
}

export { getAdsSpendSnapshot, reconcileAdsSpend };

async function findExistingEvent(prisma: PrismaClient, idempotencyKey: string, tokenFingerprint: string): Promise<any | null> {
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdDeliveryEvent" WHERE "idempotencyKey" = ? OR "eventTokenFingerprint" = ? LIMIT 1`, idempotencyKey, tokenFingerprint))[0] ?? null;
}

async function existingDeliveryEvent(prisma: PrismaClient, deliveryId: string, eventType: VerifiedEventType): Promise<any | null> {
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdDeliveryEvent" WHERE "deliveryId" = ? AND "eventType" = ? LIMIT 1`, deliveryId, eventType))[0] ?? null;
}

async function persistRejectedIfPossible(prisma: PrismaClient, request: VerifyEventRequest, payload: any, tokenFingerprint: string, reason: string, receivedAt: Date): Promise<void> {
  const idempotencyKey = request.clientEventId && payload.deliveryId ? `ads:${request.eventType}:${payload.deliveryId}:${request.clientEventId}` : `ads:${request.eventType}:rejected:${tokenFingerprint}`;
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "AdDeliveryEvent" ("id", "eventType", "deliveryId", "traceId", "campaignId", "advertiserId", "creativeId", "creativeVersion", "placement", "viewerHash", "country", "deviceClass", "receivedAtServer", "verificationStatus", "failureReasonCode", "eventTokenFingerprint", "idempotencyKey", "currency", "metadataJson")
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'rejected', ?, ?, ?, ?, ?)`,
    randomAdsId("adevt_rej"),
    request.eventType,
    payload.deliveryId ?? null,
    payload.traceId ?? null,
    payload.campaignId ?? null,
    payload.advertiserId ?? null,
    payload.creativeId ?? null,
    payload.creativeVersion ?? null,
    payload.placement ?? null,
    payload.viewerHash ?? null,
    request.country?.toUpperCase() ?? null,
    request.deviceClass ?? null,
    receivedAt.toISOString(),
    reason,
    tokenFingerprint,
    idempotencyKey,
    payload.currency ?? "USD",
    JSON.stringify({ phase: "3B", reason }),
  );
}

function rejected(reason: string, eventType: VerifiedEventType): any {
  return { ok: false, counted: false, eventType, verificationStatus: "rejected", failureReasonCode: reason, error: reason };
}

function eventResponse(row: any | null, extra: Record<string, any> = {}): any {
  return {
    ok: Boolean(row),
    counted: Boolean(row && row.verificationStatus === "verified"),
    eventId: row?.id ?? null,
    eventType: row?.eventType ?? null,
    verificationStatus: row?.verificationStatus ?? null,
    failureReasonCode: row?.failureReasonCode ?? null,
    costMinor: Number(row?.costMinor ?? 0),
    currency: row?.currency ?? "USD",
    ledgerEntryId: row?.ledgerEntryId ?? null,
    ...extra,
  };
}

function campaignEligibleNow(campaign: any): boolean {
  const now = Date.now();
  const starts = campaign.startAt ? new Date(campaign.startAt).getTime() : 0;
  const ends = campaign.endAt ? new Date(campaign.endAt).getTime() : Number.MAX_SAFE_INTEGER;
  return campaign.status === "eligibleForDelivery" && campaign.moderationStatus === "approved" && Number(campaign.fundedMinor ?? 0) > Number(campaign.spentMinor ?? 0) && starts <= now && ends > now;
}

function safeDestination(campaign: any): any {
  return { type: campaign.destinationType, id: campaign.destinationId, url: campaign.destinationURL };
}

function hash(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function eventConfig() {
  return {
    impressionVerificationEnabled: envFlag("ONEWAY_ADS_IMPRESSION_VERIFICATION_ENABLED", true),
    clickVerificationEnabled: envFlag("ONEWAY_ADS_CLICK_VERIFICATION_ENABLED", true),
  };
}

function envFlag(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw == null || raw.trim() === "") return fallback;
  return ["1", "true", "yes", "on"].includes(raw.trim().toLowerCase());
}
