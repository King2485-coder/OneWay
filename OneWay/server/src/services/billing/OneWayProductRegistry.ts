export type OneWayProductCategory = "subscription" | "phone" | "capacity";
export type OneWayBillingType = "free" | "monthly" | "one_time";

export type OneWaySellableProduct = {
  id: string;
  name: string;
  category: OneWayProductCategory;
  billingType: OneWayBillingType;
  amount: number;
  currency: "usd";
  stripeProductId?: string;
  stripePriceId?: string;
  stripeProductEnv?: string;
  stripePriceEnv?: string;
  entitlementKey: string;
  active: boolean;
  effectiveDate: string;
  capacityDelta?: number;
  shopDelta?: number;
  corePlanRank?: number;
};

const effectiveDate = "2026-07-31";

export const oneWayProductRegistry: readonly OneWaySellableProduct[] = [
  {
    id: "oneway_free", name: "OneWay Free", category: "subscription", billingType: "free",
    amount: 0, currency: "usd", entitlementKey: "plan.free", active: true, effectiveDate, corePlanRank: 0,
  },
  {
    id: "oneway_private", name: "OneWay Private", category: "subscription", billingType: "monthly",
    amount: 999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_ONEWAY_PRIVATE",
    stripePriceEnv: "STRIPE_PRICE_ONEWAY_PRIVATE", entitlementKey: "plan.private", active: true, effectiveDate, corePlanRank: 1,
  },
  {
    id: "oneway_complete", name: "OneWay Complete", category: "subscription", billingType: "monthly",
    amount: 1999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_ONEWAY_COMPLETE",
    stripePriceEnv: "STRIPE_PRICE_ONEWAY_COMPLETE", entitlementKey: "plan.complete", active: true, effectiveDate, corePlanRank: 2,
  },
  {
    id: "oneway_business", name: "OneWay Business", category: "subscription", billingType: "monthly",
    amount: 3999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_ONEWAY_BUSINESS",
    stripePriceEnv: "STRIPE_PRICE_ONEWAY_BUSINESS", entitlementKey: "plan.business", active: true, effectiveDate, corePlanRank: 3,
  },
  {
    id: "oneway_business_pro", name: "OneWay Business Pro", category: "subscription", billingType: "monthly",
    amount: 7999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_ONEWAY_BUSINESS_PRO",
    stripePriceEnv: "STRIPE_PRICE_ONEWAY_BUSINESS_PRO", entitlementKey: "plan.business_pro", active: true, effectiveDate, corePlanRank: 4,
  },
  {
    id: "oneway_phone_number", name: "OneWay Phone Number", category: "phone", billingType: "monthly",
    amount: 499, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_PHONE_NUMBER",
    stripePriceEnv: "STRIPE_PRICE_PHONE_NUMBER", entitlementKey: "phone.number", active: true, effectiveDate,
  },
  {
    id: "oneway_phone_300", name: "OneWay Phone 300", category: "phone", billingType: "monthly",
    amount: 1499, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_PHONE_300",
    stripePriceEnv: "STRIPE_PRICE_PHONE_300", entitlementKey: "phone.300", active: true, effectiveDate,
  },
  {
    id: "oneway_phone_1000", name: "OneWay Phone 1000", category: "phone", billingType: "monthly",
    amount: 3999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_PHONE_1000",
    stripePriceEnv: "STRIPE_PRICE_PHONE_1000", entitlementKey: "phone.1000", active: true, effectiveDate,
  },
  {
    id: "oneway_shop_slot_1", name: "+1 product slot", category: "capacity", billingType: "one_time",
    amount: 199, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_SHOP_SLOT_1",
    stripePriceEnv: "STRIPE_PRICE_SHOP_SLOT_1", entitlementKey: "shop.product_slots.1", capacityDelta: 1, active: true, effectiveDate,
  },
  {
    id: "oneway_shop_slot_10", name: "+10 product slots", category: "capacity", billingType: "one_time",
    amount: 999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_SHOP_SLOT_10",
    stripePriceEnv: "STRIPE_PRICE_SHOP_SLOT_10", entitlementKey: "shop.product_slots.10", capacityDelta: 10, active: true, effectiveDate,
  },
  {
    id: "oneway_shop_slot_25", name: "+25 product slots", category: "capacity", billingType: "one_time",
    amount: 1999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_SHOP_SLOT_25",
    stripePriceEnv: "STRIPE_PRICE_SHOP_SLOT_25", entitlementKey: "shop.product_slots.25", capacityDelta: 25, active: true, effectiveDate,
  },
  {
    id: "oneway_shop_slot_50", name: "+50 product slots", category: "capacity", billingType: "one_time",
    amount: 3499, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_SHOP_SLOT_50",
    stripePriceEnv: "STRIPE_PRICE_SHOP_SLOT_50", entitlementKey: "shop.product_slots.50", capacityDelta: 50, active: true, effectiveDate,
  },
  {
    id: "oneway_shop_slot_100", name: "+100 product slots", category: "capacity", billingType: "one_time",
    amount: 5999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_SHOP_SLOT_100",
    stripePriceEnv: "STRIPE_PRICE_SHOP_SLOT_100", entitlementKey: "shop.product_slots.100", capacityDelta: 100, active: true, effectiveDate,
  },
  {
    id: "oneway_additional_shop", name: "Additional Shop", category: "capacity", billingType: "one_time",
    amount: 1999, currency: "usd", stripeProductEnv: "STRIPE_PRODUCT_ADDITIONAL_SHOP",
    stripePriceEnv: "STRIPE_PRICE_ADDITIONAL_SHOP", entitlementKey: "shop.additional", shopDelta: 1, active: true, effectiveDate,
  },
] as const;

export function resolveOneWayProduct(id: string): OneWaySellableProduct | undefined {
  return oneWayProductRegistry.find((product) => product.id === id && product.active);
}

export function stripePriceForProduct(product: OneWaySellableProduct): string | undefined {
  const configured = product.stripePriceEnv ? process.env[product.stripePriceEnv]?.trim() : undefined;
  return configured || product.stripePriceId;
}

export function isCorePlan(product: OneWaySellableProduct): boolean {
  return product.category === "subscription" && typeof product.corePlanRank === "number";
}

export function publicProduct(product: OneWaySellableProduct) {
  return {
    id: product.id,
    name: product.name,
    category: product.category,
    billingType: product.billingType,
    amount: product.amount,
    currency: product.currency,
    entitlementKey: product.entitlementKey,
    active: product.active,
    effectiveDate: product.effectiveDate,
    capacityDelta: product.capacityDelta ?? 0,
    shopDelta: product.shopDelta ?? 0,
  };
}
