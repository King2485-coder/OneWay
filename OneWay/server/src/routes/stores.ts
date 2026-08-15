import type { PrismaClient, StorefrontProduct as PrismaStorefrontProduct } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { safeSlug } from "./helpers";
import { toProductDTO, toStoreDTO } from "../services/catalog";
import { ensureUserRecord } from "../services/identity";
import { emailProvider } from "../services/email/createEmailProvider";
import {
  buildStoreReplyAddress,
  createStoreEmailMessage,
  ensureStoreEmailMessageTable,
  fallbackProviderMessageId,
  listStoreEmailMessages,
  normalizeEmail,
  type StoreEmailMessageDTO,
} from "../services/storeEmailMessages";
import { logger } from "../lib/logger";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";
import {
  isWalletPaymentError,
  oneWayWalletPaymentService,
  type WalletPaymentStatus,
} from "../services/wallet/OneWayWalletPaymentService";
import { classifySensitiveField, redactSensitiveString } from "../lib/privacy/redaction";
import { decryptIfEncrypted, encryptIfEnabled } from "../services/privacy/EncryptionService";
import { addColumnIfMissing as addRuntimeColumnIfMissing } from "../lib/runtimeSchemaPatch";

const createStoreSchema = z.object({
  name: z.string().min(1).max(80),
  description: z.string().max(500).default(""),
  category: z.string().min(1).max(80).default("General"),
  tagline: z.string().max(120).optional(),
  published: z.boolean().optional(),
});

const inventoryStatuses = ["in_stock", "sold_out", "hidden"] as const;
const checkoutModes = ["contact", "payment_link", "oneway_wallet"] as const;
const fulfillmentPreferences = ["pickup", "local_delivery", "shipping", "digital"] as const;
const stripeConnectStatuses = ["not_started", "pending", "connected", "restricted"] as const;
const orderPaymentStatuses = ["not_requested", "payment_link_sent", "paid_manual", "refunded", "failed"] as const;
const orderRequestStatuses = ["requested", "accepted", "completed", "canceled"] as const;
const storeAnalyticsEventTypes = [
  "storefront_view",
  "product_view",
  "request_to_buy_started",
  "request_to_buy_submitted",
  "buy_now_clicked",
  "share_clicked",
  "oneway_wallet_checkout_started",
  "oneway_wallet_payment_completed",
  "oneway_wallet_payment_failed",
] as const;

const productSchema = z.object({
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(1_000).default(""),
  priceCents: z.number().int().min(0).max(50_000_000),
  imageUrl: z.string().trim().max(2_000).optional().default(""),
  inventoryCount: z.number().int().min(0).max(999_999).optional(),
  trackInventory: z.boolean().optional().default(false),
  lowStockThreshold: z.number().int().min(0).max(999).optional().default(3),
  paymentMode: z.enum(checkoutModes).optional().default("contact"),
  paymentLinkUrl: z.string().trim().max(2_000).optional().default("").refine((value) => !value || Boolean(safeHref(value)), {
    message: "Add a valid payment link."
  }),
  inventoryStatus: z.enum(inventoryStatuses).default("in_stock"),
  sortOrder: z.number().int().min(0).max(10_000).optional(),
});

const productPatchSchema = productSchema.partial();

const siteStoreSchema = z.object({
  storeEnabled: z.boolean().default(true),
  storeName: z.string().trim().max(120).default(""),
  storeDescription: z.string().trim().max(1_000).default(""),
  currency: z.string().trim().length(3).default("USD"),
  products: z.array(productSchema.extend({ id: z.string().trim().min(1).optional() })).max(100).default([]),
  contactToBuyEnabled: z.boolean().default(true),
  checkoutMode: z.enum(checkoutModes).default("contact"),
  paymentLinkUrl: z.string().trim().max(2_000).optional().default(""),
  paymentsEnabled: z.boolean().optional().default(false),
  stripeConnectStatus: z.enum(stripeConnectStatuses).optional().default("not_started"),
  defaultPaymentMode: z.enum(checkoutModes).optional().default("contact"),
  defaultPaymentLinkUrl: z.string().trim().max(2_000).optional().default("").refine((value) => !value || Boolean(safeHref(value)), {
    message: "Add a valid payment link."
  }),
  contactEmail: z.string().trim().max(254).optional().default(""),
  contactPhone: z.string().trim().max(40).optional().default(""),
  pickupEnabled: z.boolean().default(false),
  localDeliveryEnabled: z.boolean().default(false),
  shippingEnabled: z.boolean().default(false),
  digitalDeliveryEnabled: z.boolean().default(false),
  pickupInstructions: z.string().trim().max(700).optional().default(""),
  shippingNote: z.string().trim().max(700).optional().default(""),
  deliveryAreaNote: z.string().trim().max(700).optional().default(""),
  fulfillmentNote: z.string().trim().max(700).optional().default(""),
  marketplaceListed: z.boolean().default(false),
});

const inquirySchema = z.object({
  productId: z.string().trim().max(160).optional().default(""),
  customerName: z.string().trim().max(120).optional().default(""),
  customerEmail: z.string().trim().max(254).optional().default(""),
  customerPhone: z.string().trim().max(40).optional().default(""),
  productName: z.string().trim().max(160).optional().default(""),
  message: z.string().trim().min(1).max(2_000),
  quantity: z.coerce.number().int().min(1).max(999).optional().default(1),
  fulfillmentPreference: z.enum(fulfillmentPreferences).optional().default("pickup"),
  preferredContactMethod: z.enum(["oneway", "email", "phone", "text"]).optional().default("oneway"),
}).refine((body) => Boolean(body.customerEmail || body.customerPhone), {
  message: "Add an email or phone number so the seller can reply.",
}).refine((body) => Boolean(body.customerName.trim()), {
  message: "Add your name so the seller knows who to reply to.",
  path: ["customerName"],
}).refine((body) => !body.customerEmail || Boolean(safeEmail(body.customerEmail)), {
  message: "Add a valid email address.",
  path: ["customerEmail"],
}).refine((body) => !body.customerPhone || body.customerPhone.replace(/\D/g, "").length >= 7, {
  message: "Add a valid phone number.",
  path: ["customerPhone"],
});

const inquiryStatusSchema = z.object({
  status: z.enum(["new", "replied", "archived", "order_requested"]).optional(),
  ownerReply: z.string().trim().max(2_000).optional().default(""),
  convertToOrderRequest: z.boolean().optional().default(false),
  orderRequestNote: z.string().trim().max(1_000).optional().default(""),
});

const notificationStatusSchema = z.object({
  status: z.enum(["unread", "read", "dismissed"]),
});

const orderRequestStatusSchema = z.object({
  status: z.enum(["requested", "accepted", "completed", "canceled"]).optional(),
  note: z.string().trim().max(1_000).optional(),
  totalCents: z.number().int().min(0).max(50_000_000).optional(),
});

const orderPaymentStatusSchema = z.object({
  paymentStatus: z.enum(orderPaymentStatuses),
  paymentLinkUrl: z.string().trim().max(2_000).optional().default("").refine((value) => !value || Boolean(safeHref(value)), {
    message: "Add a valid payment link."
  }),
});

const walletCheckoutSchema = z.object({
  amountCents: z.number().int().min(1).max(50_000_000).optional(),
  buyerWalletUserId: z.string().trim().max(120).optional().default(""),
});

const orderReplySchema = z.object({
  message: z.string().trim().min(1).max(2_000),
});

const storeEventSchema = z.object({
  eventType: z.enum(storeAnalyticsEventTypes),
  productId: z.string().trim().max(160).optional().default(""),
  metadata: z.record(z.string(), z.union([z.string(), z.number(), z.boolean(), z.null()])).optional().default({}),
});

const analyticsRangeSchema = z.enum(["today", "7d", "30d"]).default("7d");

type InventoryStatus = typeof inventoryStatuses[number];
type CheckoutMode = typeof checkoutModes[number];
type FulfillmentPreference = typeof fulfillmentPreferences[number];
type InquiryStatus = "new" | "replied" | "archived" | "order_requested";
type StoreNotificationStatus = "unread" | "read" | "dismissed";
type StoreOrderRequestStatus = "requested" | "accepted" | "completed" | "canceled";
type OrderPaymentStatus = typeof orderPaymentStatuses[number];
type StoreAnalyticsEventType = typeof storeAnalyticsEventTypes[number];

type SiteStoreProduct = {
  id: string;
  name: string;
  description: string;
  priceCents: number;
  imageUrl: string;
  inventoryCount?: number | null;
  trackInventory?: boolean;
  lowStockThreshold?: number;
  paymentMode?: CheckoutMode;
  paymentLinkUrl?: string;
  inventoryStatus: InventoryStatus;
  sortOrder: number;
};

type SiteStore = {
  domain: string;
  ownerId: string;
  storeEnabled: boolean;
  storeName: string;
  storeDescription: string;
  currency: string;
  products: SiteStoreProduct[];
  contactToBuyEnabled: boolean;
  checkoutMode: CheckoutMode;
  paymentLinkUrl: string;
  paymentsEnabled: boolean;
  stripeConnectStatus: typeof stripeConnectStatuses[number];
  defaultPaymentMode: CheckoutMode;
  defaultPaymentLinkUrl: string;
  contactEmail: string;
  contactPhone: string;
  pickupEnabled: boolean;
  localDeliveryEnabled: boolean;
  shippingEnabled: boolean;
  digitalDeliveryEnabled: boolean;
  pickupInstructions: string;
  shippingNote: string;
  deliveryAreaNote: string;
  fulfillmentNote: string;
  marketplaceListed: boolean;
  published: boolean;
  publishedAt: string | null;
  updatedAt: string;
};

type SiteStoreInquiry = {
  id: string;
  domain: string;
  ownerId?: string;
  userId?: string;
  productId?: string | null;
  customerName: string;
  customerEmail: string;
  customerPhone: string;
  productName: string;
  paymentMode?: CheckoutMode | string;
  productPaymentLinkUrl?: string | null;
  message: string;
  quantity?: number;
  fulfillmentPreference?: FulfillmentPreference | string;
  status: InquiryStatus | string;
  ownerReply?: string;
  replyProvider?: string | null;
  replyProviderMessageId?: string | null;
  replyStatus?: string | null;
  repliedAt?: string | Date | null;
  convertedAt?: string | Date | null;
  orderRequestNote?: string;
  createdAt: string | Date;
  updatedAt: string | Date;
  emailMessages?: StoreEmailMessageDTO[];
};

type SiteStoreNotification = {
  id: string;
  userId?: string;
  domain: string;
  type: string;
  title: string;
  body: string;
  status: StoreNotificationStatus | string;
  relatedInquiryId?: string | null;
  relatedOrderRequestId?: string | null;
  createdAt: string | Date;
  readAt?: string | Date | null;
};

type SiteStoreOrderRequest = {
  id: string;
  userId?: string;
  domain: string;
  inquiryId?: string | null;
  productId?: string | null;
  customerName: string;
  customerEmail: string;
  customerPhone: string;
  productName: string;
  paymentMode?: CheckoutMode | string;
  paymentLinkUrl?: string | null;
  message: string;
  quantity: number;
  fulfillmentPreference: FulfillmentPreference | string;
  note: string;
  status: StoreOrderRequestStatus | string;
  paymentStatus?: OrderPaymentStatus | string;
  paidAt?: string | Date | null;
  walletPaymentStatus?: WalletPaymentStatus | string;
  walletPaymentId?: string | null;
  buyerWalletUserId?: string | null;
  sellerWalletUserId?: string | null;
  walletPaidAt?: string | Date | null;
  walletRefundedAt?: string | Date | null;
  totalCents: number;
  currency: string;
  sellerReply?: string;
  replyProvider?: string | null;
  replyProviderMessageId?: string | null;
  replyStatus?: string | null;
  repliedAt?: string | Date | null;
  inventoryApplied?: boolean;
  statusTimelineJson?: string;
  createdAt: string | Date;
  updatedAt: string | Date;
  emailMessages?: StoreEmailMessageDTO[];
};

type RequestableProduct = {
  id: string;
  name: string;
  status: "in_stock" | "sold_out" | "hidden";
  inventoryCount?: number | null;
  trackInventory?: boolean;
  lowStockThreshold?: number;
  priceCents?: number;
  paymentMode?: CheckoutMode;
  paymentLinkUrl?: string;
};

type PublishedStoreOwner = {
  ownerId: string;
  storeName: string;
  checkoutMode: CheckoutMode;
  paymentLinkUrl: string;
  fulfillmentPreferences: FulfillmentPreference[];
  products: RequestableProduct[];
};

const siteStores = new Map<string, SiteStore>();
let storeOperationsTablesReady = false;
let storefrontProductCommerceColumnsReady = false;

const inquiryEncryptedFields = [
  "customerName",
  "customerEmail",
  "customerPhone",
  "productPaymentLinkUrl",
  "message",
  "ownerReply",
  "orderRequestNote",
] as const;

const orderEncryptedFields = [
  "customerName",
  "customerEmail",
  "customerPhone",
  "paymentLinkUrl",
  "message",
  "note",
  "sellerReply",
  "walletPaymentId",
  "buyerWalletUserId",
  "sellerWalletUserId",
] as const;

function storeEncryptionContext(domain: string, entity: string, field: string): string {
  return `store:${domain}:${entity}:${field}`;
}

function encryptStoreField(domain: string, entity: string, field: string, value: string | null | undefined): string | null {
  if (value == null) return null;
  return encryptIfEnabled(value, storeEncryptionContext(domain, entity, field));
}

function decryptStoreField(domain: string, entity: string, field: string, value: string | null | undefined): string {
  return decryptIfEncrypted(value ?? "", storeEncryptionContext(domain, entity, field));
}

