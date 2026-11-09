CREATE TABLE IF NOT EXISTS "PricingAgentProduct" (
  "id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "category" TEXT NOT NULL,
  "stripeProductIdsJson" TEXT NOT NULL DEFAULT '[]', "stripePriceIdsJson" TEXT NOT NULL DEFAULT '[]',
  "billingType" TEXT NOT NULL, "publicPriceMinor" INTEGER NOT NULL DEFAULT 0, "currency" TEXT NOT NULL DEFAULT 'USD',
  "targetMarginBasisPoints" INTEGER NOT NULL DEFAULT 7000, "includedAllowancesJson" TEXT NOT NULL DEFAULT '{}',
  "metadataJson" TEXT NOT NULL DEFAULT '{}', "active" BOOLEAN NOT NULL DEFAULT true,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS "PricingAgentRun" (
  "id" TEXT PRIMARY KEY, "idempotencyKey" TEXT NOT NULL UNIQUE, "startedAt" DATETIME NOT NULL, "completedAt" DATETIME,
  "status" TEXT NOT NULL, "reportingPeriodStart" DATETIME NOT NULL, "reportingPeriodEnd" DATETIME NOT NULL,
  "stripeAccountId" TEXT, "stripeEnvironment" TEXT NOT NULL, "dataSourceVersion" TEXT NOT NULL,
  "costModelVersion" TEXT NOT NULL, "authority" TEXT NOT NULL, "currency" TEXT NOT NULL DEFAULT 'USD',
  "completeness" TEXT NOT NULL DEFAULT 'INCOMPLETE', "errorSummary" TEXT, "summaryJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS "PricingAgentRun_idempotency_key" ON "PricingAgentRun"("idempotencyKey");
CREATE INDEX IF NOT EXISTS "PricingAgentRun_period_idx" ON "PricingAgentRun"("reportingPeriodStart", "reportingPeriodEnd");
CREATE TABLE IF NOT EXISTS "PricingAgentProductResult" (
  "id" TEXT PRIMARY KEY, "runId" TEXT NOT NULL, "productId" TEXT NOT NULL, "stripeProductId" TEXT, "stripePriceId" TEXT,
  "grossRevenueMinor" INTEGER NOT NULL DEFAULT 0, "netRevenueMinor" INTEGER NOT NULL DEFAULT 0,
  "stripeFeesMinor" INTEGER NOT NULL DEFAULT 0, "refundsMinor" INTEGER NOT NULL DEFAULT 0,
  "disputesMinor" INTEGER NOT NULL DEFAULT 0, "discountsMinor" INTEGER NOT NULL DEFAULT 0,
  "estimatedDirectCostMinor" INTEGER NOT NULL DEFAULT 0, "contributionProfitMinor" INTEGER NOT NULL DEFAULT 0,
  "contributionMarginBasisPoints" INTEGER, "activeCustomers" INTEGER NOT NULL DEFAULT 0,
  "newCustomers" INTEGER NOT NULL DEFAULT 0, "cancelledCustomers" INTEGER NOT NULL DEFAULT 0,
  "churnRateBasisPoints" INTEGER, "averageRevenuePerUserMinor" INTEGER, "averageCostPerUserMinor" INTEGER,
  "scenario" TEXT NOT NULL, "risk" TEXT NOT NULL, "metricsJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE("runId", "productId", "stripePriceId", "scenario")
);
CREATE INDEX IF NOT EXISTS "PricingAgentResult_run_risk_idx" ON "PricingAgentProductResult"("runId", "risk");
CREATE TABLE IF NOT EXISTS "PricingAgentCostInput" (
  "id" TEXT PRIMARY KEY, "key" TEXT NOT NULL, "valueDecimal" TEXT NOT NULL, "unit" TEXT NOT NULL,
  "currency" TEXT NOT NULL DEFAULT 'USD', "provider" TEXT NOT NULL, "effectiveAt" DATETIME NOT NULL,
  "source" TEXT NOT NULL, "lastUpdatedAt" DATETIME NOT NULL, "updatedBy" TEXT NOT NULL, "confidence" TEXT NOT NULL,
  "metadataJson" TEXT NOT NULL DEFAULT '{}', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE("key", "effectiveAt")
);
CREATE INDEX IF NOT EXISTS "PricingAgentCostInput_key_effective_idx" ON "PricingAgentCostInput"("key", "effectiveAt");
CREATE TABLE IF NOT EXISTS "PricingAgentRecommendation" (
  "id" TEXT PRIMARY KEY, "runId" TEXT NOT NULL, "productId" TEXT NOT NULL, "severity" TEXT NOT NULL,
  "recommendationType" TEXT NOT NULL, "currentValueJson" TEXT NOT NULL, "proposedValueJson" TEXT NOT NULL,
  "explanation" TEXT NOT NULL, "projectedMarginBasisPoints" INTEGER, "confidence" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'DRAFT', "ownerDecision" TEXT, "ownerNotes" TEXT, "ownerDecidedAt" DATETIME,
  "expiresAt" DATETIME, "evidenceJson" TEXT NOT NULL DEFAULT '{}', "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS "PricingAgentRecommendation_run_status_idx" ON "PricingAgentRecommendation"("runId", "status");
CREATE TABLE IF NOT EXISTS "PricingAgentReport" (
  "id" TEXT PRIMARY KEY, "runId" TEXT NOT NULL UNIQUE, "title" TEXT NOT NULL, "reportJson" TEXT NOT NULL,
  "reportHtml" TEXT NOT NULL, "approvalStatus" TEXT NOT NULL DEFAULT 'PENDING',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS "PricingAgentAlert" (
  "id" TEXT PRIMARY KEY, "runId" TEXT, "severity" TEXT NOT NULL, "code" TEXT NOT NULL, "message" TEXT NOT NULL,
  "detailsJson" TEXT NOT NULL DEFAULT '{}', "status" TEXT NOT NULL DEFAULT 'OPEN',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "resolvedAt" DATETIME
);
CREATE TABLE IF NOT EXISTS "PricingAgentAuditLog" (
  "id" TEXT PRIMARY KEY, "actorId" TEXT, "actorType" TEXT NOT NULL, "action" TEXT NOT NULL,
  "resourceType" TEXT NOT NULL, "resourceId" TEXT, "detailsJson" TEXT NOT NULL DEFAULT '{}',
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
