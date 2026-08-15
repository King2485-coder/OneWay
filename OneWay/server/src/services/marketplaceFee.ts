export type MarketplaceFeeType = "FIXED";
export type MarketplaceRefundBehavior = "FULL_BEFORE_FULFILLMENT_REVERSE_PARTIAL_RETAIN";
export type MarketplacePaymentStatus = "created" | "pending_payment" | "paid" | "failed" | "canceled" | "refunded";
export type MarketplacePayoutStatus = "not_eligible" | "pending" | "in_transit" | "paid" | "blocked";

export type MarketplaceFeeConfiguration = {
  feeType: MarketplaceFeeType;
  feeAmountMinor: number;
  currency: "USD";
  active: boolean;
  effectiveDate: string;
  refundBehavior: MarketplaceRefundBehavior;
  minimumOrderAmountMinor: number;
};

export type MarketplaceOrderLedgerInput = {
  currency: string;
  subtotalMinor: number;
  discountAmountMinor?: number;
  shippingAmountMinor?: number;
  taxAmountMinor?: number;
  paymentProcessingFeeMinor?: number;
  refundedAmountMinor?: number;
  disputedAmountMinor?: number;
  paymentStatus: MarketplacePaymentStatus;
};

export type MarketplaceOrderLedger = {
  currency: string;
  subtotalMinor: number;
  discountAmountMinor: number;
  shippingAmountMinor: number;
  taxAmountMinor: number;
  customerTotalMinor: number;
  paymentProcessingFeeMinor: number;
  oneWayPlatformFeeMinor: number;
  sellerGrossAmountMinor: number;
  sellerNetAmountMinor: number;
  refundedAmountMinor: number;
  disputedAmountMinor: number;
  payoutAmountMinor: number;
  paymentStatus: MarketplacePaymentStatus;
  payoutStatus: MarketplacePayoutStatus;
  feeConfigSnapshot: MarketplaceFeeConfiguration;
};

export const defaultMarketplaceFeeConfiguration: MarketplaceFeeConfiguration = {
  feeType: "FIXED",
  feeAmountMinor: 30,
  currency: "USD",
  active: true,
  effectiveDate: "2026-07-22T00:00:00.000Z",
  refundBehavior: "FULL_BEFORE_FULFILLMENT_REVERSE_PARTIAL_RETAIN",
  minimumOrderAmountMinor: Number(process.env.ONEWAY_MARKETPLACE_MIN_ORDER_MINOR ?? 100),
};

export function marketplaceFeeConfiguration(): MarketplaceFeeConfiguration {
  const feeAmountMinor = Number(process.env.ONEWAY_MARKETPLACE_FEE_MINOR ?? defaultMarketplaceFeeConfiguration.feeAmountMinor);
  const minimumOrderAmountMinor = Number(process.env.ONEWAY_MARKETPLACE_MIN_ORDER_MINOR ?? defaultMarketplaceFeeConfiguration.minimumOrderAmountMinor);
  return {
    ...defaultMarketplaceFeeConfiguration,
    feeAmountMinor: Number.isFinite(feeAmountMinor) ? feeAmountMinor : defaultMarketplaceFeeConfiguration.feeAmountMinor,
    minimumOrderAmountMinor: Number.isFinite(minimumOrderAmountMinor) ? minimumOrderAmountMinor : defaultMarketplaceFeeConfiguration.minimumOrderAmountMinor,
  };
}

export function dollarsToMinorUnits(amount: number): number {
  if (!Number.isFinite(amount)) return 0;
  return Math.round(amount * 100);
}

export function minorUnitsToDollars(amountMinor: number): number {
  return amountMinor / 100;
}

export function shouldAssessOneWayFee(paymentStatus: MarketplacePaymentStatus): boolean {
  return paymentStatus === "paid";
}

