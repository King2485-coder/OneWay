import type { PrismaClient } from "@prisma/client";
import crypto from "node:crypto";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { toProductDTO } from "../services/catalog";
import { createStripeClient, stripeConfigured } from "../services/stripe";
import { ensureAdsTables } from "../services/ads/AdsTables";
import { creativeFingerprint, evaluateAdsCampaignEligibility } from "../services/ads/AdsCampaignEligibilityService";
import { evaluateAndTransitionAdsCampaign, transitionAdsCampaignState } from "../services/ads/AdsCampaignStateService";
import { requestAdDelivery, verifyDeliveryToken } from "../services/ads/AdsDeliveryEngine";
import { getAdsEventSummary, getAdsSpendSnapshot, reconcileAdsSpend, verifyAndRecordAdEvent } from "../services/ads/AdsVerifiedEventService";

const objectives = [
  "promote_shop",
  "promote_product",
  "promote_site",
  "promote_community",
  "website_visits",
  "product_sales",
  "profile_visits",
  "event_promotion",
  "app_engagement",
] as const;

const placements = [
  "shop_discovery",
  "marketplace_results",
  "site_discovery",
  "community_discovery",
  "content_feed",
  "featured_profile",
  "featured_event",
] as const;

const campaignStatuses = [
  "draft",
  "submitted",
  "fundingRequired",
  "paymentPending",
  "underReview",
  "approved",
  "readyForActivation",
  "scheduled",
  "eligibleForDelivery",
  "active",
  "paused",
  "budgetExhausted",
  "completed",
  "rejected",
  "revisionRequired",
  "canceled",
  "suspended",
] as const;

const advertiserSchema = z.object({
  businessName: z.string().trim().min(2).max(120),
  displayName: z.string().trim().min(2).max(120),
  businessType: z.string().trim().min(2).max(80).default("creator"),
  websiteURL: z.string().url().optional(),
  oneWaySiteId: z.string().trim().min(1).max(120).optional(),
  oneWayShopId: z.string().trim().min(1).max(120).optional(),
  associatedProfileId: z.string().trim().min(1).max(120).optional(),
  associatedCommunityId: z.string().trim().min(1).max(120).optional(),
  contactEmail: z.string().email(),
  country: z.string().trim().length(2).default("US"),
  state: z.string().trim().max(80).optional(),
  city: z.string().trim().max(100).optional(),
});

const advertiserPatchSchema = advertiserSchema.partial();

const campaignCreateSchema = z.object({
  advertiserId: z.string().trim().min(1),
  name: z.string().trim().min(2).max(140),
  objective: z.enum(objectives),
  internalNotes: z.string().trim().max(1000).optional(),
});

const campaignPatchSchema = z.object({
  name: z.string().trim().min(2).max(140).optional(),
  internalNotes: z.string().trim().max(1000).optional(),
  destinationType: z.enum(["shop", "product", "site", "community", "profile", "external_url", "event"]).optional(),
  destinationId: z.string().trim().min(1).max(180).optional(),
  destinationURL: z.string().url().optional(),
  dailyBudgetMinor: z.number().int().nonnegative().optional(),
  lifetimeBudgetMinor: z.number().int().nonnegative().optional(),
  maxSpendMinor: z.number().int().nonnegative().optional(),
  currency: z.string().trim().length(3).optional(),
  startAt: z.string().datetime().optional(),
  endAt: z.string().datetime().optional(),
  scheduleTimezone: z.string().trim().min(1).max(80).optional(),
  currentBuilderStep: z.enum(["profile", "objective", "destination", "creative", "placements", "budget", "review"]).optional(),
  placements: z.array(z.enum(placements)).optional(),
  audienceRules: z.array(z.object({
    ruleType: z.enum(["country", "state", "city", "radius", "language", "interest", "community_category", "context", "adult_age_range", "returning_user", "device_family"]),
    ruleValue: z.string().trim().min(1).max(160),
  })).optional(),
});

const campaignSubmitSchema = z.object({
  clientSubmissionId: z.string().trim().min(8).max(180).optional(),
});

const creativeSchema = z.object({
  headline: z.string().trim().min(3).max(80),
  bodyText: z.string().trim().min(8).max(240),
  cta: z.enum(["Shop Now", "Learn More", "Visit Site", "View Product", "Join Community", "View Profile", "Get Tickets", "Contact Business"]),
  logoURL: z.string().url().optional(),
  imageURL: z.string().url().optional(),
  videoURL: z.string().url().optional(),
  thumbnailURL: z.string().url().optional(),
  accessibilityDescription: z.string().trim().max(240).optional(),
});

const fundSchema = z.object({
  amountMinor: z.number().int().min(500).max(500000),
  currency: z.string().trim().length(3).default("USD"),
  idempotencyKey: z.string().trim().min(8).max(180).optional(),
});

const deliverySchema = z.object({
  placement: z.enum(placements),
  contextualCategory: z.string().trim().max(100).optional(),
  deviceClass: z.string().trim().max(40).optional(),
  country: z.string().trim().length(2).optional(),
  viewerReference: z.string().trim().max(160).optional(),
  isMinor: z.boolean().optional(),
  internalTest: z.boolean().optional(),
});

const deliveryPreviewSchema = z.object({
  placement: z.enum(placements),
  contextualCategory: z.string().trim().max(100).optional(),
  deviceClass: z.string().trim().max(40).optional(),
  country: z.string().trim().length(2).optional(),
  viewerReference: z.string().trim().max(160).optional(),
  isMinor: z.boolean().optional(),
});

const verifyDeliveryTokenSchema = z.object({
  token: z.string().trim().min(20),
  campaignId: z.string().trim().min(1).optional(),
  placement: z.enum(placements).optional(),
});

const impressionSchema = z.object({
  token: z.string().trim().min(20),
  visibleAreaPercent: z.number().min(0).max(100),
  durationMs: z.number().int().nonnegative(),
  deviceClass: z.string().trim().max(40).optional(),
  clientEventId: z.string().trim().min(4).max(180).optional(),
  occurredAt: z.string().datetime().optional(),
  sessionReference: z.string().trim().max(180).optional(),
  country: z.string().trim().length(2).optional(),
});

const clickSchema = z.object({
  token: z.string().trim().min(20),
  clientEventId: z.string().trim().min(4).max(180).optional(),
  occurredAt: z.string().datetime().optional(),
  sessionReference: z.string().trim().max(180).optional(),
  country: z.string().trim().length(2).optional(),
  deviceClass: z.string().trim().max(40).optional(),
});

const conversionSchema = z.object({
  campaignId: z.string().trim().min(1),
  creativeId: z.string().trim().min(1).optional(),
  conversionType: z.enum(["product_purchase", "shop_visit", "product_view", "add_to_cart", "checkout_started", "checkout_completed", "site_visit", "community_joined", "profile_followed", "event_registration"]),
  sourceEntityType: z.string().trim().max(80).optional(),
  sourceEntityId: z.string().trim().max(160).optional(),
  amountMinor: z.number().int().nonnegative().default(0),
  currency: z.string().trim().length(3).default("USD"),
  verified: z.boolean().default(false),
});

const reportAdSchema = z.object({
  reason: z.enum(["scam_or_fraud", "misleading_content", "inappropriate_content", "prohibited_product", "impersonation", "offensive_content", "irrelevant_or_repetitive", "other"]),
  details: z.string().trim().max(1000).optional(),
  placement: z.string().trim().max(100).optional(),
});

const preferencesSchema = z.object({
  contextualCategories: z.array(z.string().trim().min(1).max(80)).max(40).optional(),
  locationBasedAdsEnabled: z.boolean().optional(),
  reducedRepetitionEnabled: z.boolean().optional(),
  minorContextualOnly: z.boolean().optional(),
});

const adminDecisionSchema = z.object({
  reason: z.string().trim().max(500).optional(),
  notes: z.string().trim().max(1000).optional(),
});

const createLegacyAdSchema = z.object({
  productId: z.string().uuid(),
  budget: z.number().positive(),
  featured: z.boolean().optional(),
});

const legacyTrackSchema = z.object({ adId: z.string().uuid() });

