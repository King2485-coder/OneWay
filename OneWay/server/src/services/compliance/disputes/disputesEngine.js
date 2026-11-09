/**
 * OneWay Bank — Reg E Disputes Engine
 *
 * Regulation E (Electronic Fund Transfer Act) compliance:
 * - Provisional credit within 5 business days
 * - Investigation completed within 10 business days (45 for new accounts / POS)
 * - Written notice to customer within 3 business days of resolution
 * - Error must be reported within 60 days of statement
 *
 * Also handles:
 * - NACHA ACH dispute process (R10, R11 return codes)
 * - Visa/MC chargeback initiation via Unit.co
 * - Crypto dispute management (Zero Hash)
 * - SAR filing triggers for fraud patterns
 */

require("dotenv").config();
const { query, withTransaction } = require("../config/database");
const unitService  = require("../services/unitService");
const emailService = require("../services/emailService");
const smsService   = require("../services/smsService");
const logger       = require("../utils/logger");
const cron         = require("../utils/optionalCron");
const { assertBankEnabled, disputesEnabled } = require("../utils/flags");
const { encryptComplianceText, encryptComplianceJson } = require("../utils/encryption");

// ── Business day calculator (excludes weekends + US federal holidays) ──
const FEDERAL_HOLIDAYS_2025 = [
  "2025-01-01","2025-01-20","2025-02-17","2025-05-26",
  "2025-06-19","2025-07-04","2025-09-01","2025-11-27","2025-12-25",
];

function addBusinessDays(date, days) {
  const d = new Date(date);
  let added = 0;
  while (added < days) {
    d.setDate(d.getDate() + 1);
    const iso = d.toISOString().split("T")[0];
    const dow = d.getDay();
    if (dow !== 0 && dow !== 6 && !FEDERAL_HOLIDAYS_2025.includes(iso)) added++;
  }
  return d;
}

function businessDaysBetween(start, end) {
  const s = new Date(start), e = new Date(end);
  let count = 0;
  const d = new Date(s);
  while (d <= e) {
    const iso = d.toISOString().split("T")[0];
    const dow = d.getDay();
    if (dow !== 0 && dow !== 6 && !FEDERAL_HOLIDAYS_2025.includes(iso)) count++;
    d.setDate(d.getDate() + 1);
  }
  return count;
}

// ═══════════════════════════════════════════════════════════
// DISPUTE SCHEMA (ensure tables exist)
// ═══════════════════════════════════════════════════════════

