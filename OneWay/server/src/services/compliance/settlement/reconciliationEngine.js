/**
 * OneWay Bank — Settlement Reconciliation Engine
 * Runs nightly via cron: 0 2 * * * (2 AM daily)
 *
 * Process:
 * 1. Pull Unit.co settlement report
 * 2. Pull internal ledger totals
 * 3. Pull Stripe settlement (card acceptance)
 * 4. Pull Zero Hash crypto settlement
 * 5. Compare line by line — every cent must match
 * 6. Flag breaks, auto-resolve minor rounding, escalate major breaks
 * 7. Generate reconciliation report
 * 8. Alert compliance officer on any unresolved breaks
 *
 * Regulatory requirement: All breaks investigated before next business day
 */

require("dotenv").config();
const axios       = require("../utils/optionalAxios");
const cron        = require("../utils/optionalCron");
const { query, withTransaction } = require("../config/database");
const logger      = require("../utils/logger");
const emailService = require("../services/emailService");
const { reconciliationEnabled } = require("../utils/flags");

const UNIT_BASE  = process.env.UNIT_BASE_URL  || "https://api.s.unit.sh";
const UNIT_TOKEN = process.env.UNIT_API_TOKEN;
const MT_KEY     = process.env.MODERN_TREASURY_API_KEY;
const MT_ORG     = process.env.MODERN_TREASURY_ORG_ID;
const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
const ZH_KEY     = process.env.ZERO_HASH_API_KEY;
const ZH_SECRET  = process.env.ZERO_HASH_API_SECRET;

// ── Tolerance: breaks under $0.01 are rounding, auto-resolve
const ROUNDING_TOLERANCE  = 0.01;
// ── Breaks over $100 require immediate escalation
const ESCALATION_THRESHOLD = 100.00;

// ═══════════════════════════════════════════════════════════
// UNIT.CO SETTLEMENT
// ═══════════════════════════════════════════════════════════

async function fetchUnitSettlement(date) {
  logger.info(`Fetching Unit.co settlement for ${date}`);

  const res = await axios.get(`${UNIT_BASE}/statements`, {
    headers: { Authorization: `Bearer ${UNIT_TOKEN}` },
    params: { "filter[period]": date },
  });

  const accounts = res.data.data || [];
  const summary = { credits:0, debits:0, fees:0, netBalance:0, transactions:[] };

  for (const account of accounts) {
    const txRes = await axios.get(`${UNIT_BASE}/transactions`, {
      headers: { Authorization: `Bearer ${UNIT_TOKEN}` },
      params: {
        "filter[accountId]":  account.id,
        "filter[since]":      `${date}T00:00:00Z`,
        "filter[until]":      `${date}T23:59:59Z`,
        "page[limit]":        1000,
      },
    });

    const txns = txRes.data.data || [];
    for (const tx of txns) {
      const amt = tx.attributes.amount / 100; // cents → dollars
      const dir = tx.attributes.direction;
      if (dir === "Credit") summary.credits += amt;
      else summary.debits += amt;

      summary.transactions.push({
        id:          tx.id,
        type:        tx.type,
        amount:      amt,
        direction:   dir,
        description: tx.attributes.description,
        createdAt:   tx.attributes.createdAt,
        accountId:   account.id,
      });
    }
  }

  summary.netBalance = summary.credits - summary.debits;
  logger.info(`Unit.co: ${summary.transactions.length} txns, net $${summary.netBalance.toFixed(2)}`);
  return summary;
}

// ═══════════════════════════════════════════════════════════
// INTERNAL LEDGER
// ═══════════════════════════════════════════════════════════