function encryptInquiryData<T extends Partial<SiteStoreInquiry>>(domain: string, data: T): T {
  const next: Partial<SiteStoreInquiry> = { ...data };
  for (const field of inquiryEncryptedFields) {
    if (field in next) {
      (next as Record<string, unknown>)[field] = encryptStoreField(domain, "inquiry", field, next[field] as string | null | undefined);
    }
  }
  return next as T;
}

function decryptStoreInquiry<T extends SiteStoreInquiry>(inquiry: T): T {
  const next: Partial<SiteStoreInquiry> = { ...inquiry };
  for (const field of inquiryEncryptedFields) {
    if (field in next) {
      (next as Record<string, unknown>)[field] = decryptStoreField(inquiry.domain, "inquiry", field, next[field] as string | null | undefined);
    }
  }
  return next as T;
}

function encryptOrderRequestData<T extends Partial<SiteStoreOrderRequest>>(domain: string, data: T): T {
  const next: Partial<SiteStoreOrderRequest> = { ...data };
  for (const field of orderEncryptedFields) {
    if (field in next) {
      (next as Record<string, unknown>)[field] = encryptStoreField(domain, "order", field, next[field] as string | null | undefined);
    }
  }
  return next as T;
}

function decryptStoreOrderRequest<T extends SiteStoreOrderRequest>(order: T): T {
  const next: Partial<SiteStoreOrderRequest> = { ...order };
  for (const field of orderEncryptedFields) {
    if (field in next) {
      (next as Record<string, unknown>)[field] = decryptStoreField(order.domain, "order", field, next[field] as string | null | undefined);
    }
  }
  return next as T;
}

function encryptNotificationBody(domain: string, body: string): string {
  return encryptStoreField(domain, "notification", "body", body) ?? "";
}

