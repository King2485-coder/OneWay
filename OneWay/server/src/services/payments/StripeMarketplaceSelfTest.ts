import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const tempDir = mkdtempSync(path.join(tmpdir(), "oneway-stripe-marketplace-"));
process.env.DATABASE_URL = `file:${path.join(tempDir, "stripe-marketplace.db")}`;

async function main(): Promise<void> {
  const { PrismaClient } = await import("@prisma/client");
  const { ensurePaymentTables } = await import("./PaymentTables");
  const { calculateMarketplaceOrderLedger } = await import("../marketplaceFee");
  const prisma = new PrismaClient();

  try {
    await ensurePaymentTables(prisma);
    const expectedTables = [
      "SellerPaymentAccount",
      "OneWayBillingCustomer",
      "StripeWebhookEvent",
      "ShopPayment",
      "PlatformFee",
      "Refund",
      "Transfer",
      "SellerPayout",
      "Dispute",
      "Invoice",
    ];
    const rows = await prisma.$queryRawUnsafe<Array<{ name: string }>>(
      `SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (${expectedTables.map(() => "?").join(",")})`,
      ...expectedTables,
    );
    const names = new Set(rows.map((row) => row.name));
    for (const table of expectedTables) assert.equal(names.has(table), true, `${table} table should exist`);

    const ledger = calculateMarketplaceOrderLedger({
      currency: "USD",
      subtotalMinor: 2500,
      shippingAmountMinor: 0,
      taxAmountMinor: 0,
      discountAmountMinor: 0,
      paymentProcessingFeeMinor: 0,
      paymentStatus: "paid",
    });
    assert.equal(ledger.oneWayPlatformFeeMinor, 30, "OneWay keeps a fixed $0.30 marketplace fee per completed order");
    assert.equal(ledger.sellerNetAmountMinor, 2470, "Seller net excludes the fixed OneWay platform fee");

    console.log("Stripe marketplace table and fee self-test passed");
  } finally {
    await prisma.$disconnect();
  }
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });
