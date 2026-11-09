-- OneWay fixed marketplace fee ledger.
-- Money is stored in integer minor units; the legacy Float fields remain for compatibility.

ALTER TABLE "Order" ADD COLUMN "sellerId" TEXT;
ALTER TABLE "Order" ADD COLUMN "paymentIntentId" TEXT;
ALTER TABLE "Order" ADD COLUMN "currency" TEXT NOT NULL DEFAULT 'USD';
ALTER TABLE "Order" ADD COLUMN "paymentStatus" TEXT NOT NULL DEFAULT 'created';
ALTER TABLE "Order" ADD COLUMN "payoutStatus" TEXT NOT NULL DEFAULT 'not_eligible';
ALTER TABLE "Order" ADD COLUMN "subtotalMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "discountAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "shippingAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "taxAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "customerTotalMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "paymentProcessingFeeMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "oneWayPlatformFeeMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "sellerGrossAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "sellerNetAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "refundedAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "disputedAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "payoutAmountMinor" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "Order" ADD COLUMN "feeConfigSnapshotJson" TEXT;
ALTER TABLE "Order" ADD COLUMN "idempotencyKey" TEXT;

CREATE UNIQUE INDEX "Order_idempotencyKey_key" ON "Order"("idempotencyKey");
CREATE INDEX "Order_sellerId_createdAt_idx" ON "Order"("sellerId", "createdAt");
CREATE INDEX "Order_paymentStatus_idx" ON "Order"("paymentStatus");
CREATE INDEX "Order_payoutStatus_idx" ON "Order"("payoutStatus");

CREATE TABLE "MarketplaceFeeConfiguration" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "feeType" TEXT NOT NULL DEFAULT 'FIXED',
  "feeAmountMinor" INTEGER NOT NULL DEFAULT 30,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "active" BOOLEAN NOT NULL DEFAULT true,
  "effectiveDate" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "refundBehavior" TEXT NOT NULL DEFAULT 'FULL_BEFORE_FULFILLMENT_REVERSE_PARTIAL_RETAIN',
  "minimumOrderAmountMinor" INTEGER NOT NULL DEFAULT 100,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX "MarketplaceFeeConfiguration_active_currency_effectiveDate_idx"
ON "MarketplaceFeeConfiguration"("active", "currency", "effectiveDate");

INSERT INTO "MarketplaceFeeConfiguration" (
  "id",
  "feeType",
  "feeAmountMinor",
  "currency",
  "active",
  "refundBehavior",
  "minimumOrderAmountMinor"
) VALUES (
  'oneway-fixed-marketplace-fee-usd-v1',
  'FIXED',
  30,
  'USD',
  true,
  'FULL_BEFORE_FULFILLMENT_REVERSE_PARTIAL_RETAIN',
  100
);
