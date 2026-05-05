import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { safeSlug } from "./helpers";
import { toStoreDTO } from "../services/catalog";

const createStoreSchema = z.object({
  name: z.string().min(1).max(80),
  description: z.string().max(500).default(""),
  category: z.string().min(1).max(80).default("General"),
  tagline: z.string().max(120).optional(),
  published: z.boolean().optional(),
});

export function storesRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.get("/", async (_req, res) => {
    const stores = await prisma.storefront.findMany({
      where: { published: true },
      include: { products: { where: { published: true } }, theme: true },
      orderBy: { updatedAt: "desc" },
    });
    res.json(stores.map(toStoreDTO));
  });

  router.post("/", authMiddleware, async (req, res) => {
    const parsed = createStoreSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const ownerId = (req as AuthenticatedRequest).userId;
    const baseSlug = safeSlug(parsed.data.name);
    const slug = await uniqueSlug(prisma, baseSlug);

    const store = await prisma.storefront.create({
      data: {
        ownerId,
        name: parsed.data.name,
        slug,
        description: parsed.data.description,
        category: parsed.data.category,
        tagline: parsed.data.tagline ?? null,
        published: parsed.data.published ?? false,
        theme: {
          create: {
            primaryHex: "#0A84FF",
            accentHex: "#30D158",
            background: "dark",
            font: "SF Pro",
          },
        },
      },
      include: { products: true, theme: true },
    });

    res.status(201).json(toStoreDTO(store));
  });

  router.get("/:id", async (req, res) => {
    const idOrSlug = req.params.id;
    const store = await prisma.storefront.findFirst({
      where: {
        published: true,
        OR: [{ id: idOrSlug }, { slug: idOrSlug }],
      },
      include: { products: { where: { published: true } }, theme: true },
    });

    if (!store) {
      res.status(404).json({ error: "not_found" });
      return;
    }

    res.json(toStoreDTO(store));
  });

  return router;
}

async function uniqueSlug(prisma: PrismaClient, base: string): Promise<string> {
  let candidate = base;
  let counter = 1;
  while (await prisma.storefront.findUnique({ where: { slug: candidate } })) {
    candidate = `${base}-${counter++}`;
  }
  return candidate;
}
