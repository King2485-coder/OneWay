import type { PrismaClient } from "@prisma/client";

import { evaluateAdsCampaignEligibility, type AdsEligibilityResult } from "./AdsCampaignEligibilityService";
import { ensureAdsTables } from "./AdsTables";

export type AdsActor = {
  actorType: "user" | "admin" | "system" | "stripe_webhook";
  actorId: string | null;
};

export type AdsTransitionResult = {
  ok: boolean;
  previousState: string;
  newState: string;
  campaign: any;
  eligibility?: AdsEligibilityResult;
  error?: string;
};

const allowedTransitions: Record<string, Set<string>> = {
  draft: new Set(["underReview", "submitted", "canceled"]),
  submitted: new Set(["underReview", "canceled"]),
  underReview: new Set(["fundingRequired", "rejected", "draft", "suspended"]),
  revisionRequired: new Set(["draft", "underReview", "canceled"]),
  rejected: new Set(["draft", "underReview", "canceled"]),
  approved: new Set(["fundingRequired", "suspended"]),
  fundingRequired: new Set(["paymentPending", "readyForActivation", "canceled", "suspended"]),
  paymentPending: new Set(["fundingRequired", "readyForActivation", "canceled", "suspended"]),
  readyForActivation: new Set(["scheduled", "eligibleForDelivery", "paused", "canceled", "suspended", "completed", "budgetExhausted"]),
  scheduled: new Set(["eligibleForDelivery", "paused", "canceled", "suspended", "completed", "budgetExhausted"]),
  eligibleForDelivery: new Set(["paused", "canceled", "suspended", "completed", "budgetExhausted", "scheduled", "readyForActivation"]),
  paused: new Set(["scheduled", "eligibleForDelivery", "canceled", "suspended", "completed", "budgetExhausted", "readyForActivation"]),
  active: new Set(["paused", "canceled", "suspended", "completed", "budgetExhausted"]),
  suspended: new Set(["readyForActivation", "canceled"]),
};

export async function transitionAdsCampaignState(
  prisma: PrismaClient,
  campaignId: string,
  nextState: string,
  actor: AdsActor,
  reason: string,
  metadata: Record<string, any> = {},
): Promise<AdsTransitionResult> {
  await ensureAdsTables(prisma);
  const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "deletedAt" IS NULL LIMIT 1`, campaignId))[0];
  if (!campaign) return { ok: false, previousState: "missing", newState: nextState, campaign: null, error: "campaign_not_found" };
  const previousState = String(campaign.status ?? "draft");
  if (previousState === nextState) {
    await audit(prisma, actor, "ads.campaign.transition.idempotent", campaign, previousState, nextState, reason, metadata);
    return { ok: true, previousState, newState: nextState, campaign };
  }
  if (!allowedTransitions[previousState]?.has(nextState)) {
    await audit(prisma, actor, "ads.campaign.transition.rejected", campaign, previousState, nextState, "invalid_transition", { ...metadata, requestedReason: reason });
    return { ok: false, previousState, newState: nextState, campaign, error: "invalid_state_transition" };
  }
  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(
      `UPDATE "AdCampaign" SET "status" = ?, "pausedAt" = CASE WHEN ? = 'paused' THEN CURRENT_TIMESTAMP ELSE "pausedAt" END, "completedAt" = CASE WHEN ? IN ('completed','canceled') THEN CURRENT_TIMESTAMP ELSE "completedAt" END, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`,
      nextState,
      nextState,
      nextState,
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdAuditLog" ("id", "actorUserId", "actorType", "action", "resourceType", "resourceId", "metadataJson")
       VALUES (?, ?, ?, 'ads.campaign.state_transitioned', 'AdCampaign', ?, ?)`,
      randomId("adaudit"),
      actor.actorId,
      actor.actorType,
      campaignId,
      JSON.stringify({ previousState, newState: nextState, reason, ...metadata }),
    );
  });
  const updated = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? LIMIT 1`, campaignId))[0];
  return { ok: true, previousState, newState: nextState, campaign: updated };
}

export async function evaluateAndTransitionAdsCampaign(
  prisma: PrismaClient,
  campaignId: string,
  actor: AdsActor,
  options: { ownerUserId?: string; reason?: string; forcePersist?: boolean } = {},
): Promise<AdsTransitionResult> {
  const eligibility = await evaluateAdsCampaignEligibility(prisma, campaignId, {
    ownerUserId: options.ownerUserId,
    persist: true,
  });
  const campaign = (await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "deletedAt" IS NULL LIMIT 1`, campaignId))[0];
  if (!campaign) return { ok: false, previousState: "missing", newState: eligibility.resultingRecommendedState, campaign: null, eligibility, error: "campaign_not_found" };
  const nextState = eligibility.resultingRecommendedState;
  const shouldTransition =
    (eligibility.isEligible && ["readyForActivation", "scheduled", "eligibleForDelivery", "paused"].includes(String(campaign.status))) ||
    nextState === "completed" ||
    nextState === "budgetExhausted";
  if (!shouldTransition || String(campaign.status) === nextState) {
    await audit(prisma, actor, eligibility.isEligible ? "ads.campaign.eligibility.passed" : "ads.campaign.eligibility.failed", campaign, String(campaign.status), String(campaign.status), options.reason ?? "eligibility_evaluated", {
      correlationId: eligibility.correlationId,
      blockingReasonCodes: eligibility.blockingReasons.map((reason) => reason.code),
      warnings: eligibility.warnings.map((reason) => reason.code),
    });
    return { ok: eligibility.isEligible, previousState: String(campaign.status), newState: String(campaign.status), campaign, eligibility, error: eligibility.isEligible ? undefined : "eligibility_blocked" };
  }
  const transition = await transitionAdsCampaignState(prisma, campaignId, nextState, actor, options.reason ?? "eligibility_evaluated", {
    correlationId: eligibility.correlationId,
    blockingReasonCodes: eligibility.blockingReasons.map((reason) => reason.code),
    warnings: eligibility.warnings.map((reason) => reason.code),
  });
  return { ...transition, eligibility };
}

async function audit(prisma: PrismaClient, actor: AdsActor, action: string, campaign: any, previousState: string, newState: string, reason: string, metadata: Record<string, any>): Promise<void> {
  await prisma.$executeRawUnsafe(
    `INSERT INTO "AdAuditLog" ("id", "actorUserId", "actorType", "action", "resourceType", "resourceId", "metadataJson")
     VALUES (?, ?, ?, ?, 'AdCampaign', ?, ?)`,
    randomId("adaudit"),
    actor.actorId,
    actor.actorType,
    action,
    campaign.id,
    JSON.stringify({ campaignId: campaign.id, advertiserId: campaign.advertiserId, previousState, newState, reason, ...metadata }),
  );
}

function randomId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}
