import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { createStripeClient } from "../services/stripe";
import { parsePrice } from "../services/catalog";

const createOrderSchema = z.object({
  items: z.array(
    z.object({
      productId: z.string().uuid(),
      quantity: z.number().int().positive().max(20).default(1),
    })
  ).min(1),
});

export function ordersRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();
  router.use(authMiddleware);

  router.post("/", async (req, res) => {
    const parsed = createOrderSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const userId = (req as AuthenticatedRequest).userId;
    const ids = parsed.data.items.map((item) => item.productId);
    const products = await prisma.storefrontProduct.findMany({
      where: {
        id: { in: ids },
        published: true,
        storefront: { published: true },
      },
      include: { storefront: true },
    });

    if (products.length !== ids.length) {
      res.status(400).json({ error: "product_not_found" });
      return;
    }

    const productById = new Map(products.map((product) => [product.id, product]));
    const storeId = products[0]?.storefrontId ?? null;
    const lineItems = parsed.data.items.map((item) => {
      const product = productById.get(item.productId)!;
      const unitPrice = parsePrice(product.price);
      return {
        product,
        quantity: item.quantity,
        unitPrice,
        total: unitPrice * item.quantity,
      };
    });

    const total = lineItems.reduce((sum, item) => sum + item.total, 0);
    const stripe = createStripeClient();

    let stripeCheckoutId: string | undefined;
    let checkoutUrl: string | null = null;
    if (stripe) {
      const session = await stripe.checkout.sessions.create({
        payment_method_types: ["card"],
        mode: "payment",
        line_items: lineItems.map((item) => ({
          price_data: {
            currency: "usd",
            product_data: {
              name: item.product.name,
              description: item.product.description,
              images: item.product.imageUrl ? [item.product.imageUrl] : [],
            },
            unit_amount: Math.round(item.unitPrice * 100),
          },
          quantity: item.quantity,
        })),
        success_url: process.env.STRIPE_SUCCESS_URL ?? "https://oneway.app/success",
        cancel_url: process.env.STRIPE_CANCEL_URL ?? "https://oneway.app/cancel",
      });
      stripeCheckoutId = session.id;
      checkoutUrl = session.url;
    }

    const order = await prisma.order.create({
      data: {
        userId,
        storeId,
        total,
        status: stripe ? "pending_payment" : "created",
        stripeCheckoutId,
        items: {
          create: lineItems.map((item) => ({
            productId: item.product.id,
            name: item.product.name,
            quantity: item.quantity,
            unitPrice: item.unitPrice,
            imageUrl: item.product.imageUrl,
          })),
        },
      },
      include: { items: true },
    });

    res.status(201).json({
      order,
      checkoutUrl,
    });
  });

  router.get("/", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const orders = await prisma.order.findMany({
      where: { userId },
      include: { items: true },
      orderBy: { createdAt: "desc" },
    });
    res.json(orders);
  });

  return router;
}
