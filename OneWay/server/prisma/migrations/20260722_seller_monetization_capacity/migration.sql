CREATE TABLE IF NOT EXISTS "SellerPackage" (
  "id" TEXT PRIMARY KEY,
  "code" TEXT NOT NULL UNIQUE,
  "displayName" TEXT NOT NULL,
  "description" TEXT NOT NULL,
  "packageType" TEXT NOT NULL,
  "billingType" TEXT NOT NULL,
  "quantity" INTEGER,
  "priceAmount" REAL NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "active" BOOLEAN NOT NULL DEFAULT true,
  "sortOrder" INTEGER NOT NULL DEFAULT 0,
  "externalProductId" TEXT,
  "externalPriceId" TEXT,
  "appStoreProductId" TEXT,
  "startsAt" DATETIME,
  "endsAt" DATETIME,
  "metadata" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "SellerPackage_active_sort_idx" ON "SellerPackage" ("active", "sortOrder");
CREATE INDEX IF NOT EXISTS "SellerPackage_type_billing_idx" ON "SellerPackage" ("packageType", "billingType");

CREATE TABLE IF NOT EXISTS "SellerEntitlement" (
  "id" TEXT PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "entitlementType" TEXT NOT NULL,
  "sourceType" TEXT NOT NULL,
  "sourceReferenceId" TEXT,
  "quantity" INTEGER NOT NULL DEFAULT 0,
  "startsAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "expiresAt" DATETIME,
  "status" TEXT NOT NULL DEFAULT 'ACTIVE',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "SellerEntitlement_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS "SellerEntitlement_user_status_idx" ON "SellerEntitlement" ("userId", "status");
CREATE INDEX IF NOT EXISTS "SellerEntitlement_type_idx" ON "SellerEntitlement" ("entitlementType");
CREATE INDEX IF NOT EXISTS "SellerEntitlement_expires_idx" ON "SellerEntitlement" ("expiresAt");

CREATE TABLE IF NOT EXISTS "SellerPlanTransaction" (
  "id" TEXT PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "packageId" TEXT NOT NULL,
  "transactionType" TEXT NOT NULL,
  "billingProvider" TEXT NOT NULL,
  "providerTransactionId" TEXT UNIQUE,
  "providerCustomerId" TEXT,
  "idempotencyKey" TEXT NOT NULL UNIQUE,
  "amount" REAL NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD',
  "paymentStatus" TEXT NOT NULL DEFAULT 'CREATED',
  "entitlementStatus" TEXT NOT NULL DEFAULT 'PENDING',
  "refundedAmount" REAL NOT NULL DEFAULT 0,
  "purchasedAt" DATETIME,
  "effectiveAt" DATETIME,
  "expiresAt" DATETIME,
  "metadata" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "SellerPlanTransaction_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS "SellerPlanTransaction_user_created_idx" ON "SellerPlanTransaction" ("userId", "createdAt");
CREATE INDEX IF NOT EXISTS "SellerPlanTransaction_status_idx" ON "SellerPlanTransaction" ("paymentStatus");
CREATE INDEX IF NOT EXISTS "SellerPlanTransaction_type_idx" ON "SellerPlanTransaction" ("transactionType");
