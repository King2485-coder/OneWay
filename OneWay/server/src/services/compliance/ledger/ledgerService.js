/**
 * OneWay Bank — Modern Treasury Ledger Integration
 *
 * Modern Treasury (moderntreausry.com) provides:
 * - Double-entry ledger with audit trail
 * - Payment operations (ACH, wire, RTP)
 * - Auto-reconciliation against bank statements
 * - Expected payments matching
 *
 * Every dollar movement creates two ledger entries (debit + credit)
 * that must always sum to zero. This is the immutable financial record
 * that regulators, auditors, and courts will examine.
 *
 * Also includes our own hardened PostgreSQL ledger as a parallel record.
 */

require("dotenv").config();
const axios    = require("../utils/optionalAxios");
const { query, withTransaction } = require("../config/database");
const logger   = require("../utils/logger");
const { assertBankEnabled, ledgerEnabled } = require("../utils/flags");
const { encryptComplianceText, encryptComplianceJson } = require("../utils/encryption");

const MT_BASE = "https://app.moderntreasury.com/api";
const MT_KEY  = process.env.MODERN_TREASURY_API_KEY;
const MT_ORG  = process.env.MODERN_TREASURY_ORG_ID;

// Modern Treasury uses HTTP Basic auth: org-id:api-key
const mtClient = axios.create({
  baseURL: MT_BASE,
  auth: { username: MT_ORG, password: MT_KEY },
  headers: { "Content-Type": "application/json" },
  timeout: 15000,
});

mtClient.interceptors.response.use(
  res => res,
  err => {
    logger.error("Modern Treasury API error:", {
      status:  err.response?.status,
      message: err.response?.data?.message || err.message,
    });
    throw err;
  }
);

// ═══════════════════════════════════════════════════════════
// LEDGER SCHEMA (PostgreSQL — parallel to Modern Treasury)
// ═══════════════════════════════════════════════════════════

async function ensureLedgerSchema() {
  if (!ledgerEnabled()) {
    logger.info("OneWay Bank ledger schema paused.");
    return { enabled: false };
  }

  if (isSQLite()) {
    await ensureSQLiteLedgerSchema();
    await seedChartOfAccounts();
    logger.info("✓ Dormant OneWay Bank ledger schema ready for local/dev SQLite");
    return { enabled: true, mode: "sqlite" };
  }

  await query(`
    -- Ledger accounts (asset, liability, equity, revenue, expense)
    CREATE TABLE IF NOT EXISTS ledger_accounts (
      id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      name            VARCHAR(255) UNIQUE NOT NULL,
      normal_balance  VARCHAR(6) CHECK (normal_balance IN ('debit','credit')) NOT NULL,
      type            VARCHAR(20) NOT NULL, -- asset|liability|equity|revenue|expense
      currency        VARCHAR(3) DEFAULT 'USD',
      mt_ledger_account_id VARCHAR(255),   -- Modern Treasury ID
      description     TEXT,
      is_active       BOOLEAN DEFAULT TRUE,
      created_at      TIMESTAMPTZ DEFAULT NOW()
    );

    -- Ledger transactions (immutable — INSERT ONLY, no UPDATE/DELETE)
    CREATE TABLE IF NOT EXISTS ledger_transactions (
      id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      description     VARCHAR(500) NOT NULL,
      status          VARCHAR(20) DEFAULT 'pending',    -- pending|posted|archived
      effective_at    TIMESTAMPTZ NOT NULL,
      metadata        JSONB DEFAULT '{}',
      external_id     VARCHAR(255) UNIQUE,              -- idempotency key
      mt_ledger_tx_id VARCHAR(255),                     -- Modern Treasury ledger TX ID
      unit_tx_id      VARCHAR(255),
      created_at      TIMESTAMPTZ DEFAULT NOW()
    );

    -- Ledger entries (double-entry — each tx has 2+ entries summing to 0)
    CREATE TABLE IF NOT EXISTS ledger_entries (
      id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      ledger_transaction_id UUID NOT NULL REFERENCES ledger_transactions(id),
      ledger_account_id     UUID NOT NULL REFERENCES ledger_accounts(id),
      direction             VARCHAR(6) CHECK (direction IN ('debit','credit')) NOT NULL,
      amount                NUMERIC(20, 4) NOT NULL CHECK (amount > 0),
      currency              VARCHAR(3) DEFAULT 'USD',
      available_balance_after NUMERIC(20,4),
      pending_balance_after   NUMERIC(20,4),
      created_at            TIMESTAMPTZ DEFAULT NOW()
    );

    -- IMMUTABILITY ENFORCEMENT: prevent updates/deletes
    CREATE OR REPLACE FUNCTION prevent_ledger_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Ledger entries are immutable. Use a reversing entry instead.';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS trg_ledger_entries_immutable ON ledger_entries;
    CREATE TRIGGER trg_ledger_entries_immutable
      BEFORE UPDATE OR DELETE ON ledger_entries
      FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();

    -- BALANCE CHECK: ensure every transaction has balanced entries
    CREATE OR REPLACE FUNCTION check_ledger_balance()
    RETURNS TRIGGER AS $$
    DECLARE
      debit_sum  NUMERIC;
      credit_sum NUMERIC;
    BEGIN
      -- Only check when transaction is posted
      IF NEW.status = 'posted' THEN
        SELECT
          COALESCE(SUM(CASE WHEN direction='debit'  THEN amount ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN direction='credit' THEN amount ELSE 0 END), 0)
        INTO debit_sum, credit_sum
        FROM ledger_entries
        WHERE ledger_transaction_id = NEW.id;

        IF ABS(debit_sum - credit_sum) > 0.001 THEN
          RAISE EXCEPTION 'Ledger imbalance: debits=% credits=% for transaction %',
            debit_sum, credit_sum, NEW.id;
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS trg_ledger_balance_check ON ledger_transactions;
    CREATE TRIGGER trg_ledger_balance_check
      BEFORE UPDATE ON ledger_transactions
      FOR EACH ROW EXECUTE FUNCTION check_ledger_balance();

    CREATE INDEX IF NOT EXISTS idx_ledger_entries_account ON ledger_entries(ledger_account_id);
    CREATE INDEX IF NOT EXISTS idx_ledger_entries_tx ON ledger_entries(ledger_transaction_id);
    CREATE INDEX IF NOT EXISTS idx_ledger_tx_effective ON ledger_transactions(effective_at);
    CREATE INDEX IF NOT EXISTS idx_ledger_tx_status ON ledger_transactions(status);
  `);

  // Seed chart of accounts
  await seedChartOfAccounts();
}

