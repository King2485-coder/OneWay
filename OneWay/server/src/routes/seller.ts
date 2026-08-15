import type { PrismaClient, StorefrontProduct } from "@prisma/client";
import express from "express";
import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import multer from "multer";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { addColumnIfMissing } from "../lib/runtimeSchemaPatch";
import { logger } from "../lib/logger";

const paymentModes = ["contact", "payment_link", "oneway_wallet"] as const;

const storefrontPatchSchema = z.object({
  name: z.string().trim().min(1).optional(),
  handle: z.string().trim().min(1).optional(),
  logoUrl: z.string().trim().url().nullable().optional(),
  bannerUrl: z.string().trim().url().nullable().optional(),
  description: z.string().trim().optional(),
  category: z.string().trim().optional(),
  tagline: z.string().trim().nullable().optional(),
  paymentsEnabled: z.boolean().optional(),
  defaultPaymentMode: z.enum(paymentModes).optional(),
  defaultPaymentLinkUrl: z.string().trim().url().nullable().optional(),
});

const productSchema = z.object({
  title: z.string().trim().min(1).max(120),
  description: z.string().trim().max(4000).default(""),
  priceCents: z.number().int().nonnegative(),
  currency: z.string().trim().min(3).max(3).default("USD"),
  images: z.array(z.string().trim().url()).optional(),
  primaryImageUrl: z.string().trim().url().nullable().optional(),
  inventoryCount: z.number().int().nonnegative().default(0),
  isAvailable: z.boolean().default(true),
  category: z.string().trim().nullable().optional(),
  paymentMode: z.enum(paymentModes).default("contact"),
  paymentLinkUrl: z.string().trim().url().nullable().optional(),
  status: z.enum(["draft", "active", "archived"]).default("draft"),
});

const productPatchSchema = productSchema.partial();

const imageUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.mimetype)) {
      cb(new multer.MulterError("LIMIT_UNEXPECTED_FILE", "image"));
      return;
    }
    cb(null, true);
  }
});

