import type { PrismaClient } from "@prisma/client";
import express from "express";

import { toProductDTO, toStoreDTO } from "../services/catalog";

export function featuredRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.get("/", async (_req, res) => {
    const [products, stores] = await Promise.all([
      prisma.storefrontProduct.findMany({
        where: {
          featured: true,
          published: true,
          storefront: { published: true },
        },
        take: 12,
        orderBy: { name: "asc" },
      }),
      prisma.storefront.findMany({
        where: { published: true },
        include: {
          products: {
            where: { featured: true, published: true },
            take: 3,
          },
          theme: true,
        },
        take: 8,
        orderBy: { updatedAt: "desc" },
      }),
    ]);

    res.json({
      products: products.map(toProductDTO),
      stores: stores.map(toStoreDTO),
    });
  });

  return router;
}