export function adsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.use(async (_req, _res, next) => {
    try {
      await ensureAdsTables(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/config", (_req, res) => {
    res.json({ ok: true, config: adsConfig() });
  });

  router.post("/advertisers", authMiddleware, async (req, res) => {
    if (!adsConfig().advertiserCreationEnabled) return res.status(403).json({ ok: false, error: "ads_advertiser_creation_disabled" });
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = advertiserSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const existing = await findDuplicateAdvertiser(prisma, userId, parsed.data.oneWayShopId, parsed.data.oneWaySiteId);
    if (existing) return res.status(200).json({ ok: true, advertiser: existing, idempotentReplay: true });
    const id = randomId("adv");
    await prisma.$executeRawUnsafe(
      `INSERT INTO "AdvertiserProfile" ("id", "ownerUserId", "businessName", "displayName", "businessType", "websiteURL", "oneWaySiteId", "oneWayShopId", "associatedProfileId", "associatedCommunityId", "contactEmail", "country", "state", "city", "status", "verificationStatus")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pendingVerification', 'pending')`,
      id, userId, parsed.data.businessName, parsed.data.displayName, parsed.data.businessType, parsed.data.websiteURL ?? null,
      parsed.data.oneWaySiteId ?? null, parsed.data.oneWayShopId ?? null, parsed.data.associatedProfileId ?? null, parsed.data.associatedCommunityId ?? null,
      parsed.data.contactEmail, parsed.data.country.toUpperCase(), parsed.data.state ?? null, parsed.data.city ?? null,
    );
    await audit(prisma, userId, "ads.advertiser.created", "AdvertiserProfile", id, {});
    res.status(201).json({ ok: true, advertiser: await advertiserById(prisma, id, userId) });
  });

  router.get("/advertisers", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdvertiserProfile" WHERE "ownerUserId" = ? AND "deletedAt" IS NULL ORDER BY "createdAt" DESC`, userId);
    res.json({ ok: true, advertisers: rows.map(advertiserDTO) });
  });

  router.get("/advertisers/:id", authMiddleware, async (req, res) => {
    const row = await advertiserById(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!row) return res.status(404).json({ ok: false, error: "advertiser_not_found" });
    res.json({ ok: true, advertiser: row });
  });

  router.patch("/advertisers/:id", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = advertiserPatchSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const existing = await advertiserById(prisma, routeParam(req, "id"), userId);
    if (!existing) return res.status(404).json({ ok: false, error: "advertiser_not_found" });
    const next = { ...existing, ...parsed.data };
    await prisma.$executeRawUnsafe(
      `UPDATE "AdvertiserProfile" SET "businessName" = ?, "displayName" = ?, "businessType" = ?, "websiteURL" = ?, "oneWaySiteId" = ?, "oneWayShopId" = ?, "associatedProfileId" = ?, "associatedCommunityId" = ?, "contactEmail" = ?, "country" = ?, "state" = ?, "city" = ?, "version" = "version" + 1, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`,
      next.businessName, next.displayName, next.businessType, next.websiteURL ?? null, next.oneWaySiteId ?? null, next.oneWayShopId ?? null,
      next.associatedProfileId ?? null, next.associatedCommunityId ?? null, next.contactEmail, String(next.country).toUpperCase(), next.state ?? null, next.city ?? null, routeParam(req, "id"), userId,
    );
    await audit(prisma, userId, "ads.advertiser.updated", "AdvertiserProfile", routeParam(req, "id"), {});
    res.json({ ok: true, advertiser: await advertiserById(prisma, routeParam(req, "id"), userId) });
  });

  router.delete("/advertisers/:id", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const existing = await advertiserById(prisma, routeParam(req, "id"), userId);
    if (!existing) return res.status(404).json({ ok: false, error: "advertiser_not_found" });
    const activeRows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT "id" FROM "AdCampaign" WHERE "advertiserId" = ? AND "ownerUserId" = ? AND "deletedAt" IS NULL AND "status" NOT IN ('draft','rejected','canceled','completed') LIMIT 1`,
      routeParam(req, "id"),
      userId,
    );
    if (activeRows.length) return res.status(409).json({ ok: false, error: "advertiser_has_locked_campaigns" });
    await prisma.$executeRawUnsafe(`UPDATE "AdvertiserProfile" SET "status" = 'closed', "deletedAt" = CURRENT_TIMESTAMP, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`, routeParam(req, "id"), userId);
    await audit(prisma, userId, "ads.advertiser.closed", "AdvertiserProfile", routeParam(req, "id"), {});
    res.json({ ok: true });
  });

  router.get("/manager/home", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaigns = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "ownerUserId" = ? AND "deletedAt" IS NULL`, userId);
    const metrics = await overviewMetrics(prisma, userId);
    res.json({
      ok: true,
      config: adsConfig(),
      statusCounts: countBy(campaigns, "status"),
      metrics,
      primaryActions: ["Create Campaign Draft", "Manage Advertiser Profile", "Review Policy Status"],
    });
  });

  router.post("/campaigns", authMiddleware, async (req, res) => {
    const config = adsConfig();
    if (!config.campaignCreationEnabled) return res.status(403).json({ ok: false, error: "ads_campaigns_disabled" });
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = campaignCreateSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    if (!config.enabledObjectives.includes(parsed.data.objective)) return res.status(403).json({ ok: false, error: "ads_objective_disabled" });
    const advertiser = await advertiserById(prisma, parsed.data.advertiserId, userId);
    if (!advertiser) return res.status(404).json({ ok: false, error: "advertiser_not_found" });
    if (["restricted", "suspended", "closed"].includes(advertiser.status)) return res.status(403).json({ ok: false, error: "advertiser_not_eligible" });
    const id = randomId("adcamp");
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(
        `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "internalNotes", "currency") VALUES (?, ?, ?, ?, ?, ?, 'USD')`,
        id, advertiser.id, userId, parsed.data.name, parsed.data.objective, parsed.data.internalNotes ?? null,
      );
      await tx.$executeRawUnsafe(`INSERT INTO "AdBudget" ("id", "campaignId", "currency") VALUES (?, ?, 'USD')`, randomId("adbudget"), id);
    });
    await audit(prisma, userId, "ads.campaign.created", "AdCampaign", id, { objective: parsed.data.objective });
    res.status(201).json({ ok: true, campaign: await campaignDTO(prisma, id, userId) });
  });

  router.get("/campaigns", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "ownerUserId" = ? AND "deletedAt" IS NULL ORDER BY "updatedAt" DESC`, userId);
    res.json({ ok: true, campaigns: await Promise.all(rows.map((row) => hydrateCampaign(prisma, row))) });
  });

  router.post("/destinations/validate", authMiddleware, async (req, res) => {
    const schema = z.object({
      destinationType: z.enum(["shop", "product", "site", "community", "profile", "external_url", "event"]),
      destinationId: z.string().trim().min(1).max(180).optional(),
      destinationURL: z.string().url().optional(),
    });
    const parsed = schema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const validation = await validateDestination(prisma, (req as AuthenticatedRequest).userId, parsed.data.destinationType, parsed.data.destinationId, parsed.data.destinationURL);
    res.status(validation.ok ? 200 : 400).json({ ok: validation.ok, validation });
  });

  router.get("/campaigns/:id", authMiddleware, async (req, res) => {
    const campaign = await campaignDTO(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, campaign });
  });

  router.get("/campaigns/:id/validation", authMiddleware, async (req, res) => {
    const validation = await validateCampaignForSubmission(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    res.json({ ok: true, validation });
  });

  router.patch("/campaigns/:id", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = campaignPatchSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const existing = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!existing) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (!["draft", "rejected", "paused"].includes(existing.status)) return res.status(409).json({ ok: false, error: "campaign_locked_for_review_or_delivery" });
    if (parsed.data.destinationURL && !safeDestinationURL(parsed.data.destinationURL)) return res.status(400).json({ ok: false, error: "unsafe_destination_url" });
    const config = adsConfig();
    if (parsed.data.placements?.some((placement) => !config.enabledPlacements.includes(placement))) return res.status(403).json({ ok: false, error: "ads_placement_disabled" });
    const destinationType = parsed.data.destinationType ?? existing.destinationType;
    const destinationId = parsed.data.destinationId ?? existing.destinationId;
    const destinationURL = parsed.data.destinationURL ?? existing.destinationURL;
    if (destinationType && (destinationId || destinationURL)) {
      const destinationValidation = await validateDestination(prisma, userId, destinationType, destinationId, destinationURL);
      if (!destinationValidation.ok) return res.status(400).json({ ok: false, error: "invalid_ad_destination", validation: destinationValidation });
    }
    if (parsed.data.startAt && parsed.data.endAt && new Date(parsed.data.endAt).getTime() <= new Date(parsed.data.startAt).getTime()) {
      return res.status(400).json({ ok: false, error: "invalid_schedule", message: "Campaign end date must be after start date." });
    }
    for (const rule of parsed.data.audienceRules ?? []) {
      if (isSensitiveTargeting(rule.ruleType, rule.ruleValue)) return res.status(400).json({ ok: false, error: "sensitive_targeting_rejected" });
    }
    const completionState = draftCompletionState({
      ...existing,
      ...parsed.data,
      destinationType,
      destinationId,
      destinationURL,
      placements: parsed.data.placements,
    });
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(
        `UPDATE "AdCampaign" SET "name" = COALESCE(?, "name"), "internalNotes" = COALESCE(?, "internalNotes"), "destinationType" = COALESCE(?, "destinationType"), "destinationId" = COALESCE(?, "destinationId"), "destinationURL" = COALESCE(?, "destinationURL"), "dailyBudgetMinor" = COALESCE(?, "dailyBudgetMinor"), "lifetimeBudgetMinor" = COALESCE(?, "lifetimeBudgetMinor"), "maxSpendMinor" = COALESCE(?, "maxSpendMinor"), "currency" = COALESCE(?, "currency"), "startAt" = COALESCE(?, "startAt"), "endAt" = COALESCE(?, "endAt"), "scheduleTimezone" = COALESCE(?, "scheduleTimezone"), "currentBuilderStep" = COALESCE(?, "currentBuilderStep"), "draftCompletionStateJson" = ?, "version" = "version" + 1, "moderationStatus" = CASE WHEN "status" = 'rejected' THEN 'revisionRequired' ELSE "moderationStatus" END, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`,
        parsed.data.name ?? null, parsed.data.internalNotes ?? null, parsed.data.destinationType ?? null, parsed.data.destinationId ?? null, parsed.data.destinationURL ?? null,
        parsed.data.dailyBudgetMinor ?? null, parsed.data.lifetimeBudgetMinor ?? null, parsed.data.maxSpendMinor ?? null, parsed.data.currency?.toUpperCase() ?? null,
        parsed.data.startAt ?? null, parsed.data.endAt ?? null, parsed.data.scheduleTimezone ?? null, parsed.data.currentBuilderStep ?? null, JSON.stringify(completionState), routeParam(req, "id"), userId,
      );
      if (parsed.data.placements) {
        await tx.$executeRawUnsafe(`DELETE FROM "AdPlacementSelection" WHERE "campaignId" = ?`, routeParam(req, "id"));
        for (const placement of parsed.data.placements) {
          await tx.$executeRawUnsafe(`INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, ?, 1)`, randomId("adplace"), routeParam(req, "id"), placement);
        }
      }
      if (parsed.data.audienceRules) {
        await tx.$executeRawUnsafe(`DELETE FROM "AdAudienceRule" WHERE "campaignId" = ?`, routeParam(req, "id"));
        for (const rule of parsed.data.audienceRules) {
          await tx.$executeRawUnsafe(`INSERT INTO "AdAudienceRule" ("id", "campaignId", "ruleType", "ruleValue") VALUES (?, ?, ?, ?)`, randomId("adaud"), routeParam(req, "id"), rule.ruleType, rule.ruleValue);
        }
      }
      await tx.$executeRawUnsafe(`UPDATE "AdBudget" SET "dailyBudgetMinor" = COALESCE(?, "dailyBudgetMinor"), "lifetimeBudgetMinor" = COALESCE(?, "lifetimeBudgetMinor"), "remainingMinor" = MAX("fundedMinor" - "spentMinor", 0), "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ?`, parsed.data.dailyBudgetMinor ?? null, parsed.data.lifetimeBudgetMinor ?? null, routeParam(req, "id"));
    });
    await audit(prisma, userId, "ads.campaign.updated", "AdCampaign", routeParam(req, "id"), {});
    res.json({ ok: true, campaign: await campaignDTO(prisma, routeParam(req, "id"), userId) });
  });

  router.post("/campaigns/:id/submit", authMiddleware, async (req, res) => {
    const config = adsConfig();
    if (!config.campaignSubmissionEnabled || !config.moderationEnabled) return res.status(403).json({ ok: false, error: "ads_campaign_submission_disabled" });
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = campaignSubmitSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const existing = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!existing) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (["submitted", "underReview"].includes(existing.status)) {
      return res.json({ ok: true, campaign: await campaignDTO(prisma, routeParam(req, "id"), userId), idempotentReplay: true });
    }
    if (!["draft", "rejected"].includes(existing.status)) return res.status(409).json({ ok: false, error: "campaign_locked_for_submission" });
    const validation = await validateCampaignForSubmission(prisma, routeParam(req, "id"), userId);
    if (!validation.ok) return res.status(400).json({ ok: false, error: "campaign_not_ready", validation, missing: validation.missing });
    const snapshot = await campaignDTO(prisma, routeParam(req, "id"), userId);
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(`UPDATE "AdCampaign" SET "status" = 'underReview', "moderationStatus" = 'pendingAutomatedReview', "clientSubmissionId" = COALESCE(?, "clientSubmissionId"), "submittedSnapshotJson" = ?, "submittedAt" = CURRENT_TIMESTAMP, "currentBuilderStep" = 'review', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`, parsed.data.clientSubmissionId ?? null, JSON.stringify(snapshot), routeParam(req, "id"), userId);
      await tx.$executeRawUnsafe(`UPDATE "AdCreative" SET "moderationStatus" = 'pendingAutomatedReview', "status" = 'submitted', "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ?`, routeParam(req, "id"));
      await tx.$executeRawUnsafe(`INSERT INTO "AdModerationReview" ("id", "campaignId", "status", "riskLevel", "reviewerNotes") VALUES (?, ?, 'pendingManualReview', ?, ?)`, randomId("adreview"), routeParam(req, "id"), validation.riskLevel, validation.riskLevel === "medium" ? "Queued for manual review because automated review found policy-sensitive wording." : "Automated review completed; awaiting approval.");
    });
    await audit(prisma, userId, "ads.campaign.submitted", "AdCampaign", routeParam(req, "id"), { riskLevel: validation.riskLevel });
    res.json({ ok: true, campaign: await campaignDTO(prisma, routeParam(req, "id"), userId) });
  });

  router.get("/campaigns/:id/eligibility", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const result = await evaluateAdsCampaignEligibility(prisma, routeParam(req, "id"), { ownerUserId: userId, persist: true });
    if (result.blockingReasons.some((reason) => reason.code === "campaign_missing" || reason.code === "campaign_owner_mismatch")) return res.status(404).json({ ok: false, error: "campaign_not_found", eligibility: result });
    res.json({ ok: true, eligibility: result });
  });

  router.post("/campaigns/:id/evaluate-activation", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const transition = await evaluateAndTransitionAdsCampaign(prisma, routeParam(req, "id"), { actorType: "user", actorId: userId }, { ownerUserId: userId, reason: "owner_requested_activation_evaluation" });
    if (transition.error === "campaign_not_found") return res.status(404).json({ ok: false, error: "campaign_not_found", eligibility: transition.eligibility });
    res.status(transition.ok ? 200 : 409).json({ ok: transition.ok, transition, eligibility: transition.eligibility, campaign: transition.campaign ? await campaignDTO(prisma, routeParam(req, "id"), userId) : null });
  });

  router.post("/campaigns/:id/pause", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (!["readyForActivation", "scheduled", "eligibleForDelivery", "paused"].includes(campaign.status)) return res.status(409).json({ ok: false, error: "campaign_not_pausable" });
    const transition = await transitionAdsCampaignState(prisma, campaign.id, "paused", { actorType: "user", actorId: userId }, "owner_paused_campaign");
    res.status(transition.ok ? 200 : 409).json({ ok: transition.ok, transition, campaign: await campaignDTO(prisma, campaign.id, userId), error: transition.error });
  });

  router.post("/campaigns/:id/resume", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (campaign.status !== "paused") return res.status(409).json({ ok: false, error: "campaign_not_paused" });
    await transitionAdsCampaignState(prisma, campaign.id, "readyForActivation", { actorType: "user", actorId: userId }, "owner_requested_resume");
    const transition = await evaluateAndTransitionAdsCampaign(prisma, campaign.id, { actorType: "user", actorId: userId }, { ownerUserId: userId, reason: "owner_resume_reevaluation" });
    res.status(transition.ok ? 200 : 409).json({ ok: transition.ok, transition, eligibility: transition.eligibility, campaign: await campaignDTO(prisma, campaign.id, userId), error: transition.error });
  });

  router.post("/campaigns/:id/cancel", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (["completed", "canceled"].includes(campaign.status)) return res.json({ ok: true, campaign: await campaignDTO(prisma, campaign.id, userId), idempotentReplay: true });
    const transition = await transitionAdsCampaignState(prisma, campaign.id, "canceled", { actorType: "user", actorId: userId }, "owner_canceled_campaign", { unusedFundsPolicy: "preserve_ledger_no_automatic_refund" });
    res.status(transition.ok ? 200 : 409).json({ ok: transition.ok, transition, campaign: await campaignDTO(prisma, campaign.id, userId), error: transition.error });
  });

  router.post("/campaigns/:id/duplicate", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const source = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!source) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const nextCampaignId = randomId("adcamp");
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(
        `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationId", "destinationURL", "internalNotes", "startAt", "endAt", "dailyBudgetMinor", "lifetimeBudgetMinor", "maxSpendMinor", "currency", "billingModel", "pacingMode", "currentBuilderStep", "draftCompletionStateJson", "scheduleTimezone")
         VALUES (?, ?, ?, ?, ?, 'draft', 'notSubmitted', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        nextCampaignId,
        source.advertiserId,
        userId,
        `${source.name} Copy`,
        source.objective,
        source.destinationType ?? null,
        source.destinationId ?? null,
        source.destinationURL ?? null,
        source.internalNotes ?? null,
        source.startAt ?? null,
        source.endAt ?? null,
        Number(source.dailyBudgetMinor ?? 0),
        Number(source.lifetimeBudgetMinor ?? 0),
        Number(source.maxSpendMinor ?? 0),
        String(source.currency ?? "USD"),
        source.billingModel ?? "PREPAID_CPM",
        source.pacingMode ?? "standard",
        source.currentBuilderStep ?? "review",
        source.draftCompletionStateJson ?? "{}",
        source.scheduleTimezone ?? null,
      );
      await tx.$executeRawUnsafe(`INSERT INTO "AdBudget" ("id", "campaignId", "currency", "dailyBudgetMinor", "lifetimeBudgetMinor") VALUES (?, ?, ?, ?, ?)`, randomId("adbudget"), nextCampaignId, String(source.currency ?? "USD"), Number(source.dailyBudgetMinor ?? 0), Number(source.lifetimeBudgetMinor ?? 0));
      const creatives = await tx.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "deletedAt" IS NULL ORDER BY "createdAt"`, source.id);
      for (const creative of creatives) {
        await tx.$executeRawUnsafe(
          `INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "version", "status", "moderationStatus", "headline", "bodyText", "cta", "logoURL", "imageURL", "videoURL", "thumbnailURL", "destinationPreviewJson", "policyFlagsJson")
           VALUES (?, ?, ?, ?, 1, 'draft', 'notSubmitted', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          randomId("adcre"),
          nextCampaignId,
          source.advertiserId,
          userId,
          creative.headline,
          creative.bodyText,
          creative.cta,
          creative.logoURL ?? null,
          creative.imageURL ?? null,
          creative.videoURL ?? null,
          creative.thumbnailURL ?? null,
          creative.destinationPreviewJson ?? "{}",
          creative.policyFlagsJson ?? "[]",
        );
      }
      const placementRows = await tx.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPlacementSelection" WHERE "campaignId" = ? AND "enabled" = 1`, source.id);
      for (const placement of placementRows) {
        await tx.$executeRawUnsafe(`INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, ?, 1)`, randomId("adplace"), nextCampaignId, placement.placement);
      }
      const audienceRows = await tx.$queryRawUnsafe<any[]>(`SELECT * FROM "AdAudienceRule" WHERE "campaignId" = ?`, source.id);
      for (const rule of audienceRows) {
        await tx.$executeRawUnsafe(`INSERT INTO "AdAudienceRule" ("id", "campaignId", "ruleType", "ruleValue") VALUES (?, ?, ?, ?)`, randomId("adaud"), nextCampaignId, rule.ruleType, rule.ruleValue);
      }
    });
    await audit(prisma, userId, "ads.campaign.duplicated", "AdCampaign", nextCampaignId, { sourceCampaignId: source.id });
    res.status(201).json({ ok: true, campaign: await campaignDTO(prisma, nextCampaignId, userId) });
  });

  router.delete("/campaigns/:id", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (!["draft", "rejected", "canceled"].includes(campaign.status)) return res.status(409).json({ ok: false, error: "campaign_locked_for_delete" });
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(`UPDATE "AdCampaign" SET "status" = 'canceled', "deletedAt" = CURRENT_TIMESTAMP, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`, routeParam(req, "id"), userId);
      await tx.$executeRawUnsafe(`UPDATE "AdCreative" SET "deletedAt" = CURRENT_TIMESTAMP, "status" = 'deleted', "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ? AND "ownerUserId" = ?`, routeParam(req, "id"), userId);
    });
    await audit(prisma, userId, "ads.campaign.deleted", "AdCampaign", routeParam(req, "id"), {});
    res.json({ ok: true });
  });

  router.post("/campaigns/:id/creatives", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = creativeSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (parsed.data.videoURL && !safeDestinationURL(parsed.data.videoURL)) return res.status(400).json({ ok: false, error: "unsafe_video_url" });
    if (parsed.data.imageURL && !safeDestinationURL(parsed.data.imageURL)) return res.status(400).json({ ok: false, error: "unsafe_image_url" });
    const id = randomId("adcre");
    await prisma.$executeRawUnsafe(
      `INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "headline", "bodyText", "cta", "logoURL", "imageURL", "videoURL", "thumbnailURL", "accessibilityDescription", "destinationPreviewJson", "policyFlagsJson")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id, campaign.id, campaign.advertiserId, userId, parsed.data.headline, parsed.data.bodyText, parsed.data.cta, parsed.data.logoURL ?? null, parsed.data.imageURL ?? null, parsed.data.videoURL ?? null, parsed.data.thumbnailURL ?? null,
      parsed.data.accessibilityDescription ?? null,
      JSON.stringify(destinationPreview(campaign)), JSON.stringify(policyFlags(parsed.data.headline, parsed.data.bodyText)),
    );
    await audit(prisma, userId, "ads.creative.created", "AdCreative", id, {});
    res.status(201).json({ ok: true, creative: await creativeById(prisma, id, userId) });
  });

  router.patch("/creatives/:id", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = creativeSchema.partial().safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const creative = await creativeById(prisma, routeParam(req, "id"), userId);
    if (!creative) return res.status(404).json({ ok: false, error: "creative_not_found" });
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(
        `UPDATE "AdCreative" SET "headline" = COALESCE(?, "headline"), "bodyText" = COALESCE(?, "bodyText"), "cta" = COALESCE(?, "cta"), "logoURL" = COALESCE(?, "logoURL"), "imageURL" = COALESCE(?, "imageURL"), "videoURL" = COALESCE(?, "videoURL"), "thumbnailURL" = COALESCE(?, "thumbnailURL"), "accessibilityDescription" = COALESCE(?, "accessibilityDescription"), "version" = "version" + 1, "revision" = COALESCE("revision", 1) + 1, "approvedFingerprint" = NULL, "moderationStatus" = 'revisionRequired', "status" = 'draft', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`,
        parsed.data.headline ?? null, parsed.data.bodyText ?? null, parsed.data.cta ?? null, parsed.data.logoURL ?? null, parsed.data.imageURL ?? null, parsed.data.videoURL ?? null, parsed.data.thumbnailURL ?? null, parsed.data.accessibilityDescription ?? null, routeParam(req, "id"), userId,
      );
      await tx.$executeRawUnsafe(`UPDATE "AdCampaign" SET "currentRevision" = COALESCE("currentRevision", 1) + 1, "status" = CASE WHEN "status" IN ('readyForActivation','scheduled','eligibleForDelivery','active','paused') THEN 'underReview' ELSE "status" END, "moderationStatus" = 'revisionRequired', "eligibilityStateJson" = '{}', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, creative.campaignId);
    });
    await audit(prisma, userId, "ads.creative.updated_requires_review", "AdCreative", routeParam(req, "id"), {});
    res.json({ ok: true, creative: await creativeById(prisma, routeParam(req, "id"), userId) });
  });

  router.delete("/creatives/:id", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const creative = await creativeById(prisma, routeParam(req, "id"), userId);
    if (!creative) return res.status(404).json({ ok: false, error: "creative_not_found" });
    await prisma.$executeRawUnsafe(`UPDATE "AdCreative" SET "deletedAt" = CURRENT_TIMESTAMP, "status" = 'deleted', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`, routeParam(req, "id"), userId);
    await audit(prisma, userId, "ads.creative.deleted", "AdCreative", routeParam(req, "id"), {});
    res.json({ ok: true });
  });

  router.post("/creatives/:id/preview", authMiddleware, async (req, res) => {
    const creative = await creativeById(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!creative) return res.status(404).json({ ok: false, error: "creative_not_found" });
    res.json({ ok: true, preview: safeCreativeDTO(creative), controls: adControls() });
  });

  router.post("/campaigns/:id/fund", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    if (!adsFundingAllowedForUser(userId)) return res.status(403).json({ ok: false, error: "ads_campaign_funding_disabled" });
    const parsed = fundSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    if (!["approved", "fundingRequired", "paymentPending", "readyForActivation"].includes(campaign.status)) return res.status(409).json({ ok: false, error: "campaign_not_ready_for_funding" });
    const advertiser = await advertiserById(prisma, campaign.advertiserId, userId);
    if (!advertiser || ["restricted", "suspended", "closed"].includes(advertiser.status)) return res.status(403).json({ ok: false, error: "advertiser_not_eligible" });
    const amountMinor = Math.max(parsed.data.amountMinor, adsConfig().minimumBudgetMinor);
    const currency = parsed.data.currency.toUpperCase();
    if (Number(campaign.lifetimeBudgetMinor ?? 0) > 0 && amountMinor > Number(campaign.lifetimeBudgetMinor) * 3) return res.status(400).json({ ok: false, error: "funding_amount_exceeds_safe_limit" });
    const existingOpenPayment = (await prisma.$queryRawUnsafe<any[]>(
      `SELECT * FROM "AdPayment" WHERE "campaignId" = ? AND "ownerUserId" = ? AND "amountMinor" = ? AND "currency" = ? AND "status" IN ('requires_payment','processing') ORDER BY "createdAt" DESC LIMIT 1`,
      campaign.id,
      userId,
      amountMinor,
      currency,
    ))[0];
    if (existingOpenPayment) return res.json({ ok: true, payment: adPaymentDTO(existingOpenPayment), balance: await campaignBalance(prisma, campaign.id, userId), idempotentReplay: true });
    const idempotencyKey = parsed.data.idempotencyKey ?? `ads-fund:${campaign.id}:${amountMinor}:${currency}`;
    const existing = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "idempotencyKey" = ? LIMIT 1`, idempotencyKey);
    if (existing[0]) return res.json({ ok: true, payment: adPaymentDTO(existing[0]), balance: await campaignBalance(prisma, campaign.id, userId), idempotentReplay: true });
    const paymentId = randomId("adpay");
    let stripeIntent: any = null;
    const stripe = createStripeClient();
    if (stripe) {
      stripeIntent = await stripe.paymentIntents.create({
        amount: amountMinor,
        currency: currency.toLowerCase(),
        automatic_payment_methods: { enabled: true },
        metadata: {
          paymentDomain: "ads",
          advertiserId: campaign.advertiserId,
          campaignId: campaign.id,
          adsPaymentId: paymentId,
          oneWayUserId: userId,
        },
      }, { idempotencyKey });
    }
    await prisma.$executeRawUnsafe(
      `INSERT INTO "AdPayment" ("id", "campaignId", "advertiserId", "ownerUserId", "stripePaymentIntentId", "amountMinor", "currency", "status", "idempotencyKey", "metadataJson")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      paymentId, campaign.id, campaign.advertiserId, userId, stripeIntent?.id ?? null, amountMinor, currency,
      stripeIntent ? "requires_payment" : "stripe_not_configured", idempotencyKey, JSON.stringify({ stripeConfigured: Boolean(stripe), clientSecretPresent: Boolean(stripeIntent?.client_secret) }),
    );
    await prisma.$executeRawUnsafe(`UPDATE "AdCampaign" SET "status" = 'paymentPending', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, campaign.id);
    await audit(prisma, userId, "ads.payment.created", "AdPayment", paymentId, { campaignId: campaign.id, amountMinor: parsed.data.amountMinor });
    res.status(201).json({ ok: true, payment: adPaymentDTO((await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "id" = ?`, paymentId))[0]), balance: await campaignBalance(prisma, campaign.id, userId), stripe: { configured: Boolean(stripe), paymentIntentId: stripeIntent?.id ?? null, clientSecret: stripeIntent?.client_secret ?? null, publishableKey: process.env.STRIPE_PUBLISHABLE_KEY ?? null } });
  });

  router.get("/campaigns/:id/billing", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const [budgetRows, payments, ledger] = await Promise.all([
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, campaign.id),
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "campaignId" = ? ORDER BY "createdAt" DESC`, campaign.id),
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdLedgerEntry" WHERE "campaignId" = ? ORDER BY "createdAt" DESC`, campaign.id),
    ]);
    res.json({ ok: true, budget: budgetRows[0] ?? null, payments: payments.map(adPaymentDTO), ledger: ledger.map(ledgerDTO) });
  });

  router.get("/campaigns/:id/funding", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const [payments, ledger, receipts] = await Promise.all([
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "campaignId" = ? AND "ownerUserId" = ? ORDER BY "createdAt" DESC`, campaign.id, userId),
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdLedgerEntry" WHERE "campaignId" = ? ORDER BY "createdAt" DESC`, campaign.id),
      prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdReceipt" WHERE "campaignId" = ? AND "ownerUserId" = ? ORDER BY "issuedAt" DESC`, campaign.id, userId),
    ]);
    res.json({ ok: true, balance: await campaignBalance(prisma, campaign.id, userId), payments: payments.map(adPaymentDTO), ledger: ledger.map(ledgerDTO), receipts: receipts.map(receiptDTO) });
  });

  router.post("/campaigns/:id/reconcile-ledger", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const result = await reconcileCampaignLedger(prisma, campaign.id, userId);
    await audit(prisma, userId, "ads.ledger.reconciled", "AdCampaign", campaign.id, result);
    res.json({ ok: true, reconciliation: result, balance: await campaignBalance(prisma, campaign.id, userId) });
  });

  router.get("/invoices", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "ownerUserId" = ? ORDER BY "createdAt" DESC`, userId);
    res.json({ ok: true, invoices: rows.map(adPaymentDTO) });
  });

  router.get("/receipts", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPayment" WHERE "ownerUserId" = ? AND "status" = 'paid' ORDER BY "updatedAt" DESC`, userId);
    res.json({ ok: true, receipts: rows.map(adPaymentDTO) });
  });

  router.get("/campaigns/:id/report", authMiddleware, async (req, res) => {
    if (!adsConfig().reportingEnabled) return res.status(403).json({ ok: false, error: "ads_reporting_disabled" });
    const campaign = await campaignRow(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, report: await campaignReport(prisma, campaign) });
  });

  router.get("/reports/overview", authMiddleware, async (req, res) => {
    if (!adsConfig().reportingEnabled) return res.json({ ok: true, overview: emptyOverview() });
    res.json({ ok: true, overview: await overviewMetrics(prisma, (req as AuthenticatedRequest).userId) });
  });

  router.get("/reports/export", authMiddleware, async (req, res) => {
    if (!adsConfig().reportingEnabled) return res.status(403).json({ ok: false, error: "ads_reporting_disabled" });
    const userId = (req as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT c."id", c."name", c."status", c."spentMinor", COUNT(i."id") AS impressions, COUNT(k."id") AS clicks FROM "AdCampaign" c LEFT JOIN "AdImpression" i ON i."campaignId" = c."id" LEFT JOIN "AdClick" k ON k."campaignId" = c."id" WHERE c."ownerUserId" = ? GROUP BY c."id" ORDER BY c."createdAt" DESC`, userId);
    res.type("text/csv").send(["campaignId,name,status,spentMinor,impressions,clicks", ...rows.map((r) => [r.id, csv(r.name), r.status, r.spentMinor, r.impressions, r.clicks].join(","))].join("\n"));
  });

  router.post("/delivery/request", async (req, res) => {
    const parsed = deliverySchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const viewerHash = viewerHashFor(req, parsed.data.viewerReference);
    const preference = await preferenceFor(prisma, viewerHash);
    const blocked = await blockedAdvertisers(prisma, viewerHash);
    const result = await requestAdDelivery(prisma, {
      placement: parsed.data.placement,
      viewerHash,
      country: parsed.data.country,
      deviceClass: parsed.data.deviceClass,
      contextualCategory: parsed.data.contextualCategory,
      isMinor: parsed.data.isMinor === true || preference?.minorContextualOnly,
      blockedAdvertiserIds: blocked,
      internalTest: parsed.data.internalTest === true,
    });
    res.json(result);
  });

  router.post("/campaigns/:id/delivery-preview", authMiddleware, async (req, res) => {
    const parsed = deliveryPreviewSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const campaign = await campaignRow(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const viewerHash = viewerHashFor(req, parsed.data.viewerReference ?? `internal-preview-${(req as AuthenticatedRequest).userId}`);
    const preference = await preferenceFor(prisma, viewerHash);
    const blocked = await blockedAdvertisers(prisma, viewerHash);
    const result = await requestAdDelivery(prisma, {
      placement: parsed.data.placement,
      viewerHash,
      country: parsed.data.country,
      deviceClass: parsed.data.deviceClass,
      contextualCategory: parsed.data.contextualCategory,
      isMinor: parsed.data.isMinor === true || preference?.minorContextualOnly,
      blockedAdvertiserIds: blocked,
      internalTest: true,
      campaignId: campaign.id,
      ownerUserId: (req as AuthenticatedRequest).userId,
    });
    res.json(result);
  });

  router.post("/delivery/verify-token", authMiddleware, async (req, res) => {
    const parsed = verifyDeliveryTokenSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const verification = await verifyDeliveryToken(prisma, parsed.data.token, { campaignId: parsed.data.campaignId, placement: parsed.data.placement });
    res.status(verification.ok ? 200 : 409).json({ ok: verification.ok, error: verification.error, payload: verification.payload ? redactedDeliveryPayload(verification.payload) : null });
  });

  router.post("/events/impression", async (req, res) => {
    const parsed = impressionSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const result = await verifyAndRecordAdEvent(prisma, {
      eventType: "impression",
      token: parsed.data.token,
      clientEventId: parsed.data.clientEventId,
      occurredAt: parsed.data.occurredAt,
      visibleAreaPercent: parsed.data.visibleAreaPercent,
      durationMs: parsed.data.durationMs,
      sessionReference: parsed.data.sessionReference,
      country: parsed.data.country,
      deviceClass: parsed.data.deviceClass,
      metadata: { route: "/events/impression" },
    });
    res.status(result.ok || result.failureReasonCode === "visibility_threshold_not_met" ? 200 : 409).json(result);
  });

  router.post("/events/click", async (req, res) => {
    const parsed = clickSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const result = await verifyAndRecordAdEvent(prisma, {
      eventType: "click",
      token: parsed.data.token,
      clientEventId: parsed.data.clientEventId,
      occurredAt: parsed.data.occurredAt,
      sessionReference: parsed.data.sessionReference,
      country: parsed.data.country,
      deviceClass: parsed.data.deviceClass,
      metadata: { route: "/events/click" },
    });
    res.status(result.ok ? 200 : 409).json(result);
  });

  router.post("/impressions", async (req, res) => {
    const parsed = impressionSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const result = await verifyAndRecordAdEvent(prisma, {
      eventType: "impression",
      token: parsed.data.token,
      clientEventId: parsed.data.clientEventId,
      occurredAt: parsed.data.occurredAt,
      visibleAreaPercent: parsed.data.visibleAreaPercent,
      durationMs: parsed.data.durationMs,
      sessionReference: parsed.data.sessionReference,
      country: parsed.data.country,
      deviceClass: parsed.data.deviceClass,
      metadata: { route: "/impressions_compat" },
    });
    res.status(result.ok || result.failureReasonCode === "visibility_threshold_not_met" ? 200 : 409).json(result);
  });

  router.post("/clicks", async (req, res) => {
    const parsed = clickSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const result = await verifyAndRecordAdEvent(prisma, {
      eventType: "click",
      token: parsed.data.token,
      clientEventId: parsed.data.clientEventId,
      occurredAt: parsed.data.occurredAt,
      sessionReference: parsed.data.sessionReference,
      country: parsed.data.country,
      deviceClass: parsed.data.deviceClass,
      metadata: { route: "/clicks_compat" },
    });
    res.status(result.ok ? 200 : 409).json(result);
  });

  router.get("/campaigns/:id/events/summary", authMiddleware, async (req, res) => {
    const summary = await getAdsEventSummary(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!summary) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, summary });
  });

  router.get("/campaigns/:id/spend", authMiddleware, async (req, res) => {
    const spend = await getAdsSpendSnapshot(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!spend) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, spend });
  });

  router.post("/campaigns/:id/reconcile-spend", authMiddleware, async (req, res) => {
    const reconciliation = await reconcileAdsSpend(prisma, routeParam(req, "id"), (req as AuthenticatedRequest).userId);
    if (!reconciliation) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, reconciliation });
  });

  router.post("/conversions", authMiddleware, async (req, res) => {
    const parsed = conversionSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const campaign = await campaignRow(prisma, parsed.data.campaignId, (req as AuthenticatedRequest).userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const id = randomId("adconv");
    await prisma.$executeRawUnsafe(`INSERT INTO "AdConversion" ("id", "campaignId", "creativeId", "advertiserId", "conversionType", "sourceEntityType", "sourceEntityId", "amountMinor", "currency", "verified", "metadataJson") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, campaign.id, parsed.data.creativeId ?? null, campaign.advertiserId, parsed.data.conversionType, parsed.data.sourceEntityType ?? null, parsed.data.sourceEntityId ?? null, parsed.data.amountMinor, parsed.data.currency.toUpperCase(), parsed.data.verified, JSON.stringify({ serverSide: true }));
    res.status(201).json({ ok: true, conversionId: id });
  });

  router.post("/:id/hide", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, routeParam(req, "id")))[0];
    if (!campaign) return res.status(404).json({ ok: false, error: "ad_not_found" });
    await prisma.$executeRawUnsafe(`INSERT OR IGNORE INTO "AdAdvertiserBlock" ("id", "userId", "advertiserId", "reason") VALUES (?, ?, ?, 'hide_campaign')`, randomId("adblock"), userId, campaign.advertiserId);
    res.json({ ok: true, hidden: true });
  });

  router.post("/:id/report", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = reportAdSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, routeParam(req, "id")))[0];
    if (!campaign) return res.status(404).json({ ok: false, error: "ad_not_found" });
    const creative = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "deletedAt" IS NULL ORDER BY "updatedAt" DESC LIMIT 1`, campaign.id))[0];
    const id = randomId("adreport");
    await prisma.$executeRawUnsafe(`INSERT INTO "AdReport" ("id", "userId", "campaignId", "creativeId", "advertiserId", "placement", "reason", "details", "campaignSnapshotJson", "creativeSnapshotJson") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, userId, campaign.id, creative?.id ?? null, campaign.advertiserId, parsed.data.placement ?? null, parsed.data.reason, parsed.data.details ?? null, JSON.stringify(campaign), JSON.stringify(creative ?? {}));
    await prisma.$executeRawUnsafe(`INSERT OR IGNORE INTO "AdAdvertiserBlock" ("id", "userId", "advertiserId", "reason") VALUES (?, ?, ?, ?)`, randomId("adblock"), userId, campaign.advertiserId, `reported:${parsed.data.reason}`);
    await audit(prisma, userId, "ads.report.created", "AdReport", id, { campaignId: campaign.id });
    res.status(201).json({ ok: true, reportId: id, hidden: true });
  });

  router.get("/preferences", authMiddleware, async (req, res) => {
    res.json({ ok: true, preferences: await getOrCreatePreference(prisma, (req as AuthenticatedRequest).userId) });
  });

  router.patch("/preferences", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = preferencesSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    await getOrCreatePreference(prisma, userId);
    await prisma.$executeRawUnsafe(`UPDATE "AdUserPreference" SET "contextualCategoriesJson" = COALESCE(?, "contextualCategoriesJson"), "locationBasedAdsEnabled" = COALESCE(?, "locationBasedAdsEnabled"), "reducedRepetitionEnabled" = COALESCE(?, "reducedRepetitionEnabled"), "minorContextualOnly" = COALESCE(?, "minorContextualOnly"), "updatedAt" = CURRENT_TIMESTAMP WHERE "userId" = ?`, parsed.data.contextualCategories ? JSON.stringify(parsed.data.contextualCategories) : null, parsed.data.locationBasedAdsEnabled ?? null, parsed.data.reducedRepetitionEnabled ?? null, parsed.data.minorContextualOnly ?? null, userId);
    res.json({ ok: true, preferences: await getOrCreatePreference(prisma, userId) });
  });

  router.post("/advertisers/:id/block", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await prisma.$executeRawUnsafe(`INSERT OR IGNORE INTO "AdAdvertiserBlock" ("id", "userId", "advertiserId", "reason") VALUES (?, ?, ?, 'user_blocked_advertiser')`, randomId("adblock"), userId, routeParam(req, "id"));
    res.json({ ok: true, blocked: true });
  });

  router.get("/admin/campaigns", authMiddleware, async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "deletedAt" IS NULL ORDER BY "updatedAt" DESC LIMIT 100`);
    res.json({ ok: true, campaigns: await Promise.all(rows.map((row) => hydrateCampaign(prisma, row))) });
  });

  router.get("/admin/moderation", authMiddleware, async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT c.*, a."businessName", a."status" AS "advertiserStatus", a."verificationStatus"
       FROM "AdCampaign" c
       JOIN "AdvertiserProfile" a ON a."id" = c."advertiserId"
       WHERE c."deletedAt" IS NULL AND c."status" IN ('underReview','submitted','revisionRequired','readyForActivation','scheduled','eligibleForDelivery')
       ORDER BY c."submittedAt" DESC, c."updatedAt" DESC LIMIT 100`,
    );
    res.json({ ok: true, queue: await Promise.all(rows.map(async (row) => ({ campaign: await hydrateCampaign(prisma, row), advertiserSummary: { businessName: row.businessName, status: row.advertiserStatus, verificationStatus: row.verificationStatus }, eligibility: await evaluateAdsCampaignEligibility(prisma, row.id, { persist: true }) }))) });
  });

  router.get("/admin/campaigns/:id", authMiddleware, async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const row = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, routeParam(req, "id")))[0];
    if (!row) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, campaign: await hydrateCampaign(prisma, row), reviews: await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdModerationReview" WHERE "campaignId" = ? ORDER BY "createdAt" DESC`, routeParam(req, "id")), eligibility: await evaluateAdsCampaignEligibility(prisma, routeParam(req, "id"), { persist: true }) });
  });

  router.post("/admin/campaigns/:id/approve", authMiddleware, adminCampaignDecision(prisma, "approved"));
  router.post("/admin/campaigns/:id/reject", authMiddleware, adminCampaignDecision(prisma, "rejected"));
  router.post("/admin/campaigns/:id/request-revision", authMiddleware, adminCampaignDecision(prisma, "revisionRequired"));
  router.post("/admin/campaigns/:id/suspend", authMiddleware, adminCampaignDecision(prisma, "suspended"));
  router.post("/admin/advertisers/:id/suspend", authMiddleware, async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    await prisma.$executeRawUnsafe(`UPDATE "AdvertiserProfile" SET "status" = 'suspended', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, routeParam(req, "id"));
    await audit(prisma, (req as AuthenticatedRequest).userId, "ads.admin.advertiser.suspended", "AdvertiserProfile", routeParam(req, "id"), {});
    res.json({ ok: true });
  });

  // Legacy sponsored product compatibility.
  router.post("/create", authMiddleware, async (req, res) => {
    const parsed = createLegacyAdSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const userId = (req as AuthenticatedRequest).userId;
    const product = await prisma.storefrontProduct.findFirst({ where: { id: parsed.data.productId, storefront: { ownerId: userId } } });
    if (!product) return res.status(404).json({ error: "product_not_found" });
    const ad = await prisma.ad.create({ data: { productId: product.id, budget: parsed.data.budget, featured: parsed.data.featured ?? false } });
    res.status(201).json(ad);
  });

  router.get("/feed", async (_req, res) => {
    const ads = await prisma.ad.findMany({
      where: { active: true, product: { published: true, storefront: { published: true } } },
      include: { product: true },
      orderBy: [{ featured: "desc" }, { updatedAt: "desc" }],
      take: 12,
    });
    res.json(ads.map((ad) => ({ id: ad.id, budget: ad.budget, clicks: ad.clicks, impressions: ad.impressions, featured: ad.featured, sponsoredLabel: "Sponsored", product: toProductDTO(ad.product) })));
  });

  router.post("/track-click", async (req, res) => {
    const parsed = legacyTrackSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const ad = await prisma.ad.update({ where: { id: parsed.data.adId }, data: { clicks: { increment: 1 } } });
    res.json({ ok: true, clicks: ad.clicks });
  });

  router.post("/track-view", async (req, res) => {
    const parsed = legacyTrackSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const ad = await prisma.ad.update({ where: { id: parsed.data.adId }, data: { impressions: { increment: 1 } } });
    res.json({ ok: true, impressions: ad.impressions });
  });

  return router;
}

export function adminAdsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(async (_req, _res, next) => {
    try {
      await ensureAdsTables(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/campaigns", async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "deletedAt" IS NULL ORDER BY "updatedAt" DESC LIMIT 100`);
    res.json({ ok: true, campaigns: await Promise.all(rows.map((row) => hydrateCampaign(prisma, row))) });
  });

  router.get("/moderation", async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const rows = await prisma.$queryRawUnsafe<any[]>(
      `SELECT c.*, a."businessName", a."status" AS "advertiserStatus", a."verificationStatus"
       FROM "AdCampaign" c
       JOIN "AdvertiserProfile" a ON a."id" = c."advertiserId"
       WHERE c."deletedAt" IS NULL AND c."status" IN ('underReview','submitted','revisionRequired','readyForActivation','scheduled','eligibleForDelivery')
       ORDER BY c."submittedAt" DESC, c."updatedAt" DESC LIMIT 100`,
    );
    res.json({ ok: true, queue: await Promise.all(rows.map(async (row) => ({ campaign: await hydrateCampaign(prisma, row), advertiserSummary: { businessName: row.businessName, status: row.advertiserStatus, verificationStatus: row.verificationStatus }, eligibility: await evaluateAdsCampaignEligibility(prisma, row.id, { persist: true }) }))) });
  });

  router.get("/campaigns/:id", async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const id = routeParam(req, "id");
    const row = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, id))[0];
    if (!row) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    res.json({ ok: true, campaign: await hydrateCampaign(prisma, row), reviews: await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdModerationReview" WHERE "campaignId" = ? ORDER BY "createdAt" DESC`, id), eligibility: await evaluateAdsCampaignEligibility(prisma, id, { persist: true }) });
  });

  router.post("/campaigns/:id/approve", adminCampaignDecision(prisma, "approved"));
  router.post("/campaigns/:id/reject", adminCampaignDecision(prisma, "rejected"));
  router.post("/campaigns/:id/request-revision", adminCampaignDecision(prisma, "revisionRequired"));
  router.post("/campaigns/:id/suspend", adminCampaignDecision(prisma, "suspended"));
  router.post("/advertisers/:id/suspend", async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const id = routeParam(req, "id");
    await prisma.$executeRawUnsafe(`UPDATE "AdvertiserProfile" SET "status" = 'suspended', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, id);
    await audit(prisma, (req as unknown as AuthenticatedRequest).userId, "ads.admin.advertiser.suspended", "AdvertiserProfile", id, {});
    res.json({ ok: true });
  });

  return router;
}

function statusTransition(prisma: PrismaClient, status: typeof campaignStatuses[number], action: string): express.RequestHandler {
  return async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const campaign = await campaignRow(prisma, routeParam(req, "id"), userId);
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    await prisma.$executeRawUnsafe(`UPDATE "AdCampaign" SET "status" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`, status, routeParam(req, "id"), userId);
    await audit(prisma, userId, action, "AdCampaign", routeParam(req, "id"), {});
    res.json({ ok: true, campaign: await campaignDTO(prisma, routeParam(req, "id"), userId) });
  };
}

function adminCampaignDecision(prisma: PrismaClient, decision: "approved" | "rejected" | "revisionRequired" | "suspended"): express.RequestHandler {
  return async (req, res) => {
    if (!adminAllowed(req)) return res.status(403).json({ ok: false, error: "admin_required" });
    const parsed = adminDecisionSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
    const id = routeParam(req, "id");
    const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "deletedAt" IS NULL LIMIT 1`, id))[0];
    if (!campaign) return res.status(404).json({ ok: false, error: "campaign_not_found" });
    const reviewableStates = decision === "suspended"
      ? ["underReview", "submitted", "revisionRequired", "rejected", "fundingRequired", "paymentPending", "readyForActivation", "scheduled", "eligibleForDelivery", "paused"]
      : ["underReview", "submitted", "revisionRequired", "rejected"];
    if (!reviewableStates.includes(String(campaign.status))) {
      return res.status(409).json({ ok: false, error: "campaign_not_in_reviewable_state", status: campaign.status });
    }
    const status = decision === "approved" ? "fundingRequired" : decision === "revisionRequired" ? "revisionRequired" : decision === "suspended" ? "suspended" : "rejected";
    const moderation = decision;
    const creativeRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "deletedAt" IS NULL ORDER BY "version" DESC, "updatedAt" DESC`, id);
    const primaryCreative = creativeRows[0];
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe(`UPDATE "AdCampaign" SET "status" = ?, "moderationStatus" = ?, "approvedAt" = CASE WHEN ? = 'approved' THEN CURRENT_TIMESTAMP ELSE "approvedAt" END, "currentRevision" = COALESCE("currentRevision", 1), "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, status, moderation, moderation, id);
      for (const creative of creativeRows) {
        await tx.$executeRawUnsafe(
          `UPDATE "AdCreative" SET "moderationStatus" = ?, "status" = CASE WHEN ? = 'approved' THEN 'approved' ELSE 'draft' END, "revision" = COALESCE("revision", ?), "approvedFingerprint" = CASE WHEN ? = 'approved' THEN ? ELSE "approvedFingerprint" END, "approvedAt" = CASE WHEN ? = 'approved' THEN CURRENT_TIMESTAMP ELSE "approvedAt" END, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
          moderation,
          moderation,
          Number(campaign.currentRevision ?? 1),
          moderation,
          creativeFingerprint(creative),
          moderation,
          creative.id,
        );
      }
      await tx.$executeRawUnsafe(
        `INSERT INTO "AdModerationReview" ("id", "campaignId", "creativeId", "reviewType", "status", "riskLevel", "rejectionReason", "reviewerNotes", "createdBy", "updatedAt", "decidedAt", "campaignRevision", "creativeVersion", "destinationSnapshotJson", "manualReviewJson", "decision", "publicReason", "internalNotes", "policyCodesJson", "reviewerActorId")
         VALUES (?, ?, ?, 'manual', ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        randomId("adreview"),
        id,
        primaryCreative?.id ?? null,
        moderation,
        decision === "approved" ? "low" : "medium",
        parsed.data.reason ?? null,
        parsed.data.notes ?? null,
        (req as AuthenticatedRequest).userId,
        Number(campaign.currentRevision ?? 1),
        primaryCreative ? Number(primaryCreative.version ?? 1) : null,
        JSON.stringify(destinationPreview(campaign)),
        JSON.stringify({ decision, notesProvided: Boolean(parsed.data.notes) }),
        moderation,
        parsed.data.reason ?? null,
        parsed.data.notes ?? null,
        JSON.stringify(decision === "approved" ? [] : [decision]),
        (req as AuthenticatedRequest).userId,
      );
    });
    await audit(prisma, (req as AuthenticatedRequest).userId, `ads.admin.campaign.${decision}`, "AdCampaign", id, { reason: parsed.data.reason, previousState: campaign.status, newState: status });
    res.json({ ok: true, campaign: await hydrateCampaign(prisma, (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ?`, id))[0]), eligibility: await evaluateAdsCampaignEligibility(prisma, id, { persist: true }) });
  };
}

async function validateCampaignForSubmission(prisma: PrismaClient, id: string, userId: string): Promise<{ ok: boolean; missing: string[]; fieldErrors: Record<string, string>; stepErrors: Record<string, string[]>; blockingErrors: string[]; warnings: string[]; completionPercentage: number; nextIncompleteStep: string | null; riskLevel: string; destinationPreview?: any }> {
  const campaign = await campaignRow(prisma, id, userId);
  if (!campaign) return { ok: false, missing: ["Campaign not found."], fieldErrors: {}, stepErrors: { profile: ["Campaign not found."] }, blockingErrors: ["Campaign not found."], warnings: [], completionPercentage: 0, nextIncompleteStep: "profile", riskLevel: "medium" };
  const config = adsConfig();
  const advertiser = await advertiserById(prisma, campaign.advertiserId, userId);
  const [creative] = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "deletedAt" IS NULL LIMIT 1`, id);
  const placementRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPlacementSelection" WHERE "campaignId" = ? AND "enabled" = 1`, id);
  const missing: string[] = [];
  const fieldErrors: Record<string, string> = {};
  const stepErrors: Record<string, string[]> = {};
  const warnings: string[] = [];
  const blockingErrors: string[] = [];
  if (!advertiser) addStep(stepErrors, "profile", "Create or select an advertiser profile.");
  if (advertiser && ["restricted", "suspended", "closed"].includes(advertiser.status)) addStep(stepErrors, "profile", "Advertiser profile is not eligible.");
  if (!config.enabledObjectives.includes(campaign.objective)) addStep(stepErrors, "objective", "This campaign objective is disabled by server feature flag.");
  let destinationValidation: Awaited<ReturnType<typeof validateDestination>> | undefined;
  if (!campaign.destinationType || (!campaign.destinationId && !campaign.destinationURL)) {
    fieldErrors.destination = "Add a valid destination.";
    addStep(stepErrors, "destination", "Add a valid destination.");
  } else {
    destinationValidation = await validateDestination(prisma, userId, campaign.destinationType, campaign.destinationId, campaign.destinationURL);
    if (!destinationValidation.ok) {
      fieldErrors.destination = destinationValidation.reason;
      addStep(stepErrors, "destination", destinationValidation.reason);
    }
  }
  if (!creative) addStep(stepErrors, "creative", "Add at least one ad creative.");
  if (creative && policyFlags(creative.headline, creative.bodyText).length) warnings.push("Creative contains wording that needs manual moderation.");
  if (!placementRows.length) addStep(stepErrors, "placements", "Choose at least one placement.");
  for (const placement of placementRows) {
    if (!config.enabledPlacements.includes(placement.placement)) addStep(stepErrors, "placements", `${placement.placement} is disabled.`);
  }
  if (Number(campaign.lifetimeBudgetMinor) < config.minimumBudgetMinor) addStep(stepErrors, "budget", `Set a lifetime budget of at least ${config.minimumBudgetMinor} minor units.`);
  if (!config.supportedCountries.includes(String(campaign.currency ?? "USD") === "USD" ? "US" : "")) warnings.push("Campaign currency is not mapped to a supported rollout country.");
  if (campaign.startAt && campaign.endAt && new Date(campaign.endAt).getTime() <= new Date(campaign.startAt).getTime()) addStep(stepErrors, "budget", "Campaign end date must be after start date.");
  const audienceRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdAudienceRule" WHERE "campaignId" = ?`, id);
  if (audienceRows.some((rule) => isSensitiveTargeting(rule.ruleType, rule.ruleValue))) addStep(stepErrors, "budget", "Sensitive targeting is not allowed.");
  for (const value of Object.values(stepErrors).flat()) {
    missing.push(value);
    blockingErrors.push(value);
  }
  const flags = creative ? policyFlags(creative.headline, creative.bodyText) : [];
  const steps = ["profile", "objective", "destination", "creative", "placements", "budget", "review"];
  const completed = steps.filter((step) => !stepErrors[step]?.length && step !== "review").length;
  const nextIncompleteStep = steps.find((step) => stepErrors[step]?.length) ?? null;
  return {
    ok: blockingErrors.length === 0,
    missing,
    fieldErrors,
    stepErrors,
    blockingErrors,
    warnings,
    completionPercentage: Math.round((completed / 6) * 100),
    nextIncompleteStep,
    riskLevel: flags.length ? "medium" : "low",
    destinationPreview: destinationValidation?.preview,
  };
}

async function validateDestination(prisma: PrismaClient, userId: string, type: string, id?: string | null, url?: string | null): Promise<{ ok: boolean; reason: string; preview?: any }> {
  const config = adsConfig();
  if (type === "external_url") {
    if (!config.externalWebsiteAdsEnabled) return { ok: false, reason: "External website ads are disabled." };
    if (!url || !safeDestinationURL(url) || !url.startsWith("https://")) return { ok: false, reason: "Use a safe HTTPS destination URL." };
    return { ok: true, reason: "valid", preview: { type, url } };
  }
  if (!id) return { ok: false, reason: "Destination ID is required." };
  if (type === "shop") {
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT "id", "name", "published", "status", "publicVisible" FROM "Storefront" WHERE "id" = ? AND "ownerId" = ? LIMIT 1`, id, userId);
    const shop = rows[0];
    if (!shop) return { ok: false, reason: "Shop was not found or is not owned by you." };
    if (!shop.published || shop.status !== "live" && shop.status !== "published" || !shop.publicVisible) return { ok: false, reason: "Shop must be published and public before promotion." };
    return { ok: true, reason: "valid", preview: { type, id: shop.id, title: shop.name } };
  }
  if (type === "product") {
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT p."id", p."name", p."published", p."status", s."published" AS "shopPublished", s."publicVisible" AS "shopPublicVisible" FROM "StorefrontProduct" p JOIN "Storefront" s ON s."id" = p."storefrontId" WHERE p."id" = ? AND s."ownerId" = ? LIMIT 1`, id, userId);
    const product = rows[0];
    if (!product) return { ok: false, reason: "Product was not found or is not owned by you." };
    if (!product.published || product.status !== "published" || !product.shopPublished || !product.shopPublicVisible) return { ok: false, reason: "Product and shop must be published before promotion." };
    return { ok: true, reason: "valid", preview: { type, id: product.id, title: product.name } };
  }
  if (type === "site") {
    if (!config.enabledObjectives.includes("promote_site")) return { ok: false, reason: "Site promotion is disabled by server feature flag." };
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT "id", "title", "status", "visibility", "activePublicationId" FROM "Site" WHERE "id" = ? AND "userId" = ? LIMIT 1`, id, userId);
    const site = rows[0];
    if (!site) return { ok: false, reason: "Site was not found or is not owned by you." };
    if (site.status !== "PUBLISHED" || !site.activePublicationId || !["PUBLIC", "UNLISTED"].includes(site.visibility ?? "PUBLIC")) return { ok: false, reason: "Site must be published before promotion." };
    return { ok: true, reason: "valid", preview: { type, id: site.id, title: site.title } };
  }
  if (type === "community") {
    if (!config.enabledObjectives.includes("promote_community")) return { ok: false, reason: "Community promotion is disabled by server feature flag." };
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT "id", "name", "visibility", "deletedAt" FROM "Community" WHERE "id" = ? AND "ownerId" = ? LIMIT 1`, id, userId);
    const community = rows[0];
    if (!community || community.deletedAt) return { ok: false, reason: "Community was not found or is not owned by you." };
    if (community.visibility === "private") return { ok: false, reason: "Private communities cannot be promoted in Phase 1." };
    return { ok: true, reason: "valid", preview: { type, id: community.id, title: community.name } };
  }
  return { ok: false, reason: "This destination type is not enabled for Phase 1." };
}

