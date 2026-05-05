import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { getDevUserId, safeSlug } from "./helpers";
import { generateStorefrontDraft } from "../services/ai";

const generateSchema = z.object({
  prompt: z.string().min(1),
  businessName: z.string().optional(),
  category: z.string().optional(),
  tone: z.string().optional(),
  goals: z.array(z.string()).optional(),
  preferredColors: z.array(z.string()).optional(),
  includeSections: z.array(z.string()).optional()
});

const improveSchema = z.object({
  prompt: z.string().min(1),
  /// When true, replace products/collections entirely; otherwise we merge.
  overwrite: z.boolean().optional()
});

const avatarCreateSchema = z.object({
  name: z.string().min(1).max(80),
  personality: z.string().min(1).max(200),
  voiceType: z.string().min(1).max(80),
  niche: z.string().min(1).max(80),
});

const generateContentSchema = z.object({
  avatarId: z.string().uuid().optional(),
  productId: z.string().uuid().optional(),
});

const scheduleLiveSchema = z.object({
  avatarId: z.string().uuid(),
  productId: z.string().uuid().optional(),
  scheduledFor: z.string().datetime().optional(),
  title: z.string().min(1).max(120).optional(),
});

const autoReplySchema = z.object({
  avatarId: z.string().uuid().optional(),
  message: z.string().min(1).max(500),
  context: z.string().max(500).optional(),
});

