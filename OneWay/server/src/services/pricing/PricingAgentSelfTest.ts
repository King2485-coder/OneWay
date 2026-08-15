import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { PrismaClient } from "@prisma/client";

import { PricingAgent, PricingAgentAuthority, previousCompletedCalendarMonth } from "./PricingAgent";
import { reportPdf, requirePricingAdmin, resultsCsv, resultsWorkbook } from "../../routes/adminPricing";

async function main(): Promise<void> {
  process.env.STRIPE_ENV = "sandbox";
  const tempDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "oneway-pricing-agent-"));
  const prisma = new PrismaClient({ datasources: { db: { url: `file:${path.join(tempDirectory, "pricing.db")}` } } });
  try {
    const agent = new PricingAgent(prisma);
    await agent.upsertProduct({ id: "private", name: "Private", category: "Private", stripeProductIDs: ["prod_private"], stripePriceIDs: ["price_private_monthly"], billingType: "MONTHLY", publicPriceMinor: 1300, currency: "USD", targetMarginBasisPoints: 7000, includedAllowances: { pstnMinutes: 100 } }, "self-test");
    for (const key of ["database_cost_per_active_user", "support_cost_per_active_user", "hosting_reserve_per_active_user", "compliance_reserve_per_active_user", "fraud_reserve_percentage", "chargeback_reserve_percentage"]) {
      await agent.addCostInput({ key, value: key.endsWith("percentage") ? 1 : 0.25, unit: key.endsWith("percentage") ? "percent" : "USD/active-user-month", currency: "USD", provider: "self-test", effectiveAt: "2026-01-01T00:00:00.000Z", source: "deterministic self-test fixture", confidence: "HIGH" }, "self-test");
    }

    const stripe = stripeFixture();
    const run = await agent.run({ stripe, actorId: "self-test", period: { start: new Date("2026-07-01T07:00:00.000Z"), end: new Date("2026-08-01T07:00:00.000Z") }, now: new Date("2026-08-05T18:00:00.000Z") });
    assert.equal(run.status, "COMPLETED");
    assert.equal(run.authority, PricingAgentAuthority.recommendationOnly);
    assert.equal(run.completeness, "COMPLETE");
    assert.equal(run.summary.monthlyGrossRevenueMinor, 1300);
    assert.equal(run.summary.stripeFeesMinor, 68);
    assert.equal(run.summary.refundsMinor, 100);
    assert.equal(run.summary.disputesMinor, 50);
    assert.equal(run.summary.marketplace.gmvMinor, 5000);
    assert.equal(run.summary.marketplace.oneWayMarketplaceRevenueMinor, 300);
    assert.equal(run.results.length, 3);
    const light = run.results.find((r: any) => r.scenario === "LIGHT");
    const heavy = run.results.find((r: any) => r.scenario === "HEAVY");
    assert.ok(light.estimatedDirectCostMinor < heavy.estimatedDirectCostMinor);
    assert.equal(run.recommendations.some((r: any) => r.status === "READY_FOR_REVIEW"), true);
    assert.match(resultsCsv(run), /private/);
    const xlsx = Buffer.from(await (await resultsWorkbook(run)).xlsx.writeBuffer());
    assert.equal(xlsx.subarray(0, 2).toString(), "PK", "XLSX must be a valid ZIP-based workbook");
    const pdf = await reportPdf(run);
    assert.equal(pdf.subarray(0, 4).toString(), "%PDF", "PDF export must be a valid PDF document");
    const recommendationId = run.recommendations[0].id;
    await agent.decideRecommendation(recommendationId, "APPROVED", "Owner approved for future planning only.", "self-test-owner");
    const decided = await agent.getRun(run.id);
    assert.equal(decided.recommendations[0].status, "APPROVED");
    await assert.rejects(() => agent.decideRecommendation(recommendationId, "IMPLEMENTED", null, "self-test-owner"), /pricing_implementation_not_supported/);
    assertUnauthorizedAdminGuard();
    const replay = await agent.run({ stripe, period: { start: new Date("2026-07-01T07:00:00.000Z"), end: new Date("2026-08-01T07:00:00.000Z") }, now: new Date("2026-08-05T18:00:00.000Z") });
    assert.equal(replay.id, run.id, "monthly run must be idempotent");
    const previous = previousCompletedCalendarMonth(new Date("2026-08-05T16:00:00.000Z"));
    assert.equal(previous.start.toISOString(), "2026-07-01T07:00:00.000Z");
    assert.equal(previous.end.toISOString(), "2026-08-01T07:00:00.000Z");
    console.log("Pricing Agent self-test passed: read-only Stripe reconciliation, marketplace separation, fees, refunds, disputes, scenarios, recommendations, and idempotency.");
  } finally {
    await prisma.$disconnect();
    fs.rmSync(tempDirectory, { recursive: true, force: true });
  }
}

