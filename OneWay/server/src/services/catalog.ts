import type { Storefront, StorefrontProduct, StorefrontTheme } from "@prisma/client";

type StoreWithCatalog = Storefront & {
  products?: StorefrontProduct[];
  theme?: StorefrontTheme | null;
};

export function toStoreDTO(store: StoreWithCatalog) {
  return {
    id: store.id,
    ownerId: store.ownerId,
    name: store.name,
    slug: store.slug,
    description: store.description,
    category: store.category,
    tagline: store.tagline,
    published: store.published,
    featured: (store.products ?? []).some((product) => product.featured),
    products: (store.products ?? []).map(toProductDTO),
    theme: store.theme
      ? {
          primaryHex: store.theme.primaryHex,
          accentHex: store.theme.accentHex,
          background: store.theme.background,
          font: store.theme.font,
        }
      : null,
  };
}

export function toProductDTO(product: StorefrontProduct) {
  return {
    id: product.id,
    storeId: product.storefrontId,
    name: product.name,
    description: product.description,
    price: parsePrice(product.price),
    imageUrl: product.imageUrl,
    featured: product.featured,
    published: product.published,
    isSubscription: product.isSubscription,
    stripePriceId: product.stripePriceId,
  };
}

export function parsePrice(price: string): number {
  const value = Number(price);
  return Number.isFinite(value) ? value : 0;
}

export function publicImageUrl(filename: string): string {
  const configuredBase =
    process.env.UPLOADS_PUBLIC_BASE_URL?.trim() ||
    process.env.S3_PUBLIC_URL_BASE?.trim() ||
    "https://cdn.oneway.app/uploads";
  return `${configuredBase.replace(/\/$/, "")}/${filename.replace(/^\//, "")}`;
}
