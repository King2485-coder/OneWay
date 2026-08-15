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
    handle: store.handle,
    slug: store.slug,
    logoUrl: store.logoUrl,
    bannerUrl: store.bannerUrl,
    description: store.description,
    category: store.category,
    tagline: store.tagline,
    storeStatus: store.published ? "published" : "draft",
    searchable: Boolean((store as any).searchable ?? store.published),
    publicVisible: Boolean((store as any).publicVisible ?? store.published),
    launchedAt: (store as any).launchedAt instanceof Date ? (store as any).launchedAt.toISOString() : ((store as any).launchedAt ?? null),
    paymentsEnabled: Boolean((store as any).paymentsEnabled ?? false),
    defaultPaymentMode: (store as any).defaultPaymentMode ?? "contact",
    defaultPaymentLinkUrl: (store as any).defaultPaymentLinkUrl ?? null,
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
  const imageUrls = parseStringArray((product as any).imageUrlsJson);
  const primaryImageUrl = product.imageUrl ?? imageUrls[0] ?? null;
  const trackInventory = (product as any).trackInventory ?? true;
  const inventoryCount = (product as any).inventory ?? 0;
  const status = product.published ? "active" : "draft";
  return {
    id: product.id,
    productId: product.id,
    storeId: product.storefrontId,
    storefrontId: product.storefrontId,
    title: product.name,
    name: product.name,
    description: product.description,
    price: parsePrice(product.price),
    priceCents: Math.round(parsePrice(product.price) * 100),
    currency: (product as any).currency ?? "USD",
    imageUrl: product.imageUrl,
    primaryImageUrl,
    mediaURL: primaryImageUrl,
    imageUrls,
    images: imageUrls.map((url, index) => ({
      imageId: encodeURIComponent(url),
      productId: product.id,
      storeId: product.storefrontId,
      sellerId: null,
      storageKey: url,
      url,
      thumbnailUrl: url,
      width: null,
      height: null,
      contentType: imageContentType(url),
      fileSize: 0,
      sortOrder: index,
      createdAt: new Date().toISOString(),
    })),
    inventoryCount,
    isAvailable: product.published && (!trackInventory || inventoryCount > 0),
    category: (product as any).category ?? null,
    paymentMode: (product as any).paymentMode ?? "contact",
    paymentLinkUrl: (product as any).paymentLinkUrl ?? null,
    publishedAt: (product as any).publishedAt instanceof Date ? (product as any).publishedAt.toISOString() : ((product as any).publishedAt ?? null),
    status,
    featured: product.featured,
    published: product.published,
    isSubscription: product.isSubscription,
    stripePriceId: product.stripePriceId,
  };
}

function parseStringArray(value: unknown): string[] {
  if (typeof value !== "string" || !value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string" && item.length > 0) : [];
  } catch {
    return [];
  }
}

function imageContentType(url: string): string {
  const value = url.toLowerCase();
  if (value.endsWith(".png")) return "image/png";
  if (value.endsWith(".webp")) return "image/webp";
  return "image/jpeg";
}

export function parsePrice(price: string): number {
  const value = Number(price.replace(/[$,]/g, "").trim());
  return Number.isFinite(value) ? value : 0;
}

export function publicImageUrl(filename: string): string {
  const configuredBase =
    process.env.UPLOADS_PUBLIC_BASE_URL?.trim() ||
    process.env.S3_PUBLIC_URL_BASE?.trim() ||
    "https://cdn.oneway.app/uploads";
  return `${configuredBase.replace(/\/$/, "")}/${filename.replace(/^\//, "")}`;
}