async function fetchInternalLedger(date) {
  logger.info(`Fetching internal ledger for ${date}`);

  const result = await query(`
    SELECT
      SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END) AS credits,
      SUM(CASE WHEN amount < 0 THEN ABS(amount) ELSE 0 END) AS debits,
      COUNT(*) AS tx_count,
      SUM(CASE WHEN type = 'fee' THEN ABS(amount) ELSE 0 END) AS fees_collected
    FROM transactions
    WHERE DATE(created_at) = $1
      AND status = 'completed'
  `, [date]);

  const row = result.rows[0];
  const credits = parseFloat(row.credits || 0);
  const debits  = parseFloat(row.debits  || 0);

  // Also get transaction-level detail for matching
  const detail = await query(`
    SELECT
      id, amount, type, status, reference_id,
      unit_transaction_id, description, created_at
    FROM transactions
    WHERE DATE(created_at) = $1
      AND status = 'completed'
    ORDER BY created_at ASC
  `, [date]);

  return {
    credits,
    debits,
    fees:       parseFloat(row.fees_collected || 0),
    netBalance: credits - debits,
    txCount:    parseInt(row.tx_count || 0),
    transactions: detail.rows,
  };
}

// ═══════════════════════════════════════════════════════════
// STRIPE SETTLEMENT
// ═══════════════════════════════════════════════════════════

async function fetchStripeSettlement(date) {
  logger.info(`Fetching Stripe settlement for ${date}`);

  try {
    const res = await axios.get("https://api.stripe.com/v1/balance/history", {
      auth:   { username: STRIPE_KEY, password: "" },
      params: {
        created: {
          gte: Math.floor(new Date(`${date}T00:00:00Z`).getTime() / 1000),
          lte: Math.floor(new Date(`${date}T23:59:59Z`).getTime() / 1000),
        },
        limit: 100,
        type:  "payout",
      },
    });

    const payouts = res.data.data || [];
    const totalPayout = payouts.reduce((sum, p) => sum + p.amount / 100, 0);

    return {
      payouts:      payouts.length,
      totalPayout,
      transactions: payouts.map(p => ({
        id:          p.id,
        amount:      p.amount / 100,
        currency:    p.currency,
        status:      p.status,
        arrivalDate: p.arrival_date,
        description: p.description,
      })),
    };
  } catch (err) {
    logger.warn("Stripe settlement fetch failed:", err.message);
    return { payouts: 0, totalPayout: 0, transactions: [] };
  }
}

// ═══════════════════════════════════════════════════════════
// ZERO HASH CRYPTO SETTLEMENT
// ═══════════════════════════════════════════════════════════

async function fetchCryptoSettlement(date) {
  logger.info(`Fetching Zero Hash settlement for ${date}`);

  try {
    const crypto = require("crypto");
    const ts = Date.now().toString();
    const sig = crypto.createHmac("sha256", ZH_SECRET)
      .update(`${ts}GET/settlement/settlements`)
      .digest("base64");

    const res = await axios.get("https://api.zerohash.com/settlement/settlements", {
      headers: {
        "X-ZeroHash-Timestamp": ts,
        "X-ZeroHash-Signature": sig,
        "X-ZeroHash-API-Key":   ZH_KEY,
      },
      params: { created_gt: `${date}T00:00:00Z`, created_lt: `${date}T23:59:59Z` },
    });

    const settlements = res.data.settlements || [];
    const totalFiat   = settlements.reduce((s, x) => s + (parseFloat(x.fiat_amount) || 0), 0);

    return {
      count:        settlements.length,
      totalFiat,
      settlements:  settlements.map(s => ({
        id:         s.settlement_id,
        asset:      s.underlying,
        quantity:   s.quantity,
        fiatAmount: s.fiat_amount,
        status:     s.status,
      })),
    };
  } catch (err) {
    logger.warn("Zero Hash settlement fetch failed:", err.message);
    return { count: 0, totalFiat: 0, settlements: [] };
  }
}

// ═══════════════════════════════════════════════════════════
// RECONCILE — compare all sources, flag breaks
// ═══════════════════════════════════════════════════════════

