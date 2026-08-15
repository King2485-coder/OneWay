import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";

import { logger } from "../../lib/logger";
import { createStripeClient } from "../stripe";
import { ensurePricingAgentTables } from "./PricingAgentTables";

export enum PricingAgentAuthority {
  readOnly = "readOnly",
  recommendationOnly = "recommendationOnly",
  approvalRequired = "approvalRequired",
}

export type PricingScenario = "LIGHT" | "EXPECTED" | "HEAVY";
export type RecommendationState = "DRAFT" | "READY_FOR_REVIEW" | "APPROVED" | "REJECTED" | "DEFERRED" | "IMPLEMENTED" | "EXPIRED";

export interface ReportingPeriod { start: Date; end: Date }
export interface RunOptions { period?: ReportingPeriod; actorId?: string; force?: boolean; stripe?: any; now?: Date }

type ProductRegistryRow = {
  id: string; name: string; category: string; stripeProductIdsJson: string; stripePriceIdsJson: string;
  billingType: string; publicPriceMinor: number; currency: string; targetMarginBasisPoints: number;
  includedAllowancesJson: string; metadataJson: string;
};

type ProductAccumulator = {
  product: ProductRegistryRow;
  stripeProductId: string | null;
  stripePriceId: string | null;
  gross: number; fees: number; refunds: number; disputes: number; discounts: number;
  activeCustomers: Set<string>; newCustomers: Set<string>; cancelledCustomers: Set<string>;
  failedPayments: number; paidPayments: number; trialsStarted: number; trialsConverted: number;
};

const DATA_SOURCE_VERSION = "stripe-v1";
const COST_MODEL_VERSION = "oneway-cost-v1";
const SCENARIO_MULTIPLIER: Record<PricingScenario, number> = { LIGHT: 0.55, EXPECTED: 1, HEAVY: 1.8 };
const ALLOWED_STATES = new Set<RecommendationState>(["DRAFT", "READY_FOR_REVIEW", "APPROVED", "REJECTED", "DEFERRED", "IMPLEMENTED", "EXPIRED"]);

export class PricingAgent {
  constructor(private readonly prisma: PrismaClient) {}