function addStep(stepErrors: Record<string, string[]>, step: string, message: string): void {
  stepErrors[step] = [...(stepErrors[step] ?? []), message];
}

function draftCompletionState(campaign: any): Record<string, boolean> {
  return {
    profile: Boolean(campaign.advertiserId),
    objective: Boolean(campaign.objective),
    destination: Boolean(campaign.destinationType && (campaign.destinationId || campaign.destinationURL)),
    creative: false,
    placements: Array.isArray(campaign.placements) ? campaign.placements.length > 0 : true,
    budget: Number(campaign.lifetimeBudgetMinor ?? 0) >= adsConfig().minimumBudgetMinor,
  };
}

async function selectEligibleCampaign(prisma: PrismaClient, placement: string, viewerHash: string, isMinor: boolean | undefined, blocked: Set<string>): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT c.* FROM "AdCampaign" c
     JOIN "AdvertiserProfile" a ON a."id" = c."advertiserId"
     JOIN "AdPlacementSelection" p ON p."campaignId" = c."id"
     JOIN "AdBudget" b ON b."campaignId" = c."id"
     WHERE c."status" = 'eligibleForDelivery'
       AND c."moderationStatus" = 'approved'
       AND a."status" = 'active'
       AND p."placement" = ? AND p."enabled" = 1
       AND b."remainingMinor" > 0
       AND (c."startAt" IS NULL OR c."startAt" <= CURRENT_TIMESTAMP)
       AND (c."endAt" IS NULL OR c."endAt" > CURRENT_TIMESTAMP)
       AND c."deletedAt" IS NULL
     ORDER BY b."remainingMinor" DESC, c."updatedAt" DESC
     LIMIT 50`,
    placement,
  );
  for (const campaign of rows) {
    if (blocked.has(campaign.advertiserId)) continue;
    if (isMinor && !minorSafeCampaign(campaign)) continue;
    const recent = await prisma.$queryRawUnsafe<any[]>(`SELECT COUNT(*) AS count FROM "AdImpression" WHERE "campaignId" = ? AND "viewerHash" = ? AND "createdAt" >= datetime('now','-1 day')`, campaign.id, viewerHash);
    if (Number(recent[0]?.count ?? 0) >= adsConfig().frequencyCaps.maxImpressionsPerUserPerCampaignPerDay) continue;
    return campaign;
  }
  return null;
}

async function advertiserById(prisma: PrismaClient, id: string, userId: string): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdvertiserProfile" WHERE "id" = ? AND "ownerUserId" = ? AND "deletedAt" IS NULL LIMIT 1`, id, userId);
  return rows[0] ? advertiserDTO(rows[0]) : null;
}