export function calculateMarketplaceOrderLedger(input: MarketplaceOrderLedgerInput, config = marketplaceFeeConfiguration()): MarketplaceOrderLedger {
  if (input.currency !== config.currency) {
    throw new Error(`unsupported_marketplace_fee_currency:${input.currency}`);
  }

  const subtotalMinor = positive(input.subtotalMinor);
  const discountAmountMinor = positive(input.discountAmountMinor ?? 0);
  const shippingAmountMinor = positive(input.shippingAmountMinor ?? 0);
  const taxAmountMinor = positive(input.taxAmountMinor ?? 0);
  const paymentProcessingFeeMinor = positive(input.paymentProcessingFeeMinor ?? 0);
  const refundedAmountMinor = positive(input.refundedAmountMinor ?? 0);
  const disputedAmountMinor = positive(input.disputedAmountMinor ?? 0);
  const customerTotalMinor = Math.max(0, subtotalMinor + shippingAmountMinor + taxAmountMinor - discountAmountMinor);

  if (customerTotalMinor > 0 && customerTotalMinor < config.minimumOrderAmountMinor) {
    throw new Error(`minimum_order_amount_not_met:${config.minimumOrderAmountMinor}`);
  }

  const oneWayPlatformFeeMinor = config.active && shouldAssessOneWayFee(input.paymentStatus) ? config.feeAmountMinor : 0;
  const sellerGrossAmountMinor = Math.max(0, customerTotalMinor - taxAmountMinor);
  const sellerNetAmountMinor = Math.max(
    0,
    sellerGrossAmountMinor - refundedAmountMinor - disputedAmountMinor - paymentProcessingFeeMinor - oneWayPlatformFeeMinor
  );

  return {
    currency: input.currency,
    subtotalMinor,
    discountAmountMinor,
    shippingAmountMinor,
    taxAmountMinor,
    customerTotalMinor,
    paymentProcessingFeeMinor,
    oneWayPlatformFeeMinor,
    sellerGrossAmountMinor,
    sellerNetAmountMinor,
    refundedAmountMinor,
    disputedAmountMinor,
    payoutAmountMinor: input.paymentStatus === "paid" ? sellerNetAmountMinor : 0,
    paymentStatus: input.paymentStatus,
    payoutStatus: input.paymentStatus === "paid" ? "pending" : "not_eligible",
    feeConfigSnapshot: config,
  };
}

export function applyFullRefundToLedger(
  ledger: MarketplaceOrderLedger,
  beforeFulfillment: boolean,
  fraudulentOrDuplicate = false
): MarketplaceOrderLedger {
  const reverseFee = beforeFulfillment || fraudulentOrDuplicate;
  return calculateMarketplaceOrderLedger({
    currency: ledger.currency,
    subtotalMinor: ledger.subtotalMinor,
    discountAmountMinor: ledger.discountAmountMinor,
    shippingAmountMinor: ledger.shippingAmountMinor,
    taxAmountMinor: ledger.taxAmountMinor,
    paymentProcessingFeeMinor: ledger.paymentProcessingFeeMinor,
    refundedAmountMinor: ledger.customerTotalMinor,
    disputedAmountMinor: ledger.disputedAmountMinor,
    paymentStatus: "refunded",
  }, {
    ...ledger.feeConfigSnapshot,
    feeAmountMinor: reverseFee ? 0 : ledger.feeConfigSnapshot.feeAmountMinor,
  });
}

export function applyPartialRefundToLedger(ledger: MarketplaceOrderLedger, refundAmountMinor: number): MarketplaceOrderLedger {
  return calculateMarketplaceOrderLedger({
    currency: ledger.currency,
    subtotalMinor: ledger.subtotalMinor,
    discountAmountMinor: ledger.discountAmountMinor,
    shippingAmountMinor: ledger.shippingAmountMinor,
    taxAmountMinor: ledger.taxAmountMinor,
    paymentProcessingFeeMinor: ledger.paymentProcessingFeeMinor,
    refundedAmountMinor: positive(refundAmountMinor),
    disputedAmountMinor: ledger.disputedAmountMinor,
    paymentStatus: "paid",
  }, ledger.feeConfigSnapshot);
}

function positive(value: number): number {
  return Math.max(0, Math.round(Number.isFinite(value) ? value : 0));
}
