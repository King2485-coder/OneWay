import express from "express";
import { z } from "zod";

import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord } from "../services/identity";
import { EXTRA_NUMBERS_PRODUCT_ID } from "../services/numbers";

const appStoreSyncSchema = z.object({
  productId: z.literal(EXTRA_NUMBERS_PRODUCT_ID),
  transactionId: z.string().trim().min(1).max(128),
  originalTransactionId: z.string().trim().min(1).max(128).optional(),
  expiresAt: z.string().datetime().optional(),
});

export function subscriptionsRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.post("/app-store/sync", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = appStoreSyncSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const expiresAt = parsed.data.expiresAt ? new Date(parsed.data.expiresAt) : null;
    const existing = await prisma.subscription.findFirst({
      where: {
        userId,
        productId: parsed.data.productId,
      },
      orderBy: { updatedAt: "desc" },
    });

    const subscription = existing
      ? await prisma.subscription.update({
          where: { id: existing.id },
          data: {
            status: "active",
            expiresAt,
          },
        })
      : await prisma.subscription.create({
          data: {
            userId,
            productId: parsed.data.productId,
            status: "active",
            expiresAt,
          },
        });

    res.json({
      subscription,
      transactionId: parsed.data.transactionId,
      originalTransactionId: parsed.data.originalTransactionId,
    });
  });

  return router;
}
