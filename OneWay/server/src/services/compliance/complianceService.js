/**
 * OneWay Bank — Compliance Integration Layer
 *
 * Wires the ledger, settlement, and disputes engines into your
 * existing backend. Drop this into src/services/complianceService.js
 *
 * Every financial transaction in the system MUST:
 * 1. Record in internal ledger (double-entry)
 * 2. Record in Modern Treasury (audit trail)
 * 3. Webhook to Unit.co for bank-layer recording
 * 4. Be reconcilable at settlement
 */

const ledger     = require("./ledger/ledgerService");
const disputes   = require("./disputes/disputesEngine");
const settlement = require("./settlement/reconciliationEngine");
const logger     = require("./utils/logger");
const { query, withTransaction } = require("./config/database");
const { encryptComplianceText, encryptComplianceJson } = require("./utils/encryption");
const {
  assertBankEnabled,
  complianceLayerEnabled,
  ledgerEnabled,
  reconciliationEnabled,
  disputesEnabled,
} = require("./utils/flags");

// ═══════════════════════════════════════════════════════════
// INITIALIZE — call on server startup
// ═══════════════════════════════════════════════════════════

async function initializeCompliance() {
  if (!complianceLayerEnabled()) {
    logger.info("OneWay Bank compliance layer disabled. Stripe remains active.");
    return {
      enabled: false,
      message: "OneWay Bank compliance layer disabled. Stripe remains active.",
    };
  }

  logger.info("Initializing dormant OneWay Bank compliance control plane...");
  await ensureComplianceControlPlaneSchema();

  if (ledgerEnabled()) await ledger.ensureLedgerSchema();
  else logger.info("OneWay Bank ledger module paused.");

  if (disputesEnabled()) await disputes.ensureDisputeSchema();
  else logger.info("OneWay Bank disputes module paused.");

  if (reconciliationEnabled()) await settlement.ensureSchema();
  else logger.info("OneWay Bank reconciliation module paused.");

  logger.info("✓ OneWay Bank compliance scaffolding initialized. Stripe remains active.");
  return {
    enabled: true,
    ledgerEnabled: ledgerEnabled(),
    disputesEnabled: disputesEnabled(),
    reconciliationEnabled: reconciliationEnabled(),
  };
}

