import type { PrismaClient } from "@prisma/client";

import { ensureAdsTables } from "./AdsTables";
import { randomAdsId } from "./AdsEventTokens";

const MICROS_PER_MINOR = 1000;

type SpendEventType = "impression" | "click";

type SpendInput = {
  eventId: string;
  eventType: SpendEventType;
  campaign: any;
  pricingSnapshotId: string;
  placement: string;
  currency: string;
  now?: Date;
};

export async function ensureAdPricingSnapshot(prisma: PrismaClient, campaign: any, creativeVersion: number): Promise<any> {
  await ensureAdsTables(prisma);
  const billingModel = String(campaign.billingModel ?? "PREPAID_CPM").toUpperCase();
  const eventBillingModel = billingModel.includes("CPC") ? "CPC" : "CPM";
  const effectiveVersion = Number(campaign.currentRevision ?? campaign.version ?? 1);
  const existing = (await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "AdPricingSnapshot" WHERE "campaignId" = ? AND "creativeVersion" = ? AND "billingModel" = ? AND "effectiveVersion" = ? LIMIT 1`,
    campaign.id,
    creativeVersion,
    eventBillingModel,
    effectiveVersion,
  ))[0];
  if (existing) return existing;

  const id = randomAdsId("adprice");
  const rateMinor = eventBillingModel === "CPC"
    ? numberEnv("ONEWAY_ADS_CPC_PRICE_MINOR", 25)
    : numberEnv("ONEWAY_ADS_CPM_PRICE_MINOR", 500);
  await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "AdPricingSnapshot" ("id", "campaignId", "advertiserId", "creativeVersion", "billingModel", "rateMinor", "currency", "pricingUnit", "effectiveVersion", "approvedAt", "metadataJson")
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    id,
    campaign.id,
    campaign.advertiserId,
    creativeVersion,
    eventBillingModel,
    rateMinor,
    String(campaign.currency ?? "USD").toUpperCase(),
    eventBillingModel === "CPC" ? "click" : "thousand_impressions",
    effectiveVersion,
    campaign.approvedAt ?? new Date().toISOString(),
    JSON.stringify({ source: "server_pricing_snapshot", phase: "3B" }),
  );
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPricingSnapshot" WHERE "id" = ? LIMIT 1`, id))[0]
    ?? (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPricingSnapshot" WHERE "campaignId" = ? AND "creativeVersion" = ? AND "billingModel" = ? AND "effectiveVersion" = ? LIMIT 1`, campaign.id, creativeVersion, eventBillingModel, effectiveVersion))[0];
}