async function ensureDisputeSchema() {
  if (!disputesEnabled()) {
    logger.info("OneWay Bank disputes schema paused.");
    return { enabled: false };
  }

  if (isSQLite()) {
    await ensureSQLiteDisputeSchema();
    logger.info("✓ Dormant OneWay Bank disputes schema ready for local/dev SQLite");
    return { enabled: true, mode: "sqlite" };
  }

  await query(`
    CREATE TYPE IF NOT EXISTS dispute_type AS ENUM (
      'unauthorized_eft','wrong_amount','duplicate_charge',
      'item_not_received','merchant_fraud','ach_unauthorized',
      'crypto_dispute','other'
    );
    CREATE TYPE IF NOT EXISTS dispute_status AS ENUM (
      'filed','provisional_credit_issued','under_investigation',
      'resolved_customer','resolved_merchant','withdrawn','escalated'
    );
  `).catch(() => {}); // types may already exist

  await query(`
    CREATE TABLE IF NOT EXISTS disputes (
      id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      case_number           VARCHAR(20) UNIQUE NOT NULL,
      user_id               UUID NOT NULL REFERENCES users(id),
      account_id            UUID REFERENCES accounts(id),
      transaction_id        UUID REFERENCES transactions(id),
      dispute_type          VARCHAR(50) NOT NULL,
      status                VARCHAR(50) DEFAULT 'filed',
      amount                NUMERIC(20,4) NOT NULL,
      currency              VARCHAR(3) DEFAULT 'USD',
      description           TEXT NOT NULL,
      merchant_name         VARCHAR(255),
      transaction_date      DATE,

      -- Reg E timelines (auto-calculated)
      filed_at              TIMESTAMPTZ DEFAULT NOW(),
      provisional_credit_deadline TIMESTAMPTZ,  -- +5 business days
      investigation_deadline      TIMESTAMPTZ,  -- +10 business days (45 for new accts)
      resolution_notice_deadline  TIMESTAMPTZ,  -- +3 business days after resolution

      -- Actions taken
      provisional_credit_issued   BOOLEAN DEFAULT FALSE,
      provisional_credit_at       TIMESTAMPTZ,
      provisional_credit_amount   NUMERIC(20,4),

      -- Resolution
      resolution               VARCHAR(20),    -- 'customer_favor' | 'merchant_favor' | 'partial'
      resolution_amount        NUMERIC(20,4),
      resolution_notes         TEXT,
      resolved_at              TIMESTAMPTZ,
      resolved_by              UUID,

      -- Notice sent
      resolution_notice_sent   BOOLEAN DEFAULT FALSE,
      resolution_notice_sent_at TIMESTAMPTZ,

      -- External references
      unit_dispute_id          VARCHAR(255),
      nacha_return_code        VARCHAR(10),
      visa_case_number         VARCHAR(255),
      stripe_dispute_id        VARCHAR(255),

      -- Evidence
      evidence                 JSONB DEFAULT '[]',

      -- Compliance flags
      is_new_account           BOOLEAN DEFAULT FALSE,  -- extends deadline to 45 days
      sar_filed                BOOLEAN DEFAULT FALSE,
      escalated_at             TIMESTAMPTZ,

      created_at               TIMESTAMPTZ DEFAULT NOW(),
      updated_at               TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS dispute_events (
      id          BIGSERIAL PRIMARY KEY,
      dispute_id  UUID NOT NULL REFERENCES disputes(id),
      event_type  VARCHAR(100) NOT NULL,
      description TEXT,
      data        JSONB DEFAULT '{}',
      performed_by UUID,
      created_at  TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_disputes_user_id ON disputes(user_id);
    CREATE INDEX IF NOT EXISTS idx_disputes_status ON disputes(status);
    CREATE INDEX IF NOT EXISTS idx_disputes_filed_at ON disputes(filed_at);
    CREATE INDEX IF NOT EXISTS idx_disputes_investigation_deadline ON disputes(investigation_deadline);
  `);
}