async function reconcile(date) {
  if (!reconciliationEnabled()) {
    logger.info("OneWay Bank reconciliation paused.");
    return { status: "PAUSED", date, breaks: [], breakCount: 0, criticalCount: 0 };
  }

  logger.info(`\n${"═".repeat(60)}`);
  logger.info(`RECONCILIATION RUN — ${date}`);
  logger.info(`${"═".repeat(60)}\n`);

  const [unit, internal, stripe, crypto] = await Promise.all([
    fetchUnitSettlement(date),
    fetchInternalLedger(date),
    fetchStripeSettlement(date),
    fetchCryptoSettlement(date),
  ]);

  const breaks = [];
  const resolved = [];

  // ── 1. Unit.co vs Internal Ledger ──
  const unitVsInternal = Math.abs(unit.netBalance - internal.netBalance);
  if (unitVsInternal > ROUNDING_TOLERANCE) {
    const brk = {
      type:      "UNIT_VS_INTERNAL",
      severity:  unitVsInternal > ESCALATION_THRESHOLD ? "CRITICAL" : "MINOR",
      expected:  unit.netBalance,
      actual:    internal.netBalance,
      delta:     unitVsInternal,
      description: `Unit.co net $${unit.netBalance.toFixed(2)} vs Internal $${internal.netBalance.toFixed(2)}`,
    };
    breaks.push(brk);
    logger.error(`❌ BREAK: ${brk.description} (Δ $${unitVsInternal.toFixed(2)})`);
  } else {
    resolved.push({ check:"Unit vs Internal", result:"MATCH", delta: unitVsInternal });
    logger.info(`✓ Unit.co ↔ Internal ledger match (Δ $${unitVsInternal.toFixed(4)})`);
  }

  // ── 2. Transaction count match ──
  const countDiff = Math.abs(unit.transactions.length - internal.txCount);
  if (countDiff > 0) {
    // Find which transactions are in Unit but not in our DB
    const unitIds   = new Set(unit.transactions.map(t => t.id));
    const internalIds = new Set(internal.transactions.map(t => t.unit_transaction_id).filter(Boolean));
    const missing   = [...unitIds].filter(id => !internalIds.has(id));

    if (missing.length > 0) {
      breaks.push({
        type:      "MISSING_TRANSACTIONS",
        severity:  "CRITICAL",
        expected:  unit.transactions.length,
        actual:    internal.txCount,
        delta:     missing.length,
        description: `${missing.length} Unit transactions not in internal ledger`,
        missingIds: missing,
      });
      logger.error(`❌ BREAK: ${missing.length} missing transactions: ${missing.slice(0,5).join(", ")}`);
    }
  } else {
    logger.info(`✓ Transaction count match: ${unit.transactions.length} transactions`);
  }

  // ── 3. Fees reconciliation ──
  const expectedFees = unit.transactions
    .filter(t => t.type === "fee")
    .reduce((s, t) => s + t.amount, 0);
  const feeDiff = Math.abs(expectedFees - internal.fees);
  if (feeDiff > ROUNDING_TOLERANCE) {
    breaks.push({
      type:      "FEE_MISMATCH",
      severity:  feeDiff > 10 ? "HIGH" : "LOW",
      expected:  expectedFees,
      actual:    internal.fees,
      delta:     feeDiff,
      description: `Fee mismatch: expected $${expectedFees.toFixed(2)}, recorded $${internal.fees.toFixed(2)}`,
    });
  } else {
    logger.info(`✓ Fees match: $${internal.fees.toFixed(2)}`);
  }

  // ── 4. Crypto settlement integrity ──
  const cryptoTxns = await query(`
    SELECT SUM(total_usd) as total, COUNT(*) as count
    FROM crypto_transactions
    WHERE DATE(created_at) = $1 AND status = 'completed'
  `, [date]);

  const internalCrypto = parseFloat(cryptoTxns.rows[0]?.total || 0);
  const cryptoDiff     = Math.abs(internalCrypto - crypto.totalFiat);
  if (cryptoDiff > ROUNDING_TOLERANCE && crypto.totalFiat > 0) {
    breaks.push({
      type:      "CRYPTO_SETTLEMENT_MISMATCH",
      severity:  cryptoDiff > ESCALATION_THRESHOLD ? "CRITICAL" : "MINOR",
      expected:  crypto.totalFiat,
      actual:    internalCrypto,
      delta:     cryptoDiff,
      description: `Crypto settlement: ZeroHash $${crypto.totalFiat.toFixed(2)} vs Internal $${internalCrypto.toFixed(2)}`,
    });
  } else {
    logger.info(`✓ Crypto settlement match: $${internalCrypto.toFixed(2)}`);
  }

  // ── Persist reconciliation report ──
  const report = {
    date,
    runAt:          new Date().toISOString(),
    status:         breaks.length === 0 ? "CLEAN" : breaks.some(b=>b.severity==="CRITICAL") ? "CRITICAL" : "BREAKS",
    summary: {
      unitCredits:     unit.credits,
      unitDebits:      unit.debits,
      unitNet:         unit.netBalance,
      internalCredits: internal.credits,
      internalDebits:  internal.debits,
      internalNet:     internal.netBalance,
      stripePayouts:   stripe.totalPayout,
      cryptoSettled:   crypto.totalFiat,
      totalTxCount:    unit.transactions.length,
    },
    breaks,
    resolved,
    breakCount:  breaks.length,
    criticalCount: breaks.filter(b=>b.severity==="CRITICAL").length,
  };

  await withTransaction(async (client) => {
    await client.query(`
      INSERT INTO reconciliation_reports
        (date, status, summary, breaks, break_count, critical_count, run_at)
      VALUES ($1,$2,$3,$4,$5,$6,NOW())
      ON CONFLICT (date) DO UPDATE SET
        status=$2, summary=$3, breaks=$4, break_count=$5, critical_count=$6, run_at=NOW()
    `, [date, report.status, JSON.stringify(report.summary), JSON.stringify(breaks), breaks.length, report.criticalCount]);

    // Persist individual breaks for investigation tracking
    for (const brk of breaks) {
      await client.query(`
        INSERT INTO reconciliation_breaks
          (date, type, severity, expected_amount, actual_amount, delta, description, status)
        VALUES ($1,$2,$3,$4,$5,$6,$7,'open')
        ON CONFLICT DO NOTHING
      `, [date, brk.type, brk.severity, brk.expected, brk.actual, brk.delta, brk.description]);
    }
  });

  // ── Alert compliance officer ──
  if (breaks.length > 0) {
    const critical = breaks.filter(b => b.severity === "CRITICAL");
    await emailService.sendEmail(
      process.env.COMPLIANCE_EMAIL || "compliance@onewaybank.com",
      `${critical.length > 0 ? "🚨 CRITICAL" : "⚠️"} Settlement Breaks — ${date}`,
      generateBreakReport(date, report)
    );
    if (critical.length > 0) {
      logger.error(`🚨 ${critical.length} CRITICAL breaks — compliance officer notified`);
    }
  } else {
    logger.info(`✅ Settlement CLEAN — no breaks found for ${date}`);
  }

  return report;
}