  async run(options: RunOptions = {}): Promise<Record<string, any>> {
    await ensurePricingAgentTables(this.prisma);
    const now = options.now ?? new Date();
    const period = options.period ?? previousCompletedCalendarMonth(now);
    validateCompletedPeriod(period, now);
    const environment = stripeEnvironment();
    const idempotencyKey = `pricing:${environment}:${period.start.toISOString()}:${period.end.toISOString()}`;
    const existing = await this.rows(`SELECT * FROM "PricingAgentRun" WHERE "idempotencyKey" = ? LIMIT 1`, idempotencyKey);
    const retryFailedRun = existing[0]?.status === "FAILED";
    if (existing[0] && !options.force && !retryFailedRun) return this.getRun(String(existing[0].id));

    const stripe = options.stripe ?? createStripeClient();
    if (!stripe) throw new Error("stripe_not_configured");
    if (!options.stripe && !/^(sk|rk)_(test|live)_/.test(process.env.STRIPE_SECRET_KEY?.trim() ?? "")) {
      throw new Error("invalid_stripe_secret_key_format");
    }
    if (environment === "production" && process.env.PRICING_AGENT_ALLOW_LIVE_READS !== "true") {
      throw new Error("pricing_agent_live_reads_not_approved");
    }

    const runId = existing[0]?.id ? String(existing[0].id) : crypto.randomUUID();
    if (existing[0] && (options.force || retryFailedRun)) {
      await this.prisma.$executeRawUnsafe(`DELETE FROM "PricingAgentProductResult" WHERE "runId" = ?`, runId);
      await this.prisma.$executeRawUnsafe(`DELETE FROM "PricingAgentRecommendation" WHERE "runId" = ?`, runId);
      await this.prisma.$executeRawUnsafe(`DELETE FROM "PricingAgentReport" WHERE "runId" = ?`, runId);
      await this.prisma.$executeRawUnsafe(`DELETE FROM "PricingAgentAlert" WHERE "runId" = ?`, runId);
      await this.prisma.$executeRawUnsafe(`UPDATE "PricingAgentRun" SET "status" = 'RUNNING', "startedAt" = ?, "completedAt" = NULL, "errorSummary" = NULL WHERE "id" = ?`, now.toISOString(), runId);
    } else {
      await this.prisma.$executeRawUnsafe(
        `INSERT INTO "PricingAgentRun" ("id", "idempotencyKey", "startedAt", "status", "reportingPeriodStart", "reportingPeriodEnd", "stripeEnvironment", "dataSourceVersion", "costModelVersion", "authority") VALUES (?, ?, ?, 'RUNNING', ?, ?, ?, ?, ?, ?)`,
        runId, idempotencyKey, now.toISOString(), period.start.toISOString(), period.end.toISOString(), environment,
        DATA_SOURCE_VERSION, COST_MODEL_VERSION, PricingAgentAuthority.recommendationOnly,
      );
    }
    await this.audit(options.actorId ?? "pricing-agent", "system", "pricing.run.started", "PricingAgentRun", runId, { period });

    try {
      const account = await stripe.accounts.retrieve();
      const accountId = String(account?.id ?? process.env.STRIPE_PLATFORM_ACCOUNT_ID ?? "unknown");
      const registry = await this.productRegistry();
      const snapshot = await collectStripeSnapshot(stripe, period);
      const { accumulators, missingMappings } = buildAccumulators(registry, snapshot, period);
      const costInputs = await this.activeCostInputs(period.end);
      const missingCosts = requiredCostKeys().filter((key) => costInputs[key] == null);
      const results: Array<Record<string, any>> = [];

      for (const accumulator of accumulators.values()) {
        for (const scenario of ["LIGHT", "EXPECTED", "HEAVY"] as PricingScenario[]) {
          const result = calculateResult(accumulator, scenario, costInputs);
          await this.saveResult(runId, result);
          results.push(result);
        }
      }

      if (missingMappings.length) await this.alert(runId, "WARNING", "UNMAPPED_STRIPE_OBJECTS", `${missingMappings.length} Stripe objects could not be mapped with stable OneWay metadata.`, { stripeObjectIds: missingMappings });
      if (missingCosts.length) await this.alert(runId, "WARNING", "MISSING_COST_INPUTS", "Direct-cost calculations are incomplete until the listed cost inputs are configured.", { keys: missingCosts });

      const recommendations = await this.generateRecommendations(runId, results, missingCosts.length > 0);
      const summary = buildSummary(results, snapshot, missingMappings, missingCosts, recommendations);
      const completeness = missingMappings.length || missingCosts.length ? "INCOMPLETE" : "COMPLETE";
      const report = buildReport(period, summary, results, recommendations, completeness);
      await this.prisma.$executeRawUnsafe(
        `INSERT INTO "PricingAgentReport" ("id", "runId", "title", "reportJson", "reportHtml") VALUES (?, ?, ?, ?, ?)`,
        crypto.randomUUID(), runId, report.title, JSON.stringify(report), renderReportHtml(report),
      );
      await this.prisma.$executeRawUnsafe(
        `UPDATE "PricingAgentRun" SET "status" = 'COMPLETED', "completedAt" = ?, "stripeAccountId" = ?, "completeness" = ?, "summaryJson" = ? WHERE "id" = ?`,
        new Date().toISOString(), accountId, completeness, JSON.stringify(summary), runId,
      );
      await this.audit(options.actorId ?? "pricing-agent", "system", "pricing.run.completed", "PricingAgentRun", runId, { completeness, productResultCount: results.length });
      return this.getRun(runId);
    } catch (error) {
      const message = safeErrorMessage(error);
      await this.prisma.$executeRawUnsafe(`UPDATE "PricingAgentRun" SET "status" = 'FAILED', "completedAt" = ?, "errorSummary" = ? WHERE "id" = ?`, new Date().toISOString(), message.slice(0, 1000), runId);
      await this.alert(runId, "CRITICAL", "RUN_FAILED", "Stripe reconciliation failed. The previous completed report remains authoritative.", { error: message });
      await this.audit(options.actorId ?? "pricing-agent", "system", "pricing.run.failed", "PricingAgentRun", runId, { error: message });
      logger.error({ err: error, runId }, "PRICING_AGENT_RUN_FAILED");
      throw error;
    }
  }

  async getRun(runId: string): Promise<Record<string, any>> {
    await ensurePricingAgentTables(this.prisma);
    const run = (await this.rows(`SELECT * FROM "PricingAgentRun" WHERE "id" = ? LIMIT 1`, runId))[0];
    if (!run) throw new Error("pricing_run_not_found");
    const [results, recommendations, reports, alerts] = await Promise.all([
      this.rows(`SELECT * FROM "PricingAgentProductResult" WHERE "runId" = ? ORDER BY "productId", "scenario"`, runId),
      this.rows(`SELECT * FROM "PricingAgentRecommendation" WHERE "runId" = ? ORDER BY "severity" DESC, "createdAt" DESC`, runId),
      this.rows(`SELECT * FROM "PricingAgentReport" WHERE "runId" = ? LIMIT 1`, runId),
      this.rows(`SELECT * FROM "PricingAgentAlert" WHERE "runId" = ? ORDER BY "createdAt" DESC`, runId),
    ]);
    return { ...run, summary: json(run.summaryJson, {}), results: results.map(parseResult), recommendations: recommendations.map(parseRecommendation), report: reports[0] ? { ...reports[0], report: json(reports[0].reportJson, {}) } : null, alerts };
  }

  async dashboard(): Promise<Record<string, any>> {
    await ensurePricingAgentTables(this.prisma);
    const latest = (await this.rows(`SELECT "id" FROM "PricingAgentRun" WHERE "status" = 'COMPLETED' ORDER BY "reportingPeriodEnd" DESC LIMIT 1`))[0];
    const history = await this.rows(`SELECT "id", "status", "reportingPeriodStart", "reportingPeriodEnd", "completeness", "startedAt", "completedAt", "errorSummary" FROM "PricingAgentRun" ORDER BY "startedAt" DESC LIMIT 24`);
    const costs = await this.rows(`SELECT * FROM "PricingAgentCostInput" ORDER BY "key", "effectiveAt" DESC`);
    return { authority: PricingAgentAuthority.recommendationOnly, latestRun: latest ? await this.getRun(String(latest.id)) : null, runHistory: history, costInputs: costs };
  }

