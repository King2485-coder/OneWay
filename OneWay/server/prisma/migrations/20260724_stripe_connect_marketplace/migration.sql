CREATE TABLE IF NOT EXISTS "ShopPayment" (
  "id" TEXT PRIMARY KEY,
  "orderId" TEXT NOT NULL,
  "shopId" TEXT,
  "sellerId" TEXT,
  "buyerId" TEXT NOT NULL,
  "stripePaymentIntentId" TEXT UNIQUE,
  "stripeCheckoutSessionId" TEXT UNIQUE,
  "stripeChargeId" TEXT,
  "stripeCustomerId" TEXT,
  "connectedAccountId" TEXT,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL DEFAULT 'CREATED',
  "paymentMethodTypes" TEXT,
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "ShopPayment_orderId_idx" ON "ShopPayment" ("orderId");
CREATE INDEX IF NOT EXISTS "ShopPayment_sellerId_idx" ON "ShopPayment" ("sellerId");
CREATE INDEX IF NOT EXISTS "ShopPayment_status_idx" ON "ShopPayment" ("status");

CREATE TABLE IF NOT EXISTS "PlatformFee" (
  "id" TEXT PRIMARY KEY,
  "orderId" TEXT NOT NULL,
  "shopPaymentId" TEXT,
  "stripeApplicationFeeId" TEXT UNIQUE,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL DEFAULT 'PENDING',
  "feeType" TEXT NOT NULL DEFAULT 'MARKETPLACE_ORDER_FLAT',
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "PlatformFee_orderId_feeType_key" ON "PlatformFee" ("orderId", "feeType");
CREATE INDEX IF NOT EXISTS "PlatformFee_status_idx" ON "PlatformFee" ("status");

CREATE TABLE IF NOT EXISTS "Refund" (
  "id" TEXT PRIMARY KEY,
  "orderId" TEXT,
  "shopPaymentId" TEXT,
  "stripeRefundId" TEXT UNIQUE,
  "stripePaymentIntentId" TEXT,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL DEFAULT 'PENDING',
  "reason" TEXT,
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "Refund_orderId_idx" ON "Refund" ("orderId");
CREATE INDEX IF NOT EXISTS "Refund_status_idx" ON "Refund" ("status");

CREATE TABLE IF NOT EXISTS "Transfer" (
  "id" TEXT PRIMARY KEY,
  "orderId" TEXT,
  "shopPaymentId" TEXT,
  "stripeTransferId" TEXT NOT NULL UNIQUE,
  "connectedAccountId" TEXT,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL DEFAULT 'CREATED',
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "Transfer_connectedAccountId_idx" ON "Transfer" ("connectedAccountId");
CREATE INDEX IF NOT EXISTS "Transfer_status_idx" ON "Transfer" ("status");

CREATE TABLE IF NOT EXISTS "SellerPayout" (
  "id" TEXT PRIMARY KEY,
  "stripePayoutId" TEXT NOT NULL UNIQUE,
  "connectedAccountId" TEXT,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "arrivalDate" DATETIME,
  "status" TEXT NOT NULL DEFAULT 'CREATED',
  "failureCode" TEXT,
  "failureMessage" TEXT,
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "SellerPayout_connectedAccountId_idx" ON "SellerPayout" ("connectedAccountId");
CREATE INDEX IF NOT EXISTS "SellerPayout_status_idx" ON "SellerPayout" ("status");

CREATE TABLE IF NOT EXISTS "Dispute" (
  "id" TEXT PRIMARY KEY,
  "orderId" TEXT,
  "stripeDisputeId" TEXT NOT NULL UNIQUE,
  "stripeChargeId" TEXT,
  "amountMinor" INTEGER NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL,
  "reason" TEXT,
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "Dispute_orderId_idx" ON "Dispute" ("orderId");
CREATE INDEX IF NOT EXISTS "Dispute_status_idx" ON "Dispute" ("status");

CREATE TABLE IF NOT EXISTS "Invoice" (
  "id" TEXT PRIMARY KEY,
  "stripeInvoiceId" TEXT NOT NULL UNIQUE,
  "stripeCustomerId" TEXT,
  "stripeSubscriptionId" TEXT,
  "userId" TEXT,
  "amountDueMinor" INTEGER NOT NULL DEFAULT 0,
  "amountPaidMinor" INTEGER NOT NULL DEFAULT 0,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "status" TEXT NOT NULL DEFAULT 'DRAFT',
  "hostedInvoiceUrl" TEXT,
  "metadataJson" TEXT,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "Invoice_customer_idx" ON "Invoice" ("stripeCustomerId");
CREATE INDEX IF NOT EXISTS "Invoice_subscription_idx" ON "Invoice" ("stripeSubscriptionId");
