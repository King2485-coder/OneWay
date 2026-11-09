import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";

import { ensureAdsTables } from "./AdsTables";

export type AdsEligibilityReasonCode =
  | "advertiser_missing"
  | "advertiser_not_active"
  | "advertiser_suspended"
  | "advertiser_restricted"
  | "advertiser_closed"
  | "advertiser_verification_required"
  | "campaign_missing"
  | "campaign_owner_mismatch"
  | "campaign_status_not_evaluable"
  | "campaign_paused"
  | "campaign_canceled"
  | "campaign_suspended"
  | "campaign_completed"
  | "campaign_budget_exhausted"
  | "campaign_not_approved"
  | "creative_missing"
  | "creative_not_approved"
  | "creative_version_mismatch"
  | "creative_media_disabled"
  | "destination_invalid"
  | "destination_unpublished"
  | "placement_missing"
  | "placement_disabled"
  | "objective_disabled"
  | "funding_missing"
  | "payment_not_verified"
  | "ledger_credit_missing"
  | "ledger_duplicate_credit"
  | "receipt_missing"
  | "ledger_unreconciled"
  | "balance_zero"
  | "refund_hold"
  | "dispute_hold"
  | "chargeback"
  | "currency_mismatch"
  | "budget_invalid"
  | "budget_exhausted"
  | "schedule_missing"
  | "schedule_invalid"
  | "schedule_not_started"
  | "schedule_expired"
  | "ads_disabled"
  | "submission_disabled"
  | "moderation_disabled"
  | "funding_disabled"
  | "activation_disabled"
  | "paid_delivery_disabled"
  | "country_unsupported"
  | "targeting_invalid"
  | "minor_policy_violation";

export type AdsEligibilityIssue = {
  code: AdsEligibilityReasonCode;
  message: string;
  severity: "blocker" | "warning";
};

export type AdsEligibilityResult = {
  isEligible: boolean;
  deliveryBlocked: boolean;
  resultingRecommendedState: "readyForActivation" | "scheduled" | "eligibleForDelivery" | "completed" | "paused" | "canceled" | "suspended" | "budgetExhausted";
  blockingReasons: AdsEligibilityIssue[];
  warnings: AdsEligibilityIssue[];
  evaluatedAt: string;
  campaignId: string;
  advertiserId: string | null;
  campaignRevision: number;
  creativeVersion: number | null;
  fundingBalanceMinor: number;
  currency: string;
  scheduleState: "missing" | "invalid" | "future" | "current" | "expired";
  enabledPlacements: string[];
  disabledPlacements: string[];
  featureFlagSnapshot: Record<string, any>;
  policySnapshotVersion: string;
  correlationId: string;
};

type AdsConfigSnapshot = ReturnType<typeof adsFeatureFlags>;