  async upsertProduct(input: Record<string, any>, actorId: string): Promise<void> {
    await ensurePricingAgentTables(this.prisma);
    const id = requiredString(input.id, "product_id_required");
    const existing = await this.rows(`SELECT "id" FROM "PricingAgentProduct" WHERE "id" = ?`, id);
    const values = [requiredString(input.name, "product_name_required"), requiredString(input.category, "product_category_required"), JSON.stringify(input.stripeProductIDs ?? []), JSON.stringify(input.stripePriceIDs ?? []), requiredString(input.billingType, "billing_type_required"), integer(input.publicPriceMinor), String(input.currency ?? "USD").toUpperCase(), integer(input.targetMarginBasisPoints ?? 7000), JSON.stringify(input.includedAllowances ?? {}), JSON.stringify(input.metadata ?? {}), id];
    if (existing[0]) await this.prisma.$executeRawUnsafe(`UPDATE "PricingAgentProduct" SET "name"=?, "category"=?, "stripeProductIdsJson"=?, "stripePriceIdsJson"=?, "billingType"=?, "publicPriceMinor"=?, "currency"=?, "targetMarginBasisPoints"=?, "includedAllowancesJson"=?, "metadataJson"=?, "updatedAt"=CURRENT_TIMESTAMP WHERE "id"=?`, ...values);
    else await this.prisma.$executeRawUnsafe(`INSERT INTO "PricingAgentProduct" ("name", "category", "stripeProductIdsJson", "stripePriceIdsJson", "billingType", "publicPriceMinor", "currency", "targetMarginBasisPoints", "includedAllowancesJson", "metadataJson", "id") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, ...values);
    await this.audit(actorId, "admin", existing[0] ? "pricing.product.updated" : "pricing.product.created", "PricingAgentProduct", id, { input });
  }

  async addCostInput(input: Record<string, any>, actorId: string): Promise<string> {
    await ensurePricingAgentTables(this.prisma);
    const id = crypto.randomUUID();
    const effectiveAt = new Date(requiredString(input.effectiveAt, "effective_at_required"));
    if (!Number.isFinite(effectiveAt.getTime())) throw new Error("invalid_effective_at");
    await this.prisma.$executeRawUnsafe(
      `INSERT INTO "PricingAgentCostInput" ("id", "key", "valueDecimal", "unit", "currency", "provider", "effectiveAt", "source", "lastUpdatedAt", "updatedBy", "confidence", "metadataJson") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id, requiredString(input.key, "cost_key_required"), requiredDecimal(input.value, "cost_value_required"), requiredString(input.unit, "cost_unit_required"), String(input.currency ?? "USD").toUpperCase(), requiredString(input.provider, "provider_required"), effectiveAt.toISOString(), requiredString(input.source, "source_required"), new Date().toISOString(), actorId, String(input.confidence ?? "MEDIUM").toUpperCase(), JSON.stringify(input.metadata ?? {}),
    );
    await this.audit(actorId, "admin", "pricing.cost_input.version_created", "PricingAgentCostInput", id, { key: input.key, effectiveAt });
    return id;
  }

  async decideRecommendation(id: string, state: RecommendationState, notes: string | null, actorId: string): Promise<void> {
    if (!ALLOWED_STATES.has(state)) throw new Error("invalid_recommendation_state");
    if (state === "IMPLEMENTED") throw new Error("pricing_implementation_not_supported");
    const decided = ["APPROVED", "REJECTED", "DEFERRED"].includes(state);
    await this.prisma.$executeRawUnsafe(`UPDATE "PricingAgentRecommendation" SET "status"=?, "ownerDecision"=?, "ownerNotes"=?, "ownerDecidedAt"=?, "updatedAt"=CURRENT_TIMESTAMP WHERE "id"=?`, state, decided ? state : null, notes, decided ? new Date().toISOString() : null, id);
    await this.audit(actorId, "admin", "pricing.recommendation.decision_recorded", "PricingAgentRecommendation", id, { state, notes });
  }

  private async productRegistry(): Promise<ProductRegistryRow[]> {
    return this.rows(`SELECT * FROM "PricingAgentProduct" WHERE "active" = true ORDER BY "name"`) as Promise<ProductRegistryRow[]>;
  }

  private async activeCostInputs(at: Date): Promise<Record<string, number>> {
    const rows = await this.rows(`SELECT * FROM "PricingAgentCostInput" WHERE "effectiveAt" <= ? ORDER BY "key", "effectiveAt" DESC`, at.toISOString());
    const values: Record<string, number> = {};
    for (const row of rows) if (values[String(row.key)] == null) values[String(row.key)] = Number(row.valueDecimal);
    return values;
  }

