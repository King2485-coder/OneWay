import type { PrismaClient } from "@prisma/client";
import crypto from "node:crypto";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import { LedgerBalanceService } from "../services/ledger/LedgerBalanceService";
import { ensurePaymentTables } from "../services/payments/PaymentTables";
import { oneWayWalletPaymentService } from "../services/wallet/OneWayWalletPaymentService";

const USD = "USD";
const regulatedWalletEnabled = envFlag("ONEWAY_BANK_ENABLED", false);

const amountSchema = z.object({
  amountMinor: z.number().int().positive(),
  currency: z.string().trim().length(3).default(USD),
  note: z.string().trim().max(280).optional(),
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
});

const requestSchema = amountSchema.extend({
  recipient: z.string().trim().min(2).max(160),
  reason: z.string().trim().max(280).optional(),
  expiresAt: z.string().datetime().optional(),
});

export function walletRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  const ledger = new LedgerBalanceService(prisma);

  router.use(authMiddleware);
  router.use(async (_req, _res, next) => {
    try {
      await ensurePaymentTables(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    try {
      const state = await buildWalletState(prisma, ledger, userId);
      logger.info({ userId, currency: USD }, "WALLET_OPENED");
      res.json({ ok: true, wallet: state });
    } catch (error) {
      logger.error({ err: error, userId }, "WALLET_BALANCE_FETCH_FAILED");
      res.status(500).json({ ok: false, error: "wallet_unavailable", message: "Wallet could not be loaded." });
    }
  });

  router.get("/balances", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    try {
      const state = await buildWalletState(prisma, ledger, userId);
      logger.info({ userId, currency: USD }, "WALLET_BALANCE_FETCH_SUCCEEDED");
      res.json({ ok: true, balances: state.balances, capabilities: state.capabilities });
    } catch (error) {
      logger.error({ err: error, userId }, "WALLET_BALANCE_FETCH_FAILED");
      res.status(500).json({ ok: false, error: "wallet_balance_unavailable", message: "Wallet balances could not be loaded." });
    }
  });

  router.get("/transactions", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const limit = clampNumber(Number(req.query.limit ?? 50), 1, 100);
    try {
      const history = await walletHistory(ledger, userId, limit);
      const shopPurchases = await buyerShopTransactions(prisma, userId, limit);
      const sellerEarnings = await sellerEarningTransactions(prisma, userId, limit);
      res.json({
        ok: true,
        transactions: [...history, ...shopPurchases, ...sellerEarnings]
          .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))
          .slice(0, limit),
      });
    } catch (error) {
      logger.error({ err: error, userId }, "WALLET_TRANSACTIONS_FETCH_FAILED");
      res.status(500).json({ ok: false, error: "wallet_history_unavailable", message: "Wallet history could not be loaded." });
    }
  });

  router.get("/transactions/:transactionId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const transactionId = String(req.params.transactionId ?? "");
    const state = await buildWalletState(prisma, ledger, userId);
    const match = state.recentTransactions.find((transaction) => transaction.id === transactionId);
    if (!match) {
      res.status(404).json({ ok: false, error: "transaction_not_found" });
      return;
    }
    res.json({ ok: true, transaction: match });
  });

  router.get("/payment-methods", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const status = await oneWayWalletPaymentService.getStatus();
    const customers = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "OneWayBillingCustomer" WHERE "userId" = ? LIMIT 1`, userId);
    res.json({
      ok: true,
      paymentMethods: [],
      stripeCustomer: customers[0] ? {
        stripeCustomerId: customers[0].stripeCustomerId,
        defaultPaymentMethodId: customers[0].defaultPaymentMethodId,
        status: customers[0].status,
      } : null,
      applePay: { supported: true, configuredThroughStripe: Boolean(process.env.STRIPE_SECRET_KEY?.trim()) },
      cards: [],
      provider: status,
      message: "Cards and Apple Pay are managed by Stripe. OneWay never stores card numbers.",
    });
  });

  router.get("/bank-accounts", (_req, res) => {
    res.json({ ok: true, bankAccounts: [], message: "Bank linking requires a provider-hosted flow and is not enabled yet." });
  });

  router.get("/seller-earnings", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await sellerEarningTransactions(prisma, userId, 100);
    res.json({ ok: true, sellerEarnings: rows, summary: await sellerEarningsSummary(prisma, userId) });
  });

  router.get("/payouts", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const accounts = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "SellerPaymentAccount" WHERE "sellerUserId" = ? ORDER BY "updatedAt" DESC`, userId);
    const ids = accounts.map((account) => account.stripeAccountId).filter(Boolean);
    const rows = ids.length
      ? await prisma.$queryRawUnsafe<any[]>(
        `SELECT * FROM "SellerPayout" WHERE "connectedAccountId" IN (${ids.map(() => "?").join(",")}) ORDER BY "createdAt" DESC LIMIT 100`,
        ...ids,
      )
      : [];
    res.json({
      ok: true,
      payouts: rows.map((row) => ({
        id: row.id,
        stripePayoutId: row.stripePayoutId,
        amountMinor: row.amountMinor,
        currency: row.currency,
        status: row.status,
        bank: "Stripe Express payout account",
        estimatedArrival: row.arrivalDate,
        createdAt: row.createdAt,
      })),
      lastPayout: rows[0] ?? null,
      nextEstimatedPayout: null,
    });
  });

  router.get("/automatic-payments", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "AutopayAuthorization" WHERE "userId" = ? ORDER BY "createdAt" DESC`, userId);
    res.json({
      ok: true,
      automaticPayments: rows.map((row) => ({
        id: row.id,
        scope: row.scope,
        status: row.status,
        termsVersion: row.termsVersion,
        consentedAt: row.consentedAt,
        revokedAt: row.revokedAt,
        lastUsedAt: row.lastUsedAt,
      })),
      defaultState: "OFF",
    });
  });

  router.get("/invoices", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "Invoice" WHERE "userId" = ? ORDER BY "createdAt" DESC LIMIT 100`, userId);
    res.json({ ok: true, invoices: rows.map(redactPaymentRecord) });
  });

  router.get("/receipts/:orderId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const order = await prisma.order.findFirst({
      where: { id: req.params.orderId, OR: [{ userId }, { sellerId: userId }] },
    });
    if (!order) return res.status(404).json({ ok: false, error: "receipt_not_found" });
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "ShopPayment" WHERE "orderId" = ? ORDER BY "createdAt" DESC LIMIT 1`, order.id);
    res.json({
      ok: true,
      receipt: {
        orderId: order.id,
        shopId: order.storeId,
        sellerId: order.sellerId,
        buyerId: order.userId,
        grossAmountMinor: order.sellerGrossAmountMinor,
        stripeFeeMinor: order.paymentProcessingFeeMinor,
        oneWayFeeMinor: order.oneWayPlatformFeeMinor,
        netEarningsMinor: order.sellerNetAmountMinor,
        customerTotalMinor: order.customerTotalMinor,
        currency: order.currency,
        status: order.paymentStatus,
        stripePaymentIntentId: rows[0]?.stripePaymentIntentId ?? order.paymentIntentId,
        orderDate: order.createdAt.toISOString(),
      },
    });
  });

  router.get("/limits", (_req, res) => {
    res.json({
      ok: true,
      limits: {
        currency: USD,
        send: regulatedLimit("Send money"),
        deposit: regulatedLimit("Add money"),
        withdraw: regulatedLimit("Withdraw"),
        paymentRequest: { status: "available_in_test", dailyCount: 10 },
        sellerPayout: regulatedLimit("Seller payout"),
      },
    });
  });

  router.get("/security", (_req, res) => {
    res.json({
      ok: true,
      security: {
        walletOpenBiometricRequired: true,
        sendBiometricRequired: true,
        withdrawalBiometricRequired: true,
        transferNotifications: true,
        spendingAlerts: true,
        withdrawalAlerts: true,
      },
    });
  });

  router.patch("/security", (_req, res) => {
    logger.info({}, "WALLET_SECURITY_CHANGED");
    res.json({ ok: true, message: "Wallet security preferences saved locally until the security backend is connected." });
  });

  router.get("/verification", (_req, res) => {
    res.json({
      ok: true,
      verification: {
        state: regulatedWalletEnabled ? "information_required" : "not_started",
        message: regulatedWalletEnabled
          ? "Start provider-hosted identity verification before money movement."
          : "Verification is required before regulated Wallet balances, deposits, withdrawals, or P2P transfers are enabled.",
      },
    });
  });

  router.post("/send", (req, res) => {
    const parsed = amountSchema.extend({ recipient: z.string().trim().min(2).max(160) }).safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    logger.info({ idempotencyKey: safeIdempotency(parsed.data.idempotencyKey), amountMinor: parsed.data.amountMinor, currency: parsed.data.currency }, "WALLET_SEND_STARTED");
    sendRegulatedUnavailable(res, "send_money_disabled", "Send Money requires verified custodial Wallet rails and recipient resolution.");
  });

  router.post("/requests", (req, res) => {
    const parsed = requestSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ ok: false, error: "validation_failed", issues: parsed.error.issues });
      return;
    }
    const requestId = `wreq_${crypto.randomUUID()}`;
    logger.info({ requestId, amountMinor: parsed.data.amountMinor, currency: parsed.data.currency }, "WALLET_REQUEST_CREATED");
    res.status(201).json({
      ok: true,
      request: {
        id: requestId,
        status: "pending",
        recipient: parsed.data.recipient,
        amountMinor: parsed.data.amountMinor,
        currency: parsed.data.currency,
        reason: parsed.data.reason ?? null,
        createdAt: new Date().toISOString(),
      },
    });
  });

  router.get("/requests", (_req, res) => {
    res.json({ ok: true, requests: [] });
  });

  router.post("/requests/:requestId/pay", (_req, res) => {
    sendRegulatedUnavailable(res, "pay_request_disabled", "Paying requests requires verified Wallet rails.");
  });

  router.post("/requests/:requestId/decline", (req, res) => {
    res.json({ ok: true, requestId: req.params.requestId, status: "declined" });
  });

  router.post("/requests/:requestId/cancel", (req, res) => {
    res.json({ ok: true, requestId: req.params.requestId, status: "canceled" });
  });

  router.post("/deposits/session", (_req, res) => {
    sendRegulatedUnavailable(res, "deposit_disabled", "Add Money requires a provider-hosted deposit flow.");
  });

  router.post("/withdrawals", (_req, res) => {
    sendRegulatedUnavailable(res, "withdrawal_disabled", "Withdraw requires verified available funds and payout rails.");
  });

  router.post("/payment-methods/session", (_req, res) => {
    sendRegulatedUnavailable(res, "payment_method_session_disabled", "Payment method setup requires a provider-hosted session.");
  });

  router.delete("/payment-methods/:paymentMethodId", (req, res) => {
    res.json({ ok: true, paymentMethodId: req.params.paymentMethodId, status: "not_found_or_removed" });
  });

  router.patch("/payment-methods/:paymentMethodId/default", (req, res) => {
    res.json({ ok: true, paymentMethodId: req.params.paymentMethodId, status: "not_configured" });
  });

  router.post("/bank-accounts/session", (_req, res) => {
    sendRegulatedUnavailable(res, "bank_link_disabled", "Bank linking must use an approved provider-hosted flow.");
  });

  router.post("/payouts", (_req, res) => {
    sendRegulatedUnavailable(res, "seller_payout_disabled", "Seller payouts require verified payout rails.");
  });

  router.post("/freeze", (_req, res) => {
    res.json({ ok: true, status: "freeze_request_recorded", message: "Wallet freeze requests require support review in this environment." });
  });

  router.post("/unfreeze-request", (_req, res) => {
    res.json({ ok: true, status: "unfreeze_request_recorded", message: "Wallet unfreeze request recorded for review." });
  });

  router.post("/verification/session", (_req, res) => {
    sendRegulatedUnavailable(res, "verification_provider_disabled", "Identity verification will open a provider-hosted session when configured.");
  });

  return router;
}

async function buildWalletState(prisma: PrismaClient, ledger: LedgerBalanceService, userId: string) {
  const availableAccountId = walletAccountId(userId, "available");
  const pendingAccountId = walletAccountId(userId, "pending");
  const sellerAccountId = walletAccountId(userId, "seller");
  const payoutAccountId = walletAccountId(userId, "payout");

  await Promise.all([
    ledger.createAccountIfMissing({ accountId: availableAccountId, userId, currency: USD }),
    ledger.createAccountIfMissing({ accountId: pendingAccountId, userId, currency: USD }),
    ledger.createAccountIfMissing({ accountId: sellerAccountId, userId, currency: USD }),
    ledger.createAccountIfMissing({ accountId: payoutAccountId, userId, currency: USD }),
  ]);

  const [available, pending, seller, payout, provider, history, shopPurchases, sellerEarnings] = await Promise.all([
    ledger.getAvailableBalance(availableAccountId),
    ledger.getAvailableBalance(pendingAccountId),
    ledger.getAvailableBalance(sellerAccountId),
    ledger.getAvailableBalance(payoutAccountId),
    oneWayWalletPaymentService.getStatus(),
    walletHistory(ledger, userId, 20),
    buyerShopTransactions(prisma, userId, 12),
    sellerEarningTransactions(prisma, userId, 12),
  ]);

  const balances = {
    currency: USD,
    availableBalanceMinor: available.availableBalance,
    pendingBalanceMinor: pending.pendingBalance + pending.availableBalance,
    sellerEarningsMinor: seller.availableBalance + sellerEarnings.reduce((sum, row) => sum + Math.max(row.amountMinor, 0), 0),
    pendingSellerPayoutsMinor: payout.pendingBalance + payout.availableBalance,
    totalOneWayFundsMinor:
      available.availableBalance
      + pending.pendingBalance
      + pending.availableBalance
      + seller.availableBalance
      + payout.pendingBalance
      + payout.availableBalance,
    negativeBalanceMinor: Math.min(available.availableBalance, 0),
  };

  return {
    userId,
    mode: regulatedWalletEnabled ? "provider_required" : "phase_1_non_custodial",
    provider,
    capabilities: walletCapabilities(provider),
    balances,
    recentTransactions: [...history, ...shopPurchases, ...sellerEarnings]
      .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))
      .slice(0, 20),
    notices: [
      regulatedWalletEnabled
        ? "Wallet money movement is feature-flagged until provider verification is complete."
        : "Regulated stored Wallet balances, deposits, withdrawals, and peer transfers are disabled until approved payment rails, KYC, AML, and money-transmission coverage are active.",
      "All money amounts are stored as integer minor units. Pending, seller, payout, and available balances are separated.",
    ],
  };
}

async function walletHistory(ledger: LedgerBalanceService, userId: string, limit: number): Promise<WalletTransactionDTO[]> {
  const accounts = [
    walletAccountId(userId, "available"),
    walletAccountId(userId, "pending"),
    walletAccountId(userId, "seller"),
    walletAccountId(userId, "payout"),
  ];
  const histories = await Promise.all(accounts.map(async (accountId) => {
    try {
      return await ledger.getLedgerHistory(accountId, limit);
    } catch {
      return null;
    }
  }));
  return histories.flatMap((history) => (history?.transactions ?? []).map((transaction) => ({
    id: transaction.id,
    type: transaction.type,
    title: titleForLedgerType(transaction.type),
    counterparty: transaction.metadata?.counterpartyName as string | undefined ?? "OneWay Ledger",
    amountMinor: transaction.amountCents,
    currency: transaction.currency,
    direction: inferDirection(transaction.entries[0]?.direction),
    status: transaction.status,
    createdAt: transaction.createdAt,
    completedAt: transaction.postedAt,
    reference: transaction.externalId ?? transaction.id,
    paymentMethod: transaction.metadata?.paymentMethod as string | undefined ?? null,
    fees: [],
    receiptAvailable: transaction.status === "posted",
    category: transaction.type,
  })));
}

async function buyerShopTransactions(prisma: PrismaClient, userId: string, limit: number): Promise<WalletTransactionDTO[]> {
  const rows = await prisma.order.findMany({
    where: { userId },
    orderBy: { createdAt: "desc" },
    take: limit,
  });
  return rows.map((order) => ({
    id: `order:${order.id}`,
    type: "shop_purchase",
    title: "Shop Purchase",
    counterparty: order.storeId ?? "OneWay Shop",
    amountMinor: order.customerTotalMinor || Math.round(Number(order.total) * 100),
    currency: order.currency,
    direction: "outgoing",
    status: order.paymentStatus,
    createdAt: order.createdAt.toISOString(),
    completedAt: ["paid", "captured", "refunded"].includes(order.paymentStatus) ? order.updatedAt.toISOString() : null,
    reference: order.id,
    paymentMethod: order.paymentStatus === "paid" ? "OneWay Wallet" : "External payment",
    fees: [
      { label: "Tax", amountMinor: order.taxAmountMinor },
      { label: "Shipping", amountMinor: order.shippingAmountMinor },
    ].filter((fee) => fee.amountMinor > 0),
    receiptAvailable: ["paid", "captured", "refunded"].includes(order.paymentStatus),
    category: "shop_purchase",
  }));
}

async function sellerEarningTransactions(prisma: PrismaClient, userId: string, limit: number): Promise<WalletTransactionDTO[]> {
  const rows = await prisma.order.findMany({
    where: { sellerId: userId, paymentStatus: { in: ["paid", "captured"] } },
    orderBy: { createdAt: "desc" },
    take: limit,
  });
  return rows.map((order) => ({
    id: `seller:${order.id}`,
    type: "seller_earning",
    title: "Seller Earnings",
    counterparty: order.storeId ?? "OneWay Shops",
    amountMinor: order.sellerNetAmountMinor,
    currency: order.currency,
    direction: "incoming",
    status: order.payoutStatus,
    createdAt: order.createdAt.toISOString(),
    completedAt: order.updatedAt.toISOString(),
    reference: order.id,
    paymentMethod: "Shop order settlement",
    fees: [
      { label: "OneWay Sale Fee", amountMinor: order.oneWayPlatformFeeMinor },
      { label: "Processing Fee", amountMinor: order.paymentProcessingFeeMinor },
    ].filter((fee) => fee.amountMinor > 0),
    receiptAvailable: true,
    category: "seller_earning",
  }));
}

async function sellerEarningsSummary(prisma: PrismaClient, userId: string): Promise<Record<string, number | string>> {
  const rows = await prisma.$queryRawUnsafe<any[]>(
    `SELECT
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "sellerGrossAmountMinor" ELSE 0 END), 0) AS gross,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "paymentProcessingFeeMinor" ELSE 0 END), 0) AS stripeFee,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "oneWayPlatformFeeMinor" ELSE 0 END), 0) AS oneWayFee,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') THEN "sellerNetAmountMinor" ELSE 0 END), 0) AS net,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') AND "payoutStatus" IN ('pending','in_transit') THEN "sellerNetAmountMinor" ELSE 0 END), 0) AS pending,
       COALESCE(SUM(CASE WHEN "paymentStatus" IN ('paid','captured') AND "payoutStatus" = 'paid' THEN "sellerNetAmountMinor" ELSE 0 END), 0) AS paid
     FROM "Order" WHERE "sellerId" = ?`,
    userId,
  );
  const row = rows[0] ?? {};
  return {
    currency: USD,
    grossAmountMinor: Number(row.gross ?? 0),
    stripeFeeMinor: Number(row.stripeFee ?? 0),
    oneWayFeeMinor: Number(row.oneWayFee ?? 0),
    netEarningsMinor: Number(row.net ?? 0),
    pendingBalanceMinor: Number(row.pending ?? 0),
    availableBalanceMinor: Math.max(0, Number(row.net ?? 0) - Number(row.pending ?? 0)),
    completedPayoutsMinor: Number(row.paid ?? 0),
  };
}

function redactPaymentRecord(row: any): Record<string, any> {
  const copy: Record<string, any> = {};
  for (const [key, value] of Object.entries(row)) {
    if (/secret|clientSecret|payloadJson|card|bank/i.test(key)) continue;
    copy[key] = value instanceof Date ? value.toISOString() : value;
  }
  return copy;
}

function walletAccountId(userId: string, kind: "available" | "pending" | "seller" | "payout"): string {
  return `wallet:${userId}:${kind}`;
}

function walletCapabilities(provider: Awaited<ReturnType<typeof oneWayWalletPaymentService.getStatus>>) {
  return {
    walletBalanceRead: true,
    transactionHistory: true,
    shopPurchases: true,
    sellerEarnings: true,
    paymentRequests: true,
    sendMoney: regulatedWalletEnabled && provider.available,
    addMoney: regulatedWalletEnabled && provider.available,
    withdrawMoney: regulatedWalletEnabled && provider.available,
    bankLinking: regulatedWalletEnabled && provider.available,
    paymentMethodLinking: regulatedWalletEnabled && provider.available,
    sellerPayouts: regulatedWalletEnabled && provider.available,
  };
}

function sendRegulatedUnavailable(res: express.Response, error: string, message: string): void {
  res.status(503).json({
    ok: false,
    error,
    message,
    regulatedFeature: true,
    requiredBeforeEnablement: ["payment provider", "KYC", "AML", "sanctions screening", "money-transmission/compliance coverage"],
  });
}

function regulatedLimit(label: string) {
  return {
    status: regulatedWalletEnabled ? "provider_authoritative" : "disabled",
    label,
    message: regulatedWalletEnabled ? "Limit is supplied by the Wallet provider." : "Disabled until Wallet provider and compliance architecture are active.",
  };
}

function inferDirection(direction?: string): "incoming" | "outgoing" | "neutral" {
  if (direction === "credit") return "incoming";
  if (direction === "debit") return "outgoing";
  return "neutral";
}

function titleForLedgerType(type: string): string {
  switch (type) {
    case "deposit": return "Deposit";
    case "withdrawal": return "Withdrawal";
    case "storefront_payment": return "Shop Payment";
    case "dispute_provisional_credit": return "Dispute Credit";
    case "reversal": return "Reversal";
    default: return "Wallet Transaction";
  }
}

function clampNumber(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.min(Math.max(Math.trunc(value), min), max);
}

function safeIdempotency(value?: string): string | null {
  if (!value) return null;
  return `${value.slice(0, 8)}…${value.slice(-4)}`;
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

interface WalletTransactionDTO {
  id: string;
  type: string;
  title: string;
  counterparty: string;
  amountMinor: number;
  currency: string;
  direction: "incoming" | "outgoing" | "neutral";
  status: string;
  createdAt: string;
  completedAt: string | null;
  reference: string;
  paymentMethod: string | null;
  fees: Array<{ label: string; amountMinor: number }>;
  receiptAvailable: boolean;
  category: string;
}
