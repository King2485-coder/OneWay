import { partialUpdateSchema } from "../lib/patchSchema";
import type { PrismaClient, StorePolicy, Storefront, StorefrontProduct } from "@prisma/client";
import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { safeSlug, uuidSchema } from "./helpers";
import { logger } from "../lib/logger";
import { addColumnIfMissing as addRuntimeColumnIfMissing } from "../lib/runtimeSchemaPatch";
import { storefrontPublicShopUrl } from "../lib/storefrontPublicUrl";
import { shortId } from "../lib/privacy/redaction";
import { S3ObjectStorage } from "../lib/storage/S3ObjectStorage";

const bannedShopTerms = new Set(["admin", "support", "billing", "security", "oneway", "root"]);
const handlePattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const stripeConnectStatuses = ["not_started", "pending", "connected", "restricted"] as const;
const paymentModes = ["contact", "payment_link", "oneway_wallet"] as const;

const createSchema = z.object({
  name: z.string().trim().optional().default(""),
  category: z.string().trim().optional().default("General"),
  tagline: z.string().trim().optional()
});

const patchSchema = z.object({
  name: z.string().trim().min(1).optional(),
  handle: z.string().trim().min(1).optional(),
  logoUrl: z.string().trim().url().nullable().optional(),
  bannerUrl: z.string().trim().url().nullable().optional(),
  announcement: z.string().trim().nullable().optional(),
  description: z.string().trim().nullable().optional(),
  sellerStory: z.string().trim().nullable().optional(),
  category: z.string().trim().nullable().optional(),
  location: z.string().trim().nullable().optional(),
  tagline: z.string().trim().nullable().optional(),
  shippingSettingsJson: z.string().trim().nullable().optional(),
  paymentStatus: z.string().trim().nullable().optional(),
  paymentsReady: z.boolean().optional(),
  paymentsEnabled: z.boolean().optional(),
  stripeConnectStatus: z.enum(stripeConnectStatuses).optional(),
  defaultPaymentMode: z.enum(paymentModes).optional(),
  defaultPaymentLinkUrl: z.string().trim().max(2_000).nullable().optional().refine((value) => !value || isValidPublicUrl(value), {
    message: "Add a valid payment link."
  }),
  policiesReady: z.boolean().optional(),
  setupCompleted: z.boolean().optional(),
  status: z.enum(["draft", "published", "paused"]).optional(),
  published: z.boolean().optional()
});

const listingCreateSchema = z.object({
  title: z.string().trim().min(1).max(120),
  description: z.string().trim().min(1).max(4000),
  priceCents: z.number().int().nonnegative(),
  currency: z.string().trim().min(3).max(3).default("USD"),
  inventory: z.number().int().nonnegative().default(0),
  inventoryCount: z.number().int().nonnegative().optional(),
  trackInventory: z.boolean().default(true),
  lowStockThreshold: z.number().int().min(0).max(999).default(3),
  paymentMode: z.enum(paymentModes).optional().default("contact"),
  paymentLinkUrl: z.string().trim().max(2_000).optional().default("").refine((value) => !value || isValidPublicUrl(value), {
    message: "Add a valid payment link."
  }),
  category: z.string().trim().nullable().optional(),
  tags: z.array(z.string().trim().min(1)).default([]),
  imageUrls: z.array(z.string().url()).default([]),
  variants: z.array(z.string().trim().min(1)).default([]),
  shippingInfo: z.string().trim().nullable().optional(),
  returnEligible: z.boolean().default(true),
  status: z.enum(["draft", "published"]).default("draft")
});

const listingPatchSchema = partialUpdateSchema(listingCreateSchema);

const policyPatchSchema = z.object({
  returns: z.string().trim().nullable().optional(),
  refunds: z.string().trim().nullable().optional(),
  processingTime: z.string().trim().nullable().optional(),
  shipping: z.string().trim().nullable().optional(),
  support: z.string().trim().nullable().optional(),
  sections: z.record(z.string(), z.string().max(12_000)).optional()
});