  private async saveResult(runId: string, result: Record<string, any>): Promise<void> {
    await this.prisma.$executeRawUnsafe(
      `INSERT INTO "PricingAgentProductResult" ("id", "runId", "productId", "stripeProductId", "stripePriceId", "grossRevenueMinor", "netRevenueMinor", "stripeFeesMinor", "refundsMinor", "disputesMinor", "discountsMinor", "estimatedDirectCostMinor", "contributionProfitMinor", "contributionMarginBasisPoints", "activeCustomers", "newCustomers", "cancelledCustomers", "churnRateBasisPoints", "averageRevenuePerUserMinor", "averageCostPerUserMinor", "scenario", "risk", "metricsJson") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      crypto.randomUUID(), runId, result.productId, result.stripeProductId, result.stripePriceId, result.grossRevenueMinor, result.netRevenueMinor, result.stripeFeesMinor, result.refundsMinor, result.disputesMinor, result.discountsMinor, result.estimatedDirectCostMinor, result.contributionProfitMinor, result.contributionMarginBasisPoints, result.activeCustomers, result.newCustomers, result.cancelledCustomers, result.churnRateBasisPoints, result.averageRevenuePerUserMinor, result.averageCostPerUserMinor, result.scenario, result.risk, JSON.stringify(result.metrics),
    );
  }

  private async generateRecommendations(runId: string, results: Array<Record<string, any>>, incomplete: boolean): Promise<Array<Record<string, any>>> {
    const byProduct = new Map<string, Array<Record<string, any>>>();
    for (const result of results) byProduct.set(result.productId, [...(byProduct.get(result.productId) ?? []), result]);
    const recommendations: Array<Record<string, any>> = [];
    for (const [productId, productResults] of byProduct) {
      const expected = productResults.find((r) => r.scenario === "EXPECTED");
      const heavy = productResults.find((r) => r.scenario === "HEAVY");
      if (!expected || !heavy) continue;
      const target = Number(expected.metrics.targetMarginBasisPoints ?? 7000);
      const margin = expected.contributionMarginBasisPoints;
      const heavyMargin = heavy.contributionMarginBasisPoints;
      const critical = margin != null && margin < warningThreshold(expected.metrics.category, "critical");
      const belowTarget = margin != null && (margin < target || (heavyMargin != null && heavyMargin < warningThreshold(expected.metrics.category, "warning")));
      const recommendationType = belowTarget ? (heavyMargin != null && heavyMargin < 0 ? "INTRODUCE_OVERAGE_OR_REDUCE_ALLOWANCE" : "REVIEW_PRICE_OR_PACKAGING") : "KEEP_CURRENT_PRICE";
      const status = incomplete ? "DRAFT" : "READY_FOR_REVIEW";
      const explanation = incomplete
        ? "Cost or product mapping data is incomplete. Configure the missing inputs before relying on this recommendation."
        : belowTarget
          ? `Expected or heavy-use margin is below the configured safety threshold. Review OneWay economics before approving any price or allowance change.`
          : "Expected and heavy-use economics meet the configured thresholds; no pricing action is recommended.";
      const row = { id: crypto.randomUUID(), runId, productId, severity: critical ? "CRITICAL" : belowTarget ? "WARNING" : "INFO", recommendationType, currentValue: { publicPriceMinor: expected.metrics.publicPriceMinor, expectedMarginBasisPoints: margin, heavyMarginBasisPoints: heavyMargin }, proposedValue: belowTarget ? { action: "OWNER_REVIEW_REQUIRED", automaticChange: false } : { action: "NO_CHANGE" }, explanation, projectedMarginBasisPoints: null, confidence: incomplete ? "LOW" : "MEDIUM", status, evidence: { expected, heavy, dataSourceVersion: DATA_SOURCE_VERSION, costModelVersion: COST_MODEL_VERSION } };
      await this.prisma.$executeRawUnsafe(`INSERT INTO "PricingAgentRecommendation" ("id", "runId", "productId", "severity", "recommendationType", "currentValueJson", "proposedValueJson", "explanation", "projectedMarginBasisPoints", "confidence", "status", "evidenceJson") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, row.id, runId, productId, row.severity, recommendationType, JSON.stringify(row.currentValue), JSON.stringify(row.proposedValue), explanation, null, row.confidence, status, JSON.stringify(row.evidence));
      recommendations.push(row);
    }
    return recommendations;
  }

  private async alert(runId: string | null, severity: string, code: string, message: string, details: Record<string, any>): Promise<void> {
    await this.prisma.$executeRawUnsafe(`INSERT INTO "PricingAgentAlert" ("id", "runId", "severity", "code", "message", "detailsJson") VALUES (?, ?, ?, ?, ?, ?)`, crypto.randomUUID(), runId, severity, code, message, JSON.stringify(details));
  }

  private async audit(actorId: string | null, actorType: string, action: string, resourceType: string, resourceId: string | null, details: Record<string, any>): Promise<void> {
    await this.prisma.$executeRawUnsafe(`INSERT INTO "PricingAgentAuditLog" ("id", "actorId", "actorType", "action", "resourceType", "resourceId", "detailsJson") VALUES (?, ?, ?, ?, ?, ?, ?)`, crypto.randomUUID(), actorId, actorType, action, resourceType, resourceId, JSON.stringify(details));
  }

  private rows(query: string, ...values: any[]): Promise<any[]> { return this.prisma.$queryRawUnsafe<any[]>(query, ...values); }
}

export function previousCompletedCalendarMonth(now: Date): ReportingPeriod {
  const local = phoenixParts(now);
  const end = phoenixLocalToUtc(local.year, local.month, 1, 0, 0, 0);
  const previous = local.month === 1 ? { year: local.year - 1, month: 12 } : { year: local.year, month: local.month - 1 };
  return { start: phoenixLocalToUtc(previous.year, previous.month, 1, 0, 0, 0), end };
}

