import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { getDevUserId, uuidSchema } from "./helpers";

const listingPatchSchema = z.object({
  title: z.string().trim().min(1).max(120).optional(),
  description: z.string().trim().min(1).max(4000).optional(),
  priceCents: z.number().int().nonnegative().optional(),
  inventory: z.number().int().nonnegative().optional(),
  category: z.string().trim().nullable().optional(),
  tags: z.array(z.string().trim().min(1)).optional(),
  imageUrls: z.array(z.string().url()).optional(),
  variants: z.array(z.string().trim().min(1)).optional(),
  shippingInfo: z.string().trim().nullable().optional(),
  returnEligible: z.boolean().optional(),
  status: z.enum(["draft", "published"]).optional()
});

export function listingsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.patch("/:id", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });
    const parsed = listingPatchSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const existing = await prisma.storefrontProduct.findFirst({
      where: { id, storefront: { ownerId } }
    });
    if (!existing) return res.status(404).json({ error: "not_found" });

    const updated = await prisma.storefrontProduct.update({
      where: { id },
      data: {
        name: parsed.data.title ?? undefined,
        description: parsed.data.description ?? undefined,
        price: parsed.data.priceCents == null ? undefined : (parsed.data.priceCents / 100).toFixed(2),
        inventory: parsed.data.inventory ?? undefined,
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

    res.json({
      id: updated.id,
      storefrontId: updated.storefrontId,
      title: updated.name,
      description: updated.description,
      priceCents: Math.round(Number(updated.price) * 100),
      currency: "USD",
      inventory: updated.inventory,
      category: updated.category,
      tags: updated.tagsJson ? JSON.parse(updated.tagsJson) : [],
      imageUrls: updated.imageUrlsJson ? JSON.parse(updated.imageUrlsJson) : (updated.imageUrl ? [updated.imageUrl] : []),
      variants: updated.variantsJson ? JSON.parse(updated.variantsJson) : [],
      shippingInfo: updated.shippingInfo,
      returnEligible: updated.returnEligible,
      status: updated.published ? "published" : "draft"
    });
  });

  router.delete("/:id", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!uuidSchema.safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    const existing = await prisma.storefrontProduct.findFirst({
      where: { id, storefront: { ownerId } }
    });
    if (!existing) return res.status(404).json({ error: "not_found" });

    await prisma.storefrontProduct.delete({ where: { id } });
    res.status(204).end();
  });

  return router;
}
