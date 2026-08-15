import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import express from "express";
import ExcelJS from "exceljs";
import PDFDocument from "pdfkit";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { PricingAgent, type RecommendationState } from "../services/pricing/PricingAgent";

export function adminPricingRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  const agent = new PricingAgent(prisma);
  router.use(authMiddleware, requirePricingAdmin);

  router.get("/dashboard", async (_req, res, next) => {
    try { res.json({ ok: true, ...(await agent.dashboard()) }); } catch (error) { next(error); }
  });

  router.get("/dashboard/ui", async (_req, res, next) => {
    try { res.type("html").send(renderDashboard(await agent.dashboard())); } catch (error) { next(error); }
  });

  router.post("/runs", async (req, res, next) => {
    try {
      const auth = req as unknown as AuthenticatedRequest;
      const period = parsePeriod(req.body?.reportingPeriodStart, req.body?.reportingPeriodEnd);
      const run = await agent.run({ actorId: auth.userId, period, force: req.body?.force === true });
      res.status(201).json({ ok: true, run });
    } catch (error) { next(error); }
  });

  router.get("/runs/:runId", async (req, res, next) => {
    try { res.json({ ok: true, run: await agent.getRun(req.params.runId) }); } catch (error) { next(error); }
  });

  router.put("/products/:productId", async (req, res, next) => {
    try {
      const auth = req as unknown as AuthenticatedRequest;
      await agent.upsertProduct({ ...req.body, id: req.params.productId }, auth.userId);
      res.json({ ok: true });
    } catch (error) { next(error); }
  });

  router.post("/cost-inputs", async (req, res, next) => {
    try {
      const auth = req as unknown as AuthenticatedRequest;
      const id = await agent.addCostInput(req.body ?? {}, auth.userId);
      res.status(201).json({ ok: true, id });
    } catch (error) { next(error); }
  });

  router.patch("/recommendations/:recommendationId", async (req, res, next) => {
    try {
      const auth = req as unknown as AuthenticatedRequest;
      const state = String(req.body?.status ?? "") as RecommendationState;
      await agent.decideRecommendation(req.params.recommendationId, state, typeof req.body?.notes === "string" ? req.body.notes : null, auth.userId);
      res.json({ ok: true, automaticPricingChange: false });
    } catch (error) { next(error); }
  });

  router.get("/runs/:runId/export/:format", async (req, res, next) => {
    try {
      const run = await agent.getRun(req.params.runId);
      const format = req.params.format.toLowerCase();
      const base = `oneway-pricing-${String(run.reportingPeriodStart).slice(0, 7)}`;
      if (format === "json") {
        res.setHeader("Content-Disposition", `attachment; filename="${base}.json"`);
        return res.json(exportEnvelope(run));
      }
      if (format === "csv") {
        res.setHeader("Content-Disposition", `attachment; filename="${base}.csv"`);
        return res.type("text/csv").send(resultsCsv(run));
      }
      if (format === "html") {
        res.setHeader("Content-Disposition", `attachment; filename="${base}.html"`);
        return res.type("html").send(run.report?.reportHtml ?? "<p>Report unavailable.</p>");
      }
      if (format === "xlsx") {
        const workbook = await resultsWorkbook(run);
        res.setHeader("Content-Disposition", `attachment; filename="${base}.xlsx"`);
        res.type("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        return res.send(Buffer.from(await workbook.xlsx.writeBuffer()));
      }
      if (format === "pdf") {
        res.setHeader("Content-Disposition", `attachment; filename="${base}.pdf"`);
        return res.type("application/pdf").send(await reportPdf(run));
      }
      return res.status(400).json({ ok: false, error: "unsupported_export_format", supported: ["json", "csv", "xlsx", "pdf", "html"] });
    } catch (error) { next(error); }
  });

  return router;
}

export function requirePricingAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  const configured = process.env.ONEWAY_PRICING_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_PAYMENT_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_LEDGER_ADMIN_TOKEN?.trim()
    || process.env.ONEWAY_AUDIT_ADMIN_TOKEN?.trim();
  const provided = String(req.headers["x-oneway-admin-token"] ?? "");
  const auth = req as AuthenticatedRequest;
  const valid = Boolean(configured && safeEqual(configured, provided));
  if (valid || (process.env.NODE_ENV !== "production" && auth.authMode === "dev")) return next();
  res.status(403).json({ ok: false, error: "pricing_admin_required" });
}

