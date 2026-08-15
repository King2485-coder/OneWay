import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";

import { evaluateAdsCampaignEligibility } from "./AdsCampaignEligibilityService";
import { ensureAdsTables } from "./AdsTables";
import { adsTokenFingerprint, signAdsEventToken } from "./AdsEventTokens";
import { ensureAdPricingSnapshot } from "./AdsSpendEngine";

const validPlacements = new Set([
  "shop_discovery",
  "marketplace_results",
  "site_discovery",
  "community_discovery",
  "content_feed",
  "featured_profile",
  "featured_event",
]);

type AdsDeliveryRequest = {
  placement: string;
  viewerHash: string;
  country?: string;
  deviceClass?: string;
  contextualCategory?: string;
  isMinor?: boolean;
  blockedAdvertiserIds?: Set<string>;
  internalTest?: boolean;
  campaignId?: string;
  ownerUserId?: string;
  now?: Date;
};

type DeliveryDecision = {
  ok: boolean;
  ad: any | null;
  reason: string | null;
  delivery: {
    deliveryId: string;
    traceId: string;
    token: string;
    expiresAt: string;
    internalTest: boolean;
    paidDeliveryEnabled: boolean;
  } | null;
  deliveryStatus: {
    paidDeliveryEnabled: boolean;
    internalDeliveryEnabled: boolean;
    publicDeliveryBlocked: boolean;
  };
};

type DeliveryCandidate = {
  campaign: any;
  creative: any;
  budget: any;
  eligibility: any;
  frequency: FrequencySnapshot;
  pacingScore: number;
};

type FrequencySnapshot = {
  campaignHour: number;
  campaignDay: number;
  advertiserDay: number;
  campaignHourCap: number;
  campaignDayCap: number;
  advertiserDayCap: number;
};