async function collectStripeSnapshot(stripe: any, period: ReportingPeriod): Promise<Record<string, any[]>> {
  const created = { gte: Math.floor(period.start.getTime() / 1000), lt: Math.floor(period.end.getTime() / 1000) };
  const [balanceTransactions, charges, invoices, subscriptions, products, prices, refunds, disputes, paymentIntents, checkoutSessions, applicationFees, transfers, payouts] = await Promise.all([
    listAll(stripe.balanceTransactions, { created, limit: 100 }), listAll(stripe.charges, { created, limit: 100 }),
    listAll(stripe.invoices, { created, limit: 100, expand: ["data.lines.data.price.product"] }),
    listAll(stripe.subscriptions, { status: "all", limit: 100, expand: ["data.items.data.price.product"] }),
    listAll(stripe.products, { active: true, limit: 100 }), listAll(stripe.prices, { active: true, limit: 100, expand: ["data.product"] }),
    listAll(stripe.refunds, { created, limit: 100 }), listAll(stripe.disputes, { created, limit: 100 }),
    listAll(stripe.paymentIntents, { created, limit: 100 }), listAll(stripe.checkout?.sessions, { created, limit: 100 }),
    listAll(stripe.applicationFees, { created, limit: 100 }), listAll(stripe.transfers, { created, limit: 100 }), listAll(stripe.payouts, { created, limit: 100 }),
  ]);
  return { balanceTransactions, charges, invoices, subscriptions, products, prices, refunds, disputes, paymentIntents, checkoutSessions, applicationFees, transfers, payouts };
}

async function listAll(resource: any, params: Record<string, any>): Promise<any[]> {
  if (!resource?.list) return [];
  const rows: any[] = [];
  let startingAfter: string | undefined;
  for (let page = 0; page < 100; page += 1) {
    const response = await resource.list({ ...params, ...(startingAfter ? { starting_after: startingAfter } : {}) });
    const data = Array.isArray(response?.data) ? response.data : [];
    rows.push(...data);
    if (!response?.has_more || !data.length) break;
    startingAfter = String(data[data.length - 1].id);
  }
  return rows;
}