function safeEqual(expected: string, provided: string): boolean {
  const a = Buffer.from(expected); const b = Buffer.from(provided);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function parsePeriod(start: unknown, end: unknown): { start: Date; end: Date } | undefined {
  if (start == null && end == null) return undefined;
  if (typeof start !== "string" || typeof end !== "string") throw new Error("both_reporting_period_bounds_required");
  const period = { start: new Date(start), end: new Date(end) };
  if (!Number.isFinite(period.start.getTime()) || !Number.isFinite(period.end.getTime())) throw new Error("invalid_reporting_period");
  return period;
}

function exportEnvelope(run: Record<string, any>): Record<string, any> {
  return { reportingPeriod: { start: run.reportingPeriodStart, endExclusive: run.reportingPeriodEnd }, costModelVersion: run.costModelVersion, generationDate: run.completedAt, currency: run.currency, dataCompletenessWarning: run.completeness === "COMPLETE" ? null : "Results contain missing mappings or cost inputs.", approvalStatus: run.report?.approvalStatus ?? "PENDING", run };
}

export function resultsCsv(run: Record<string, any>): string {
  const header = ["reporting_period_start", "reporting_period_end_exclusive", "cost_model_version", "currency", "completeness", "approval_status", "product_id", "stripe_product_id", "stripe_price_id", "scenario", "gross_revenue_minor", "net_revenue_minor", "stripe_fees_minor", "refunds_minor", "disputes_minor", "direct_cost_minor", "contribution_profit_minor", "contribution_margin_basis_points", "active_customers", "churn_rate_basis_points", "risk"];
  const rows = (run.results ?? []).map((r: any) => [run.reportingPeriodStart, run.reportingPeriodEnd, run.costModelVersion, run.currency, run.completeness, run.report?.approvalStatus ?? "PENDING", r.productId, r.stripeProductId, r.stripePriceId, r.scenario, r.grossRevenueMinor, r.netRevenueMinor, r.stripeFeesMinor, r.refundsMinor, r.disputesMinor, r.estimatedDirectCostMinor, r.contributionProfitMinor, r.contributionMarginBasisPoints, r.activeCustomers, r.churnRateBasisPoints, r.risk].map(csvCell).join(","));
  return [header.join(","), ...rows].join("\n") + "\n";
}

export async function resultsWorkbook(run: Record<string, any>): Promise<ExcelJS.Workbook> {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "OneWay Pricing Agent";
  workbook.created = new Date(run.completedAt ?? Date.now());
  const summary = workbook.addWorksheet("Executive Summary");
  summary.columns = [{ header: "Metric", key: "metric", width: 34 }, { header: "Value", key: "value", width: 28 }];
  const envelope = exportEnvelope(run);
  const fields: Array<[string, any]> = [
    ["Reporting period start", envelope.reportingPeriod.start], ["Reporting period end (exclusive)", envelope.reportingPeriod.endExclusive],
    ["Cost model version", envelope.costModelVersion], ["Currency", envelope.currency], ["Completeness", run.completeness],
    ["Data completeness warning", envelope.dataCompletenessWarning ?? "None"], ["Approval status", envelope.approvalStatus],
    ["Gross revenue (minor)", run.summary?.monthlyGrossRevenueMinor], ["Net revenue (minor)", run.summary?.netRevenueMinor],
    ["Contribution profit (minor)", run.summary?.contributionProfitMinor], ["Expected margin (basis points)", run.summary?.expectedGrossMarginBasisPoints],
  ];
  fields.forEach(([metric, value]) => summary.addRow({ metric, value }));
  const plans = workbook.addWorksheet("Plan Performance");
  plans.columns = ["Product", "Stripe Product", "Stripe Price", "Scenario", "Gross Revenue", "Net Revenue", "Stripe Fees", "Refunds", "Disputes", "Direct Cost", "Contribution Profit", "Margin bps", "Active Customers", "Churn bps", "Risk"].map((header) => ({ header, key: header, width: 20 }));
  for (const r of run.results ?? []) plans.addRow([r.productId, r.stripeProductId, r.stripePriceId, r.scenario, r.grossRevenueMinor, r.netRevenueMinor, r.stripeFeesMinor, r.refundsMinor, r.disputesMinor, r.estimatedDirectCostMinor, r.contributionProfitMinor, r.contributionMarginBasisPoints, r.activeCustomers, r.churnRateBasisPoints, r.risk]);
  const recommendations = workbook.addWorksheet("Recommendations");
  recommendations.columns = ["Product", "Severity", "Type", "Status", "Confidence", "Explanation", "Current Value", "Proposed Value"].map((header) => ({ header, key: header, width: header === "Explanation" ? 70 : 24 }));
  for (const r of run.recommendations ?? []) recommendations.addRow([r.productId, r.severity, r.recommendationType, r.status, r.confidence, r.explanation, JSON.stringify(r.currentValue), JSON.stringify(r.proposedValue)]);
  for (const sheet of workbook.worksheets) { sheet.views = [{ state: "frozen", ySplit: 1 }]; sheet.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } }; sheet.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF5B21B6" } }; sheet.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: sheet.columnCount } }; }
  return workbook;
}