export function storefrontsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.use(async (_req, _res, next) => {
    try {
      await ensureStorefrontCommerceColumns(prisma);
      next();
    } catch (error) {
      next(error);
    }
  });

  router.get("/", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const stores = await prisma.storefront.findMany({
      where: { ownerId },
      include: {
        products: true,
        collections: true,
        theme: true,
        policy: true
      },
      orderBy: [{ updatedAt: "desc" }]
    });
    res.json(stores.map(toDTO));
  });

  router.get("/me", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const stores = await prisma.storefront.findMany({
      where: { ownerId },
      include: { products: true, collections: true, theme: true, policy: true },
      orderBy: [{ updatedAt: "desc" }]
    });
    res.json(stores.map(toDTO));
  });

  router.get("/marketplace", async (req, res) => {
    const q = normalizeSearchQuery(typeof req.query.q === "string" ? req.query.q : "");
    const category = normalizeSearchQuery(typeof req.query.category === "string" ? req.query.category : "");
    const limit = parsePositiveInt(typeof req.query.limit === "string" ? req.query.limit : "", 80);

    const where = {
      status: "published" as const,
      published: true,
      ...(category
        ? {
            category: {
              contains: category
            }
          }
        : {}),
      ...(q
        ? {
            OR: [
              { name: { contains: q } },
              { tagline: { contains: q } },
              { description: { contains: q } },
              { category: { contains: q } },
              {
                products: {
                  some: {
                    published: true,
                    OR: [
                      { name: { contains: q } },
                      { description: { contains: q } },
                      { category: { contains: q } },
                    ],
                  }
                }
              },
            ],
          }
        : {}),
    };

    const stores = await prisma.storefront.findMany({
      where,
      include: {
        products: { where: { published: true } },
        collections: true,
        theme: true,
        policy: true
      },
      orderBy: [{ updatedAt: "desc" }],
      take: limit,
    });
    res.json(stores.map(toDTO));
  });

  router.get("/marketplace/:id/policies", async (req, res) => {
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return res.status(404).json({ error: "not_found" });
    const store = await prisma.storefront.findFirst({
      where: { id, status: "published", published: true },
      include: { policy: true }
    });
    if (!store?.policy || !(store.policy as any).publishedJson) {
      return res.status(404).json({ error: "policies_not_published" });
    }
    res.json(publicPolicyResponse(store.policy));
  });

  router.get("/handles/:handle/availability", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const requested = normalizeShopHandle(routeParam(req.params.handle));
    const excludeId = typeof req.query.excludeId === "string" ? req.query.excludeId : undefined;

    if (!requested || !isValidShopHandle(requested)) {
      logger.info({
        ownerId,
        handle: requested,
        excludeId,
      }, "[storefronts] handle availability invalid");
      return res.json({
        code: "invalid_handle",
        handle: requested,
        available: false,
        status: "invalid",
        message: "Use lowercase letters, numbers, and hyphens."
      });
    }

    const taken = await prisma.storefront.findFirst({
      where: {
        OR: [{ handle: requested }, { slug: requested }],
        ...(excludeId && uuidSchema.safeParse(excludeId).success ? { NOT: { id: excludeId } } : {})
      },
      select: { id: true }
    });

    logger.info({
      ownerId,
      handle: requested,
      excludeId,
      available: !taken,
    }, "[storefronts] handle availability checked");

    res.json({
      code: taken ? "duplicate_handle" : "available",
      handle: requested,
      available: !taken,
      status: taken ? "taken" : "available",
      message: taken ? "That shop link is already taken." : "Available"
    });
  });

  router.post("/", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const suppliedKey = String(req.header("Idempotency-Key") ?? "").trim();
    const idempotencyKey = suppliedKey.length >= 8 && suppliedKey.length <= 128 ? suppliedKey : randomUUID();
    const correlationId = String(req.header("X-Correlation-ID") ?? idempotencyKey).slice(0, 36);
    const parsed = createSchema.safeParse(req.body);
    logger.info({
      ownerId: shortId(ownerId),
      correlationId,
      payloadShape: payloadShape(req.body),
    }, "[storefronts] create requested");
    if (!parsed.success) {
      logger.warn({
        ownerId,
        issues: parsed.error.issues,
        payloadShape: payloadShape(req.body),
      }, "[storefronts] create validation failed");
      return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", parsed.error.issues[0]?.path?.join("."));
    }

    const ownerReady = await ensureStorefrontOwner(prisma, ownerId);
    if (!ownerReady) {
      logger.warn({ ownerId }, "[storefronts] create blocked by missing profile");
      return sendStorefrontError(res, 403, "profile_required", "Finish account setup before creating a shop.");
    }

    const replay = await storefrontCreationReplay(prisma, ownerId, idempotencyKey);
    if (replay) {
      logger.info({ ownerId: shortId(ownerId), correlationId, storefrontId: replay.id }, "[storefronts] create replayed");
      return res.status(200).json(toDTO(replay));
    }

    const owner = await prisma.user.findUnique({ where: { id: ownerId }, select: { displayName: true } });
    const name = safeShopName(parsed.data.name, owner?.displayName);
    const category = parsed.data.category || "General";
    const { tagline } = parsed.data;
    const handle = await uniqueHandle(prisma, safeSlug(name));
    logger.info({
      ownerId,
      handle,
      requestedNameLength: name.length,
    }, "[storefronts] create handle selected");
    if (bannedShopTerms.has(handle)) {
      logger.warn({ ownerId, handle }, "[storefronts] create invalid reserved handle");
      return sendStorefrontError(res, 400, "invalid_handle", "That shop link cannot be used.", "handle");
    }

    try {
      const store = await prisma.$transaction(async (tx) => {
        const created = await tx.storefront.create({
          data: {
          ownerId,
          name,
          handle,
          slug: handle,
          description: "",
          category,
          tagline: tagline || null,
          status: "draft",
          paymentStatus: "pending",
          paymentsReady: false,
          paymentsEnabled: false,
          stripeConnectStatus: process.env.NODE_ENV !== "production" ? "connected" : "not_started",
          defaultPaymentMode: "contact",
          defaultPaymentLinkUrl: null,
          policiesReady: false,
          published: false,
          searchable: false,
          publicVisible: false,
          setupCompleted: true,
          setupCompletedAt: new Date(),
          setupVersion: "business-setup-v1",
          policy: { create: defaultPolicy() },
          theme: { create: { primaryHex: "#111827", accentHex: "#2563EB", background: "light", font: "SFPro" } }
          } as any,
          include: { products: true, collections: true, theme: true, policy: true }
        });
        await tx.$executeRawUnsafe(
          `INSERT INTO "storefront_creation_attempts" ("owner_id", "idempotency_key", "storefront_id") VALUES (?, ?, ?)`,
          ownerId,
          idempotencyKey,
          created.id,
        );
        return created;
      });
      res.setHeader("X-Correlation-ID", correlationId);
      res.status(201).json(toDTO(store));
    } catch (error) {
      const recovered = await storefrontCreationReplay(prisma, ownerId, idempotencyKey).catch(() => null);
      if (recovered) {
        logger.info({ ownerId: shortId(ownerId), correlationId, storefrontId: recovered.id }, "[storefronts] create recovered after retry race");
        return res.status(200).json(toDTO(recovered));
      }
      logger.error({ ownerId, err: error }, "[storefronts] create prisma failed");
      if (isPrismaUniqueError(error)) {
        return sendStorefrontError(res, 409, "duplicate_handle", "That shop link is already taken.", "handle");
      }
      res.status(500).json(structuredStorefrontError("backend_unavailable", "We couldn't reach OneWay right now."));
    }
  });

  router.get("/id/:id", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true, collections: true, theme: true, policy: true }
    });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");
    res.json(toDTO(store));
  });

  router.patch("/:id", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");

    const parsed = patchSchema.safeParse(req.body);
    logger.info({
      ownerId,
      storefrontId: id,
      payloadShape: payloadShape(req.body),
    }, "[storefronts] update requested");
    if (!parsed.success) {
      logger.warn({
        ownerId,
        storefrontId: id,
        issues: parsed.error.issues,
        payloadShape: payloadShape(req.body),
      }, "[storefronts] update validation failed");
      return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", parsed.error.issues[0]?.path?.join("."));
    }

    const existing = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!existing) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");

    let handle: string | undefined;
    if (parsed.data.handle || parsed.data.name) {
      handle = normalizeShopHandle(parsed.data.handle ?? parsed.data.name ?? existing.handle);
      logger.info({
        ownerId,
        storefrontId: id,
        requestedHandle: parsed.data.handle ?? null,
        normalizedHandle: handle,
      }, "[storefronts] update duplicate handle check");
      if (!handle || !isValidShopHandle(handle)) {
        return sendStorefrontError(res, 400, "invalid_handle", "Use lowercase letters, numbers, and hyphens.", "handle");
      }
      if (bannedShopTerms.has(handle)) {
        return sendStorefrontError(res, 400, "invalid_handle", "That shop link cannot be used.", "handle");
      }
      const taken = await prisma.storefront.findFirst({
        where: {
          OR: [{ handle }, { slug: handle }],
          NOT: { id }
        }
      });
      if (taken) {
        logger.warn({
          ownerId,
          storefrontId: id,
          handle,
          takenBy: taken.id,
        }, "[storefronts] update duplicate handle found");
        return sendStorefrontError(res, 409, "duplicate_handle", "That shop link is already taken.", "handle");
      }
    }

    try {
      const store = await prisma.storefront.update({
        where: { id },
        data: {
          name: parsed.data.name ?? undefined,
          handle: handle ?? undefined,
          slug: handle ?? undefined,
          logoUrl: parsed.data.logoUrl ?? undefined,
          bannerUrl: parsed.data.bannerUrl ?? undefined,
          announcement: parsed.data.announcement ?? undefined,
          description: parsed.data.description ?? undefined,
          sellerStory: parsed.data.sellerStory ?? undefined,
          category: parsed.data.category ?? undefined,
          location: parsed.data.location ?? undefined,
          tagline: parsed.data.tagline ?? undefined,
          shippingSettingsJson: parsed.data.shippingSettingsJson ?? undefined,
          paymentStatus: parsed.data.paymentStatus ?? undefined,
          paymentsReady: parsed.data.paymentsReady ?? undefined,
          paymentsEnabled: parsed.data.paymentsEnabled ?? undefined,
          stripeConnectStatus: parsed.data.stripeConnectStatus ?? undefined,
          defaultPaymentMode: parsed.data.defaultPaymentMode == null
            ? undefined
            : normalizeStorefrontPaymentMode(parsed.data.defaultPaymentMode),
          defaultPaymentLinkUrl: parsed.data.defaultPaymentLinkUrl === undefined ? undefined : parsed.data.defaultPaymentLinkUrl || null,
          policiesReady: parsed.data.policiesReady ?? undefined,
          setupCompleted: parsed.data.setupCompleted ?? undefined,
          setupCompletedAt: parsed.data.setupCompleted ? ((existing as any).setupCompletedAt ?? new Date()) : undefined,
          setupVersion: parsed.data.setupCompleted ? ((existing as any).setupVersion ?? "business-setup-v1") : undefined,
          status: parsed.data.status ?? undefined,
          published: parsed.data.published ?? undefined
        } as any,
        include: { products: true, collections: true, theme: true, policy: true }
      });
      logger.info({
        ownerId,
        storefrontId: shortId(store.id, 8),
        existingHandle: existing.handle ?? existing.slug,
        requestedHandle: parsed.data.handle ?? parsed.data.name ?? null,
        resultHandle: store.handle ?? store.slug,
      }, "[storefronts] update applied");
      res.json(toDTO(store));
    } catch (error) {
      logger.error({
        ownerId,
        storefrontId: id,
        err: error,
        payloadShape: payloadShape(req.body),
      }, "[storefronts] update prisma failed");
      if (isPrismaUniqueError(error)) {
        return sendStorefrontError(res, 409, "duplicate_handle", "That shop link is already taken.", "handle");
      }
      res.status(500).json(structuredStorefrontError("backend_unavailable", "We couldn't reach OneWay right now."));
    }
  });

  router.get("/:id/setup/status", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true, collections: true, theme: true, policy: true }
    });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");

    const checklist = publishChecklist(store);
    res.json({
      ok: true,
      storefrontId: store.id,
      published: store.published,
      setupComplete: checklist.length === 0,
      checklist,
      steps: storefrontSetupSteps(store),
      nextAction: nextStorefrontAction(store, checklist)
    });
  });

  router.get("/:id/listings", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true }
    });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");
    res.json(store.products.map(toListingDTO));
  });

  router.post("/:id/listings", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");
    const parsed = listingCreateSchema.safeParse(req.body);
    logger.info({ ownerId, storefrontId: id, payloadShape: payloadShape(req.body) }, "[storefronts] listing create requested");
    if (!parsed.success) {
      logger.warn({ ownerId, storefrontId: id, issues: parsed.error.issues, payloadShape: payloadShape(req.body) }, "[storefronts] listing create validation failed");
      return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", parsed.error.issues[0]?.path?.join("."));
    }

    const store = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");

    try {
      const listing = await prisma.storefrontProduct.create({
        data: {
          storefrontId: id,
          name: parsed.data.title,
          description: parsed.data.description,
          price: centsToString(parsed.data.priceCents),
          inventory: parsed.data.inventoryCount ?? parsed.data.inventory,
          trackInventory: parsed.data.trackInventory,
          lowStockThreshold: parsed.data.lowStockThreshold,
          paymentMode: normalizeStorefrontPaymentMode(parsed.data.paymentMode),
          paymentLinkUrl: parsed.data.paymentLinkUrl || null,
          category: parsed.data.category ?? null,
          tagsJson: JSON.stringify(parsed.data.tags),
          imageUrl: parsed.data.imageUrls[0] ?? null,
          imageUrlsJson: JSON.stringify(parsed.data.imageUrls),
          variantsJson: JSON.stringify(parsed.data.variants),
          shippingInfo: parsed.data.shippingInfo ?? null,
          returnEligible: parsed.data.returnEligible,
          published: parsed.data.status === "published"
        }
      });
      res.status(201).json(toListingDTO(listing));
    } catch (error) {
      logger.error({ ownerId, storefrontId: id, err: error, payloadShape: payloadShape(req.body) }, "[storefronts] listing create prisma failed");
      res.status(500).json(structuredStorefrontError("backend_unavailable", "We couldn't reach OneWay right now."));
    }
  });

  router.patch("/listings/:listingId", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const listingId = routeParam(req.params.listingId);
    if (!uuidSchema.safeParse(listingId).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "listingId");
    const parsed = listingPatchSchema.safeParse(req.body);
    if (!parsed.success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", parsed.error.issues[0]?.path?.join("."));

    const existing = await prisma.storefrontProduct.findFirst({
      where: { id: listingId, storefront: { ownerId } }
    });
    if (!existing) return sendStorefrontError(res, 404, "not_found", "That product could not be found.");

    try {
      const updated = await prisma.storefrontProduct.update({
        where: { id: listingId },
        data: {
          name: parsed.data.title ?? undefined,
          description: parsed.data.description ?? undefined,
          price: parsed.data.priceCents == null ? undefined : centsToString(parsed.data.priceCents),
          inventory: parsed.data.inventoryCount ?? parsed.data.inventory ?? undefined,
          trackInventory: parsed.data.trackInventory ?? undefined,
          lowStockThreshold: parsed.data.lowStockThreshold ?? undefined,
          paymentMode: parsed.data.paymentMode == null
            ? undefined
            : normalizeStorefrontPaymentMode(parsed.data.paymentMode),
          paymentLinkUrl: parsed.data.paymentLinkUrl === undefined ? undefined : parsed.data.paymentLinkUrl || null,
          category: parsed.data.category ?? undefined,
          tagsJson: parsed.data.tags == null ? undefined : JSON.stringify(parsed.data.tags),
          imageUrl: parsed.data.imageUrls?.[0] ?? undefined,
          imageUrlsJson: parsed.data.imageUrls == null ? undefined : JSON.stringify(parsed.data.imageUrls),
          variantsJson: parsed.data.variants == null ? undefined : JSON.stringify(parsed.data.variants),
          shippingInfo: parsed.data.shippingInfo ?? undefined,
          returnEligible: parsed.data.returnEligible ?? undefined,
          published: parsed.data.status == null ? undefined : parsed.data.status === "published"
        }
      });
      res.json(toListingDTO(updated));
    } catch (error) {
      logger.error({ ownerId, listingId, err: error, payloadShape: payloadShape(req.body) }, "[storefronts] listing update prisma failed");
      res.status(500).json(structuredStorefrontError("backend_unavailable", "We couldn't reach OneWay right now."));
    }
  });

  router.delete("/listings/:listingId", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const listingId = routeParam(req.params.listingId);
    if (!uuidSchema.safeParse(listingId).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "listingId");

    const existing = await prisma.storefrontProduct.findFirst({
      where: { id: listingId, storefront: { ownerId } }
    });
    if (!existing) return sendStorefrontError(res, 404, "not_found", "That product could not be found.");

    try {
      await prisma.storefrontProduct.delete({ where: { id: listingId } });
      res.status(204).end();
    } catch (error) {
      logger.error({ ownerId, listingId, err: error }, "[storefronts] listing delete prisma failed");
      res.status(500).json(structuredStorefrontError("backend_unavailable", "We couldn't reach OneWay right now."));
    }
  });

  router.get("/:id/policies", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { policy: true }
    });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");
    res.json(ownerPolicyResponse(store.policy));
  });

  router.patch("/:id/policies", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");
    const parsed = policyPatchSchema.safeParse(req.body);
    if (!parsed.success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", parsed.error.issues[0]?.path?.join("."));

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { policy: true, products: true }
    });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");

    try {
      const sections = parsed.data.sections ? sanitizePolicySections(parsed.data.sections) : undefined;
      const legacyData = {
        returns: sections?.returnsAndExchanges ?? parsed.data.returns,
        refunds: sections?.refunds ?? parsed.data.refunds,
        processingTime: sections?.processingTimes ?? parsed.data.processingTime,
        shipping: sections?.shippingAndDelivery ?? parsed.data.shipping,
        support: sections?.contactingTheSeller ?? parsed.data.support,
        ...(sections ? { draftJson: JSON.stringify(sections) } : {})
      };
      const policy = store.policy
        ? await prisma.storePolicy.update({
            where: { storefrontId: id },
            data: legacyData
          })
        : await prisma.storePolicy.create({
            data: {
              storefrontId: id,
              ...defaultPolicy(),
              ...legacyData
            }
          });

      const policiesReady = computePoliciesReady(policy);
      await prisma.storefront.update({
        where: { id },
        data: { policiesReady }
      });

      res.json(ownerPolicyResponse(policy));
    } catch (error) {
      logger.error({ ownerId, storefrontId: id, err: error, payloadShape: payloadShape(req.body) }, "[storefronts] policy update prisma failed");
      res.status(500).json(structuredStorefrontError("backend_unavailable", "We couldn't reach OneWay right now."));
    }
  });

  router.post("/:id/policies/publish", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please choose a shop.", "id");
    const store = await prisma.storefront.findFirst({ where: { id, ownerId }, include: { policy: true } });
    if (!store?.policy) return sendStorefrontError(res, 404, "not_found", "Save your policies before publishing.");
    const draft = parsePolicyJSON((store.policy as any).draftJson) ?? legacyPolicyDocument(store.policy);
    const sanitized = sanitizePolicySections(draft);
    const nextVersion = Math.max(0, Number((store.policy as any).publishedVersion ?? 0)) + 1;
    const publishedAt = new Date();
    const policy = await prisma.storePolicy.update({
      where: { storefrontId: id },
      data: {
        draftJson: JSON.stringify(sanitized),
        publishedJson: JSON.stringify(sanitized),
        publishedVersion: nextVersion,
        publishedAt
      }
    });
    await prisma.storefront.update({ where: { id }, data: { policiesReady: true } });
    res.json(ownerPolicyResponse(policy));
  });

  router.post("/:id/publish", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return sendStorefrontError(res, 400, "validation_failed", "Please complete all required fields.", "id");

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true, collections: true, theme: true, policy: true }
    });
    if (!store) return sendStorefrontError(res, 404, "not_found", "That shop could not be found.");

    const owner = await prisma.user.findUnique({ where: { id: ownerId }, select: { displayName: true } });
    const name = safeShopName(store.name, owner?.displayName);
    const currentHandle = normalizeShopHandle(store.handle);
    const handle = isValidShopHandle(currentHandle)
      ? currentHandle
      : await uniqueHandle(prisma, safeSlug(name));

    const published = await prisma.storefront.update({
      where: { id },
      data: {
        name,
        handle,
        slug: handle,
        status: "published",
        published: true,
        searchable: true,
        publicVisible: true,
        launchedAt: new Date()
      } as any,
      include: { products: true, collections: true, theme: true, policy: true }
    });
    res.json(toDTO(published));
  });

  router.post("/:id/unpublish", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    const existing = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!existing) return res.status(404).json({ error: "not_found" });

    const store = await prisma.storefront.update({
      where: { id },
      data: {
        status: "paused",
        published: false,
        searchable: false,
        publicVisible: false
      } as any,
      include: { products: true, collections: true, theme: true, policy: true }
    });
    res.json(toDTO(store));
  });

  router.delete("/:id", authMiddleware, async (req, res) => {
    const ownerId = requireStorefrontOwnerId(req);
    const id = routeParam(req.params.id);
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    const confirmation = typeof req.body?.confirmation === "string" ? req.body.confirmation.trim() : "";
    const existing = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: { include: { images: true } } }
    });
    if (!existing) return res.status(404).json({ error: "not_found" });
    if (confirmation !== "DELETE" && confirmation !== existing.name) {
      return res.status(400).json({
        error: "delete_confirmation_required",
        message: "Type the shop name or DELETE to permanently delete this shop."
      });
    }

    const productIds = existing.products.map((product) => product.id);
    const storageKeys = new Set(existing.products.flatMap((product) => product.images.map((image) => image.storageKey)));
    await prisma.$transaction(async (tx) => {
      // Conversations are intentionally not relationally coupled to Storefront so
      // existing threads can survive pause. Permanent deletion removes them.
      await tx.shopConversation.deleteMany({ where: { shopId: id } });
      // Completed orders retain only their legally necessary transaction snapshot;
      // their storefront relation becomes null through Storefront.onDelete=SetNull.
      await tx.storefront.delete({ where: { id } });
    });

    const objectStorage = S3ObjectStorage.fromEnv();
    if (objectStorage) {
      await Promise.allSettled([...storageKeys].map((key) => objectStorage.delete(key)));
    }
    logger.info({ ownerId, storefrontId: shortId(id, 8), productCount: productIds.length }, "[storefronts] permanently deleted");
    res.status(204).send();
  });

  router.get("/:handle", async (req, res) => {
    const handle = safeSlug(routeParam(req.params.handle));
    const store = await prisma.storefront.findFirst({
      where: { handle },
      include: { products: { where: { published: true } }, collections: true, theme: true, policy: true }
    });
    if (!store) return res.status(404).json({ error: "not_found" });
    if (store.status === "paused") {
      return res.status(409).json({ error: "shop_paused", message: "This shop is temporarily unavailable." });
    }
    if (store.status !== "published" || !store.published) return res.status(404).json({ error: "not_found" });
    res.json(toDTO(store));
  });

  return router;
}

