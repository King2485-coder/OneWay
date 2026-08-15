# OneWay Bank Compliance Layer (Dormant)

OneWay Bank is intentionally paused. Storefront payments currently use Stripe/payment links, manual paid/refunded states, and the existing storefront analytics flow.

Do not enable live OneWay Bank money movement until revenue, banking vendors, legal review, compliance staffing, and provider fees are covered.

Default flags keep everything off:

```env
ONEWAY_BANK_ENABLED=false
ONEWAY_BANK_MOCK_MODE=true
COMPLIANCE_LAYER_ENABLED=false
LEDGER_ENABLED=false
RECONCILIATION_ENABLED=false
DISPUTES_ENABLED=false
```

When disabled, `/api/v1/ledger` and `/api/v1/disputes` return:

```json
{
  "error": "oneway_bank_disabled",
  "message": "OneWay Bank is not active yet. Storefront payments currently use Stripe/payment links."
}
```

Future activation checklist:

- Modern Treasury contract, ledger/payment credentials, and webhook verification
- Unit or equivalent bank-platform partner
- Compliance email and BSA/escalation inboxes
- Bank partner approval
- Legal/compliance review for Reg E, BSA/AML, KYC/CIP, privacy, record retention, and customer disclosures
- Production incident response and reconciliation operations
- Explicit sign-off before `ONEWAY_BANK_ENABLED=true`

---

# OneWay Bank — Compliance Infrastructure

## What's Here

```
oneway-compliance/
├── settlement/
│   └── reconciliationEngine.js   Nightly settlement reconciliation
├── disputes/
│   └── disputesEngine.js         Reg E dispute management + Reg Z
├── ledger/
│   └── ledgerService.js          Double-entry ledger + Modern Treasury
└── shared/
    ├── complianceService.js      Integration layer — ties everything together
    └── compliance-schema.sql     PostgreSQL tables for all compliance data
```

---

## Setup

### 1. Run the schema
```sql
-- In Supabase SQL editor, paste compliance-schema.sql
```

### 2. Add env variables
```bash
# Modern Treasury
MODERN_TREASURY_API_KEY=your_key
MODERN_TREASURY_ORG_ID=your_org_id

# Compliance contacts
COMPLIANCE_EMAIL=compliance@onewaybank.com
BSA_OFFICER_EMAIL=bsa@onewaybank.com
```

### 3. Wire into your server (src/index.js)
```js
const compliance = require('./services/complianceService');

// On startup
await compliance.initializeCompliance();

// Wire webhooks
app.use('/api/v1/disputes', compliance.disputes.router);
app.use('/api/v1/ledger',   compliance.ledger.router);

// Handle Unit.co webhooks
app.post('/webhooks/unit', async (req, res) => {
  await compliance.handleUnitWebhook(JSON.parse(req.body));
  res.json({ received: true });
});

// Handle Stripe webhooks
app.post('/webhooks/stripe', async (req, res) => {
  await compliance.handleStripeWebhook(JSON.parse(req.body));
  res.json({ received: true });
});
```

### 4. Replace direct balance updates
```js
// ❌ BEFORE (unsafe — no ledger, no compliance)
await db.query("UPDATE accounts SET balance = balance + $1", [amount]);

// ✅ AFTER (compliant — records in ledger, fires SAR checks)
await compliance.processDeposit({ userId, accountId, amount, unitTxId });
await compliance.processWithdrawal({ userId, accountId, amount, unitTxId });
await compliance.collectFee({ userId, accountId, amount, feeType: "wire" });
```

---

## Settlement Reconciliation

Runs automatically every night at 2 AM via cron.

**Manual run:**
```bash
node settlement/reconciliationEngine.js 2024-12-15
```

**What it checks:**
- Unit.co net vs your internal ledger net → must match to $0.01
- Transaction count: every Unit.co transaction must be in your DB
- Fee totals: fees recorded in Unit must match your fee ledger
- Crypto: Zero Hash settlements vs internal crypto transactions

**Break severity:**
- `CRITICAL`: >$100 discrepancy → immediate email to compliance officer
- `MINOR`: <$100 → logged, reviewed next business day
- `ROUNDING`: <$0.01 → auto-resolved

---

## Disputes (Reg E)

### Filing a dispute
```js
const dispute = await compliance.disputes.fileDispute({
  userId, accountId, transactionId,
  disputeType: 'unauthorized_eft',  // or wrong_amount, duplicate_charge, etc.
  amount: 500.00,
  description: 'I did not authorize this transaction',
  merchantName: 'Unknown Merchant',
  transactionDate: '2024-12-10',
});
// → Case number issued
// → Provisional credit issued within 5 business days (auto)
// → Customer notified by email (Reg E requirement)
// → Investigation deadline set (10 days standard, 45 days new accounts)
```

### Resolving a dispute
```js
await compliance.disputes.resolveDispute(disputeId, {
  resolution: 'customer_favor',   // or 'merchant_favor' | 'partial'
  resolutionAmount: 500.00,
  resolutionNotes: 'Transaction confirmed unauthorized via IP analysis',
  resolvedBy: adminUserId,
});
// → Permanent credit applied
// → Resolution notice sent to customer (Reg E: within 3 business days)
// → Audit trail updated
```

### Automatic deadline enforcement
A cron job runs every business day at 7 AM:
- ⚠️  Issues overdue provisional credits automatically
- ⚠️  Alerts compliance officer on disputes approaching investigation deadline
- 🚨  Escalates overdue investigations (potential Reg E violation)
- 📧  Sends overdue resolution notices

---

## Ledger

Every dollar movement creates TWO ledger entries that sum to zero.

### Examples

**Customer deposits $1,000:**
```
DEBIT  cash_and_equivalents        $1,000
CREDIT customer_deposits_liability $1,000
```

**Customer buys $500 of BTC (0.5% spread = $2.50 fee):**
```
DEBIT  crypto_custody_asset        $500.00
CREDIT customer_deposits_liability $497.50  (net to customer)
CREDIT crypto_spread_revenue       $2.50    (our revenue)
```

**Provisional dispute credit for $300:**
```
DEBIT  provisional_credits_asset   $300
CREDIT customer_deposits_liability $300
```

**If dispute resolved in merchant favor (reverse it):**
```
DEBIT  customer_deposits_liability $300
CREDIT provisional_credits_asset   $300
```

### Trial balance
```bash
GET /api/v1/ledger/trial-balance
# Returns all accounts with balances
# totalDebits must equal totalCredits (always)
```

---

## Compliance Timeline Summary

| Event | Deadline | Who acts |
|---|---|---|
| Dispute filed | Immediate | System: send acknowledgment |
| Provisional credit | 5 business days | System: auto-issues |
| Investigation | 10 business days (45 new accts) | Compliance team |
| Resolution notice | 3 business days after resolution | System: auto-sends |
| Settlement reconciliation | Before next business day | System: runs at 2 AM |
| SAR filing (if warranted) | 30 days of detection | BSA Officer |
| CTR filing (>$10K cash) | 15 days | System: auto-files via Unit |

---

## Data Retention (Required by Law)

| Data | Retention | Law |
|---|---|---|
| Transaction records | 5 years | BSA |
| Dispute records | 7 years | Reg E |
| Ledger entries | 7 years | SOX |
| Reconciliation reports | 7 years | SOX |
| SAR records | 5 years | BSA |
| Customer identification | 5 years post-close | CIP/KYC |
| Audit logs | 7 years | SOX |

**The `ledger_entries` table has a database trigger that makes updates and deletes impossible.
Records can only be reversed via new entries — never modified.**