export function reportPdf(run: Record<string, any>): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const document = new PDFDocument({ margin: 48, size: "LETTER", info: { Title: run.report?.title ?? "OneWay Pricing Review", Author: "OneWay Pricing Agent" } });
    const chunks: Buffer[] = [];
    document.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    document.on("error", reject);
    document.on("end", () => resolve(Buffer.concat(chunks)));
    document.fontSize(24).fillColor("#4c1d95").text(run.report?.title ?? "OneWay Pricing Review");
    document.moveDown(0.4).fontSize(10).fillColor("#555555").text(`Reporting period: ${run.reportingPeriodStart} to ${run.reportingPeriodEnd} (exclusive)`);
    document.text(`Cost model: ${run.costModelVersion} · Currency: ${run.currency} · Approval: ${run.report?.approvalStatus ?? "PENDING"}`);
    if (run.completeness !== "COMPLETE") document.moveDown().fontSize(11).fillColor("#8a4b00").text("Data completeness warning: missing mappings or cost inputs reduce recommendation confidence. No pricing action should be taken from incomplete data.");
    const summary = run.summary ?? {};
    document.moveDown().fontSize(17).fillColor("#111111").text("Executive Summary");
    document.fontSize(11).text(`Gross revenue: ${formatMoney(summary.monthlyGrossRevenueMinor)}\nNet revenue: ${formatMoney(summary.netRevenueMinor)}\nStripe fees: ${formatMoney(summary.stripeFeesMinor)}\nRefunds: ${formatMoney(summary.refundsMinor)}\nDisputes: ${formatMoney(summary.disputesMinor)}\nContribution profit: ${formatMoney(summary.contributionProfitMinor)}\nExpected margin: ${summary.expectedGrossMarginBasisPoints == null ? "Incomplete" : `${(summary.expectedGrossMarginBasisPoints / 100).toFixed(1)}%`}`);
    document.moveDown().fontSize(17).text("Product-Level Margins");
    for (const r of (run.results ?? []).filter((row: any) => row.scenario === "EXPECTED")) document.fontSize(10).text(`${r.productId}: net ${formatMoney(r.netRevenueMinor)}, cost ${formatMoney(r.estimatedDirectCostMinor)}, margin ${r.contributionMarginBasisPoints == null ? "incomplete" : `${(r.contributionMarginBasisPoints / 100).toFixed(1)}%`}, risk ${r.risk}`);
    document.moveDown().fontSize(17).text("Recommendations Requiring Approval");
    const recommendations = (run.recommendations ?? []).filter((r: any) => r.recommendationType !== "KEEP_CURRENT_PRICE");
    if (!recommendations.length) document.fontSize(10).text("No pricing changes recommended.");
    for (const r of recommendations) document.fontSize(10).text(`${r.severity} · ${r.productId} · ${r.recommendationType}\n${r.explanation}`).moveDown(0.5);
    document.moveDown().fontSize(9).fillColor("#555555").text("Recommendation-only report. Approval does not change Stripe prices, subscriptions, refunds, entitlements, App Store pricing, or public website pricing.");
    document.end();
  });
}

function formatMoney(value: any): string { return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value ?? 0) / 100); }

function csvCell(value: any): string { const text = value == null ? "" : String(value); return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text; }

