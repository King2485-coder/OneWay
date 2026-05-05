import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { toProductDTO } from "../services/catalog";

const createProductSchema = z.object({
  storeId: z.string().uuid(),
  name: z.string().min(1).max(120),
  description: z.string().max(1000).default(""),
  price: z.number().nonnegative(),
  imageUrl: z.string().url().optional(),
  featured: z.boolean().optional(),
  published: z.boolean().optional(),
  isSubscription: z.boolean().optional(),
  stripePriceId: z.string().optional(),
});

export function productsRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.get("/", async (req, res) => {
    const storeId = typeof req.query.storeId === "string" ? req.query.storeId : undefined;
    const products = await prisma.storefrontProduct.findMany({
      where: {
        published: true,
        ...(storeId ? { storefrontId: storeId } : {}),
        storefront: { published: true },
      },
      orderBy: [{ featured: "desc" }, { name: "asc" }],
    });
    res.json(products.map(toProductDTO));
  });

  router.post("/", authMiddleware, async (req, res) => {
    const parsed = createProductSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    const store = await prisma.storefront.findFirst({
      where: { id: parsed.data.storeId, ownerId: userId },
    });
    if (!store) {
      res.status(404).json({ error: "store_not_found" });
      return;
    }

    const product = await prisma.storefrontProduct.create({
      data: {
        storefrontId: store.id,
        name: parsed.data.name,
        description: parsed.data.description,
        price: parsed.data.price.toFixed(2),
        imageUrl: parsed.data.imageUrl,
        featured: parsed.data.featured ?? false,
        published: parsed.data.published ?? true,
        isSubscription: parsed.data.isSubscription ?? false,
        stripePriceId: parsed.data.stripePriceId,
      },
    });

    res.status(201).json(toProductDTO(product));
  });

  router.get("/:id", async (req, res) => {
    const product = await prisma.storefrontProduct.findFirst({
      where: {
        id: req.params.id,
        published: true,
        storefront: { published: true },
      },
    });
    if (!product) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    res.json(toProductDTO(product));
  });

  return router;
}