function assertUnauthorizedAdminGuard(): void {
  const previousNodeEnvironment = process.env.NODE_ENV;
  const previousToken = process.env.ONEWAY_PRICING_ADMIN_TOKEN;
  process.env.NODE_ENV = "production";
  process.env.ONEWAY_PRICING_ADMIN_TOKEN = "pricing-test-secret";
  let status = 200; let body: any = null; let advanced = false;
  requirePricingAdmin({ headers: {}, userId: "self-test", authMode: "jwt" } as any, { status(code: number) { status = code; return this; }, json(value: any) { body = value; return this; } } as any, (() => { advanced = true; }) as any);
  assert.equal(status, 403);
  assert.equal(body.error, "pricing_admin_required");
  assert.equal(advanced, false);
  process.env.NODE_ENV = previousNodeEnvironment;
  if (previousToken == null) delete process.env.ONEWAY_PRICING_ADMIN_TOKEN; else process.env.ONEWAY_PRICING_ADMIN_TOKEN = previousToken;
}

function stripeFixture(): any {
  const empty = { list: async () => ({ data: [], has_more: false }) };
  return {
    accounts: { retrieve: async () => ({ id: "acct_test_oneway" }) },
    products: { list: async () => ({ data: [{ id: "prod_private", metadata: { oneway_product_id: "private" } }], has_more: false }) },
    prices: { list: async () => ({ data: [{ id: "price_private_monthly", product: { id: "prod_private", metadata: { oneway_product_id: "private" } }, metadata: { oneway_product_id: "private", oneway_plan_tier: "private", oneway_category: "Private", oneway_billing_type: "MONTHLY", oneway_allowance_version: "v1" } }], has_more: false }) },
    invoices: { list: async () => ({ data: [{ id: "in_test", customer: "cus_test", status: "paid", charge: "ch_private", lines: { data: [{ id: "il_private", amount: 1300, discount_amounts: [], price: { id: "price_private_monthly", product: { id: "prod_private", metadata: { oneway_product_id: "private" } }, metadata: { oneway_product_id: "private" } } }] } }], has_more: false }) },
    charges: { list: async () => ({ data: [{ id: "ch_private", invoice: "in_test", amount: 1300, amount_captured: 1300, customer: "cus_test", metadata: { oneway_product_id: "private" } }, { id: "ch_seller", amount: 5000, amount_captured: 5000, destination: "acct_seller", metadata: { sellerId: "seller_test" } }], has_more: false }) },
    balanceTransactions: { list: async () => ({ data: [{ id: "txn_private", source: "ch_private", amount: 1300, fee: 68, net: 1232 }], has_more: false }) },
    refunds: { list: async () => ({ data: [{ id: "re_test", charge: "ch_private", amount: 100, metadata: { oneway_product_id: "private" } }], has_more: false }) },
    disputes: { list: async () => ({ data: [{ id: "dp_test", charge: "ch_private", amount: 50, metadata: { oneway_product_id: "private" } }], has_more: false }) },
    subscriptions: { list: async () => ({ data: [{ id: "sub_test", customer: "cus_test", status: "active", created: 1782892800, items: { data: [{ price: { id: "price_private_monthly", product: { id: "prod_private", metadata: { oneway_product_id: "private" } }, metadata: { oneway_product_id: "private" } } }] } }], has_more: false }) },
    applicationFees: { list: async () => ({ data: [{ id: "fee_marketplace", amount: 300, amount_refunded: 0 }], has_more: false }) },
    transfers: { list: async () => ({ data: [{ id: "tr_seller", amount: 4700 }], has_more: false }) },
    payouts: empty, paymentIntents: empty, checkout: { sessions: empty },
  };
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