export function sellerRouter({ prisma }: { prisma: PrismaClient }): express.Router {
  const router = express.Router();
  router.use(authMiddleware);
  router.use(async (_req, _res, next) => {
    try {
      await ensureSellerRuntimeColumns(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/storefront", async (req, res) => {
    const ownerId = userId(req);
    const store = await primaryStorefront(prisma, ownerId);
    if (!store) return res.status(404).json({ error: "store_not_found" });
    res.json(toSellerStorefrontDTO(store));
  });

  router.patch("/storefront", async (req, res) => {
    const ownerId = userId(req);
    const parsed = storefrontPatchSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const store = await primaryStorefront(prisma, ownerId);
    if (!store) return res.status(404).json({ error: "store_not_found" });

    const updated = await prisma.storefront.update({
      where: { id: store.id },
      data: {
        name: parsed.data.name,
        handle: parsed.data.handle,
        slug: parsed.data.handle,
        logoUrl: parsed.data.logoUrl,
        bannerUrl: parsed.data.bannerUrl,
        description: parsed.data.description,
        category: parsed.data.category,
        tagline: parsed.data.tagline,
        paymentsEnabled: parsed.data.paymentsEnabled,
        defaultPaymentMode: parsed.data.defaultPaymentMode,
        defaultPaymentLinkUrl: parsed.data.defaultPaymentLinkUrl,
      },
      include: storeInclude,
    });
    res.json(toSellerStorefrontDTO(updated));
  });

  router.post("/storefront/launch", async (req, res) => {
    const ownerId = userId(req);
    const store = await primaryStorefront(prisma, ownerId);
    if (!store) return res.status(404).json({ error: "store_not_found" });

    const checklist = launchChecklist(store);
    if (checklist.length) {
      return res.status(400).json({ error: "validation_failed", message: "Complete required fields before launch.", checklist });
    }

    const now = new Date();
    const updated = await prisma.storefront.update({
      where: { id: store.id },
      data: {
        status: "published",
        published: true,
        searchable: true,
        publicVisible: true,
        launchedAt: now,
        setupCompleted: true,
        setupCompletedAt: (store as any).setupCompletedAt ?? now,
      } as any,
      include: storeInclude,
    });

    res.json(toSellerStorefrontDTO(updated));
  });

  router.get("/products", async (req, res) => {
    const ownerId = userId(req);
    const store = await primaryStorefront(prisma, ownerId);
    if (!store) return res.json([]);
    res.json(store.products.map(toSellerProductDTO));
  });

  router.post("/products", async (req, res) => {
    const ownerId = userId(req);
    const store = await primaryStorefront(prisma, ownerId);
    if (!store) return res.status(404).json({ error: "store_not_found" });
    const parsed = productSchema.safeParse(req.body);
    logger.info({ ownerId, storeId: store.id, payloadShape: payloadShape(req.body) }, "[seller] product create started");
    if (!parsed.success) {
      logger.warn({ ownerId, storeId: store.id, issues: parsed.error.issues }, "[seller] product create validation failed");
      return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    }

    const imageUrls = normalizedImages(parsed.data.images, parsed.data.primaryImageUrl);
    const product = await prisma.storefrontProduct.create({
      data: productData(store.id, parsed.data, imageUrls),
    });
    logger.info({ ownerId, storeId: store.id, productId: product.id, status: parsed.data.status }, "[seller] product create success");
    res.status(201).json(toSellerProductDTO(product));
  });

  router.patch("/products/:productId", async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, String(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    const parsed = productPatchSchema.safeParse(req.body);
    logger.info({ ownerId, productId: existing.id, storeId: existing.storefrontId, payloadShape: payloadShape(req.body) }, "[seller] product update started");
    if (!parsed.success) {
      logger.warn({ ownerId, productId: existing.id, issues: parsed.error.issues }, "[seller] product update validation failed");
      return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    }

    const imageUrls = parsed.data.images || parsed.data.primaryImageUrl !== undefined
      ? normalizedImages(parsed.data.images, parsed.data.primaryImageUrl)
      : undefined;
    const updated = await prisma.storefrontProduct.update({
      where: { id: existing.id },
      data: productPatchData(parsed.data, imageUrls),
    });
    logger.info({ ownerId, productId: updated.id, storeId: updated.storefrontId }, "[seller] product update success");
    res.json(toSellerProductDTO(updated));
  });

  router.delete("/products/:productId", async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, param(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    await prisma.storefrontProduct.update({
      where: { id: existing.id },
      data: { published: false, status: "archived" } as any,
    });
    res.status(204).end();
  });

  router.post("/products/:productId/images", imageUpload.single("image"), async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, param(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    const currentImages = parseJsonArray(existing.imageUrlsJson);
    if (currentImages.length >= 10) {
      return res.status(400).json({ error: "too_many_images", message: "Products can have up to 10 images." });
    }
    if (!req.file || !hasValidImageSignature(req.file.buffer, req.file.mimetype)) {
      return res.status(400).json({ error: "invalid_image", message: "Upload a jpg, png, or webp image." });
    }

    logger.info({
      ownerId,
      productId: existing.id,
      storeId: existing.storefrontId,
      contentType: req.file.mimetype,
      fileSize: req.file.size,
    }, "[seller] product image upload requested");

    const extension = extensionFor(req.file.mimetype);
    const filename = `${randomUUID()}.${extension}`;
    const storageKey = `products/${existing.storefrontId}/${existing.id}/${filename}`;
    const url = await saveProductImage(req, storageKey, req.file.buffer);
    logger.info({ ownerId, productId: existing.id, storageKey }, "[seller] product image storage write success");
    const nextImages = [...currentImages, url];
    const imageId = randomUUID();
    const sortOrder = nextImages.length - 1;
    await prisma.$executeRaw`
      INSERT INTO "ProductImage" (
        "id", "productId", "storeId", "sellerId", "storageKey", "url", "thumbnailUrl", "contentType", "fileSize", "sortOrder", "createdAt"
      ) VALUES (
        ${imageId}, ${existing.id}, ${existing.storefrontId}, ${ownerId}, ${storageKey}, ${url}, ${url}, ${req.file.mimetype}, ${req.file.size}, ${sortOrder}, CURRENT_TIMESTAMP
      )
    `;
    logger.info({ ownerId, productId: existing.id, imageId, storageKey }, "[seller] product image DB record success");
    const updated = await prisma.storefrontProduct.update({
      where: { id: existing.id },
      data: {
        imageUrl: existing.imageUrl || url,
        imageUrlsJson: JSON.stringify(nextImages),
      },
    });

    logger.info({
      ownerId,
      productId: existing.id,
      imageId,
      storageKey,
      imageCount: nextImages.length,
    }, "[seller] product image upload saved");

    res.status(201).json({
      image: productImageDTO({
        imageId,
        url,
        productId: existing.id,
        storeId: existing.storefrontId,
        sellerId: ownerId,
        storageKey,
        contentType: req.file.mimetype,
        fileSize: req.file.size,
        sortOrder,
      }),
      product: toSellerProductDTO(updated),
    });
  });

  router.get("/products/:productId/images", async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, param(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    const rows = await productImageRows(prisma, existing.id);
    const primaryUrl = existing.imageUrl || parseJsonArray(existing.imageUrlsJson)[0] || null;
    res.json(rows.map((row) => productImageDTO({
      imageId: row.id,
      url: row.url,
      productId: row.productId,
      storeId: row.storeId,
      sellerId: row.sellerId,
      storageKey: row.storageKey,
      contentType: row.contentType,
      fileSize: row.fileSize,
      sortOrder: row.sortOrder,
      isPrimary: row.url === primaryUrl,
      thumbnailUrl: row.thumbnailUrl,
    })));
  });

  router.delete("/products/:productId/images/:imageId", async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, param(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    const imageId = decodeURIComponent(req.params.imageId);
    const rows = await prisma.$queryRaw<Array<{ url: string }>>`
      SELECT "url" FROM "ProductImage" WHERE "id" = ${imageId} AND "productId" = ${existing.id} LIMIT 1
    `;
    const imageUrl = rows[0]?.url ?? imageId;
    const nextImages = parseJsonArray(existing.imageUrlsJson).filter((url) => url !== imageUrl);
    const currentStatus = String((existing as any).status ?? (existing.published ? "active" : "draft"));
    if (existing.published && currentStatus !== "draft" && nextImages.length === 0) {
      return res.status(400).json({ error: "primary_image_required", message: "Add a replacement image or return the product to draft before deleting the last image." });
    }
    await prisma.$executeRaw`
      DELETE FROM "ProductImage" WHERE ("id" = ${imageId} OR "url" = ${imageUrl}) AND "productId" = ${existing.id}
    `;
    const updated = await prisma.storefrontProduct.update({
      where: { id: existing.id },
      data: {
        imageUrl: nextImages[0] ?? null,
        imageUrlsJson: JSON.stringify(nextImages),
      },
    });
    res.json(toSellerProductDTO(updated));
  });

  router.patch("/products/:productId/images/reorder", async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, param(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    const parsed = z.object({ imageUrls: z.array(z.string().url()) }).safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const allowed = new Set(parseJsonArray(existing.imageUrlsJson));
    const nextImages = parsed.data.imageUrls.filter((url) => allowed.has(url));
    for (const [index, url] of nextImages.entries()) {
      await prisma.$executeRaw`UPDATE "ProductImage" SET "sortOrder" = ${index} WHERE "productId" = ${existing.id} AND "url" = ${url}`;
    }
    const updated = await prisma.storefrontProduct.update({
      where: { id: existing.id },
      data: {
        imageUrl: nextImages[0] ?? existing.imageUrl,
        imageUrlsJson: JSON.stringify(nextImages),
      },
    });
    res.json(toSellerProductDTO(updated));
  });

  router.patch("/products/:productId/images/:imageId/primary", async (req, res) => {
    const ownerId = userId(req);
    const existing = await sellerProduct(prisma, ownerId, param(req.params.productId));
    if (!existing) return res.status(404).json({ error: "product_not_found" });
    const imageId = decodeURIComponent(req.params.imageId);
    const rows = await prisma.$queryRaw<Array<{ id: string; url: string }>>`
      SELECT "id", "url" FROM "ProductImage" WHERE "id" = ${imageId} AND "productId" = ${existing.id} LIMIT 1
    `;
    const imageUrl = rows[0]?.url ?? imageId;
    const allowed = new Set(parseJsonArray(existing.imageUrlsJson));
    if (!allowed.has(imageUrl)) return res.status(404).json({ error: "image_not_found" });
    const nextImages = [imageUrl, ...parseJsonArray(existing.imageUrlsJson).filter((url) => url !== imageUrl)];
    for (const [index, url] of nextImages.entries()) {
      await prisma.$executeRaw`UPDATE "ProductImage" SET "sortOrder" = ${index} WHERE "productId" = ${existing.id} AND "url" = ${url}`;
    }
    const updated = await prisma.storefrontProduct.update({
      where: { id: existing.id },
      data: {
        imageUrl,
        imageUrlsJson: JSON.stringify(nextImages),
      },
    });
    res.json(toSellerProductDTO(updated));
  });

  router.use((error: unknown, _req: express.Request, res: express.Response, next: express.NextFunction) => {
    if (error instanceof multer.MulterError) {
      res.status(error.code === "LIMIT_FILE_SIZE" ? 413 : 400).json({ error: "invalid_upload", message: error.code === "LIMIT_FILE_SIZE" ? "Images must be 10MB or smaller." : "Only jpg, png, and webp images are supported." });
      return;
    }
    next(error);
  });

  return router;
}

const storeInclude = { products: true, collections: true, theme: true, policy: true } as const;

async function primaryStorefront(prisma: PrismaClient, ownerId: string) {
  return prisma.storefront.findFirst({
    where: { ownerId },
    include: storeInclude,
    orderBy: [{ updatedAt: "desc" }],
  });
}

async function sellerProduct(prisma: PrismaClient, ownerId: string, productId: string) {
  return prisma.storefrontProduct.findFirst({
    where: { id: productId, storefront: { ownerId } },
  });
}

function userId(req: express.Request): string {
  return (req as AuthenticatedRequest).userId;
}

function param(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

function launchChecklist(store: Awaited<ReturnType<typeof primaryStorefront>>): string[] {
  if (!store) return ["Create a storefront"];
  const checklist: string[] = [];
  if (!store.name.trim()) checklist.push("Add business name");
  if (!store.description.trim()) checklist.push("Add description");
  if (!store.category.trim()) checklist.push("Choose category");
  if (!store.products.some((product) => isBuyerVisible(product))) checklist.push("Add at least one active product");
  return checklist;
}

function isBuyerVisible(product: StorefrontProduct): boolean {
  const status = String((product as any).status ?? (product.published ? "active" : "draft"));
  return product.published && status !== "draft" && status !== "archived";
}

function productData(storeId: string, input: z.infer<typeof productSchema>, imageUrls: string[]) {
  const active = input.status === "active";
  return {
    storefrontId: storeId,
    name: input.title,
    description: input.description,
    price: (input.priceCents / 100).toFixed(2),
    imageUrl: imageUrls[0] ?? null,
    imageUrlsJson: JSON.stringify(imageUrls),
    inventory: input.inventoryCount,
    category: input.category ?? null,
    paymentMode: input.paymentMode,
    paymentLinkUrl: input.paymentLinkUrl ?? null,
    published: active,
    currency: input.currency,
    status: input.status,
    publishedAt: active ? new Date() : null,
  } as any;
}

function productPatchData(input: z.infer<typeof productPatchSchema>, imageUrls?: string[]) {
  const status = input.status;
  return {
    name: input.title,
    description: input.description,
    price: input.priceCents == null ? undefined : (input.priceCents / 100).toFixed(2),
    imageUrl: imageUrls === undefined ? undefined : imageUrls[0] ?? null,
    imageUrlsJson: imageUrls === undefined ? undefined : JSON.stringify(imageUrls),
    inventory: input.inventoryCount,
    category: input.category,
    paymentMode: input.paymentMode,
    paymentLinkUrl: input.paymentLinkUrl,
    published: status == null ? undefined : status === "active",
    currency: input.currency,
    status,
    publishedAt: status === "active" ? new Date() : undefined,
  } as any;
}

function toSellerStorefrontDTO(store: NonNullable<Awaited<ReturnType<typeof primaryStorefront>>>) {
  return {
    id: store.id,
    ownerId: store.ownerId,
    sellerId: store.ownerId,
    name: store.name,
    handle: store.handle,
    slug: store.slug,
    logoUrl: store.logoUrl,
    bannerUrl: store.bannerUrl,
    description: store.description,
    category: store.category,
    tagline: store.tagline,
    storeStatus: store.published ? "published" : "draft",
    status: store.published ? "published" : "draft",
    published: store.published,
    searchable: Boolean((store as any).searchable ?? store.published),
    publicVisible: Boolean((store as any).publicVisible ?? store.published),
    launchedAt: dateString((store as any).launchedAt),
    paymentsEnabled: store.paymentsEnabled,
    defaultPaymentMode: store.defaultPaymentMode,
    defaultPaymentLinkUrl: store.defaultPaymentLinkUrl,
    products: store.products.map(toSellerProductDTO),
  };
}

function toSellerProductDTO(product: StorefrontProduct) {
  const imageUrls = parseJsonArray(product.imageUrlsJson);
  const primaryImageUrl = product.imageUrl || imageUrls[0] || null;
  const active = isBuyerVisible(product);
  return {
    productId: product.id,
    id: product.id,
    storeId: product.storefrontId,
    sellerId: null,
    title: product.name,
    name: product.name,
    description: product.description,
    price: product.price,
    priceCents: Math.round(Number(product.price) * 100),
    currency: String((product as any).currency ?? "USD"),
    images: imageUrls.map((url, index) => productImageDTO({
      url,
      productId: product.id,
      storeId: product.storefrontId,
      sellerId: "",
      storageKey: url,
      contentType: contentTypeForUrl(url),
      fileSize: 0,
      sortOrder: index,
      isPrimary: url === primaryImageUrl,
    })),
    imageUrls,
    primaryImageUrl,
    mediaURL: primaryImageUrl,
    inventoryCount: product.inventory,
    inventory: product.inventory,
    isAvailable: active && (!(product.trackInventory ?? true) || product.inventory > 0),
    category: product.category,
    paymentMode: product.paymentMode,
    paymentLinkUrl: product.paymentLinkUrl,
    publishedAt: dateString((product as any).publishedAt),
    status: active ? "active" : String((product as any).status ?? "draft"),
  };
}

function productImageDTO(input: {
  imageId?: string;
  url: string;
  productId: string;
  storeId: string;
  sellerId: string;
  storageKey: string;
  contentType: string;
  fileSize: number;
  sortOrder: number;
  isPrimary?: boolean;
  thumbnailUrl?: string | null;
}) {
  return {
    imageId: input.imageId ?? encodeURIComponent(input.url),
    productId: input.productId,
    storeId: input.storeId,
    sellerId: input.sellerId,
    storageKey: input.storageKey,
    url: input.url,
    thumbnailUrl: input.thumbnailUrl ?? input.url,
    mediumUrl: input.url,
    originalUrl: input.url,
    width: null,
    height: null,
    contentType: input.contentType,
    mimeType: input.contentType,
    fileSize: input.fileSize,
    sortOrder: input.sortOrder,
    isPrimary: Boolean(input.isPrimary),
    altText: null,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
}

async function productImageRows(prisma: PrismaClient, productId: string) {
  return prisma.$queryRaw<Array<{
    id: string;
    productId: string;
    storeId: string;
    sellerId: string;
    storageKey: string;
    url: string;
    thumbnailUrl: string | null;
    contentType: string;
    fileSize: number;
    sortOrder: number;
  }>>`
    SELECT "id", "productId", "storeId", "sellerId", "storageKey", "url", "thumbnailUrl", "contentType", "fileSize", "sortOrder"
    FROM "ProductImage"
    WHERE "productId" = ${productId}
    ORDER BY "sortOrder" ASC, "createdAt" ASC
  `;
}

function normalizedImages(images: string[] | undefined, primaryImageUrl: string | null | undefined): string[] {
  const values = [...(images ?? [])];
  if (primaryImageUrl) values.unshift(primaryImageUrl);
  return Array.from(new Set(values.filter(Boolean)));
}

function parseJsonArray(value: string | null | undefined): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string" && item.length > 0) : [];
  } catch {
    return [];
  }
}

async function saveProductImage(req: express.Request, storageKey: string, buffer: Buffer): Promise<string> {
  const uploadsRoot = process.env.UPLOADS_DIR?.trim() || path.join(process.cwd(), "uploads");
  const absolutePath = path.join(uploadsRoot, storageKey);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, buffer);
  return `${req.protocol}://${req.get("host")}/uploads/${storageKey}`;
}

function extensionFor(mimeType: string): string {
  if (mimeType === "image/png") return "png";
  if (mimeType === "image/webp") return "webp";
  return "jpg";
}

function hasValidImageSignature(buffer: Buffer, mimeType: string): boolean {
  if (mimeType === "image/jpeg") return buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
  if (mimeType === "image/png") return buffer.length >= 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  if (mimeType === "image/webp") return buffer.length >= 12 && buffer.subarray(0, 4).toString("ascii") === "RIFF" && buffer.subarray(8, 12).toString("ascii") === "WEBP";
  return false;
}

function contentTypeForUrl(url: string): string {
  const lower = url.toLowerCase();
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".webp")) return "image/webp";
  return "image/jpeg";
}