export async function recordAdsSpend(prisma: PrismaClient, input: SpendInput): Promise<{ costMinor: number; ledgerEntryId: string | null; billingModel: string; budgetStatus: string; accruedMicros: number; remainingMinor: number }> {
  const config = spendConfig();
  if (!config.spendAccountingEnabled) {
    return { costMinor: 0, ledgerEntryId: null, billingModel: "disabled", budgetStatus: String(input.campaign.status ?? "unknown"), accruedMicros: 0, remainingMinor: Number(input.campaign.fundedMinor ?? 0) - Number(input.campaign.spentMinor ?? 0) };
  }

  const pricing = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPricingSnapshot" WHERE "id" = ? LIMIT 1`, input.pricingSnapshotId))[0]
    ?? await ensureAdPricingSnapshot(prisma, input.campaign, Number(input.campaign.currentRevision ?? input.campaign.version ?? 1));
  const billingModel = String(pricing.billingModel ?? "CPM").toUpperCase();
  const billable = (input.eventType === "impression" && billingModel === "CPM" && config.impressionBillingEnabled)
    || (input.eventType === "click" && billingModel === "CPC" && config.clickBillingEnabled);
  if (!billable) {
    await updateEventSpend(prisma, input, 0, null, billingModel);
    return { costMinor: 0, ledgerEntryId: null, billingModel, budgetStatus: String(input.campaign.status ?? "unknown"), accruedMicros: 0, remainingMinor: Number(input.campaign.fundedMinor ?? 0) - Number(input.campaign.spentMinor ?? 0) };
  }

  const eventMicros = billingModel === "CPM"
    ? Math.max(0, Math.round(Number(pricing.rateMinor ?? 0) * MICROS_PER_MINOR / 1000))
    : Math.max(0, Number(pricing.rateMinor ?? 0) * MICROS_PER_MINOR);
  const budgetRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, input.campaign.id);
  const remainingMinor = Number(budgetRows[0]?.remainingMinor ?? 0);
  if (remainingMinor <= 0) throw new Error("budget_exhausted");

  const accrualId = `${input.campaign.id}:${billingModel}:${pricing.id}`;
  const existingAccrual = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdSpendAccrual" WHERE "campaignId" = ? AND "billingModel" = ? AND "pricingSnapshotId" = ? LIMIT 1`, input.campaign.id, billingModel, pricing.id))[0];
  if (!existingAccrual) {
    await prisma.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "AdSpendAccrual" ("id", "campaignId", "advertiserId", "pricingSnapshotId", "billingModel", "currency")
       VALUES (?, ?, ?, ?, ?, ?)`,
      accrualId,
      input.campaign.id,
      input.campaign.advertiserId,
      pricing.id,
      billingModel,
      input.currency,
    );
  }
  const accrual = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdSpendAccrual" WHERE "campaignId" = ? AND "billingModel" = ? AND "pricingSnapshotId" = ? LIMIT 1`, input.campaign.id, billingModel, pricing.id))[0];
  const nextMicros = Number(accrual?.remainderMicros ?? 0) + eventMicros;
  const debitMinor = Math.min(remainingMinor, Math.floor(nextMicros / MICROS_PER_MINOR));
  const remainderMicros = nextMicros - debitMinor * MICROS_PER_MINOR;
  let ledgerEntryId: string | null = null;

  if (debitMinor > 0) {
    ledgerEntryId = randomAdsId("adledger");
    await prisma.$executeRawUnsafe(
      `INSERT OR IGNORE INTO "AdLedgerEntry" ("id", "campaignId", "advertiserId", "entryType", "amountMinor", "currency", "status", "idempotencyKey", "metadataJson")
       VALUES (?, ?, ?, ?, ?, ?, 'posted', ?, ?)`,
      ledgerEntryId,
      input.campaign.id,
      input.campaign.advertiserId,
      input.eventType === "click" ? "clickSpend" : "impressionSpend",
      -debitMinor,
      input.currency,
      `ads:${input.eventType}:spend:${input.eventId}`,
      JSON.stringify({ phase: "3B", eventId: input.eventId, pricingSnapshotId: pricing.id, placement: input.placement, eventMicros }),
    );
    await prisma.$executeRawUnsafe(`UPDATE "AdBudget" SET "spentMinor" = "spentMinor" + ?, "remainingMinor" = MAX("remainingMinor" - ?, 0), "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ?`, debitMinor, debitMinor, input.campaign.id);
    await prisma.$executeRawUnsafe(`UPDATE "AdCampaign" SET "spentMinor" = "spentMinor" + ?, "status" = CASE WHEN ("fundedMinor" - ("spentMinor" + ?)) <= 0 THEN 'budgetExhausted' ELSE "status" END, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, debitMinor, debitMinor, input.campaign.id);
  }

  await prisma.$executeRawUnsafe(
    `UPDATE "AdSpendAccrual" SET "accruedMicros" = "accruedMicros" + ?, "debitedMinor" = "debitedMinor" + ?, "remainderMicros" = ?, "eventCount" = "eventCount" + 1, "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ? AND "billingModel" = ? AND "pricingSnapshotId" = ?`,
    eventMicros,
    debitMinor,
    remainderMicros,
    input.campaign.id,
    billingModel,
    pricing.id,
  );
  await updateEventSpend(prisma, input, debitMinor, ledgerEntryId, billingModel);
  const updatedBudget = (await prisma.$queryRawUnsafe<any[]>(`SELECT "remainingMinor" FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, input.campaign.id))[0];
  const updatedCampaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT "status" FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, input.campaign.id))[0];
  return { costMinor: debitMinor, ledgerEntryId, billingModel, budgetStatus: String(updatedCampaign?.status ?? input.campaign.status ?? "unknown"), accruedMicros: eventMicros, remainingMinor: Number(updatedBudget?.remainingMinor ?? 0) };
}

export async function getAdsSpendSnapshot(prisma: PrismaClient, campaignId: string, ownerUserId?: string): Promise<any> {
  await ensureAdsTables(prisma);
  const ownerFilter = ownerUserId ? `AND c."ownerUserId" = ?` : "";
  const params = ownerUserId ? [campaignId, ownerUserId] : [campaignId];
  const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT c.* FROM "AdCampaign" c WHERE c."id" = ? ${ownerFilter} LIMIT 1`, ...params))[0];
  if (!campaign) return null;
  const budget = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, campaignId))[0] ?? null;
  const ledger = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdLedgerEntry" WHERE "campaignId" = ? AND "entryType" IN ('impressionSpend','clickSpend','impressionCharge') ORDER BY "createdAt" DESC`, campaignId);
  const accrual = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdSpendAccrual" WHERE "campaignId" = ? ORDER BY "updatedAt" DESC`, campaignId);
  const eventSpend = await prisma.$queryRawUnsafe<any[]>(`SELECT COALESCE(SUM("costMinor"),0) AS "costMinor", COUNT(*) AS "events" FROM "AdDeliveryEvent" WHERE "campaignId" = ? AND "verificationStatus" = 'verified'`, campaignId);
  return {
    campaignId,
    status: campaign.status,
    currency: campaign.currency ?? "USD",
    fundedMinor: Number(campaign.fundedMinor ?? 0),
    spentMinor: Number(campaign.spentMinor ?? 0),
    remainingMinor: Number(budget?.remainingMinor ?? (Number(campaign.fundedMinor ?? 0) - Number(campaign.spentMinor ?? 0))),
    eventCostMinor: Number(eventSpend[0]?.costMinor ?? 0),
    verifiedEvents: Number(eventSpend[0]?.events ?? 0),
    latestLedgerDebit: ledger[0] ?? null,
    accrual,
  };
}