async function findDuplicateAdvertiser(prisma: PrismaClient, userId: string, shopId?: string, siteId?: string): Promise<any | null> {
  if (!shopId && !siteId) return null;
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdvertiserProfile" WHERE "ownerUserId" = ? AND "deletedAt" IS NULL AND (("oneWayShopId" IS NOT NULL AND "oneWayShopId" = ?) OR ("oneWaySiteId" IS NOT NULL AND "oneWaySiteId" = ?)) LIMIT 1`, userId, shopId ?? "", siteId ?? "");
  return rows[0] ? advertiserDTO(rows[0]) : null;
}

async function campaignRow(prisma: PrismaClient, id: string, userId: string): Promise<any | null> {
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "ownerUserId" = ? AND "deletedAt" IS NULL LIMIT 1`, id, userId))[0] ?? null;
}

async function campaignDTO(prisma: PrismaClient, id: string, userId: string): Promise<any | null> {
  const row = await campaignRow(prisma, id, userId);
  return row ? hydrateCampaign(prisma, row) : null;
}

async function hydrateCampaign(prisma: PrismaClient, row: any): Promise<any> {
  const [creatives, placementRows, audienceRows, budgetRows] = await Promise.all([
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "campaignId" = ? AND "deletedAt" IS NULL ORDER BY "createdAt" DESC`, row.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdPlacementSelection" WHERE "campaignId" = ? AND "enabled" = 1 ORDER BY "placement"`, row.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdAudienceRule" WHERE "campaignId" = ? ORDER BY "createdAt"`, row.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdBudget" WHERE "campaignId" = ? LIMIT 1`, row.id),
  ]);
  return { ...row, placements: placementRows.map((p) => p.placement), audienceRules: audienceRows, creatives: creatives.map(safeCreativeDTO), budget: budgetRows[0] ?? null };
}

