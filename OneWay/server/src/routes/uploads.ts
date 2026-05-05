import express from "express";
import fs from "node:fs/promises";
import path from "node:path";
import multer from "multer";

import { authMiddleware } from "../middleware/auth";
import { publicImageUrl } from "../services/catalog";

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 5 * 1024 * 1024 },
});

export function uploadsRouter(): express.Router {
  const router = express.Router();

  router.post("/", authMiddleware, upload.single("image"), async (req, res) => {
    if (!req.file) {
      res.status(400).json({ error: "image_required" });
      return;
    }

    const extension = extensionFor(req.file.mimetype);
    const filename = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}.${extension}`;
    const uploadsDir = path.join(process.cwd(), "uploads", "storefronts");
    await fs.mkdir(uploadsDir, { recursive: true });
    await fs.writeFile(path.join(uploadsDir, filename), req.file.buffer);

    res.status(201).json({
      imageUrl: publicImageUrl(`storefronts/${filename}`),
      filename,
    });
  });

  return router;
}

function extensionFor(mimeType: string): string {
  switch (mimeType) {
    case "image/png":
      return "png";
    case "image/webp":
      return "webp";
    case "image/gif":
      return "gif";
    default:
      return "jpg";
  }
}
