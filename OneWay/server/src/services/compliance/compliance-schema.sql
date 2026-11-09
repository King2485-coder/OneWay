-- ════════════════════════════════════════════════════════
-- ONEWAY BANK — COMPLIANCE SCHEMA ADDITIONS
-- Add to existing schema.sql or run separately
-- ════════════════════════════════════════════════════════

-- ── LEDGER ACCOUNTS ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ledger_accounts (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name            VARCHAR(255) UNIQUE NOT NULL,
  normal_balance  VARCHAR(6)  CHECK (normal_balance IN ('debit','credit')) NOT NULL,
  type            VARCHAR(20) NOT NULL,
  currency        VARCHAR(3)  DEFAULT 'USD',
  mt_ledger_account_id VARCHAR(255),
  description     TEXT,
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── LEDGER TRANSACTIONS (immutable) ────────────────────────
CREATE TABLE IF NOT EXISTS ledger_transactions (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  description     VARCHAR(500) NOT NULL,
  status          VARCHAR(20)  DEFAULT 'pending',
  effective_at    TIMESTAMPTZ  NOT NULL,
  metadata        JSONB        DEFAULT '{}',
  external_id     VARCHAR(255) UNIQUE,
  mt_ledger_tx_id VARCHAR(255),
  unit_tx_id      VARCHAR(255),
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── LEDGER ENTRIES (immutable — no UPDATE/DELETE ever) ──────
CREATE TABLE IF NOT EXISTS ledger_entries (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ledger_transaction_id UUID NOT NULL REFERENCES ledger_transactions(id),
  ledger_account_id     UUID NOT NULL REFERENCES ledger_accounts(id),
  direction             VARCHAR(6) CHECK (direction IN ('debit','credit')) NOT NULL,
  amount                NUMERIC(20,4) NOT NULL CHECK (amount > 0),
  currency              VARCHAR(3) DEFAULT 'USD',
  created_at            TIMESTAMPTZ DEFAULT NOW()
);

-- Immutability triggers
CREATE OR REPLACE FUNCTION prevent_ledger_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Ledger entries are immutable. Use a reversing entry.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ledger_entries_immutable ON ledger_entries;
CREATE TRIGGER trg_ledger_entries_immutable
  BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();

-- Balance enforcement trigger
CREATE OR REPLACE FUNCTION check_ledger_balance()
RETURNS TRIGGER AS $$
DECLARE debit_sum NUMERIC; credit_sum NUMERIC;
BEGIN
  IF NEW.status = 'posted' THEN
    SELECT
      COALESCE(SUM(CASE WHEN direction='debit'  THEN amount ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN direction='credit' THEN amount ELSE 0 END),0)
    INTO debit_sum, credit_sum
    FROM ledger_entries WHERE ledger_transaction_id = NEW.id;
    IF ABS(debit_sum - credit_sum) > 0.001 THEN
      RAISE EXCEPTION 'Ledger imbalance: debits=% credits=% tx=%', debit_sum, credit_sum, NEW.id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ledger_balance_check ON ledger_transactions;
CREATE TRIGGER trg_ledger_balance_check
  BEFORE UPDATE ON ledger_transactions
  FOR EACH ROW EXECUTE FUNCTION check_ledger_balance();

-- ── DISPUTES ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS disputes (
  id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_number                 VARCHAR(20) UNIQUE NOT NULL,
  user_id                     UUID NOT NULL REFERENCES users(id),
  account_id                  UUID REFERENCES accounts(id),
  transaction_id              UUID REFERENCES transactions(id),
  dispute_type                VARCHAR(50)  NOT NULL,
  status                      VARCHAR(50)  DEFAULT 'filed',
  amount                      NUMERIC(20,4) NOT NULL,
  currency                    VARCHAR(3)   DEFAULT 'USD',
  description                 TEXT NOT NULL,
  merchant_name               VARCHAR(255),
  transaction_date            DATE,

  -- Reg E deadlines (auto-calculated on insert)
  filed_at                    TIMESTAMPTZ DEFAULT NOW(),
  provisional_credit_deadline TIMESTAMPTZ,
  investigation_deadline      TIMESTAMPTZ,
  resolution_notice_deadline  TIMESTAMPTZ,

  -- Provisional credit
  provisional_credit_issued   BOOLEAN DEFAULT FALSE,
  provisional_credit_at       TIMESTAMPTZ,
  provisional_credit_amount   NUMERIC(20,4),

  -- Resolution
  resolution                  VARCHAR(20),
  resolution_amount           NUMERIC(20,4),
  resolution_notes            TEXT,
  resolved_at                 TIMESTAMPTZ,
  resolved_by                 UUID,
  resolution_notice_sent      BOOLEAN DEFAULT FALSE,
  resolution_notice_sent_at   TIMESTAMPTZ,

  -- External refs
  unit_dispute_id             VARCHAR(255),
  nacha_return_code           VARCHAR(10),
  stripe_dispute_id           VARCHAR(255),

  -- Evidence & flags
  evidence                    JSONB DEFAULT '[]',
  is_new_account              BOOLEAN DEFAULT FALSE,
  sar_filed                   BOOLEAN DEFAULT FALSE,
  escalated_at                TIMESTAMPTZ,

  created_at                  TIMESTAMPTZ DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dispute_events (
  id           BIGSERIAL PRIMARY KEY,
  dispute_id   UUID NOT NULL REFERENCES disputes(id),
  event_type   VARCHAR(100) NOT NULL,
  description  TEXT,
  data         JSONB DEFAULT '{}',
  performed_by UUID,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ── RECONCILIATION ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reconciliation_reports (
  id              BIGSERIAL PRIMARY KEY,
  date            DATE UNIQUE NOT NULL,
  status          VARCHAR(20) NOT NULL,
  summary         JSONB,
  breaks          JSONB DEFAULT '[]',
  break_count     INTEGER DEFAULT 0,
  critical_count  INTEGER DEFAULT 0,
  run_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS reconciliation_breaks (
  id               BIGSERIAL PRIMARY KEY,
  date             DATE NOT NULL,
  type             VARCHAR(100),
  severity         VARCHAR(20),
  expected_amount  NUMERIC(20,4),
  actual_amount    NUMERIC(20,4),
  delta            NUMERIC(20,4),
  description      TEXT,
  status           VARCHAR(20) DEFAULT 'open',
  notes            TEXT,
  resolved_by      UUID,
  resolved_at      TIMESTAMPTZ,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- ── INDEXES ─────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_ledger_entries_account   ON ledger_entries(ledger_account_id);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_tx        ON ledger_entries(ledger_transaction_id);
CREATE INDEX IF NOT EXISTS idx_ledger_tx_effective      ON ledger_transactions(effective_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_tx_status         ON ledger_transactions(status);
CREATE INDEX IF NOT EXISTS idx_disputes_user_id         ON disputes(user_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status          ON disputes(status);
CREATE INDEX IF NOT EXISTS idx_disputes_deadlines       ON disputes(investigation_deadline) WHERE status NOT IN ('resolved_customer','resolved_merchant','withdrawn');
CREATE INDEX IF NOT EXISTS idx_recon_breaks_date        ON reconciliation_breaks(date);
CREATE INDEX IF NOT EXISTS idx_recon_breaks_status      ON reconciliation_breaks(status);

-- ── ROW LEVEL SECURITY ──────────────────────────────────────
ALTER TABLE disputes             ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_transactions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries       ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE ledger_entries       IS 'IMMUTABLE — insert only. Reversing entries only, no updates or deletes.';
COMMENT ON TABLE disputes             IS 'Reg E dispute records — 7 year retention required';
COMMENT ON TABLE reconciliation_reports IS 'Nightly settlement reconciliation — 7 year retention required';
