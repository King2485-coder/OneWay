import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { getDevUserId, safeSlug, uuidSchema } from "./helpers";

const createSchema = z.object({
  name: z.string().min(1),
  category: z.string().min(1).default("General"),
  tagline: z.string().optional()
});

const patchSchema = z.object({
  name: z.string().min(1).optional(),
  description: z.string().optional(),
  category: z.string().optional(),
  tagline: z.string().optional()
});

export function storefrontsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.get("/", async (req, res) => {
    const ownerId = getDevUserId(req);
    const stores = await prisma.storefront.findMany({
      where: { ownerId },
      include: { products: true, collections: true, theme: true }
    });
    res.json(stores.map(toDTO));
  });

  router.post("/", async (req, res) => {
    const ownerId = getDevUserId(req);
    const parsed = createSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const { name, category, tagline } = parsed.data;
    const baseSlug = safeSlug(name);
    const slug = await uniqueSlug(prisma, baseSlug);

    const store = await prisma.storefront.create({
      data: {
        ownerId,
        name,
        slug,
        description: "",
        category,
        tagline: tagline || null,
        published: false,
        theme: { create: { primaryHex: "#111827", accentHex: "#2563EB", background: "light", font: "SFPro" } }
      },
      include: { products: true, collections: true, theme: true }
    });
    res.status(201).json(toDTO(store));
  });

  router.get("/:id", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    const store = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true, collections: true, theme: true }
    });
    if (!store) return res.status(404).json({ error: "not_found" });
    res.json(toDTO(store));
  });

  router.patch("/:id", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    const parsed = patchSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    // Ensure ownership.
    const existing = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!existing) return res.status(404).json({ error: "not_found" });

    const store = await prisma.storefront.update({
      where: { id },
      data: {
        name: parsed.data.name ?? undefined,
        description: parsed.data.description ?? undefined,
        category: parsed.data.category ?? undefined,
        tagline: parsed.data.tagline ?? undefined
      },
      include: { products: true, collections: true, theme: true }
    });
    res.json(toDTO(store));
  });

  router.post("/:id/publish", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });
    const existing = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!existing) return res.status(404).json({ error: "not_found" });
    const store = await prisma.storefront.update({
      where: { id },
      data: { published: true },
      include: { products: true, collections: true, theme: true }
    });
    res.json(toDTO(store));
  });

  router.post("/:id/unpublish", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });
    const existing = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!existing) return res.status(404).json({ error: "not_found" });
    const store = await prisma.storefront.update({
      where: { id },
      data: { published: false },
      include: { products: true, collections: true, theme: true }
    });
    res.json(toDTO(store));
  });

  router.delete("/:id", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    // Ownership check.
    const existing = await prisma.storefront.findFirst({ where: { id, ownerId } });
    if (!existing) return res.status(404).json({ error: "not_found" });

    // Hard delete: relies on onDelete: Cascade in Prisma schema.
    await prisma.storefront.delete({ where: { id } });
    res.status(204).send();
  });

  return router;
}

async function uniqueSlug(prisma: PrismaClient, base: string): Promise<string> {
  let candidate = base;
  let counter = 1;
  // Ensure global uniqueness, not just per-owner.
  // Deleted storefronts are hard-deleted, so slug becomes free again.
  while (await prisma.storefront.findUnique({ where: { slug: candidate } })) {
    candidate = `${base}-${counter++}`;
  }
  return candidate;
}

function toDTO(store: any) {
  return {
    id: store.id,
    ownerId: store.ownerId,
    name: store.name,
    slug: store.slug,
    description: store.description,
    category: store.category,
    tagline: store.tagline,
    published: store.published,
    products: (store.products || []).map((p: any) => ({
      id: p.id,
      name: p.name,
      description: p.description,
      price: p.price,
      isSubscription: p.isSubscription,
      mediaURL: null
    })),
    collections: (store.collections || []).map((c: any) => ({ id: c.id, title: c.title })),
    theme: store.theme
      ? { primaryHex: store.theme.primaryHex, accentHex: store.theme.accentHex, background: store.theme.background, font: store.theme.font }
      : null,
    layout: null
  };
}