function decryptNotificationBody(domain: string, body: string): string {
  return decryptStoreField(domain, "notification", "body", body);
}

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
    const baseHandle = safeSlug(parsed.data.name);
    const handle = await uniqueHandle(prisma, baseHandle);

    const store = await prisma.storefront.create({
      data: {
        ownerId,
        name: parsed.data.name,
        handle,
        slug: handle,
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

  router.get("/site-directory", async (_req, res) => {
    const stores = Array.from(siteStores.values())
      .filter((store) => store.published && store.storeEnabled && store.marketplaceListed)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      .map((store) => ({
        domain: store.domain,
        name: store.storeName,
        description: store.storeDescription,
        productCount: store.products.filter((product) => product.inventoryStatus !== "hidden").length,
        pickupEnabled: store.pickupEnabled,
        shippingEnabled: store.shippingEnabled,
        updatedAt: store.updatedAt,
      }));

    res.json({ stores });
  });

  router.get("/search", async (req, res) => {
    const q = String(req.query.q ?? "").trim().toLowerCase();
    const category = String(req.query.category ?? "").trim().toLowerCase();
    const stores = await prisma.storefront.findMany({
      where: {
        published: true,
        status: "published",
        ...(category ? { category: { contains: category } } : {}),
        ...(q
          ? {
              OR: [
                { name: { contains: q } },
                { handle: { contains: q } },
                { slug: { contains: q } },
                { category: { contains: q } },
                { description: { contains: q } },
                { tagline: { contains: q } },
              ],
            }
          : {}),
      },
      include: { products: { where: { published: true } }, theme: true },
      orderBy: { updatedAt: "desc" },
      take: 50,
    });
    res.json({ stores: stores.map(toStoreDTO) });
  });

  router.get("/:handle/products", async (req, res) => {
    const handle = String(req.params.handle ?? "").trim().toLowerCase();
    const store = await prisma.storefront.findFirst({
      where: {
        published: true,
        status: "published",
        OR: [{ handle }, { slug: handle }],
      },
      include: {
        products: {
          where: { published: true },
          orderBy: [{ featured: "desc" }, { name: "asc" }],
        },
        theme: true,
      },
    });
    if (!store) {
      res.status(404).json({ error: "store_not_found", message: "This shop is not live yet." });
      return;
    }
    res.json({ store: toStoreDTO(store), products: store.products.map(toProductDTO) });
  });

  router.post("/:domain/events", async (req, res) => {
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = storeEventSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", message: "That activity could not be saved." });
      return;
    }

    const store = await findPublishedSiteStoreOwner(prisma, domain);
    if (!store) {
      res.status(404).json({ error: "store_not_published", message: "This shop is not live yet." });
      return;
    }

    await trackStoreEvent(prisma, {
      userId: store.ownerId,
      domain,
      eventType: parsed.data.eventType,
      productId: parsed.data.productId || null,
      metadata: parsed.data.metadata,
    });

    res.status(202).json({ ok: true });
  });

  router.get("/:domain/buy/:productId", async (req, res) => {
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const store = await findPublishedSiteStoreOwner(prisma, domain);
    if (!store) {
      res.status(404).json({ error: "store_not_published", message: "This shop is not live yet." });
      return;
    }

    const productId = String(req.params.productId || "");
    const product = store.products.find((item) => item.id === productId);
    const paymentLink = safeHref(product?.paymentLinkUrl ?? "") || safeHref(store.paymentLinkUrl);
    const paymentMode = product?.paymentMode === "payment_link" && paymentLink ? "payment_link" : store.checkoutMode;
    if (!product || product.status !== "in_stock" || paymentMode !== "payment_link" || !paymentLink) {
      res.redirect(302, `${publicStoreUrl(domain)}#inquiry`);
      return;
    }

    await trackStoreEvent(prisma, {
      userId: store.ownerId,
      domain,
      eventType: "buy_now_clicked",
      productId,
      metadata: { surface: "public_store_redirect" },
    });
    res.redirect(302, paymentLink);
  });

  router.post("/:domain/inquiries", async (req, res) => {
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const store = await findPublishedSiteStoreOwner(prisma, domain);
    if (!store) {
      res.status(404).json({ error: "store_not_published", message: "This store is not accepting inquiries yet." });
      return;
    }

    const parsed = inquirySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      if (wantsHtml(req)) {
        res.status(400).type("html").send(renderInquiryResultPage({
          title: "Almost there",
          message: parsed.error.issues[0]?.message ?? "Please add your message and a way to reply.",
          domain,
        }));
        return;
      }
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const requestedProduct = resolveRequestableProduct(store.products, {
      productId: parsed.data.productId,
      productName: parsed.data.productName,
      quantity: parsed.data.quantity,
    });
    if (!requestedProduct.ok) {
      const payload = { error: requestedProduct.error, message: requestedProduct.message };
      if (wantsHtml(req)) {
        res.status(400).type("html").send(renderInquiryResultPage({
          title: "Item unavailable",
          message: requestedProduct.message,
          domain,
        }));
        return;
      }
      res.status(400).json(payload);
      return;
    }
    if (!store.fulfillmentPreferences.includes(parsed.data.fulfillmentPreference)) {
      const payload = { error: "fulfillment_unavailable", message: "That fulfillment option is not available for this shop right now." };
      if (wantsHtml(req)) {
        res.status(400).type("html").send(renderInquiryResultPage({
          title: "Choose another option",
          message: payload.message,
          domain,
        }));
        return;
      }
      res.status(400).json(payload);
      return;
    }

    const paymentMode = resolveOrderPaymentMode(store, requestedProduct);
    const productPaymentLinkUrl = requestedProduct.paymentLinkUrl || store.paymentLinkUrl || "";
    const totalCents = Math.max(0, requestedProduct.priceCents * parsed.data.quantity);

    await ensureStoreInquiryTable(prisma);
    const inquiryData = {
      productId: requestedProduct.productId || null,
      customerName: parsed.data.customerName,
      customerEmail: parsed.data.customerEmail,
      customerPhone: parsed.data.customerPhone,
      productName: requestedProduct.productName || parsed.data.productName,
      productPaymentLinkUrl: productPaymentLinkUrl || null,
      message: addPreferredContactToMessage(parsed.data.message, parsed.data.preferredContactMethod),
      quantity: parsed.data.quantity,
      fulfillmentPreference: parsed.data.fulfillmentPreference,
      status: "order_requested",
      convertedAt: new Date(),
    };
    const inquiry = await prisma.storeInquiry.create({
      data: {
        userId: store.ownerId,
        domain,
        ...encryptInquiryData(domain, inquiryData),
      },
    });
    const plainInquiry = { ...inquiry, ...inquiryData };
    const orderRequest = await upsertStoreOrderRequest(prisma, {
      userId: store.ownerId,
      domain,
      inquiry: plainInquiry,
      note: "Customer requested to buy from the public storefront.",
      paymentMode,
      totalCents,
    });
    await trackStoreEvent(prisma, {
      userId: store.ownerId,
      domain,
      eventType: "request_to_buy_submitted",
      productId: requestedProduct.productId || null,
      metadata: { source: "buyer_form" },
    });
    await createStoreEmailMessage(prisma, {
      userId: store.ownerId,
      domain,
      inquiryId: inquiry.id,
      direction: "inbound",
      fromEmail: safeEmail(plainInquiry.customerEmail),
      toEmail: buildStoreReplyAddress("inquiries", inquiry.id),
      subject: `New inquiry for ${plainInquiry.productName || store.storeName || titleFromDomain(domain)}`,
      bodyText: plainInquiry.message,
      provider: "oneway_storefront",
      providerMessageId: fallbackProviderMessageId("store_inquiry"),
      status: "received",
    });
    await createStoreNotification(prisma, {
      userId: store.ownerId,
      domain,
      type: "buyer_inquiry",
      title: "New order request",
      body: `${plainInquiry.customerName || plainInquiry.customerEmail || plainInquiry.customerPhone || "A customer"} requested ${plainInquiry.quantity} ${plainInquiry.productName || store.storeName || titleFromDomain(domain)}.${requestedProduct.lowStock ? " Stock is low." : ""}`,
      relatedInquiryId: inquiry.id,
      relatedOrderRequestId: orderRequest.id,
    });
    logStoreInquiryCreated({
      userId: store.ownerId,
      domain,
      inquiryId: inquiry.id,
      productId: requestedProduct.productId || null,
      hasCustomerEmail: Boolean(safeEmail(inquiry.customerEmail)),
      hasCustomerPhone: Boolean(inquiry.customerPhone),
    });

    if (wantsHtml(req)) {
      res.status(201).type("html").send(renderInquiryResultPage({
        title: "Inquiry sent",
        message: `${store.storeName || titleFromDomain(domain)} received your order request. The seller can reply from OneWay with next steps.`,
        domain,
      }));
      return;
    }

    res.status(201).json({
      request: {
        inquiryId: inquiry.id,
        orderRequestId: orderRequest.id,
        domain,
        productId: requestedProduct.productId || null,
        productName: plainInquiry.productName,
        quantity: plainInquiry.quantity,
        fulfillmentPreference: plainInquiry.fulfillmentPreference,
        status: orderRequest.status,
        createdAt: toISODate(orderRequest.createdAt),
      },
      message: "Request sent. The seller will reply soon from OneWay.",
    });
  });

  router.put("/:domain", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = siteStoreSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const now = new Date().toISOString();
    const existing = siteStores.get(siteStoreKey(userId, domain)) ?? defaultSiteStore(userId, domain);
    const products = parsed.data.products
      .map((product, index) => normalizeProduct({
        ...product,
        id: product.id || randomProductId(),
        sortOrder: product.sortOrder ?? index,
      }))
      .sort(compareProducts);

    const store: SiteStore = {
      ...existing,
      storeEnabled: parsed.data.storeEnabled,
      storeName: parsed.data.storeName || existing.storeName || titleFromDomain(domain),
      storeDescription: parsed.data.storeDescription,
      currency: parsed.data.currency.toUpperCase(),
      products,
      contactToBuyEnabled: parsed.data.contactToBuyEnabled,
      checkoutMode: normalizeCheckoutMode(parsed.data.checkoutMode),
      paymentLinkUrl: safeHref(parsed.data.paymentLinkUrl || ""),
      paymentsEnabled: parsed.data.paymentsEnabled,
      stripeConnectStatus: parsed.data.stripeConnectStatus,
      defaultPaymentMode: normalizeCheckoutMode(parsed.data.defaultPaymentMode),
      defaultPaymentLinkUrl: safeHref(parsed.data.defaultPaymentLinkUrl || ""),
      contactEmail: parsed.data.contactEmail || "",
      contactPhone: parsed.data.contactPhone || "",
      pickupEnabled: parsed.data.pickupEnabled,
      localDeliveryEnabled: parsed.data.localDeliveryEnabled,
      shippingEnabled: parsed.data.shippingEnabled,
      digitalDeliveryEnabled: parsed.data.digitalDeliveryEnabled,
      pickupInstructions: parsed.data.pickupInstructions || "",
      shippingNote: parsed.data.shippingNote || "",
      deliveryAreaNote: parsed.data.deliveryAreaNote || "",
      fulfillmentNote: parsed.data.fulfillmentNote || "",
      marketplaceListed: parsed.data.marketplaceListed,
      published: existing.published,
      publishedAt: existing.publishedAt,
      updatedAt: now,
    };

    siteStores.set(siteStoreKey(userId, domain), store);
    res.json(toSiteStoreDTO(store));
  });

  router.post("/:domain/products", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = productSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const store = siteStores.get(siteStoreKey(userId, domain)) ?? defaultSiteStore(userId, domain);
    const product = normalizeProduct({
      ...parsed.data,
      id: randomProductId(),
      sortOrder: parsed.data.sortOrder ?? store.products.length,
    });
    store.products = [...store.products, product].sort(compareProducts);
    store.storeEnabled = true;
    store.updatedAt = new Date().toISOString();
    siteStores.set(siteStoreKey(userId, domain), store);
    res.status(201).json(toSiteStoreDTO(store));
  });

  router.put("/:domain/products/:productId", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = productPatchSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const key = siteStoreKey(userId, domain);
    const store = siteStores.get(key) ?? defaultSiteStore(userId, domain);
    const index = store.products.findIndex((product) => product.id === req.params.productId);
    if (index < 0) {
      res.status(404).json({ error: "product_not_found", message: "That product could not be found." });
      return;
    }

    store.products[index] = normalizeProduct({
      ...store.products[index],
      ...parsed.data,
      id: store.products[index].id,
      sortOrder: parsed.data.sortOrder ?? store.products[index].sortOrder,
    });
    store.products = store.products.sort(compareProducts);
    store.updatedAt = new Date().toISOString();
    siteStores.set(key, store);
    res.json(toSiteStoreDTO(store));
  });

  router.delete("/:domain/products/:productId", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const key = siteStoreKey(userId, domain);
    const store = siteStores.get(key) ?? defaultSiteStore(userId, domain);
    store.products = store.products.filter((product) => product.id !== req.params.productId);
    store.updatedAt = new Date().toISOString();
    siteStores.set(key, store);
    res.json(toSiteStoreDTO(store));
  });

  router.get("/:domain/inquiries", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const inquiries = await prisma.storeInquiry.findMany({
      where: { userId, domain },
      orderBy: { createdAt: "desc" },
    });
    const inquiryDTOs = await Promise.all(inquiries.map(async (inquiry) => {
      const emailMessages = await listStoreEmailMessages(prisma, {
        userId,
        domain,
        inquiryId: inquiry.id,
      });
      return toInquiryDTO({ ...inquiry, emailMessages });
    }));

    res.json({ inquiries: inquiryDTOs });
  });

  router.patch("/:domain/inquiries/:inquiryId", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const inquiryId = String(req.params.inquiryId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = inquiryStatusSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const existingRaw = await prisma.storeInquiry.findFirst({
      where: { id: inquiryId, userId, domain },
    });
    if (!existingRaw) {
      res.status(404).json({ error: "inquiry_not_found", message: "That inquiry could not be found." });
      return;
    }
    const existing = decryptStoreInquiry(existingRaw as SiteStoreInquiry);

    const ownerReply = parsed.data.ownerReply.trim();
    const shouldReply = Boolean(ownerReply);
    const shouldConvert = parsed.data.convertToOrderRequest;
    let replyProvider: string | null = existing.replyProvider ?? null;
    let replyProviderMessageId: string | null = existing.replyProviderMessageId ?? null;
    let replyStatus: string | null = existing.replyStatus ?? null;

    if (shouldReply && !safeEmail(existing.customerEmail)) {
      res.status(400).json({
        error: "buyer_email_missing",
        message: "This customer did not include an email address. Ask for an email before replying from OneWay.",
      });
      return;
    }

    if (shouldReply) {
      const result = await emailProvider.sendOutboundMessage({
        fromUserId: userId,
        toEmail: existing.customerEmail,
        replyTo: buildStoreReplyAddress("inquiries", existing.id),
        subject: `Reply from ${titleFromDomain(domain)}`,
        body: ownerReply,
        messageSessionId: existing.id,
      });
      replyProvider = result.provider;
      replyProviderMessageId = result.providerMessageId;
      replyStatus = result.status;
      await createStoreEmailMessage(prisma, {
        userId,
        domain,
        inquiryId: existing.id,
        direction: "outbound",
        fromEmail: emailFromAddress(),
        toEmail: existing.customerEmail,
        subject: `Reply from ${titleFromDomain(domain)}`,
        bodyText: ownerReply,
        provider: result.provider,
        providerMessageId: result.providerMessageId,
        status: result.status,
      });
    }

    const nextStatus: InquiryStatus = shouldConvert
      ? "order_requested"
      : shouldReply
        ? "replied"
        : parsed.data.status ?? (existing.status as InquiryStatus);

    const ownerReplyToStore = shouldReply ? ownerReply : existing.ownerReply;
    const orderRequestNoteToStore = shouldConvert
      ? (parsed.data.orderRequestNote.trim() || ownerReply || existing.orderRequestNote)
      : existing.orderRequestNote;
    const updated = await prisma.storeInquiry.update({
      where: { id: existing.id },
      data: {
        status: nextStatus,
        ...encryptInquiryData(domain, {
          ownerReply: ownerReplyToStore,
          orderRequestNote: orderRequestNoteToStore,
        }),
        replyProvider,
        replyProviderMessageId,
        replyStatus,
        repliedAt: shouldReply ? new Date() : existing.repliedAt,
        convertedAt: shouldConvert ? new Date() : existing.convertedAt,
      },
    });
    const updatedPlain = decryptStoreInquiry(updated as SiteStoreInquiry);

    let orderRequest: Awaited<ReturnType<typeof upsertStoreOrderRequest>> | null = null;
    if (shouldConvert) {
      orderRequest = await upsertStoreOrderRequest(prisma, {
        userId,
        domain,
        inquiry: updatedPlain,
        note: parsed.data.orderRequestNote.trim() || ownerReply || existing.orderRequestNote || "",
      });
      await createStoreNotification(prisma, {
        userId,
        domain,
        type: "order_request",
        title: "Order request created",
        body: `${updatedPlain.customerName || updatedPlain.customerEmail || updatedPlain.customerPhone || "A customer"} is ready for a follow-up.`,
        relatedInquiryId: existing.id,
        relatedOrderRequestId: orderRequest.id,
      });
      logStoreInquiryConverted({ userId, domain, inquiryId: existing.id, orderRequestId: orderRequest.id });
    }

    const emailMessages = await listStoreEmailMessages(prisma, {
      userId,
      domain,
      inquiryId: updatedPlain.id,
    });

    res.json({
      inquiry: toInquiryDTO({ ...updatedPlain, emailMessages }),
      orderRequest: orderRequest ? toOrderRequestDTO(orderRequest) : null,
    });
  });

  router.get("/:domain/notifications", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const notifications = await prisma.storeNotification.findMany({
      where: { userId, domain, NOT: { status: "dismissed" } },
      orderBy: { createdAt: "desc" },
      take: 100,
    });

    res.json({ notifications: notifications.map(toNotificationDTO) });
  });

  router.patch("/:domain/notifications/:notificationId", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const notificationId = String(req.params.notificationId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = notificationStatusSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const existing = await prisma.storeNotification.findFirst({
      where: { id: notificationId, userId, domain },
    });
    if (!existing) {
      res.status(404).json({ error: "notification_not_found", message: "That notification could not be found." });
      return;
    }

    const updated = await prisma.storeNotification.update({
      where: { id: existing.id },
      data: {
        status: parsed.data.status,
        readAt: parsed.data.status === "read" ? new Date() : existing.readAt,
      },
    });

    res.json({ notification: toNotificationDTO(updated) });
  });

  router.post("/:domain/notifications/read-all", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const updated = await prisma.storeNotification.updateMany({
      where: { userId, domain, status: "unread" },
      data: { status: "read", readAt: new Date() },
    });

    res.json({ ok: true, updatedCount: updated.count });
  });

  router.get("/:domain/analytics", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const range = analyticsRangeSchema.parse(typeof req.query.range === "string" ? req.query.range : "7d");
    const analytics = await storeAnalyticsSummary(prisma, { userId, domain, range });
    res.json(analytics);
  });

  router.get("/:domain/order-requests", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const statusRaw = typeof req.query.status === "string" ? req.query.status : "";
    const statusFilter = parseOrderStatusFilter(statusRaw);
    if (statusRaw.trim() && statusFilter.length === 0) {
      res.status(400).json({
        error: "invalid_status_filter",
        message: "Use one of: requested, accepted, completed, canceled.",
      });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const orderRequests = await prisma.storeOrderRequest.findMany({
      where: {
        userId,
        domain,
        ...(statusFilter.length > 0 ? { status: { in: statusFilter } } : {}),
      },
      orderBy: { createdAt: "desc" },
      take: 100,
    });

    res.json({ orderRequests: orderRequests.map(toOrderRequestDTO) });
  });

  router.get("/:domain/orders/:orderId", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const orderRequest = await findStoreOrderRequest(prisma, { userId, domain, orderId });
    if (!orderRequest) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }
    const emailMessages = await listStoreEmailMessages(prisma, {
      userId,
      domain,
      orderRequestId: orderRequest.id,
      inquiryId: orderRequest.inquiryId ?? null,
    });

    res.json({
      order: toOrderRequestDTO({ ...orderRequest, emailMessages }),
      emailDeliveryConfigured: isEmailDeliveryConfigured(),
    });
  });

  router.post("/:domain/orders/:orderId/reply", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = orderReplySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const existing = await findStoreOrderRequest(prisma, { userId, domain, orderId });
    if (!existing) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }
    if (!safeEmail(existing.customerEmail)) {
      res.status(400).json({
        error: "buyer_email_missing",
        message: "This customer did not include an email address. Ask for an email before replying from OneWay.",
      });
      return;
    }

    let replyProvider: string | null = existing.replyProvider ?? null;
    let replyProviderMessageId: string | null = existing.replyProviderMessageId ?? null;
    let replyStatus: string | null = existing.replyStatus ?? null;
    let providerMessage: string | undefined;

    if (isEmailDeliveryConfigured() || isDevStubEmailProvider()) {
      const result = await emailProvider.sendOutboundMessage({
        fromUserId: userId,
        toEmail: existing.customerEmail,
        replyTo: buildStoreReplyAddress("orders", existing.id),
        subject: `Update from ${titleFromDomain(domain)}`,
        body: parsed.data.message,
        htmlBody: renderStoreReplyEmail({
          domain,
          customerName: existing.customerName,
          productName: existing.productName,
          message: parsed.data.message,
        }),
        messageSessionId: existing.id,
      });
      replyProvider = result.provider;
      replyProviderMessageId = result.providerMessageId;
      replyStatus = result.status;
      providerMessage = result.message;
    } else {
      replyProvider = emailProvider.name;
      replyProviderMessageId = fallbackProviderMessageId("email_not_configured");
      replyStatus = "failed";
      providerMessage = "Email delivery is not configured yet. Reply was saved in OneWay.";
    }
    await createStoreEmailMessage(prisma, {
      userId,
      domain,
      orderRequestId: existing.id,
      inquiryId: existing.inquiryId,
      direction: "outbound",
      fromEmail: emailFromAddress(),
      toEmail: existing.customerEmail,
      subject: `Update from ${titleFromDomain(domain)}`,
      bodyText: parsed.data.message,
      bodyHtml: renderStoreReplyEmail({
        domain,
        customerName: existing.customerName,
        productName: existing.productName,
        message: parsed.data.message,
      }),
      provider: replyProvider ?? emailProvider.name,
      providerMessageId: replyProviderMessageId,
      status: replyStatus === "email_not_configured" ? "failed" : replyStatus ?? "failed",
    });

    const updated = await prisma.storeOrderRequest.update({
      where: { id: existing.id },
      data: {
        ...encryptOrderRequestData(domain, { sellerReply: parsed.data.message }),
        replyProvider,
        replyProviderMessageId,
        replyStatus,
        repliedAt: new Date(),
      },
    });
    const emailMessages = await listStoreEmailMessages(prisma, {
      userId,
      domain,
      orderRequestId: updated.id,
      inquiryId: updated.inquiryId ?? null,
    });

    res.json({
      order: toOrderRequestDTO({ ...updated, emailMessages }),
      emailDeliveryConfigured: isEmailDeliveryConfigured(),
      message: replyStatus === "stubbed"
        ? "Stubbed in dev. Reply was saved in OneWay."
        : replyStatus === "failed"
            ? providerMessage ?? "SendGrid could not deliver this reply. Reply was saved in OneWay."
        : undefined,
    });
  });

  router.post("/:domain/orders/:orderId/send-payment-link", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const existing = await findStoreOrderRequest(prisma, { userId, domain, orderId });
    if (!existing) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }

    const paymentLinkUrl = safeHref(existing.paymentLinkUrl ?? "");
    if (!paymentLinkUrl) {
      res.status(400).json({ error: "payment_link_missing", message: "Add a valid payment link before sending it." });
      return;
    }
    if (!safeEmail(existing.customerEmail)) {
      res.status(400).json({
        error: "buyer_email_missing",
        message: "This customer did not include an email address. Ask for an email before sending a payment link.",
      });
      return;
    }

    const message = paymentLinkMessage(existing, paymentLinkUrl);
    let replyProvider: string | null = existing.replyProvider ?? null;
    let replyProviderMessageId: string | null = existing.replyProviderMessageId ?? null;
    let replyStatus: string | null = existing.replyStatus ?? null;
    let providerMessage: string | undefined;

    if (isEmailDeliveryConfigured() || isDevStubEmailProvider()) {
      const result = await emailProvider.sendOutboundMessage({
        fromUserId: userId,
        toEmail: existing.customerEmail,
        replyTo: buildStoreReplyAddress("orders", existing.id),
        subject: `Payment link from ${titleFromDomain(domain)}`,
        body: message,
        htmlBody: renderStoreReplyEmail({
          domain,
          customerName: existing.customerName,
          productName: existing.productName,
          message,
        }),
        messageSessionId: existing.id,
      });
      replyProvider = result.provider;
      replyProviderMessageId = result.providerMessageId;
      replyStatus = result.status;
      providerMessage = result.message;
    } else {
      replyProvider = emailProvider.name;
      replyProviderMessageId = fallbackProviderMessageId("email_not_configured");
      replyStatus = "failed";
      providerMessage = "Email delivery is not configured yet. Payment link was saved in OneWay.";
    }

    await createStoreEmailMessage(prisma, {
      userId,
      domain,
      orderRequestId: existing.id,
      inquiryId: existing.inquiryId,
      direction: "outbound",
      fromEmail: emailFromAddress(),
      toEmail: existing.customerEmail,
      subject: `Payment link from ${titleFromDomain(domain)}`,
      bodyText: message,
      bodyHtml: renderStoreReplyEmail({
        domain,
        customerName: existing.customerName,
        productName: existing.productName,
        message,
      }),
      provider: replyProvider ?? emailProvider.name,
      providerMessageId: replyProviderMessageId,
      status: replyStatus === "email_not_configured" ? "failed" : replyStatus ?? "failed",
    });

    const updated = await prisma.storeOrderRequest.update({
      where: { id: existing.id },
      data: {
        ...encryptOrderRequestData(domain, {
          sellerReply: message,
          paymentLinkUrl,
        }),
        replyProvider,
        replyProviderMessageId,
        replyStatus,
        repliedAt: new Date(),
        paymentStatus: replyStatus === "failed" ? "failed" : "payment_link_sent",
      },
    });
    await auditStoreOrderChange(prisma, {
      actorId: userId,
      action: "storefront.payment_status_changed",
      domain,
      orderId: updated.id,
      metadata: {
        previousStatus: existing.paymentStatus ?? "not_requested",
        nextStatus: updated.paymentStatus,
        source: "send_payment_link",
      },
    });
    const emailMessages = await listStoreEmailMessages(prisma, {
      userId,
      domain,
      orderRequestId: updated.id,
      inquiryId: updated.inquiryId ?? null,
    });

    res.json({
      order: toOrderRequestDTO({ ...updated, emailMessages }),
      emailDeliveryConfigured: isEmailDeliveryConfigured(),
      message: replyStatus === "stubbed"
        ? "Payment link saved and stubbed in dev."
        : replyStatus === "failed"
          ? providerMessage ?? "Email delivery is not configured yet. Payment link was saved in OneWay."
          : "Payment link sent.",
    });
  });

  router.patch("/:domain/orders/:orderId/payment-status", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = orderPaymentStatusSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const existing = await findStoreOrderRequest(prisma, { userId, domain, orderId });
    if (!existing) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }

    const paymentLinkUrl = parsed.data.paymentLinkUrl ? safeHref(parsed.data.paymentLinkUrl) : existing.paymentLinkUrl;
    const paidAt = parsed.data.paymentStatus === "paid_manual" ? new Date() : existing.paidAt;
    const updated = await prisma.storeOrderRequest.update({
      where: { id: existing.id },
      data: {
        paymentStatus: parsed.data.paymentStatus,
        ...encryptOrderRequestData(domain, { paymentLinkUrl }),
        paidAt: parsed.data.paymentStatus === "refunded" || parsed.data.paymentStatus === "failed" ? null : paidAt,
      },
    });
    await auditStoreOrderChange(prisma, {
      actorId: userId,
      action: "storefront.payment_status_changed",
      domain,
      orderId: updated.id,
      metadata: {
        previousStatus: existing.paymentStatus ?? "not_requested",
        nextStatus: parsed.data.paymentStatus,
        source: "seller_update",
      },
    });

    res.json({ order: toOrderRequestDTO(updated) });
  });

  router.post("/:domain/orders/:orderId/wallet/checkout", async (req, res) => {
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = walletCheckoutSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", message: "Enter a valid payment amount.", issues: parsed.error.issues });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const existingRaw = await prisma.storeOrderRequest.findFirst({ where: { id: orderId, domain } });
    if (!existingRaw) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }
    const existing = decryptStoreOrderRequest(existingRaw as SiteStoreOrderRequest);
    const orderOwnerId = existing.userId ?? existingRaw.userId;
    if (existing.paymentMode !== "oneway_wallet") {
      res.status(400).json({ error: "wallet_not_selected", message: "This order is not set up for OneWay Wallet." });
      return;
    }

    const amountCents = parsed.data.amountCents ?? existing.totalCents;
    if (!Number.isInteger(amountCents) || amountCents <= 0) {
      res.status(400).json({ error: "invalid_wallet_payment", message: "Enter a valid payment amount." });
      return;
    }

    const walletStatus = await oneWayWalletPaymentService.getStatus();
    if (!walletStatus.available) {
      res.status(503).json({
        code: "payment_setup_unavailable",
        error: "payment_setup_unavailable",
        message: "OneWay Wallet is not available for this shop yet.",
        walletStatus,
      });
      return;
    }

    await trackStoreEvent(prisma, {
      userId: orderOwnerId,
      domain,
      eventType: "oneway_wallet_checkout_started",
      productId: existing.productId ?? null,
      metadata: { provider: walletStatus.provider, mockMode: walletStatus.mockMode },
    });

    try {
      const checkout = await oneWayWalletPaymentService.createCheckout({
        orderId,
        amountCents,
        buyerWalletUserId: parsed.data.buyerWalletUserId || null,
        sellerWalletUserId: orderOwnerId,
      });
      const captured = await oneWayWalletPaymentService.capturePayment(orderId);
      const now = new Date();
      const updated = await prisma.storeOrderRequest.update({
        where: { id: existing.id },
        data: {
          paymentMode: "oneway_wallet",
          paymentStatus: "paid_manual",
          paidAt: now,
          totalCents: amountCents,
          walletPaymentStatus: "paid",
          ...encryptOrderRequestData(domain, {
            walletPaymentId: captured.walletPaymentId || checkout.walletPaymentId,
            buyerWalletUserId: parsed.data.buyerWalletUserId || null,
            sellerWalletUserId: orderOwnerId,
          }),
          walletPaidAt: now,
          walletRefundedAt: null,
        },
      });
      await auditStoreOrderChange(prisma, {
        actorId: orderOwnerId,
        action: "storefront.payment_status_changed",
        domain,
        orderId: updated.id,
        metadata: {
          previousStatus: existing.paymentStatus ?? "not_requested",
          nextStatus: "paid_manual",
          paymentMode: "oneway_wallet",
          walletPaymentStatus: "paid",
        },
      });
      await trackStoreEvent(prisma, {
        userId: orderOwnerId,
        domain,
        eventType: "oneway_wallet_payment_completed",
        productId: existing.productId ?? null,
        metadata: {
          provider: captured.provider,
          walletPaymentId: captured.walletPaymentId,
          mockMode: walletStatus.mockMode,
        },
      });

      res.json({
        ok: true,
        order: toOrderRequestDTO(updated),
        walletPayment: captured,
        walletStatus,
        message: walletStatus.mockMode
          ? "OneWay Wallet test payment complete."
          : "OneWay Wallet payment complete.",
        testModeWarning: captured.testModeWarning ?? walletStatus.testModeWarning,
      });
    } catch (error) {
      await trackStoreEvent(prisma, {
        userId: orderOwnerId,
        domain,
        eventType: "oneway_wallet_payment_failed",
        productId: existing.productId ?? null,
        metadata: { reason: error instanceof Error ? error.message : "unknown" },
      });
      if (isWalletPaymentError(error)) {
        res.status(error.statusCode).json({ code: error.code, error: error.code, message: error.message });
        return;
      }
      res.status(502).json({ code: "wallet_payment_failed", error: "wallet_payment_failed", message: "OneWay Wallet payment could not be completed." });
    }
  });

  router.post("/:domain/orders/:orderId/wallet/refund", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const existing = await findStoreOrderRequest(prisma, { userId, domain, orderId });
    if (!existing) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }
    if (existing.paymentMode !== "oneway_wallet" || existing.walletPaymentStatus !== "paid") {
      res.status(400).json({ error: "wallet_refund_unavailable", message: "This order does not have a paid OneWay Wallet payment." });
      return;
    }

    try {
      const refund = await oneWayWalletPaymentService.refundPayment(orderId);
      const now = new Date();
      const updated = await prisma.storeOrderRequest.update({
        where: { id: existing.id },
        data: {
          paymentStatus: "refunded",
          paidAt: null,
          walletPaymentStatus: "refunded",
          ...encryptOrderRequestData(domain, {
            walletPaymentId: refund.walletPaymentId || existing.walletPaymentId,
          }),
          walletRefundedAt: now,
        },
      });
      await auditStoreOrderChange(prisma, {
        actorId: userId,
        action: "storefront.payment_status_changed",
        domain,
        orderId: updated.id,
        metadata: {
          previousStatus: existing.paymentStatus ?? "not_requested",
          nextStatus: "refunded",
          paymentMode: "oneway_wallet",
          walletPaymentStatus: "refunded",
        },
      });
      res.json({
        ok: true,
        order: toOrderRequestDTO(updated),
        walletPayment: refund,
        message: refund.testModeWarning ? "OneWay Wallet test refund complete." : "OneWay Wallet refund complete.",
        testModeWarning: refund.testModeWarning,
      });
    } catch (error) {
      if (isWalletPaymentError(error)) {
        res.status(error.statusCode).json({ code: error.code, error: error.code, message: error.message });
        return;
      }
      res.status(502).json({ code: "wallet_payment_failed", error: "wallet_payment_failed", message: "OneWay Wallet refund could not be completed." });
    }
  });

  router.patch("/:domain/orders/:orderId/status", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderId = String(req.params.orderId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = orderRequestStatusSchema.safeParse(req.body ?? {});
    if (!parsed.success || !parsed.data.status) {
      res.status(400).json({ error: "invalid_body", issues: parsed.success ? [] : parsed.error.issues });
      return;
    }

    const existing = await findStoreOrderRequest(prisma, { userId, domain, orderId });
    if (!existing) {
      res.status(404).json({ error: "order_not_found", message: "That order request could not be found." });
      return;
    }

    const updated = await updateStoreOrderRequestStatus(prisma, {
      existing,
      status: parsed.data.status,
      note: parsed.data.note,
      totalCents: parsed.data.totalCents,
    });
    await auditStoreOrderChange(prisma, {
      actorId: userId,
      action: "storefront.order_status_changed",
      domain,
      orderId: updated.id,
      metadata: {
        previousStatus: existing.status,
        nextStatus: parsed.data.status,
      },
    });
    await createStoreNotification(prisma, {
      userId,
      domain,
      type: `order_${parsed.data.status}`,
      title: `Order ${orderStatusLabel(parsed.data.status)}`,
      body: `${updated.productName || "Order request"} is now ${orderStatusLabel(parsed.data.status).toLowerCase()}.`,
      relatedOrderRequestId: updated.id,
      relatedInquiryId: updated.inquiryId,
    });

    res.json({ order: toOrderRequestDTO(updated), orderRequest: toOrderRequestDTO(updated) });
  });

  router.patch("/:domain/order-requests/:orderRequestId", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    const orderRequestId = String(req.params.orderRequestId || "");
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = orderRequestStatusSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    await ensureStoreInquiryTable(prisma);
    const existingRaw = await prisma.storeOrderRequest.findFirst({
      where: { id: orderRequestId, userId, domain },
    });
    if (!existingRaw) {
      res.status(404).json({ error: "order_request_not_found", message: "That order request could not be found." });
      return;
    }
    const existing = decryptStoreOrderRequest(existingRaw as SiteStoreOrderRequest);

    const updated = await updateStoreOrderRequestStatus(prisma, {
      existing,
      status: parsed.data.status ?? (existing.status as StoreOrderRequestStatus),
      note: parsed.data.note,
      totalCents: parsed.data.totalCents,
    });
    if (parsed.data.status) {
      await auditStoreOrderChange(prisma, {
        actorId: userId,
        action: "storefront.order_status_changed",
        domain,
        orderId: updated.id,
        metadata: {
          previousStatus: existing.status,
          nextStatus: parsed.data.status,
        },
      });
    }
    if (parsed.data.status) {
      await createStoreNotification(prisma, {
        userId,
        domain,
        type: `order_${parsed.data.status}`,
        title: `Order ${orderStatusLabel(parsed.data.status)}`,
        body: `${updated.productName || "Order request"} is now ${orderStatusLabel(parsed.data.status).toLowerCase()}.`,
        relatedOrderRequestId: updated.id,
        relatedInquiryId: updated.inquiryId,
      });
    }

    res.json({ orderRequest: toOrderRequestDTO(updated), order: toOrderRequestDTO(updated) });
  });

  router.post("/:domain/publish", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const domain = normalizeSiteDomain(req.params.domain);
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    await ensureUserRecord(userId);
    const key = siteStoreKey(userId, domain);
    const store = siteStores.get(key) ?? defaultSiteStore(userId, domain);
    const validation = validateSiteStore(store);
    if (validation) {
      res.status(400).json({ error: "store_not_ready", message: validation });
      return;
    }

    const now = new Date();
    store.storeEnabled = true;
    store.published = true;
    store.publishedAt = now.toISOString();
    store.updatedAt = now.toISOString();
    siteStores.set(key, store);

    const title = store.storeName || titleFromDomain(domain);
    const description = store.storeDescription || "A simple OneWay storefront.";
    await prisma.site.upsert({
      where: { userId_domain: { userId, domain } },
      update: {
        title,
        description,
        mode: "nocode",
        publishedHtml: renderPublishedSiteStore(store),
        publishedAt: now,
      },
      create: {
        userId,
        domain,
        title,
        description,
        mode: "nocode",
        html: "",
        blocksJson: "[]",
        aiPrompt: "",
        publishedHtml: renderPublishedSiteStore(store),
        publishedAt: now,
      },
    });

    res.json(toSiteStoreDTO(store));
  });

  router.get("/:id", async (req, res) => {
    const authHeader = req.headers.authorization || "";
    if (authHeader.trim()) {
      authMiddleware(req, res, async () => {
        const userId = (req as unknown as AuthenticatedRequest).userId;
        const domain = normalizeSiteDomain(req.params.id);
        if (!domain) {
          res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
          return;
        }
        const store = siteStores.get(siteStoreKey(userId, domain)) ?? defaultSiteStore(userId, domain);
        siteStores.set(siteStoreKey(userId, domain), store);
        res.json(toSiteStoreDTO(store));
      });
      return;
    }

    const idOrSlug = req.params.id;
    const store = await prisma.storefront.findFirst({
      where: {
        published: true,
        OR: [{ id: idOrSlug }, { slug: idOrSlug }, { handle: idOrSlug }],
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

function normalizeSiteDomain(input: string | string[] | undefined): string | null {
  const value = Array.isArray(input) ? input[0] : input;
  const raw = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/\/.*$/, "")
    .replace(/\.$/, "");

  const slug = raw.endsWith(".oneway.app") ? raw.slice(0, -".oneway.app".length) : raw;
  if (!/^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/.test(slug)) {
    return null;
  }
  return `${slug}.oneway.app`;
}

function siteStoreKey(userId: string, domain: string): string {
  return `${userId}:${domain}`;
}

function defaultSiteStore(ownerId: string, domain: string): SiteStore {
  const now = new Date().toISOString();
  return {
    domain,
    ownerId,
    storeEnabled: false,
    storeName: titleFromDomain(domain),
    storeDescription: "",
    currency: "USD",
    products: [],
    contactToBuyEnabled: true,
    checkoutMode: "contact",
    paymentLinkUrl: "",
    paymentsEnabled: process.env.NODE_ENV !== "production",
    stripeConnectStatus: process.env.NODE_ENV !== "production" ? "connected" : "not_started",
    defaultPaymentMode: "contact",
    defaultPaymentLinkUrl: "",
    contactEmail: "",
    contactPhone: "",
    pickupEnabled: false,
    localDeliveryEnabled: false,
    shippingEnabled: false,
    digitalDeliveryEnabled: false,
    pickupInstructions: "",
    shippingNote: "",
    deliveryAreaNote: "",
    fulfillmentNote: "",
    marketplaceListed: false,
    published: false,
    publishedAt: null,
    updatedAt: now,
  };
}

function normalizeProduct(input: {
  id: string;
  name: string;
  description?: string;
  priceCents: number;
  imageUrl?: string;
  inventoryCount?: number | null;
  trackInventory?: boolean;
  lowStockThreshold?: number;
  paymentMode?: CheckoutMode;
  paymentLinkUrl?: string;
  inventoryStatus?: InventoryStatus;
  sortOrder?: number;
}): SiteStoreProduct {
  const trackInventory = input.trackInventory ?? false;
  const inventoryCount = input.inventoryCount ?? null;
  const soldOutByCount = trackInventory && inventoryCount !== null && inventoryCount <= 0;
  return {
    id: input.id,
    name: input.name.trim(),
    description: (input.description ?? "").trim(),
    priceCents: Math.max(0, Math.round(input.priceCents)),
    imageUrl: safeImageUrl(input.imageUrl ?? ""),
    inventoryCount,
    trackInventory,
    lowStockThreshold: input.lowStockThreshold ?? 3,
    paymentMode: normalizeCheckoutMode(input.paymentMode ?? "contact"),
    paymentLinkUrl: safeHref(input.paymentLinkUrl ?? "") || "",
    inventoryStatus: soldOutByCount ? "sold_out" : input.inventoryStatus ?? "in_stock",
    sortOrder: input.sortOrder ?? 0,
  };
}

function compareProducts(a: SiteStoreProduct, b: SiteStoreProduct): number {
  return a.sortOrder - b.sortOrder || a.name.localeCompare(b.name);
}

function randomProductId(): string {
  return `prod_${Math.random().toString(36).slice(2, 10)}${Date.now().toString(36).slice(-4)}`;
}

function titleFromDomain(domain: string): string {
  const slug = domain.replace(/\.oneway\.app$/, "");
  return slug
    .split("-")
    .map((part) => part ? part[0].toUpperCase() + part.slice(1) : part)
    .join(" ");
}

function validateSiteStore(store: SiteStore): string | null {
  if (!store.storeName.trim()) return "Add a store name before publishing.";
  const visibleProducts = store.products.filter((product) => product.inventoryStatus !== "hidden");
  if (visibleProducts.length === 0) return "Add at least one visible product before publishing.";
  if (store.checkoutMode === "contact" && !store.contactToBuyEnabled) {
    return "Turn on Contact to buy or add a payment link before publishing.";
  }
  if (store.checkoutMode === "payment_link" && !safeHref(store.paymentLinkUrl)) {
    return "Add a valid payment link before publishing.";
  }
  return null;
}

function toSiteStoreDTO(store: SiteStore) {
  return {
    domain: store.domain,
    storeEnabled: store.storeEnabled,
    storeName: store.storeName,
    storeDescription: store.storeDescription,
    currency: store.currency,
    products: store.products,
    contactToBuyEnabled: store.contactToBuyEnabled,
    checkoutMode: store.checkoutMode,
    paymentLinkUrl: store.paymentLinkUrl,
    paymentsEnabled: store.paymentsEnabled,
    stripeConnectStatus: store.stripeConnectStatus,
    defaultPaymentMode: store.defaultPaymentMode,
    defaultPaymentLinkUrl: store.defaultPaymentLinkUrl,
    contactEmail: store.contactEmail,
    contactPhone: store.contactPhone,
    pickupEnabled: store.pickupEnabled,
    localDeliveryEnabled: store.localDeliveryEnabled,
    shippingEnabled: store.shippingEnabled,
    digitalDeliveryEnabled: store.digitalDeliveryEnabled,
    pickupInstructions: store.pickupInstructions,
    shippingNote: store.shippingNote,
    deliveryAreaNote: store.deliveryAreaNote,
    fulfillmentNote: store.fulfillmentNote,
    marketplaceListed: store.marketplaceListed,
    published: store.published,
    publishedAt: store.publishedAt,
    updatedAt: store.updatedAt,
  };
}

function toInquiryDTO(inquiry: SiteStoreInquiry) {
  const safeInquiry = decryptStoreInquiry(inquiry);
  return {
    id: safeInquiry.id,
    domain: safeInquiry.domain,
    productId: safeInquiry.productId ?? null,
    customerName: safeInquiry.customerName,
    customerEmail: safeInquiry.customerEmail,
    customerPhone: safeInquiry.customerPhone,
    productName: safeInquiry.productName,
    productPaymentLinkUrl: safeInquiry.productPaymentLinkUrl ?? null,
    message: safeInquiry.message,
    quantity: safeInquiry.quantity ?? 1,
    fulfillmentPreference: safeInquiry.fulfillmentPreference ?? "",
    status: safeInquiry.status,
    ownerReply: safeInquiry.ownerReply ?? "",
    replyProvider: safeInquiry.replyProvider ?? null,
    replyProviderMessageId: safeInquiry.replyProviderMessageId ?? null,
    replyStatus: safeInquiry.replyStatus ?? null,
    repliedAt: toISODate(safeInquiry.repliedAt),
    convertedAt: toISODate(safeInquiry.convertedAt),
    orderRequestNote: safeInquiry.orderRequestNote ?? "",
    emailMessages: safeInquiry.emailMessages ?? [],
    createdAt: toISODate(safeInquiry.createdAt) ?? new Date().toISOString(),
    updatedAt: toISODate(safeInquiry.updatedAt) ?? new Date().toISOString(),
  };
}

function toNotificationDTO(notification: SiteStoreNotification) {
  return {
    id: notification.id,
    domain: notification.domain,
    type: notification.type,
    title: notification.title,
    body: decryptNotificationBody(notification.domain, notification.body),
    status: notification.status,
    relatedInquiryId: notification.relatedInquiryId ?? null,
    relatedOrderRequestId: notification.relatedOrderRequestId ?? null,
    createdAt: toISODate(notification.createdAt) ?? new Date().toISOString(),
    readAt: toISODate(notification.readAt),
  };
}

function toOrderRequestDTO(orderRequest: SiteStoreOrderRequest) {
  const safeOrderRequest = decryptStoreOrderRequest(orderRequest);
  return {
    id: safeOrderRequest.id,
    domain: safeOrderRequest.domain,
    inquiryId: safeOrderRequest.inquiryId ?? null,
    productId: safeOrderRequest.productId ?? null,
    customerName: safeOrderRequest.customerName,
    customerEmail: safeOrderRequest.customerEmail,
    customerPhone: safeOrderRequest.customerPhone,
    productName: safeOrderRequest.productName,
    paymentMode: safeOrderRequest.paymentMode ?? "contact",
    paymentLinkUrl: safeOrderRequest.paymentLinkUrl ?? null,
    message: safeOrderRequest.message,
    quantity: safeOrderRequest.quantity,
    fulfillmentPreference: safeOrderRequest.fulfillmentPreference,
    note: safeOrderRequest.note,
    status: safeOrderRequest.status,
    paymentStatus: safeOrderRequest.paymentStatus ?? "not_requested",
    paidAt: toISODate(safeOrderRequest.paidAt),
    walletPaymentStatus: safeOrderRequest.walletPaymentStatus ?? "not_started",
    walletPaymentId: safeOrderRequest.walletPaymentId ?? null,
    buyerWalletUserId: safeOrderRequest.buyerWalletUserId ?? null,
    sellerWalletUserId: safeOrderRequest.sellerWalletUserId ?? null,
    walletPaidAt: toISODate(safeOrderRequest.walletPaidAt),
    walletRefundedAt: toISODate(safeOrderRequest.walletRefundedAt),
    totalCents: safeOrderRequest.totalCents,
    currency: safeOrderRequest.currency,
    sellerReply: safeOrderRequest.sellerReply ?? "",
    replyProvider: safeOrderRequest.replyProvider ?? null,
    replyProviderMessageId: safeOrderRequest.replyProviderMessageId ?? null,
    replyStatus: safeOrderRequest.replyStatus ?? null,
    repliedAt: toISODate(safeOrderRequest.repliedAt),
    inventoryApplied: Boolean(safeOrderRequest.inventoryApplied),
    statusTimeline: parseStatusTimeline(safeOrderRequest.statusTimelineJson),
    emailMessages: safeOrderRequest.emailMessages ?? [],
    createdAt: toISODate(safeOrderRequest.createdAt) ?? new Date().toISOString(),
    updatedAt: toISODate(safeOrderRequest.updatedAt) ?? new Date().toISOString(),
  };
}

function findPublishedSiteStore(domain: string): SiteStore | null {
  return Array.from(siteStores.values())
    .filter((store) => store.domain === domain && store.published && store.storeEnabled)
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))[0] ?? null;
}

async function findPublishedSiteStoreOwner(
  prisma: PrismaClient,
  domain: string,
): Promise<PublishedStoreOwner | null> {
  const memoryStore = findPublishedSiteStore(domain);
  if (memoryStore) {
    const paymentLinkUrl = safeHref(memoryStore.defaultPaymentLinkUrl || "") || safeHref(memoryStore.paymentLinkUrl);
    const checkoutMode = resolvePublishedCheckoutMode(memoryStore.defaultPaymentMode, memoryStore.checkoutMode, paymentLinkUrl);
    return {
      ownerId: memoryStore.ownerId,
      storeName: memoryStore.storeName || titleFromDomain(domain),
      checkoutMode,
      paymentLinkUrl,
      fulfillmentPreferences: enabledFulfillmentPreferences(memoryStore),
      products: memoryStore.products.map((product) => ({
        id: product.id,
        name: product.name,
        status: product.inventoryStatus,
        priceCents: product.priceCents,
        inventoryCount: product.inventoryCount ?? null,
        trackInventory: product.trackInventory ?? false,
        lowStockThreshold: product.lowStockThreshold ?? 3,
        paymentMode: product.paymentMode ?? memoryStore.checkoutMode,
        paymentLinkUrl: product.paymentLinkUrl,
      })),
    };
  }

  const slug = domain.replace(/\.oneway\.app$/, "");
  await ensureStorefrontProductCommerceColumns(prisma);
  const storefront = await prisma.storefront.findFirst({
    where: {
      published: true,
      OR: [{ slug }, { handle: slug }],
    },
    include: { products: true },
  });
  if (storefront) {
    const launchDetails = parseStorefrontLaunchDetails(storefront.shippingSettingsJson);
    const paymentLinkUrl = safeHref(storefront.defaultPaymentLinkUrl ?? "") || safeHref(launchDetails.paymentLinkUrl);
    const checkoutMode = resolvePublishedCheckoutMode(storefront.defaultPaymentMode as CheckoutMode, launchDetails.checkoutMode, paymentLinkUrl);
    return {
      ownerId: storefront.ownerId,
      storeName: storefront.name || titleFromDomain(domain),
      checkoutMode,
      paymentLinkUrl,
      fulfillmentPreferences: launchDetails.fulfillmentPreferences,
      products: storefront.products.map(storefrontProductToRequestable),
    };
  }

  const site = await prisma.site.findFirst({
    where: {
      domain,
      publishedAt: { not: null },
      NOT: { publishedHtml: "" },
    },
    orderBy: { publishedAt: "desc" },
  });
  if (!site) return null;

  return {
    ownerId: site.userId,
    storeName: site.title || titleFromDomain(domain),
    checkoutMode: "contact",
    paymentLinkUrl: "",
    fulfillmentPreferences: ["pickup", "local_delivery", "shipping", "digital"],
    products: [],
  };
}

function storefrontProductToRequestable(product: PrismaStorefrontProduct): RequestableProduct {
  const trackInventory = product.trackInventory ?? true;
  const inventoryCount = product.inventory;
  const paymentLinkUrl = safeHref(product.paymentLinkUrl ?? "") || "";
  return {
    id: product.id,
    name: product.name,
    status: !product.published
      ? "hidden"
      : trackInventory && inventoryCount <= 0
        ? "sold_out"
        : "in_stock",
    inventoryCount,
    trackInventory,
    lowStockThreshold: product.lowStockThreshold ?? 3,
    priceCents: Math.round(Number(product.price) * 100),
    paymentMode: (product.paymentMode as CheckoutMode | null) ?? "contact",
    paymentLinkUrl,
  };
}

function resolvePublishedCheckoutMode(preferred: CheckoutMode | string | null | undefined, fallback: CheckoutMode, paymentLinkUrl: string): CheckoutMode {
  if (preferred === "oneway_wallet") return isWalletPubliclyAvailable() ? "oneway_wallet" : "contact";
  if (preferred === "payment_link") return paymentLinkUrl ? "payment_link" : fallback;
  if (preferred === "contact") return "contact";
  if (fallback === "oneway_wallet") return isWalletPubliclyAvailable() ? "oneway_wallet" : "contact";
  if (fallback === "payment_link" && !paymentLinkUrl) return "contact";
  return fallback;
}

function parseStorefrontLaunchDetails(value: string | null | undefined): {
  checkoutMode: CheckoutMode;
  paymentLinkUrl: string;
  fulfillmentPreferences: FulfillmentPreference[];
} {
  if (!value) {
    return {
      checkoutMode: "contact",
      paymentLinkUrl: "",
      fulfillmentPreferences: ["pickup", "local_delivery", "shipping", "digital"],
    };
  }

  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    const paymentLinkUrl = safeHref(String(parsed.paymentLinkUrl ?? parsed.website ?? "")) || "";
    const parsedCheckoutMode = checkoutModes.includes(parsed.checkoutMode as CheckoutMode)
      ? parsed.checkoutMode as CheckoutMode
      : "contact";
    const checkoutMode: CheckoutMode = parsedCheckoutMode === "payment_link" && !paymentLinkUrl
      ? "contact"
      : parsedCheckoutMode;
    const preferences: FulfillmentPreference[] = [
      parsed.pickupEnabled === true ? "pickup" : null,
      parsed.localDeliveryEnabled === true ? "local_delivery" : null,
      parsed.shippingEnabled === true ? "shipping" : null,
      parsed.digitalDeliveryEnabled === true ? "digital" : null,
    ].filter(Boolean) as FulfillmentPreference[];
    return {
      checkoutMode,
      paymentLinkUrl,
      fulfillmentPreferences: preferences.length > 0 ? preferences : ["pickup", "local_delivery", "shipping", "digital"],
    };
  } catch {
    return {
      checkoutMode: "contact",
      paymentLinkUrl: "",
      fulfillmentPreferences: ["pickup", "local_delivery", "shipping", "digital"],
    };
  }
}

function enabledFulfillmentPreferences(store: SiteStore): FulfillmentPreference[] {
  const preferences: FulfillmentPreference[] = [
    store.pickupEnabled ? "pickup" : null,
    store.localDeliveryEnabled ? "local_delivery" : null,
    store.shippingEnabled ? "shipping" : null,
    store.digitalDeliveryEnabled ? "digital" : null,
  ].filter(Boolean) as FulfillmentPreference[];
  return preferences.length > 0 ? preferences : ["pickup", "local_delivery", "shipping", "digital"];
}

function normalizeCheckoutMode(mode: CheckoutMode): CheckoutMode {
  if (mode === "oneway_wallet" && !isWalletPubliclyAvailable()) return "contact";
  return mode;
}

function isWalletPubliclyAvailable(): boolean {
  const enabled = envFlag("ONEWAY_BANK_ENABLED", false);
  if (!enabled) return false;
  const mockMode = envFlag("ONEWAY_BANK_MOCK_MODE", process.env.NODE_ENV !== "production");
  if (mockMode && process.env.NODE_ENV !== "production") return true;
  return enabled && Boolean((process.env.ONEWAY_BANK_API_URL ?? "").trim()) && Boolean((process.env.ONEWAY_BANK_API_KEY ?? "").trim());
}

function resolveRequestableProduct(
  products: RequestableProduct[],
  input: { productId?: string; productName?: string; quantity?: number },
): { ok: true; productId: string; productName: string; priceCents: number; paymentMode: CheckoutMode; paymentLinkUrl: string; inventoryCount?: number | null; lowStock?: boolean } | { ok: false; error: string; message: string } {
  const productId = input.productId?.trim() ?? "";
  const productName = input.productName?.trim() ?? "";
  if (!productId && !productName) return { ok: true, productId: "", productName: "", priceCents: 0, paymentMode: "contact", paymentLinkUrl: "" };
  if (products.length === 0) return { ok: true, productId: "", productName, priceCents: 0, paymentMode: "contact", paymentLinkUrl: "" };

  const product = products.find((item) => {
    if (productId && item.id === productId) return true;
    return Boolean(productName) && item.name.toLowerCase() === productName.toLowerCase();
  });
  if (!product) {
    return {
      ok: false,
      error: "product_not_available",
      message: "That product is not available right now.",
    };
  }
  if (product.status === "hidden") {
    return {
      ok: false,
      error: "product_hidden",
      message: "That product is not available right now.",
    };
  }
  if (product.status === "sold_out") {
    return {
      ok: false,
      error: "product_sold_out",
      message: "That product is sold out right now.",
    };
  }
  const quantity = Math.max(1, input.quantity ?? 1);
  if (product.trackInventory && typeof product.inventoryCount === "number" && quantity > product.inventoryCount) {
    return {
      ok: false,
      error: "quantity_unavailable",
      message: `Only ${product.inventoryCount} available right now.`,
    };
  }
  const lowStockThreshold = product.lowStockThreshold ?? 3;
  const lowStock = Boolean(product.trackInventory && typeof product.inventoryCount === "number" && product.inventoryCount > 0 && product.inventoryCount <= lowStockThreshold);
  return {
    ok: true,
    productId: product.id,
    productName: product.name,
    priceCents: product.priceCents ?? 0,
    paymentMode: product.paymentMode ?? "contact",
    paymentLinkUrl: product.paymentLinkUrl ?? "",
    inventoryCount: product.inventoryCount,
    lowStock,
  };
}

function resolveOrderPaymentMode(
  store: PublishedStoreOwner,
  product: { productId: string; paymentMode: CheckoutMode; paymentLinkUrl: string },
): CheckoutMode {
  if (product.productId && product.paymentMode === "oneway_wallet" && isWalletPubliclyAvailable()) return "oneway_wallet";
  if (product.productId && product.paymentMode === "payment_link" && product.paymentLinkUrl) return "payment_link";
  if (store.checkoutMode === "oneway_wallet" && isWalletPubliclyAvailable()) return "oneway_wallet";
  if (store.checkoutMode === "payment_link" && (product.paymentLinkUrl || store.paymentLinkUrl)) return "payment_link";
  return "contact";
}

function addPreferredContactToMessage(message: string, preferredContactMethod: string): string {
  const label = preferredContactMethodLabel(preferredContactMethod);
  return label ? `${message}\n\nPreferred contact: ${label}` : message;
}

function preferredContactMethodLabel(value: string): string {
  switch (value) {
    case "email": return "Email";
    case "phone": return "Phone";
    case "text": return "Text";
    case "oneway": return "OneWay message";
    default: return "";
  }
}

function fulfillmentLabel(value: FulfillmentPreference | string): string {
  switch (value) {
    case "pickup": return "Pickup";
    case "local_delivery": return "Local delivery";
    case "shipping": return "Shipping";
    case "digital": return "Digital delivery";
    default: return String(value);
  }
}

async function ensureStoreInquiryTable(prisma: PrismaClient): Promise<void> {
  if (storeOperationsTablesReady) return;
  await ensureStoreEmailMessageTable(prisma);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "StoreInquiry" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "domain" TEXT NOT NULL,
      "productId" TEXT,
      "customerName" TEXT NOT NULL DEFAULT '',
      "customerEmail" TEXT NOT NULL DEFAULT '',
      "customerPhone" TEXT NOT NULL DEFAULT '',
      "productName" TEXT NOT NULL DEFAULT '',
      "productPaymentLinkUrl" TEXT,
      "message" TEXT NOT NULL,
      "quantity" INTEGER NOT NULL DEFAULT 1,
      "fulfillmentPreference" TEXT NOT NULL DEFAULT '',
      "status" TEXT NOT NULL DEFAULT 'new',
      "ownerReply" TEXT NOT NULL DEFAULT '',
      "replyProvider" TEXT,
      "replyProviderMessageId" TEXT,
      "replyStatus" TEXT,
      "repliedAt" DATETIME,
      "convertedAt" DATETIME,
      "orderRequestNote" TEXT NOT NULL DEFAULT '',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "StoreInquiry_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreInquiry_userId_domain_createdAt_idx" ON "StoreInquiry"("userId", "domain", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreInquiry_domain_createdAt_idx" ON "StoreInquiry"("domain", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreInquiry_status_createdAt_idx" ON "StoreInquiry"("status", "createdAt")`);
  await addColumnIfMissing(prisma, "StoreInquiry", `"productId" TEXT`);
  await addColumnIfMissing(prisma, "StoreInquiry", `"productPaymentLinkUrl" TEXT`);
  await addColumnIfMissing(prisma, "StoreInquiry", `"quantity" INTEGER NOT NULL DEFAULT 1`);
  await addColumnIfMissing(prisma, "StoreInquiry", `"fulfillmentPreference" TEXT NOT NULL DEFAULT ''`);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "StoreNotification" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "domain" TEXT NOT NULL,
      "type" TEXT NOT NULL,
      "title" TEXT NOT NULL,
      "body" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'unread',
      "relatedInquiryId" TEXT,
      "relatedOrderRequestId" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "readAt" DATETIME,
      CONSTRAINT "StoreNotification_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreNotification_userId_domain_createdAt_idx" ON "StoreNotification"("userId", "domain", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreNotification_userId_status_createdAt_idx" ON "StoreNotification"("userId", "status", "createdAt")`);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "StoreOrderRequest" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "domain" TEXT NOT NULL,
      "inquiryId" TEXT,
      "productId" TEXT,
      "customerName" TEXT NOT NULL DEFAULT '',
      "customerEmail" TEXT NOT NULL DEFAULT '',
      "customerPhone" TEXT NOT NULL DEFAULT '',
      "productName" TEXT NOT NULL DEFAULT '',
      "paymentMode" TEXT NOT NULL DEFAULT 'contact',
      "paymentLinkUrl" TEXT,
      "message" TEXT NOT NULL,
      "quantity" INTEGER NOT NULL DEFAULT 1,
      "fulfillmentPreference" TEXT NOT NULL DEFAULT '',
      "note" TEXT NOT NULL DEFAULT '',
      "status" TEXT NOT NULL DEFAULT 'requested',
      "paymentStatus" TEXT NOT NULL DEFAULT 'not_requested',
      "paidAt" DATETIME,
      "walletPaymentStatus" TEXT NOT NULL DEFAULT 'not_started',
      "walletPaymentId" TEXT,
      "buyerWalletUserId" TEXT,
      "sellerWalletUserId" TEXT,
      "walletPaidAt" DATETIME,
      "walletRefundedAt" DATETIME,
      "totalCents" INTEGER NOT NULL DEFAULT 0,
      "currency" TEXT NOT NULL DEFAULT 'USD',
      "sellerReply" TEXT NOT NULL DEFAULT '',
      "replyProvider" TEXT,
      "replyProviderMessageId" TEXT,
      "replyStatus" TEXT,
      "repliedAt" DATETIME,
      "inventoryApplied" BOOLEAN NOT NULL DEFAULT false,
      "statusTimelineJson" TEXT NOT NULL DEFAULT '[]',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "StoreOrderRequest_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreOrderRequest_userId_domain_createdAt_idx" ON "StoreOrderRequest"("userId", "domain", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreOrderRequest_userId_status_createdAt_idx" ON "StoreOrderRequest"("userId", "status", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreOrderRequest_inquiryId_idx" ON "StoreOrderRequest"("inquiryId")`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"productId" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"paymentMode" TEXT NOT NULL DEFAULT 'contact'`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"paymentLinkUrl" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"paymentStatus" TEXT NOT NULL DEFAULT 'not_requested'`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"paidAt" DATETIME`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"walletPaymentStatus" TEXT NOT NULL DEFAULT 'not_started'`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"walletPaymentId" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"buyerWalletUserId" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"sellerWalletUserId" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"walletPaidAt" DATETIME`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"walletRefundedAt" DATETIME`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"quantity" INTEGER NOT NULL DEFAULT 1`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"fulfillmentPreference" TEXT NOT NULL DEFAULT ''`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"sellerReply" TEXT NOT NULL DEFAULT ''`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"replyProvider" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"replyProviderMessageId" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"replyStatus" TEXT`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"repliedAt" DATETIME`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"inventoryApplied" BOOLEAN NOT NULL DEFAULT false`);
  await addColumnIfMissing(prisma, "StoreOrderRequest", `"statusTimelineJson" TEXT NOT NULL DEFAULT '[]'`);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "StoreAnalyticsEvent" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "domain" TEXT NOT NULL,
      "eventType" TEXT NOT NULL,
      "productId" TEXT,
      "metadata" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "StoreAnalyticsEvent_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreAnalyticsEvent_userId_domain_createdAt_idx" ON "StoreAnalyticsEvent"("userId", "domain", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreAnalyticsEvent_domain_eventType_createdAt_idx" ON "StoreAnalyticsEvent"("domain", "eventType", "createdAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "StoreAnalyticsEvent_productId_createdAt_idx" ON "StoreAnalyticsEvent"("productId", "createdAt")`);
  storeOperationsTablesReady = true;
}

async function ensureStorefrontProductCommerceColumns(prisma: PrismaClient): Promise<void> {
  if (storefrontProductCommerceColumnsReady) return;
  await addColumnIfMissing(prisma, "StorefrontProduct", `"trackInventory" BOOLEAN NOT NULL DEFAULT true`);
  await addColumnIfMissing(prisma, "StorefrontProduct", `"lowStockThreshold" INTEGER NOT NULL DEFAULT 3`);
  await addColumnIfMissing(prisma, "StorefrontProduct", `"paymentMode" TEXT NOT NULL DEFAULT 'contact'`);
  await addColumnIfMissing(prisma, "StorefrontProduct", `"paymentLinkUrl" TEXT`);
  await addColumnIfMissing(prisma, "Storefront", `"paymentsEnabled" BOOLEAN NOT NULL DEFAULT false`);
  await addColumnIfMissing(prisma, "Storefront", `"stripeConnectStatus" TEXT NOT NULL DEFAULT 'not_started'`);
  await addColumnIfMissing(prisma, "Storefront", `"defaultPaymentMode" TEXT NOT NULL DEFAULT 'contact'`);
  await addColumnIfMissing(prisma, "Storefront", `"defaultPaymentLinkUrl" TEXT`);
  storefrontProductCommerceColumnsReady = true;
}

async function addColumnIfMissing(prisma: PrismaClient, table: string, columnDefinition: string): Promise<void> {
  await addRuntimeColumnIfMissing(prisma, { table, columnDefinition });
}

async function createStoreNotification(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  type: string;
  title: string;
  body: string;
  relatedInquiryId?: string | null;
  relatedOrderRequestId?: string | null;
}): Promise<void> {
  await ensureStoreInquiryTable(prisma);
  await prisma.storeNotification.create({
    data: {
      userId: input.userId,
      domain: input.domain,
      type: input.type,
      title: input.title,
      body: encryptNotificationBody(input.domain, input.body),
      status: "unread",
      relatedInquiryId: input.relatedInquiryId ?? null,
      relatedOrderRequestId: input.relatedOrderRequestId ?? null,
    },
  });
}