function buildAccumulators(registry: ProductRegistryRow[], snapshot: Record<string, any[]>, period: ReportingPeriod): { accumulators: Map<string, ProductAccumulator>; missingMappings: string[] } {
  const byProductId = new Map<string, ProductRegistryRow>();
  const byPriceId = new Map<string, ProductRegistryRow>();
  for (const product of registry) {
    byProductId.set(product.id, product);
    for (const id of json(product.stripeProductIdsJson, [])) byProductId.set(String(id), product);
    for (const id of json(product.stripePriceIdsJson, [])) byPriceId.set(String(id), product);
  }
  for (const product of snapshot.products) {
    const internal = product.metadata?.oneway_product_id;
    if (internal && byProductId.has(internal)) byProductId.set(String(product.id), byProductId.get(internal)!);
  }
  for (const price of snapshot.prices) {
    const productId = typeof price.product === "string" ? price.product : price.product?.id;
    const internal = price.metadata?.oneway_product_id ?? price.product?.metadata?.oneway_product_id;
    const mapped = byProductId.get(String(internal ?? productId ?? ""));
    if (mapped) byPriceId.set(String(price.id), mapped);
  }
  const accumulators = new Map<string, ProductAccumulator>();
  const missingMappings: string[] = [];
  const get = (priceId: string | null, stripeProductId: string | null, metadata: any): ProductAccumulator | null => {
    const internal = metadata?.oneway_product_id;
    const product = (internal ? byProductId.get(String(internal)) : null) ?? (priceId ? byPriceId.get(priceId) : null) ?? (stripeProductId ? byProductId.get(stripeProductId) : null);
    if (!product) return null;
    if (!priceId) {
      const existing = [...accumulators.values()].find((candidate) => candidate.product.id === product.id);
      if (existing) return existing;
    }
    const key = `${product.id}:${priceId ?? "none"}`;
    if (!accumulators.has(key)) accumulators.set(key, { product, stripeProductId, stripePriceId: priceId, gross: 0, fees: 0, refunds: 0, disputes: 0, discounts: 0, activeCustomers: new Set(), newCustomers: new Set(), cancelledCustomers: new Set(), failedPayments: 0, paidPayments: 0, trialsStarted: 0, trialsConverted: 0 });
    return accumulators.get(key)!;
  };

  const chargeMap = new Map(snapshot.charges.map((c) => [String(c.id), c]));
  const balanceBySource = new Map(snapshot.balanceTransactions.map((b) => [String(b.source ?? ""), b]));
  for (const invoice of snapshot.invoices) {
    const lines = invoice.lines?.data ?? [];
    for (const line of lines) {
      const price = line.price ?? line.pricing?.price_details?.price;
      const priceId = typeof price === "string" ? price : price?.id ?? null;
      const stripeProductId = typeof price?.product === "string" ? price.product : price?.product?.id ?? null;
      const acc = get(priceId, stripeProductId, { ...(price?.product?.metadata ?? {}), ...(price?.metadata ?? {}), ...(line.metadata ?? {}) });
      if (!acc) { missingMappings.push(String(line.id ?? invoice.id)); continue; }
      const amount = Number(line.amount ?? 0);
      acc.gross += amount;
      acc.discounts += Number(line.discount_amounts?.reduce((sum: number, d: any) => sum + Number(d.amount ?? 0), 0) ?? 0);
      if (invoice.customer) acc.activeCustomers.add(String(invoice.customer));
      if (invoice.status === "paid") acc.paidPayments += 1;
      if (["open", "uncollectible"].includes(String(invoice.status))) acc.failedPayments += 1;
      const chargeId = typeof invoice.charge === "string" ? invoice.charge : invoice.charge?.id;
      const balance = balanceBySource.get(String(chargeId ?? ""));
      if (balance) acc.fees += Math.max(0, Number(balance.fee ?? 0));
    }
  }
  for (const charge of snapshot.charges) {
    if (charge.invoice || charge.metadata?.sellerId || charge.transfer_data || charge.destination) continue;
    const acc = get(null, null, charge.metadata);
    if (!acc) { if (charge.amount_captured > 0) missingMappings.push(String(charge.id)); continue; }
    acc.gross += Number(charge.amount_captured ?? charge.amount ?? 0);
    if (charge.customer) acc.activeCustomers.add(String(charge.customer));
    const balance = balanceBySource.get(String(charge.id));
    if (balance) acc.fees += Math.max(0, Number(balance.fee ?? 0));
  }
  for (const refund of snapshot.refunds) {
    const charge = chargeMap.get(String(refund.charge ?? ""));
    const acc = get(null, null, { ...(charge?.metadata ?? {}), ...(refund.metadata ?? {}) });
    if (acc) acc.refunds += Number(refund.amount ?? 0);
  }
  for (const dispute of snapshot.disputes) {
    const charge = chargeMap.get(String(dispute.charge ?? ""));
    const acc = get(null, null, { ...(charge?.metadata ?? {}), ...(dispute.metadata ?? {}) });
    if (acc) acc.disputes += Number(dispute.amount ?? 0);
  }
  for (const subscription of snapshot.subscriptions) {
    for (const item of subscription.items?.data ?? []) {
      const priceId = String(item.price?.id ?? "") || null;
      const stripeProductId = typeof item.price?.product === "string" ? item.price.product : item.price?.product?.id ?? null;
      const acc = get(priceId, stripeProductId, { ...(item.price?.product?.metadata ?? {}), ...(item.price?.metadata ?? {}), ...(subscription.metadata ?? {}) });
      if (!acc) continue;
      const customer = String(subscription.customer ?? "");
      if (["active", "trialing", "past_due"].includes(String(subscription.status)) && customer) acc.activeCustomers.add(customer);
      const created = Number(subscription.created ?? 0) * 1000;
      if (created >= period.start.getTime() && created < period.end.getTime() && customer) acc.newCustomers.add(customer);
      const canceled = Number(subscription.canceled_at ?? 0) * 1000;
      if (canceled >= period.start.getTime() && canceled < period.end.getTime() && customer) acc.cancelledCustomers.add(customer);
      if (subscription.trial_start) acc.trialsStarted += 1;
      if (subscription.trial_end && String(subscription.status) === "active") acc.trialsConverted += 1;
    }
  }
  return { accumulators, missingMappings: [...new Set(missingMappings)] };
}

function calculateResult(acc: ProductAccumulator, scenario: PricingScenario, costs: Record<string, number>): Record<string, any> {
  const netRevenue = acc.gross - acc.fees - acc.refunds - acc.disputes - acc.discounts;
  const users = acc.activeCustomers.size;
  const variablePerUser = categoryCostPerUser(acc.product.category, costs);
  const reserveRate = (costs.fraud_reserve_percentage ?? 0) + (costs.chargeback_reserve_percentage ?? 0) + (costs.support_reserve_percentage ?? 0);
  const directCost = Math.round(users * variablePerUser * SCENARIO_MULTIPLIER[scenario] * 100 + Math.max(0, netRevenue) * reserveRate / 100);
  const profit = netRevenue - directCost;
  const margin = netRevenue > 0 ? Math.round(profit / netRevenue * 10_000) : null;
  const churn = users + acc.cancelledCustomers.size > 0 ? Math.round(acc.cancelledCustomers.size / (users + acc.cancelledCustomers.size) * 10_000) : null;
  const risk = margin == null ? "INCOMPLETE" : margin < warningThreshold(acc.product.category, "critical") ? "CRITICAL" : margin < warningThreshold(acc.product.category, "warning") ? "WARNING" : "HEALTHY";
  return { productId: acc.product.id, stripeProductId: acc.stripeProductId, stripePriceId: acc.stripePriceId, grossRevenueMinor: acc.gross, netRevenueMinor: netRevenue, stripeFeesMinor: acc.fees, refundsMinor: acc.refunds, disputesMinor: acc.disputes, discountsMinor: acc.discounts, estimatedDirectCostMinor: directCost, contributionProfitMinor: profit, contributionMarginBasisPoints: margin, activeCustomers: users, newCustomers: acc.newCustomers.size, cancelledCustomers: acc.cancelledCustomers.size, churnRateBasisPoints: churn, averageRevenuePerUserMinor: users ? Math.round(netRevenue / users) : null, averageCostPerUserMinor: users ? Math.round(directCost / users) : null, scenario, risk, metrics: { category: acc.product.category, publicPriceMinor: acc.product.publicPriceMinor, targetMarginBasisPoints: acc.product.targetMarginBasisPoints, failedPaymentRateBasisPoints: acc.paidPayments + acc.failedPayments ? Math.round(acc.failedPayments / (acc.paidPayments + acc.failedPayments) * 10_000) : null, trialConversionBasisPoints: acc.trialsStarted ? Math.round(acc.trialsConverted / acc.trialsStarted * 10_000) : null } };
}

