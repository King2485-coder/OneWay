import "dotenv/config";
import Stripe from "stripe";
import { oneWayProductRegistry, stripePriceForProduct } from "../src/services/billing/OneWayProductRegistry";

async function main() {
  const key = process.env.STRIPE_SECRET_KEY?.trim() ?? "";
  if (!/^(sk|rk)_test_/.test(key)) {
    console.error("Stripe test-mode audit blocked: configure a restricted or secret test key. Live keys are refused.");
    process.exitCode = 2;
    return;
  }
  const stripe = new Stripe(key);
  const account = await stripe.accounts.retrieve();
  const results = [];
  for (const product of oneWayProductRegistry.filter((entry) => entry.billingType !== "free")) {
    const priceId = stripePriceForProduct(product);
    if (!priceId) {
      results.push({ productId: product.id, status: "MISSING_PRICE_MAPPING" });
      continue;
    }
    const price = await stripe.prices.retrieve(priceId, { expand: ["product"] });
    const stripeProduct = typeof price.product === "string" ? null : price.product;
    const problems = [
      !price.active && "inactive_price",
      price.unit_amount !== product.amount && "amount_mismatch",
      price.currency !== product.currency && "currency_mismatch",
      product.billingType === "monthly" && price.recurring?.interval !== "month" && "interval_mismatch",
      product.billingType === "one_time" && price.type !== "one_time" && "billing_type_mismatch",
      stripeProduct && !stripeProduct.active && "inactive_product",
      stripeProduct?.metadata?.oneway_product_id && stripeProduct.metadata.oneway_product_id !== product.id && "product_metadata_mismatch",
      price.metadata?.oneway_product_id && price.metadata.oneway_product_id !== product.id && "price_metadata_mismatch",
    ].filter(Boolean);
    results.push({
      productId: product.id,
      stripeProductId: stripeProduct?.id ?? (typeof price.product === "string" ? price.product : null),
      stripePriceId: price.id,
      status: problems.length ? "INVALID" : "VALID",
      problems,
    });
  }
  console.log(JSON.stringify({
    mode: "test",
    accountId: account.id,
    accountBusinessName: account.business_profile?.name ?? account.settings?.dashboard?.display_name ?? null,
    results,
  }, null, 2));
  if (results.some((result) => result.status !== "VALID")) process.exitCode = 1;
}

main().catch((error) => {
  console.error(`Stripe test-mode audit failed: ${error instanceof Error ? error.message : "unknown_error"}`);
  process.exitCode = 1;
});