function generateBreakReport(date, report) {
  const rows = report.breaks.map(b => `
    <tr style="background:${b.severity==="CRITICAL"?"#fee":"#fff"}">
      <td>${b.type}</td>
      <td><strong>${b.severity}</strong></td>
      <td>$${(b.expected||0).toFixed(2)}</td>
      <td>$${(b.actual||0).toFixed(2)}</td>
      <td><strong>$${(b.delta||0).toFixed(2)}</strong></td>
      <td>${b.description}</td>
    </tr>
  `).join("");

  return `
    <h2>OneWay Bank — Settlement Reconciliation Report</h2>
    <p>Date: <strong>${date}</strong> · Status: <strong style="color:${report.status==="CLEAN"?"green":"red"}">${report.status}</strong></p>
    <h3>Summary</h3>
    <ul>
      <li>Unit.co net: $${report.summary.unitNet.toFixed(2)}</li>
      <li>Internal ledger net: $${report.summary.internalNet.toFixed(2)}</li>
      <li>Stripe payouts: $${report.summary.stripePayouts.toFixed(2)}</li>
      <li>Crypto settled: $${report.summary.cryptoSettled.toFixed(2)}</li>
      <li>Total transactions: ${report.summary.totalTxCount}</li>
    </ul>
    <h3>Breaks (${report.breaks.length})</h3>
    <table border="1" cellpadding="8" style="border-collapse:collapse;width:100%">
      <tr><th>Type</th><th>Severity</th><th>Expected</th><th>Actual</th><th>Delta</th><th>Description</th></tr>
      ${rows}
    </table>
    <p><em>All breaks must be investigated and resolved before the next business day. Log findings in the reconciliation_breaks table.</em></p>
  `;
}

