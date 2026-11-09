import assert from "node:assert/strict";

const base = process.env.ONEWAY_E2E_BASE_URL ?? "http://127.0.0.1:8791";
const seller = `seller-${Date.now()}`;
const buyer = `buyer-${Date.now()}`;

async function request(path: string, user?: string, init: RequestInit = {}) {
  const response = await fetch(`${base}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(user ? { authorization: `Bearer dev:${user}` } : {}),
      ...(init.headers ?? {}),
    },
  });
  const text = await response.text();
  let body: any = null;
  if (text) body = JSON.parse(text);
  return { response, body };
}

async function main() {
const shopName = `Lifecycle Shop ${Date.now()}`;
const shopCreationKey = `shop-create-${Date.now()}`;
const created = await request("/api/storefronts", seller, {
  method: "POST",
  headers: { "idempotency-key": shopCreationKey, "x-correlation-id": shopCreationKey },
  body: JSON.stringify({ name: shopName, category: "Testing" }),
});
assert.equal(created.response.status, 201, JSON.stringify(created.body));
const shopId = created.body.id as string;
const handle = created.body.handle as string;
const createReplay = await request("/api/storefronts", seller, {
  method: "POST",
  headers: { "idempotency-key": shopCreationKey, "x-correlation-id": shopCreationKey },
  body: JSON.stringify({ name: shopName, category: "Testing" }),
});
assert.equal(createReplay.response.status, 200, JSON.stringify(createReplay.body));
assert.equal(createReplay.body.id, shopId, "shop creation retry must return the original shop");

const launched = await request(`/api/storefronts/${shopId}/publish`, seller, {
  method: "POST",
  body: "{}",
});
assert.equal(launched.response.status, 200, JSON.stringify(launched.body));
assert.equal(launched.body.status, "published");
assert.equal(launched.body.published, true);
assert.deepEqual(launched.body.publishChecklist, []);

let search = await request(`/api/storefronts/marketplace?q=${encodeURIComponent(shopName)}`);
assert.equal(search.body.length, 1, "published shop must be searchable by a second profile");

const listing = await request(`/api/storefronts/${shopId}/listings`, seller, {
  method: "POST",
  body: JSON.stringify({
    title: "Lifecycle Product",
    description: "Authoritative test product",
    priceCents: 1299,
    inventory: 3,
    category: "Testing",
    status: "published",
  }),
});
assert.equal(listing.response.status, 201, JSON.stringify(listing.body));

const conversation = await request("/api/shops/messages/conversations", buyer, {
  method: "POST",
  body: JSON.stringify({ shopId, productId: listing.body.id, type: "productInquiry" }),
});
assert.equal(conversation.response.status, 201, JSON.stringify(conversation.body));
const conversationId = conversation.body.conversation.id as string;
const buyerMessage = await request(`/api/shops/messages/conversations/${conversationId}/messages`, buyer, {
  method: "POST",
  body: JSON.stringify({ encryptedPayload: "buyer-test-ciphertext", recipientUserId: seller, clientMessageId: `buyer-${Date.now()}` }),
});
assert.equal(buyerMessage.response.status, 201, JSON.stringify(buyerMessage.body));
const sellerReply = await request(`/api/shops/messages/conversations/${conversationId}/messages`, seller, {
  method: "POST",
  body: JSON.stringify({ encryptedPayload: "seller-test-ciphertext", recipientUserId: buyer, clientMessageId: `seller-${Date.now()}` }),
});
assert.equal(sellerReply.response.status, 201, JSON.stringify(sellerReply.body));

const paused = await request(`/api/storefronts/${shopId}/unpublish`, seller, { method: "POST", body: "{}" });
assert.equal(paused.body.status, "paused");
search = await request(`/api/storefronts/marketplace?q=${encodeURIComponent(shopName)}`);
assert.equal(search.body.length, 0, "paused shop must disappear from search");
const pausedDirect = await request(`/api/storefronts/${handle}`);
assert.equal(pausedDirect.response.status, 409);
assert.equal(pausedDirect.body.message, "This shop is temporarily unavailable.");
const blockedOrder = await request("/api/orders", buyer, {
  method: "POST",
  body: JSON.stringify({ idempotencyKey: `paused-${Date.now()}`, items: [{ productId: listing.body.id, quantity: 1 }] }),
});
assert.equal(blockedOrder.response.status, 400, "paused shops cannot accept purchases");

const resumed = await request(`/api/storefronts/${shopId}/publish`, seller, { method: "POST", body: "{}" });
assert.equal(resumed.body.status, "published");
search = await request(`/api/storefronts/marketplace?q=${encodeURIComponent(shopName)}`);
assert.equal(search.body.length, 1, "resumed shop must return to search");

const idempotencyKey = `checkout-${Date.now()}`;
const order = await request("/api/orders", buyer, {
  method: "POST",
  body: JSON.stringify({ idempotencyKey, items: [{ productId: listing.body.id, quantity: 1 }] }),
});
assert.equal(order.response.status, 201, JSON.stringify(order.body));
assert.equal(order.body.order.paymentStatus, "paid", "local safe-test checkout should be paid without a real charge");
const replay = await request("/api/orders", buyer, {
  method: "POST",
  body: JSON.stringify({ idempotencyKey, items: [{ productId: listing.body.id, quantity: 1 }] }),
});
assert.equal(replay.response.status, 200);
assert.equal(replay.body.order.id, order.body.order.id, "idempotent replay must return the same order");
const listingsAfterCheckout = await request(`/api/storefronts/${shopId}/listings`, seller);
assert.equal(listingsAfterCheckout.body[0].inventory, 2, "inventory must decrement exactly once after an idempotent replay");
const buyerOrders = await request("/api/orders", buyer);
const sellerOrders = await request("/api/orders", seller);
assert.equal(buyerOrders.body.filter((item: any) => item.id === order.body.order.id).length, 1);
assert.equal(sellerOrders.body.filter((item: any) => item.id === order.body.order.id).length, 1);

const deleted = await request(`/api/storefronts/${shopId}`, seller, {
  method: "DELETE",
  body: JSON.stringify({ confirmation: shopName }),
});
assert.equal(deleted.response.status, 204, JSON.stringify(deleted.body));
assert.equal((await request(`/api/storefronts/id/${shopId}`, seller)).response.status, 404);
assert.equal((await request(`/api/storefronts/${handle}`)).response.status, 404);
search = await request(`/api/storefronts/marketplace?q=${encodeURIComponent(shopName)}`);
assert.equal(search.body.length, 0);

console.log(JSON.stringify({
  ok: true,
  lifecycle: ["draft", "published", "paused", "published", "deleted"],
  twoProfiles: { seller, buyer },
  messaging: "buyer message and seller reply persisted",
  checkout: "safe local test mode; one idempotent order; no real charge",
  orderId: order.body.order.id,
}));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