export async function requestAdDelivery(prisma: PrismaClient, request: AdsDeliveryRequest): Promise<DeliveryDecision> {
  await ensureAdsTables(prisma);
  const now = request.now ?? new Date();
  const traceId = randomId("adtrace");
  const config = adsDeliveryConfig();
  const placement = String(request.placement ?? "");
  const viewerHash = request.viewerHash || "viewer-anonymous";
  const noFill = async (reason: string, metadata: Record<string, any> = {}): Promise<DeliveryDecision> => {
    await recordAttempt(prisma, {
      traceId,
      campaign: null,
      creative: null,
      viewerHash,
      placement,
      decision: "no_fill",
      reason,
      country: request.country,
      deviceClass: request.deviceClass,
      pacingScore: 0,
      frequency: null,
      eligibility: null,
      metadata,
    });
    return deliveryResponse(null, null, reason, config);
  };

  if (!config.adsEnabled) return noFill("ads_disabled");
  if (!validPlacements.has(placement) || !config.enabledPlacements.includes(placement)) return noFill("invalid_or_disabled_placement");
  if (!config.paidDeliveryEnabled) {
    if (!config.internalDeliveryEnabled || request.internalTest !== true) {
      return noFill("ads_delivery_disabled", { paidDeliveryEnabled: false, internalDeliveryEnabled: config.internalDeliveryEnabled });
    }
    if (!internalTesterAllowed(request.ownerUserId, viewerHash, config)) {
      return noFill("internal_tester_not_allowed");
    }
  }

  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT c.*, a."status" AS "advertiserStatus", a."verificationStatus" AS "advertiserVerificationStatus", a."country" AS "advertiserCountry"
       FROM "AdCampaign" c
       JOIN "AdvertiserProfile" a ON a."id" = c."advertiserId"
       JOIN "AdPlacementSelection" p ON p."campaignId" = c."id"
       JOIN "AdBudget" b ON b."campaignId" = c."id"
      WHERE c."deletedAt" IS NULL
        AND c."status" = 'eligibleForDelivery'
        AND c."moderationStatus" = 'approved'
        AND a."status" = 'active'
        AND p."placement" = ?
        AND p."enabled" = 1
        AND b."remainingMinor" > 0
        AND (c."startAt" IS NULL OR c."startAt" <= ?)
        AND (c."endAt" IS NULL OR c."endAt" > ?)
        ${request.campaignId ? `AND c."id" = ?` : ""}
      ORDER BY b."remainingMinor" DESC, c."updatedAt" DESC
      LIMIT 80`,
    ...(request.campaignId ? [placement, now.toISOString(), now.toISOString(), request.campaignId] : [placement, now.toISOString(), now.toISOString()]),
  );

  let lastReason = "no_eligible_campaign";
  const candidates: DeliveryCandidate[] = [];
  for (const campaign of rows) {
    const screened = await screenCandidate(prisma, campaign, request, config, now);
    if (!screened.ok) {
      lastReason = screened.reason;
      await recordAttempt(prisma, {
        traceId,
        campaign,
        creative: screened.creative ?? null,
        viewerHash,
        placement,
        decision: "rejected",
        reason: screened.reason,
        country: request.country,
        deviceClass: request.deviceClass,
        pacingScore: screened.pacingScore ?? 0,
        frequency: screened.frequency ?? null,
        eligibility: screened.eligibility ?? null,
        metadata: { internalTest: request.internalTest === true },
      });
      continue;
    }
    candidates.push(screened.candidate);
  }

  candidates.sort((a, b) => b.pacingScore - a.pacingScore || Number(b.budget.remainingMinor ?? 0) - Number(a.budget.remainingMinor ?? 0));
  const selected = candidates[0];
  if (!selected) return noFill(lastReason);

  const deliveryId = randomId("addel");
  const expiresAt = new Date(now.getTime() + config.tokenTtlSeconds * 1000).toISOString();
  const tokenPayload = {
    deliveryId,
    traceId,
    campaignId: selected.campaign.id,
    creativeId: selected.creative.id,
    creativeVersion: Number(selected.creative.version ?? selected.creative.revision ?? 1),
    placement,
    viewerHash,
    issuedAt: now.toISOString(),
    expiresAt,
    paidDeliveryEnabled: config.paidDeliveryEnabled,
    internalTest: request.internalTest === true,
  };
  const encodedPayload = Buffer.from(JSON.stringify(tokenPayload)).toString("base64url");
  const signature = sign(encodedPayload);
  const token = `${encodedPayload}.${signature}`;
  const tokenHash = hash(token);
  const pricingSnapshot = await ensureAdPricingSnapshot(prisma, selected.campaign, Number(selected.creative.version ?? selected.creative.revision ?? 1));
  const eventTokenBase = {
    tokenVersion: 1 as const,
    deliveryId,
    traceId,
    campaignId: selected.campaign.id,
    advertiserId: selected.campaign.advertiserId,
    creativeId: selected.creative.id,
    creativeVersion: Number(selected.creative.version ?? selected.creative.revision ?? 1),
    placement,
    viewerHash,
    issuedAt: now.toISOString(),
    expiresAt,
    pricingSnapshotId: pricingSnapshot.id,
    currency: String(selected.campaign.currency ?? "USD").toUpperCase(),
    internalTest: request.internalTest === true,
    paidDeliveryEnabled: config.paidDeliveryEnabled,
  };
  const impressionToken = signAdsEventToken({ ...eventTokenBase, eventType: "impression", nonce: randomId("adimpnonce") });
  const clickToken = signAdsEventToken({ ...eventTokenBase, eventType: "click", nonce: randomId("adclknonce") });

  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdDeliveryToken" ("id", "campaignId", "creativeId", "viewerHash", "placement", "tokenHash", "expiresAt", "deliveryId", "traceId", "creativeVersion", "signature", "status", "metadataJson", "impressionTokenHash", "clickTokenHash", "pricingSnapshotId", "eventTokensJson")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'issued', ?, ?, ?, ?, ?)`,
      randomId("adtok"),
      selected.campaign.id,
      selected.creative.id,
      viewerHash,
      placement,
      tokenHash,
      expiresAt,
      deliveryId,
      traceId,
      Number(selected.creative.version ?? selected.creative.revision ?? 1),
      signature,
      JSON.stringify({ phase: "3B", internalTest: request.internalTest === true, paidDeliveryEnabled: config.paidDeliveryEnabled }),
      adsTokenFingerprint(impressionToken),
      adsTokenFingerprint(clickToken),
      pricingSnapshot.id,
      JSON.stringify({ impression: adsTokenFingerprint(impressionToken), click: adsTokenFingerprint(clickToken), pricingSnapshotId: pricingSnapshot.id }),
    );
    await recordAttempt(tx as unknown as PrismaClient, {
      traceId,
      campaign: selected.campaign,
      creative: selected.creative,
      viewerHash,
      placement,
      decision: "delivered",
      reason: "eligible_internal_delivery",
      country: request.country,
      deviceClass: request.deviceClass,
      pacingScore: selected.pacingScore,
      frequency: selected.frequency,
      eligibility: selected.eligibility,
      metadata: { deliveryId, phase: "3A", internalTest: request.internalTest === true },
    });
  });

  const ad = {
    ...safeCreativeDTO(selected.creative),
    campaignId: selected.campaign.id,
    advertiserId: selected.campaign.advertiserId,
    placement,
    sponsoredLabel: "Sponsored",
    impressionToken: token,
    clickToken,
    deliveryToken: token,
    deliveryId,
    traceId,
    controls: adControls(),
    why: whyCopy(placement, request.contextualCategory),
  };
  ad.impressionToken = impressionToken;
  return deliveryResponse(ad, { deliveryId, traceId, token, expiresAt, internalTest: request.internalTest === true, paidDeliveryEnabled: config.paidDeliveryEnabled }, null, config);
}

