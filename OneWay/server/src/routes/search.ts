import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { parseAuthToken } from "../middleware/auth";
import { getDevUserId } from "./helpers";
import { toStoreDTO, toProductDTO } from "../services/catalog";

const querySchema = z.object({
  q: z.string().min(1),
  scope: z.enum(["shop", "manage"]).optional()
});

export function searchRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.get("/", async (req, res) => {
    const parsed = querySchema.safeParse(req.query);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const bearer = typeof req.headers.authorization === "string" && req.headers.authorization.startsWith("Bearer ")
      ? req.headers.authorization.slice("Bearer ".length).trim()
      : undefined;
    const maybeUserId = parseAuthToken(bearer) ?? getDevUserId(req);
    const q = parsed.data.q.toLowerCase();
    const manageScope = parsed.data.scope === "manage";

    const stores = await prisma.storefront.findMany({
      where: {
        ...(manageScope ? { ownerId: maybeUserId } : { published: true }),
        OR: [
          { name: { contains: q } },
          { category: { contains: q } },
          { slug: { contains: q } }
        ]
      },
      include: {
        products: {
          where: manageScope ? undefined : { published: true },
        },
        collections: true,
        theme: true,
      }
    });

    const results: any[] = [];
    for (const s of stores) {
      results.push({
        id: cryptoRandomUUID(),
        title: s.name,
        subtitle: s.tagline || null,
        kind: "storefront",
        storefront: toStoreDTO(s),
        product: null,
        category: s.category
      });

      for (const p of s.products) {
        if (p.name.toLowerCase().includes(q) || p.description.toLowerCase().includes(q)) {
          results.push({
            id: cryptoRandomUUID(),
            title: p.name,
            subtitle: s.name,
            kind: "product",
            storefront: toStoreDTO(s),
            product: toProductDTO(p),
            category: s.category
          });
        }
      }
    }

    res.json(results);
  });

  return router;
}

function cryptoRandomUUID(): string {
  // Node 18+ exposes crypto.randomUUID, but keep a tiny fallback.
  const c: any = globalThis.crypto as any;
  if (c?.randomUUID) return c.randomUUID();
  return "00000000-0000-0000-0000-000000000000";
}