function routeParam(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

function requireStorefrontOwnerId(req: express.Request): string {
  return (req as AuthenticatedRequest).userId;
}

function payloadShape(body: unknown): Record<string, string> {
  if (!body || typeof body !== "object" || Array.isArray(body)) return {};
  return Object.fromEntries(
    Object.entries(body as Record<string, unknown>).map(([key, value]) => {
      if (Array.isArray(value)) return [key, "array"];
      if (value === null) return [key, "null"];
      return [key, typeof value];
    })
  );
}

function normalizeShopHandle(value: string | null | undefined): string {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function normalizeSearchQuery(value: string): string {
  return value.trim();
}

function parsePositiveInt(value: string, fallback: number): number {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(parsed, 200);
}

function isValidShopHandle(value: string): boolean {
  return handlePattern.test(value) && !bannedShopTerms.has(value);
}

function structuredStorefrontError(code: string, message: string, field?: string) {
  return {
    code,
    error: code,
    message,
    ...(field ? { field } : {})
  };
}

function sendStorefrontError(
  res: express.Response,
  status: number,
  code: string,
  message: string,
  field?: string
) {
  return res.status(status).json(structuredStorefrontError(code, message, field));
}

function isPrismaUniqueError(error: unknown): boolean {
  return typeof error === "object"
    && error !== null
    && "code" in error
    && (error as { code?: string }).code === "P2002";
}

async function uniqueHandle(prisma: PrismaClient, base: string): Promise<string> {
  let candidate = base;
  let counter = 1;
  while (await prisma.storefront.findFirst({ where: { OR: [{ handle: candidate }, { slug: candidate }] } })) {
    candidate = `${base}-${counter++}`;
  }
  return candidate;
}

async function ensureStorefrontOwner(prisma: PrismaClient, ownerId: string): Promise<boolean> {
  const existing = await prisma.user.findUnique({ where: { id: ownerId }, select: { id: true } });
  if (existing) return true;

  if (process.env.NODE_ENV === "production") {
    return false;
  }

  await prisma.user.create({
    data: {
      id: ownerId,
      email: null,
      displayName: ownerId === "dev-user" ? "OneWay Dev Seller" : "OneWay Seller"
    }
  });
  return true;
}

function defaultPolicy() {
  return {
    returns: "Returns accepted within 14 days for eligible items.",
    refunds: "Refunds are processed after returned items are approved.",
    processingTime: "Ships within 3-5 business days.",
    shipping: "Shipping rates are defined by the seller at checkout.",
    support: "Message the seller in OneWay for support."
  };
}

const policyKeys = [
  "processingTimes", "shippingAndDelivery", "returnsAndExchanges", "refunds", "cancellations",
  "digitalProducts", "damagedOrIncorrectOrders", "privacyAndCustomerInformation", "contactingTheSeller", "customPolicy"
] as const;

function sanitizePolicyText(value: unknown): string {
  return String(value ?? "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim().slice(0, 12_000);
}

function sanitizePolicySections(input: Record<string, unknown>): Record<string, string> {
  return Object.fromEntries(policyKeys.map((key) => [key, sanitizePolicyText(input[key])]));
}

function parsePolicyJSON(value: unknown): Record<string, string> | null {
  if (typeof value !== "string" || !value) return null;
  try { return sanitizePolicySections(JSON.parse(value)); } catch { return null; }
}

function legacyPolicyDocument(policy: Partial<StorePolicy>): Record<string, string> {
  return sanitizePolicySections({
    processingTimes: policy.processingTime,
    shippingAndDelivery: policy.shipping,
    returnsAndExchanges: policy.returns,
    refunds: policy.refunds,
    contactingTheSeller: policy.support
  });
}

function ownerPolicyResponse(policy: StorePolicy | null | undefined) {
  if (!policy) return { sections: null, publishedSections: null, version: 0, status: "example", createdAt: null, updatedAt: null, publishedAt: null };
  const draft = parsePolicyJSON((policy as any).draftJson) ?? legacyPolicyDocument(policy);
  const published = parsePolicyJSON((policy as any).publishedJson);
  return {
    sections: draft,
    publishedSections: published,
    version: Number((policy as any).publishedVersion ?? 0),
    status: published ? "published" : "draft",
    createdAt: (policy as any).createdAt ?? null,
    updatedAt: (policy as any).updatedAt ?? null,
    publishedAt: (policy as any).publishedAt ?? null
  };
}

function publicPolicyResponse(policy: StorePolicy) {
  return {
    sections: parsePolicyJSON((policy as any).publishedJson) ?? {},
    version: Number((policy as any).publishedVersion ?? 0),
    publishedAt: (policy as any).publishedAt ?? null
  };
}

function computePoliciesReady(policy: Partial<StorePolicy> | null | undefined) {
  if (!policy) return false;
  return [policy.returns, policy.refunds, policy.processingTime, policy.shipping, policy.support]
    .every((value) => typeof value === "string" && value.trim().length > 0);
}

function publishChecklist(store: Storefront & { products: StorefrontProduct[]; policy: StorePolicy | null }) {
  // Optional onboarding fields never block publication. Authentication and
  // ownership are enforced by the publish route; a missing name is repaired
  // with safeShopName before the database update.
  void store;
  return [];
}

function storefrontSetupSteps(store: Storefront & { products: StorefrontProduct[]; policy: StorePolicy | null }) {
  return {
    shopName: Boolean(store.name.trim()),
    description: Boolean(store.description?.trim()),
    firstProduct: store.products.some((product) => product.published),
    // Shop Messages is always available after launch. External buyer contact
    // details and payment setup are optional and never gate publication.
    buyerContact: true,
    publish: Boolean(store.published)
  };
}

function nextStorefrontAction(store: Storefront & { products: StorefrontProduct[]; policy: StorePolicy | null }, checklist: string[]) {
  if (store.published) return "Share your shop";
  if (checklist.includes("Add a shop name")) return "Name your shop";
  if (checklist.includes("Choose a valid shop link")) return "Choose your shop link";
  if (checklist.includes("Add a category") || checklist.includes("Add a shop description")) return "Tell buyers what you sell";
  if (checklist.includes("Add at least one visible product")) return "Add your first product";
  return "Publish your shop";
}

function safeShopName(name: string | null | undefined, displayName: string | null | undefined): string {
  const requested = String(name ?? "").trim();
  if (requested) return requested;
  const sellerName = String(displayName ?? "").trim();
  return sellerName ? `${sellerName}'s Shop` : "My OneWay Shop";
}

function centsToString(cents: number) {
  return (cents / 100).toFixed(2);
}

function normalizeStorefrontPaymentMode(mode: string | null | undefined): "contact" | "payment_link" | "oneway_wallet" {
  if (mode === "oneway_wallet" && !envFlag("ONEWAY_BANK_ENABLED", false)) return "contact";
  if (mode === "payment_link" || mode === "oneway_wallet") return mode;
  return "contact";
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function parseJsonArray(value?: string | null): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map((item) => String(item)) : [];
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

function toListingDTO(product: StorefrontProduct) {
  const inventoryCount = product.inventory;
  const trackInventory = product.trackInventory ?? true;
  const lowStockThreshold = product.lowStockThreshold ?? 3;
  const soldOut = trackInventory && inventoryCount <= 0;
  const lowStock = trackInventory && inventoryCount > 0 && inventoryCount <= lowStockThreshold;
  const imageUrls = parseJsonArray(product.imageUrlsJson).length > 0 ? parseJsonArray(product.imageUrlsJson) : (product.imageUrl ? [product.imageUrl] : []);
  const visibleStatus = product.published ? "active" : "draft";
  return {
    id: product.id,
    productId: product.id,
    storefrontId: product.storefrontId,
    storeId: product.storefrontId,
    title: product.name,
    name: product.name,
    description: product.description,
    priceCents: Math.round(Number(product.price) * 100),
    price: product.price,
    currency: "USD",
    inventory: product.inventory,
    inventoryCount,
    isAvailable: product.published && (!trackInventory || inventoryCount > 0),
    trackInventory,
    soldOut,
    lowStock,
    lowStockThreshold,
    paymentMode: normalizeStorefrontPaymentMode(product.paymentMode ?? "contact"),
    paymentLinkUrl: product.paymentLinkUrl ?? null,
    category: product.category,
    tags: parseJsonArray(product.tagsJson),
    imageUrls,
    primaryImageUrl: product.imageUrl ?? imageUrls[0] ?? null,
    mediaURL: product.imageUrl ?? imageUrls[0] ?? null,
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
      createdAt: new Date().toISOString()
    })),
    variants: parseJsonArray(product.variantsJson),
    shippingInfo: product.shippingInfo,
    returnEligible: product.returnEligible,
    status: visibleStatus
  };
}

let storefrontCommerceColumnsReady = false;

async function storefrontCreationReplay(prisma: PrismaClient, ownerId: string, idempotencyKey: string): Promise<any | null> {
  const rows = await prisma.$queryRawUnsafe<Array<{ storefront_id: string }>>(
    `SELECT "storefront_id" FROM "storefront_creation_attempts" WHERE "owner_id" = ? AND "idempotency_key" = ? LIMIT 1`,
    ownerId,
    idempotencyKey,
  );
  const storefrontId = rows[0]?.storefront_id;
  if (!storefrontId) return null;
  return prisma.storefront.findFirst({
    where: { id: storefrontId, ownerId },
    include: { products: true, collections: true, theme: true, policy: true },
  });
}

export async function ensureStorefrontCommerceColumns(prisma: PrismaClient): Promise<void> {
  if (storefrontCommerceColumnsReady) return;
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"trackInventory" BOOLEAN NOT NULL DEFAULT true` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"lowStockThreshold" INTEGER NOT NULL DEFAULT 3` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"paymentMode" TEXT NOT NULL DEFAULT 'contact'` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"paymentLinkUrl" TEXT` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"paymentsEnabled" BOOLEAN NOT NULL DEFAULT false` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"stripeConnectStatus" TEXT NOT NULL DEFAULT 'not_started'` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"defaultPaymentMode" TEXT NOT NULL DEFAULT 'contact'` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"defaultPaymentLinkUrl" TEXT` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"searchable" BOOLEAN NOT NULL DEFAULT false` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"publicVisible" BOOLEAN NOT NULL DEFAULT false` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"launchedAt" TIMESTAMP` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"setupCompleted" BOOLEAN NOT NULL DEFAULT false` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"setupCompletedAt" TIMESTAMP` });
  await addRuntimeColumnIfMissing(prisma, { table: "Storefront", columnDefinition: `"setupVersion" TEXT` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"currency" TEXT NOT NULL DEFAULT 'USD'` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"publishedAt" TIMESTAMP` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"status" TEXT NOT NULL DEFAULT 'draft'` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorefrontProduct", columnDefinition: `"updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorePolicy", columnDefinition: `"draftJson" TEXT` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorePolicy", columnDefinition: `"publishedJson" TEXT` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorePolicy", columnDefinition: `"publishedVersion" INTEGER NOT NULL DEFAULT 0` });
  await addRuntimeColumnIfMissing(prisma, { table: "StorePolicy", columnDefinition: `"publishedAt" DATETIME` });
  await addRuntimeColumnIfMissing(prisma, { table: "Order", columnDefinition: `"policyVersion" INTEGER` });
  await addRuntimeColumnIfMissing(prisma, { table: "Order", columnDefinition: `"policySnapshotJson" TEXT` });
  storefrontCommerceColumnsReady = true;
}

function isValidPublicUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:";
  } catch {
    return false;
  }
}