async function creativeById(prisma: PrismaClient, id: string, userId: string): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCreative" WHERE "id" = ? AND "ownerUserId" = ? AND "deletedAt" IS NULL LIMIT 1`, id, userId);
  return rows[0] ?? null;
}

async function campaignReport(prisma: PrismaClient, campaign: any): Promise<any> {
  const [imp, clk, conv, ledger] = await Promise.all([
    prisma.$queryRawUnsafe<any[]>(`SELECT COUNT(*) AS count FROM "AdImpression" WHERE "campaignId" = ?`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT COUNT(*) AS count FROM "AdClick" WHERE "campaignId" = ?`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT COUNT(*) AS count, COALESCE(SUM("amountMinor"),0) AS sales FROM "AdConversion" WHERE "campaignId" = ? AND "verified" = 1`, campaign.id),
    prisma.$queryRawUnsafe<any[]>(`SELECT COALESCE(SUM(CASE WHEN "amountMinor" < 0 THEN -\"amountMinor\" ELSE 0 END),0) AS spend FROM "AdLedgerEntry" WHERE "campaignId" = ?`, campaign.id),
  ]);
  const impressions = Number(imp[0]?.count ?? 0);
  const clicks = Number(clk[0]?.count ?? 0);
  const spendMinor = Number(ledger[0]?.spend ?? campaign.spentMinor ?? 0);
  const salesAttributedMinor = Number(conv[0]?.sales ?? 0);
  return {
    campaignId: campaign.id,
    impressions,
    uniqueReachEstimate: impressions,
    clicks,
    clickThroughRate: impressions ? clicks / impressions : 0,
    spendMinor,
    averageCPMMinor: impressions ? Math.round((spendMinor / impressions) * 1000) : 0,
    averageCPCMinor: 0,
    conversions: Number(conv[0]?.count ?? 0),
    conversionRate: clicks ? Number(conv[0]?.count ?? 0) / clicks : 0,
    salesAttributedMinor,
    returnOnAdSpend: spendMinor ? salesAttributedMinor / spendMinor : null,
    remainingBudgetMinor: Math.max(0, Number(campaign.fundedMinor ?? 0) - spendMinor),
  };
}