async function trackStoreEvent(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  eventType: StoreAnalyticsEventType;
  productId?: string | null;
  metadata?: Record<string, string | number | boolean | null>;
}): Promise<void> {
  await ensureStoreInquiryTable(prisma);
  await prisma.storeAnalyticsEvent.create({
    data: {
      userId: input.userId,
      domain: input.domain,
      eventType: input.eventType,
      productId: input.productId || null,
      metadata: sanitizeAnalyticsMetadata(input.metadata ?? {}),
    },
  });
}

async function storeAnalyticsSummary(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  range: "today" | "7d" | "30d";
}) {
  await ensureStoreInquiryTable(prisma);
  const since = analyticsRangeStart(input.range);
  const events = await prisma.storeAnalyticsEvent.findMany({
    where: {
      userId: input.userId,
      domain: input.domain,
      createdAt: { gte: since },
    },
    orderBy: { createdAt: "desc" },
    take: 5_000,
  });
  const count = (type: StoreAnalyticsEventType) => events.filter((event) => event.eventType === type).length;
  const views = count("storefront_view");
  const productViews = count("product_view");
  const requests = count("request_to_buy_submitted");
  const buyClicks = count("buy_now_clicked") + count("oneway_wallet_checkout_started");
  const shares = count("share_clicked");
  const productCounts = new Map<string, number>();
  for (const event of events) {
    if (!event.productId || (event.eventType !== "product_view" && event.eventType !== "buy_now_clicked" && event.eventType !== "request_to_buy_submitted" && event.eventType !== "oneway_wallet_checkout_started")) continue;
    productCounts.set(event.productId, (productCounts.get(event.productId) ?? 0) + 1);
  }

  return {
    range: input.range,
    since: since.toISOString(),
    cards: {
      views,
      productViews,
      requests,
      buyClicks,
      shares,
      conversionRate: views > 0 ? Number(((requests / views) * 100).toFixed(1)) : 0,
    },
    topProducts: Array.from(productCounts.entries())
      .map(([productId, count]) => ({ productId, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5),
    empty: events.length === 0,
  };
}

function analyticsRangeStart(range: "today" | "7d" | "30d"): Date {
  const now = new Date();
  if (range === "today") {
    return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  }
  const days = range === "30d" ? 30 : 7;
  return new Date(now.getTime() - days * 24 * 60 * 60 * 1_000);
}

function parseOrderStatusFilter(value: string): StoreOrderRequestStatus[] {
  if (!value.trim()) return [];
  const valid = new Set<StoreOrderRequestStatus>(orderRequestStatuses);
  return value
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter((item): item is StoreOrderRequestStatus => valid.has(item as StoreOrderRequestStatus));
}

function sanitizeAnalyticsMetadata(metadata: Record<string, string | number | boolean | null>): string {
  const allowed: Record<string, string | number | boolean | null> = {};
  for (const [key, value] of Object.entries(metadata)) {
    if (!/^[a-zA-Z0-9_:-]{1,40}$/.test(key)) continue;
    if (classifySensitiveField(key) !== "safe") continue;
    if (typeof value === "string") {
      const redacted = redactSensitiveString(value);
      if (redacted !== value) continue;
      allowed[key] = value.slice(0, 120);
    } else if (typeof value === "number" || typeof value === "boolean" || value === null) {
      allowed[key] = value;
    }
  }
  return JSON.stringify(allowed);
}

async function upsertStoreOrderRequest(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  inquiry: SiteStoreInquiry;
  note: string;
  paymentMode?: CheckoutMode;
  totalCents?: number;
}) {
  await ensureStoreInquiryTable(prisma);
  const inquiry = decryptStoreInquiry(input.inquiry);
  const existing = input.inquiry.id
    ? await prisma.storeOrderRequest.findFirst({
      where: {
        userId: input.userId,
        domain: input.domain,
        inquiryId: input.inquiry.id,
      },
    })
    : null;

  const data = {
    productId: inquiry.productId ?? null,
    customerName: inquiry.customerName,
    customerEmail: inquiry.customerEmail,
    customerPhone: inquiry.customerPhone,
    productName: inquiry.productName,
    paymentMode: input.paymentMode ?? inquiry.paymentMode ?? (inquiry.productPaymentLinkUrl ? "payment_link" : "contact"),
    paymentLinkUrl: inquiry.productPaymentLinkUrl ?? null,
    paymentStatus: inquiry.productPaymentLinkUrl ? "not_requested" : "not_requested",
    walletPaymentStatus: input.paymentMode === "oneway_wallet" ? "not_started" : "not_started",
    message: inquiry.message,
    quantity: Math.max(1, inquiry.quantity ?? 1),
    fulfillmentPreference: inquiry.fulfillmentPreference ?? "",
    note: input.note,
    status: "requested",
    totalCents: Math.max(0, input.totalCents ?? 0),
    currency: "USD",
    statusTimelineJson: appendStatusTimeline(existing?.statusTimelineJson ?? "[]", "requested"),
  };

  if (existing) {
    const updated = await prisma.storeOrderRequest.update({
      where: { id: existing.id },
      data: encryptOrderRequestData(input.domain, data),
    });
    return decryptStoreOrderRequest(updated as SiteStoreOrderRequest);
  }

  const created = await prisma.storeOrderRequest.create({
    data: {
      userId: input.userId,
      domain: input.domain,
      inquiryId: inquiry.id,
      ...encryptOrderRequestData(input.domain, data),
    },
  });
  return decryptStoreOrderRequest(created as SiteStoreOrderRequest);
}

async function findStoreOrderRequest(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  orderId: string;
}) {
  await ensureStoreInquiryTable(prisma);
  const found = await prisma.storeOrderRequest.findFirst({
    where: {
      id: input.orderId,
      userId: input.userId,
      domain: input.domain,
    },
  });
  return found ? decryptStoreOrderRequest(found as SiteStoreOrderRequest) : null;
}