export function aiRouter({ prisma }: { prisma: PrismaClient }) {
  const router = express.Router();

  router.post("/storefronts/generate", async (req, res) => {
    const ownerId = getDevUserId(req);
    const parsed = generateSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const {
      prompt,
      businessName = "",
      category = "",
      preferredColors = []
    } = parsed.data;

    // 1) Generate a draft payload (OpenAI if configured, otherwise fallback).
    const draft = await generateStorefrontDraft({
      prompt,
      businessName,
      category,
      preferredColors
    });

    // 2) Create a real storefront record.
    const baseSlug = safeSlug(draft.name || businessName || "store");
    const slug = await uniqueSlug(prisma, baseSlug);

    const store = await prisma.storefront.create({
      data: {
        ownerId,
        name: draft.name,
        slug,
        description: draft.description,
        category: draft.category,
        tagline: draft.tagline || null,
        published: false,
        theme: {
          create: {
            primaryHex: draft.theme.primaryHex,
            accentHex: draft.theme.accentHex,
            background: draft.theme.background,
            font: draft.theme.font
          }
        },
        products: {
          create: draft.products.map((p) => ({
            name: p.name,
            description: p.description,
            price: p.price,
            isSubscription: p.isSubscription
          }))
        },
        collections: {
          create: draft.collections.map((c) => ({ title: c.title }))
        },
        generated: {
          create: {
            prompt,
            response: JSON.stringify(draft)
          }
        }
      },
      include: { products: true, collections: true, theme: true }
    });

    res.status(201).json({
      storefront: {
        id: store.id,
        ownerId: store.ownerId,
        name: store.name,
        slug: store.slug,
        description: store.description,
        category: store.category,
        tagline: store.tagline,
        published: store.published,
        products: store.products.map((p) => ({
          id: p.id,
          name: p.name,
          description: p.description,
          price: p.price,
          isSubscription: p.isSubscription,
          mediaURL: null
        })),
        collections: store.collections.map((c) => ({ id: c.id, title: c.title })),
        theme: store.theme
          ? { primaryHex: store.theme.primaryHex, accentHex: store.theme.accentHex, background: store.theme.background, font: store.theme.font }
          : null,
        layout: null
      },
      generatedCopy: {
        hero: draft.hero.title,
        about: "About",
        products: "Products"
      }
    });
  });

  router.post("/storefronts/:id/improve", async (req, res) => {
    const ownerId = getDevUserId(req);
    const id = req.params.id;
    if (!z.string().uuid().safeParse(id).success) return res.status(400).json({ error: "bad_id" });

    const parsed = improveSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const { prompt, overwrite = false } = parsed.data;

    const existing = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true, collections: true, theme: true }
    });
    if (!existing) return res.status(404).json({ error: "not_found" });

    const draft = await generateStorefrontDraft({
      prompt,
      businessName: existing.name,
      category: existing.category
    });

    await prisma.$transaction(async (tx) => {
      await tx.storefrontGeneratedContent.create({
        data: {
          storefrontId: id,
          prompt,
          response: JSON.stringify(draft)
        }
      });

      await tx.storefront.update({
        where: { id },
        data: {
          description: draft.description,
          category: draft.category,
          tagline: draft.tagline || null
        }
      });

      if (existing.theme) {
        await tx.storefrontTheme.update({
          where: { storefrontId: id },
          data: {
            primaryHex: draft.theme.primaryHex,
            accentHex: draft.theme.accentHex,
            background: draft.theme.background,
            font: draft.theme.font
          }
        });
      } else {
        await tx.storefrontTheme.create({
          data: {
            storefrontId: id,
            primaryHex: draft.theme.primaryHex,
            accentHex: draft.theme.accentHex,
            background: draft.theme.background,
            font: draft.theme.font
          }
        });
      }

      if (overwrite) {
        await tx.storefrontProduct.deleteMany({ where: { storefrontId: id } });
        await tx.storefrontCollection.deleteMany({ where: { storefrontId: id } });
      }

      const existingProductNames = new Set((existing.products || []).map((p: any) => String(p.name).toLowerCase()));
      const newProducts = draft.products.filter((p) => overwrite || !existingProductNames.has(p.name.toLowerCase()));
      for (const p of newProducts) {
        await tx.storefrontProduct.create({
          data: {
            storefrontId: id,
            name: p.name,
            description: p.description,
            price: p.price,
            isSubscription: p.isSubscription
          }
        });
      }

      const existingCollectionTitles = new Set((existing.collections || []).map((c: any) => String(c.title).toLowerCase()));
      const newCollections = draft.collections.filter((c) => overwrite || !existingCollectionTitles.has(c.title.toLowerCase()));
      for (const c of newCollections) {
        await tx.storefrontCollection.create({ data: { storefrontId: id, title: c.title } });
      }
    });

    const updated = await prisma.storefront.findFirst({
      where: { id, ownerId },
      include: { products: true, collections: true, theme: true }
    });
    if (!updated) return res.status(404).json({ error: "not_found" });

    res.json({
      storefront: {
        id: updated.id,
        ownerId: updated.ownerId,
        name: updated.name,
        slug: updated.slug,
        description: updated.description,
        category: updated.category,
        tagline: updated.tagline,
        published: updated.published,
        products: (updated.products || []).map((p: any) => ({
          id: p.id,
          name: p.name,
          description: p.description,
          price: p.price,
          isSubscription: p.isSubscription,
          mediaURL: null
        })),
        collections: (updated.collections || []).map((c: any) => ({ id: c.id, title: c.title })),
        theme: updated.theme
          ? { primaryHex: updated.theme.primaryHex, accentHex: updated.theme.accentHex, background: updated.theme.background, font: updated.theme.font }
          : null,
        layout: null
      },
      generatedCopy: {
        hero: draft.hero.title,
        about: "About",
        products: "Products"
      }
    });
  });

  router.get("/trending-products", async (_req, res) => {
    const products = await prisma.storefrontProduct.findMany({
      where: {
        published: true,
        storefront: { published: true },
      },
      include: {
        ads: { where: { active: true } },
      },
      orderBy: [{ featured: "desc" }, { name: "asc" }],
      take: 12,
    });

    res.json(
      products.map((product) => ({
        id: product.id,
        name: product.name,
        description: product.description,
        price: Number(product.price) || 0,
        imageUrl: product.imageUrl,
        featured: product.featured,
        score: product.ads.reduce((sum, ad) => sum + ad.clicks + ad.impressions * 0.1, 0),
      }))
    );
  });

  router.post("/generate-content", async (req, res) => {
    const parsed = generateContentSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const avatar = parsed.data.avatarId
      ? await prisma.aIAvatar.findUnique({ where: { id: parsed.data.avatarId } })
      : await prisma.aIAvatar.findFirst({ orderBy: { createdAt: "desc" } });
    const product = parsed.data.productId
      ? await prisma.storefrontProduct.findUnique({ where: { id: parsed.data.productId } })
      : await prisma.storefrontProduct.findFirst({
          where: { published: true, storefront: { published: true } },
          orderBy: [{ featured: "desc" }, { name: "asc" }],
        });

    if (!avatar || !product) {
      return res.status(404).json({ error: "missing_avatar_or_product" });
    }

    const hook = generateHook(product.name, avatar.niche);
    const script = `${hook} Today I'm showing you ${product.name}. ${product.description} This is the kind of ${avatar.niche.toLowerCase()} find that gets people to stop scrolling.`;
    const caption = `🔥 ${product.name} is trending in ${avatar.niche}. Tap to shop now.`;

    const content = await prisma.aIAvatarContent.create({
      data: {
        avatarId: avatar.id,
        productId: product.id,
        hook,
        script,
        caption,
        videoUrl: `https://cdn.oneway.app/avatars/${avatar.id}/${Date.now()}.mp4`,
        status: "ready",
      },
      include: { avatar: true, product: true },
    });

    res.status(201).json({
      id: content.id,
      hook,
      script,
      caption,
      videoUrl: content.videoUrl,
      avatar: content.avatar,
      product: content.product,
    });
  });

  router.post("/schedule-live", async (req, res) => {
    const parsed = scheduleLiveSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const avatar = await prisma.aIAvatar.findUnique({ where: { id: parsed.data.avatarId } });
    if (!avatar) return res.status(404).json({ error: "avatar_not_found" });

    const live = await prisma.scheduledLive.create({
      data: {
        avatarId: avatar.id,
        productId: parsed.data.productId,
        title: parsed.data.title ?? `${avatar.name} goes live`,
        scheduledFor: parsed.data.scheduledFor ? new Date(parsed.data.scheduledFor) : new Date(Date.now() + 1000 * 60 * 60),
        status: "scheduled",
      },
    });
    res.status(201).json(live);
  });

  router.post("/auto-reply", async (req, res) => {
    const parsed = autoReplySchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const avatar = parsed.data.avatarId
      ? await prisma.aIAvatar.findUnique({ where: { id: parsed.data.avatarId } })
      : null;
    const reply = avatar
      ? `${avatar.name}: ${generateReply(parsed.data.message, avatar.personality)}`
      : generateReply(parsed.data.message, parsed.data.context ?? "helpful");

    res.json({ reply });
  });

  router.post("/avatar/create", async (req, res) => {
    const parsed = avatarCreateSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const avatar = await prisma.aIAvatar.create({
      data: parsed.data,
    });
    res.status(201).json(avatar);
  });

  router.post("/avatar/generate-video", async (req, res) => {
    const parsed = generateContentSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const avatar = parsed.data.avatarId
      ? await prisma.aIAvatar.findUnique({ where: { id: parsed.data.avatarId } })
      : await prisma.aIAvatar.findFirst({ orderBy: { createdAt: "desc" } });
    const product = parsed.data.productId
      ? await prisma.storefrontProduct.findUnique({ where: { id: parsed.data.productId } })
      : await prisma.storefrontProduct.findFirst({
          where: { published: true, storefront: { published: true } },
          orderBy: [{ featured: "desc" }, { name: "asc" }],
        });

    if (!avatar || !product) return res.status(404).json({ error: "missing_avatar_or_product" });

    const content = await prisma.aIAvatarContent.create({
      data: {
        avatarId: avatar.id,
        productId: product.id,
        hook: generateHook(product.name, avatar.niche),
        script: `${avatar.name} presents ${product.name}.`,
        caption: `Created by ${avatar.name}`,
        videoUrl: `https://cdn.oneway.app/avatars/${avatar.id}/video-${Date.now()}.mp4`,
        status: "rendered",
        postedAt: new Date(),
      },
      include: { avatar: true, product: true },
    });

    res.status(201).json(content);
  });

  router.get("/avatar/feed", async (_req, res) => {
    const items = await prisma.aIAvatarContent.findMany({
      include: {
        avatar: true,
        product: true,
      },
      orderBy: [{ postedAt: "desc" }, { createdAt: "desc" }],
      take: 20,
    });
    res.json(items);
  });

  router.get("/lives/trending", async (_req, res) => {
    const lives = await prisma.scheduledLive.findMany({
      where: {
        status: {
          in: ["scheduled", "live"],
        },
      },
      include: {
        avatar: true,
        product: true,
      },
      orderBy: [
        { viewerCount: "desc" },
        { scheduledFor: "asc" },
      ],
      take: 12,
    });

    res.json(lives);
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

function generateHook(productName: string, niche: string): string {
  const hooks = [
    `You NEED this ${productName} in your ${niche.toLowerCase()} routine.`,
    `Don't miss this ${productName} drop.`,
    `This ${productName} is about to sell out.`,
  ];
  return hooks[Math.floor(Math.random() * hooks.length)] ?? hooks[0];
}

function generateReply(message: string, personality: string): string {
  if (/price|cost/i.test(message)) return `It’s priced to move and worth a look. Want the product link?`;
  if (/ship|delivery/i.test(message)) return `Shipping details are available at checkout, and I can pin the item for you.`;
  return `Love that question. I’m keeping the vibe ${personality.toLowerCase()} here, and I’d definitely check the pinned product first.`;
}
