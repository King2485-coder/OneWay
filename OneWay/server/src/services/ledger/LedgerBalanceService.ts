import crypto from "node:crypto";
import type { PrismaClient } from "@prisma/client";

import { logger } from "../../lib/logger";

type RawDb = Pick<PrismaClient, "$executeRawUnsafe" | "$queryRawUnsafe">;

type LedgerDirection = "credit" | "debit";
type LedgerBucket = "available" | "pending";

export type LedgerTransactionType =
  | "deposit"
  | "withdrawal"
  | "storefront_payment"
  | "dispute_provisional_credit"
  | "reversal"
  | "adjustment";

export interface LedgerBalanceProjection {
  accountId: string;
  availableBalance: number;
  pendingBalance: number;
  totalBalance: number;
  currency: string;
  entryCount: number;
  rebuiltAt: string;
}

export interface LedgerReconciliationResult {
  accountId: string;
  cachedBalance: number;
  cachedAvailableBalance: number;
  projectedBalance: number;
  projectedAvailableBalance: number;
  projectedPendingBalance: number;
  mismatchCents: number;
  action: "matched" | "auto_healed" | "escalated";
  severity: "none" | "low" | "high";
  reconciliationId: string;
}

export interface LedgerPostInput {
  accountId: string;
  amountCents: number;
  type: LedgerTransactionType;
  direction: LedgerDirection;
  balanceBucket?: LedgerBucket;
  currency?: string;
  description?: string;
  externalId?: string | null;
  unitTxId?: string | null;
  stripeId?: string | null;
  metadata?: Record<string, unknown>;
  counterpartyAccountId?: string;
  allowNegativeBalance?: boolean;
  reverseOfTransactionId?: string | null;
}

export interface LedgerPostResult {
  transactionId: string;
  accountId: string;
  amountCents: number;
  type: LedgerTransactionType;
  status: "posted" | "idempotent_replay";
  projection: LedgerBalanceProjection;
}

export interface LedgerHistoryResult {
  accountId: string;
  projection: LedgerBalanceProjection;
  transactions: Array<{
    id: string;
    type: string;
    status: string;
    amountCents: number;
    currency: string;
    externalId: string | null;
    unitTxId: string | null;
    stripeId: string | null;
    reverseOfTransactionId: string | null;
    metadata: Record<string, unknown> | null;
    createdAt: string;
    postedAt: string | null;
    entries: Array<{
      id: string;
      accountId: string;
      direction: string;
      amountCents: number;
      balanceBucket: string;
      status: string;
      createdAt: string;
    }>;
  }>;
}

export class LedgerBalanceError extends Error {
  constructor(
    public readonly code:
      | "ledger_account_not_found"
      | "invalid_amount"
      | "insufficient_funds"
      | "ledger_post_failed"
      | "ledger_transaction_not_found",
    message: string,
    public readonly statusCode = 400,
  ) {
    super(message);
    this.name = "LedgerBalanceError";
  }
}

interface AccountRow {
  id: string;
  user_id: string | null;
  balance: number;
  available_balance: number;
  pending_balance: number;
  currency: string;
  allow_negative_balance: number | boolean;
}

interface ProjectedRow {
  available_balance: number | bigint | null;
  pending_balance: number | bigint | null;
  entry_count: number | bigint | null;
}

interface TransactionRow {
  id: string;
  account_id: string;
  type: string;
  status: string;
  amount_cents: number;
  currency: string;
  external_id: string | null;
  unit_tx_id: string | null;
  stripe_id: string | null;
  reverse_of_transaction_id: string | null;
  metadata_json: string | null;
  created_at: string | Date;
  posted_at: string | Date | null;
}

interface EntryRow {
  id: string;
  transaction_id: string;
  account_id: string;
  direction: string;
  amount_cents: number;
  balance_bucket: string;
  status: string;
  created_at: string | Date;
}

let ledgerTablesReady = false;

export class LedgerBalanceService {
  constructor(private readonly prisma: PrismaClient) {}