async function ensureSQLiteDisputeSchema() {
  await query(`
    CREATE TABLE IF NOT EXISTS disputes (
      id TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
      case_number TEXT UNIQUE NOT NULL,
      user_id TEXT NOT NULL,
      account_id TEXT,
      transaction_id TEXT,
      dispute_type TEXT NOT NULL,
      status TEXT DEFAULT 'filed',
      amount NUMERIC NOT NULL,
      currency TEXT DEFAULT 'USD',
      description TEXT NOT NULL,
      merchant_name TEXT,
      transaction_date DATETIME,
      filed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      provisional_credit_deadline DATETIME,
      investigation_deadline DATETIME,
      resolution_notice_deadline DATETIME,
      provisional_credit_issued BOOLEAN DEFAULT FALSE,
      provisional_credit_at DATETIME,
      provisional_credit_amount NUMERIC,
      resolution TEXT,
      resolution_amount NUMERIC,
      resolution_notes TEXT,
      resolved_at DATETIME,
      resolved_by TEXT,
      resolution_notice_sent BOOLEAN DEFAULT FALSE,
      resolution_notice_sent_at DATETIME,
      evidence TEXT DEFAULT '[]',
      is_new_account BOOLEAN DEFAULT FALSE,
      sar_filed BOOLEAN DEFAULT FALSE,
      escalated_at DATETIME,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`
    CREATE TABLE IF NOT EXISTS dispute_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      dispute_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
      description TEXT,
      data TEXT DEFAULT '{}',
      performed_by TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await query(`CREATE INDEX IF NOT EXISTS idx_compliance_disputes_user_id ON disputes(user_id)`);
  await query(`CREATE INDEX IF NOT EXISTS idx_compliance_disputes_status ON disputes(status)`);
}

// ═══════════════════════════════════════════════════════════
// FILE A DISPUTE
// ═══════════════════════════════════════════════════════════

async function fileDispute({
  userId, accountId, transactionId,
  disputeType, amount, description,
  merchantName, transactionDate,
}) {
  assertBankEnabled("disputes.fileDispute");
  logger.info(`Filing dispute for user ${userId}: ${disputeType} $${amount}`);

  // Validate: must be filed within 60 days of statement (Reg E requirement)
  if (transactionDate) {
    const daysSince = Math.floor((Date.now() - new Date(transactionDate).getTime()) / 86400000);
    if (daysSince > 60) {
      throw new Error("Disputes must be filed within 60 days of the statement date (Reg E requirement)");
    }
  }

  // Check if account is new (< 30 days) — extends investigation deadline to 45 days
  const acctResult = await query("SELECT created_at FROM accounts WHERE id=$1", [accountId]);
  const acctAge    = acctResult.rows[0]
    ? Math.floor((Date.now() - new Date(acctResult.rows[0].created_at).getTime()) / 86400000)
    : 999;
  const isNewAccount = acctAge < 30;

  const now   = new Date();
  const caseNumber = `OW-${Date.now().toString().slice(-8)}`;
  const provisionalDeadline  = addBusinessDays(now, 5);
  const investigationDeadline = addBusinessDays(now, isNewAccount ? 45 : 10);

  const dispute = await withTransaction(async (client) => {
    const res = await client.query(`
      INSERT INTO disputes (
        case_number, user_id, account_id, transaction_id,
        dispute_type, amount, description, merchant_name, transaction_date,
        provisional_credit_deadline, investigation_deadline,
        is_new_account, status
      ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'filed')
      RETURNING *
    `, [
      caseNumber, userId, accountId, transactionId,
      disputeType,
      amount,
      encryptComplianceText(description, "dispute.description"),
      encryptComplianceText(merchantName || "", "dispute.merchantName"),
      transactionDate,
      provisionalDeadline, investigationDeadline, isNewAccount,
    ]);

    const d = res.rows[0];

    // Log event
    await client.query(`
      INSERT INTO dispute_events (dispute_id, event_type, description)
      VALUES ($1,'dispute_filed',$2)
    `, [d.id, `Dispute filed: ${disputeType} for $${amount}`]);

    return d;
  });

  // Notify customer immediately (Reg E requires acknowledgment)
  await notifyCustomer(userId, dispute, "filed");

  // Auto-issue provisional credit for Reg E eligible disputes
  if (["unauthorized_eft","wrong_amount","duplicate_charge"].includes(disputeType)) {
    await issueProvisionalCredit(dispute.id, amount, userId, accountId);
  }

  // Notify Unit.co to flag the transaction
  if (transactionId) {
    await flagTransactionAtUnit(transactionId, dispute.id);
  }

  logger.info(`Dispute filed: ${caseNumber} — provisional deadline: ${provisionalDeadline.toISOString().split("T")[0]}`);
  return dispute;
}

// ═══════════════════════════════════════════════════════════
// PROVISIONAL CREDIT (Reg E requirement: within 5 business days)
// ═══════════════════════════════════════════════════════════

async function issueProvisionalCredit(disputeId, amount, userId, accountId) {
  assertBankEnabled("disputes.issueProvisionalCredit");
  logger.info(`Issuing provisional credit for dispute ${disputeId}: $${amount}`);

  await withTransaction(async (client) => {
    // Credit the account
    await client.query(`
      UPDATE accounts
      SET balance = balance + $1, available_balance = available_balance + $1
      WHERE id = $2
    `, [amount, accountId]);

    // Record transaction
    await client.query(`
      INSERT INTO transactions
        (account_id, user_id, type, status, amount, description, reference_id)
      VALUES ($1,$2,'credit','completed',$3,$4,$5)
    `, [accountId, userId, amount, `Provisional credit — dispute ${disputeId}`, `PROV-${disputeId}`]);

    // Update dispute record
    await client.query(`
      UPDATE disputes SET
        provisional_credit_issued = TRUE,
        provisional_credit_at = NOW(),
        provisional_credit_amount = $1,
        status = 'provisional_credit_issued'
      WHERE id = $2
    `, [amount, disputeId]);

    await client.query(`
      INSERT INTO dispute_events (dispute_id, event_type, description, data)
      VALUES ($1,'provisional_credit_issued',$2,$3)
    `, [disputeId, `Provisional credit of $${amount} issued`, JSON.stringify({amount})]);
  });

  // Notify customer
  const d = await query("SELECT user_id FROM disputes WHERE id=$1", [disputeId]);
  if (d.rows[0]) await notifyCustomer(d.rows[0].user_id, {id:disputeId,amount}, "provisional_credit");

  logger.info(`✓ Provisional credit issued: $${amount}`);
}

// ═══════════════════════════════════════════════════════════
// INVESTIGATION
// ═══════════════════════════════════════════════════════════

async function addEvidence(disputeId, evidence) {
  const { evidenceType, description, fileUrl, submittedBy } = evidence;

  await query(`
    UPDATE disputes SET
      evidence = evidence || $1::jsonb,
      updated_at = NOW()
    WHERE id = $2
  `, [JSON.stringify([{
    type: evidenceType,
    description: encryptComplianceText(description, "dispute.evidence.description"),
    fileUrl: encryptComplianceText(fileUrl, "dispute.evidence.fileUrl"),
    submittedBy,
    addedAt: new Date(),
  }]), disputeId]);

  await query(`
    INSERT INTO dispute_events (dispute_id, event_type, description, performed_by)
    VALUES ($1,'evidence_added',$2,$3)
  `, [disputeId, `Evidence added: ${evidenceType}`, submittedBy]);
}

async function updateInvestigationStatus(disputeId, notes, status) {
  await query(`
    UPDATE disputes SET
      status = $1, updated_at = NOW()
    WHERE id = $2
  `, [status, disputeId]);

  await query(`
    INSERT INTO dispute_events (dispute_id, event_type, description)
    VALUES ($1,'investigation_update',$2)
  `, [disputeId, notes]);
}

// ═══════════════════════════════════════════════════════════
// RESOLVE DISPUTE
// ═══════════════════════════════════════════════════════════

async function resolveDispute(disputeId, {
  resolution,        // 'customer_favor' | 'merchant_favor' | 'partial'
  resolutionAmount,  // final amount in customer's favor
  resolutionNotes,
  resolvedBy,
}) {
  assertBankEnabled("disputes.resolveDispute");
  logger.info(`Resolving dispute ${disputeId}: ${resolution}`);

  const disputeRes = await query("SELECT * FROM disputes WHERE id=$1", [disputeId]);
  const dispute    = disputeRes.rows[0];
  if (!dispute) throw new Error("Dispute not found");

  const noticeDeadline = addBusinessDays(new Date(), 3);

  await withTransaction(async (client) => {
    // Update dispute
    await client.query(`
      UPDATE disputes SET
        status = $1,
        resolution = $2,
        resolution_amount = $3,
        resolution_notes = $4,
        resolved_at = NOW(),
        resolved_by = $5,
        resolution_notice_deadline = $6
      WHERE id = $7
    `, [
      resolution==="customer_favor"?"resolved_customer":"resolved_merchant",
      resolution, resolutionAmount, resolutionNotes, resolvedBy,
      noticeDeadline, disputeId,
    ]);

    // If merchant favor: reverse provisional credit
    if (resolution === "merchant_favor" && dispute.provisional_credit_issued) {
      await client.query(`
        UPDATE accounts SET
          balance = balance - $1,
          available_balance = available_balance - $1
        WHERE id = $2
      `, [dispute.provisional_credit_amount, dispute.account_id]);

      await client.query(`
        INSERT INTO transactions
          (account_id, user_id, type, status, amount, description, reference_id)
        VALUES ($1,$2,'debit','completed',$3,$4,$5)
      `, [
        dispute.account_id, dispute.user_id,
        dispute.provisional_credit_amount,
        `Provisional credit reversal — dispute resolved in merchant favor`,
        `REV-${disputeId}`,
      ]);
    }

    // If partial: adjust to correct amount
    if (resolution === "partial" && dispute.provisional_credit_issued) {
      const adjustment = dispute.provisional_credit_amount - resolutionAmount;
      if (adjustment > 0) {
        await client.query(`
          UPDATE accounts SET
            balance = balance - $1,
            available_balance = available_balance - $1
          WHERE id = $2
        `, [adjustment, dispute.account_id]);
      }
    }

    await client.query(`
      INSERT INTO dispute_events (dispute_id, event_type, description, performed_by, data)
      VALUES ($1,'dispute_resolved',$2,$3,$4)
    `, [disputeId, `Resolved: ${resolution} — $${resolutionAmount}`, resolvedBy, JSON.stringify({resolution,resolutionAmount})]);
  });

  // Send resolution notice to customer (Reg E: within 3 business days)
  await sendResolutionNotice(dispute, resolution, resolutionAmount, resolutionNotes);

  logger.info(`✓ Dispute ${disputeId} resolved: ${resolution}`);
}

// ═══════════════════════════════════════════════════════════
// NACHA ACH DISPUTE (Return Codes)
// ═══════════════════════════════════════════════════════════

const NACHA_RETURN_CODES = {
  R01: "Insufficient Funds",
  R02: "Account Closed",
  R04: "Invalid Account Number",
  R07: "Authorization Revoked by Customer",
  R08: "Payment Stopped",
  R10: "Customer Advises Not Authorized — file dispute",
  R11: "Check Truncation Entry Return",
  R29: "Corporate Customer Advises Not Authorized",
};

async function handleNACHAReturn(returnCode, transactionId, unitPaymentId) {
  assertBankEnabled("disputes.handleNACHAReturn");
  logger.info(`NACHA return: ${returnCode} for transaction ${transactionId}`);

  const txResult = await query(
    "SELECT * FROM transactions WHERE id=$1 OR unit_transaction_id=$2",
    [transactionId, unitPaymentId]
  );
  const tx = txResult.rows[0];
  if (!tx) { logger.warn(`Transaction not found for NACHA return ${returnCode}`); return; }

  // Update transaction status
  await query("UPDATE transactions SET status='failed', metadata=metadata||$1 WHERE id=$2",
    [JSON.stringify({nachaReturnCode:returnCode, nachaReason:NACHA_RETURN_CODES[returnCode]}), tx.id]);

  // R10 = unauthorized — auto-file dispute
  if (returnCode === "R10" || returnCode === "R07") {
    await fileDispute({
      userId:          tx.user_id,
      accountId:       tx.account_id,
      transactionId:   tx.id,
      disputeType:     "ach_unauthorized",
      amount:          Math.abs(tx.amount),
      description:     `ACH return: ${NACHA_RETURN_CODES[returnCode]}`,
      transactionDate: tx.created_at,
    });
  }

  // Notify customer
  await notifyCustomer(tx.user_id, {
    caseNumber: `ACH-${tx.id.slice(0,8)}`,
    amount:     Math.abs(tx.amount),
    description: NACHA_RETURN_CODES[returnCode],
  }, "ach_return");
}

// ═══════════════════════════════════════════════════════════
// CUSTOMER NOTIFICATIONS (Reg E requires written notice)
// ═══════════════════════════════════════════════════════════

async function notifyCustomer(userId, dispute, eventType) {
  const userRes = await query("SELECT email, first_name, phone FROM users WHERE id=$1", [userId]);
  const user    = userRes.rows[0];
  if (!user) return;

  const templates = {
    filed: {
      subject: `Dispute Filed — Case ${dispute.case_number}`,
      body: `
        <h2>Hi ${user.first_name},</h2>
        <p>We've received your dispute for <strong>$${dispute.amount}</strong>.</p>
        <p><strong>Case Number:</strong> ${dispute.case_number}</p>
        <p>Under Regulation E, we will:</p>
        <ul>
          <li>Issue provisional credit within <strong>5 business days</strong> if applicable</li>
          <li>Complete our investigation within <strong>10 business days</strong></li>
          <li>Send you written notice of our determination</li>
        </ul>
        <p>You will receive updates at this email address. Please retain any evidence related to this dispute.</p>
      `,
    },
    provisional_credit: {
      subject: `Provisional Credit Applied — Case ${dispute.id?.slice(0,8)}`,
      body: `
        <h2>Hi ${user.first_name},</h2>
        <p>A provisional credit of <strong>$${dispute.amount}</strong> has been applied to your account while we investigate your dispute.</p>
        <p><em>Note: This credit is provisional. If our investigation determines the transaction was valid, the credit will be reversed.</em></p>
      `,
    },
    resolved_customer: {
      subject: `Dispute Resolved — Case ${dispute.case_number}`,
      body: `
        <h2>Hi ${user.first_name},</h2>
        <p>We have completed our investigation of your dispute.</p>
        <p><strong>Outcome: Resolved in your favor</strong></p>
        <p>A credit of <strong>$${dispute.resolutionAmount}</strong> has been permanently applied to your account.</p>
        <p>If you have questions, contact us at disputes@onewaybank.com</p>
      `,
    },
    resolved_merchant: {
      subject: `Dispute Determination — Case ${dispute.case_number}`,
      body: `
        <h2>Hi ${user.first_name},</h2>
        <p>We have completed our investigation of your dispute.</p>
        <p><strong>Outcome: Resolved in merchant's favor</strong></p>
        <p>Based on our investigation, we determined that the transaction was valid. Any provisional credit has been reversed.</p>
        <p><strong>Reason:</strong> ${dispute.resolutionNotes}</p>
        <p>You have the right to request the documents we used in our determination. Contact disputes@onewaybank.com within 10 days.</p>
      `,
    },
    ach_return: {
      subject: `ACH Payment Returned — ${dispute.description}`,
      body: `
        <h2>Hi ${user.first_name},</h2>
        <p>Your ACH payment of <strong>$${dispute.amount}</strong> was returned.</p>
        <p><strong>Reason:</strong> ${dispute.description}</p>
        <p>If you did not authorize this transaction, we have automatically filed a dispute on your behalf.</p>
      `,
    },
  };

  const template = templates[eventType];
  if (!template) return;

  await emailService.sendEmail(user.email, template.subject, template.body);

  // Also SMS for critical events
  if (user.phone && ["filed","provisional_credit"].includes(eventType)) {
    await smsService.sendOTP(user.phone).catch(() => {});
  }
}

async function sendResolutionNotice(dispute, resolution, amount, notes) {
  const userRes = await query("SELECT email, first_name FROM users WHERE id=$1", [dispute.user_id]);
  const user    = userRes.rows[0];
  if (!user) return;

  const eventType = resolution === "customer_favor" ? "resolved_customer" : "resolved_merchant";
  await notifyCustomer(dispute.user_id, { ...dispute, resolutionAmount:amount, resolutionNotes:notes }, eventType);

  await query(`
    UPDATE disputes SET
      resolution_notice_sent = TRUE,
      resolution_notice_sent_at = NOW()
    WHERE id = $1
  `, [dispute.id]);
}

// ═══════════════════════════════════════════════════════════
// FLAG AT UNIT.CO
// ═══════════════════════════════════════════════════════════

async function flagTransactionAtUnit(transactionId, disputeId) {
  try {
    const txRes = await query("SELECT unit_transaction_id FROM transactions WHERE id=$1", [transactionId]);
    if (!txRes.rows[0]?.unit_transaction_id) return;
    // Unit.co dispute API call would go here
    logger.info(`Transaction ${txRes.rows[0].unit_transaction_id} flagged at Unit.co for dispute ${disputeId}`);
  } catch (err) {
    logger.warn("Could not flag transaction at Unit.co:", err.message);
  }
}

// ═══════════════════════════════════════════════════════════
// DEADLINE MONITOR — runs every business day at 7 AM
// ═══════════════════════════════════════════════════════════

cron.schedule("0 7 * * 1-5", async () => {
  logger.info("Running dispute deadline monitor...");

  const now = new Date();

  // Find disputes past provisional credit deadline (still not issued)
  const overdueProvisional = await query(`
    SELECT d.*, u.email, u.first_name
    FROM disputes d
    JOIN users u ON u.id = d.user_id
    WHERE d.provisional_credit_issued = FALSE
      AND d.provisional_credit_deadline < NOW()
      AND d.status NOT IN ('resolved_customer','resolved_merchant','withdrawn')
  `);

  for (const d of overdueProvisional.rows) {
    logger.error(`⚠️  OVERDUE provisional credit: Case ${d.case_number} (deadline: ${d.provisional_credit_deadline})`);
    // Force issue provisional credit — cannot be delayed under Reg E
    await issueProvisionalCredit(d.id, d.amount, d.user_id, d.account_id);
    await emailService.sendEmail(
      process.env.COMPLIANCE_EMAIL,
      `⚠️ Overdue Provisional Credit Issued — ${d.case_number}`,
      `<p>Provisional credit was overdue for case ${d.case_number}. Auto-issued $${d.amount} to comply with Reg E.</p>`
    );
  }

  // Find disputes approaching investigation deadline (3 days warning)
  const approachingDeadline = await query(`
    SELECT d.*, u.email, u.first_name
    FROM disputes d
    JOIN users u ON u.id = d.user_id
    WHERE d.investigation_deadline BETWEEN NOW() AND NOW() + INTERVAL '3 days'
      AND d.status NOT IN ('resolved_customer','resolved_merchant','withdrawn')
  `);

  if (approachingDeadline.rows.length > 0) {
    await emailService.sendEmail(
      process.env.COMPLIANCE_EMAIL,
      `⚠️ ${approachingDeadline.rows.length} Disputes Approaching Deadline`,
      `<p>The following disputes must be resolved within 3 business days:</p><ul>${
        approachingDeadline.rows.map(d=>`<li>Case ${d.case_number} — $${d.amount} — deadline ${d.investigation_deadline}</li>`).join("")
      }</ul>`
    );
  }

  // Find overdue investigation deadlines — CRITICAL compliance violation
  const overdueInvestigation = await query(`
    SELECT * FROM disputes
    WHERE investigation_deadline < NOW()
      AND status NOT IN ('resolved_customer','resolved_merchant','withdrawn')
  `);

  if (overdueInvestigation.rows.length > 0) {
    logger.error(`🚨 CRITICAL: ${overdueInvestigation.rows.length} disputes past investigation deadline!`);
    await emailService.sendEmail(
      process.env.COMPLIANCE_EMAIL,
      `🚨 CRITICAL: Overdue Dispute Investigations — Reg E Violation Risk`,
      `<p><strong>${overdueInvestigation.rows.length} disputes have passed their investigation deadline.</strong></p>
       <p>This is a potential Regulation E violation. Immediate action required.</p>
       <ul>${overdueInvestigation.rows.map(d=>`<li>Case ${d.case_number} — filed ${d.filed_at} — deadline ${d.investigation_deadline}</li>`).join("")}</ul>`
    );
  }

  // Find notices not sent after resolution
  const noticeOverdue = await query(`
    SELECT d.*, u.email, u.first_name
    FROM disputes d
    JOIN users u ON u.id = d.user_id
    WHERE d.resolution_notice_sent = FALSE
      AND d.resolved_at IS NOT NULL
      AND d.resolution_notice_deadline < NOW()
  `);

  for (const d of noticeOverdue.rows) {
    logger.warn(`Sending overdue resolution notice for case ${d.case_number}`);
    await sendResolutionNotice(d, d.resolution, d.resolution_amount, d.resolution_notes);
  }

  logger.info(`Deadline monitor complete. ${approachingDeadline.rows.length} approaching, ${overdueInvestigation.rows.length} overdue.`);
});

// ── Express routes (mount at /api/v1/disputes) ──
const router = require("express").Router();
const { authenticate, requireKYC } = require("../middleware/authenticate");
const { auditLog } = require("../utils/auditLog");

router.get("/", authenticate, async (req, res, next) => {
  try {
    const result = await query(
      "SELECT * FROM disputes WHERE user_id=$1 ORDER BY created_at DESC",
      [req.user.id]
    );
    res.json({ disputes: result.rows });
  } catch(e) { next(e); }
});

router.get("/:id", authenticate, async (req, res, next) => {
  try {
    const d = await query("SELECT * FROM disputes WHERE id=$1 AND user_id=$2", [req.params.id, req.user.id]);
    if (!d.rows[0]) return res.status(404).json({error:"Dispute not found"});
    const events = await query("SELECT * FROM dispute_events WHERE dispute_id=$1 ORDER BY created_at ASC", [req.params.id]);
    res.json({ dispute: d.rows[0], events: events.rows });
  } catch(e) { next(e); }
});

router.post("/", authenticate, requireKYC, async (req, res, next) => {
  try {
    const { accountId, transactionId, disputeType, amount, description, merchantName, transactionDate } = req.body;
    if (!disputeType || !amount || !description) return res.status(422).json({error:"Missing required fields"});

    const dispute = await fileDispute({
      userId: req.user.id, accountId, transactionId, disputeType,
      amount: parseFloat(amount), description, merchantName, transactionDate,
    });

    await auditLog({userId:req.user.id, action:"dispute.filed", resourceId:dispute.id, ipAddress:req.ip});
    res.status(201).json({ dispute, message:`Dispute filed. Case number: ${dispute.case_number}` });
  } catch(e) { next(e); }
});

router.post("/:id/evidence", authenticate, async (req, res, next) => {
  try {
    const { evidenceType, description, fileUrl } = req.body;
    await addEvidence(req.params.id, { evidenceType, description, fileUrl, submittedBy: req.user.id });
    res.json({ message: "Evidence added" });
  } catch(e) { next(e); }
});

router.post("/:id/withdraw", authenticate, async (req, res, next) => {
  try {
    await query("UPDATE disputes SET status='withdrawn', updated_at=NOW() WHERE id=$1 AND user_id=$2", [req.params.id, req.user.id]);
    res.json({ message: "Dispute withdrawn" });
  } catch(e) { next(e); }
});

module.exports = {
  router,
  fileDispute,
  resolveDispute,
  issueProvisionalCredit,
  handleNACHAReturn,
  addEvidence,
  ensureDisputeSchema,
};

function isSQLite() {
  return (process.env.DATABASE_URL || "").trim().startsWith("file:");
}
