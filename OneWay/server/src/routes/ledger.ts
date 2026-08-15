import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { FinancialComplianceService } from "../services/ledger/FinancialComplianceService";
import { isLedgerBalanceError, LedgerBalanceService } from "../services/ledger/LedgerBalanceService";
import { runLedgerReconciliationOnce } from "../services/ledger/LedgerReconciliationJob";

const accountIdSchema = z.string().trim().min(1).max(128).regex(/^[A-Za-z0-9_:\-.]+$/);
const amountSchema = z.object({
  amountCents: z.number().int().positive(),
  currency: z.string().trim().length(3).optional(),
  externalId: z.string().trim().max(160).optional(),
  unitTxId: z.string().trim().max(160).optional(),
  stripeId: z.string().trim().max(160).optional(),
  metadata: z.record(z.unknown()).optional(),
});
const withdrawalSchema = amountSchema.extend({ allowNegativeBalance: z.boolean().optional() });
const reversalSchema = z.object({
  transactionId: z.string().trim().min(1).max(160),
  externalId: z.string().trim().max(160).optional(),
  metadata: z.record(z.unknown()).optional(),
});

export function ledgerRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  const ledger = new LedgerBalanceService(prisma);
  const compliance = new FinancialComplianceService(ledger);

  router.use(authMiddleware);
  router.use(requireLedgerAdmin);

  router.get("/account/:id/balance", async (req, res) => {
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    try {
      res.json({ ok: true, balance: await ledger.getAvailableBalance(accountId) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/rebuild", async (req, res) => {
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    try {
      res.json({ ok: true, balance: await ledger.rebuildBalance(accountId) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/reconcile", async (req, res) => {
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    try {
      res.json({ ok: true, reconciliation: await ledger.reconcileAccountBalance(accountId) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.get("/account/:id/history", async (req, res) => {
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    const limit = Number.parseInt(String(req.query.limit ?? "50"), 10);
    try {
      res.json({ ok: true, history: await ledger.getLedgerHistory(accountId, limit) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/deposit", async (req, res) => {
    if (!oneWayBankMoneyMovementEnabled(res)) return;
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    const parsed = amountSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    try {
      res.status(201).json({ ok: true, posting: await compliance.processDeposit({ accountId, ...parsed.data }) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/withdrawal", async (req, res) => {
    if (!oneWayBankMoneyMovementEnabled(res)) return;
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    const parsed = withdrawalSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    try {
      res.status(201).json({ ok: true, posting: await compliance.processWithdrawal({ accountId, ...parsed.data }) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/storefront-payment", async (req, res) => {
    if (!oneWayBankMoneyMovementEnabled(res)) return;
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    const parsed = amountSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    try {
      res.status(201).json({ ok: true, posting: await compliance.processStorefrontPayment({ accountId, ...parsed.data }) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/dispute/provisional-credit", async (req, res) => {
    if (!oneWayBankMoneyMovementEnabled(res)) return;
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    const parsed = amountSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    try {
      res.status(201).json({ ok: true, posting: await compliance.processDisputeProvisionalCredit({ accountId, ...parsed.data }) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/account/:id/reversal", async (req, res) => {
    if (!oneWayBankMoneyMovementEnabled(res)) return;
    const accountId = parseAccountId(req.params.id, res);
    if (!accountId) return;
    const parsed = reversalSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    try {
      res.status(201).json({ ok: true, posting: await compliance.processReversal({ accountId, ...parsed.data }) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  router.post("/reconcile", async (req, res) => {
    const limit = Number.parseInt(String(req.body?.limit ?? "1000"), 10);
    try {
      res.json({ ok: true, result: await runLedgerReconciliationOnce(prisma, limit) });
    } catch (error) {
      sendLedgerError(res, error);
    }
  });

  return router;
}

function requireLedgerAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  const configuredToken = process.env.ONEWAY_LEDGER_ADMIN_TOKEN?.trim();
  const header = req.headers["x-oneway-admin-token"];
  const headerToken = Array.isArray(header) ? header[0] : header;
  const adminTokenMatches = Boolean(configuredToken && headerToken === configuredToken);
  const auth = req as AuthenticatedRequest;
  const devAdmin = process.env.NODE_ENV !== "production" && auth.authMode === "dev";

  if (adminTokenMatches || devAdmin) {
    next();
    return;
  }

  res.status(403).json({ ok: false, error: "ledger_admin_required" });
}

function oneWayBankMoneyMovementEnabled(res: express.Response): boolean {
  if (envFlag("ONEWAY_BANK_ENABLED", false)) return true;
  res.status(503).json({
    ok: false,
    error: "oneway_bank_disabled",
    message: "OneWay Bank is not active yet. Storefront payments currently use Stripe/payment links.",
  });
  return false;
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function parseAccountId(value: string, res: express.Response): string | null {
  const parsed = accountIdSchema.safeParse(value);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: "invalid_account_id" });
    return null;
  }
  return parsed.data;
}

function sendLedgerError(res: express.Response, error: unknown): void {
  if (isLedgerBalanceError(error)) {
    res.status(error.statusCode).json({ ok: false, error: error.code, message: error.message });
    return;
  }
  res.status(500).json({ ok: false, error: "ledger_unavailable", message: "Ledger operation failed." });
}