  async getAvailableBalance(accountId: string): Promise<LedgerBalanceProjection> {
    await this.ensureLedgerTables();
    await this.requireAccount(accountId);
    return this.buildProjection(this.prisma, accountId);
  }

  async getPendingBalance(accountId: string): Promise<LedgerBalanceProjection> {
    await this.ensureLedgerTables();
    await this.requireAccount(accountId);
    return this.buildProjection(this.prisma, accountId);
  }

  async rebuildBalance(accountId: string): Promise<LedgerBalanceProjection> {
    await this.ensureLedgerTables();
    await this.requireAccount(accountId);
    return this.rebuildProjection(this.prisma, accountId);
  }

  async reconcileAccountBalance(accountId: string): Promise<LedgerReconciliationResult> {
    await this.ensureLedgerTables();
    const account = await this.requireAccount(accountId);
    const projection = await this.buildProjection(this.prisma, accountId);
    const cachedBalance = toNumber(account.balance);
    const cachedAvailableBalance = toNumber(account.available_balance);
    const balanceMismatch = Math.abs(cachedBalance - projection.totalBalance);
    const availableMismatch = Math.abs(cachedAvailableBalance - projection.availableBalance);
    const mismatchCents = Math.max(balanceMismatch, availableMismatch);
    const threshold = parseIntegerEnv("LEDGER_AUTO_HEAL_THRESHOLD_CENTS", 5);

    let action: LedgerReconciliationResult["action"] = "matched";
    let severity: LedgerReconciliationResult["severity"] = "none";
    let finalProjection = projection;

    if (mismatchCents > 0 && mismatchCents <= threshold) {
      finalProjection = await this.rebuildProjection(this.prisma, accountId);
      action = "auto_healed";
      severity = "low";
    } else if (mismatchCents > threshold) {
      action = "escalated";
      severity = "high";
    }

    const reconciliationId = crypto.randomUUID();
    await this.prisma.$executeRawUnsafe(
      `INSERT INTO ledger_reconciliations (
        id, account_id, cached_balance, cached_available_balance,
        projected_balance, projected_available_balance, projected_pending_balance,
        mismatch_cents, action, severity, details_json, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
      reconciliationId,
      accountId,
      cachedBalance,
      cachedAvailableBalance,
      projection.totalBalance,
      projection.availableBalance,
      projection.pendingBalance,
      mismatchCents,
      action,
      severity,
      JSON.stringify({ thresholdCents: threshold, rebuiltAt: finalProjection.rebuiltAt }),
    );

    if (action === "escalated") {
      logger.warn({ accountId, mismatchCents, cachedBalance, projectedBalance: projection.totalBalance }, "[ledger] balance mismatch escalated");
    }

    return {
      accountId,
      cachedBalance,
      cachedAvailableBalance,
      projectedBalance: projection.totalBalance,
      projectedAvailableBalance: projection.availableBalance,
      projectedPendingBalance: projection.pendingBalance,
      mismatchCents,
      action,
      severity,
      reconciliationId,
    };
  }

  async createAccountIfMissing(input: {
    accountId: string;
    userId?: string | null;
    currency?: string;
    allowNegativeBalance?: boolean;
  }): Promise<void> {
    await this.ensureLedgerTables();
    await this.createAccountIfMissingWithClient(this.prisma, input);
  }

  async postLedgerTransaction(input: LedgerPostInput): Promise<LedgerPostResult> {
    await this.ensureLedgerTables();
    const amountCents = Math.trunc(input.amountCents);
    if (!Number.isInteger(amountCents) || amountCents <= 0) {
      throw new LedgerBalanceError("invalid_amount", "Amount must be a positive number of cents.", 400);
    }

    const balanceBucket = input.balanceBucket ?? "available";
    const currency = normalizeCurrency(input.currency);
    const counterpartyAccountId = input.counterpartyAccountId ?? defaultCounterpartyAccount(input.type);

    await this.createAccountIfMissingWithClient(this.prisma, { accountId: input.accountId, currency });
    await this.createAccountIfMissingWithClient(this.prisma, {
      accountId: counterpartyAccountId,
      currency,
      allowNegativeBalance: true,
    });

    const existing = await this.findIdempotentTransaction(input);
    if (existing) {
      return {
        transactionId: existing.id,
        accountId: input.accountId,
        amountCents: toNumber(existing.amount_cents),
        type: existing.type as LedgerTransactionType,
        status: "idempotent_replay",
        projection: await this.rebuildProjection(this.prisma, input.accountId),
      };
    }

    const account = await this.requireAccount(input.accountId);
    if (input.direction === "debit" && balanceBucket === "available") {
      const projected = await this.buildProjection(this.prisma, input.accountId);
      const accountAllowsNegative = Boolean(account.allow_negative_balance);
      if (!input.allowNegativeBalance && !accountAllowsNegative && projected.availableBalance - amountCents < 0) {
        throw new LedgerBalanceError("insufficient_funds", "This account does not have enough available balance.", 409);
      }
    }

    const transactionId = crypto.randomUUID();
    const userEntryId = crypto.randomUUID();
    const counterpartyEntryId = crypto.randomUUID();
    const counterpartyDirection: LedgerDirection = input.direction === "credit" ? "debit" : "credit";
    const metadata = JSON.stringify({ ...(input.metadata ?? {}), description: input.description ?? undefined });

    try {
      const projection = await this.prisma.$transaction(async (tx) => {
        await tx.$executeRawUnsafe(
          `INSERT INTO ledger_transactions (
            id, account_id, type, status, amount_cents, currency,
            external_id, unit_tx_id, stripe_id, reverse_of_transaction_id,
            metadata_json, created_at, posted_at
          ) VALUES (?, ?, ?, 'posted', ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`,
          transactionId,
          input.accountId,
          input.type,
          amountCents,
          currency,
          nullable(input.externalId),
          nullable(input.unitTxId),
          nullable(input.stripeId),
          nullable(input.reverseOfTransactionId),
          metadata,
        );
        await tx.$executeRawUnsafe(
          `INSERT INTO ledger_entries (
            id, transaction_id, account_id, direction, amount_cents,
            balance_bucket, status, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, 'posted', CURRENT_TIMESTAMP)`,
          userEntryId,
          transactionId,
          input.accountId,
          input.direction,
          amountCents,
          balanceBucket,
        );
        await tx.$executeRawUnsafe(
          `INSERT INTO ledger_entries (
            id, transaction_id, account_id, direction, amount_cents,
            balance_bucket, status, created_at
          ) VALUES (?, ?, ?, ?, ?, 'available', 'posted', CURRENT_TIMESTAMP)`,
          counterpartyEntryId,
          transactionId,
          counterpartyAccountId,
          counterpartyDirection,
          amountCents,
        );
        await this.rebuildProjection(tx, counterpartyAccountId);
        return this.rebuildProjection(tx, input.accountId);
      });

      return {
        transactionId,
        accountId: input.accountId,
        amountCents,
        type: input.type,
        status: "posted",
        projection,
      };
    } catch (error) {
      logger.error({ err: error, accountId: input.accountId, type: input.type }, "[ledger] post failed");
      throw new LedgerBalanceError("ledger_post_failed", "Ledger posting failed.", 500);
    }
  }

  async reverseTransaction(input: {
    accountId: string;
    transactionId: string;
    externalId?: string | null;
    metadata?: Record<string, unknown>;
  }): Promise<LedgerPostResult> {
    await this.ensureLedgerTables();
    const rows = await this.prisma.$queryRawUnsafe<TransactionRow[]>(
      `SELECT * FROM ledger_transactions WHERE id = ? AND account_id = ? LIMIT 1`,
      input.transactionId,
      input.accountId,
    );
    const original = rows[0];
    if (!original) {
      throw new LedgerBalanceError("ledger_transaction_not_found", "The original ledger transaction could not be found.", 404);
    }

    const existingReversals = await this.prisma.$queryRawUnsafe<TransactionRow[]>(
      `SELECT * FROM ledger_transactions WHERE reverse_of_transaction_id = ? AND account_id = ? LIMIT 1`,
      original.id,
      input.accountId,
    );
    const existingReversal = existingReversals[0];
    if (existingReversal) {
      return {
        transactionId: existingReversal.id,
        accountId: input.accountId,
        amountCents: toNumber(existingReversal.amount_cents),
        type: "reversal",
        status: "idempotent_replay",
        projection: await this.rebuildProjection(this.prisma, input.accountId),
      };
    }

    const entries = await this.prisma.$queryRawUnsafe<EntryRow[]>(
      `SELECT * FROM ledger_entries WHERE transaction_id = ? AND account_id = ? LIMIT 1`,
      input.transactionId,
      input.accountId,
    );
    const userEntry = entries[0];
    if (!userEntry) {
      throw new LedgerBalanceError("ledger_transaction_not_found", "The original ledger entry could not be found.", 404);
    }

    const reversal = await this.postLedgerTransaction({
      accountId: input.accountId,
      amountCents: toNumber(original.amount_cents),
      type: "reversal",
      direction: userEntry.direction === "credit" ? "debit" : "credit",
      balanceBucket: normalizeBucket(userEntry.balance_bucket),
      currency: original.currency,
      externalId: input.externalId ?? `reversal:${original.id}`,
      reverseOfTransactionId: original.id,
      metadata: {
        ...(input.metadata ?? {}),
        originalTransactionId: original.id,
        originalType: original.type,
      },
      allowNegativeBalance: true,
      counterpartyAccountId: "system:reversals",
    });
    await this.prisma.$executeRawUnsafe(
      `UPDATE ledger_transactions SET reversed_at = CURRENT_TIMESTAMP WHERE id = ? AND reversed_at IS NULL`,
      original.id,
    );
    return reversal;
  }

  async getLedgerHistory(accountId: string, limit = 50): Promise<LedgerHistoryResult> {
    await this.ensureLedgerTables();
    await this.requireAccount(accountId);
    const boundedLimit = Math.min(Math.max(Math.trunc(limit) || 50, 1), 200);
    const projection = await this.buildProjection(this.prisma, accountId);
    const transactions = await this.prisma.$queryRawUnsafe<TransactionRow[]>(
      `SELECT * FROM ledger_transactions WHERE account_id = ? ORDER BY created_at DESC LIMIT ?`,
      accountId,
      boundedLimit,
    );
    const transactionIds = transactions.map((transaction) => transaction.id);
    const entriesByTransaction = new Map<string, EntryRow[]>();

    for (const transactionId of transactionIds) {
      const entries = await this.prisma.$queryRawUnsafe<EntryRow[]>(
        `SELECT * FROM ledger_entries WHERE transaction_id = ? ORDER BY created_at ASC`,
        transactionId,
      );
      entriesByTransaction.set(transactionId, entries);
    }

    return {
      accountId,
      projection,
      transactions: transactions.map((transaction) => ({
        id: transaction.id,
        type: transaction.type,
        status: transaction.status,
        amountCents: toNumber(transaction.amount_cents),
        currency: transaction.currency,
        externalId: transaction.external_id,
        unitTxId: transaction.unit_tx_id,
        stripeId: transaction.stripe_id,
        reverseOfTransactionId: transaction.reverse_of_transaction_id,
        metadata: parseMetadata(transaction.metadata_json),
        createdAt: toISO(transaction.created_at),
        postedAt: transaction.posted_at ? toISO(transaction.posted_at) : null,
        entries: (entriesByTransaction.get(transaction.id) ?? []).map((entry) => ({
          id: entry.id,
          accountId: entry.account_id,
          direction: entry.direction,
          amountCents: toNumber(entry.amount_cents),
          balanceBucket: entry.balance_bucket,
          status: entry.status,
          createdAt: toISO(entry.created_at),
        })),
      })),
    };
  }

  async listAccountIds(limit = 1_000): Promise<string[]> {
    await this.ensureLedgerTables();
    const rows = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(
      `SELECT id FROM accounts ORDER BY updated_at DESC LIMIT ?`,
      Math.min(Math.max(Math.trunc(limit) || 1_000, 1), 10_000),
    );
    return rows.map((row) => row.id);
  }

  private async ensureLedgerTables(): Promise<void> {
    if (ledgerTablesReady) return;
    await this.prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS accounts (
        id TEXT NOT NULL PRIMARY KEY,
        user_id TEXT,
        balance INTEGER NOT NULL DEFAULT 0,
        available_balance INTEGER NOT NULL DEFAULT 0,
        pending_balance INTEGER NOT NULL DEFAULT 0,
        currency TEXT NOT NULL DEFAULT 'USD',
        status TEXT NOT NULL DEFAULT 'active',
        allow_negative_balance BOOLEAN NOT NULL DEFAULT false,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS accounts_user_id_idx ON accounts(user_id)`);
    await this.prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS ledger_transactions (
        id TEXT NOT NULL PRIMARY KEY,
        account_id TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'posted',
        amount_cents INTEGER NOT NULL,
        currency TEXT NOT NULL DEFAULT 'USD',
        external_id TEXT,
        unit_tx_id TEXT,
        stripe_id TEXT,
        reverse_of_transaction_id TEXT,
        metadata_json TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        posted_at DATETIME,
        reversed_at DATETIME,
        CONSTRAINT ledger_transactions_account_fkey FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE RESTRICT ON UPDATE CASCADE
      )
    `);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_transactions_account_created_idx ON ledger_transactions(account_id, created_at)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_transactions_type_created_idx ON ledger_transactions(type, created_at)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_transactions_reverse_of_idx ON ledger_transactions(reverse_of_transaction_id)`);
    await this.prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS ledger_transactions_external_id_unique ON ledger_transactions(external_id) WHERE external_id IS NOT NULL`);
    await this.prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS ledger_transactions_unit_tx_id_unique ON ledger_transactions(unit_tx_id) WHERE unit_tx_id IS NOT NULL`);
    await this.prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS ledger_transactions_stripe_id_unique ON ledger_transactions(stripe_id) WHERE stripe_id IS NOT NULL`);
    await this.prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS ledger_entries (
        id TEXT NOT NULL PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        direction TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        balance_bucket TEXT NOT NULL DEFAULT 'available',
        status TEXT NOT NULL DEFAULT 'posted',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT ledger_entries_transaction_fkey FOREIGN KEY (transaction_id) REFERENCES ledger_transactions(id) ON DELETE RESTRICT ON UPDATE CASCADE,
        CONSTRAINT ledger_entries_account_fkey FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE RESTRICT ON UPDATE CASCADE
      )
    `);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_entries_account_bucket_status_idx ON ledger_entries(account_id, balance_bucket, status)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_entries_transaction_idx ON ledger_entries(transaction_id)`);
    await this.prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS ledger_reconciliations (
        id TEXT NOT NULL PRIMARY KEY,
        account_id TEXT NOT NULL,
        cached_balance INTEGER NOT NULL,
        cached_available_balance INTEGER NOT NULL,
        projected_balance INTEGER NOT NULL,
        projected_available_balance INTEGER NOT NULL,
        projected_pending_balance INTEGER NOT NULL,
        mismatch_cents INTEGER NOT NULL,
        action TEXT NOT NULL,
        severity TEXT NOT NULL,
        details_json TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT ledger_reconciliations_account_fkey FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE RESTRICT ON UPDATE CASCADE
      )
    `);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_reconciliations_account_created_idx ON ledger_reconciliations(account_id, created_at)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS ledger_reconciliations_severity_created_idx ON ledger_reconciliations(severity, created_at)`);
    ledgerTablesReady = true;
  }

  private async createAccountIfMissingWithClient(db: RawDb, input: {
    accountId: string;
    userId?: string | null;
    currency?: string;
    allowNegativeBalance?: boolean;
  }): Promise<void> {
    await db.$executeRawUnsafe(
      `INSERT OR IGNORE INTO accounts (
        id, user_id, currency, allow_negative_balance, created_at, updated_at
      ) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`,
      input.accountId,
      input.userId ?? null,
      normalizeCurrency(input.currency),
      input.allowNegativeBalance ? 1 : 0,
    );
  }

  private async requireAccount(accountId: string): Promise<AccountRow> {
    const rows = await this.prisma.$queryRawUnsafe<AccountRow[]>(`SELECT * FROM accounts WHERE id = ? LIMIT 1`, accountId);
    const account = rows[0];
    if (!account) {
      throw new LedgerBalanceError("ledger_account_not_found", "Ledger account not found.", 404);
    }
    return account;
  }

  private async buildProjection(db: RawDb, accountId: string): Promise<LedgerBalanceProjection> {
    const rows = await db.$queryRawUnsafe<ProjectedRow[]>(
      `SELECT
        COALESCE(SUM(CASE WHEN balance_bucket = 'available' THEN CASE WHEN direction = 'credit' THEN amount_cents ELSE -amount_cents END ELSE 0 END), 0) AS available_balance,
        COALESCE(SUM(CASE WHEN balance_bucket = 'pending' THEN CASE WHEN direction = 'credit' THEN amount_cents ELSE -amount_cents END ELSE 0 END), 0) AS pending_balance,
        COUNT(*) AS entry_count
       FROM ledger_entries
       WHERE account_id = ? AND status = 'posted'`,
      accountId,
    );
    const row = rows[0] ?? { available_balance: 0, pending_balance: 0, entry_count: 0 };
    const accountRows = await db.$queryRawUnsafe<Array<{ currency: string }>>(
      `SELECT currency FROM accounts WHERE id = ? LIMIT 1`,
      accountId,
    );
    const availableBalance = toNumber(row.available_balance);
    const pendingBalance = toNumber(row.pending_balance);
    return {
      accountId,
      availableBalance,
      pendingBalance,
      totalBalance: availableBalance + pendingBalance,
      currency: normalizeCurrency(accountRows[0]?.currency),
      entryCount: toNumber(row.entry_count),
      rebuiltAt: new Date().toISOString(),
    };
  }

  private async rebuildProjection(db: RawDb, accountId: string): Promise<LedgerBalanceProjection> {
    const projection = await this.buildProjection(db, accountId);
    await db.$executeRawUnsafe(
      `UPDATE accounts
       SET balance = ?, available_balance = ?, pending_balance = ?, updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`,
      projection.totalBalance,
      projection.availableBalance,
      projection.pendingBalance,
      accountId,
    );
    return projection;
  }

  private async findIdempotentTransaction(input: LedgerPostInput): Promise<TransactionRow | null> {
    const checks: Array<[string, string | null | undefined]> = [
      ["external_id", input.externalId],
      ["unit_tx_id", input.unitTxId],
      ["stripe_id", input.stripeId],
    ];
    for (const [column, value] of checks) {
      if (!value) continue;
      const rows = await this.prisma.$queryRawUnsafe<TransactionRow[]>(
        `SELECT * FROM ledger_transactions WHERE ${column} = ? LIMIT 1`,
        value,
      );
      if (rows[0]) return rows[0];
    }
    return null;
  }
}

export function isLedgerBalanceError(error: unknown): error is LedgerBalanceError {
  return error instanceof LedgerBalanceError;
}

function defaultCounterpartyAccount(type: LedgerTransactionType): string {
  switch (type) {
    case "storefront_payment":
      return "system:storefront-clearing";
    case "dispute_provisional_credit":
      return "system:dispute-provisional";
    case "reversal":
      return "system:reversals";
    case "withdrawal":
    case "deposit":
    case "adjustment":
    default:
      return "system:external-settlement";
  }
}

function normalizeCurrency(value: string | null | undefined): string {
  const normalized = (value ?? "USD").trim().toUpperCase();
  return /^[A-Z]{3}$/.test(normalized) ? normalized : "USD";
}

function normalizeBucket(value: string): LedgerBucket {
  return value === "pending" ? "pending" : "available";
}

function nullable(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function toNumber(value: number | bigint | null | undefined): number {
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "number") return value;
  return 0;
}

function toISO(value: string | Date): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function parseMetadata(value: string | null): Record<string, unknown> | null {
  if (!value) return null;
  try {
    const parsed = JSON.parse(value) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function parseIntegerEnv(name: string, fallback: number): number {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}