export async function verifyDeliveryToken(prisma: PrismaClient, token: string, expected: { campaignId?: string; placement?: string } = {}): Promise<{ ok: boolean; error?: string; payload?: any; tokenRow?: any }> {
  await ensureAdsTables(prisma);
  const parsed = parseToken(token);
  if (!parsed.ok) return { ok: false, error: parsed.error };
  if (expected.campaignId && parsed.payload.campaignId !== expected.campaignId) return { ok: false, error: "tampered_campaign_id" };
  if (expected.placement && parsed.payload.placement !== expected.placement) return { ok: false, error: "tampered_placement" };
  if (new Date(parsed.payload.expiresAt).getTime() < Date.now()) return { ok: false, error: "expired_delivery_token" };
  const row = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdDeliveryToken" WHERE "tokenHash" = ? LIMIT 1`, hash(token)))[0];
  if (!row) return { ok: false, error: "unknown_delivery_token" };
  if (row.deliveryId && row.deliveryId !== parsed.payload.deliveryId) return { ok: false, error: "tampered_delivery_id" };
  if (row.campaignId !== parsed.payload.campaignId || row.placement !== parsed.payload.placement) return { ok: false, error: "tampered_delivery_token" };
  if (row.impressionId || row.clickId || row.status === "consumed") return { ok: false, error: "duplicate_delivery" };
  return { ok: true, payload: parsed.payload, tokenRow: row };
}

async function screenCandidate(prisma: PrismaClient, campaign: any, request: AdsDeliveryRequest, config: ReturnType<typeof adsDeliveryConfig>, now: Date): Promise<
  | { ok: true; candidate: DeliveryCandidate }
  | { ok: false; reason: string; creative?: any; eligibility?: any; frequency?: FrequencySnapshot; pacingScore?: number }