function categoryCostPerUser(category: string, costs: Record<string, number>): number {
  const common = (costs.database_cost_per_active_user ?? 0) + (costs.support_cost_per_active_user ?? 0) + (costs.hosting_reserve_per_active_user ?? 0) + (costs.compliance_reserve_per_active_user ?? 0);
  const normalized = category.toLowerCase();
  if (normalized.includes("phone") || normalized.includes("sms")) return common + (costs.phone_number_monthly_cost ?? 0) + (costs.expected_pstn_cost_per_user ?? 0) + (costs.expected_sms_cost_per_user ?? 0);
  if (normalized.includes("site")) return common + (costs.site_hosting_cost_per_active_user ?? 0) + (costs.bandwidth_cost_per_active_user ?? 0);
  if (normalized.includes("ai")) return common + (costs.ai_cost_per_active_user ?? 0);
  if (normalized.includes("storage") || normalized.includes("cloud")) return common + (costs.cloud_storage_cost_per_active_user ?? 0) + (costs.bandwidth_cost_per_active_user ?? 0);
  if (normalized.includes("marketplace") || normalized.includes("shop")) return common + (costs.marketplace_support_cost_per_active_user ?? 0);
  return common + (costs.video_cost_per_active_user ?? 0) + (costs.email_cost_per_active_user ?? 0);
}

function requiredCostKeys(): string[] { return ["database_cost_per_active_user", "support_cost_per_active_user", "hosting_reserve_per_active_user", "compliance_reserve_per_active_user", "fraud_reserve_percentage", "chargeback_reserve_percentage"]; }
function warningThreshold(category: string, level: "warning" | "critical"): number { const telecom = /phone|sms|telecom/i.test(category); return telecom ? (level === "warning" ? 4000 : 2000) : (level === "warning" ? 6000 : 4000); }

function buildSummary(results: Array<Record<string, any>>, snapshot: Record<string, any[]>, missingMappings: string[], missingCosts: string[], recommendations: Array<Record<string, any>>): Record<string, any> {
  const expected = results.filter((r) => r.scenario === "EXPECTED");
  const total = (key: string) => expected.reduce((sum, row) => sum + Number(row[key] ?? 0), 0);
  const net = total("netRevenueMinor");
  const profit = total("contributionProfitMinor");
  const gmv = snapshot.charges.filter((c) => c.metadata?.sellerId || c.transfer_data || c.destination).reduce((sum, c) => sum + Number(c.amount_captured ?? c.amount ?? 0), 0);
  const marketplaceRevenue = snapshot.applicationFees.reduce((sum, fee) => sum + Number(fee.amount ?? 0) - Number(fee.amount_refunded ?? 0), 0);
  const sellerPayoutTotal = snapshot.transfers.reduce((sum, t) => sum + Number(t.amount ?? 0), 0);
  return { monthlyGrossRevenueMinor: total("grossRevenueMinor"), netRevenueMinor: net, stripeFeesMinor: total("stripeFeesMinor"), refundsMinor: total("refundsMinor"), disputesMinor: total("disputesMinor"), activeSubscribers: expected.reduce((sum, row) => sum + Number(row.activeCustomers ?? 0), 0), contributionProfitMinor: profit, expectedGrossMarginBasisPoints: net > 0 ? Math.round(profit / net * 10_000) : null, productsBelowTarget: expected.filter((r) => r.risk !== "HEALTHY").length, criticalAlerts: recommendations.filter((r) => r.severity === "CRITICAL").length, marketplace: { gmvMinor: gmv, oneWayMarketplaceRevenueMinor: marketplaceRevenue, sellerPayoutTotalMinor: sellerPayoutTotal, takeRateBasisPoints: gmv > 0 ? Math.round(marketplaceRevenue / gmv * 10_000) : null, note: "Marketplace GMV and seller funds are excluded from OneWay subscription revenue." }, missingMappings, missingCosts };
}

function buildReport(period: ReportingPeriod, summary: Record<string, any>, results: Array<Record<string, any>>, recommendations: Array<Record<string, any>>, completeness: string): Record<string, any> {
  const month = new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric", timeZone: "America/Phoenix" }).format(period.start);
  return { title: `OneWay Pricing Review — ${month}`, reportingPeriod: { start: period.start.toISOString(), endExclusive: period.end.toISOString() }, generatedAt: new Date().toISOString(), currency: "USD", costModelVersion: COST_MODEL_VERSION, dataSourceVersion: DATA_SOURCE_VERSION, authority: PricingAgentAuthority.recommendationOnly, completeness, dataCompletenessWarning: completeness === "COMPLETE" ? null : "Missing mappings or cost inputs reduce recommendation confidence. No pricing action should be taken from incomplete data.", sections: { executiveSummary: summary, revenueOverview: { grossRevenueMinor: summary.monthlyGrossRevenueMinor, netRevenueMinor: summary.netRevenueMinor, contributionProfitMinor: summary.contributionProfitMinor }, productLevelMargins: results, shopsAndMarketplace: summary.marketplace, recommendationsRequiringApproval: recommendations.filter((r) => r.recommendationType !== "KEEP_CURRENT_PRICE"), noActionRecommendations: recommendations.filter((r) => r.recommendationType === "KEEP_CURRENT_PRICE"), missingData: { productMappings: summary.missingMappings, costInputs: summary.missingCosts }, nextReviewDate: nextMonthlyRunDate(period.end).toISOString() } };
}