export async function reconcileAdsSpend(prisma: PrismaClient, campaignId: string, ownerUserId?: string): Promise<any> {
  const snapshot = await getAdsSpendSnapshot(prisma, campaignId, ownerUserId);
  if (!snapshot) return null;
  const ledgerRows = await prisma.$queryRawUnsafe<any[]>(`SELECT COALESCE(SUM(CASE WHEN "amountMinor" < 0 THEN -"amountMinor" ELSE 0 END),0) AS "ledgerSpend" FROM "AdLedgerEntry" WHERE "campaignId" = ? AND "status" = 'posted' AND "entryType" IN ('impressionSpend','clickSpend','impressionCharge')`, campaignId);
  const ledgerSpendMinor = Number(ledgerRows[0]?.ledgerSpend ?? 0);
  return {
    ...snapshot,
    ledgerSpendMinor,
    cachedSpendMinor: snapshot.spentMinor,
    reconciled: ledgerSpendMinor === snapshot.spentMinor,
    phase: "3B",
  };
}

async function updateEventSpend(prisma: PrismaClient, input: SpendInput, costMinor: number, ledgerEntryId: string | null, billingModel: string): Promise<void> {
  await prisma.$executeRawUnsafe(
    `UPDATE "AdDeliveryEvent" SET "costMinor" = ?, "ledgerEntryId" = ?, "billingModel" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
    costMinor,
    ledgerEntryId,
    billingModel,
    input.eventId,
  );
}

function spendConfig() {
  return {
    spendAccountingEnabled: envFlag("ONEWAY_ADS_SPEND_ACCOUNTING_ENABLED", true),
    impressionBillingEnabled: envFlag("ONEWAY_ADS_IMPRESSION_BILLING_ENABLED", true),
    clickBillingEnabled: envFlag("ONEWAY_ADS_CLICK_BILLING_ENABLED", true),
  };
}

function envFlag(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw == null || raw.trim() === "") return fallback;
  return ["1", "true", "yes", "on"].includes(raw.trim().toLowerCase());
}

function numberEnv(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isFinite(value) ? value : fallback;
}