async function ensureComplianceControlPlaneSchema() {
  await query(`
    CREATE TABLE IF NOT EXISTS compliance_control_plane (
      id TEXT NOT NULL PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'paused',
      reason TEXT NOT NULL DEFAULT 'Stripe is being used while OneWay Bank is prepared.',
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`
    INSERT OR IGNORE INTO compliance_control_plane (id, status, reason)
    VALUES ('oneway-bank', 'paused', 'Stripe is being used while OneWay Bank is prepared.')
  `);
}

// ═══════════════════════════════════════════════════════════
// COMPLIANT DEPOSIT (Unit.co webhook → your system)
// ═══════════════════════════════════════════════════════════

async function processDeposit({ userId, accountId, amount, unitTxId, description, metadata }) {
  assertBankEnabled("processDeposit");
  logger.info(`Processing deposit: user=${userId} amount=$${amount} unit=${unitTxId}`);

  return withTransaction(async (client) => {
    // 1. Update account balance
    await client.query(`
      UPDATE accounts SET
        balance = balance + $1,
        available_balance = available_balance + $1,
        updated_at = NOW()
      WHERE id = $2
    `, [amount, accountId]);

    // 2. Record in transactions table
    const txRes = await client.query(`
      INSERT INTO transactions
        (account_id, user_id, type, status, amount, description, unit_transaction_id, metadata)
      VALUES ($1,$2,'credit','completed',$3,$4,$5,$6)
      RETURNING *
    `, [
      accountId,
      userId,
      amount,
      encryptComplianceText(description || "Deposit", "transaction.description"),
      unitTxId,
      encryptComplianceJson(metadata || {}, "transaction.metadata"),
    ]);

    const tx = txRes.rows[0];

    // 3. Double-entry ledger
    await ledger.recordDeposit({ userId, accountId, amount, description, unitTxId });

    // 4. Audit log
    await client.query(`
      INSERT INTO audit_log (user_id, action, resource_type, resource_id, new_value)
      VALUES ($1,'transaction.deposit','transaction',$2,$3)
    `, [userId, tx.id, JSON.stringify({amount, accountId})]);

    return tx;
  });
}

// ═══════════════════════════════════════════════════════════
// COMPLIANT WITHDRAWAL
// ═══════════════════════════════════════════════════════════

async function processWithdrawal({ userId, accountId, amount, unitTxId, description, metadata }) {
  assertBankEnabled("processWithdrawal");
  // Check sufficient funds first
  const acct = await query("SELECT balance FROM accounts WHERE id=$1 AND user_id=$2", [accountId, userId]);
  if (!acct.rows[0] || acct.rows[0].balance < amount) {
    throw new Error("Insufficient funds");
  }

  return withTransaction(async (client) => {
    await client.query(`
      UPDATE accounts SET
        balance = balance - $1,
        available_balance = available_balance - $1
      WHERE id = $2
    `, [amount, accountId]);

    const txRes = await client.query(`
      INSERT INTO transactions
        (account_id, user_id, type, status, amount, description, unit_transaction_id, metadata)
      VALUES ($1,$2,'debit','completed',-$3,$4,$5,$6)
      RETURNING *
    `, [
      accountId,
      userId,
      amount,
      encryptComplianceText(description || "Withdrawal", "transaction.description"),
      unitTxId,
      encryptComplianceJson(metadata || {}, "transaction.metadata"),
    ]);

    await ledger.recordWithdrawal({ userId, accountId, amount, description, unitTxId });

    return txRes.rows[0];
  });
}

// ═══════════════════════════════════════════════════════════
// COMPLIANT FEE COLLECTION
// ═══════════════════════════════════════════════════════════

async function collectFee({ userId, accountId, amount, feeType }) {
  assertBankEnabled("collectFee");
  const feeDescriptions = {
    wire:           "Wire transfer fee",
    monthly:        "Monthly service fee",
    crypto_spread:  "Crypto trading spread",
    ach_expedited:  "Expedited ACH fee",
    foreign_tx:     "Foreign transaction fee",
  };

  return withTransaction(async (client) => {
    await client.query(`
      UPDATE accounts SET balance = balance - $1 WHERE id = $2
    `, [amount, accountId]);

    await client.query(`
      INSERT INTO transactions
        (account_id, user_id, type, status, amount, description)
      VALUES ($1,$2,'fee','completed',-$3,$4)
    `, [accountId, userId, amount, encryptComplianceText(feeDescriptions[feeType] || `${feeType} fee`, "transaction.description")]);

    await ledger.recordFee({ userId, accountId, amount, feeType });
  });
}

// ═══════════════════════════════════════════════════════════
// UNIT.CO WEBHOOK HANDLER (routes events to correct processors)
// ═══════════════════════════════════════════════════════════

async function handleUnitWebhook(event) {
  assertBankEnabled("handleUnitWebhook");
  const { type, data } = event;
  logger.info(`Unit.co webhook: ${type}`);

  // Look up our account from Unit's account ID
  const getAccountByUnit = async (unitAccountId) => {
    const res = await query("SELECT * FROM accounts WHERE unit_account_id=$1", [unitAccountId]);
    return res.rows[0];
  };

  const getUserByAccount = async (accountId) => {
    const res = await query("SELECT user_id FROM accounts WHERE id=$1", [accountId]);
    return res.rows[0]?.user_id;
  };

  switch (type) {
    case "transaction.created": {
      const attrs = data.attributes;
      const acct  = await getAccountByUnit(data.relationships?.account?.data?.id);
      if (!acct) { logger.warn(`Account not found for Unit event ${type}`); break; }
      const userId = await getUserByAccount(acct.id);
      const amount = attrs.amount / 100;

      if (attrs.direction === "Credit") {
        await processDeposit({ userId, accountId:acct.id, amount, unitTxId:data.id, description:attrs.summary });
      } else {
        await processWithdrawal({ userId, accountId:acct.id, amount, unitTxId:data.id, description:attrs.summary });
      }
      break;
    }

    case "payment.returned": {
      // NACHA return
      const returnCode = data.attributes?.returnReason;
      if (returnCode) {
        await disputes.handleNACHAReturn(returnCode, null, data.id);
      }
      break;
    }

    case "card.transaction.created": {
      // Card swipe — record interchange
      const attrs    = data.attributes;
      const acct     = await getAccountByUnit(data.relationships?.account?.data?.id);
      if (!acct) break;
      const userId   = await getUserByAccount(acct.id);
      const amount   = attrs.amount / 100;
      const interchange = amount * 0.0175; // ~1.75% interchange estimate

      await processWithdrawal({ userId, accountId:acct.id, amount, unitTxId:data.id, description:attrs.merchant?.name||"Card purchase" });
      await ledger.recordLedgerTransaction({
        description: `Interchange — ${attrs.merchant?.name}`,
        externalId:  `ic-${data.id}`,
        effectiveAt: new Date(),
        entries: [
          { account:"interchange_receivable", direction:"debit",  amount: interchange },
          { account:"interchange_revenue",    direction:"credit", amount: interchange },
        ],
      });
      break;
    }

    case "application.denied": {
      // KYC rejected at bank layer — update our records
      const customerId = data.id;
      await query(
        "UPDATE users SET status='suspended', kyc_status='rejected' WHERE unit_customer_id=$1",
        [customerId]
      );
      break;
    }

    case "account.frozen": {
      const acct = await getAccountByUnit(data.relationships?.account?.data?.id);
      if (acct) {
        await query("UPDATE accounts SET status='frozen' WHERE id=$1", [acct.id]);
        logger.warn(`Account ${acct.id} frozen by Unit.co`);
      }
      break;
    }

    default:
      logger.debug(`Unhandled Unit.co webhook: ${type}`);
  }
}

// ═══════════════════════════════════════════════════════════
// MERCHANT PAYMENT PROCESSING (Stripe)
// ═══════════════════════════════════════════════════════════

async function handleStripeWebhook(event) {
  assertBankEnabled("handleStripeWebhook");
  const { type, data } = event;

  switch (type) {
    case "payment_intent.succeeded": {
      const pi     = data.object;
      const userId = pi.metadata?.userId;
      const accountId = pi.metadata?.accountId;
      if (!userId || !accountId) break;

      await processDeposit({
        userId, accountId,
        amount:      pi.amount_received / 100,
        description: `Payment received — ${pi.id}`,
        metadata:    { stripePaymentIntentId: pi.id, source: "stripe" },
      });
      break;
    }

    case "charge.dispute.created": {
      // Stripe chargeback — auto-file dispute
      const charge = data.object;
      const userId = charge.metadata?.userId;
      const accountId = charge.metadata?.accountId;
      if (!userId || !accountId) break;

      await disputes.fileDispute({
        userId, accountId,
        disputeType:     "merchant_fraud",
        amount:          charge.amount / 100,
        description:     `Stripe chargeback: ${charge.failure_message||"Dispute filed"}`,
        merchantName:    charge.merchant_name||"Unknown",
        transactionDate: new Date(charge.created * 1000).toISOString(),
      });
      break;
    }

    case "payout.paid": {
      // Stripe settled funds to our bank account
      const payout = data.object;
      await ledger.recordLedgerTransaction({
        description: `Stripe payout settled: ${payout.id}`,
        externalId:  payout.id,
        effectiveAt: new Date(payout.arrival_date * 1000),
        entries: [
          { account:"cash_and_equivalents", direction:"debit",  amount: payout.amount/100 },
          { account:"payables",             direction:"credit", amount: payout.amount/100 },
        ],
      });
      break;
    }
  }
}

// ═══════════════════════════════════════════════════════════
// SAR TRIGGER (Suspicious Activity Report)
// ═══════════════════════════════════════════════════════════

async function checkForSuspiciousActivity(userId, transaction) {
  const flags = [];

  // Pattern: multiple large transactions in 24 hours
  const recentLarge = await query(`
    SELECT COUNT(*) as count, SUM(ABS(amount)) as total
    FROM transactions
    WHERE user_id = $1
      AND created_at > NOW() - INTERVAL '24 hours'
      AND ABS(amount) > 5000
      AND status = 'completed'
  `, [userId]);

  if (parseInt(recentLarge.rows[0].count) >= 3) {
    flags.push({ rule:"MULTIPLE_LARGE_24H", detail:`${recentLarge.rows[0].count} transactions totaling $${recentLarge.rows[0].total}` });
  }

  // Pattern: structuring (multiple transactions just under $10,000)
  const structuring = await query(`
    SELECT COUNT(*) as count
    FROM transactions
    WHERE user_id = $1
      AND created_at > NOW() - INTERVAL '7 days'
      AND ABS(amount) BETWEEN 8000 AND 9999
      AND type IN ('credit','debit')
  `, [userId]);

  if (parseInt(structuring.rows[0].count) >= 3) {
    flags.push({ rule:"POTENTIAL_STRUCTURING", detail:`${structuring.rows[0].count} transactions $8K-$10K in 7 days` });
  }

  // Pattern: rapid account drain
  const acctBalance = await query("SELECT balance FROM accounts WHERE user_id=$1 ORDER BY is_primary DESC LIMIT 1", [userId]);
  if (acctBalance.rows[0] && Math.abs(transaction.amount) > acctBalance.rows[0].balance * 0.8) {
    flags.push({ rule:"LARGE_WITHDRAWAL_PCT", detail:`Transaction is >80% of account balance` });
  }

  if (flags.length > 0) {
    // Flag transaction
    await query(`
      UPDATE transactions SET is_flagged=TRUE, flag_reason=$1 WHERE id=$2
    `, [JSON.stringify(flags), transaction.id]);

    // Log for compliance team
    await query(`
      INSERT INTO audit_log (user_id, action, resource_type, resource_id, new_value)
      VALUES ($1,'compliance.sar_trigger','transaction',$2,$3)
    `, [userId, transaction.id, JSON.stringify(flags)]);

    // Alert compliance officer
    const emailService = require("../services/emailService");
    await emailService.sendEmail(
      process.env.COMPLIANCE_EMAIL,
      `⚠️ SAR Trigger — User ${userId}`,
      `<p>Suspicious activity patterns detected for user <strong>${userId}</strong>:</p>
       <ul>${flags.map(f=>`<li><strong>${f.rule}</strong>: ${f.detail}</li>`).join("")}</ul>
       <p>Transaction: ${transaction.id} — $${Math.abs(transaction.amount)}</p>
       <p>Review required within 30 days. File SAR via FinCEN if warranted.</p>`
    );

    logger.warn(`SAR trigger for user ${userId}: ${flags.map(f=>f.rule).join(", ")}`);
  }

  return flags;
}

// ═══════════════════════════════════════════════════════════
// .ENV ADDITIONS NEEDED
// ═══════════════════════════════════════════════════════════

const ENV_ADDITIONS = `
# ── Modern Treasury ──
# Get from: https://app.moderntreasury.com/developers/api-keys
MODERN_TREASURY_API_KEY=your_mt_api_key
MODERN_TREASURY_ORG_ID=your_mt_org_id
MODERN_TREASURY_WEBHOOK_KEY=your_mt_webhook_key

# ── Compliance emails ──
COMPLIANCE_EMAIL=compliance@onewaybank.com
BSA_OFFICER_EMAIL=bsa@onewaybank.com

# ── Dispute settings ──
MAX_DISPUTE_AMOUNT=50000
AUTO_PROVISIONAL_CREDIT_THRESHOLD=5000
`;

module.exports = {
  initializeCompliance,
  processDeposit,
  processWithdrawal,
  collectFee,
  handleUnitWebhook,
  handleStripeWebhook,
  checkForSuspiciousActivity,
  // Re-export sub-modules
  ledger,
  disputes,
  settlement,
};