async function updateStoreOrderRequestStatus(prisma: PrismaClient, input: {
  existing: SiteStoreOrderRequest;
  status: StoreOrderRequestStatus;
  note?: string;
  totalCents?: number;
}) {
  const inventoryApplied = input.status === "completed" && !input.existing.inventoryApplied
    ? await applyInventoryForCompletedOrder(prisma, input.existing)
    : Boolean(input.existing.inventoryApplied);
  const nextTimeline = appendStatusTimeline(input.existing.statusTimelineJson, input.status);
  const updated = await prisma.storeOrderRequest.update({
    where: { id: input.existing.id },
    data: {
      status: input.status,
      ...encryptOrderRequestData(input.existing.domain, {
        note: input.note ?? input.existing.note,
      }),
      totalCents: input.totalCents ?? input.existing.totalCents,
      inventoryApplied,
      statusTimelineJson: nextTimeline,
    },
  });
  return decryptStoreOrderRequest(updated as SiteStoreOrderRequest);
}

async function applyInventoryForCompletedOrder(prisma: PrismaClient, order: SiteStoreOrderRequest): Promise<boolean> {
  const quantity = Math.max(1, order.quantity || 1);
  if (!order.productId) return false;

  const product = await prisma.storefrontProduct.findUnique({ where: { id: order.productId } });
  if (product && (product.trackInventory ?? true)) {
    await prisma.storefrontProduct.update({
      where: { id: product.id },
      data: {
        inventory: Math.max(0, product.inventory - quantity),
      },
    });
    return true;
  }

  const memoryStore = findPublishedSiteStore(order.domain);
  if (memoryStore) {
    const productIndex = memoryStore.products.findIndex((item) => item.id === order.productId);
    if (productIndex >= 0 && memoryStore.products[productIndex].trackInventory) {
      const current = memoryStore.products[productIndex].inventoryCount ?? 0;
      memoryStore.products[productIndex].inventoryCount = Math.max(0, current - quantity);
      if (memoryStore.products[productIndex].inventoryCount === 0) {
        memoryStore.products[productIndex].inventoryStatus = "sold_out";
      }
      memoryStore.updatedAt = new Date().toISOString();
      siteStores.set(siteStoreKey(memoryStore.ownerId, memoryStore.domain), memoryStore);
      return true;
    }
  }

  return false;
}

