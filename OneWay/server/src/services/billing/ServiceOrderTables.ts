import type { PrismaClient } from "@prisma/client";

let ready = false;

export async function ensureServiceOrderTables(prisma: PrismaClient): Promise<void> {
  if (ready) return;
  const statements = [
    `CREATE TABLE IF NOT EXISTS "BillingOrder" (
      "id" TEXT PRIMARY KEY, "orderNumber" TEXT NOT NULL UNIQUE, "userId" TEXT NOT NULL,
      "productId" TEXT NOT NULL, "orderType" TEXT NOT NULL, "status" TEXT NOT NULL,
      "currency" TEXT NOT NULL DEFAULT 'USD', "subtotal" INTEGER NOT NULL, "tax" INTEGER NOT NULL DEFAULT 0,
      "total" INTEGER NOT NULL, "stripeCustomerId" TEXT, "stripeCheckoutSessionId" TEXT UNIQUE,
      "stripePaymentIntentId" TEXT, "stripeSubscriptionId" TEXT, "stripeInvoiceId" TEXT,
      "idempotencyKey" TEXT NOT NULL UNIQUE, "termsVersion" TEXT NOT NULL, "environment" TEXT NOT NULL,
      "failureCode" TEXT, "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "completedAt" DATETIME, "cancelledAt" DATETIME
    )`,
    `CREATE INDEX IF NOT EXISTS "BillingOrder_user_created_idx" ON "BillingOrder" ("userId", "createdAt")`,
    `CREATE INDEX IF NOT EXISTS "BillingOrder_product_status_idx" ON "BillingOrder" ("productId", "status")`,
    `CREATE TABLE IF NOT EXISTS "BillingEntitlement" (
      "id" TEXT PRIMARY KEY, "userId" TEXT NOT NULL, "entitlementKey" TEXT NOT NULL,
      "sourceOrderId" TEXT NOT NULL, "productId" TEXT NOT NULL, "status" TEXT NOT NULL DEFAULT 'ACTIVE',
      "quantity" INTEGER NOT NULL DEFAULT 1, "stripeCustomerId" TEXT, "stripeSubscriptionId" TEXT,
      "stripePriceId" TEXT, "grantedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "revokedAt" DATETIME, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE ("userId", "entitlementKey", "sourceOrderId")
    )`,
    `CREATE INDEX IF NOT EXISTS "BillingEntitlement_user_status_idx" ON "BillingEntitlement" ("userId", "status")`,
    `CREATE TABLE IF NOT EXISTS "BillingSubscription" (
      "id" TEXT PRIMARY KEY, "userId" TEXT NOT NULL, "productId" TEXT NOT NULL,
      "entitlementKey" TEXT NOT NULL, "stripeCustomerId" TEXT NOT NULL, "stripeSubscriptionId" TEXT NOT NULL UNIQUE,
      "stripePriceId" TEXT, "status" TEXT NOT NULL, "cancelAtPeriodEnd" BOOLEAN NOT NULL DEFAULT false,
      "currentPeriodStart" DATETIME, "currentPeriodEnd" DATETIME, "pendingProductId" TEXT,
      "pendingChangeAt" DATETIME, "gracePeriodEnd" DATETIME, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`,
    `CREATE INDEX IF NOT EXISTS "BillingSubscription_user_status_idx" ON "BillingSubscription" ("userId", "status")`,
    `CREATE TABLE IF NOT EXISTS "BillingWebhookEvent" (
      "stripeEventId" TEXT PRIMARY KEY, "eventType" TEXT NOT NULL, "status" TEXT NOT NULL,
      "orderId" TEXT, "receivedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "processedAt" DATETIME, "failureCode" TEXT
    )`,
    `CREATE TABLE IF NOT EXISTS "BillingCustomerLink" (
      "id" TEXT PRIMARY KEY, "userId" TEXT NOT NULL UNIQUE, "stripeCustomerId" TEXT NOT NULL UNIQUE,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`,
    `CREATE TABLE IF NOT EXISTS "BillingAuditLog" (
      "id" TEXT PRIMARY KEY, "userId" TEXT, "orderId" TEXT, "action" TEXT NOT NULL,
      "actorType" TEXT NOT NULL, "metadataJson" TEXT NOT NULL DEFAULT '{}',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`,
    `CREATE INDEX IF NOT EXISTS "BillingAuditLog_order_created_idx" ON "BillingAuditLog" ("orderId", "createdAt")`,
  ];
  for (const statement of statements) await prisma.$executeRawUnsafe(statement);
  ready = true;
}
