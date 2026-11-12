import express, { type RequestHandler } from "express";
import multer from "multer";
import { randomUUID } from "node:crypto";
import { TextDecoder } from "node:util";
import { statfs } from "node:fs/promises";
import type { PrismaClient } from "@prisma/client";
import type { ObjectStorage } from "../lib/storage/ObjectStorage";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { loadPublicIdentity } from "../services/identity";
import { encryptString, decryptString, isFieldEncryptionEnabled } from "../services/privacy/EncryptionService";
import { validCloudMedia } from "./cloudMedia";
import type { CommunityRealtimeServer } from "../realtime/CommunityRealtimeServer";

const maximum = 20 * 1024 * 1024;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const office = new Set(["application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.openxmlformats-officedocument.presentationml.presentation"]);
export function communityAttachmentKind(bytes: Buffer, mime: string): "photo" | "video" | "audio" | "file" | null {
  if (!bytes.length || bytes.length > maximum) return null;
  if (mime.startsWith("image/") || mime.startsWith("video/")) return validCloudMedia(bytes, mime) ? (mime.startsWith("image/") ? "photo" : "video") : null;
  if (["audio/mp4", "audio/x-m4a"].includes(mime)) return bytes.length >= 16 && bytes.toString("ascii", 4, 8) === "ftyp" ? "audio" : null;
  if (mime === "application/pdf") return bytes.toString("ascii", 0, 5) === "%PDF-" ? "file" : null;
  if (office.has(mime)) return bytes.subarray(0, 4).equals(Buffer.from([80,75,3,4])) ? "file" : null;
  if (["text/plain", "text/csv"].includes(mime)) {
    try { new TextDecoder("utf-8", { fatal: true }).decode(bytes); return bytes.includes(0) ? null : "file"; } catch { return null; }
  }
  return null;
}
export function reservedCommunityAttachmentBody(body: string): boolean {
  try { return JSON.parse(body)?.onewayCommunityAttachment !== undefined; } catch { return false; }
}
export function communityAttachmentsRouter(deps: { prisma: PrismaClient; storage: ObjectStorage; realtime?: CommunityRealtimeServer; authenticate?: RequestHandler; identity?: typeof loadPublicIdentity }) {
  const router = express.Router();
  const uploading = new Set<string>();
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: maximum, files: 1, fields: 1, fieldSize: 128 } });
  router.use(deps.authenticate ?? authMiddleware);
  const member: RequestHandler = async (req, res, next) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    if (!uuid.test(String(req.params.id))) { res.status(400).json({ error: "invalid_community_id" }); return; }
    const community = await deps.prisma.community.findFirst({ where: { id: String(req.params.id), deletedAt: null, members: { some: { userId } } } });
    if (!community || JSON.parse(community.bannedUserIdsJson || "[]").includes(userId) || JSON.parse(community.blockedUserIdsJson || "[]").includes(userId)) { res.status(403).json({ error: "community_membership_required" }); return; }
    next();
  };
  router.post("/:id/attachments", member, (req, res, next) => {
    if (!isFieldEncryptionEnabled()) { res.status(503).json({ error: "community_media_not_configured" }); return; }
    const owner = (req as unknown as AuthenticatedRequest).userId;
    if (uploading.has(owner) || uploading.size >= 2) { res.status(429).json({ error: "community_upload_busy" }); return; }
    uploading.add(owner);
    const release = () => uploading.delete(owner); res.once("finish", release); res.once("close", release);
    upload.single("file")(req, res, error => {
      if (error) { res.status(error instanceof multer.MulterError && error.code === "LIMIT_FILE_SIZE" ? 413 : 400).json({ error: "invalid_community_upload" }); return; }
      next();
    });
  }, async (req, res) => {
    const owner = (req as unknown as AuthenticatedRequest).userId;
    const communityId = String(req.params.id);
    const file = req.file;
    const kind = file && communityAttachmentKind(file.buffer, file.mimetype);
    if (!file || !kind) { res.status(400).json({ error: "unsupported_community_attachment", message: "Choose an image, video, voice recording, PDF, text, CSV or Office document up to 20 MB." }); return; }
    const clientMessageId = req.body?.clientMessageId;
    if (typeof clientMessageId !== "string" || !uuid.test(clientMessageId)) { res.status(400).json({ error: "invalid_client_message_id" }); return; }
    const existing = await deps.prisma.communityMessage.findFirst({ where: { communityId, senderId: owner, clientMessageId } });
    if (existing) { res.status(200).json({ message: wire(existing) }); return; }
    // Check membership again after receiving the upload.
    if (!await deps.prisma.community.findFirst({ where: { id: communityId, deletedAt: null, members: { some: { userId: owner } } } })) { res.status(403).end(); return; }
    const id = randomUUID(); const key = `community-media/${communityId}/${id}`;
    const fileName = file.originalname.replace(/[\x00-\x1f/\\]/g, "_").slice(0, 180) || "attachment";
    let stored = false;
    try {
      const previous = await deps.prisma.communityMessage.findMany({ where: { communityId, body: { startsWith: '{"onewayCommunityAttachment":true,' } }, select: { body: true } });
      const used = previous.reduce((sum, row) => { try { const n = JSON.parse(row.body).byteCount; return sum + (Number.isFinite(n) && n > 0 ? n : 0); } catch { return sum; } }, 0);
      if (used + file.size > 250 * 1024 * 1024) { res.status(413).json({ error: "community_storage_full", message: "This community has reached its attachment storage limit." }); return; }
      if (process.env.ONEWAY_PRIVATE_CLOUD_DIR) {
        const disk = await statfs(process.env.ONEWAY_PRIVATE_CLOUD_DIR);
        if (disk.bavail * disk.bsize < 256 * 1024 * 1024 + file.size * 2) { res.status(503).json({ error: "community_storage_busy" }); return; }
      }
      const encrypted = encryptString(file.buffer.toString("base64"), { purpose: "community-media", communityId, id });
      await deps.storage.put(key, Buffer.from(encrypted), "application/octet-stream"); stored = true;
      const identity = await (deps.identity ?? loadPublicIdentity)(owner);
      const message = await deps.prisma.communityMessage.create({ data: { id, communityId, senderId: owner, clientMessageId, senderHandle: identity.onewayId, senderDisplayName: identity.displayName || identity.onewayId, body: JSON.stringify({ onewayCommunityAttachment: true, kind, fileName, mimeType: file.mimetype, byteCount: file.size, key }), status: "sent" } });
      stored = false;
      await deps.prisma.community.update({ where: { id: communityId }, data: { updatedAt: new Date() } });
      res.status(201).json({ message: wire(message) });
      deps.realtime?.broadcastMessageCreated(message).catch(() => undefined);
    } catch { if (stored) await deps.storage.delete(key).catch(() => undefined); res.status(503).json({ error: "community_upload_failed" }); }
  });
  router.get("/:id/attachments/:messageId", member, async (req, res) => {
    if (!uuid.test(String(req.params.messageId))) { res.status(404).end(); return; }
    const message = await deps.prisma.communityMessage.findFirst({ where: { id: String(req.params.messageId), communityId: String(req.params.id) } });
    if (!message) { res.status(404).end(); return; }
    try {
      const info = JSON.parse(message.body);
      if (info.onewayCommunityAttachment !== true || info.key !== `community-media/${String(req.params.id)}/${message.id}`) { res.status(404).end(); return; }
      const object = await deps.storage.read(info.key); if (!object) { res.status(404).end(); return; }
      const chunks: Buffer[] = []; let total = 0;
      for await (const chunk of object.stream) { const b = Buffer.from(chunk); total += b.length; if (total > maximum * 2) { object.stream.destroy(); throw Error("invalid_object"); } chunks.push(b); }
      const bytes = Buffer.from(decryptString(Buffer.concat(chunks).toString(), { purpose: "community-media", communityId: String(req.params.id), id: message.id }), "base64");
      if (bytes.length !== info.byteCount || communityAttachmentKind(bytes, info.mimeType) !== info.kind) throw Error("invalid_media");
      res.set({ "Cache-Control": "no-store", "Content-Type": info.mimeType, "X-Content-Type-Options": "nosniff", "Content-Disposition": "attachment" }).send(bytes);
    } catch { res.status(503).json({ error: "community_download_failed" }); }
  });
  return router;
}
function wire(message: any) { return { id: message.id, clientMessageId: message.clientMessageId, communityId: message.communityId, senderId: message.senderId, senderHandle: message.senderHandle, senderDisplayName: message.senderDisplayName, body: message.body, status: message.status, createdAt: new Date(message.createdAt).toISOString() }; }
