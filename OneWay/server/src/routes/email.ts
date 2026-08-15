import type { PrismaClient } from "@prisma/client";
import express from "express";
import multer from "multer";
import { z } from "zod";

import { logger } from "../lib/logger";
import { emailSendRateLimit } from "../lib/rateLimit";
import type { ObjectStorage } from "../lib/storage/ObjectStorage";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import type { EmailProvider } from "../services/email/EmailProvider";
import type { EmailAlertPushService } from "../services/EmailAlertPushService";
import { MailboxError, OneWayMailboxService, type MailFolder } from "../services/email/OneWayMailboxService";
import {
  createStoreEmailMessage,
  extractStoreReplyTarget,
  fallbackProviderMessageId,
  normalizeEmail,
  sanitizeEmailHtml,
  sanitizeEmailText,
} from "../services/storeEmailMessages";

const upload = multer({ limits: { files: 10, fileSize: 25_000_000, fields: 100 } });

export function emailRouter({ prisma, storage, provider, alerts }: { prisma: PrismaClient; storage: ObjectStorage; provider: EmailProvider; alerts?: EmailAlertPushService }) {
  const router = express.Router();
  const mailbox = new OneWayMailboxService(prisma, storage, provider, alerts);

  // Public Mailgun Routes/Forwards target. Authentication is the provider's
  // timestamped HMAC signature; user JWT auth is intentionally not used here.
  router.post("/mailgun/inbound", upload.any(), async (req, res) => {
    try {
      const fields = req.body as Record<string, unknown>;
      const headers = parseMailgunHeaders(field(fields, "message-headers"));
      const result = await mailbox.ingestMailgun({
        timestamp: field(fields, "timestamp"),
        token: field(fields, "token"),
        signature: field(fields, "signature"),
        recipient: field(fields, "recipient"),
        sender: normalizeEmail(field(fields, "sender")) || extractAddress(field(fields, "from")) || field(fields, "sender"),
        subject: sanitizeEmailText(field(fields, "subject")),
        bodyText: sanitizeEmailText(field(fields, "stripped-text") || field(fields, "body-plain")),
        bodyHtml: sanitizeEmailHtml(field(fields, "stripped-html") || field(fields, "body-html")),
        cc: splitAddresses(headers.cc || ""),
        messageId: headers["message-id"],
        spam: (headers["x-mailgun-sflag"] || "").toLowerCase() === "yes",
        spamScore: numberOrUndefined(headers["x-mailgun-sscore"]),
        headers,
      }, (req.files as Express.Multer.File[] | undefined) || []);
      res.status(200).json({ ok: true, ...result });
    } catch (error) {
      respondMailboxError(res, error);
    }
  });

  router.post("/mailgun/events", async (req, res) => {
    try {
      const body = req.body as Record<string, any>;
      const signature = body.signature || {};
      const event = body["event-data"] || body.eventData || {};
      const rawEventType = String(event.event || "");
      const eventType = rawEventType === "failed"
        ? (String(event.severity || "").toLowerCase() === "temporary" ? "temporary_fail" : "permanent_fail")
        : rawEventType;
      const result = await mailbox.ingestMailgunEvent({
        timestamp: String(signature.timestamp || ""), token: String(signature.token || ""), signature: String(signature.signature || ""),
        eventId: String(event.id || ""), eventType, recipient: typeof event.recipient === "string" ? event.recipient : undefined,
        providerMessageId: event.message?.headers?.["message-id"], oneWayMessageId: event["user-variables"]?.["oneway-message-id"],
        safeDetails: { severity: event.severity, reason: event.reason, deliveryCode: event["delivery-status"]?.code, description: event["delivery-status"]?.description },
      });
      res.status(200).json({ ok: true, ...result });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.post("/sendgrid/inbound", upload.none(), async (req, res) => {
    if (!isInboundWebhookAllowed(req)) {
      res.status(401).json({ ok: false, error: "email_webhook_unauthorized" });
      return;
    }

    const fields = req.body as Record<string, unknown>;
    const to = field(fields, "to");
    const from = field(fields, "from");
    const subject = sanitizeEmailText(field(fields, "subject"));
    const text = sanitizeEmailText(field(fields, "text") || field(fields, "plain"));
    const html = sanitizeEmailHtml(field(fields, "html"));
    const envelope = field(fields, "envelope");
    const headers = field(fields, "headers");
    const providerMessageId = field(fields, "sg_message_id")
      || field(fields, "message-id")
      || extractHeader(headers, "Message-ID")
      || fallbackProviderMessageId("sendgrid_inbound");

    const target = extractStoreReplyTarget([to, envelope, headers]);
    if (!target) {
      logger.info({
        hasRecipient: Boolean(to),
        hasSubject: Boolean(subject),
      }, "[email:inbound] no store reply target matched");
      res.status(202).json({ ok: true, matched: false });
      return;
    }

    if (target.kind === "orders") {
      const order = await prisma.storeOrderRequest.findFirst({ where: { id: target.id } });
      if (!order) {
        res.status(202).json({ ok: true, matched: false, reason: "order_not_found" });
        return;
      }
      await createStoreEmailMessage(prisma, {
        userId: order.userId,
        domain: order.domain,
        orderRequestId: order.id,
        inquiryId: order.inquiryId,
        direction: "inbound",
        fromEmail: normalizeEmail(from) || from,
        toEmail: to,
        subject,
        bodyText: text || stripHtml(html),
        bodyHtml: html || null,
        provider: "sendgrid",
        providerMessageId,
        status: "received",
      });
      await createNotificationBestEffort(prisma, {
        userId: order.userId,
        domain: order.domain,
        type: "order_email_reply",
        title: "Customer replied",
        body: `${order.customerName || order.customerEmail || "A customer"} replied by email.`,
        relatedInquiryId: order.inquiryId,
        relatedOrderRequestId: order.id,
      });
      res.json({ ok: true, matched: true, kind: target.kind, id: target.id });
      return;
    }

    const inquiry = await prisma.storeInquiry.findFirst({ where: { id: target.id } });
    if (!inquiry) {
      res.status(202).json({ ok: true, matched: false, reason: "inquiry_not_found" });
      return;
    }
    await createStoreEmailMessage(prisma, {
      userId: inquiry.userId,
      domain: inquiry.domain,
      inquiryId: inquiry.id,
      direction: "inbound",
      fromEmail: normalizeEmail(from) || from,
      toEmail: to,
      subject,
      bodyText: text || stripHtml(html),
      bodyHtml: html || null,
      provider: "sendgrid",
      providerMessageId,
      status: "received",
    });
    await createNotificationBestEffort(prisma, {
      userId: inquiry.userId,
      domain: inquiry.domain,
      type: "inquiry_email_reply",
      title: "Customer replied",
      body: `${inquiry.customerName || inquiry.customerEmail || "A customer"} replied by email.`,
      relatedInquiryId: inquiry.id,
    });
    res.json({ ok: true, matched: true, kind: target.kind, id: target.id });
  });

  router.get("/readiness", async (_req, res) => {
    const readiness = mailbox.readiness();
    res.status(readiness.ready ? 200 : 503).json(readiness);
  });

  router.use(authMiddleware);

  router.get("/mailbox", async (req, res) => {
    try {
      res.json({ mailbox: await mailbox.getMailbox((req as AuthenticatedRequest).userId) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.post("/mailbox/claim", async (req, res) => {
    try {
      const parsed = z.object({ address: z.string().max(254).optional() }).parse(req.body || {});
      res.status(201).json({ mailbox: await mailbox.claim((req as AuthenticatedRequest).userId, parsed.address) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.get("/messages", async (req, res) => {
    try {
      const parsed = z.object({
        folder: z.enum(["inbox", "starred", "sent", "drafts", "archive", "trash", "spam", "all"]).default("inbox"),
        cursor: z.string().optional(), query: z.string().max(200).optional(), limit: z.coerce.number().int().min(1).max(100).default(40),
      }).parse(req.query);
      res.json(await mailbox.list((req as AuthenticatedRequest).userId, parsed.folder as MailFolder, parsed.cursor, parsed.limit, parsed.query));
    } catch (error) { respondMailboxError(res, error); }
  });

  router.get("/threads/:threadId", async (req, res) => {
    try { res.json(await mailbox.thread((req as unknown as AuthenticatedRequest).userId, req.params.threadId)); }
    catch (error) { respondMailboxError(res, error); }
  });

  router.post("/drafts", async (req, res) => {
    try {
      const input = mailInputSchema.parse(req.body);
      res.status(201).json({ message: await mailbox.saveDraft((req as AuthenticatedRequest).userId, input) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.post("/send", emailSendRateLimit(), async (req, res) => {
    try {
      const input = mailInputSchema.extend({ draftId: z.string().optional(), inReplyTo: z.string().optional(), references: z.array(z.string()).max(100).optional() }).parse(req.body);
      res.status(202).json({ message: await mailbox.send((req as AuthenticatedRequest).userId, input) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.patch("/messages/:messageId", async (req, res) => {
    try {
      const input = z.object({ folder: z.enum(["inbox", "sent", "drafts", "archive", "trash", "spam"]).optional(), isRead: z.boolean().optional(), isStarred: z.boolean().optional() }).parse(req.body);
      res.json({ message: await mailbox.update((req as unknown as AuthenticatedRequest).userId, req.params.messageId, input) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.post("/blocked-senders", async (req, res) => {
    try {
      const input = z.object({ sender: z.string().max(254) }).parse(req.body);
      res.status(201).json(await mailbox.blockSender((req as AuthenticatedRequest).userId, input.sender));
    } catch (error) { respondMailboxError(res, error); }
  });

  router.get("/labels", async (req, res) => {
    try { res.json({ labels: await mailbox.labels((req as AuthenticatedRequest).userId) }); }
    catch (error) { respondMailboxError(res, error); }
  });

  router.post("/labels", async (req, res) => {
    try {
      const input = z.object({ name: z.string().min(1).max(40), color: z.string().max(20).default("purple") }).parse(req.body);
      res.status(201).json({ label: await mailbox.createLabel((req as AuthenticatedRequest).userId, input.name, input.color) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.delete("/labels/:labelId", async (req, res) => {
    try { await mailbox.deleteLabel((req as unknown as AuthenticatedRequest).userId, req.params.labelId); res.status(204).end(); }
    catch (error) { respondMailboxError(res, error); }
  });

  router.put("/messages/:messageId/labels", async (req, res) => {
    try {
      const input = z.object({ labelIds: z.array(z.string()).max(50) }).parse(req.body);
      res.json({ message: await mailbox.setMessageLabels((req as unknown as AuthenticatedRequest).userId, req.params.messageId, input.labelIds) });
    } catch (error) { respondMailboxError(res, error); }
  });

  router.get("/attachments/:attachmentId", async (req, res) => {
    try {
      const file = await mailbox.attachment((req as unknown as AuthenticatedRequest).userId, req.params.attachmentId);
      res.setHeader("Content-Type", file.contentType);
      res.setHeader("Content-Length", String(file.bytes));
      res.setHeader("Content-Disposition", `attachment; filename="${file.filename.replace(/["\r\n]/g, "_")}"`);
      file.stream.pipe(res);
    } catch (error) { respondMailboxError(res, error); }
  });

  return router;
}

const mailInputSchema = z.object({
  id: z.string().optional(), threadId: z.string().optional(), to: z.array(z.string()).max(50).default([]),
  cc: z.array(z.string()).max(50).optional(), bcc: z.array(z.string()).max(50).optional(), subject: z.string().max(998).optional(),
  bodyText: z.string().max(1_000_000).default(""), bodyHtml: z.string().max(2_000_000).optional(),
});

function respondMailboxError(res: express.Response, error: unknown): void {
  if (error instanceof MailboxError) {
    res.status(error.status).json({ error: error.code, message: error.message });
    return;
  }
  if (error instanceof z.ZodError) {
    res.status(400).json({ error: "invalid_body", issues: error.issues });
    return;
  }
  logger.error({ err: error }, "[email:mailbox] request failed");
  res.status(500).json({ error: "email_request_failed" });
}

function parseMailgunHeaders(raw: string): Record<string, string> {
  try {
    const entries = JSON.parse(raw) as Array<[string, string]>;
    return Object.fromEntries(entries.map(([key, value]) => [String(key).toLowerCase(), String(value)]));
  } catch { return {}; }
}

function extractAddress(raw: string): string | null {
  const match = raw.match(/<([^<>]+)>/);
  return normalizeEmail(match?.[1] || raw);
}

function splitAddresses(raw: string): string[] {
  return raw.split(",").map(extractAddress).filter((value): value is string => Boolean(value));
}

function numberOrUndefined(value: string | undefined): number | undefined {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function isInboundWebhookAllowed(req: express.Request): boolean {
  const expected = process.env.SENDGRID_INBOUND_WEBHOOK_SECRET?.trim()
    || process.env.EMAIL_INBOUND_WEBHOOK_SECRET?.trim()
    || "";

  if (!expected) {
    return process.env.NODE_ENV !== "production";
  }

  const headerSecret = String(req.headers["x-oneway-email-secret"] || req.headers["x-sendgrid-inbound-secret"] || "");
  const querySecret = typeof req.query.secret === "string" ? req.query.secret : "";
  return headerSecret === expected || querySecret === expected;
}

function field(fields: Record<string, unknown>, key: string): string {
  const value = fields[key];
  if (Array.isArray(value)) return String(value[0] ?? "");
  return String(value ?? "");
}

function extractHeader(headers: string, name: string): string {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = headers.match(new RegExp(`^${escaped}:\\s*(.+)$`, "im"));
  return sanitizeEmailText(match?.[1] ?? "");
}

function stripHtml(html: string): string {
  return sanitizeEmailText(
    html
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>/gi, "\n")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
  );
}

async function createNotificationBestEffort(prisma: PrismaClient, input: {
  userId: string;
  domain: string;
  type: string;
  title: string;
  body: string;
  relatedInquiryId?: string | null;
  relatedOrderRequestId?: string | null;
}): Promise<void> {
  try {
    await prisma.storeNotification.create({
      data: {
        userId: input.userId,
        domain: input.domain,
        type: input.type,
        title: input.title,
        body: input.body,
        status: "unread",
        relatedInquiryId: input.relatedInquiryId ?? null,
        relatedOrderRequestId: input.relatedOrderRequestId ?? null,
      },
    });
  } catch (error) {
    logger.warn({
      err: error,
      userId: input.userId,
      domain: input.domain,
      type: input.type,
      relatedInquiryId: input.relatedInquiryId ?? null,
      relatedOrderRequestId: input.relatedOrderRequestId ?? null,
    }, "[email:inbound] notification create skipped");
  }
}