function parseStatusTimeline(value: string | null | undefined): Array<{ status: string; at: string }> {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((item) => item && typeof item.status === "string" && typeof item.at === "string")
      .map((item) => ({ status: item.status, at: item.at }));
  } catch {
    return [];
  }
}

function appendStatusTimeline(value: string | null | undefined, status: StoreOrderRequestStatus): string {
  const timeline = parseStatusTimeline(value);
  timeline.push({ status, at: new Date().toISOString() });
  return JSON.stringify(timeline.slice(-20));
}

function orderStatusLabel(status: StoreOrderRequestStatus): string {
  switch (status) {
    case "requested": return "Requested";
    case "accepted": return "Accepted";
    case "completed": return "Completed";
    case "canceled": return "Canceled";
  }
}

function paymentStatusLabel(status: OrderPaymentStatus | string): string {
  switch (status) {
    case "payment_link_sent": return "Payment link sent";
    case "paid_manual": return "Paid";
    case "refunded": return "Refunded";
    case "failed": return "Payment failed";
    case "not_requested":
    default: return "Not requested";
  }
}

function paymentLinkMessage(order: SiteStoreOrderRequest, paymentLinkUrl: string): string {
  const greeting = order.customerName.trim() ? `Hi ${order.customerName.trim()},` : "Hi,";
  const product = order.productName.trim() || "your order request";
  return `${greeting}\n\nThanks for your request for ${product}. You can use this payment link when you're ready:\n${paymentLinkUrl}\n\nAfter payment, reply here and the seller will confirm next steps.`;
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function isEmailDeliveryConfigured(): boolean {
  const provider = (process.env.EMAIL_PROVIDER ?? "stub").trim().toLowerCase();
  if (provider === "stub") return false;
  if (provider === "sendgrid") {
    const from = process.env.EMAIL_FROM_ADDRESS?.trim()
      || process.env.EMAIL_FROM?.trim()
      || process.env.SENDGRID_FROM_EMAIL?.trim();
    return Boolean(process.env.SENDGRID_API_KEY?.trim() && from);
  }
  return false;
}

function emailFromAddress(): string {
  return process.env.EMAIL_FROM_ADDRESS?.trim()
    || process.env.EMAIL_FROM?.trim()
    || process.env.SENDGRID_FROM_EMAIL?.trim()
    || "no-reply@oneway.app";
}

function isDevStubEmailProvider(): boolean {
  const provider = (process.env.EMAIL_PROVIDER ?? "stub").trim().toLowerCase();
  return provider === "stub" && process.env.NODE_ENV !== "production";
}

function logStoreInquiryCreated(input: {
  userId: string;
  domain: string;
  inquiryId: string;
  productId: string | null;
  hasCustomerEmail: boolean;
  hasCustomerPhone: boolean;
}): void {
  logger.info(input, "[store:inquiry] new buyer inquiry");
}

function logStoreInquiryConverted(input: {
  userId: string;
  domain: string;
  inquiryId: string;
  orderRequestId: string;
}): void {
  logger.info(input, "[store:inquiry] converted to order request");
}

function toISODate(value: string | Date | null | undefined): string | null {
  if (!value) return null;
  if (value instanceof Date) return value.toISOString();
  return value;
}

function renderPublishedSiteStore(store: SiteStore): string {
  const visibleProducts = store.products
    .filter((product) => product.inventoryStatus !== "hidden")
    .sort(compareProducts);
  const productsHtml = visibleProducts.map((product) => renderProductCard(store, product)).join("\n");
  const inquiryEndpoint = storeInquiryEndpoint(store.domain);
  const productOptions = visibleProducts
    .map((product) => `<option value="${escapeAttr(product.name)}">${escapeText(product.name)}</option>`)
    .join("");
  const optionChips = [
    store.pickupEnabled ? `<span>Local pickup</span>` : "",
    store.localDeliveryEnabled ? `<span>Local delivery</span>` : "",
    store.shippingEnabled ? `<span>Shipping available</span>` : "",
    store.digitalDeliveryEnabled ? `<span>Digital delivery</span>` : "",
    store.marketplaceListed ? `<span>Listed in OneWay</span>` : "",
  ].filter(Boolean).join("");
  const fulfillmentOptions = enabledFulfillmentPreferences(store)
    .map((preference) => `<option value="${escapeAttr(preference)}">${escapeText(fulfillmentLabel(preference))}</option>`)
    .join("");
  const contactRows = [
    safeEmail(store.contactEmail) ? `<p><strong>Email:</strong> <a href="mailto:${escapeAttr(safeEmail(store.contactEmail))}">${escapeText(safeEmail(store.contactEmail))}</a></p>` : "",
    store.contactPhone ? `<p><strong>Phone/Text:</strong> ${escapeText(store.contactPhone)}</p>` : "",
    store.pickupInstructions ? `<p><strong>Pickup:</strong> ${escapeText(store.pickupInstructions)}</p>` : "",
    store.deliveryAreaNote ? `<p><strong>Local delivery:</strong> ${escapeText(store.deliveryAreaNote)}</p>` : "",
    store.shippingNote ? `<p><strong>Shipping:</strong> ${escapeText(store.shippingNote)}</p>` : "",
    store.fulfillmentNote ? `<p>${escapeText(store.fulfillmentNote)}</p>` : "",
  ].filter(Boolean).join("\n");

  return sanitizeHtml(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeText(store.storeName || titleFromDomain(store.domain))}</title>
  <meta name="description" content="${escapeAttr(store.storeDescription)}" />
  <style>
    :root{color-scheme:dark;--bg:#13072d;--panel:rgba(255,255,255,.08);--text:#f7f2ff;--muted:#c9b9ee;--accent:#ffcc33;--blue:#3385ff}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,"Avenir Next",sans-serif;background:radial-gradient(circle at top left,#402079,transparent 38%),linear-gradient(150deg,#0b041b,#28105a 58%,#4e1f8f);color:var(--text);line-height:1.6}
    main{width:min(1080px,calc(100% - 32px));margin:0 auto;padding:64px 0}.eyebrow{color:var(--accent);font-weight:900;text-transform:uppercase;letter-spacing:.12em;font-size:.78rem}
    h1{font-size:clamp(2.4rem,9vw,6rem);line-height:.94;margin:.12em 0 .24em}h2{font-size:1.5rem;margin:0 0 16px}p{color:var(--muted);font-size:1.08rem}
    .hero{padding:34px 0 46px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px}.card{position:relative;overflow:hidden;border-radius:26px;background:var(--panel);border:1px solid rgba(255,255,255,.14);backdrop-filter:blur(14px)}
    .card img{display:block;width:100%;aspect-ratio:4/3;object-fit:cover;background:rgba(255,255,255,.06)}.content{padding:18px}.price{font-size:1.25rem;font-weight:900;color:var(--accent);margin:.4rem 0}.badge{position:absolute;top:12px;left:12px;border-radius:999px;background:rgba(0,0,0,.62);padding:6px 10px;font-size:.72rem;font-weight:900;text-transform:uppercase}.badge.low{left:auto;right:12px;background:rgba(255,204,51,.92);color:#13072d}
    .button{display:inline-flex;align-items:center;justify-content:center;border-radius:999px;padding:11px 15px;background:#fff;color:#13072d;font-weight:900;text-decoration:none}.sold{opacity:.62}.sold .button{pointer-events:none;background:rgba(255,255,255,.18);color:var(--muted)}
    .options{display:flex;flex-wrap:wrap;gap:10px;margin-top:20px}.options span{border-radius:999px;padding:8px 12px;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.12);color:var(--muted);font-weight:800;font-size:.85rem}
    .contact{margin-top:28px;border-radius:26px;padding:22px;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.14)}
    details{margin-top:10px}.detail{font-size:.95rem;color:var(--muted)}summary{cursor:pointer;color:#fff;font-weight:900}.meta{display:flex;gap:8px;flex-wrap:wrap;margin:.5rem 0}.meta span{border-radius:999px;background:rgba(255,255,255,.1);padding:5px 9px;color:var(--muted);font-size:.78rem;font-weight:800}
    form{display:grid;gap:12px;margin-top:14px}.form-row{display:grid;grid-template-columns:120px 1fr;gap:12px}@media(max-width:600px){.form-row{grid-template-columns:1fr}}
    input,select,textarea{width:100%;border:1px solid rgba(255,255,255,.16);border-radius:16px;background:rgba(0,0,0,.22);color:var(--text);padding:13px 14px;font:inherit}textarea{min-height:110px;resize:vertical}form button{border:0;cursor:pointer}
    .hint{font-size:.92rem;color:var(--muted)}
    footer{padding:36px 0;color:var(--muted);font-size:.9rem}
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <p class="eyebrow">${escapeText(store.domain)}</p>
      <h1>${escapeText(store.storeName || titleFromDomain(store.domain))}</h1>
      <p>${escapeText(store.storeDescription || "Browse this OneWay storefront and contact the seller when you are ready.")}</p>
      ${optionChips ? `<div class="options">${optionChips}</div>` : ""}
    </section>
    <section>
      <h2>Products</h2>
      <div class="grid">${productsHtml}</div>
    </section>
    <section class="contact" id="inquiry">
      <h2>Request order</h2>
      <p class="hint">Tell the seller what you want, how many, and how you would like to receive it. They will reply from OneWay.</p>
      <form method="post" action="${escapeAttr(inquiryEndpoint)}">
        <input name="customerName" autocomplete="name" placeholder="Your name" />
        <input name="customerEmail" type="email" autocomplete="email" placeholder="Email for reply" />
        <input name="customerPhone" autocomplete="tel" placeholder="Phone or text number" />
        <select name="productName">
          <option value="">Choose an item</option>
          ${productOptions}
        </select>
        <div class="form-row">
          <input name="quantity" type="number" min="1" value="1" placeholder="Quantity" />
          <select name="fulfillmentPreference">
            ${fulfillmentOptions}
          </select>
        </div>
        <textarea name="message" required placeholder="What would you like to ask or buy?"></textarea>
        <button class="button" type="submit">Send order request</button>
      </form>
    </section>
    ${contactRows ? `<section class="contact" id="contact"><h2>Other ways to buy</h2>${contactRows}</section>` : ""}
    <footer>Hosted on OneWay</footer>
  </main>
</body>
</html>`);
}

function renderProductCard(store: SiteStore, product: SiteStoreProduct): string {
  const soldOut = product.inventoryStatus === "sold_out";
  const lowStock = Boolean(product.trackInventory && typeof product.inventoryCount === "number" && product.inventoryCount > 0 && product.inventoryCount <= (product.lowStockThreshold ?? 3));
  const stockText = product.trackInventory
    ? soldOut
      ? "Sold out"
      : `${product.inventoryCount ?? 0} available`
    : "Available";
  const image = product.imageUrl
    ? `<img src="${escapeAttr(product.imageUrl)}" alt="${escapeAttr(product.name)}" loading="lazy" />`
    : `<img alt="" />`;
  const paymentLink = safeHref(product.paymentLinkUrl || "") || safeHref(store.paymentLinkUrl);
  const productMode = resolveProductActionMode(store, product, paymentLink);
  const actionLabel = productMode === "oneway_wallet"
    ? "Pay with OneWay"
    : productMode === "payment_link"
      ? "Buy now"
      : "Request order";
  const href = productMode === "payment_link" && paymentLink
    ? storeBuyEndpoint(store.domain, product.id)
    : "#inquiry";
  return `<article class="card ${soldOut ? "sold" : ""}">
    ${soldOut ? `<span class="badge">Sold out</span>` : ""}
    ${lowStock ? `<span class="badge low">Low stock</span>` : ""}
    ${image}
    <div class="content">
      <h2>${escapeText(product.name)}</h2>
      <p>${escapeText(product.description)}</p>
      <div class="meta"><span>${escapeText(stockText)}</span><span>${escapeText(enabledFulfillmentPreferences(store).map(fulfillmentLabel).join(" • "))}</span></div>
      <div class="price">${formatPrice(product.priceCents, store.currency)}</div>
      <details>
        <summary>Product details</summary>
        <p class="detail">${escapeText(product.description || "Message the seller for details, availability, pickup, shipping, or digital delivery.")}</p>
      </details>
      <a class="button" href="${escapeAttr(soldOut ? "#" : href)}">${soldOut ? "Sold out" : escapeText(actionLabel)}</a>
    </div>
  </article>`;
}

function resolveProductActionMode(store: SiteStore, product: SiteStoreProduct, paymentLink: string): CheckoutMode {
  const productMode = product.paymentMode ?? "contact";
  if (productMode === "oneway_wallet" && isWalletPubliclyAvailable()) return "oneway_wallet";
  if (productMode === "payment_link" && paymentLink) return "payment_link";
  if (store.checkoutMode === "oneway_wallet" && isWalletPubliclyAvailable()) return "oneway_wallet";
  if (store.checkoutMode === "payment_link" && paymentLink) return "payment_link";
  return "contact";
}

function formatPrice(priceCents: number, currency: string): string {
  try {
    return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(priceCents / 100);
  } catch {
    return `$${(priceCents / 100).toFixed(2)}`;
  }
}

function safeHref(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  return "";
}

function storeInquiryEndpoint(domain: string): string {
  const slug = domain.replace(/\.oneway\.app$/, "");
  return `${publicStoreApiBase()}/api/stores/${encodeURIComponent(slug)}/inquiries`;
}

function storeBuyEndpoint(domain: string, productId: string): string {
  const slug = domain.replace(/\.oneway\.app$/, "");
  return `${publicStoreApiBase()}/api/stores/${encodeURIComponent(slug)}/buy/${encodeURIComponent(productId)}`;
}

function publicStoreUrl(domain: string): string {
  const slug = domain.replace(/\.oneway\.app$/, "");
  return `${publicStoreApiBase()}/api/stores/${encodeURIComponent(slug)}`;
}

function renderStoreReplyEmail(input: {
  domain: string;
  customerName: string;
  productName: string;
  message: string;
}): string {
  const heading = input.productName.trim()
    ? `Update about ${input.productName.trim()}`
    : `Update from ${titleFromDomain(input.domain)}`;
  const greeting = input.customerName.trim()
    ? `Hi ${input.customerName.trim()},`
    : "Hi,";

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeText(heading)}</title>
</head>
<body style="margin:0;background:#13072d;color:#f7f2ff;font-family:-apple-system,BlinkMacSystemFont,'Avenir Next',Arial,sans-serif;">
  <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
    <div style="border:1px solid rgba(255,255,255,.16);border-radius:24px;background:#24104f;padding:28px;">
      <p style="margin:0 0 8px;color:#ffcc33;font-size:12px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;">OneWay Storefront</p>
      <h1 style="margin:0 0 18px;font-size:28px;line-height:1.15;color:#ffffff;">${escapeText(heading)}</h1>
      <p style="margin:0 0 14px;color:#d8cdf3;">${escapeText(greeting)}</p>
      <div style="white-space:pre-line;color:#f7f2ff;line-height:1.58;font-size:16px;">${escapeText(input.message)}</div>
      <p style="margin:24px 0 0;color:#a998d7;font-size:13px;">Sent from ${escapeText(titleFromDomain(input.domain))} on OneWay.</p>
    </div>
  </div>
</body>
</html>`;
}

function publicStoreApiBase(): string {
  return (process.env.STORE_PUBLIC_API_BASE_URL?.trim()
    || process.env.SMS_WEBHOOK_BASE_URL?.trim()
    || process.env.PSTN_WEBHOOK_BASE_URL?.trim()
    || "https://api.oneway.is").replace(/\/+$/, "");
}

function contactHref(store: SiteStore, productName: string): string {
  const email = safeEmail(store.contactEmail);
  if (email) {
    return `mailto:${email}?subject=${encodeURIComponent(`Interested in ${productName}`)}`;
  }
  return "#contact";
}

function wantsHtml(req: express.Request): boolean {
  const accept = String(req.headers.accept ?? "");
  const contentType = String(req.headers["content-type"] ?? "");
  return accept.includes("text/html") || contentType.includes("application/x-www-form-urlencoded");
}

function renderInquiryResultPage(input: { title: string; message: string; domain: string }): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeText(input.title)}</title>
  <style>
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:linear-gradient(145deg,#10051f,#3c187a);color:#f7f2ff;font-family:-apple-system,BlinkMacSystemFont,"Avenir Next",sans-serif}
    main{width:min(520px,calc(100% - 32px));border:1px solid rgba(255,255,255,.16);border-radius:28px;background:rgba(255,255,255,.08);padding:28px;box-shadow:0 28px 80px rgba(0,0,0,.24)}
    h1{margin:0 0 10px;font-size:2rem}p{color:#c9b9ee;line-height:1.5}a{display:inline-flex;margin-top:12px;border-radius:999px;background:#fff;color:#16072d;padding:12px 16px;text-decoration:none;font-weight:900}
  </style>
</head>
<body>
  <main>
    <h1>${escapeText(input.title)}</h1>
    <p>${escapeText(input.message)}</p>
    <a href="https://${escapeAttr(input.domain)}">Back to store</a>
  </main>
</body>
</html>`;
}

function safeEmail(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed)) return "";
  return trimmed;
}

function safeImageUrl(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  if (trimmed.startsWith("/uploads/")) return trimmed;
  return "";
}

function sanitizeHtml(html: string): string {
  return html
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "")
    .replace(/\son[a-z]+\s*=\s*"[^"]*"/gi, "")
    .replace(/\son[a-z]+\s*=\s*'[^']*'/gi, "")
    .replace(/\son[a-z]+\s*=\s*[^\s>]+/gi, "")
    .replace(/javascript:/gi, "");
}

function escapeText(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeAttr(value: string): string {
  return escapeText(value)
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

async function auditStoreOrderChange(
  prisma: PrismaClient,
  input: {
    actorId: string;
    action: "storefront.order_status_changed" | "storefront.payment_status_changed";
    domain: string;
    orderId: string;
    metadata: Record<string, unknown>;
  },
): Promise<void> {
  await recordAuditEventSafe(prisma, {
    actorId: input.actorId,
    actorType: "user",
    action: input.action,
    resourceType: "store_order",
    resourceId: input.orderId,
    metadata: {
      domain: input.domain,
      ...input.metadata,
    },
  });
}

async function uniqueHandle(prisma: PrismaClient, base: string): Promise<string> {
  let candidate = base;
  let counter = 1;
  while (await prisma.storefront.findFirst({ where: { OR: [{ handle: candidate }, { slug: candidate }] } })) {
    candidate = `${base}-${counter++}`;
  }
  return candidate;
}
