export type PaymentChargeCategory =
  | "PHYSICAL_MARKETPLACE_FEE"
  | "DIGITAL_APP_FEATURE"
  | "SERVICE_SUBSCRIPTION"
  | "MANUAL_REVIEW";

export interface PaymentPolicyDecision {
  productCode: string;
  chargeCategory: PaymentChargeCategory;
  physicalCommerceEligible: boolean;
  appleIAPRequired: boolean;
  externalCheckoutAllowed: boolean;
  storefrontCountry: string;
  reviewRequired: boolean;
  decisionReason: string;
  reviewedAt: string;
}

const approvedPhysicalFeeCodes = new Set(["MARKETPLACE_ORDER_FLAT", "MARKETPLACE_ORDER_PERCENTAGE", "PAYOUT_FEE", "REFUND_ADMIN_FEE"]);
const digitalFeatureCodes = new Set(["SELLER_SUBSCRIPTION", "SHOP_CAPACITY", "PRODUCT_CAPACITY", "PROMOTED_LISTING"]);

export function decidePaymentPolicy(productCode: string, storefrontCountry = "US"): PaymentPolicyDecision {
  const code = productCode.trim().toUpperCase();
  const reviewedAt = new Date().toISOString();
  if (approvedPhysicalFeeCodes.has(code)) {
    return {
      productCode: code,
      chargeCategory: "PHYSICAL_MARKETPLACE_FEE",
      physicalCommerceEligible: true,
      appleIAPRequired: false,
      externalCheckoutAllowed: true,
      storefrontCountry,
      reviewRequired: false,
      decisionReason: "Fee is tied to physical marketplace commerce or seller payout operations.",
      reviewedAt,
    };
  }
  if (digitalFeatureCodes.has(code)) {
    return {
      productCode: code,
      chargeCategory: "DIGITAL_APP_FEATURE",
      physicalCommerceEligible: false,
      appleIAPRequired: true,
      externalCheckoutAllowed: false,
      storefrontCountry,
      reviewRequired: true,
      decisionReason: "Fee may unlock digital app functionality and must remain gated until Apple/App Review policy is confirmed.",
      reviewedAt,
    };
  }
  return {
    productCode: code,
    chargeCategory: "MANUAL_REVIEW",
    physicalCommerceEligible: false,
    appleIAPRequired: false,
    externalCheckoutAllowed: false,
    storefrontCountry,
    reviewRequired: true,
    decisionReason: "Unknown fee code requires administrator and compliance review before activation.",
    reviewedAt,
  };
}
