import type { PrismaClient } from "@prisma/client";

let ready = false;

export async function ensurePaymentTables(prisma: PrismaClient): Promise<void> {
  if (ready) return;
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "SellerPaymentAccount" (
      "id" TEXT PRIMARY KEY,
      "sellerUserId" TEXT NOT NULL,
      "shopId" TEXT,
      "stripeAccountId" TEXT NOT NULL UNIQUE,
      "accountConfiguration" TEXT,
      "onboardingStatus" TEXT NOT NULL DEFAULT 'NOT_STARTED',
      "chargesEnabled" BOOLEAN NOT NULL DEFAULT false,
      "payoutsEnabled" BOOLEAN NOT NULL DEFAULT false,
      "detailsSubmitted" BOOLEAN NOT NULL DEFAULT false,
      "requirementsCurrentlyDue" TEXT,
      "requirementsEventuallyDue" TEXT,
      "requirementsPastDue" TEXT,
      "disabledReason" TEXT,
      "country" TEXT DEFAULT 'US',
      "defaultCurrency" TEXT DEFAULT 'usd',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "SellerPaymentAccount_sellerUserId_shopId_key" ON "SellerPaymentAccount" ("sellerUserId", COALESCE("shopId", ''))`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SellerPaymentAccount_sellerUserId_idx" ON "SellerPaymentAccount" ("sellerUserId")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "OneWayBillingCustomer" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL UNIQUE,
      "stripeCustomerId" TEXT NOT NULL UNIQUE,
      "defaultPaymentMethodId" TEXT,
      "billingEmail" TEXT,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "status" TEXT NOT NULL DEFAULT 'ACTIVE',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AutopayAuthorization" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "stripeCustomerId" TEXT,
      "stripePaymentMethodId" TEXT,
      "scope" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'PENDING',
      "termsVersion" TEXT NOT NULL,
      "consentedAt" DATETIME,
      "revokedAt" DATETIME,
      "revokedReason" TEXT,
      "lastUsedAt" DATETIME,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AutopayAuthorization_userId_idx" ON "AutopayAuthorization" ("userId")`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "AutopayAuthorization_userId_scope_active_key" ON "AutopayAuthorization" ("userId", "scope") WHERE "status" IN ('ACTIVE', 'PENDING')`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "ServiceFeeDefinition" (
      "id" TEXT PRIMARY KEY,
      "code" TEXT NOT NULL UNIQUE,
      "name" TEXT NOT NULL,
      "description" TEXT NOT NULL,
      "feeType" TEXT NOT NULL,
      "amountMinor" INTEGER,
      "percentageBasisPoints" INTEGER,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "billingFrequency" TEXT NOT NULL DEFAULT 'ONE_TIME',
      "physicalCommerceEligible" BOOLEAN NOT NULL DEFAULT false,
      "appleIAPReviewStatus" TEXT NOT NULL DEFAULT 'REQUIRED',
      "autopayEligible" BOOLEAN NOT NULL DEFAULT false,
      "active" BOOLEAN NOT NULL DEFAULT false,
      "effectiveFrom" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "effectiveUntil" DATETIME,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "OneWayServiceSubscription" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "planCode" TEXT NOT NULL,
      "stripeCustomerId" TEXT,
      "stripeSubscriptionId" TEXT UNIQUE,
      "stripePriceId" TEXT,
      "status" TEXT NOT NULL DEFAULT 'INCOMPLETE',
      "autoRenew" BOOLEAN NOT NULL DEFAULT false,
      "currentPeriodStart" DATETIME,
      "currentPeriodEnd" DATETIME,
      "cancelAtPeriodEnd" BOOLEAN NOT NULL DEFAULT false,
      "canceledAt" DATETIME,
      "trialEnd" DATETIME,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "OneWayServiceSubscription_userId_idx" ON "OneWayServiceSubscription" ("userId")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "PaymentWebhookEvent" (
      "providerEventId" TEXT PRIMARY KEY,
      "eventType" TEXT NOT NULL,
      "apiVersion" TEXT,
      "receivedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "processingStatus" TEXT NOT NULL DEFAULT 'RECEIVED',
      "processedAt" DATETIME,
      "attemptCount" INTEGER NOT NULL DEFAULT 0,
      "lastFailureCode" TEXT,
      "relatedEntityType" TEXT,
      "relatedEntityId" TEXT
    )
  `);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "StripeWebhookEvent" (
      "id" TEXT PRIMARY KEY,
      "stripeEventId" TEXT NOT NULL UNIQUE,
      "stripeAccountId" TEXT,
      "eventType" TEXT NOT NULL,
      "apiVersion" TEXT,
      "livemode" BOOLEAN NOT NULL DEFAULT false,
      "objectId" TEXT,
      "payloadJson" TEXT,
      "status" TEXT NOT NULL DEFAULT 'RECEIVED',
      "attemptCount" INTEGER NOT NULL DEFAULT 1,
      "lastError" TEXT,
      "receivedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "processedAt" DATETIME,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StripeWebhookEvent_type_status_idx" ON "StripeWebhookEvent" ("eventType", "status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StripeWebhookEvent_account_idx" ON "StripeWebhookEvent" ("stripeAccountId")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ShopPayment_orderId_idx" ON "ShopPayment" ("orderId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ShopPayment_sellerId_idx" ON "ShopPayment" ("sellerId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ShopPayment_status_idx" ON "ShopPayment" ("status")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "PlatformFee_orderId_feeType_key" ON "PlatformFee" ("orderId", "feeType")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "PlatformFee_status_idx" ON "PlatformFee" ("status")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Refund_orderId_idx" ON "Refund" ("orderId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Refund_status_idx" ON "Refund" ("status")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Transfer_connectedAccountId_idx" ON "Transfer" ("connectedAccountId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Transfer_status_idx" ON "Transfer" ("status")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SellerPayout_connectedAccountId_idx" ON "SellerPayout" ("connectedAccountId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SellerPayout_status_idx" ON "SellerPayout" ("status")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Dispute_orderId_idx" ON "Dispute" ("orderId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Dispute_status_idx" ON "Dispute" ("status")`);

  await prisma.$executeRawUnsafe(`
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
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Invoice_customer_idx" ON "Invoice" ("stripeCustomerId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Invoice_subscription_idx" ON "Invoice" ("stripeSubscriptionId")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "PaymentNotificationOutbox" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "audience" TEXT NOT NULL,
      "eventType" TEXT NOT NULL,
      "title" TEXT NOT NULL,
      "body" TEXT NOT NULL,
      "relatedEntityType" TEXT,
      "relatedEntityId" TEXT,
      "status" TEXT NOT NULL DEFAULT 'PENDING',
      "metadataJson" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "sentAt" DATETIME
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "PaymentNotificationOutbox_user_status_idx" ON "PaymentNotificationOutbox" ("userId", "status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "PaymentNotificationOutbox_event_idx" ON "PaymentNotificationOutbox" ("eventType")`);

  await prisma.$executeRawUnsafe(`
    INSERT OR IGNORE INTO "ServiceFeeDefinition" (
      "id", "code", "name", "description", "feeType", "amountMinor", "currency",
      "billingFrequency", "physicalCommerceEligible", "appleIAPReviewStatus", "autopayEligible", "active"
    ) VALUES (
      'fee_marketplace_order_flat_usd_30', 'MARKETPLACE_ORDER_FLAT', 'OneWay Marketplace Order Fee',
      'Fixed OneWay platform fee deducted from each successfully completed physical Shop order.',
      'MARKETPLACE_ORDER_FLAT', 30, 'USD', 'PER_ORDER', true, 'NOT_REQUIRED', false, true
    )
  `);
  ready = true;
}