function toDTO(store: Storefront & { products?: StorefrontProduct[]; collections?: any[]; theme?: any; policy?: StorePolicy | null }) {
  const checklist = publishChecklist({
    ...store,
    products: store.products || [],
    policy: store.policy ?? null
  });

  return {
    id: store.id,
    ownerId: store.ownerId,
    name: store.name,
    handle: store.handle,
    slug: store.slug,
    shopUrl: storefrontPublicShopUrl(store.handle),
    logoUrl: store.logoUrl,
    bannerUrl: store.bannerUrl,
    announcement: store.announcement,
    description: store.description,
    sellerStory: store.sellerStory,
    category: store.category,
    location: store.location,
    tagline: store.tagline,
    shippingSettingsJson: store.shippingSettingsJson,
    paymentStatus: store.paymentStatus,
    paymentsReady: store.paymentsReady,
    paymentsEnabled: store.paymentsEnabled,
    stripeConnectStatus: store.stripeConnectStatus,
    defaultPaymentMode: normalizeStorefrontPaymentMode(store.defaultPaymentMode),
    defaultPaymentLinkUrl: store.defaultPaymentLinkUrl,
    policiesReady: store.policiesReady,
    status: store.status,
    published: store.published,
    storeStatus: store.published ? "published" : "draft",
    searchable: Boolean((store as any).searchable ?? store.published),
    publicVisible: Boolean((store as any).publicVisible ?? store.published),
    launchedAt: (store as any).launchedAt instanceof Date ? (store as any).launchedAt.toISOString() : ((store as any).launchedAt ?? null),
    setupComplete: Boolean((store as any).setupCompleted) || checklist.length === 0,
    setupCompleted: Boolean((store as any).setupCompleted) || checklist.length === 0,
    setupCompletedAt: (store as any).setupCompletedAt instanceof Date ? (store as any).setupCompletedAt.toISOString() : ((store as any).setupCompletedAt ?? null),
    setupVersion: (store as any).setupVersion ?? null,
    publishChecklist: checklist,
    products: (store.products || []).map(toListingDTO),
    collections: (store.collections || []).map((c: any) => ({ id: c.id, title: c.title })),
    theme: store.theme
      ? { primaryHex: store.theme.primaryHex, accentHex: store.theme.accentHex, background: store.theme.background, font: store.theme.font }
      : null,
    policy: store.policy ? publicPolicyResponse(store.policy) : null,
    layout: null
  };
}