> {
  const eligibility = await evaluateAdsCampaignEligibility(prisma, campaign.id, { now, persist: true });
  if (!eligibility.isEligible || eligibility.resultingRecommendedState !== "eligibleForDelivery") return { ok: false, reason: firstReason(eligibility), eligibility };
  if (request.blockedAdvertiserIds?.has(campaign.advertiserId)) return { ok: false, reason: "advertiser_blocked_by_viewer", eligibility };
  if (request.isMinor && !minorSafeCampaign(campaign)) return { ok: false, reason: "minor_policy_block", eligibility };
  if (!objectiveMatchesPlacement(campaign.objective, campaign.destinationType, request.placement)) return { ok: false, reason: "objective_or_destination_placement_mismatch", eligibility };
  if (!(await audienceMatches(prisma, campaign.id, request))) return { ok: false, reason: "audience_mismatch", eligibility };

  const [creative] = await prisma.$queryRawUnsafe<any[]>(
    `SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "status" = 'approved' AND "moderationStatus" = 'approved' AND "deletedAt" IS NULL ORDER BY "version" DESC, "updatedAt" DESC LIMIT 1`,
    campaign.id,
  );
  if (!creative) return { ok: false, reason: "no_approved_creative", eligibility };
  const [budget] = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, campaign.id);
  if (!budget || Number(budget.remainingMinor ?? 0) <= 0) return { ok: false, reason: "budget_exhausted", creative, eligibility };
  if (Number(budget.dailyBudgetMinor ?? 0) > 0) {
    const spentToday = await dailySpend(prisma, campaign.id);
    if (spentToday >= Number(budget.dailyBudgetMinor)) return { ok: false, reason: "daily_budget_exhausted", creative, eligibility };
  }
  const frequency = await frequencySnapshot(prisma, campaign, request.viewerHash, config);
  if (frequency.campaignHour >= frequency.campaignHourCap || frequency.campaignDay >= frequency.campaignDayCap || frequency.advertiserDay >= frequency.advertiserDayCap) {
    return { ok: false, reason: "frequency_exceeded", creative, eligibility, frequency };
  }
  const pacingScore = pacingScoreFor(campaign, budget, now);
  if (pacingScore <= -1) return { ok: false, reason: "pacing_throttled", creative, eligibility, frequency, pacingScore };
  return { ok: true, candidate: { campaign, creative, budget, eligibility, frequency, pacingScore } };
}

async function recordAttempt(prisma: PrismaClient, input: {
  traceId: string;
  campaign: any | null;
  creative: any | null;
  viewerHash: string;
  placement: string;
  decision: string;
  reason: string | null;
  country?: string;
  deviceClass?: string;
  pacingScore: number;
  frequency: FrequencySnapshot | null;
  eligibility: any | null;
  metadata: Record<string, any>;
}): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "AdDeliveryAttempt" ("id", "traceId", "campaignId", "advertiserId", "creativeId", "creativeVersion", "viewerHash", "placement", "decision", "reason", "country", "deviceClass", "pacingScore", "frequencySnapshotJson", "eligibilitySnapshotJson", "metadataJson")
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    randomId("adattempt"),
    input.traceId,
    input.campaign?.id ?? null,
    input.campaign?.advertiserId ?? null,
    input.creative?.id ?? null,
    input.creative ? Number(input.creative.version ?? input.creative.revision ?? 1) : null,
    input.viewerHash,
    input.placement,
    input.decision,
    input.reason,
    input.country?.toUpperCase() ?? null,
    input.deviceClass ?? null,
    input.pacingScore,
    JSON.stringify(input.frequency ?? {}),
    JSON.stringify(input.eligibility ? { isEligible: input.eligibility.isEligible, blockers: input.eligibility.blockingReasons, warnings: input.eligibility.warnings } : {}),
    JSON.stringify(input.metadata),
  );
}

function deliveryResponse(ad: any | null, delivery: DeliveryDecision["delivery"], reason: string | null, config: ReturnType<typeof adsDeliveryConfig>): DeliveryDecision {
  return {
    ok: true,
    ad,
    reason,
    delivery,
    deliveryStatus: {
      paidDeliveryEnabled: config.paidDeliveryEnabled,
      internalDeliveryEnabled: config.internalDeliveryEnabled,
      publicDeliveryBlocked: !config.paidDeliveryEnabled,
    },
  };
}

async function audienceMatches(prisma: PrismaClient, campaignId: string, request: AdsDeliveryRequest): Promise<boolean> {
  const rules = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdAudienceRule" WHERE "campaignId" = ?`, campaignId);
  for (const rule of rules) {
    const type = String(rule.ruleType ?? "");
    const value = String(rule.ruleValue ?? "").toLowerCase();
    if (type === "country" && request.country && value !== request.country.toLowerCase()) return false;
    if (type === "device_family" && request.deviceClass && value !== request.deviceClass.toLowerCase()) return false;
  }
  return true;
}