function renderDashboard(data: Record<string, any>): string {
  const run = data.latestRun;
  const summary = run?.summary ?? {};
  const money = (value: any) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value ?? 0) / 100);
  const cards = [
    ["Monthly Gross Revenue", money(summary.monthlyGrossRevenueMinor)], ["Net Revenue", money(summary.netRevenueMinor)],
    ["Stripe Fees", money(summary.stripeFeesMinor)], ["Refunds", money(summary.refundsMinor)],
    ["Disputes", money(summary.disputesMinor)], ["Active Subscribers", summary.activeSubscribers ?? "—"],
    ["Contribution Profit", money(summary.contributionProfitMinor)], ["Expected Gross Margin", summary.expectedGrossMarginBasisPoints == null ? "Incomplete" : `${(summary.expectedGrossMarginBasisPoints / 100).toFixed(1)}%`],
    ["Products Below Target", summary.productsBelowTarget ?? "—"], ["Critical Alerts", summary.criticalAlerts ?? "—"],
  ].map(([label, value]) => `<article><small>${esc(label)}</small><strong>${esc(value)}</strong></article>`).join("");
  const results = (run?.results ?? []).filter((r: any) => r.scenario === "EXPECTED").map((r: any) => {
    const refundRate = r.grossRevenueMinor > 0 ? Math.round(r.refundsMinor / r.grossRevenueMinor * 10_000) : 0;
    const recommendation = (run?.recommendations ?? []).find((item: any) => item.productId === r.productId);
    const riskScore = { CRITICAL: 4, WARNING: 3, INCOMPLETE: 2, HEALTHY: 1 }[String(r.risk)] ?? 0;
    return `<tr data-margin="${r.contributionMarginBasisPoints ?? -999999}" data-revenue="${r.grossRevenueMinor}" data-churn="${r.churnRateBasisPoints ?? 0}" data-refund="${refundRate}" data-cost="${r.estimatedDirectCostMinor}" data-risk="${riskScore}"><td>${esc(r.productId)}</td><td>${money(r.metrics?.publicPriceMinor)}</td><td>${r.activeCustomers}</td><td>${money(r.grossRevenueMinor)}</td><td>${money(r.netRevenueMinor)}</td><td>${money(r.estimatedDirectCostMinor)}</td><td>${r.contributionMarginBasisPoints == null ? "Incomplete" : `${(r.contributionMarginBasisPoints / 100).toFixed(1)}%`}</td><td>${(refundRate / 100).toFixed(1)}%</td><td>${r.churnRateBasisPoints == null ? "—" : `${(r.churnRateBasisPoints / 100).toFixed(1)}%`}</td><td><span class="risk ${String(r.risk).toLowerCase()}">${esc(r.risk)}</span></td><td>${esc(recommendation?.recommendationType ?? "—")}</td></tr>`;
  }).join("");
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OneWay Pricing Agent</title><style>:root{color-scheme:dark}body{margin:0;background:#08070c;color:#f8f5ff;font:15px system-ui}.wrap{max-width:1280px;margin:auto;padding:34px}header,.section-head{display:flex;justify-content:space-between;align-items:end;gap:20px}h1{font-size:36px;margin:0}.authority{color:#c8a8ff}.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin:28px 0}.cards article{background:#15121d;border:1px solid #302840;border-radius:16px;padding:18px}.cards small{color:#aaa2b5;display:block}.cards strong{font-size:22px;display:block;margin-top:9px}section{background:#100e16;border:1px solid #2b2536;border-radius:20px;padding:22px;overflow:auto}select{background:#201a2b;color:#fff;border:1px solid #4b3d60;border-radius:9px;padding:9px 12px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:12px;border-bottom:1px solid #292332;white-space:nowrap}.risk{padding:5px 9px;border-radius:999px}.healthy{background:#123c2a}.warning{background:#4a3511}.critical{background:#501d27}.incomplete{background:#34303c}@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}.wrap{padding:20px}}</style></head><body><div class="wrap"><header><div><p class="authority">Internal financial operations · recommendation only</p><h1>OneWay Pricing Agent</h1></div><p>${esc(run ? `${String(run.reportingPeriodStart).slice(0,10)} – ${String(run.reportingPeriodEnd).slice(0,10)}` : "No completed run")}</p></header><div class="cards">${cards}</div><section><div class="section-head"><h2>Plan Performance</h2><label>Sort by <select id="sort"><option value="margin">Lowest margin</option><option value="revenue">Highest revenue</option><option value="churn">Highest churn</option><option value="refund">Highest refund rate</option><option value="cost">Highest infrastructure cost</option><option value="risk">Highest risk</option></select></label></div><table><thead><tr><th>Product</th><th>Public Price</th><th>Active</th><th>Gross Revenue</th><th>Net Revenue</th><th>Direct Cost</th><th>Expected Margin</th><th>Refund Rate</th><th>Churn</th><th>Risk</th><th>Recommendation</th></tr></thead><tbody id="plans">${results || '<tr><td colspan="11">Run the agent after configuring products and cost inputs.</td></tr>'}</tbody></table></section></div><script>(()=>{const select=document.getElementById('sort'),body=document.getElementById('plans');if(!select||!body)return;const sort=()=>{const key=select.value,ascending=key==='margin';[...body.querySelectorAll('tr[data-margin]')].sort((a,b)=>{const av=Number(a.dataset[key]),bv=Number(b.dataset[key]);return ascending?av-bv:bv-av}).forEach(row=>body.appendChild(row))};select.addEventListener('change',sort);sort()})()</script></body></html>`;
}

function esc(value: any): string { return String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;"); }
