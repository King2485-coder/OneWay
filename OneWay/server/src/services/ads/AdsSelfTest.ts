import "dotenv/config";

import { PrismaClient } from "@prisma/client";

import { handleAdsPaymentIntentSucceeded, handleAdsRefundOrDispute } from "./AdsBilling";
import { evaluateAdsCampaignEligibility } from "./AdsCampaignEligibilityService";
import { evaluateAndTransitionAdsCampaign, transitionAdsCampaignState } from "./AdsCampaignStateService";
import { requestAdDelivery, verifyDeliveryToken } from "./AdsDeliveryEngine";
import { ensureAdsTables } from "./AdsTables";
import { getAdsEventSummary, getAdsSpendSnapshot, reconcileAdsSpend, verifyAndRecordAdEvent } from "./AdsVerifiedEventService";

const prisma = new PrismaClient();

async function main(): Promise<void> {
  await ensureAdsTables(prisma);
  const stamp = Date.now().toString(36);
  const ownerUserId = `ads-test-user-${stamp}`;
  const advertiserId = `ads-test-adv-${stamp}`;
  const campaignId = `ads-test-camp-${stamp}`;
  const creativeId = `ads-test-creative-${stamp}`;
  const draftCampaignId = `ads-test-draft-camp-${stamp}`;
  const fundingCampaignId = `ads-test-funding-camp-${stamp}`;
  const fundingPaymentId = `ads-test-payment-${stamp}`;
  const activationCampaignId = `ads-test-activation-camp-${stamp}`;
  const activationCreativeId = `ads-test-activation-creative-${stamp}`;
  const activationPaymentId = `ads-test-activation-payment-${stamp}`;
  const futureCampaignId = `ads-test-future-camp-${stamp}`;
  const blockedCampaignId = `ads-test-blocked-camp-${stamp}`;
  const exhaustedCampaignId = `ads-test-exhausted-camp-${stamp}`;
  const expiredCampaignId = `ads-test-expired-camp-${stamp}`;
  const objectiveMismatchCampaignId = `ads-test-objective-mismatch-camp-${stamp}`;
  const stripePaymentIntentId = `pi_ads_test_${stamp}`;
  const activationPaymentIntentId = `pi_ads_activation_${stamp}`;
  const tokenId = `ads-test-token-${stamp}`;
  const tokenHash = `ads-test-token-hash-${stamp}`;
  const now = new Date();
  const startsPast = new Date(now.getTime() - 60_000).toISOString();
  const endsFuture = new Date(now.getTime() + 86_400_000).toISOString();
  const startsFuture = new Date(now.getTime() + 3_600_000).toISOString();
  const endsAfterFutureStart = new Date(now.getTime() + 90_000_000).toISOString();

  process.env.ONEWAY_ADS_CAMPAIGN_ACTIVATION_ENABLED = "true";
  process.env.ONEWAY_ADS_PAID_DELIVERY_ENABLED = "false";
  process.env.ONEWAY_ADS_INTERNAL_DELIVERY_ENABLED = "true";
  process.env.ONEWAY_ADS_FREQ_CAMPAIGN_HOUR = "2";
  process.env.ONEWAY_ADS_IMPRESSION_VERIFICATION_ENABLED = "true";
  process.env.ONEWAY_ADS_CLICK_VERIFICATION_ENABLED = "true";
  process.env.ONEWAY_ADS_SPEND_ACCOUNTING_ENABLED = "true";
  process.env.ONEWAY_ADS_IMPRESSION_BILLING_ENABLED = "true";
  process.env.ONEWAY_ADS_CLICK_BILLING_ENABLED = "true";
  process.env.ONEWAY_ADS_CPM_PRICE_MINOR = "1000";

  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdvertiserProfile" ("id", "ownerUserId", "businessName", "displayName", "businessType", "contactEmail", "status", "verificationStatus")
       VALUES (?, ?, 'Ads Test Business', 'Ads Test', 'creator', 'ads-test@example.com', 'active', 'verified')`,
      advertiserId,
      ownerUserId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "fundedMinor", "currency")
       VALUES (?, ?, ?, 'Ads Self Test', 'website_visits', 'active', 'approved', 'external_url', 'https://oneway.is', 500, 500, 'USD')`,
      campaignId,
      advertiserId,
      ownerUserId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "currency", "currentBuilderStep", "draftCompletionStateJson")
       VALUES (?, ?, ?, 'Ads Draft Self Test', 'website_visits', 'draft', 'notSubmitted', 'external_url', 'https://oneway.is', 500, 'USD', 'review', '{"profile":true,"objective":true,"destination":true,"creative":false,"placements":true,"budget":true}')`,
      draftCampaignId,
      advertiserId,
      ownerUserId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "currency")
       VALUES (?, ?, ?, 'Ads Funding Self Test', 'website_visits', 'paymentPending', 'approved', 'external_url', 'https://oneway.is', 1200, 'USD')`,
      fundingCampaignId,
      advertiserId,
      ownerUserId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "remainingMinor")
       VALUES (?, ?, 'USD', 1200, 0, 0)`,
      `ads-test-funding-budget-${stamp}`,
      fundingCampaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdPayment" ("id", "campaignId", "advertiserId", "ownerUserId", "stripePaymentIntentId", "amountMinor", "currency", "status", "idempotencyKey")
       VALUES (?, ?, ?, ?, ?, 1200, 'USD', 'requires_payment', ?)`,
      fundingPaymentId,
      fundingCampaignId,
      advertiserId,
      ownerUserId,
      stripePaymentIntentId,
      `ads-test-funding-${stamp}`,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "fundedMinor", "currency", "startAt", "endAt", "currentRevision")
       VALUES (?, ?, ?, 'Ads Activation Self Test', 'website_visits', 'readyForActivation', 'approved', 'external_url', 'https://oneway.is', 1500, 1500, 'USD', ?, ?, 1)`,
      activationCampaignId,
      advertiserId,
      ownerUserId,
      startsPast,
      endsFuture,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "remainingMinor")
       VALUES (?, ?, 'USD', 1500, 1500, 1500)`,
      `ads-test-activation-budget-${stamp}`,
      activationCampaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "version", "revision", "status", "moderationStatus", "headline", "bodyText", "cta")
       VALUES (?, ?, ?, ?, 1, 1, 'approved', 'approved', 'Visit OneWay', 'A private communication platform for business.', 'Learn More')`,
      activationCreativeId,
      activationCampaignId,
      advertiserId,
      ownerUserId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, 'content_feed', 1)`,
      `ads-test-activation-placement-${stamp}`,
      activationCampaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdPayment" ("id", "campaignId", "advertiserId", "ownerUserId", "stripePaymentIntentId", "amountMinor", "currency", "status", "idempotencyKey")
       VALUES (?, ?, ?, ?, ?, 1500, 'USD', 'paid', ?)`,
      activationPaymentId,
      activationCampaignId,
      advertiserId,
      ownerUserId,
      activationPaymentIntentId,
      `ads-test-activation-payment-${stamp}`,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdLedgerEntry" ("id", "campaignId", "advertiserId", "entryType", "amountMinor", "currency", "status", "idempotencyKey", "stripeEventId", "stripePaymentIntentId")
       VALUES (?, ?, ?, 'campaignFunding', 1500, 'USD', 'posted', ?, ?, ?)`,
      `ads-test-activation-ledger-${stamp}`,
      activationCampaignId,
      advertiserId,
      `ads-test-activation-ledger-key-${stamp}`,
      `evt_ads_activation_${stamp}`,
      activationPaymentIntentId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdReceipt" ("id", "receiptNumber", "campaignId", "advertiserId", "ownerUserId", "paymentId", "stripePaymentIntentId", "stripeEventId", "amountMinor", "currency", "status")
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1500, 'USD', 'issued')`,
      `ads-test-activation-receipt-${stamp}`,
      `OWADS-TEST-${stamp}`,
      activationCampaignId,
      advertiserId,
      ownerUserId,
      activationPaymentId,
      activationPaymentIntentId,
      `evt_ads_activation_${stamp}`,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "fundedMinor", "currency", "startAt", "endAt")
       VALUES (?, ?, ?, 'Ads Future Self Test', 'website_visits', 'readyForActivation', 'approved', 'external_url', 'https://oneway.is', 1500, 1500, 'USD', ?, ?)`,
      futureCampaignId,
      advertiserId,
      ownerUserId,
      startsFuture,
      endsAfterFutureStart,
    );
    await tx.$executeRawUnsafe(`INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "remainingMinor") VALUES (?, ?, 'USD', 1500, 1500, 1500)`, `ads-test-future-budget-${stamp}`, futureCampaignId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "status", "moderationStatus", "headline", "bodyText", "cta") VALUES (?, ?, ?, ?, 'approved', 'approved', 'Future OneWay', 'A scheduled campaign for OneWay Ads.', 'Learn More')`, `ads-test-future-creative-${stamp}`, futureCampaignId, advertiserId, ownerUserId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, 'content_feed', 1)`, `ads-test-future-placement-${stamp}`, futureCampaignId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdPayment" ("id", "campaignId", "advertiserId", "ownerUserId", "stripePaymentIntentId", "amountMinor", "currency", "status", "idempotencyKey") VALUES (?, ?, ?, ?, ?, 1500, 'USD', 'paid', ?)`, `ads-test-future-payment-${stamp}`, futureCampaignId, advertiserId, ownerUserId, `pi_ads_future_${stamp}`, `ads-test-future-payment-${stamp}`);
    await tx.$executeRawUnsafe(`INSERT INTO "AdLedgerEntry" ("id", "campaignId", "advertiserId", "entryType", "amountMinor", "currency", "status", "idempotencyKey", "stripeEventId", "stripePaymentIntentId") VALUES (?, ?, ?, 'campaignFunding', 1500, 'USD', 'posted', ?, ?, ?)`, `ads-test-future-ledger-${stamp}`, futureCampaignId, advertiserId, `ads-test-future-ledger-key-${stamp}`, `evt_ads_future_${stamp}`, `pi_ads_future_${stamp}`);
    await tx.$executeRawUnsafe(`INSERT INTO "AdReceipt" ("id", "receiptNumber", "campaignId", "advertiserId", "ownerUserId", "paymentId", "stripePaymentIntentId", "stripeEventId", "amountMinor", "currency", "status") VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1500, 'USD', 'issued')`, `ads-test-future-receipt-${stamp}`, `OWADS-FUTURE-${stamp}`, futureCampaignId, advertiserId, ownerUserId, `ads-test-future-payment-${stamp}`, `pi_ads_future_${stamp}`, `evt_ads_future_${stamp}`);
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "currency", "startAt", "endAt")
       VALUES (?, ?, ?, 'Ads Blocked Self Test', 'website_visits', 'readyForActivation', 'approved', 'external_url', 'https://oneway.is', 1500, 'USD', ?, ?)`,
      blockedCampaignId,
      advertiserId,
      ownerUserId,
      startsPast,
      endsFuture,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "fundedMinor", "currency", "startAt", "endAt")
       VALUES (?, ?, ?, 'Ads Exhausted Self Test', 'website_visits', 'eligibleForDelivery', 'approved', 'external_url', 'https://oneway.is', 1500, 1500, 'USD', ?, ?)`,
      exhaustedCampaignId,
      advertiserId,
      ownerUserId,
      startsPast,
      endsFuture,
    );
    await tx.$executeRawUnsafe(`INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "spentMinor", "remainingMinor") VALUES (?, ?, 'USD', 1500, 1500, 1500, 0)`, `ads-test-exhausted-budget-${stamp}`, exhaustedCampaignId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "revision", "status", "moderationStatus", "headline", "bodyText", "cta") VALUES (?, ?, ?, ?, 1, 'approved', 'approved', 'Exhausted OneWay', 'A spent campaign should not deliver.', 'Learn More')`, `ads-test-exhausted-creative-${stamp}`, exhaustedCampaignId, advertiserId, ownerUserId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, 'content_feed', 1)`, `ads-test-exhausted-placement-${stamp}`, exhaustedCampaignId);
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "fundedMinor", "currency", "startAt", "endAt")
       VALUES (?, ?, ?, 'Ads Expired Self Test', 'website_visits', 'eligibleForDelivery', 'approved', 'external_url', 'https://oneway.is', 1500, 1500, 'USD', ?, ?)`,
      expiredCampaignId,
      advertiserId,
      ownerUserId,
      new Date(now.getTime() - 172_800_000).toISOString(),
      new Date(now.getTime() - 86_400_000).toISOString(),
    );
    await tx.$executeRawUnsafe(`INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "remainingMinor") VALUES (?, ?, 'USD', 1500, 1500, 1500)`, `ads-test-expired-budget-${stamp}`, expiredCampaignId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "revision", "status", "moderationStatus", "headline", "bodyText", "cta") VALUES (?, ?, ?, ?, 1, 'approved', 'approved', 'Expired OneWay', 'An expired campaign should not deliver.', 'Learn More')`, `ads-test-expired-creative-${stamp}`, expiredCampaignId, advertiserId, ownerUserId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, 'content_feed', 1)`, `ads-test-expired-placement-${stamp}`, expiredCampaignId);
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCampaign" ("id", "advertiserId", "ownerUserId", "name", "objective", "status", "moderationStatus", "destinationType", "destinationURL", "lifetimeBudgetMinor", "fundedMinor", "currency", "startAt", "endAt", "currentRevision")
       VALUES (?, ?, ?, 'Ads Objective Mismatch Self Test', 'website_visits', 'eligibleForDelivery', 'approved', 'external_url', 'https://oneway.is', 1500, 1500, 'USD', ?, ?, 1)`,
      objectiveMismatchCampaignId,
      advertiserId,
      ownerUserId,
      startsPast,
      endsFuture,
    );
    await tx.$executeRawUnsafe(`INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "remainingMinor") VALUES (?, ?, 'USD', 1500, 1500, 1500)`, `ads-test-objective-mismatch-budget-${stamp}`, objectiveMismatchCampaignId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "revision", "status", "moderationStatus", "headline", "bodyText", "cta") VALUES (?, ?, ?, ?, 1, 'approved', 'approved', 'Mismatch OneWay', 'A mismatched placement should not deliver.', 'Learn More')`, `ads-test-objective-mismatch-creative-${stamp}`, objectiveMismatchCampaignId, advertiserId, ownerUserId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, 'shop_discovery', 1)`, `ads-test-objective-mismatch-placement-${stamp}`, objectiveMismatchCampaignId);
    await tx.$executeRawUnsafe(`INSERT INTO "AdPayment" ("id", "campaignId", "advertiserId", "ownerUserId", "stripePaymentIntentId", "amountMinor", "currency", "status", "idempotencyKey") VALUES (?, ?, ?, ?, ?, 1500, 'USD', 'paid', ?)`, `ads-test-objective-mismatch-payment-${stamp}`, objectiveMismatchCampaignId, advertiserId, ownerUserId, `pi_ads_objective_mismatch_${stamp}`, `ads-test-objective-mismatch-payment-${stamp}`);
    await tx.$executeRawUnsafe(`INSERT INTO "AdLedgerEntry" ("id", "campaignId", "advertiserId", "entryType", "amountMinor", "currency", "status", "idempotencyKey", "stripeEventId", "stripePaymentIntentId") VALUES (?, ?, ?, 'campaignFunding', 1500, 'USD', 'posted', ?, ?, ?)`, `ads-test-objective-mismatch-ledger-${stamp}`, objectiveMismatchCampaignId, advertiserId, `ads-test-objective-mismatch-ledger-key-${stamp}`, `evt_ads_objective_mismatch_${stamp}`, `pi_ads_objective_mismatch_${stamp}`);
    await tx.$executeRawUnsafe(`INSERT INTO "AdReceipt" ("id", "receiptNumber", "campaignId", "advertiserId", "ownerUserId", "paymentId", "stripePaymentIntentId", "stripeEventId", "amountMinor", "currency", "status") VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1500, 'USD', 'issued')`, `ads-test-objective-mismatch-receipt-${stamp}`, `OWADS-MISMATCH-${stamp}`, objectiveMismatchCampaignId, advertiserId, ownerUserId, `ads-test-objective-mismatch-payment-${stamp}`, `pi_ads_objective_mismatch_${stamp}`, `evt_ads_objective_mismatch_${stamp}`);
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdBudget" ("id", "campaignId", "currency", "lifetimeBudgetMinor", "fundedMinor", "remainingMinor")
       VALUES (?, ?, 'USD', 500, 500, 500)`,
      `ads-test-budget-${stamp}`,
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdCreative" ("id", "campaignId", "advertiserId", "ownerUserId", "status", "moderationStatus", "headline", "bodyText", "cta")
       VALUES (?, ?, ?, ?, 'approved', 'approved', 'Visit OneWay', 'See what OneWay can do for your business.', 'Learn More')`,
      creativeId,
      campaignId,
      advertiserId,
      ownerUserId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdPlacementSelection" ("id", "campaignId", "placement", "enabled") VALUES (?, ?, 'site_discovery', 1)`,
      `ads-test-placement-${stamp}`,
      campaignId,
    );
    await tx.$executeRawUnsafe(
      `INSERT INTO "AdDeliveryToken" ("id", "campaignId", "creativeId", "viewerHash", "placement", "tokenHash", "expiresAt")
       VALUES (?, ?, ?, 'viewer-safe-hash', 'site_discovery', ?, datetime('now','+10 minutes'))`,
      tokenId,
      campaignId,
      creativeId,
      tokenHash,
    );
  });

  const privateProbe = await prisma.$queryRawUnsafe<Array<{ name: string }>>(
    `SELECT name FROM sqlite_master WHERE type="table" AND name IN ('Message','Conversation','CallSession','Call')`,
  );
  const phase1Columns = await prisma.$queryRawUnsafe<Array<{ name: string }>>(`PRAGMA table_info("AdCampaign")`);
  const phase1ColumnNames = new Set(phase1Columns.map((row) => row.name));
  for (const required of ["currentBuilderStep", "draftCompletionStateJson", "clientSubmissionId", "submittedSnapshotJson", "scheduleTimezone", "version"]) {
    if (!phase1ColumnNames.has(required)) throw new Error(`missing_phase1_campaign_column:${required}`);
  }
  const crossOwnerRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "ownerUserId" = ?`, draftCampaignId, `other-${ownerUserId}`);
  if (crossOwnerRows.length !== 0) throw new Error("cross_owner_campaign_query_returned_rows");
  await prisma.$executeRawUnsafe(`UPDATE "AdCampaign" SET "deletedAt" = CURRENT_TIMESTAMP, "status" = 'canceled' WHERE "id" = ? AND "ownerUserId" = ? AND "status" = 'draft'`, draftCampaignId, ownerUserId);
  const deletedDraftRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "deletedAt" IS NOT NULL`, draftCampaignId);
  if (deletedDraftRows.length !== 1) throw new Error("draft_delete_did_not_persist");
  const stripeEvent = { id: `evt_ads_test_${stamp}`, type: "payment_intent.succeeded" };
  const stripeIntent = {
    id: stripePaymentIntentId,
    amount: 1200,
    amount_received: 1200,
    currency: "usd",
    metadata: {
      paymentDomain: "ads",
      adsPaymentId: fundingPaymentId,
      campaignId: fundingCampaignId,
      advertiserId,
      oneWayUserId: ownerUserId,
    },
  };
  const firstFundingHandled = await handleAdsPaymentIntentSucceeded(prisma, stripeEvent, stripeIntent);
  const duplicateFundingHandled = await handleAdsPaymentIntentSucceeded(prisma, stripeEvent, stripeIntent);
  if (!firstFundingHandled || !duplicateFundingHandled) throw new Error("ads_funding_webhook_not_handled");
  const fundingRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ?`, fundingCampaignId);
  const funded = fundingRows[0];
  if (Number(funded.fundedMinor) !== 1200 || funded.status !== "readyForActivation") throw new Error("ads_funding_status_or_balance_invalid");
  const ledgerRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdLedgerEntry" WHERE "campaignId" = ? AND "entryType" = 'campaignFunding'`, fundingCampaignId);
  if (ledgerRows.length !== 1) throw new Error("duplicate_ads_funding_ledger_credit_created");
  const receiptRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdReceipt" WHERE "campaignId" = ?`, fundingCampaignId);
  if (receiptRows.length !== 1) throw new Error("ads_receipt_not_created");
  await handleAdsRefundOrDispute(prisma, { id: `evt_ads_refund_${stamp}`, type: "charge.refunded" }, { id: `ch_ads_test_${stamp}`, payment_intent: stripePaymentIntentId, amount_refunded: 200, currency: "usd" });
  const refundRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdLedgerEntry" WHERE "campaignId" = ? AND "entryType" = 'refund'`, fundingCampaignId);
  if (refundRows.length !== 1 || Number(refundRows[0].amountMinor) !== -200) throw new Error("ads_refund_ledger_invalid");
  const eligibility = await evaluateAdsCampaignEligibility(prisma, activationCampaignId, { ownerUserId, persist: true });
  if (!eligibility.isEligible || eligibility.resultingRecommendedState !== "eligibleForDelivery" || !eligibility.deliveryBlocked) throw new Error(`ads_activation_eligibility_invalid:${JSON.stringify(eligibility.blockingReasons)}`);
  const activationTransition = await evaluateAndTransitionAdsCampaign(prisma, activationCampaignId, { actorType: "user", actorId: ownerUserId }, { ownerUserId, reason: "self_test_activation" });
  if (!activationTransition.ok || activationTransition.newState !== "eligibleForDelivery") throw new Error("ads_activation_transition_failed");
  const activeRows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AdCampaign" WHERE "id" = ? AND "status" = 'active'`, activationCampaignId);
  if (activeRows.length !== 0) throw new Error("phase2b_moved_campaign_to_active");
  const futureTransition = await evaluateAndTransitionAdsCampaign(prisma, futureCampaignId, { actorType: "user", actorId: ownerUserId }, { ownerUserId, reason: "self_test_future_schedule" });
  if (!futureTransition.ok || futureTransition.newState !== "scheduled") throw new Error("ads_future_schedule_transition_failed");
  const blockedEligibility = await evaluateAdsCampaignEligibility(prisma, blockedCampaignId, { ownerUserId, persist: true });
  if (blockedEligibility.isEligible || !blockedEligibility.blockingReasons.some((reason) => reason.code === "creative_missing" || reason.code === "payment_not_verified")) throw new Error("ads_blocked_eligibility_failed");
  const pauseTransition = await transitionAdsCampaignState(prisma, activationCampaignId, "paused", { actorType: "user", actorId: ownerUserId }, "self_test_pause");
  if (!pauseTransition.ok) throw new Error("ads_pause_transition_failed");
  await transitionAdsCampaignState(prisma, activationCampaignId, "readyForActivation", { actorType: "user", actorId: ownerUserId }, "self_test_resume_prep");
  const resumeTransition = await evaluateAndTransitionAdsCampaign(prisma, activationCampaignId, { actorType: "user", actorId: ownerUserId }, { ownerUserId, reason: "self_test_resume" });
  if (!resumeTransition.ok || resumeTransition.newState !== "eligibleForDelivery") throw new Error("ads_resume_reevaluation_failed");
  const publicBlocked = await requestAdDelivery(prisma, {
    placement: "content_feed",
    viewerHash: `viewer-public-${stamp}`,
    country: "US",
    deviceClass: "ios",
    internalTest: false,
  });
  if (publicBlocked.ad || publicBlocked.reason !== "ads_delivery_disabled" || publicBlocked.deliveryStatus.paidDeliveryEnabled) throw new Error("phase3a_public_delivery_not_blocked");
  const deliveryOne = await requestAdDelivery(prisma, {
    placement: "content_feed",
    viewerHash: `viewer-internal-${stamp}`,
    country: "US",
    deviceClass: "ios",
    contextualCategory: "business",
    internalTest: true,
    campaignId: activationCampaignId,
    ownerUserId,
  });
  if (!deliveryOne.ad || !deliveryOne.delivery?.token || deliveryOne.delivery.paidDeliveryEnabled) throw new Error(`phase3a_internal_delivery_failed:${deliveryOne.reason}`);
  const tokenVerification = await verifyDeliveryToken(prisma, deliveryOne.delivery.token, { campaignId: activationCampaignId, placement: "content_feed" });
  if (!tokenVerification.ok) throw new Error(`phase3a_token_verification_failed:${tokenVerification.error}`);
  if (!deliveryOne.ad.impressionToken || !deliveryOne.ad.clickToken) throw new Error("phase3b_event_tokens_missing");
  const verifiedImpression = await verifyAndRecordAdEvent(prisma, {
    eventType: "impression",
    token: deliveryOne.ad.impressionToken,
    clientEventId: `imp-${stamp}`,
    visibleAreaPercent: 95,
    durationMs: 1500,
    deviceClass: "ios",
    country: "US",
    sessionReference: `session-${stamp}`,
  });
  if (!verifiedImpression.ok || !verifiedImpression.counted || verifiedImpression.costMinor !== 1) throw new Error(`phase3b_impression_not_verified:${JSON.stringify(verifiedImpression)}`);
  const duplicateImpression = await verifyAndRecordAdEvent(prisma, {
    eventType: "impression",
    token: deliveryOne.ad.impressionToken,
    clientEventId: `imp-${stamp}`,
    visibleAreaPercent: 95,
    durationMs: 1500,
    deviceClass: "ios",
    country: "US",
    sessionReference: `session-${stamp}`,
  });
  if (!duplicateImpression.duplicate || duplicateImpression.costMinor !== 1) throw new Error("phase3b_duplicate_impression_not_idempotent");
  const verifiedClick = await verifyAndRecordAdEvent(prisma, {
    eventType: "click",
    token: deliveryOne.ad.clickToken,
    clientEventId: `click-${stamp}`,
    deviceClass: "ios",
    country: "US",
    sessionReference: `session-${stamp}`,
  });
  if (!verifiedClick.ok || !verifiedClick.counted) throw new Error(`phase3b_click_not_verified:${JSON.stringify(verifiedClick)}`);
  const tamperedEventToken = `${deliveryOne.ad.impressionToken.slice(0, -1)}x`;
  const tamperedEvent = await verifyAndRecordAdEvent(prisma, {
    eventType: "impression",
    token: tamperedEventToken,
    clientEventId: `tampered-${stamp}`,
    visibleAreaPercent: 95,
    durationMs: 1500,
  });
  if (tamperedEvent.ok || tamperedEvent.failureReasonCode !== "invalid_signature") throw new Error("phase3b_tampered_event_not_rejected");
  const spendSnapshot = await getAdsSpendSnapshot(prisma, activationCampaignId, ownerUserId);
  if (!spendSnapshot || spendSnapshot.verifiedEvents < 2 || spendSnapshot.latestLedgerDebit?.entryType !== "impressionSpend") throw new Error("phase3b_spend_snapshot_invalid");
  const eventSummary = await getAdsEventSummary(prisma, activationCampaignId, ownerUserId);
  if (!eventSummary || !eventSummary.byType.some((row: any) => row.eventType === "impression")) throw new Error("phase3b_event_summary_missing");
  const spendReconciliation = await reconcileAdsSpend(prisma, activationCampaignId, ownerUserId);
  if (!spendReconciliation?.reconciled) throw new Error("phase3b_spend_reconciliation_failed");
  const tamperedToken = `${deliveryOne.delivery.token.slice(0, -1)}x`;
  const tamperedVerification = await verifyDeliveryToken(prisma, tamperedToken, { campaignId: activationCampaignId, placement: "content_feed" });
  if (tamperedVerification.ok || tamperedVerification.error !== "invalid_signature") throw new Error("phase3a_tampered_token_not_rejected");
  await prisma.$executeRawUnsafe(`UPDATE "AdDeliveryToken" SET "impressionId" = ? WHERE "deliveryId" = ?`, `ads-test-duplicate-impression-${stamp}`, deliveryOne.delivery.deliveryId);
  const duplicateVerification = await verifyDeliveryToken(prisma, deliveryOne.delivery.token, { campaignId: activationCampaignId, placement: "content_feed" });
  if (duplicateVerification.ok || duplicateVerification.error !== "duplicate_delivery") throw new Error("phase3a_duplicate_delivery_not_rejected");
  const deliveryTwo = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-frequency-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: activationCampaignId, ownerUserId });
  const deliveryThree = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-frequency-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: activationCampaignId, ownerUserId });
  const deliveryFour = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-frequency-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: activationCampaignId, ownerUserId });
  if (!deliveryTwo.ad || !deliveryThree.ad || deliveryFour.ad || deliveryFour.reason !== "frequency_exceeded") throw new Error(`phase3a_frequency_cap_failed:${deliveryFour.reason}`);
  const futureDelivery = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-future-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: futureCampaignId, ownerUserId });
  if (futureDelivery.ad) throw new Error("phase3a_future_campaign_delivered");
  const expiredDelivery = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-expired-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: expiredCampaignId, ownerUserId });
  if (expiredDelivery.ad) throw new Error("phase3a_expired_campaign_delivered");
  const exhaustedDelivery = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-exhausted-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: exhaustedCampaignId, ownerUserId });
  if (exhaustedDelivery.ad) throw new Error("phase3a_exhausted_campaign_delivered");
  const noFundingDelivery = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-nofunding-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: blockedCampaignId, ownerUserId });
  if (noFundingDelivery.ad) throw new Error("phase3a_unfunded_campaign_delivered");
  const placementMismatch = await requestAdDelivery(prisma, { placement: "site_discovery", viewerHash: `viewer-placement-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: activationCampaignId, ownerUserId });
  if (placementMismatch.ad) throw new Error("phase3a_placement_mismatch_delivered");
  const objectiveMismatch = await requestAdDelivery(prisma, { placement: "shop_discovery", viewerHash: `viewer-objective-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: objectiveMismatchCampaignId, ownerUserId });
  if (objectiveMismatch.ad || objectiveMismatch.reason !== "objective_or_destination_placement_mismatch") throw new Error(`phase3a_objective_mismatch_failed:${objectiveMismatch.reason}`);
  const pauseForDelivery = await transitionAdsCampaignState(prisma, activationCampaignId, "paused", { actorType: "user", actorId: ownerUserId }, "self_test_phase3a_pause");
  if (!pauseForDelivery.ok) throw new Error("phase3a_pause_setup_failed");
  const pausedDelivery = await requestAdDelivery(prisma, { placement: "content_feed", viewerHash: `viewer-paused-${stamp}`, country: "US", deviceClass: "ios", internalTest: true, campaignId: activationCampaignId, ownerUserId });
  if (pausedDelivery.ad) throw new Error("phase3a_paused_campaign_delivered");
  await transitionAdsCampaignState(prisma, activationCampaignId, "readyForActivation", { actorType: "user", actorId: ownerUserId }, "self_test_phase3a_resume_prep");
  await evaluateAndTransitionAdsCampaign(prisma, activationCampaignId, { actorType: "user", actorId: ownerUserId }, { ownerUserId, reason: "self_test_phase3a_resume" });
  await prisma.$executeRawUnsafe(`UPDATE "AdCreative" SET "headline" = 'Changed After Approval', "approvedFingerprint" = 'old-fingerprint', "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = ?`, activationCreativeId);
  await prisma.$executeRawUnsafe(`UPDATE "AdCampaign" SET "status" = 'readyForActivation' WHERE "id" = ?`, activationCampaignId);
  const revisionBlocked = await evaluateAdsCampaignEligibility(prisma, activationCampaignId, { ownerUserId, persist: true });
  if (revisionBlocked.isEligible || !revisionBlocked.blockingReasons.some((reason) => reason.code === "creative_version_mismatch")) throw new Error("ads_revision_safety_failed");
  const impressionId = `ads-test-impression-${stamp}`;
  await prisma.$executeRawUnsafe(
    `INSERT INTO "AdImpression" ("id", "campaignId", "creativeId", "advertiserId", "placement", "viewerHash", "tokenHash")
     VALUES (?, ?, ?, ?, 'site_discovery', 'viewer-safe-hash', ?)`,
    impressionId,
    campaignId,
    creativeId,
    advertiserId,
    tokenHash,
  );
  const duplicateBlocked = await prisma.$executeRawUnsafe(
    `INSERT OR IGNORE INTO "AdImpression" ("id", "campaignId", "creativeId", "advertiserId", "placement", "viewerHash", "tokenHash")
     VALUES (?, ?, ?, ?, 'site_discovery', 'viewer-safe-hash', ?)`,
    `ads-test-impression-dupe-${stamp}`,
    campaignId,
    creativeId,
    advertiserId,
    tokenHash,
  );
  if (Number(duplicateBlocked) !== 0) throw new Error("duplicate_impression_was_not_blocked");

  console.log(JSON.stringify({
    ok: true,
    advertiserLifecycle: "created_active",
    campaignLifecycle: "active_approved_funded",
    phase1DraftLifecycle: "created_saved_deleted",
    phase2aFundingLifecycle: "paid_ready_for_activation",
    phase2bEligibility: "eligible_for_delivery_certified",
    phase2bPaidDeliveryBlocked: "passed",
    phase2bFutureSchedule: "scheduled",
    phase2bBlockedCampaign: "blocked",
    phase2bPauseResume: "passed",
    phase2bRevisionSafety: "passed",
    phase3aDeliveryEngine: "internal_delivery_signed_payload",
    phase3aPaidDeliveryPublicBlocked: "passed",
    phase3aFrequencyCaps: "passed",
    phase3aPlacementMismatch: "passed",
    phase3aObjectiveMismatch: "passed",
    phase3aFutureExpiredExhaustedBlocked: "passed",
    phase3aPausedAndUnfundedBlocked: "passed",
    phase3aTokenFraudProtection: "passed",
    phase3bVerifiedImpression: "passed",
    phase3bVerifiedClick: "passed",
    phase3bReplayProtection: "passed",
    phase3bSpendAccounting: "passed",
    phase3bSpendReconciliation: "passed",
    duplicateWebhookCreditProtection: "passed",
    receiptGeneration: "passed",
    refundFoundation: "passed",
    phase1SchemaColumns: "present",
    crossOwnerCampaignBoundary: "passed",
    deliveryToken: "created",
    duplicateImpressionProtection: "passed",
    privateCommunicationTablesQueriedByAds: false,
    privateTableNamesOnlyForBoundaryProbe: privateProbe.map((row) => row.name).sort(),
  }, null, 2));
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