async function dailySpend(prisma: PrismaClient, campaignId: string): Promise<number> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT COALESCE(SUM("spendMinor"), 0) AS "spent" FROM "AdDailyMetric" WHERE "campaignId" = ? AND "metricDate" = ?`, campaignId, today());
  return Number(rows[0]?.spent ?? 0);
}

async function frequencySnapshot(prisma: PrismaClient, campaign: any, viewerHash: string, config: ReturnType<typeof adsDeliveryConfig>): Promise<FrequencySnapshot> {
  const [campaignHour, campaignDay, advertiserDay] = await Promise.all([
    countAttempts(prisma, `campaignId = ? AND "viewerHash" = ? AND "createdAt" >= datetime('now','-1 hour')`, [campaign.id, viewerHash]),
    countAttempts(prisma, `campaignId = ? AND "viewerHash" = ? AND "createdAt" >= datetime('now','-1 day')`, [campaign.id, viewerHash]),
    countAttempts(prisma, `advertiserId = ? AND "viewerHash" = ? AND "createdAt" >= datetime('now','-1 day')`, [campaign.advertiserId, viewerHash]),
  ]);
  return {
    campaignHour,
    campaignDay,
    advertiserDay,
    campaignHourCap: config.frequencyCaps.campaignHour,
    campaignDayCap: config.frequencyCaps.campaignDay,
    advertiserDayCap: config.frequencyCaps.advertiserDay,
  };
}

async function countAttempts(prisma: PrismaClient, where: string, values: unknown[]): Promise<number> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT COUNT(*) AS "count" FROM "AdDeliveryAttempt" WHERE "decision" = 'delivered' AND ${where}`, ...values);
  return Number(rows[0]?.count ?? 0);
}

function pacingScoreFor(campaign: any, budget: any, now: Date): number {
  const remaining = Number(budget.remainingMinor ?? 0);
  const funded = Math.max(1, Number(budget.fundedMinor ?? campaign.fundedMinor ?? campaign.lifetimeBudgetMinor ?? 1));
  const spent = Math.max(0, Number(budget.spentMinor ?? campaign.spentMinor ?? 0));
  const start = campaign.startAt ? new Date(campaign.startAt).getTime() : now.getTime() - 60_000;
  const end = campaign.endAt ? new Date(campaign.endAt).getTime() : now.getTime() + 86_400_000;
  const duration = Math.max(1, end - start);
  const elapsed = Math.min(Math.max(now.getTime() - start, 0), duration);
  const scheduleProgress = elapsed / duration;
  const spendProgress = spent / funded;
  const remainingRatio = remaining / funded;
  const underPacedBoost = Math.max(-1, Math.min(1, scheduleProgress - spendProgress));
  return remainingRatio + underPacedBoost;
}

function objectiveMatchesPlacement(objective: string, destinationType: string, placement: string): boolean {
  const normalizedObjective = String(objective ?? "");
  const normalizedDestination = String(destinationType ?? "");
  if (normalizedObjective === "promote_shop") return ["shop_discovery", "marketplace_results", "content_feed"].includes(placement) && ["shop", "external_url"].includes(normalizedDestination);
  if (normalizedObjective === "promote_product" || normalizedObjective === "product_sales") return ["shop_discovery", "marketplace_results", "content_feed"].includes(placement) && ["product", "shop", "external_url"].includes(normalizedDestination);
  if (normalizedObjective === "promote_site" || normalizedObjective === "website_visits") return ["site_discovery", "content_feed", "featured_profile"].includes(placement) && ["site", "external_url"].includes(normalizedDestination);
  if (normalizedObjective === "promote_community") return ["community_discovery", "content_feed"].includes(placement) && ["community", "external_url"].includes(normalizedDestination);
  if (normalizedObjective === "profile_visits") return ["featured_profile", "content_feed"].includes(placement) && ["profile", "external_url"].includes(normalizedDestination);
  if (normalizedObjective === "event_promotion") return ["featured_event", "content_feed"].includes(placement) && ["event", "external_url"].includes(normalizedDestination);
  return placement === "content_feed";
}

