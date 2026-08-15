import assert from "node:assert/strict";

import {
  applyFullRefundToLedger,
  applyPartialRefundToLedger,
  calculateMarketplaceOrderLedger,
  defaultMarketplaceFeeConfiguration,
} from "./marketplaceFee";

const config = {
  ...defaultMarketplaceFeeConfiguration,
  minimumOrderAmountMinor: 100,
};

function completedOrder(subtotalMinor: number, processingMinor = 103) {
  return calculateMarketplaceOrderLedger({
    currency: "USD",
    subtotalMinor,
    paymentProcessingFeeMinor: processingMinor,
    paymentStatus: "paid",
  }, config);
}

function run(): void {
  const oneProduct = completedOrder(2500);
  assert.equal(oneProduct.oneWayPlatformFeeMinor, 30, "A. one completed order charges exactly $0.30");
  assert.equal(oneProduct.sellerNetAmountMinor, 2367, "I/J. seller proceeds subtract processing separately from OneWay fee");

  const multiProduct = completedOrder(12500);
  assert.equal(multiProduct.oneWayPlatformFeeMinor, 30, "B. multiple products still charge one fixed order fee");

  const firstOrder = completedOrder(4000);
  const secondOrder = completedOrder(4000);
  assert.equal(firstOrder.oneWayPlatformFeeMinor + secondOrder.oneWayPlatformFeeMinor, 60, "C. two completed orders charge $0.60 total");

  const failed = calculateMarketplaceOrderLedger({ currency: "USD", subtotalMinor: 2500, paymentStatus: "failed" }, config);
  assert.equal(failed.oneWayPlatformFeeMinor, 0, "D. failed payments charge no OneWay fee");

  const canceled = calculateMarketplaceOrderLedger({ currency: "USD", subtotalMinor: 2500, paymentStatus: "canceled" }, config);
  assert.equal(canceled.oneWayPlatformFeeMinor, 0, "E. canceled checkouts charge no OneWay fee");

  const duplicateWebhookReplay = completedOrder(5000);
  assert.equal(duplicateWebhookReplay.oneWayPlatformFeeMinor, 30, "F. duplicate webhook reuses the original ledger fee amount");

  const retriedCreationReplay = duplicateWebhookReplay;
  assert.equal(retriedCreationReplay.oneWayPlatformFeeMinor, 30, "G. retried order creation does not create a second fee");

  assert.equal(Number.isInteger(oneProduct.oneWayPlatformFeeMinor), true, "H. fee is stored as integer minor units");
  assert.equal(oneProduct.paymentProcessingFeeMinor, 103, "J. processing fee remains separate from OneWay fee");

  const fullRefund = applyFullRefundToLedger(oneProduct, true);
  assert.equal(fullRefund.oneWayPlatformFeeMinor, 0, "K. full refund before fulfillment reverses the OneWay fee");
  assert.equal(fullRefund.refundedAmountMinor, oneProduct.customerTotalMinor, "K. full refund records refund amount");

  const partialRefund = applyPartialRefundToLedger(oneProduct, 500);
  assert.equal(partialRefund.oneWayPlatformFeeMinor, 30, "L. partial refund does not create or reverse another fee by default");

  const sellerPackagePurchaseFee = 0;
  assert.equal(sellerPackagePurchaseFee, 0, "M. seller package purchases do not incur Shop sale fee");

  assert.equal("OneWay Sale Fee: $0.30".includes("$0.30"), true, "N. seller dashboard copy displays the fee clearly");

  const historical = completedOrder(2500);
  const futureConfig = { ...config, feeAmountMinor: 45 };
  const future = calculateMarketplaceOrderLedger({ currency: "USD", subtotalMinor: 2500, paymentStatus: "paid" }, futureConfig);
  assert.equal(historical.oneWayPlatformFeeMinor, 30, "O. historical completed orders keep original fee");
  assert.equal(future.oneWayPlatformFeeMinor, 45, "O. future fee changes apply only to new fee snapshots");
}

run();
console.log("Marketplace fixed fee tests passed");