async function overviewMetrics(prisma: PrismaClient, userId: string): Promise<any> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "ownerUserId" = ? AND "deletedAt" IS NULL`, userId);
  const reports = await Promise.all(rows.map((row) => campaignReport(prisma, row)));
  return reports.reduce((sum, report) => ({
    amountSpentMinor: sum.amountSpentMinor + report.spendMinor,
    remainingCampaignBudgetMinor: sum.remainingCampaignBudgetMinor + report.remainingBudgetMinor,
    impressions: sum.impressions + report.impressions,
    clicks: sum.clicks + report.clicks,
    conversions: sum.conversions + report.conversions,
    salesAttributedMinor: sum.salesAttributedMinor + report.salesAttributedMinor,
    averageCostPerClickMinor: sum.clicks + report.clicks ? Math.round((sum.amountSpentMinor + report.spendMinor) / (sum.clicks + report.clicks)) : 0,
    clickThroughRate: sum.impressions + report.impressions ? (sum.clicks + report.clicks) / (sum.impressions + report.impressions) : 0,
    returnOnAdSpend: sum.amountSpentMinor + report.spendMinor ? (sum.salesAttributedMinor + report.salesAttributedMinor) / (sum.amountSpentMinor + report.spendMinor) : null,
  }), { amountSpentMinor: 0, remainingCampaignBudgetMinor: 0, impressions: 0, clicks: 0, conversions: 0, salesAttributedMinor: 0, averageCostPerClickMinor: 0, clickThroughRate: 0, returnOnAdSpend: null as number | null });
}

function emptyOverview(): any {
  return {
    amountSpentMinor: 0,
    remainingCampaignBudgetMinor: 0,
    impressions: 0,
    clicks: 0,
    conversions: 0,
    salesAttributedMinor: 0,
    averageCostPerClickMinor: 0,
    clickThroughRate: 0,
    returnOnAdSpend: null,
  };
}

async function getOrCreatePreference(prisma: PrismaClient, userId: string): Promise<any> {
  let row = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdUserPreference" WHERE "userId" = ? LIMIT 1`, userId))[0];
  if (!row) {
    await prisma.$executeRawUnsafe(`INSERT INTO "AdUserPreference" ("id", "userId") VALUES (?, ?)`, randomId("adpref"), userId);
    row = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdUserPreference" WHERE "userId" = ? LIMIT 1`, userId))[0];
  }
  return { ...row, contextualCategories: parseJson(row.contextualCategoriesJson, []) };
}

async function preferenceFor(prisma: PrismaClient, viewerHash: string): Promise<any | null> {
  const row = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdUserPreference" WHERE "userId" = ? LIMIT 1`, viewerHash))[0];
  return row ?? null;
}

async function blockedAdvertisers(prisma: PrismaClient, viewerHash: string): Promise<Set<string>> {
  const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT "advertiserId" FROM "AdAdvertiserBlock" WHERE "userId" = ?`, viewerHash);
  return new Set(rows.map((row) => row.advertiserId));
}

async function validToken(prisma: PrismaClient, token: string): Promise<any | null> {
  const row = await tokenByHash(prisma, hash(token));
  if (!row || row.impressionId) return null;
  if (new Date(row.expiresAt).getTime() < Date.now()) return null;
  return row;
}

async function tokenByHash(prisma: PrismaClient, tokenHash: string): Promise<any | null> {
  return (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdDeliveryToken" WHERE "tokenHash" = ? LIMIT 1`, tokenHash))[0] ?? null;
}

function advertiserDTO(row: any): any {
  return { ...row, billingCustomerId: row.billingCustomerId ? "[configured]" : null };
}

function safeCreativeDTO(row: any): any {
  return { id: row.id, campaignId: row.campaignId, version: row.version, status: row.status, moderationStatus: row.moderationStatus, headline: row.headline, bodyText: row.bodyText, cta: row.cta, logoURL: row.logoURL, imageURL: row.imageURL, videoURL: row.videoURL, thumbnailURL: row.thumbnailURL, accessibilityDescription: row.accessibilityDescription, policyFlags: parseJson(row.policyFlagsJson, []) };
}

function adPaymentDTO(row: any): any {
  return { id: row.id, campaignId: row.campaignId, amountMinor: row.amountMinor, currency: row.currency, status: row.status, stripePaymentIntentId: row.stripePaymentIntentId, createdAt: row.createdAt, updatedAt: row.updatedAt };
}

function ledgerDTO(row: any): any {
  return { id: row.id, campaignId: row.campaignId, entryType: row.entryType, amountMinor: row.amountMinor, currency: row.currency, status: row.status ?? "posted", stripeEventId: row.stripeEventId, stripePaymentIntentId: row.stripePaymentIntentId, createdAt: row.createdAt };
}

function receiptDTO(row: any): any {
  return { id: row.id, receiptNumber: row.receiptNumber, campaignId: row.campaignId, amountMinor: row.amountMinor, currency: row.currency, status: row.status, issuedAt: row.issuedAt, stripePaymentIntentId: row.stripePaymentIntentId };
}