function renderReportHtml(report: Record<string, any>): string {
  const s = report.sections.executiveSummary;
  const money = (n: number) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(n ?? 0) / 100);
  const rows = report.sections.productLevelMargins.filter((r: any) => r.scenario === "EXPECTED").map((r: any) => `<tr><td>${escapeHtml(r.productId)}</td><td>${money(r.netRevenueMinor)}</td><td>${money(r.estimatedDirectCostMinor)}</td><td>${r.contributionMarginBasisPoints == null ? "Incomplete" : `${(r.contributionMarginBasisPoints / 100).toFixed(1)}%`}</td><td>${escapeHtml(r.risk)}</td></tr>`).join("");
  return `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(report.title)}</title><style>body{font:15px system-ui;max-width:1050px;margin:40px auto;padding:0 24px;color:#15131a}h1{font-size:34px}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.card{padding:16px;border:1px solid #ddd;border-radius:12px}table{width:100%;border-collapse:collapse;margin-top:24px}th,td{text-align:left;padding:10px;border-bottom:1px solid #ddd}.warning{padding:14px;background:#fff6da;border-radius:10px}@media(max-width:700px){.cards{grid-template-columns:1fr 1fr}}</style></head><body><h1>${escapeHtml(report.title)}</h1>${report.dataCompletenessWarning ? `<p class="warning">${escapeHtml(report.dataCompletenessWarning)}</p>` : ""}<div class="cards"><div class="card"><b>Gross revenue</b><br>${money(s.monthlyGrossRevenueMinor)}</div><div class="card"><b>Net revenue</b><br>${money(s.netRevenueMinor)}</div><div class="card"><b>Contribution profit</b><br>${money(s.contributionProfitMinor)}</div><div class="card"><b>Products below target</b><br>${s.productsBelowTarget}</div></div><h2>Plan performance</h2><table><thead><tr><th>Product</th><th>Net revenue</th><th>Direct cost</th><th>Expected margin</th><th>Risk</th></tr></thead><tbody>${rows}</tbody></table><p>Recommendation-only report. Approval never changes Stripe, subscriptions, refunds, entitlements, or public prices.</p></body></html>`;
}

function parseResult(row: any): any { return { ...row, metrics: json(row.metricsJson, {}) }; }
function parseRecommendation(row: any): any { return { ...row, currentValue: json(row.currentValueJson, {}), proposedValue: json(row.proposedValueJson, {}), evidence: json(row.evidenceJson, {}) }; }
function json(value: any, fallback: any): any { try { return typeof value === "string" ? JSON.parse(value) : value ?? fallback; } catch { return fallback; } }
function requiredString(value: any, error: string): string { if (typeof value !== "string" || !value.trim()) throw new Error(error); return value.trim(); }
function requiredDecimal(value: any, error: string): string { const n = Number(value); if (!Number.isFinite(n) || n < 0) throw new Error(error); return String(n); }
function integer(value: any): number { const n = Number(value); if (!Number.isInteger(n) || n < 0) throw new Error("non_negative_integer_required"); return n; }
function stripeEnvironment(): string { return (process.env.STRIPE_ENV ?? (process.env.NODE_ENV === "production" ? "production" : "sandbox")).trim().toLowerCase(); }
function validateCompletedPeriod(period: ReportingPeriod, now: Date): void { if (!(period.start < period.end) || period.end > now) throw new Error("reporting_period_must_be_completed"); }
function phoenixParts(date: Date): { year: number; month: number } { const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Phoenix", year: "numeric", month: "numeric" }).formatToParts(date); return { year: Number(parts.find((p) => p.type === "year")?.value), month: Number(parts.find((p) => p.type === "month")?.value) }; }
function phoenixLocalToUtc(year: number, month: number, day: number, hour: number, minute: number, second: number): Date { return new Date(Date.UTC(year, month - 1, day, hour + 7, minute, second)); }
function nextMonthlyRunDate(periodEnd: Date): Date { const p = phoenixParts(new Date(periodEnd.getTime() + 24 * 60 * 60 * 1000)); const month = p.month === 12 ? 1 : p.month + 1; const year = p.month === 12 ? p.year + 1 : p.year; return phoenixLocalToUtc(year, month, 5, 9, 0, 0); }
function escapeHtml(value: any): string { return String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;"); }
function safeErrorMessage(error: unknown): string { const message = error instanceof Error ? error.message : "pricing_agent_failed"; return message.replace(/\b(?:sk|rk|mk)_(?:test|live)?_[A-Za-z0-9_*]+\b/g, "[REDACTED_STRIPE_KEY]"); }
