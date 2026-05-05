import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { toProductDTO } from "../services/catalog";

const createAdSchema = z.object({
  productId: z.string().uuid(),
  budget: z.number().positive(),
  featured: z.boolean().optional(),
});

const trackSchema = z.object({
  adId: z.string().uuid(),
});

export function adsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.post("/create", authMiddleware, async (req, res) => {
    const parsed = createAdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    const product = await prisma.storefrontProduct.findFirst({
      where: {
        id: parsed.data.productId,
        storefront: { ownerId: userId },
      },
    });
    if (!product) {
      res.status(404).json({ error: "product_not_found" });
      return;
    }

    const ad = await prisma.ad.create({
      data: {
        productId: product.id,
        budget: parsed.data.budget,
        featured: parsed.data.featured ?? false,
      },
    });
    res.status(201).json(ad);
  });

  router.get("/feed", async (_req, res) => {
    const ads = await prisma.ad.findMany({
      where: {
        active: true,
        product: {
          published: true,
          storefront: { published: true },
        },
      },
      include: { product: true },
      orderBy: [{ featured: "desc" }, { updatedAt: "desc" }],
      take: 12,
    });

    res.json(
      ads.map((ad) => ({
        id: ad.id,
        budget: ad.budget,
        clicks: ad.clicks,
        impressions: ad.impressions,
        featured: ad.featured,
        product: toProductDTO(ad.product),
      }))
    );
  });

  router.post("/track-click", async (req, res) => {
    const parsed = trackSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const ad = await prisma.ad.update({
      where: { id: parsed.data.adId },
      data: { clicks: { increment: 1 } },
    });
    res.json({ ok: true, clicks: ad.clicks });
  });

  router.post("/track-view", async (req, res) => {
    const parsed = trackSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const ad = await prisma.ad.update({
      where: { id: parsed.data.adId },
      data: { impressions: { increment: 1 } },
    });
    res.json({ ok: true, impressions: ad.impressions });
  });

  return router;
}