export async function evaluateAdsCampaignEligibility(
  prisma: PrismaClient,
  campaignId: string,
  options: { ownerUserId?: string; now?: Date; correlationId?: string; persist?: boolean } = {},
): Promise<AdsEligibilityResult> {
  await ensureAdsTables(prisma);
  const now = options.now ?? new Date();
  const correlationId = options.correlationId ?? randomId("adelig");
  const config = adsFeatureFlags();
  const blockers: AdsEligibilityIssue[] = [];
  const warnings: AdsEligibilityIssue[] = [];
  const addBlocker = (code: AdsEligibilityReasonCode, message: string) => blockers.push({ code, message, severity: "blocker" });
  const addWarning = (code: AdsEligibilityReasonCode, message: string) => warnings.push({ code, message, severity: "warning" });

  const campaign = (await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "AdCampaign" WHERE "id" = ? AND "deletedAt" IS NULL LIMIT 1`,
    campaignId,
  ))[0];
  if (!campaign) {
    return emptyResult(campaignId, "campaign_missing", "Campaign was not found.", config, now, correlationId);
  }
  if (options.ownerUserId && campaign.ownerUserId !== options.ownerUserId) {
    return emptyResult(campaignId, "campaign_owner_mismatch", "Campaign does not belong to this user.", config, now, correlationId);
  }

  const [advertiser, creative, placementRows, audienceRows, paymentRows, ledgerRows, receiptRows, budgetRows] = await Promise.all([
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdvertiserProfile" WHERE "id" = ? AND "deletedAt" IS NULL LIMIT 1`, campaign.advertiserId).then((rows) => rows[0]),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "deletedAt" IS NULL ORDER BY "version" DESC, "updatedAt" DESC LIMIT 1`, campaign.id).then((rows) => rows[0]),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPlacementSelection" WHERE "campaignId" = ? AND "enabled" = 1 ORDER BY "placement"`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdAudienceRule" WHERE "campaignId" = ?`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "campaignId" = ? ORDER BY "updatedAt" DESC`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdLedgerEntry" WHERE "campaignId" = ? ORDER BY "createdAt" DESC`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdReceipt" WHERE "campaignId" = ? ORDER BY "issuedAt" DESC`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, campaign.id),
  ]);

  if (!config.adsEnabled) addBlocker("ads_disabled", "OneWay Ads is disabled.");
  if (!config.campaignSubmissionEnabled) addBlocker("submission_disabled", "Campaign submission is disabled.");
  if (!config.moderationEnabled) addBlocker("moderation_disabled", "Ad moderation is disabled.");
  if (!config.campaignFundingEnabled) addBlocker("funding_disabled", "Campaign funding is disabled.");
  if (!config.campaignActivationEnabled) addBlocker("activation_disabled", "Campaign activation is limited to the next internal test phase.");
  if (!config.paidDeliveryEnabled) addWarning("paid_delivery_disabled", "Campaign passed activation checks can be certified, but paid delivery remains disabled for this test phase.");

  if (!advertiser) {
    addBlocker("advertiser_missing", "Advertiser profile was not found.");
  } else {
    const advertiserStatus = String(advertiser.status ?? "");
    if (advertiserStatus === "suspended") addBlocker("advertiser_suspended", "Advertiser profile is suspended.");
    else if (advertiserStatus === "restricted") addBlocker("advertiser_restricted", "Advertiser profile is restricted.");
    else if (advertiserStatus === "closed") addBlocker("advertiser_closed", "Advertiser profile is closed.");
    else if (advertiserStatus !== "active") addBlocker("advertiser_not_active", "Advertiser profile is not active.");
    if (!["verified", "approved"].includes(String(advertiser.verificationStatus ?? ""))) addBlocker("advertiser_verification_required", "Advertiser verification is required.");
    if (!config.supportedCountries.includes(String(advertiser.country ?? "US").toUpperCase())) addBlocker("country_unsupported", "Advertiser country is not supported for Ads activation.");
  }

  const terminalStatus = String(campaign.status ?? "");
  if (terminalStatus === "paused") addBlocker("campaign_paused", "Campaign is paused.");
  if (terminalStatus === "canceled") addBlocker("campaign_canceled", "Campaign is canceled.");
  if (terminalStatus === "suspended") addBlocker("campaign_suspended", "Campaign is suspended.");
  if (terminalStatus === "completed") addBlocker("campaign_completed", "Campaign has completed.");
  if (terminalStatus === "budgetExhausted") addBlocker("campaign_budget_exhausted", "Campaign budget is exhausted.");
  if (!["readyForActivation", "scheduled", "eligibleForDelivery", "paused"].includes(terminalStatus)) addBlocker("campaign_status_not_evaluable", "Campaign must be ready for activation before delivery certification.");
  if (String(campaign.moderationStatus ?? "") !== "approved") addBlocker("campaign_not_approved", "Campaign moderation is not approved.");

  if (!config.enabledObjectives.includes(String(campaign.objective ?? ""))) addBlocker("objective_disabled", "Selected objective is disabled.");

  if (!creative) {
    addBlocker("creative_missing", "Approved creative is required.");
  } else {
    if (String(creative.moderationStatus ?? "") !== "approved" || String(creative.status ?? "") !== "approved") addBlocker("creative_not_approved", "Creative is not approved.");
    if (Number(creative.revision ?? creative.version ?? 1) !== Number(campaign.currentRevision ?? 1)) addBlocker("creative_version_mismatch", "Creative revision does not match the current campaign revision.");
    const currentFingerprint = creativeFingerprint(creative);
    if (creative.approvedFingerprint && creative.approvedFingerprint !== currentFingerprint) addBlocker("creative_version_mismatch", "Creative changed after approval and needs review again.");
    if (creative.videoURL && !config.videoCreativeEnabled) addBlocker("creative_media_disabled", "Video creatives are disabled.");
    if (creative.imageURL && !config.imageCreativeEnabled) addBlocker("creative_media_disabled", "Image creatives are disabled.");
  }

  const destination = await validateDestinationGate(prisma, campaign);
  if (!destination.ok) addBlocker(destination.reasonCode, destination.message);

  const enabledPlacements = placementRows.map((row) => String(row.placement));
  const disabledPlacements = enabledPlacements.filter((placement) => !config.enabledPlacements.includes(placement));
  if (!enabledPlacements.length) addBlocker("placement_missing", "Choose at least one ad placement.");
  if (disabledPlacements.length) addBlocker("placement_disabled", "One or more selected placements are disabled.");
  if (audienceRows.some((rule) => sensitiveTargeting(rule.ruleType, rule.ruleValue))) addBlocker("targeting_invalid", "Sensitive targeting is not permitted.");
  if (audienceRows.some((rule) => String(rule.ruleType) === "adult_age_range" && /under|minor|child/i.test(String(rule.ruleValue)))) addBlocker("minor_policy_violation", "Minor-directed campaigns must remain contextual only.");

  const paidPayments = paymentRows.filter((row) => String(row.status) === "paid");
  const fundingCredits = ledgerRows.filter((row) => String(row.entryType) === "campaignFunding" && String(row.status ?? "posted") === "posted");
  const positiveFundingMinor = fundingCredits.reduce((sum, row) => sum + Math.max(0, Number(row.amountMinor ?? 0)), 0);
  const netLedgerMinor = ledgerRows.filter((row) => String(row.status ?? "posted") === "posted").reduce((sum, row) => sum + Number(row.amountMinor ?? 0), 0);
  const spentMinor = Number(campaign.spentMinor ?? 0);
  const fundingBalanceMinor = Math.max(0, netLedgerMinor - spentMinor);
  const duplicateCreditKeys = new Set<string>();
  let duplicateCredit = false;
  for (const row of fundingCredits) {
    const key = String(row.stripeEventId || row.stripePaymentIntentId || row.idempotencyKey || row.id);
    if (duplicateCreditKeys.has(key)) duplicateCredit = true;
    duplicateCreditKeys.add(key);
  }
  if (!paidPayments.length) addBlocker("payment_not_verified", "No verified Ads payment was found.");
  if (!positiveFundingMinor) addBlocker("ledger_credit_missing", "No verified campaign funding ledger credit was found.");
  if (duplicateCredit) addBlocker("ledger_duplicate_credit", "Duplicate funding ledger credit detected.");
  if (!receiptRows.length) addBlocker("receipt_missing", "No Ads funding receipt was found.");
  if (!Number.isFinite(netLedgerMinor)) addBlocker("ledger_unreconciled", "Campaign ledger could not be reconciled.");
  if (fundingBalanceMinor <= 0) addBlocker("balance_zero", "Campaign balance is zero.");
  if (ledgerRows.some((row) => String(row.entryType) === "disputeHold")) addBlocker("dispute_hold", "A dispute hold blocks activation.");
  if (ledgerRows.some((row) => String(row.entryType) === "chargeback")) addBlocker("chargeback", "A chargeback blocks activation.");
  if (ledgerRows.some((row) => String(row.entryType) === "refund" && Math.abs(Number(row.amountMinor ?? 0)) >= positiveFundingMinor)) addBlocker("refund_hold", "Campaign funding was fully refunded.");
  if (ledgerRows.some((row) => String(row.currency ?? "").toUpperCase() !== String(campaign.currency ?? "USD").toUpperCase())) addBlocker("currency_mismatch", "Campaign ledger currency does not match the campaign.");

  const budget = budgetRows[0];
  if (Number(campaign.lifetimeBudgetMinor ?? 0) <= 0 && Number(budget?.lifetimeBudgetMinor ?? 0) <= 0) addBlocker("budget_invalid", "Campaign lifetime budget is missing.");
  if (Number(campaign.lifetimeBudgetMinor ?? budget?.lifetimeBudgetMinor ?? 0) < config.minimumBudgetMinor) addBlocker("budget_invalid", "Campaign lifetime budget is below the minimum.");
  if (Number(campaign.fundedMinor ?? 0) <= Number(campaign.spentMinor ?? 0) && positiveFundingMinor <= spentMinor) addBlocker("budget_exhausted", "Campaign budget is exhausted.");

  const scheduleState = scheduleStateFor(campaign, now);
  if (scheduleState === "missing") addBlocker("schedule_missing", "Campaign schedule is required.");
  if (scheduleState === "invalid") addBlocker("schedule_invalid", "Campaign end time must be after start time.");
  if (scheduleState === "expired") addBlocker("schedule_expired", "Campaign schedule has expired.");

  const blockerCodes = new Set(blockers.map((reason) => reason.code));
  let resultingRecommendedState: AdsEligibilityResult["resultingRecommendedState"] = "readyForActivation";
  if (blockerCodes.has("campaign_paused")) resultingRecommendedState = "paused";
  else if (blockerCodes.has("campaign_canceled")) resultingRecommendedState = "canceled";
  else if (blockerCodes.has("campaign_suspended")) resultingRecommendedState = "suspended";
  else if (blockerCodes.has("schedule_expired") || blockerCodes.has("campaign_completed")) resultingRecommendedState = "completed";
  else if (blockerCodes.has("budget_exhausted") || blockerCodes.has("campaign_budget_exhausted")) resultingRecommendedState = "budgetExhausted";
  else if (blockers.length === 0 && scheduleState === "future") resultingRecommendedState = "scheduled";
  else if (blockers.length === 0 && scheduleState === "current") resultingRecommendedState = "eligibleForDelivery";

  const result: AdsEligibilityResult = {
    isEligible: blockers.length === 0,
    deliveryBlocked: !config.paidDeliveryEnabled,
    resultingRecommendedState,
    blockingReasons: blockers,
    warnings,
    evaluatedAt: now.toISOString(),
    campaignId: campaign.id,
    advertiserId: campaign.advertiserId ?? null,
    campaignRevision: Number(campaign.currentRevision ?? 1),
    creativeVersion: creative ? Number(creative.version ?? creative.revision ?? 1) : null,
    fundingBalanceMinor,
    currency: String(campaign.currency ?? "USD").toUpperCase(),
    scheduleState,
    enabledPlacements,
    disabledPlacements,
    featureFlagSnapshot: config,
    policySnapshotVersion: "ads-policy-2026-07-phase2b",
    correlationId,
  };

  if (options.persist) {
    await prisma.$executeRawUnsafe(
      `UPDATE "AdCampaign" SET "eligibilityStateJson" = ?, "lastEligibilityAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      JSON.stringify(result),
      campaign.id,
    );
  }

  return result;
}

function emptyResult(campaignId: string, code: AdsEligibilityReasonCode, message: string, config: AdsConfigSnapshot, now: Date, correlationId: string): AdsEligibilityResult {
  return {
    isEligible: false,
    deliveryBlocked: true,
    resultingRecommendedState: "readyForActivation",
    blockingReasons: [{ code, message, severity: "blocker" }],
    warnings: [],
    evaluatedAt: now.toISOString(),
    campaignId,
    advertiserId: null,
    campaignRevision: 0,
    creativeVersion: null,
    fundingBalanceMinor: 0,
    currency: "USD",
    scheduleState: "missing",
    enabledPlacements: [],
    disabledPlacements: [],
    featureFlagSnapshot: config,
    policySnapshotVersion: "ads-policy-2026-07-phase2b",
    correlationId,
  };
}

async function validateDestinationGate(prisma: PrismaClient, campaign: any): Promise<{ ok: true } | { ok: false; reasonCode: "destination_invalid" | "destination_unpublished"; message: string }> {
  const type = String(campaign.destinationType ?? "");
  if (!type || (!campaign.destinationId && !campaign.destinationURL)) return { ok: false, reasonCode: "destination_invalid", message: "Campaign destination is missing." };
  if (type === "external_url") {
    return safeDestinationURL(String(campaign.destinationURL ?? "")) ? { ok: true } : { ok: false, reasonCode: "destination_invalid", message: "External destination must use a safe HTTPS URL." };
  }
  if (type === "shop") {
    const shop = (await prisma.$queryRawUnsafe<any[]>(`SELECT "published", "status", "publicVisible" FROM "Storefront" WHERE "id" = ? LIMIT 1`, campaign.destinationId))[0];
    if (!shop) return { ok: false, reasonCode: "destination_invalid", message: "Shop destination was not found." };
    if (!shop.published || !["live", "published"].includes(String(shop.status)) || !shop.publicVisible) return { ok: false, reasonCode: "destination_unpublished", message: "Shop destination is not public." };
  }
  if (type === "product") {
    const product = (await prisma.$queryRawUnsafe<any[]>(`SELECT p."published", p."status", s."published" AS "shopPublished", s."publicVisible" AS "shopPublicVisible" FROM "StorefrontProduct" p JOIN "Storefront" s ON s."id" = p."storefrontId" WHERE p."id" = ? LIMIT 1`, campaign.destinationId))[0];
    if (!product) return { ok: false, reasonCode: "destination_invalid", message: "Product destination was not found." };
    if (!product.published || String(product.status) !== "published" || !product.shopPublished || !product.shopPublicVisible) return { ok: false, reasonCode: "destination_unpublished", message: "Product destination is not public." };
  }
  if (type === "site") {
    const site = (await prisma.$queryRawUnsafe<any[]>(`SELECT "status", "visibility", "activePublicationId" FROM "Site" WHERE "id" = ? LIMIT 1`, campaign.destinationId))[0];
    if (!site) return { ok: false, reasonCode: "destination_invalid", message: "Site destination was not found." };
    if (site.status !== "PUBLISHED" || !site.activePublicationId || !["PUBLIC", "UNLISTED"].includes(site.visibility ?? "PUBLIC")) return { ok: false, reasonCode: "destination_unpublished", message: "Site destination is not published." };
  }
  return { ok: true };
}

export function creativeFingerprint(creative: any): string {
  return crypto.createHash("sha256").update(JSON.stringify({
    headline: creative.headline ?? "",
    bodyText: creative.bodyText ?? "",
    cta: creative.cta ?? "",
    logoURL: creative.logoURL ?? "",
    imageURL: creative.imageURL ?? "",
    videoURL: creative.videoURL ?? "",
    thumbnailURL: creative.thumbnailURL ?? "",
    accessibilityDescription: creative.accessibilityDescription ?? "",
  })).digest("hex");
}

function scheduleStateFor(campaign: any, now: Date): AdsEligibilityResult["scheduleState"] {
  if (!campaign.startAt || !campaign.endAt) return "missing";
  const start = new Date(campaign.startAt).getTime();
  const end = new Date(campaign.endAt).getTime();
  const current = now.getTime();
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return "invalid";
  if (current < start) return "future";
  if (current >= end) return "expired";
  return "current";
}

function safeDestinationURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

function sensitiveTargeting(ruleType: string, value: string): boolean {
  return /\b(race|religion|health|medical|pregnancy|sexual|political|union|disability|credit|income|ethnic)\b/i.test(`${ruleType} ${value}`);
}

function adsFeatureFlags() {
  const enabledObjectives = csvEnv("ONEWAY_ADS_ENABLED_OBJECTIVES", "promote_shop,promote_product,website_visits").filter(Boolean);
  const enabledPlacements = csvEnv("ONEWAY_ADS_ENABLED_PLACEMENTS", "shop_discovery,marketplace_results,content_feed").filter(Boolean);
  return {
    adsEnabled: envFlag("ONEWAY_ADS_ENABLED", true),
    campaignSubmissionEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_SUBMISSION_ENABLED", true),
    moderationEnabled: envFlag("ONEWAY_ADS_MODERATION_ENABLED", true),
    campaignFundingEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_FUNDING_ENABLED", true),
    campaignActivationEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_ACTIVATION_ENABLED", false),
    paidDeliveryEnabled: envFlag("ONEWAY_ADS_PAID_DELIVERY_ENABLED", false),
    reportingEnabled: envFlag("ONEWAY_ADS_REPORTING_ENABLED", false),
    imageCreativeEnabled: envFlag("ONEWAY_ADS_IMAGE_CREATIVE_ENABLED", true),
    videoCreativeEnabled: envFlag("ONEWAY_ADS_VIDEO_CREATIVE_ENABLED", false),
    enabledObjectives,
    enabledPlacements,
    minimumBudgetMinor: numberEnv("ONEWAY_ADS_MIN_BUDGET_MINOR", 500),
    supportedCountries: csvEnv("ONEWAY_ADS_SUPPORTED_COUNTRIES", "US"),
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

function csvEnv(name: string, fallback: string): string[] {
  return (process.env[name] ?? fallback).split(",").map((value) => value.trim()).filter(Boolean);
}

function randomId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}
