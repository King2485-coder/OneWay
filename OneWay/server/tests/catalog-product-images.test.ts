import assert from "node:assert/strict";
import test from "node:test";
import type { StorefrontProduct } from "@prisma/client";
import { toProductDTO } from "../src/services/catalog.js";

function product(overrides: Partial<StorefrontProduct> = {}): StorefrontProduct {
  return {
    id: "product-1",
    storefrontId: "store-1",
    name: "Buyer-visible product",
    description: "A product uploaded by a seller",
    price: "5.00",
    imageUrl: null,
    imageUrlsJson: JSON.stringify([
      "https://api.oneway.is/uploads/products/product-1/photo.jpg",
    ]),
    inventory: 1,
    trackInventory: true,
    featured: false,
    published: true,
    isSubscription: false,
    stripePriceId: null,
    createdAt: new Date("2026-08-20T00:00:00.000Z"),
    updatedAt: new Date("2026-08-20T00:00:00.000Z"),
    ...overrides,
  } as StorefrontProduct;
}

test("catalog exposes the first uploaded image to legacy and current buyers", () => {
  const dto = toProductDTO(product());

  assert.equal(
    dto.imageUrl,
    "https://api.oneway.is/uploads/products/product-1/photo.jpg",
  );
  assert.equal(dto.primaryImageUrl, dto.imageUrl);
  assert.equal(dto.mediaURL, dto.imageUrl);
  assert.deepEqual(dto.imageUrls, [dto.imageUrl]);
  assert.equal(dto.images[0]?.url, dto.imageUrl);
});

test("explicit primary image remains authoritative", () => {
  const dto = toProductDTO(product({
    imageUrl: "https://cdn.oneway.is/products/product-1/primary.webp",
  }));

  assert.equal(dto.imageUrl, "https://cdn.oneway.is/products/product-1/primary.webp");
  assert.equal(dto.primaryImageUrl, dto.imageUrl);
});
