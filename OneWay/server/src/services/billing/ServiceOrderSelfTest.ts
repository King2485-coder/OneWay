import assert from "node:assert/strict";
import { oneWayProductRegistry, resolveOneWayProduct } from "./OneWayProductRegistry";

const expected: Record<string, [number, string]> = {
  oneway_free: [0, "free"],
  oneway_private: [999, "monthly"],
  oneway_complete: [1999, "monthly"],
  oneway_business: [3999, "monthly"],
  oneway_business_pro: [7999, "monthly"],
  oneway_phone_number: [499, "monthly"],
  oneway_phone_300: [1499, "monthly"],
  oneway_phone_1000: [3999, "monthly"],
  oneway_shop_slot_1: [199, "one_time"],
  oneway_shop_slot_10: [999, "one_time"],
  oneway_shop_slot_25: [1999, "one_time"],
  oneway_shop_slot_50: [3499, "one_time"],
  oneway_shop_slot_100: [5999, "one_time"],
  oneway_additional_shop: [1999, "one_time"],
};

assert.equal(oneWayProductRegistry.length, Object.keys(expected).length);
assert.equal(new Set(oneWayProductRegistry.map((product) => product.id)).size, oneWayProductRegistry.length);
assert.equal(new Set(oneWayProductRegistry.map((product) => product.entitlementKey)).size, oneWayProductRegistry.length);
for (const [id, [amount, billingType]] of Object.entries(expected)) {
  const product = resolveOneWayProduct(id);
  assert.ok(product, `${id} is active`);
  assert.equal(product.amount, amount, `${id} amount`);
  assert.equal(product.billingType, billingType, `${id} billing type`);
  assert.equal(product.currency, "usd");
  if (billingType !== "free") assert.ok(product.stripePriceEnv, `${id} has an explicit Price mapping`);
}
console.log("Service order registry self-test passed: stable IDs, approved prices, billing types, entitlements, and Stripe mapping requirements.");