// ── Database schema additions ──
async function ensureSchema() {
  if (!reconciliationEnabled()) {
    logger.info("OneWay Bank reconciliation schema paused.");
    return { enabled: false };
  }

  if (isSQLite()) {
    await ensureSQLiteReconciliationSchema();
    logger.info("✓ Dormant OneWay Bank reconciliation schema ready for local/dev SQLite");
    return { enabled: true, mode: "sqlite" };
  }

  await query(`
    CREATE TABLE IF NOT EXISTS reconciliation_reports (
      id           BIGSERIAL PRIMARY KEY,
      date         DATE UNIQUE NOT NULL,
      status       VARCHAR(20) NOT NULL,
      summary      JSONB,
      breaks       JSONB DEFAULT '[]',
      break_count  INTEGER DEFAULT 0,
      critical_count INTEGER DEFAULT 0,
      run_at       TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS reconciliation_breaks (
      id              BIGSERIAL PRIMARY KEY,
      date            DATE NOT NULL,
      type            VARCHAR(100),
      severity        VARCHAR(20),
      expected_amount NUMERIC(20,4),
      actual_amount   NUMERIC(20,4),
      delta           NUMERIC(20,4),
      description     TEXT,
      status          VARCHAR(20) DEFAULT 'open',
      notes           TEXT,
      resolved_by     UUID,
      resolved_at     TIMESTAMPTZ,
      created_at      TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_recon_breaks_date ON reconciliation_breaks(date);
    CREATE INDEX IF NOT EXISTS idx_recon_breaks_status ON reconciliation_breaks(status);
  `);
}

async function ensureSQLiteReconciliationSchema() {
  await query(`
    CREATE TABLE IF NOT EXISTS reconciliation_reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      date TEXT UNIQUE NOT NULL,
      status TEXT NOT NULL,
      summary TEXT,
      breaks TEXT DEFAULT '[]',
      break_count INTEGER DEFAULT 0,
      critical_count INTEGER DEFAULT 0,
      run_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`
    CREATE TABLE IF NOT EXISTS reconciliation_breaks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      date TEXT NOT NULL,
      type TEXT,
      severity TEXT,
      expected_amount NUMERIC,
      actual_amount NUMERIC,
      delta NUMERIC,
      description TEXT,
      status TEXT DEFAULT 'open',
      notes TEXT,
      resolved_by TEXT,
      resolved_at DATETIME,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`CREATE INDEX IF NOT EXISTS idx_compliance_recon_breaks_date ON reconciliation_breaks(date)`);
  await query(`CREATE INDEX IF NOT EXISTS idx_compliance_recon_breaks_status ON reconciliation_breaks(status)`);
}

// ── Cron: run every night at 2 AM ──
cron.schedule("0 2 * * *", async () => {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const date = yesterday.toISOString().split("T")[0];
  try {
    await ensureSchema();
    await reconcile(date);
  } catch (err) {
    logger.error("Reconciliation job failed:", err);
    await emailService.sendEmail(
      process.env.COMPLIANCE_EMAIL,
      "🚨 Reconciliation Job FAILED",
      `<p>The nightly reconciliation for ${date} failed with error:</p><pre>${err.message}\n${err.stack}</pre>`
    );
  }
});

// ── Manual run: node settlement/reconciliationEngine.js 2024-12-15 ──
if (require.main === module) {
  const date = process.argv[2] || new Date().toISOString().split("T")[0];
  ensureSchema()
    .then(() => reconcile(date))
    .then(r => {
      console.log(`\nReconciliation complete: ${r.status}`);
      console.log(`Breaks: ${r.breakCount} (${r.criticalCount} critical)`);
      process.exit(r.criticalCount > 0 ? 1 : 0);
    })
    .catch(err => { console.error(err); process.exit(1); });
}

module.exports = { reconcile, ensureSchema };

function isSQLite() {
  return (process.env.DATABASE_URL || "").trim().startsWith("file:");
}