async function campaignBalance(prisma: PrismaClient, campaignId: string, userId: string): Promise<any> {
  const campaign = await campaignRow(prisma, campaignId, userId);
  if (!campaign) return null;
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT COALESCE(SUM("amountMinor"),0) AS balanceMinor FROM "AdLedgerEntry" WHERE "campaignId" = ? AND "status" = 'posted'`,
    campaignId,
  );
  const balanceMinor = Number(rows[0]?.balanceMinor ?? 0);
  const spentMinor = Number(campaign.spentMinor ?? 0);
  return {
    campaignId,
    currency: String(campaign.currency ?? "USD"),
    fundedMinor: Math.max(0, balanceMinor),
    spentMinor,
    remainingMinor: Math.max(0, balanceMinor - spentMinor),
    status: campaign.status,
    readyForActivation: campaign.status === "readyForActivation",
    activationEnabled: adsConfig().campaignActivationEnabled,
  };
}

async function reconcileCampaignLedger(prisma: PrismaClient, campaignId: string, userId: string): Promise<any> {
  const campaign = await campaignRow(prisma, campaignId, userId);
  if (!campaign) throw new Error("campaign_not_found");
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT COALESCE(SUM(CASE WHEN "entryType" IN ('campaignFunding','promotionalCredit','adjustment') THEN "amountMinor" ELSE 0 END),0) AS fundedMinor,
            COALESCE(SUM("amountMinor"),0) AS netBalanceMinor
     FROM "AdLedgerEntry" WHERE "campaignId" = ? AND "status" = 'posted'`,
    campaignId,
  );
  const fundedMinor = Math.max(0, Number(rows[0]?.fundedMinor ?? 0));
  const netBalanceMinor = Number(rows[0]?.netBalanceMinor ?? 0);
  const spentMinor = Number(campaign.spentMinor ?? 0);
  const remainingMinor = Math.max(0, netBalanceMinor - spentMinor);
  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(`UPDATE "AdBudget" SET "fundedMinor" = ?, "remainingMinor" = ?, "spentMinor" = ?, "updatedAt" = CURRENT_TIMESTAMP WHERE "campaignId" = ?`, fundedMinor, remainingMinor, spentMinor, campaignId);
    await tx.$executeRawUnsafe(`UPDATE "AdCampaign" SET "fundedMinor" = ?, "spentMinor" = ?, "status" = CASE WHEN "status" = 'paymentPending' AND ? > 0 THEN 'readyForActivation' ELSE "status" END, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ? AND "ownerUserId" = ?`, fundedMinor, spentMinor, fundedMinor, campaignId, userId);
  });
  return { campaignId, fundedMinor, spentMinor, remainingMinor, netBalanceMinor };
}

function adsConfig(): any {
  const enabledObjectives = csvEnv("ONEWAY_ADS_ENABLED_OBJECTIVES", "promote_shop,promote_product,website_visits").filter((value) => (objectives as readonly string[]).includes(value));
  const enabledPlacements = csvEnv("ONEWAY_ADS_ENABLED_PLACEMENTS", "shop_discovery,marketplace_results,content_feed").filter((value) => (placements as readonly string[]).includes(value));
  return {
    adsEnabled: envFlag("ONEWAY_ADS_ENABLED", true),
    advertiserCreationEnabled: envFlag("ONEWAY_ADS_ADVERTISER_CREATION_ENABLED", true),
    campaignCreationEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_CREATION_ENABLED", true),
    campaignSubmissionEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_SUBMISSION_ENABLED", true),
    moderationEnabled: envFlag("ONEWAY_ADS_MODERATION_ENABLED", true),
    campaignFundingEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_FUNDING_ENABLED", true),
    campaignActivationEnabled: envFlag("ONEWAY_ADS_CAMPAIGN_ACTIVATION_ENABLED", false),
    fundingInternalTesterOnly: envFlag("ONEWAY_ADS_FUNDING_INTERNAL_TESTER_ONLY", true),
    paidDeliveryEnabled: envFlag("ONEWAY_ADS_PAID_DELIVERY_ENABLED", false),
    internalDeliveryEnabled: envFlag("ONEWAY_ADS_INTERNAL_DELIVERY_ENABLED", false),
    impressionVerificationEnabled: envFlag("ONEWAY_ADS_IMPRESSION_VERIFICATION_ENABLED", true),
    clickVerificationEnabled: envFlag("ONEWAY_ADS_CLICK_VERIFICATION_ENABLED", true),
    spendAccountingEnabled: envFlag("ONEWAY_ADS_SPEND_ACCOUNTING_ENABLED", true),
    impressionBillingEnabled: envFlag("ONEWAY_ADS_IMPRESSION_BILLING_ENABLED", true),
    clickBillingEnabled: envFlag("ONEWAY_ADS_CLICK_BILLING_ENABLED", true),
    conversionTrackingEnabled: envFlag("ONEWAY_ADS_CONVERSION_TRACKING_ENABLED", false),
    reportingEnabled: envFlag("ONEWAY_ADS_REPORTING_ENABLED", false),
    adminAdsEnabled: envFlag("ONEWAY_ADS_ADMIN_ENABLED", true),
    externalWebsiteAdsEnabled: envFlag("ONEWAY_ADS_EXTERNAL_WEBSITE_ENABLED", true),
    imageCreativeEnabled: envFlag("ONEWAY_ADS_IMAGE_CREATIVE_ENABLED", true),
    videoCreativeEnabled: envFlag("ONEWAY_ADS_VIDEO_CREATIVE_ENABLED", false),
    availableObjectives: objectives,
    availablePlacements: placements,
    enabledObjectives,
    enabledPlacements,
    objectiveFlags: Object.fromEntries(objectives.map((objective) => [objective, enabledObjectives.includes(objective)])),
    placementFlags: Object.fromEntries(placements.map((placement) => [placement, enabledPlacements.includes(placement)])),
    minimumBudgetMinor: numberEnv("ONEWAY_ADS_MIN_BUDGET_MINOR", 500),
    defaultCurrency: process.env.ONEWAY_ADS_DEFAULT_CURRENCY ?? "USD",
    maxCampaignDurationDays: numberEnv("ONEWAY_ADS_MAX_DURATION_DAYS", 90),
    cpmPriceMinor: numberEnv("ONEWAY_ADS_CPM_PRICE_MINOR", 500),
    cpcPriceMinor: numberEnv("ONEWAY_ADS_CPC_PRICE_MINOR", 25),
    stripeConfigured: stripeConfigured(),
    billingModels: ["PREPAID_CPM", "CPC", "FLAT_RATE_PACKAGE"],
    cpcBillingEnabled: envFlag("ONEWAY_ADS_CLICK_BILLING_ENABLED", true),
    moderationRequired: true,
    minorProtectionsEnabled: true,
    supportedCountries: (process.env.ONEWAY_ADS_SUPPORTED_COUNTRIES ?? "US").split(",").map((v) => v.trim()).filter(Boolean),
    frequencyCaps: {
      maxImpressionsPerUserPerCampaignPerDay: numberEnv("ONEWAY_ADS_FREQ_CAMPAIGN_DAY", 5),
      maxImpressionsPerUserPerAdvertiserPerDay: numberEnv("ONEWAY_ADS_FREQ_ADVERTISER_DAY", 12),
      cooldownMinutesAfterHide: numberEnv("ONEWAY_ADS_HIDE_COOLDOWN_MINUTES", 1440),
    },
  };
}

function redactedDeliveryPayload(payload: any): any {
  return {
    deliveryId: payload.deliveryId,
    traceId: payload.traceId,
    campaignId: payload.campaignId,
    creativeId: payload.creativeId,
    creativeVersion: payload.creativeVersion,
    placement: payload.placement,
    issuedAt: payload.issuedAt,
    expiresAt: payload.expiresAt,
    internalTest: payload.internalTest === true,
    paidDeliveryEnabled: payload.paidDeliveryEnabled === true,
  };
}

function adsFundingAllowedForUser(userId: string): boolean {
  const config = adsConfig();
  if (!config.campaignFundingEnabled) return false;
  const testerIds = csvEnv("ONEWAY_ADS_INTERNAL_TESTER_USER_IDS", "");
  return testerIds.length === 0 || testerIds.includes(userId);
}

function csvEnv(name: string, fallback: string): string[] {
  return (process.env[name] ?? fallback).split(",").map((value) => value.trim()).filter(Boolean);
}

function policyFlags(headline: string, body: string): string[] {
  const text = `${headline} ${body}`.toLowerCase();
  const checks: Array<[string, RegExp]> = [
    ["scam_or_deceptive_claim", /\b(guaranteed profit|get rich|risk free investment)\b/],
    ["unsafe_medical_claim", /\b(cure cancer|miracle cure|guaranteed weight loss)\b/],
    ["prohibited_weapons_or_drugs", /\b(ghost gun|illegal drug|cocaine|fentanyl)\b/],
    ["adult_or_minor_sensitive", /\b(adult only|explicit|xxx)\b/],
    ["malware_or_deceptive_download", /\b(download now|free crypto|airdrop wallet)\b/],
  ];
  return checks.filter(([, re]) => re.test(text)).map(([flag]) => flag);
}

function safeDestinationURL(value: string): boolean {
  try {
    const url = new URL(value);
    return ["https:", "oneway:"].includes(url.protocol) && !url.username && !url.password;
  } catch {
    return false;
  }
}

function safeDestination(campaign: any): any {
  return { type: campaign.destinationType, id: campaign.destinationId, url: campaign.destinationURL };
}

function destinationPreview(campaign: any): any {
  return { type: campaign.destinationType, id: campaign.destinationId, url: campaign.destinationURL };
}

function isSensitiveTargeting(ruleType: string, value: string): boolean {
  const sensitive = /\b(race|religion|health|medical|pregnancy|sexual|political|union|disability|credit|income|ethnic)\b/i;
  return sensitive.test(`${ruleType} ${value}`);
}

function campaignEligibleNow(campaign: any): boolean {
  const now = Date.now();
  const starts = campaign.startAt ? new Date(campaign.startAt).getTime() : 0;
  const ends = campaign.endAt ? new Date(campaign.endAt).getTime() : Number.MAX_SAFE_INTEGER;
  return campaign.status === "eligibleForDelivery" && campaign.moderationStatus === "approved" && Number(campaign.fundedMinor ?? 0) > Number(campaign.spentMinor ?? 0) && starts <= now && ends > now;
}

function minorSafeCampaign(campaign: any): boolean {
  return !["external_url"].includes(String(campaign.destinationType ?? ""));
}

function viewerHashFor(req: express.Request, explicit?: string): string {
  const source = explicit || String(req.ip ?? "anonymous");
  return hash(`ads-viewer:${source}`);
}

function hash(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function countBy(rows: any[], key: string): Record<string, number> {
  return rows.reduce((counts, row) => {
    counts[String(row[key] ?? "unknown")] = (counts[String(row[key] ?? "unknown")] ?? 0) + 1;
    return counts;
  }, {} as Record<string, number>);
}

function parseJson<T>(value: string | null | undefined, fallback: T): T {
  try {
    return value ? JSON.parse(value) as T : fallback;
  } catch {
    return fallback;
  }
}

function adControls(): string[] {
  return ["Hide this ad", "Report this ad", "Why am I seeing this?", "Fewer ads from this advertiser"];
}

function whyCopy(placement: string, contextualCategory?: string): string {
  if (contextualCategory) return `This campaign is related to ${contextualCategory}.`;
  if (placement.includes("shop") || placement.includes("marketplace")) return "You are viewing Shop content.";
  if (placement.includes("community")) return "This campaign is related to community discovery.";
  return "This ad is available for the content surface you are viewing.";
}

function adminAllowed(req: express.Request): boolean {
  const token = req.headers["x-oneway-admin-token"];
  return Boolean(process.env.ONEWAY_ADMIN_TOKEN?.trim() && typeof token === "string" && token === process.env.ONEWAY_ADMIN_TOKEN);
}

async function audit(prisma: PrismaClient, actorUserId: string | null, action: string, resourceType: string, resourceId: string, metadata: Record<string, any>): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "AdAuditLog" ("id", "actorUserId", "actorType", "action", "resourceType", "resourceId", "metadataJson") VALUES (?, ?, ?, ?, ?, ?, ?)`,
    randomId("adaudit"), actorUserId, actorUserId ? "user" : "system", action, resourceType, resourceId, JSON.stringify(metadata),
  );
}

function envFlag(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw == null || raw.trim() === "") return fallback;
  return ["1", "true", "yes", "on"].includes(raw.trim().toLowerCase());
}

function numberEnv(name: string, fallback: number): number {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function impressionChargeMinor(): number {
  return Math.max(1, Math.ceil(adsConfig().cpmPriceMinor / 1000));
}

function randomId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}

function csv(value: string): string {
  return `"${String(value ?? "").replace(/"/g, "\"\"")}"`;
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function routeParam(req: express.Request, key: string): string {
  const value = req.params[key];
  return Array.isArray(value) ? String(value[0] ?? "") : String(value ?? "");
}
