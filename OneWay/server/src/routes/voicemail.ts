import express from "express";
import path from "path";
import os from "os";
import fs from "fs";
import { z } from "zod";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { voicemailUploadRateLimit } from "../lib/rateLimit";
import type { VoicemailService } from "../services/VoicemailService";
import type { CallHistoryService } from "../services/CallHistoryService";
import { LocalObjectStorage } from "../lib/storage/LocalObjectStorage";
import { logger } from "../lib/logger";

interface VoicemailRouterDeps {
  voicemails: VoicemailService;
  history: CallHistoryService;
  /** When set, the audio route returns 302 → presigned URL instead of
   *  streaming. Use this when storage is S3/R2. */
  preferSignedRedirect?: boolean;
  /** Hand the local-storage instance through if you wired one — enables
   *  the public verifier sub-route under `/api/voicemail/storage/:key`. */
  localStorage?: LocalObjectStorage;
  maxBytes?: number;
}

const ALLOWED_MIME = new Set([
  "audio/m4a",
  "audio/x-m4a",
  "audio/aac",
  "audio/mpeg",
  "audio/wav",
  "audio/x-wav",
]);

const uploadMetaSchema = z.object({
  callId: z.string().uuid(),
  callerId: z.string().min(1).max(64),
  calleeId: z.string().min(1).max(64),
  durationSeconds: z.coerce.number().min(1).max(120),
});

interface MulterFile {
  originalname: string;
  mimetype: string;
  size: number;
  path: string;
}
interface MulterMiddleware { single(field: string): express.RequestHandler; }
interface MulterModule {
  (opts: { dest?: string; limits?: { fileSize: number } }): MulterMiddleware;
}

function loadMulter(): MulterModule | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    return require("multer") as MulterModule;
  } catch {
    logger.warn({}, "[voicemail] multer not installed — upload disabled");
    return null;
  }
}

export function voicemailRouter(deps: VoicemailRouterDeps): express.Router {
  const router = express.Router();

  // Public sub-route for local presigning: must NOT have auth middleware.
  // Wired before the auth middleware below.
  if (deps.localStorage) {
    router.get("/storage/:key", async (req, res) => {
      const expRaw = req.query.exp;
      const sigRaw = req.query.sig;
      if (typeof expRaw !== "string" || typeof sigRaw !== "string") {
        res.status(400).end();
        return;
      }
      const key = decodeURIComponent(req.params.key);
      const ok = deps.localStorage!.verifySignature(key, Number(expRaw), sigRaw);
      if (!ok) {
        res.status(403).end();
        return;
      }
      const result = await deps.localStorage!.read(key);
      if (!result) {
        res.status(404).end();
        return;
      }
      res.setHeader("Content-Type", result.contentType);
      res.setHeader("Content-Length", String(result.bytes));
      result.stream.pipe(res);
    });
  }

  router.use(authMiddleware);

  const multer = loadMulter();
  const upload = multer?.({
    dest: path.join(os.tmpdir(), "oneway-voicemail-staging"),
    limits: { fileSize: deps.maxBytes ?? 5 * 1024 * 1024 },
  });

  // POST /api/voicemail/upload ----------------------------------------------
  if (upload) {
    router.post("/upload", voicemailUploadRateLimit(), upload.single("audio"), async (req, res) => {
      const userId = (req as unknown as AuthenticatedRequest).userId;
      const file = (req as unknown as { file?: MulterFile }).file;
      if (!file) {
        res.status(400).json({ error: "no_file" });
        return;
      }
      if (!ALLOWED_MIME.has(file.mimetype)) {
        await unlinkSafe(file.path);
        res.status(415).json({ error: "unsupported_media_type", mimetype: file.mimetype });
        return;
      }
      const parsed = uploadMetaSchema.safeParse(req.body);
      if (!parsed.success) {
        await unlinkSafe(file.path);
        res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
        return;
      }
      if (parsed.data.callerId !== userId) {
        await unlinkSafe(file.path);
        res.status(403).json({ error: "not_caller" });
        return;
      }
      try {
        const stream = fs.createReadStream(file.path);
        const entry = await deps.voicemails.ingest({
          callId: parsed.data.callId,
          callerId: parsed.data.callerId,
          calleeId: parsed.data.calleeId,
          durationSeconds: parsed.data.durationSeconds,
          mimeType: file.mimetype,
          source: { kind: "stream", data: stream },
        });
        await unlinkSafe(file.path);
        await deps.history.attachVoicemail(entry.callId, entry.id);
        res.status(201).json({ voicemail: deps.voicemails.toPublic(entry) });
      } catch (err) {
        logger.error({ err }, "[voicemail] upload failed");
        await unlinkSafe(file.path);
        res.status(500).json({ error: "upload_failed" });
      }
    });
  } else {
    router.post("/upload", (_req, res) => {
      res.status(503).json({ error: "voicemail_upload_disabled" });
    });
  }

  // GET /api/voicemail/audio/:id --------------------------------------------
  // Streams (or 302s) the audio. Authorization: callee only.
  router.get("/audio/:id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const entry = await deps.voicemails.get(req.params.id);
    if (!entry) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (entry.calleeId !== userId) {
      res.status(403).json({ error: "forbidden" });
      return;
    }
    if (deps.preferSignedRedirect) {
      const url = await deps.voicemails.signedUrl(entry.id, 600);
      if (url && !url.startsWith("local:")) {
        res.redirect(302, url);
        return;
      }
    }
    const handle = await deps.voicemails.stream(entry.id);
    if (!handle) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    res.setHeader("Content-Type", entry.mimeType);
    res.setHeader("Content-Length", String(entry.bytes));
    res.setHeader("Cache-Control", "private, max-age=0, no-cache");
    handle.stream.on("error", (err) => {
      logger.error({ err }, "[voicemail] read error");
      if (!res.headersSent) res.status(500).end();
    });
    handle.stream.pipe(res);
  });

  // GET /api/voicemail/:userId ----------------------------------------------
  router.get("/:userId", async (req, res, next) => {
    if (req.params.userId === "audio" || req.params.userId === "storage" || req.params.userId === "upload") {
      return next();
    }
    const userId = (req as unknown as AuthenticatedRequest).userId;
    if (req.params.userId !== userId) {
      res.status(403).json({ error: "forbidden" });
      return;
    }
    const list = await deps.voicemails.forCallee(userId);
    res.json({ voicemails: list.map((v) => deps.voicemails.toPublic(v)) });
  });

  // POST /api/voicemail/:id/listened ----------------------------------------
  router.post("/:id/listened", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const entry = await deps.voicemails.get(req.params.id);
    if (!entry) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (entry.calleeId !== userId) {
      res.status(403).json({ error: "forbidden" });
      return;
    }
    await deps.voicemails.markListened(entry.id);
    res.status(204).end();
  });

  return router;
}

async function unlinkSafe(p: string): Promise<void> {
  try { await fs.promises.unlink(p); } catch { /* ignore */ }
}
