-- OneWay Ads Phase 2A funding foundation.
-- Additive migration for campaign funding ledger, receipts, and reconciliation.

ALTER TABLE "AdLedgerEntry" ADD COLUMN "status" TEXT NOT NULL DEFAULT 'posted';
ALTER TABLE "AdLedgerEntry" ADD COLUMN "stripeEventId" TEXT;

ALTER TABLE "AdPayment" ADD COLUMN "receiptId" TEXT;
ALTER TABLE "AdPayment" ADD COLUMN "failureCode" TEXT;
ALTER TABLE "AdPayment" ADD COLUMN "failureMessage" TEXT;

CREATE TABLE IF NOT EXISTS "AdReceipt" (
  "id" TEXT PRIMARY KEY,
  "receiptNumber" TEXT NOT NULL UNIQUE,
  "campaignId" TEXT NOT NULL,
  "advertiserId" TEXT NOT NULL,
  "ownerUserId" TEXT NOT NULL,
  "paymentId" TEXT,
  "stripePaymentIntentId" TEXT,
  "stripeEventId" TEXT,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL DEFAULT 'issued',
  "issuedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "metadataJson" TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS "AdReceipt_owner_issued_idx" ON "AdReceipt" ("ownerUserId", "issuedAt");
CREATE UNIQUE INDEX IF NOT EXISTS "AdLedgerEntry_stripe_event_entry_key"
ON "AdLedgerEntry" ("stripeEventId", "entryType", "campaignId")
WHERE "stripeEventId" IS NOT NULL;
