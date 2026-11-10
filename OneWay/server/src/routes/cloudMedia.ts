import express, { type RequestHandler } from "express";
import multer from "multer";
import { createHash, randomUUID } from "node:crypto";
import { statfs } from "node:fs/promises";
import type { PrismaClient } from "@prisma/client";
import type { ObjectStorage } from "../lib/storage/ObjectStorage";
import { LocalObjectStorage } from "../lib/storage/LocalObjectStorage";
import { S3ObjectStorage } from "../lib/storage/S3ObjectStorage";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { encryptString, decryptString, isFieldEncryptionEnabled } from "../services/privacy/EncryptionService";

const maximum = 20 * 1024 * 1024;
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: maximum, files: 1, fields: 0 } });
const types = new Set(["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "video/mp4", "video/quicktime"]);

export function validCloudMedia(bytes: Buffer, type: string): boolean {
  if (!types.has(type)) return false;
  if (type === "image/jpeg") return bytes.length > 3 && bytes.subarray(0, 3).equals(Buffer.from([255, 216, 255]));
  if (type === "image/png") return bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (type === "image/webp") return bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP";
  if (bytes.length < 16 || bytes.toString("ascii", 4, 8) !== "ftyp") return false;
  const brand = bytes.toString("ascii", 8, 12);
  return type.startsWith("image/") ? ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].includes(brand) : ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "qt  "].includes(brand);
}

/** Private media: encrypted objects only; downloads always check the account. */
export function cloudMediaRouter(deps: { prisma: PrismaClient; storage?: ObjectStorage | null; authenticate?: RequestHandler }) {
  const router = express.Router();
  const storage = deps.storage === undefined ? (process.env.ONEWAY_PRIVATE_CLOUD_DIR ? new LocalObjectStorage({ root: process.env.ONEWAY_PRIVATE_CLOUD_DIR }) : S3ObjectStorage.fromEnv()) : deps.storage;
  const uploading = new Set<string>();
  router.use(deps.authenticate ?? authMiddleware);
  router.use((_req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.post("/files/upload", (req, res, next) => {
    if (!storage || !isFieldEncryptionEnabled()) { res.status(503).json({ error: "private_cloud_not_configured" }); return; }
    const owner = (req as unknown as AuthenticatedRequest).userId;
    if (uploading.has(owner) || uploading.size >= 2) { res.status(429).json({ error: "cloud_busy" }); return; }
    uploading.add(owner);
    const release = () => uploading.delete(owner);
    res.once("finish", release); res.once("close", release);
    upload.single("file")(req, res, error => {
      if (error) { res.status(error instanceof multer.MulterError && error.code === "LIMIT_FILE_SIZE" ? 413 : 400).json({ error: "invalid_cloud_upload" }); return; }
      next();
    });
  }, async (req, res) => {
    const owner = (req as unknown as AuthenticatedRequest).userId;
    const file = req.file;
    if (!file || !validCloudMedia(file.buffer, file.mimetype)) { res.status(400).json({ error: "unsupported_cloud_media" }); return; }
    const id = randomUUID();
    const key = `private-media/${createHash("sha256").update(owner).digest("hex")}/${id}`;
    const name = file.originalname.replace(/[\x00-\x1f/\\]/g, "_").slice(0, 180) || "media";
    try {
      const totals = await deps.prisma.$queryRawUnsafe<any[]>(`SELECT COALESCE(SUM("byteCount"), 0) AS "bytes" FROM "CloudFile" WHERE "ownerId" = ? AND "storageKey" LIKE 'private-media/%'`, owner);
      if (Number(totals[0]?.bytes ?? 0) + file.size > 250 * 1024 * 1024) { res.status(413).json({ error: "cloud_quota_exceeded" }); return; }
      if (deps.storage === undefined && process.env.ONEWAY_PRIVATE_CLOUD_DIR) {
        const disk = await statfs(process.env.ONEWAY_PRIVATE_CLOUD_DIR);
        if (disk.bavail * disk.bsize < 256 * 1024 * 1024 + file.size * 2) { res.status(503).json({ error: "cloud_storage_full" }); return; }
      }
      const encrypted = encryptString(file.buffer.toString("base64"), { purpose: "cloud-media", owner, id });
      await storage!.put(key, Buffer.from(encrypted), "application/octet-stream");
      try {
        await deps.prisma.$executeRawUnsafe(`INSERT INTO "CloudFile" ("id", "ownerId", "name", "mimeType", "byteCount", "storageKey", "encrypted", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, ?, ?, true, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`, id, owner, name, file.mimetype, file.size, key);
      } catch (error) { await storage!.delete(key).catch(() => undefined); throw error; }
      res.status(201).json({ file: { id, name, mimeType: file.mimetype, byteCount: file.size, storageKey: key, encrypted: true, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } });
    } catch { res.status(503).json({ error: "cloud_upload_failed" }); }
  });
  router.get("/files/:id/content", async (req, res) => {
    const owner = (req as unknown as AuthenticatedRequest).userId;
    if (!storage) { res.status(503).json({ error: "private_cloud_not_configured" }); return; }
    if (!/^[0-9a-f-]{36}$/i.test(String(req.params.id))) { res.status(404).end(); return; }
    try {
      const rows = await deps.prisma.$queryRawUnsafe<any[]>(`SELECT "id", "storageKey", "mimeType", "byteCount" FROM "CloudFile" WHERE "id" = ? AND "ownerId" = ? LIMIT 1`, req.params.id, owner);
      const file = rows[0];
      const prefix = `private-media/${createHash("sha256").update(owner).digest("hex")}/`;
      if (!file || !file.storageKey.startsWith(prefix) || !types.has(file.mimeType)) { res.status(404).end(); return; }
      const object = await storage.read(file.storageKey);
      if (!object) { res.status(404).end(); return; }
      const chunks: Buffer[] = []; let length = 0;
      for await (const chunk of object.stream) { const bytes = Buffer.from(chunk); length += bytes.length; if (length > maximum * 2) { object.stream.destroy(); throw new Error("invalid_object"); } chunks.push(bytes); }
      const data = Buffer.from(decryptString(Buffer.concat(chunks).toString(), { purpose: "cloud-media", owner, id: file.id }), "base64");
      if (data.length !== Number(file.byteCount) || !validCloudMedia(data, file.mimeType)) throw new Error("invalid_media");
      res.set({ "Content-Type": file.mimeType, "X-Content-Type-Options": "nosniff", "Content-Disposition": "attachment" }).send(data);
    } catch { res.status(503).json({ error: "cloud_download_failed" }); }
  });
  return router;
}