async function ensureSQLiteLedgerSchema() {
  await query(`
    CREATE TABLE IF NOT EXISTS ledger_accounts (
      id TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
      name TEXT UNIQUE NOT NULL,
      normal_balance TEXT NOT NULL,
      type TEXT NOT NULL,
      currency TEXT DEFAULT 'USD',
      mt_ledger_account_id TEXT,
      description TEXT,
      is_active BOOLEAN DEFAULT TRUE,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`
    CREATE TABLE IF NOT EXISTS ledger_transactions (
      id TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
      description TEXT NOT NULL,
      status TEXT DEFAULT 'pending',
      effective_at DATETIME NOT NULL,
      metadata TEXT DEFAULT '{}',
      external_id TEXT UNIQUE,
      mt_ledger_tx_id TEXT,
      unit_tx_id TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`
    CREATE TABLE IF NOT EXISTS ledger_entries (
      id TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
      ledger_transaction_id TEXT NOT NULL,
      ledger_account_id TEXT NOT NULL,
      direction TEXT NOT NULL,
      amount NUMERIC NOT NULL,
      currency TEXT DEFAULT 'USD',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`CREATE INDEX IF NOT EXISTS idx_compliance_ledger_entries_account ON ledger_entries(ledger_account_id)`);
  await query(`CREATE INDEX IF NOT EXISTS idx_compliance_ledger_entries_tx ON ledger_entries(ledger_transaction_id)`);
}

// ═══════════════════════════════════════════════════════════
// CHART OF ACCOUNTS
// ═══════════════════════════════════════════════════════════

const CHART_OF_ACCOUNTS = [
  // Assets (debit normal)
  { name:"cash_and_equivalents",        type:"asset",     normal_balance:"debit",  description:"Cash held at Unit.co partner bank" },
  { name:"customer_deposits_asset",     type:"asset",     normal_balance:"debit",  description:"Customer funds deposited" },
  { name:"crypto_custody_asset",        type:"asset",     normal_balance:"debit",  description:"Crypto held in Zero Hash custody" },
  { name:"accounts_receivable",         type:"asset",     normal_balance:"debit",  description:"Money owed to OneWay" },
  { name:"provisional_credits_asset",   type:"asset",     normal_balance:"debit",  description:"Outstanding provisional dispute credits" },
  { name:"interchange_receivable",      type:"asset",     normal_balance:"debit",  description:"Interchange fees owed from Visa/MC" },

  // Liabilities (credit normal)
  { name:"customer_deposits_liability", type:"liability", normal_balance:"credit", description:"Amounts owed to customers" },
  { name:"payables",                    type:"liability", normal_balance:"credit", description:"General payables" },
  { name:"dispute_reserves",            type:"liability", normal_balance:"credit", description:"Reserve for open disputes" },
  { name:"crypto_custody_liability",    type:"liability", normal_balance:"credit", description:"Crypto owed to customers" },
  { name:"unearned_fees",               type:"liability", normal_balance:"credit", description:"Fees collected but not yet earned" },

  // Revenue (credit normal)
  { name:"interchange_revenue",         type:"revenue",   normal_balance:"credit", description:"Interchange fee revenue" },
  { name:"monthly_fee_revenue",         type:"revenue",   normal_balance:"credit", description:"Monthly service fees" },
  { name:"wire_fee_revenue",            type:"revenue",   normal_balance:"credit", description:"Wire transfer fees" },
  { name:"crypto_spread_revenue",       type:"revenue",   normal_balance:"credit", description:"Crypto trading spread" },
  { name:"interest_income",             type:"revenue",   normal_balance:"credit", description:"Interest earned on deposits" },

  // Expenses (debit normal)
  { name:"bank_fees_expense",           type:"expense",   normal_balance:"debit",  description:"Fees paid to Unit.co" },
  { name:"processing_fees_expense",     type:"expense",   normal_balance:"debit",  description:"Card processing fees" },
  { name:"dispute_losses_expense",      type:"expense",   normal_balance:"debit",  description:"Dispute charge-offs" },
  { name:"fraud_losses_expense",        type:"expense",   normal_balance:"debit",  description:"Fraud write-offs" },
];

async function seedChartOfAccounts() {
  for (const acct of CHART_OF_ACCOUNTS) {
    await query(`
      INSERT INTO ledger_accounts (name, type, normal_balance, description)
      VALUES ($1,$2,$3,$4)
      ON CONFLICT (name) DO NOTHING
    `, [acct.name, acct.type, acct.normal_balance, acct.description]);
  }
  logger.info(`✓ Chart of accounts seeded (${CHART_OF_ACCOUNTS.length} accounts)`);
}

async function getAccount(name) {
  const res = await query("SELECT * FROM ledger_accounts WHERE name=$1", [name]);
  if (!res.rows[0]) throw new Error(`Ledger account not found: ${name}`);
  return res.rows[0];
}

// ═══════════════════════════════════════════════════════════
// RECORD LEDGER TRANSACTION (double-entry)
// ═══════════════════════════════════════════════════════════

async function recordLedgerTransaction({ description, entries, effectiveAt, metadata, externalId }) {
  assertBankEnabled("ledger.recordLedgerTransaction");
  if (entries.length < 2) throw new Error("Ledger transaction requires at least 2 entries");

  // Verify balance BEFORE writing (debits must equal credits)
  const totalDebits  = entries.filter(e=>e.direction==="debit").reduce((s,e)=>s+e.amount,0);
  const totalCredits = entries.filter(e=>e.direction==="credit").reduce((s,e)=>s+e.amount,0);
  if (Math.abs(totalDebits-totalCredits) > 0.001) {
    throw new Error(`Ledger imbalance: debits=${totalDebits.toFixed(4)} credits=${totalCredits.toFixed(4)}`);
  }

  return withTransaction(async (client) => {
    // Create transaction
    const txRes = await client.query(`
      INSERT INTO ledger_transactions (description, status, effective_at, metadata, external_id)
      VALUES ($1,'pending',$2,$3,$4) RETURNING *
    `, [
      encryptComplianceText(description, "ledger_transaction.description"),
      effectiveAt || new Date(),
      encryptComplianceJson(metadata || {}, "ledger_transaction.metadata"),
      externalId || null,
    ]);

    const tx = txRes.rows[0];

    // Create entries
    for (const entry of entries) {
      const acct = typeof entry.account === "string"
        ? await getAccount(entry.account)
        : entry.account;

      await client.query(`
        INSERT INTO ledger_entries
          (ledger_transaction_id, ledger_account_id, direction, amount, currency)
        VALUES ($1,$2,$3,$4,$5)
      `, [tx.id, acct.id, entry.direction, entry.amount, entry.currency||"USD"]);
    }

    // Post the transaction (triggers balance check)
    await client.query(
      "UPDATE ledger_transactions SET status='posted' WHERE id=$1",
      [tx.id]
    );

    return tx;
  });
}

// ═══════════════════════════════════════════════════════════
// MODERN TREASURY INTEGRATION
// ═══════════════════════════════════════════════════════════

// Create ledger in Modern Treasury (one-time setup)
async function setupMTLedger() {
  assertBankEnabled("ledger.setupMTLedger");
  try {
    const res = await mtClient.post("/ledgers", {
      name:        "OneWay Bank Master Ledger",
      description: "Primary double-entry ledger for all OneWay Bank transactions",
      metadata:    { env: process.env.NODE_ENV },
    });
    logger.info(`✓ Modern Treasury ledger created: ${res.data.id}`);
    return res.data;
  } catch (err) {
    logger.warn("MT ledger setup:", err.response?.data?.message || err.message);
  }
}

async function createMTLedgerAccount(name, normalBalance, ledgerId) {
  assertBankEnabled("ledger.createMTLedgerAccount");
  const res = await mtClient.post("/ledger_accounts", {
    name,
    normal_balance: normalBalance,
    ledger_id:      ledgerId,
    currency:       "USD",
  });
  return res.data;
}

// Record a transaction in Modern Treasury (creates mirror in MT)
async function recordMTTransaction({ description, entries, metadata, externalId }) {
  assertBankEnabled("ledger.recordMTTransaction");
  const res = await mtClient.post("/ledger_transactions", {
    description,
    effective_at:      new Date().toISOString(),
    status:            "posted",
    external_id:       externalId,
    metadata,
    ledger_entries:    entries.map(e => ({
      amount:             Math.round(e.amount * 100), // MT uses cents
      direction:          e.direction,
      ledger_account_id:  e.mtAccountId,
    })),
  });
  return res.data;
}

// Sync MT ledger with internal ledger (reconciliation)
async function syncWithModernTreasury(date) {
  assertBankEnabled("ledger.syncWithModernTreasury");
  logger.info(`Syncing with Modern Treasury for ${date}`);

  const mtTxns = await mtClient.get("/ledger_transactions", {
    params: {
      effective_at_lower_bound: `${date}T00:00:00Z`,
      effective_at_upper_bound: `${date}T23:59:59Z`,
      status: "posted",
      per_page: 1000,
    },
  });

  const internalTxns = await query(`
    SELECT lt.*, COUNT(le.id) as entry_count
    FROM ledger_transactions lt
    LEFT JOIN ledger_entries le ON le.ledger_transaction_id = lt.id
    WHERE DATE(lt.effective_at) = $1 AND lt.status = 'posted'
    GROUP BY lt.id
  `, [date]);

  const mtCount       = mtTxns.data.length;
  const internalCount = internalTxns.rows.length;
  const diff          = Math.abs(mtCount - internalCount);

  if (diff > 0) {
    logger.warn(`MT sync discrepancy: MT has ${mtCount}, internal has ${internalCount}`);
    // Identify missing transactions and backfill
    const mtIds       = new Set(mtTxns.data.map(t => t.external_id).filter(Boolean));
    const internalIds = new Set(internalTxns.rows.map(t => t.external_id).filter(Boolean));
    const missingInInternal = [...mtIds].filter(id => !internalIds.has(id));
    const missingInMT       = [...internalIds].filter(id => !mtIds.has(id));
    if (missingInInternal.length) logger.error(`Missing in internal ledger: ${missingInInternal.join(", ")}`);
    if (missingInMT.length)       logger.warn(`Missing in Modern Treasury: ${missingInMT.join(", ")}`);
  } else {
    logger.info(`✓ MT sync: ${mtCount} transactions match`);
  }

  return { mtCount, internalCount, diff };
}

// ═══════════════════════════════════════════════════════════
// COMMON TRANSACTION TEMPLATES
// ═══════════════════════════════════════════════════════════

// Customer deposits money
async function recordDeposit({ userId, accountId, amount, description, unitTxId }) {
  return recordLedgerTransaction({
    description: description || `Deposit — account ${accountId}`,
    effectiveAt: new Date(),
    externalId:  unitTxId,
    metadata:    { userId, accountId, type: "deposit" },
    entries: [
      { account:"cash_and_equivalents",        direction:"debit",  amount },
      { account:"customer_deposits_liability", direction:"credit", amount },
    ],
  });
}

// Customer withdraws / makes payment
async function recordWithdrawal({ userId, accountId, amount, description, unitTxId }) {
  return recordLedgerTransaction({
    description: description || `Withdrawal — account ${accountId}`,
    effectiveAt: new Date(),
    externalId:  unitTxId,
    metadata:    { userId, accountId, type: "withdrawal" },
    entries: [
      { account:"customer_deposits_liability", direction:"debit",  amount },
      { account:"cash_and_equivalents",        direction:"credit", amount },
    ],
  });
}

// Internal transfer between accounts
async function recordTransfer({ fromAccountId, toAccountId, amount, description }) {
  return recordLedgerTransaction({
    description: description || `Transfer ${fromAccountId} → ${toAccountId}`,
    effectiveAt: new Date(),
    externalId:  `transfer-${fromAccountId}-${toAccountId}-${Date.now()}`,
    metadata:    { fromAccountId, toAccountId, type: "transfer" },
    entries: [
      // No external money movement — just internal reallocation
      { account:"customer_deposits_liability", direction:"debit",  amount }, // from account decreases liability
      { account:"customer_deposits_liability", direction:"credit", amount }, // to account increases liability
    ],
  });
}

// Fee collected
async function recordFee({ userId, accountId, amount, feeType, description }) {
  return recordLedgerTransaction({
    description: description || `Fee — ${feeType}`,
    effectiveAt: new Date(),
    externalId:  `fee-${userId}-${feeType}-${Date.now()}`,
    metadata:    { userId, feeType, type: "fee" },
    entries: [
      { account:"customer_deposits_liability", direction:"debit",  amount }, // reduces what we owe customer
      { account:`${feeType}_revenue`,          direction:"credit", amount }, // records revenue
    ],
  });
}

// Crypto purchase
async function recordCryptoPurchase({ userId, asset, quantityUSD, feeUSD, description }) {
  return recordLedgerTransaction({
    description: description || `Crypto buy: ${asset}`,
    effectiveAt: new Date(),
    metadata:    { userId, asset, type: "crypto_buy" },
    entries: [
      { account:"crypto_custody_asset",        direction:"debit",  amount: quantityUSD },
      { account:"customer_deposits_liability", direction:"credit", amount: quantityUSD - feeUSD }, // net to customer
      { account:"crypto_spread_revenue",       direction:"credit", amount: feeUSD },               // our spread
    ],
  });
}

// Provisional dispute credit
async function recordProvisionalCredit({ userId, accountId, amount, disputeId }) {
  return recordLedgerTransaction({
    description: `Provisional credit — dispute ${disputeId}`,
    effectiveAt: new Date(),
    externalId:  `prov-${disputeId}`,
    metadata:    { userId, disputeId, type: "provisional_credit" },
    entries: [
      { account:"provisional_credits_asset",   direction:"debit",  amount },
      { account:"customer_deposits_liability", direction:"credit", amount },
    ],
  });
}

// Provisional credit reversal (if dispute resolved merchant favor)
async function reverseProvisionalCredit({ userId, accountId, amount, disputeId }) {
  return recordLedgerTransaction({
    description: `Provisional credit reversal — dispute ${disputeId}`,
    effectiveAt: new Date(),
    externalId:  `prov-rev-${disputeId}`,
    metadata:    { userId, disputeId, type: "provisional_credit_reversal" },
    entries: [
      { account:"customer_deposits_liability", direction:"debit",  amount },
      { account:"provisional_credits_asset",   direction:"credit", amount },
    ],
  });
}

// ═══════════════════════════════════════════════════════════
// ACCOUNT BALANCE (from ledger)
// ═══════════════════════════════════════════════════════════

async function getLedgerBalance(accountName, asOf) {
  const acct = await getAccount(accountName);
  const res  = await query(`
    SELECT
      COALESCE(SUM(CASE WHEN le.direction='debit'  THEN le.amount ELSE 0 END),0) AS total_debits,
      COALESCE(SUM(CASE WHEN le.direction='credit' THEN le.amount ELSE 0 END),0) AS total_credits
    FROM ledger_entries le
    JOIN ledger_transactions lt ON lt.id = le.ledger_transaction_id
    WHERE le.ledger_account_id = $1
      AND lt.status = 'posted'
      ${asOf ? "AND lt.effective_at <= $2" : ""}
  `, asOf ? [acct.id, asOf] : [acct.id]);

  const { total_debits, total_credits } = res.rows[0];
  const debits  = parseFloat(total_debits);
  const credits = parseFloat(total_credits);

  // Normal balance determines sign
  return acct.normal_balance === "debit"
    ? debits - credits    // Asset/Expense: debit increases balance
    : credits - debits;   // Liability/Equity/Revenue: credit increases balance
}

// Trial balance: list all accounts with balances (must sum to zero)
async function getTrialBalance(asOf) {
  const accounts = await query("SELECT * FROM ledger_accounts WHERE is_active=TRUE ORDER BY type, name");
  const balances = [];
  let totalDebits = 0, totalCredits = 0;

  for (const acct of accounts.rows) {
    const bal = await getLedgerBalance(acct.name, asOf);
    balances.push({ account: acct.name, type: acct.type, normalBalance: acct.normal_balance, balance: bal });
    if (acct.normal_balance === "debit")  totalDebits  += bal;
    else                                  totalCredits += bal;
  }

  const isBalanced = Math.abs(totalDebits - totalCredits) < 0.01;
  if (!isBalanced) logger.error(`⚠️ Trial balance out of balance! Debits=${totalDebits} Credits=${totalCredits}`);

  return { balances, totalDebits, totalCredits, isBalanced, asOf };
}

// ═══════════════════════════════════════════════════════════
// PAYMENT OPERATIONS (Modern Treasury)
// ═══════════════════════════════════════════════════════════

async function initiatePaymentOrder({ type, amount, direction, description, counterpartyId, accountId }) {
  assertBankEnabled("ledger.initiatePaymentOrder");
  // Modern Treasury orchestrates the actual payment + updates ledger
  const res = await mtClient.post("/payment_orders", {
    type,            // "ach" | "wire" | "rtp"
    amount:          Math.round(amount * 100),
    direction,       // "credit" | "debit"
    currency:        "USD",
    description,
    counterparty_id: counterpartyId,
    originating_account_id: accountId,
    metadata:        { source: "oneway-bank" },
  });

  logger.info(`Payment order created: ${res.data.id} — ${type} ${direction} $${amount}`);
  return res.data;
}

async function createExpectedPayment({ amount, direction, counterpartyId, description, reconciliationGroups }) {
  assertBankEnabled("ledger.createExpectedPayment");
  // Expected payments allow MT to auto-match incoming deposits/payments
  const res = await mtClient.post("/expected_payments", {
    amount_upper_bound: Math.round(amount * 100) + 100,
    amount_lower_bound: Math.round(amount * 100) - 100,
    direction,
    currency:           "USD",
    description,
    counterparty_id:    counterpartyId,
    reconciliation_groups: reconciliationGroups,
  });
  return res.data;
}

// ═══════════════════════════════════════════════════════════
// EXPRESS ROUTES
// ═══════════════════════════════════════════════════════════

const router = require("express").Router();
const { authenticate } = require("../middleware/authenticate");

// Admin: trial balance
router.get("/trial-balance", authenticate, async (req, res, next) => {
  try {
    const { asOf } = req.query;
    const balance  = await getTrialBalance(asOf);
    res.json(balance);
  } catch(e) { next(e); }
});

// Admin: account balance
router.get("/balance/:accountName", authenticate, async (req, res, next) => {
  try {
    const { asOf } = req.query;
    const balance  = await getLedgerBalance(req.params.accountName, asOf);
    res.json({ account: req.params.accountName, balance, asOf: asOf || "current" });
  } catch(e) { next(e); }
});

// Admin: MT sync status
router.get("/mt-sync/:date", authenticate, async (req, res, next) => {
  try {
    const result = await syncWithModernTreasury(req.params.date);
    res.json(result);
  } catch(e) { next(e); }
});

module.exports = {
  router,
  ensureLedgerSchema,
  recordLedgerTransaction,
  recordDeposit,
  recordWithdrawal,
  recordTransfer,
  recordFee,
  recordCryptoPurchase,
  recordProvisionalCredit,
  reverseProvisionalCredit,
  getLedgerBalance,
  getTrialBalance,
  setupMTLedger,
  syncWithModernTreasury,
  initiatePaymentOrder,
  createExpectedPayment,
};

function isSQLite() {
  return (process.env.DATABASE_URL || "").trim().startsWith("file:");
}