function parseToken(token: string): { ok: true; payload: any } | { ok: false; error: string } {
  const parts = token.split(".");
  if (parts.length !== 2) return { ok: false, error: "malformed_delivery_token" };
  const [encodedPayload, signature] = parts;
  const expected = sign(encodedPayload);
  if (!safeEqual(signature, expected)) return { ok: false, error: "invalid_signature" };
  try {
    return { ok: true, payload: JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8")) };
  } catch {
    return { ok: false, error: "invalid_payload" };
  }
}

function sign(encodedPayload: string): string {
  return crypto.createHmac("sha256", deliverySecret()).update(encodedPayload).digest("base64url");
}

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function deliverySecret(): string {
  return process.env.ONEWAY_ADS_DELIVERY_TOKEN_SECRET || process.env.JWT_SECRET || process.env.ONEWAY_JWT_SECRET || "dev-oneway-ads-delivery-secret";
}

function adsDeliveryConfig() {
  return {
    adsEnabled: envFlag("ONEWAY_ADS_ENABLED", true),
    paidDeliveryEnabled: envFlag("ONEWAY_ADS_PAID_DELIVERY_ENABLED", false),
    internalDeliveryEnabled: envFlag("ONEWAY_ADS_INTERNAL_DELIVERY_ENABLED", false),
    enabledPlacements: csvEnv("ONEWAY_ADS_ENABLED_PLACEMENTS", "shop_discovery,marketplace_results,content_feed"),
    tokenTtlSeconds: numberEnv("ONEWAY_ADS_DELIVERY_TOKEN_TTL_SECONDS", 600),
    internalTesterUserIds: csvEnv("ONEWAY_ADS_INTERNAL_TESTER_USER_IDS", ""),
    frequencyCaps: {
      campaignHour: numberEnv("ONEWAY_ADS_FREQ_CAMPAIGN_HOUR", 2),
      campaignDay: numberEnv("ONEWAY_ADS_FREQ_CAMPAIGN_DAY", 5),
      advertiserDay: numberEnv("ONEWAY_ADS_FREQ_ADVERTISER_DAY", 12),
    },
  };
}

function internalTesterAllowed(ownerUserId: string | undefined, viewerHash: string, config: ReturnType<typeof adsDeliveryConfig>): boolean {
  if (!config.internalTesterUserIds.length) return true;
  return Boolean(ownerUserId && config.internalTesterUserIds.includes(ownerUserId)) || config.internalTesterUserIds.includes(viewerHash);
}

function firstReason(eligibility: any): string {
  return eligibility?.blockingReasons?.[0]?.code ?? "campaign_failed_activation";
}

function minorSafeCampaign(campaign: any): boolean {
  const text = `${campaign.name ?? ""} ${campaign.objective ?? ""} ${campaign.destinationType ?? ""}`.toLowerCase();
  return !/\b(alcohol|gambling|casino|dating|adult|weapon|vape|tobacco)\b/.test(text);
}

function safeCreativeDTO(row: any): any {
  return {
    id: row.id,
    campaignId: row.campaignId,
    version: Number(row.version ?? 1),
    status: row.status,
    moderationStatus: row.moderationStatus,
    headline: row.headline,
    bodyText: row.bodyText,
    cta: row.cta,
    logoURL: row.logoURL,
    imageURL: row.imageURL,
    videoURL: row.videoURL,
    thumbnailURL: row.thumbnailURL,
    accessibilityDescription: row.accessibilityDescription,
    policyFlags: parseJson(row.policyFlagsJson, []),
  };
}

function adControls(): any {
  return { hide: true, report: true, why: true, privacy: true };
}

function whyCopy(placement: string, contextualCategory?: string): string {
  const context = contextualCategory ? ` near ${contextualCategory}` : "";
  return `This sponsored card matched the ${placement.replace(/_/g, " ")} placement${context}. OneWay Ads do not inspect private chats, calls, Chirp, or encrypted messages.`;
}

function parseJson<T>(value: unknown, fallback: T): T {
  try {
    if (typeof value !== "string") return fallback;
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function hash(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
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
