import express from "express";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import multer from "multer";

import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { S3ObjectStorage } from "../lib/storage/S3ObjectStorage";
import { logger } from "../lib/logger";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.mimetype)) {
      cb(new multer.MulterError("LIMIT_UNEXPECTED_FILE", "image"));
      return;
    }
    cb(null, true);
  }
});

export function uploadsRouter(): express.Router {
  const router = express.Router();
  const s3 = S3ObjectStorage.fromEnv();

  router.post("/image", authMiddleware, upload.single("image"), async (req, res) => {
    if (!req.file) {
      await auditUploadRejected(req, "image_missing");
      res.status(400).json({
        code: "validation_failed",
        error: "validation_failed",
        message: "Please choose an image to upload.",
        field: "image"
      });
      return;
    }

    if (!hasValidImageSignature(req.file.buffer, req.file.mimetype)) {
      await auditUploadRejected(req, "invalid_image_signature", req.file.mimetype);
      res.status(400).json({
        code: "validation_failed",
        error: "validation_failed",
        message: "That image file does not look valid.",
        field: "image"
      });
      return;
    }

    if (req.query.purpose === "ad_creative" && s3 && !s3.hasStablePublicUrls()) {
      res.status(503).json({
        code: "media_delivery_not_configured",
        error: "media_delivery_not_configured",
        message: "Ad creative uploads are unavailable until permanent media delivery is configured."
      });
      return;
    }

    try {
      const extension = extensionFor(req.file.mimetype);
      const filename = `${randomUUID()}.${extension}`;
      const folder = req.query.purpose === "ad_creative" ? "ads" : "storefronts";
      const objectKey = `${folder}/${filename}`;
      const url = s3
        ? await uploadToObjectStorage(s3, objectKey, req.file.buffer, req.file.mimetype)
        : await saveLocally(req, filename, req.file.buffer);

      res.status(201).json({ url });
    } catch (error) {
      logger.error({ err: error }, "[uploads] storefront image upload failed");
      res.status(500).json({
        code: "backend_unavailable",
        error: "backend_unavailable",
        message: "We couldn't upload that image right now."
      });
    }
  });

  router.use((error: unknown, req: express.Request, res: express.Response, next: express.NextFunction) => {
    if (error instanceof multer.MulterError) {
      if (error.code === "LIMIT_FILE_SIZE") {
        void auditUploadRejected(req, "file_too_large");
        res.status(413).json({ code: "validation_failed", error: "validation_failed", message: "Images must be 10MB or smaller.", field: "image" });
        return;
      }
      void auditUploadRejected(req, "unsupported_file_type");
      res.status(400).json({ code: "validation_failed", error: "validation_failed", message: "Only jpg, png, and webp images are supported.", field: "image" });
      return;
    }
    next(error);
  });

  return router;
}

async function auditUploadRejected(req: express.Request, reason: string, mimeType?: string): Promise<void> {
  const auth = req as AuthenticatedRequest;
  await recordAuditEventSafe(prisma, {
    actorId: auth.userId,
    actorType: auth.userId ? "user" : "public",
    action: "upload.rejected",
    resourceType: "upload",
    resourceId: "storefront_image",
    metadata: { reason, mimeType: mimeType ?? null, path: req.path },
  });
}

function extensionFor(mimeType: string): string {
  switch (mimeType) {
    case "image/png":
      return "png";
    case "image/webp":
      return "webp";
    default:
      return "jpg";
  }
}

function hasValidImageSignature(buffer: Buffer, mimeType: string): boolean {
  if (mimeType === "image/jpeg") {
    return buffer.length >= 3
      && buffer[0] === 0xff
      && buffer[1] === 0xd8
      && buffer[2] === 0xff;
  }
  if (mimeType === "image/png") {
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    return buffer.length >= png.length && buffer.subarray(0, png.length).equals(png);
  }
  if (mimeType === "image/webp") {
    return buffer.length >= 12
      && buffer.subarray(0, 4).toString("ascii") === "RIFF"
      && buffer.subarray(8, 12).toString("ascii") === "WEBP";
  }
  return false;
}

async function uploadToObjectStorage(
  storage: S3ObjectStorage,
  objectKey: string,
  buffer: Buffer,
  mimeType: string
) {
  await storage.put(objectKey, buffer, mimeType);
  return await storage.presignedDownloadUrl(objectKey, 60 * 60 * 24 * 7);
}

async function saveLocally(req: express.Request, filename: string, buffer: Buffer) {
  const uploadsRoot = process.env.UPLOADS_DIR?.trim() || path.join(process.cwd(), "uploads");
  const uploadsDir = path.join(uploadsRoot, "storefronts");
  await fs.mkdir(uploadsDir, { recursive: true });
  await fs.writeFile(path.join(uploadsDir, filename), buffer);
  return `${req.protocol}://${req.get("host")}/uploads/storefronts/${filename}`;
}