function dateString(value: unknown): string | null {
  return value instanceof Date ? value.toISOString() : typeof value === "string" ? value : null;
}

function payloadShape(value: unknown): string[] {
  return value && typeof value === "object" && !Array.isArray(value)
    ? Object.keys(value as Record<string, unknown>).sort()
    : [];
}

let sellerColumnsReady = false;

async function ensureSellerRuntimeColumns(prisma: PrismaClient): Promise<void> {
  if (sellerColumnsReady) return;
  await addColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"searchable" BOOLEAN NOT NULL DEFAULT false`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"publicVisible" BOOLEAN NOT NULL DEFAULT false`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"launchedAt" TIMESTAMP`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"setupCompleted" BOOLEAN NOT NULL DEFAULT false`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"setupCompletedAt" TIMESTAMP`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"setupVersion" TEXT`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"currency" TEXT NOT NULL DEFAULT 'USD'`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"publishedAt" TIMESTAMP`, logPrefix: "seller schema patch" });
  await addColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"status" TEXT NOT NULL DEFAULT 'draft'`, logPrefix: "seller schema patch" });
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "ProductImage" (
      "id" TEXT PRIMARY KEY,
      "productId" TEXT NOT NULL,
      "storeId" TEXT NOT NULL,
      "sellerId" TEXT NOT NULL,
      "storageKey" TEXT NOT NULL,
      "url" TEXT NOT NULL,
      "thumbnailUrl" TEXT,
      "width" INTEGER,
      "height" INTEGER,
      "contentType" TEXT NOT NULL,
      "fileSize" INTEGER NOT NULL,
      "sortOrder" INTEGER NOT NULL DEFAULT 0,
      "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ProductImage_productId_sortOrder_idx" ON "ProductImage" ("productId", "sortOrder")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ProductImage_storeId_idx" ON "ProductImage" ("storeId")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ProductImage_sellerId_idx" ON "ProductImage" ("sellerId")`);
  sellerColumnsReady = true;
}
