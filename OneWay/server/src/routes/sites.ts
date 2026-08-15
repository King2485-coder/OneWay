import express from "express";
import fs from "node:fs/promises";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import multer from "multer";
import { z } from "zod";
import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord } from "../services/identity";
import { S3ObjectStorage } from "../lib/storage/S3ObjectStorage";

const SITE_MODES = ["nocode", "code", "ai"] as const;
const DEV_DOMAINS = ["sandbox.oneway.app", "mira.oneway.app"];
const MAX_SITE_IMAGE_BYTES = 12 * 1024 * 1024;
const MAX_SITE_VIDEO_BYTES = 250 * 1024 * 1024;
const SITE_IMAGE_MIME_TYPES = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "image/gif"] as const;
const SITE_VIDEO_MIME_TYPES = ["video/mp4", "video/quicktime", "video/x-m4v"] as const;
const SITE_MEDIA_MIME_TYPES = [...SITE_IMAGE_MIME_TYPES, ...SITE_VIDEO_MIME_TYPES] as const;

const siteImageUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_SITE_VIDEO_BYTES },
  fileFilter: (_req, file, cb) => {
    if (!SITE_MEDIA_MIME_TYPES.includes(file.mimetype as typeof SITE_MEDIA_MIME_TYPES[number])) {
      cb(new multer.MulterError("LIMIT_UNEXPECTED_FILE", "media"));
      return;
    }
    cb(null, true);
  },
});

const sitePatchSchema = z.object({
  domain: z.string().trim().max(80).optional(),
  title: z.string().trim().max(140).optional(),
  description: z.string().trim().max(500).optional(),
  mode: z.enum(SITE_MODES).optional(),
  html: z.string().max(200_000).optional(),
  blocks: z.array(z.record(z.unknown())).max(80).optional(),
  aiPrompt: z.string().trim().max(2_000).optional(),
});

const aiGenerateSchema = z.object({
  title: z.string().trim().max(140).optional(),
  description: z.string().trim().max(500).optional(),
  prompt: z.string().trim().min(1).max(2_000),
});

const mediaMetadataSchema = z.object({
  altText: z.string().trim().max(500).optional().default(""),
  caption: z.string().trim().max(500).optional().default(""),
  focalPointX: z.number().min(0).max(1).optional().default(0.5),
  focalPointY: z.number().min(0).max(1).optional().default(0.5),
});

const uploadSessionSchema = z.object({
  mediaType: z.enum(["IMAGE", "VIDEO"]).optional(),
  fileName: z.string().trim().min(1).max(240),
  mimeType: z.enum(SITE_MEDIA_MIME_TYPES),
  fileSizeBytes: z.number().int().positive().max(MAX_SITE_VIDEO_BYTES),
  checksum: z.string().trim().max(160).optional(),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
  durationMilliseconds: z.number().int().positive().optional(),
});

const publishSchema = z.object({
  idempotencyKey: z.string().trim().min(8).max(160).optional(),
  visibility: z.enum(["PUBLIC", "UNLISTED", "PRIVATE"]).optional().default("PUBLIC"),
});

type SiteMode = typeof SITE_MODES[number];

type SiteDTO = {
  id: string;
  userId: string;
  domain: string;
  title: string;
  description: string;
  mode: SiteMode;
  html: string;
  blocks: unknown[];
  aiPrompt: string;
  publishedHtml: string;
  publishedAt: string | null;
  published: boolean;
  updatedAt: string;
  createdAt: string;
};

export function sitesRouter(): express.Router {
  const router = express.Router();
  const s3 = S3ObjectStorage.fromEnv();

  router.get("/:domain/public", async (req, res) => {
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const slug = slugFromDomain(domain);
    console.info("SITE_PUBLIC_RESOLVER_REQUEST_STARTED", { slug, domain, stage: "legacy_public_route" });
    const resolved = await resolvePublicSitePublication(slug, domain);
    if (!resolved.ok) {
      const statusCode = resolved.code === "PUBLICATION_STATE_INVALID" || resolved.code === "PUBLICATION_UNAVAILABLE" ? 409 : 404;
      console.warn("SITE_PUBLIC_ROUTE_VERIFICATION_FAILED", { slug, domain, failureCode: resolved.code, stage: resolved.stage });
      res.status(statusCode).json({ error: resolved.code, message: resolved.message });
      return;
    }

    console.info("SITE_PUBLIC_ROUTE_VERIFICATION_SUCCEEDED", { siteId: resolved.site.id, publicationId: resolved.publication.id, slug, domain });
    res.json(toResolvedPublicDTO(resolved.site, resolved.publication));
  });

  router.get("/:siteId/publication/health", async (req, res) => {
    const siteId = String(req.params.siteId ?? "").trim();
    if (!siteId) return res.status(400).json({ error: "invalid_site_id" });
    const health = await publicationHealth(siteId);
    res.status(health.siteExists ? 200 : 404).json(health);
  });

  router.use(authMiddleware);

  router.get("/", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    await ensureDevSites(userId);

    const sites = await prisma.site.findMany({
      where: { userId },
      orderBy: [{ updatedAt: "desc" }],
    });
    res.json({ sites: sites.map(toDTO) });
  });

  router.post("/:domain/media/upload-session", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const parsed = uploadSessionSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });

    const site = await findOrCreateSite(userId, domain);
    const mediaType = parsed.data.mediaType ?? mediaTypeForMimeType(parsed.data.mimeType);
    if (!mimeMatchesMediaType(parsed.data.mimeType, mediaType)) {
      return res.status(400).json({ error: "invalid_media_type", message: "The selected file type does not match the requested media category." });
    }
    if (parsed.data.fileSizeBytes > maxBytesForMediaType(mediaType)) {
      return res.status(400).json({ error: "file_too_large", message: mediaType === "VIDEO" ? "Videos must be 250MB or smaller." : "Images must be 12MB or smaller." });
    }
    const assetId = randomUUID();
    const extension = extensionForMimeType(parsed.data.mimeType);
    const safeName = safeFileName(parsed.data.fileName, extension);
    const storageKey = `sites/${safeSegment(userId)}/${site.id}/${mediaType.toLowerCase()}s/${assetId}/original-${safeName}`;
    const asset = await prisma.siteMediaAsset.create({
      data: {
        id: assetId,
        siteId: site.id,
        ownerId: userId,
        mediaType,
        storageKey,
        originalStorageKey: storageKey,
        originalFileName: safeName,
        mimeType: parsed.data.mimeType,
        sourceMimeType: parsed.data.mimeType,
        outputMimeType: mediaType === "VIDEO" ? "video/mp4" : parsed.data.mimeType,
        width: parsed.data.width ?? null,
        height: parsed.data.height ?? null,
        durationMilliseconds: parsed.data.durationMilliseconds ?? null,
        fileSizeBytes: parsed.data.fileSizeBytes,
        checksum: parsed.data.checksum ?? "",
        uploadStatus: "UPLOADING",
        processingStatus: "UPLOADING",
        publicStatus: "PRIVATE",
        variantsJson: "{}",
      },
    });
    console.info(mediaType === "VIDEO" ? "SITE_VIDEO_UPLOAD_SESSION_CREATED" : "SITE_IMAGE_UPLOAD_SESSION_CREATED", {
      siteId: site.id,
      assetId,
      mediaType,
      byteCount: parsed.data.fileSizeBytes,
      stage: "session_created",
    });
    res.status(201).json({
      assetId,
      uploadMethod: "multipart",
      uploadUrl: `/api/sites/${encodeURIComponent(domain)}/media/${asset.id}/complete`,
      method: "POST",
      requiredHeaders: { "Content-Type": "multipart/form-data" },
      maxBytes: maxBytesForMediaType(mediaType),
      expectedMimeTypes: mediaType === "VIDEO" ? SITE_VIDEO_MIME_TYPES : SITE_IMAGE_MIME_TYPES,
      expiresInSeconds: 900,
      asset: toMediaDTO(asset),
    });
  });

  router.post("/:domain/media/:assetId/complete", siteImageUpload.single("media"), async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    if (!req.file) return res.status(400).json({ error: "media_required", message: "Choose a file before uploading." });

    try {
      const site = await findOrCreateSite(userId, domain);
      const assetId = String(req.params.assetId);
      const existing = await prisma.siteMediaAsset.findFirst({ where: { id: assetId, siteId: site.id, ownerId: userId, deletedAt: null } });
      if (!existing) return res.status(404).json({ error: "media_not_found", message: "Upload session was not found or expired." });
      const mediaType = mediaTypeForMimeType(req.file.mimetype);
      if (existing.mediaType !== mediaType || !mimeMatchesMediaType(req.file.mimetype, mediaType)) {
        await prisma.siteMediaAsset.update({ where: { id: existing.id }, data: { uploadStatus: "FAILED", processingStatus: "FAILED", failureCode: "mime_mismatch", failureMessage: "The uploaded file type did not match the upload session." } });
        return res.status(400).json({ error: "mime_mismatch", message: "The uploaded file type did not match the upload session." });
      }
      validateMediaSignature(req.file.buffer, req.file.mimetype, mediaType);
      if (req.file.size === 0) {
        throw new Error("The selected file has no readable bytes.");
      }
      if (req.file.size > maxBytesForMediaType(mediaType)) {
        throw new Error(mediaType === "VIDEO" ? "Videos must be 250MB or smaller." : "Images must be 12MB or smaller.");
      }
      const storageKey = existing.storageKey;
      const url = s3
        ? await uploadSiteAssetToObjectStorage(s3, storageKey, req.file.buffer, req.file.mimetype)
        : await saveSiteAssetLocally(req, storageKey, req.file.buffer);
      const checksum = createHash("sha256").update(req.file.buffer).digest("hex");
      const metadata = mediaMetadataSchema.safeParse(req.body ?? {});
      const variants = mediaType === "VIDEO" ? videoVariants(url) : responsiveVariants(url);
      console.info(mediaType === "VIDEO" ? "SITE_VIDEO_UPLOAD_HTTP_RESPONSE" : "SITE_IMAGE_UPLOAD_HTTP_RESPONSE", {
        siteId: site.id,
        assetId,
        mediaType,
        responseCode: 201,
        byteCount: req.file.size,
        stage: "storage_write_complete",
      });
      const asset = await prisma.siteMediaAsset.update({
        where: { id: existing.id },
        data: {
          mediaType,
          mimeType: req.file.mimetype,
          sourceMimeType: req.file.mimetype,
          outputMimeType: mediaType === "VIDEO" ? "video/mp4" : req.file.mimetype,
          fileSizeBytes: req.file.size,
          checksum,
          uploadStatus: "UPLOADED",
          processingStatus: "READY",
          publicStatus: "PRIVATE",
          altText: metadata.success ? metadata.data.altText : "",
          caption: metadata.success ? metadata.data.caption : "",
          focalPointX: metadata.success ? metadata.data.focalPointX : 0.5,
          focalPointY: metadata.success ? metadata.data.focalPointY : 0.5,
          variantsJson: JSON.stringify(variants),
        },
      });
      console.info(mediaType === "VIDEO" ? "SITE_VIDEO_TRANSCODING_SUCCEEDED" : "SITE_IMAGE_PROCESSING_SUCCEEDED", { siteId: site.id, assetId: asset.id, mediaType, stage: "ready" });
      console.info(mediaType === "VIDEO" ? "SITE_VIDEO_RECORD_CREATED" : "SITE_IMAGE_RECORD_CREATED", { siteId: site.id, assetId: asset.id, mediaType, stage: "record_updated" });
      res.status(201).json({ asset: toMediaDTO(asset, url), variants });
    } catch (error) {
      const assetId = String(req.params.assetId);
      await prisma.siteMediaAsset.updateMany({
        where: { id: assetId, ownerId: userId },
        data: { uploadStatus: "FAILED", processingStatus: "FAILED", failureCode: "upload_failed", failureMessage: error instanceof Error ? error.message : "Media upload failed." },
      });
      console.error("SITE_MEDIA_UPLOAD_FAILED", { domain, assetId, status: "failed", failureCode: "upload_failed" });
      res.status(400).json({ error: "site_asset_upload_failed", message: error instanceof Error ? error.message : "Media upload failed." });
    }
  });

  router.get("/:domain/media", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOrCreateSite(userId, domain);
    const assets = await prisma.siteMediaAsset.findMany({
      where: { siteId: site.id, ownerId: userId, deletedAt: null },
      orderBy: { createdAt: "desc" },
    });
    console.info("SITE_MEDIA_LIBRARY_OPENED", { siteId: site.id, status: "ok" });
    res.json({ assets: assets.map((asset) => toMediaDTO(asset)) });
  });

  router.get("/:domain/media/:assetId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOrCreateSite(userId, domain);
    const asset = await prisma.siteMediaAsset.findFirst({ where: { id: String(req.params.assetId), siteId: site.id, ownerId: userId, deletedAt: null } });
    if (!asset) return res.status(404).json({ error: "media_not_found" });
    res.json({ asset: toMediaDTO(asset) });
  });

  router.post("/:domain/media/:assetId/retry-processing", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOrCreateSite(userId, domain);
    const existing = await prisma.siteMediaAsset.findFirst({ where: { id: String(req.params.assetId), siteId: site.id, ownerId: userId, deletedAt: null } });
    if (!existing) return res.status(404).json({ error: "media_not_found" });
    const asset = await prisma.siteMediaAsset.update({
      where: { id: existing.id },
      data: { uploadStatus: "UPLOADED", processingStatus: "READY", failureCode: null, failureMessage: null },
    });
    console.info(asset.mediaType === "VIDEO" ? "SITE_VIDEO_TRANSCODING_SUCCEEDED" : "SITE_IMAGE_PROCESSING_SUCCEEDED", { siteId: site.id, assetId: asset.id, mediaType: asset.mediaType, stage: "retry_processing" });
    res.json({ asset: toMediaDTO(asset) });
  });

  router.patch("/:domain/media/:assetId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    const parsed = mediaMetadataSchema.partial().safeParse(req.body ?? {});
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const site = await findOrCreateSite(userId, domain);
    const existing = await prisma.siteMediaAsset.findFirst({ where: { id: String(req.params.assetId), siteId: site.id, ownerId: userId, deletedAt: null } });
    if (!existing) return res.status(404).json({ error: "media_not_found" });
    const asset = await prisma.siteMediaAsset.update({
      where: { id: existing.id },
      data: parsed.data,
    });
    res.json({ asset: toMediaDTO(asset) });
  });

  router.delete("/:domain/media/:assetId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOrCreateSite(userId, domain);
    const asset = await prisma.siteMediaAsset.findFirst({ where: { id: String(req.params.assetId), siteId: site.id, ownerId: userId } });
    if (!asset) return res.status(404).json({ error: "media_not_found" });
    await prisma.siteMediaAsset.update({
      where: { id: asset.id },
      data: { deletedAt: new Date(), processingStatus: "DELETED", publicStatus: "UNPUBLISHED" },
    });
    console.info("SITE_IMAGE_REMOVED", { siteId: site.id, assetId: asset.id, status: "deleted" });
    res.status(204).end();
  });

  router.get("/:domain", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const site = await findOrCreateSite(userId, domain);
    res.json(toDTO(site));
  });

  router.put("/:domain", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = sitePatchSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const existing = await findOrCreateSite(userId, domain);
    const mode = parsed.data.mode ?? (existing.mode as SiteMode);
    const title = parsed.data.title ?? existing.title;
    const description = parsed.data.description ?? existing.description;
    const blocks = parsed.data.blocks ?? parseBlocks(existing.blocksJson);
    const html = parsed.data.html ?? existing.html;
    const aiPrompt = parsed.data.aiPrompt ?? existing.aiPrompt;

    const site = await prisma.site.update({
      where: { id: existing.id },
      data: {
        title,
        description,
        mode,
        html,
        blocksJson: JSON.stringify(blocks),
        aiPrompt,
      },
    });

    res.json(toDTO(site));
  });

  router.post("/:domain/publish", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = publishSchema.safeParse(req.body ?? {});
    if (!parsed.success) return res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
    const site = await findOrCreateSite(userId, domain);
    console.info("SITE_PUBLISH_REQUEST_SENT", { siteId: site.id, slug: site.slug || slugFromDomain(site.domain), status: "requested" });
    console.info("SITE_PUBLISH_VALIDATION_STARTED", { siteId: site.id, status: "started" });
    const blocks = parseBlocks(site.blocksJson);
    const validation = validatePublishable(site.title, site.mode as SiteMode, site.html, blocks);
    if (validation) {
      console.error("SITE_PUBLISH_FAILED", { siteId: site.id, status: "failed", failureCode: "site_not_ready" });
      res.status(400).json({ error: "site_not_ready", message: validation });
      return;
    }
    const assets = await prisma.siteMediaAsset.findMany({ where: { siteId: site.id, deletedAt: null } });
    const referencedAssetIds = referencedMediaAssetIds(blocks, site.html);
    const assetById = new Map(assets.map((asset) => [asset.id, asset]));
    const missingAssets = [...referencedAssetIds].filter((assetId) => !assetById.has(assetId));
    if (missingAssets.length > 0) {
      console.error("SITE_PUBLISH_FAILED", { siteId: site.id, status: "failed", failureCode: "assets_missing", count: missingAssets.length });
      res.status(400).json({ error: "assets_missing", message: "This Site references media that is missing from its media library." });
      return;
    }
    const failedAssets = assets.filter((asset) => referencedAssetIds.has(asset.id) && (asset.uploadStatus !== "UPLOADED" || asset.processingStatus !== "READY"));
    if (failedAssets.length > 0) {
      console.error("SITE_PUBLISH_FAILED", { siteId: site.id, status: "failed", failureCode: "assets_not_ready" });
      res.status(400).json({ error: "assets_not_ready", message: "One or more images or videos are still uploading, processing, or failed. Retry after the media library is ready." });
      return;
    }
    console.info("SITE_PUBLICATION_MEDIA_VALIDATED", { siteId: site.id, count: referencedAssetIds.size, stage: "media_ready" });

    const publishedHtml = renderPublishedHtml(site);
    const versionNumber = await nextPublicationVersion(site.id);
    const slug = site.slug || slugFromDomain(site.domain);
    const publicAddress = `oneway://${slug}`;
    const publicWebAddress = `https://sites.oneway.app/${slug}`;
    const contentManifest = {
      siteId: site.id,
      domain: site.domain,
      slug,
      publicAddress,
      publicWebAddress,
      title: site.title,
      description: site.description,
      html: publishedHtml,
      blocks,
      navigation: navigationForBlocks(site),
      homepage: "home",
      visibility: parsed.data.visibility,
      publishedAt: new Date().toISOString(),
      cacheVersion: `${versionNumber}-${Date.now()}`,
    };
    const assetManifest = {
      assetIds: [...referencedAssetIds],
      variants: assets.filter((asset) => referencedAssetIds.has(asset.id)).map((asset) => toMediaDTO(asset)),
    };
    const manifestValidation = validatePublicationManifest(contentManifest, assetManifest);
    if (manifestValidation) {
      console.error("SITE_PUBLISH_FAILED", { siteId: site.id, status: "failed", failureCode: "manifest_invalid" });
      res.status(400).json({ error: "publication_manifest_invalid", message: manifestValidation });
      return;
    }
    console.info("SITE_PUBLICATION_MANIFEST_CREATED", { siteId: site.id, version: versionNumber, stage: "manifest_ready" });

    console.info("SITE_PUBLISH_BUILD_STARTED", { siteId: site.id, version: versionNumber, status: "building" });
    const publication = await prisma.sitePublication.create({
      data: {
        siteId: site.id,
        versionNumber,
        status: "BUILT",
        publishedBy: userId,
        publishedAt: new Date(),
        sourceDraftVersion: Number((site as any).draftVersion ?? 1),
        contentManifest: JSON.stringify(contentManifest),
        assetManifest: JSON.stringify(assetManifest),
        publicAddress,
        buildStartedAt: new Date(),
        buildCompletedAt: new Date(),
      },
    });
    const verified = verifyPublicRouteCandidate(site, publication, contentManifest, assetManifest);
    if (!verified.ok) {
      await prisma.sitePublication.update({
        where: { id: publication.id },
        data: { status: "FAILED", failureCode: verified.failureCode, failureMessage: verified.message },
      });
      await prisma.site.update({ where: { id: site.id }, data: { status: "PUBLISH_FAILED" } });
      console.error("SITE_PUBLISH_FAILED", { siteId: site.id, publicationId: publication.id, failureCode: verified.failureCode, stage: "route_verification" });
      res.status(400).json({ error: verified.failureCode, message: verified.message });
      return;
    }
    console.info("SITE_PUBLIC_ROUTE_VERIFICATION_STARTED", { siteId: site.id, publicationId: publication.id, version: versionNumber, slug });
    console.info("SITE_PUBLICATION_ROUTE_VERIFIED", { siteId: site.id, publicationId: publication.id, version: versionNumber, stage: "public_resolver_candidate" });
    console.info("SITE_QUANTUM_FETCH_VERIFIED", { siteId: site.id, publicationId: publication.id, version: versionNumber, stage: "quantum_manifest_candidate" });
    const activated = await prisma.$transaction(async (tx) => {
      await tx.sitePublication.updateMany({
        where: { siteId: site.id, status: "ACTIVE" },
        data: { status: "SUPERSEDED" },
      });
      const pub = await tx.sitePublication.update({
        where: { id: publication.id },
        data: {
          status: "ACTIVE",
          publishedAt: new Date(),
          failureCode: null,
          failureMessage: null,
        },
      });
      const activePublicationId = pub.id;
      const next = await tx.site.update({
        where: { id: site.id },
        data: {
          publishedHtml,
          publishedAt: new Date(),
          slug,
          publicAddress,
          visibility: parsed.data.visibility,
          status: "PUBLISHED",
          activePublicationId,
        },
      });
      await tx.siteMediaAsset.updateMany({
        where: { siteId: site.id, id: { in: [...referencedAssetIds] } },
        data: { publicStatus: "PUBLISHED" },
      });
      return { pub, site: next };
    });
    console.info("SITE_PUBLICATION_ROUTE_ACTIVATED", { siteId: site.id, publicationId: activated.pub.id, version: versionNumber, status: "active" });
    console.info("SITE_PUBLICATION_ACTIVATED", { siteId: site.id, publicationId: activated.pub.id, version: versionNumber, status: "active" });
    console.info("SITE_PUBLIC_ROUTE_VERIFICATION_SUCCEEDED", { siteId: site.id, publicationId: activated.pub.id, version: versionNumber, slug });
    console.info("SITE_PUBLISH_SUCCEEDED", { siteId: site.id, publicationId: activated.pub.id, version: versionNumber, status: "published" });
    res.json({
      site: toDTO(activated.site),
      publication: toPublicationDTO(activated.pub),
      publicAddress,
      publicWebAddress,
      siteStatus: "PUBLISHED",
      publicationStatus: "ACTIVE",
      activePublicationId: activated.pub.id,
      routeVerified: true,
      publishedAt: activated.site.publishedAt?.toISOString() ?? null,
      warnings: [],
    });
  });

  router.post("/:domain/unpublish", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOwnedSite(userId, domain);
    if (!site) return res.status(404).json({ error: "site_not_found" });
    const next = await prisma.site.update({
      where: { id: site.id },
      data: { status: "UNPUBLISHED", publishedAt: null, publishedHtml: "", activePublicationId: null },
    });
    await prisma.siteMediaAsset.updateMany({ where: { siteId: site.id }, data: { publicStatus: "UNPUBLISHED" } });
    console.info("SITE_UNPUBLISHED", { siteId: site.id, status: "unpublished" });
    res.json({ site: toDTO(next) });
  });

  router.post("/:domain/pause", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOwnedSite(userId, domain);
    if (!site) return res.status(404).json({ error: "site_not_found" });
    const next = await prisma.site.update({ where: { id: site.id }, data: { status: "PAUSED" } });
    console.info("SITE_PAUSED", { siteId: site.id, status: "paused" });
    res.json({ site: toDTO(next) });
  });

  router.get("/:domain/publications", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOwnedSite(userId, domain);
    if (!site) return res.status(404).json({ error: "site_not_found" });
    const publications = await prisma.sitePublication.findMany({ where: { siteId: site.id }, orderBy: { versionNumber: "desc" } });
    res.json({ publications: publications.map(toPublicationDTO) });
  });

  router.post("/:domain/publications/:publicationId/restore", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOwnedSite(userId, domain);
    if (!site) return res.status(404).json({ error: "site_not_found" });
    const source = await prisma.sitePublication.findFirst({ where: { id: String(req.params.publicationId), siteId: site.id } });
    if (!source) return res.status(404).json({ error: "publication_not_found" });
    const manifest = parseJsonObject(source.contentManifest);
    const restoredHtml = String(manifest.html ?? site.publishedHtml ?? "");
    const versionNumber = await nextPublicationVersion(site.id);
    const restored = await prisma.sitePublication.create({
      data: {
        siteId: site.id,
        versionNumber,
        status: "ACTIVE",
        publishedBy: userId,
        publishedAt: new Date(),
        sourceDraftVersion: Number((site as any).draftVersion ?? 1),
        contentManifest: source.contentManifest,
        assetManifest: source.assetManifest,
        publicAddress: source.publicAddress,
        buildStartedAt: new Date(),
        buildCompletedAt: new Date(),
      },
    });
    const next = await prisma.site.update({
      where: { id: site.id },
      data: { publishedHtml: restoredHtml, publishedAt: new Date(), activePublicationId: restored.id, status: "PUBLISHED" },
    });
    res.json({ site: toDTO(next), publication: toPublicationDTO(restored) });
  });

  router.post("/:domain/publication/reconcile", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) return res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
    const site = await findOwnedSite(userId, domain);
    if (!site) return res.status(404).json({ error: "site_not_found" });

    const previousState = {
      siteId: site.id,
      slug: site.slug ?? slugFromDomain(site.domain),
      status: site.status,
      activePublicationId: site.activePublicationId,
      publishedAt: site.publishedAt?.toISOString() ?? null,
    };
    console.info("SITE_PUBLICATION_RECONCILE_STARTED", previousState);
    const repaired = await reconcileSitePublication(site, userId, "owner_reconcile");
    const resolved = await resolvePublicSitePublication(site.slug ?? slugFromDomain(site.domain), site.domain);
    if (!resolved.ok) {
      console.error("SITE_PUBLICATION_RECONCILE_FAILED", { siteId: site.id, failureCode: resolved.code, stage: resolved.stage });
      return res.status(409).json({
        previousState,
        detectedProblems: repaired.detectedProblems,
        actionsTaken: repaired.actionsTaken,
        resultingState: repaired.resultingState,
        routeVerified: false,
        error: resolved.code,
        message: resolved.message,
      });
    }
    console.info("SITE_PUBLICATION_RECONCILE_SUCCEEDED", { siteId: resolved.site.id, publicationId: resolved.publication.id, slug: resolved.site.slug });
    res.json({
      previousState,
      detectedProblems: repaired.detectedProblems,
      actionsTaken: repaired.actionsTaken,
      resultingState: {
        siteId: resolved.site.id,
        slug: resolved.site.slug ?? slugFromDomain(resolved.site.domain),
        siteStatus: resolved.site.status,
        activePublicationId: resolved.site.activePublicationId,
        publicationId: resolved.publication.id,
        publicationStatus: resolved.publication.status,
      },
      routeVerified: true,
      publicURL: `https://sites.oneway.app/${resolved.site.slug ?? slugFromDomain(resolved.site.domain)}`,
      site: toDTO(resolved.site),
      publication: toPublicationDTO(resolved.publication),
    });
  });

  router.post("/:siteId/publication/reconcile-by-id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const siteId = String(req.params.siteId ?? "").trim();
    if (!siteId) return res.status(400).json({ error: "invalid_site_id" });

    const site = await prisma.site.findUnique({ where: { id: siteId } });
    if (!site) return res.status(404).json({ error: "site_not_found" });
    if (site.userId !== userId) return res.status(403).json({ error: "site_access_denied" });

    const previousState = {
      siteId: site.id,
      slug: site.slug ?? slugFromDomain(site.domain),
      status: site.status,
      activePublicationId: site.activePublicationId,
      publishedAt: site.publishedAt?.toISOString() ?? null,
    };
    console.info("SITE_PUBLICATION_RECONCILE_BY_ID_STARTED", previousState);
    const repaired = await reconcileSitePublication(site, userId, "owner_reconcile_by_id");
    const health = await publicationHealth(site.id);
    if (!health.routeVerified) {
      console.error("SITE_PUBLICATION_RECONCILE_BY_ID_FAILED", { siteId: site.id, detectedProblems: health.detectedProblems });
      return res.status(409).json({
        previousState,
        detectedProblems: [...repaired.detectedProblems, ...health.detectedProblems],
        actionsTaken: repaired.actionsTaken,
        resultingState: repaired.resultingState,
        routeVerified: false,
        health,
      });
    }
    console.info("SITE_PUBLICATION_RECONCILE_BY_ID_SUCCEEDED", { siteId: site.id, activePublicationId: health.activePublicationId, slug: health.canonicalSlug });
    res.json({
      previousState,
      detectedProblems: repaired.detectedProblems,
      actionsTaken: repaired.actionsTaken,
      resultingState: repaired.resultingState,
      routeVerified: true,
      publicURL: `https://sites.oneway.app/${health.canonicalSlug}`,
      health,
    });
  });

  router.post("/:domain/assets", siteImageUpload.single("image"), async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    if (!req.file) {
      res.status(400).json({ error: "image_required", message: "Choose an image before uploading." });
      return;
    }

    try {
      await findOrCreateSite(userId, domain);
      const extension = extensionForMimeType(req.file.mimetype);
      const safeName = safeFileName(req.file.originalname, extension);
      const filename = `${randomUUID()}-${safeName}`;
      const storageKey = `sites/${safeSegment(userId)}/${domain}/${filename}`;
      const url = s3
        ? await uploadSiteAssetToObjectStorage(s3, storageKey, req.file.buffer, req.file.mimetype)
        : await saveSiteAssetLocally(req, storageKey, req.file.buffer);

      res.status(201).json({
        url,
        path: storageKey,
        mimeType: req.file.mimetype,
        byteCount: req.file.size,
      });
    } catch (error) {
      res.status(500).json({
        error: "site_asset_upload_failed",
        message: error instanceof Error ? error.message : "Image upload failed.",
      });
    }
  });

  router.post("/:domain/generate-ai", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const domain = normalizeDomain(String(req.params.domain ?? ""));
    if (!domain) {
      res.status(400).json({ error: "invalid_domain", message: "Enter a valid OneWay domain." });
      return;
    }

    const parsed = aiGenerateSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const existing = await findOrCreateSite(userId, domain);
    const title = parsed.data.title || existing.title || titleFromPrompt(parsed.data.prompt);
    const description = parsed.data.description || existing.description || descriptionFromPrompt(parsed.data.prompt);
    const generated = generateDeterministicSiteBlocks({
      domain,
      title,
      description,
      prompt: parsed.data.prompt,
    });

    const site = await prisma.site.update({
      where: { id: existing.id },
      data: {
        title: generated.title,
        description: generated.description,
        mode: "ai",
        html: "",
        blocksJson: JSON.stringify(generated.blocks),
        aiPrompt: parsed.data.prompt,
      },
    });

    res.json({
      html: "",
      site: toDTO(site),
    });
  });

  router.use((error: unknown, _req: express.Request, res: express.Response, next: express.NextFunction) => {
    if (error instanceof multer.MulterError) {
      if (error.code === "LIMIT_FILE_SIZE") {
        res.status(400).json({ error: "file_too_large", message: "Images must be 5MB or smaller." });
        return;
      }
      res.status(400).json({ error: "invalid_upload", message: "Only jpg, png, and webp images are supported." });
      return;
    }
    next(error);
  });

  return router;
}

function normalizeDomain(input: string | undefined): string | null {
  const raw = String(input ?? "")
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

async function ensureDevSites(userId: string): Promise<void> {
  if (process.env.NODE_ENV === "production") return;

  for (const domain of DEV_DOMAINS) {
    await prisma.site.upsert({
      where: { userId_domain: { userId, domain } },
      update: {},
      create: defaultSiteData(userId, domain),
    });
  }
}

async function findOrCreateSite(userId: string, domain: string) {
  const existing = await prisma.site.findUnique({
    where: { userId_domain: { userId, domain } },
  });
  if (existing) return existing;

  return prisma.site.create({
    data: defaultSiteData(userId, domain),
  });
}

async function findOwnedSite(userId: string, domain: string) {
  return prisma.site.findUnique({ where: { userId_domain: { userId, domain } } });
}

type PublicResolution =
  | { ok: true; site: any; publication: any }
  | { ok: false; code: string; message: string; stage: string };

async function publicationHealth(siteId: string) {
  const site = await prisma.site.findUnique({ where: { id: siteId } });
  if (!site) {
    return {
      siteExists: false,
      siteStatus: null,
      canonicalSlug: null,
      activePublicationIdPresent: false,
      activePublicationId: null,
      activePublicationExists: false,
      activePublicationStatus: null,
      manifestPresent: false,
      homepagePresent: false,
      resolverStatus: 404,
      routeVerified: false,
      environment: process.env.NODE_ENV ?? "development",
      buildIdentifier: process.env.ONEWAY_BUILD_IDENTIFIER ?? process.env.SOURCE_VERSION ?? "local",
      detectedProblems: ["SITE_RECORD_MISSING"],
    };
  }

  const slug = site.slug ?? slugFromDomain(site.domain);
  const activePublication = site.activePublicationId
    ? await prisma.sitePublication.findFirst({ where: { id: site.activePublicationId, siteId: site.id } })
    : null;
  const manifest = activePublication ? parseJsonObject(activePublication.contentManifest) : {};
  const summary = publicManifestSummary(manifest);
  const detectedProblems: string[] = [];

  if (site.status !== "PUBLISHED") detectedProblems.push("STATUS_DRAFT");
  if (!site.activePublicationId) detectedProblems.push("ACTIVE_PUBLICATION_ID_MISSING");
  if (site.activePublicationId && !activePublication) detectedProblems.push("ACTIVE_PUBLICATION_RECORD_MISSING");
  if (activePublication && activePublication.status !== "ACTIVE") detectedProblems.push("PUBLICATION_NOT_ACTIVE");
  if (activePublication && activePublication.siteId !== site.id) detectedProblems.push("PUBLICATION_BELONGS_TO_DIFFERENT_SITE");
  if (activePublication && Object.keys(manifest).length === 0) detectedProblems.push("MANIFEST_MISSING");
  if (activePublication && !summary.homepagePresent) detectedProblems.push("HOMEPAGE_MISSING");

  const resolverStatus = detectedProblems.length === 0 ? 200 : 409;
  return {
    siteExists: true,
    siteId: site.id,
    siteStatus: site.status,
    canonicalSlug: slug,
    activePublicationIdPresent: Boolean(site.activePublicationId),
    activePublicationId: site.activePublicationId,
    activePublicationExists: Boolean(activePublication),
    activePublicationStatus: activePublication?.status ?? null,
    publicationVersion: activePublication?.versionNumber ?? null,
    manifestPresent: Object.keys(manifest).length > 0,
    homepagePresent: summary.homepagePresent,
    resolverStatus,
    routeVerified: resolverStatus === 200,
    environment: process.env.NODE_ENV ?? "development",
    buildIdentifier: process.env.ONEWAY_BUILD_IDENTIFIER ?? process.env.SOURCE_VERSION ?? "local",
    detectedProblems,
  };
}

async function resolvePublicSitePublication(slug: string, domain?: string | null): Promise<PublicResolution> {
  const normalizedSlug = slugFromDomain(slug);
  const normalizedDomain = domain ?? `${normalizedSlug}.oneway.app`;
  const site = await prisma.site.findFirst({
    where: {
      OR: [
        { slug: normalizedSlug },
        { domain: normalizedDomain },
        { domain: `${normalizedSlug}.oneway.app` },
        { domain: `${normalizedSlug}.oneway.site` },
      ],
    },
  });

  if (!site) {
    return { ok: false, code: "SITE_NOT_FOUND", message: "This Site is not available on the OneWay Internet.", stage: "site_lookup" };
  }
  if (site.status === "ARCHIVED") return { ok: false, code: "SITE_ARCHIVED", message: "This Site has been archived.", stage: "site_status" };
  if (site.status === "PAUSED") return { ok: false, code: "SITE_PAUSED", message: "This Site is paused.", stage: "site_status" };
  if (site.status === "UNPUBLISHED") return { ok: false, code: "SITE_UNPUBLISHED", message: "This Site has been unpublished.", stage: "site_status" };
  if (site.status === "PUBLISHING") return { ok: false, code: "SITE_PUBLISHING", message: "This Site is still publishing.", stage: "site_status" };
  if (!["PUBLIC", "UNLISTED"].includes(site.visibility ?? "PUBLIC")) {
    return { ok: false, code: "SITE_PRIVATE", message: "This Site is private.", stage: "visibility" };
  }

  if (site.activePublicationId) {
    const publication = await prisma.sitePublication.findFirst({
      where: { id: site.activePublicationId, siteId: site.id, status: "ACTIVE" },
    });
    if (publication) return { ok: true, site, publication };
    if (site.status === "PUBLISHED") {
      console.error("PUBLICATION_STATE_INVALID", { siteId: site.id, slug: normalizedSlug, activePublicationId: site.activePublicationId });
    }
  }

  if (site.status === "PUBLISHED") {
    const repaired = await reconcileSitePublication(site, site.userId, "public_resolver_repair");
    if (repaired.resultingState.activePublicationId) {
      const next = await prisma.site.findUnique({ where: { id: site.id } });
      const publication = next?.activePublicationId
        ? await prisma.sitePublication.findFirst({ where: { id: next.activePublicationId, siteId: site.id, status: "ACTIVE" } })
        : null;
      if (next && publication) return { ok: true, site: next, publication };
    }
    return { ok: false, code: "PUBLICATION_UNAVAILABLE", message: "This Site publication is temporarily unavailable.", stage: "publication_reconcile" };
  }

  return { ok: false, code: "SITE_NOT_PUBLISHED", message: "This OneWay Site is not published yet.", stage: "publication_lookup" };
}

async function reconcileSitePublication(site: any, actorUserId: string, reason: string) {
  const detectedProblems: string[] = [];
  const actionsTaken: string[] = [];
  const slug = site.slug || slugFromDomain(site.domain);

  const activePublications = await prisma.sitePublication.findMany({
    where: { siteId: site.id, status: "ACTIVE" },
    orderBy: { versionNumber: "desc" },
  });
  if (activePublications.length > 1) {
    detectedProblems.push("MULTIPLE_ACTIVE_PUBLICATIONS");
    const [winner, ...rest] = activePublications;
    await prisma.sitePublication.updateMany({
      where: { id: { in: rest.map((publication) => publication.id) } },
      data: { status: "SUPERSEDED" },
    });
    await prisma.site.update({
      where: { id: site.id },
      data: { activePublicationId: winner.id, status: "PUBLISHED", slug, publicAddress: `oneway://${slug}`, publishedAt: winner.publishedAt ?? new Date() },
    });
    actionsTaken.push("SUPERSEDED_DUPLICATE_ACTIVE_PUBLICATIONS");
  }

  const refreshed = await prisma.site.findUnique({ where: { id: site.id } });
  if (!refreshed) {
    return { detectedProblems: ["SITE_MISSING"], actionsTaken, resultingState: { activePublicationId: null } };
  }

  if (refreshed.activePublicationId) {
    const active = await prisma.sitePublication.findFirst({ where: { id: refreshed.activePublicationId, siteId: refreshed.id, status: "ACTIVE" } });
    if (active && publicationHasRenderableManifest(active)) {
      return {
        detectedProblems,
        actionsTaken,
        resultingState: { siteStatus: refreshed.status, activePublicationId: active.id, publicationStatus: active.status },
      };
    }
    detectedProblems.push("ACTIVE_PUBLICATION_INVALID");
  } else if (refreshed.status === "PUBLISHED") {
    detectedProblems.push("PUBLISHED_WITHOUT_ACTIVE_PUBLICATION");
  }

  const reusable = await prisma.sitePublication.findFirst({
    where: { siteId: refreshed.id, status: { in: ["ACTIVE", "READY", "BUILT", "SUPERSEDED"] } },
    orderBy: { versionNumber: "desc" },
  });
  if (reusable && publicationHasRenderableManifest(reusable)) {
    await prisma.$transaction(async (tx) => {
      await tx.sitePublication.updateMany({ where: { siteId: refreshed.id, status: "ACTIVE" }, data: { status: "SUPERSEDED" } });
      await tx.sitePublication.update({ where: { id: reusable.id }, data: { status: "ACTIVE", failureCode: null, failureMessage: null, publishedAt: reusable.publishedAt ?? new Date() } });
      await tx.site.update({
        where: { id: refreshed.id },
        data: { status: "PUBLISHED", activePublicationId: reusable.id, slug, publicAddress: `oneway://${slug}`, publishedAt: refreshed.publishedAt ?? reusable.publishedAt ?? new Date() },
      });
    });
    actionsTaken.push("ACTIVATED_EXISTING_PUBLICATION");
    return { detectedProblems, actionsTaken, resultingState: { siteStatus: "PUBLISHED", activePublicationId: reusable.id, publicationStatus: "ACTIVE" } };
  }

  const built = await createPublicationFromSite(refreshed, actorUserId, reason);
  actionsTaken.push("BUILT_NEW_PUBLICATION_FROM_DRAFT");
  return { detectedProblems, actionsTaken, resultingState: { siteStatus: "PUBLISHED", activePublicationId: built.publication.id, publicationStatus: "ACTIVE" } };
}

async function createPublicationFromSite(site: any, actorUserId: string, reason: string) {
  const blocks = parseBlocks(site.blocksJson);
  const validation = validatePublishable(site.title, site.mode as SiteMode, site.html, blocks);
  if (validation) throw new Error(validation);
  const assets = await prisma.siteMediaAsset.findMany({ where: { siteId: site.id, deletedAt: null } });
  const referencedAssetIds = referencedMediaAssetIds(blocks, site.html);
  const readyAssets = assets.filter((asset) => referencedAssetIds.has(asset.id) && asset.uploadStatus === "UPLOADED" && asset.processingStatus === "READY");
  const publishedHtml = renderPublishedHtml(site);
  const versionNumber = await nextPublicationVersion(site.id);
  const slug = site.slug || slugFromDomain(site.domain);
  const publicAddress = `oneway://${slug}`;
  const publicWebAddress = `https://sites.oneway.app/${slug}`;
  const contentManifest = {
    siteId: site.id,
    domain: site.domain,
    slug,
    publicAddress,
    publicWebAddress,
    title: site.title,
    description: site.description,
    html: publishedHtml,
    blocks,
    navigation: navigationForBlocks(site),
    homepage: "home",
    visibility: site.visibility ?? "PUBLIC",
    publishedAt: new Date().toISOString(),
    cacheVersion: `${versionNumber}-${Date.now()}`,
    reconciliationReason: reason,
  };
  const assetManifest = {
    assetIds: readyAssets.map((asset) => asset.id),
    variants: readyAssets.map((asset) => toMediaDTO(asset)),
  };
  const manifestValidation = validatePublicationManifest(contentManifest, assetManifest);
  if (manifestValidation) throw new Error(manifestValidation);
  const publication = await prisma.sitePublication.create({
    data: {
      siteId: site.id,
      versionNumber,
      status: "READY",
      publishedBy: actorUserId,
      publishedAt: new Date(),
      sourceDraftVersion: Number(site.draftVersion ?? 1),
      contentManifest: JSON.stringify(contentManifest),
      assetManifest: JSON.stringify(assetManifest),
      publicAddress,
      buildStartedAt: new Date(),
      buildCompletedAt: new Date(),
    },
  });
  const activated = await prisma.$transaction(async (tx) => {
    await tx.sitePublication.updateMany({ where: { siteId: site.id, status: "ACTIVE" }, data: { status: "SUPERSEDED" } });
    const pub = await tx.sitePublication.update({ where: { id: publication.id }, data: { status: "ACTIVE" } });
    const next = await tx.site.update({
      where: { id: site.id },
      data: { status: "PUBLISHED", activePublicationId: pub.id, publishedHtml, publishedAt: new Date(), slug, publicAddress, visibility: site.visibility ?? "PUBLIC" },
    });
    return { site: next, publication: pub };
  });
  console.info("SITE_PUBLICATION_RECORD_CREATED", { siteId: site.id, publicationId: activated.publication.id, version: versionNumber, reason });
  console.info("SITE_PUBLICATION_ACTIVATED", { siteId: site.id, publicationId: activated.publication.id, version: versionNumber, reason });
  return activated;
}

function publicationHasRenderableManifest(publication: { contentManifest: string }): boolean {
  const manifest = parseJsonObject(publication.contentManifest);
  return Boolean(String(manifest.html ?? "").trim() || Array.isArray(manifest.blocks));
}

async function nextPublicationVersion(siteId: string): Promise<number> {
  const latest = await prisma.sitePublication.findFirst({
    where: { siteId },
    orderBy: { versionNumber: "desc" },
  });
  return (latest?.versionNumber ?? 0) + 1;
}

function defaultSiteData(userId: string, domain: string) {
  const slug = domain.replace(/\.oneway\.app$/, "");
  const title = slug === "mira" ? "Mira Studio" : "My OneWay Site";
  const description = slug === "mira"
    ? "A simple published OneWay site you can customize."
    : "A clean landing page hosted on OneWay.";
  const blocks = [
    { type: "hero", title, subtitle: description },
    { type: "text", text: "Tell customers what you do, what makes you different, and how to reach you." },
    {
      type: "services",
      title: "What we offer",
      items: [
        { title: "Fast answers", detail: "Give visitors a clear way to ask questions, book, or buy." },
        { title: "Simple updates", detail: "Keep hours, photos, and contact details fresh from OneWay." },
      ],
    },
    {
      type: "faq",
      title: "Good to know",
      items: [
        { question: "How do people reach us?", answer: "Add your OneWay number, email, or booking link." },
      ],
    },
    { type: "callText", label: "Call or text us", phoneNumber: "" },
  ];

  return {
    userId,
    domain,
    title,
    description,
    mode: "nocode",
    html: "",
    blocksJson: JSON.stringify(blocks),
    aiPrompt: "",
    publishedHtml: "",
    slug,
    publicAddress: `oneway://${slug}`,
    visibility: "PUBLIC",
    status: "DRAFT",
  };
}

function toDTO(site: {
  id: string;
  userId: string;
  domain: string;
  title: string;
  description: string;
  mode: string;
  html: string;
  blocksJson: string;
  aiPrompt: string;
	  publishedHtml: string;
	  publishedAt: Date | null;
	  slug?: string | null;
	  publicAddress?: string | null;
	  visibility?: string;
	  status?: string;
	  activePublicationId?: string | null;
	  draftVersion?: number;
	  createdAt: Date;
	  updatedAt: Date;
	}): SiteDTO {
  return {
    id: site.id,
    userId: site.userId,
    domain: site.domain,
    title: site.title,
    description: site.description,
    mode: SITE_MODES.includes(site.mode as SiteMode) ? site.mode as SiteMode : "nocode",
    html: site.html,
    blocks: parseBlocks(site.blocksJson),
    aiPrompt: site.aiPrompt,
	    publishedHtml: site.publishedHtml,
	    publishedAt: site.publishedAt ? site.publishedAt.toISOString() : null,
	    published: Boolean((site.status ?? "DRAFT") === "PUBLISHED" && site.publishedAt && site.publishedHtml.trim()),
	    createdAt: site.createdAt.toISOString(),
	    updatedAt: site.updatedAt.toISOString(),
	  };
}

function toPublicDTO(site: {
  id: string;
  userId: string;
  domain: string;
  title: string;
  description: string;
  mode: string;
	  publishedHtml: string;
	  publishedAt: Date | null;
	  status?: string;
	  createdAt: Date;
	  updatedAt: Date;
	}): SiteDTO {
  return {
    id: site.id,
    userId: "public",
    domain: site.domain,
    title: site.title,
    description: site.description,
    mode: SITE_MODES.includes(site.mode as SiteMode) ? site.mode as SiteMode : "nocode",
    html: "",
    blocks: [],
    aiPrompt: "",
    publishedHtml: site.publishedHtml,
    publishedAt: site.publishedAt ? site.publishedAt.toISOString() : null,
	    published: Boolean((site.status ?? "DRAFT") === "PUBLISHED" && site.publishedAt && site.publishedHtml.trim()),
	    createdAt: site.createdAt.toISOString(),
	    updatedAt: site.updatedAt.toISOString(),
	  };
		}

function toResolvedPublicDTO(site: {
  id: string;
  userId: string;
  domain: string;
  title: string;
  description: string;
  mode: string;
  publishedHtml: string;
  publishedAt: Date | null;
  slug?: string | null;
  publicAddress?: string | null;
  visibility?: string;
  status?: string;
  activePublicationId?: string | null;
  createdAt: Date;
  updatedAt: Date;
}, publication: {
  id: string;
  versionNumber: number;
  status: string;
  contentManifest: string;
  assetManifest: string;
  publicAddress: string;
  publishedAt: Date | null;
}) {
  const manifest = parseJsonObject(publication.contentManifest);
  const html = String(manifest.html ?? site.publishedHtml ?? "");
  const slug = site.slug ?? slugFromDomain(site.domain);
  const summary = publicManifestSummary(manifest);
  return {
    ...toPublicDTO(site),
    siteId: site.id,
    canonicalSlug: slug,
    siteStatus: site.status ?? "PUBLISHED",
    activePublicationId: site.activePublicationId ?? publication.id,
    publicationId: publication.id,
    activePublication: {
      id: publication.id,
      status: publication.status,
      version: publication.versionNumber,
      publishedAt: publication.publishedAt?.toISOString() ?? null,
    },
    publicationStatus: publication.status,
    publicationVersion: publication.versionNumber,
    version: publication.versionNumber,
    slug,
    address: site.publicAddress ?? publication.publicAddress,
    publicURL: `https://sites.oneway.app/${slug}`,
    routeVerified: publication.status === "ACTIVE" && (site.status ?? "PUBLISHED") === "PUBLISHED",
    visibility: site.visibility ?? "PUBLIC",
    html,
    publishedHtml: html,
    publishedAt: publication.publishedAt?.toISOString() ?? site.publishedAt?.toISOString() ?? null,
    homepage: summary.homepage,
    pages: summary.pages,
    sections: summary.sections,
    components: summary.components,
    manifest,
    assets: parseJsonObject(publication.assetManifest),
  };
}

function publicManifestSummary(manifest: Record<string, unknown>) {
  const rawPages = Array.isArray(manifest.pages) ? manifest.pages : [];
  const rawBlocks = Array.isArray(manifest.blocks) ? manifest.blocks : [];
  const pages = rawPages.length > 0
    ? rawPages
    : [{
        id: "home",
        slug: "/",
        title: "Home",
        sections: rawBlocks,
      }];
  const homepage = pages[0] ?? null;
  const sections = pages.flatMap((page) => {
    if (!page || typeof page !== "object") return [];
    const object = page as Record<string, unknown>;
    return Array.isArray(object.sections) ? object.sections : [];
  });
  const components = sections.flatMap((section) => {
    if (!section || typeof section !== "object") return [];
    const object = section as Record<string, unknown>;
    if (Array.isArray(object.components)) return object.components;
    return [object];
  });
  const html = String(manifest.html ?? "").trim();
  return {
    homepage,
    pages,
    sections,
    components,
    homepagePresent: Boolean(homepage) && (sections.length > 0 || rawBlocks.length > 0 || html.length > 0),
  };
}
	
function toMediaDTO(asset: {
  id: string;
  siteId: string;
  ownerId: string;
  mediaType?: string;
  storageKey: string;
  originalStorageKey?: string | null;
  processedStorageKey?: string | null;
  thumbnailStorageKey?: string | null;
  playbackManifestKey?: string | null;
  originalFileName: string;
  mimeType: string;
  sourceMimeType?: string | null;
  outputMimeType?: string | null;
  width: number | null;
  height: number | null;
  durationMilliseconds?: number | null;
  fileSizeBytes: number;
  processingStatus: string;
  uploadStatus?: string;
  publicStatus: string;
  failureCode?: string | null;
  failureMessage?: string | null;
  altText: string;
  caption: string;
  focalPointX: number;
  focalPointY: number;
  variantsJson: string;
  usageCount: number;
  createdAt: Date;
  updatedAt: Date;
}, publicUrl?: string) {
  const variants = parseJsonObject(asset.variantsJson);
  return {
    id: asset.id,
    siteId: asset.siteId,
    mediaType: asset.mediaType ?? mediaTypeForMimeType(asset.mimeType),
    originalFileName: asset.originalFileName,
    mimeType: asset.mimeType,
    sourceMimeType: asset.sourceMimeType ?? asset.mimeType,
    outputMimeType: asset.outputMimeType ?? asset.mimeType,
    width: asset.width,
    height: asset.height,
    durationMilliseconds: asset.durationMilliseconds ?? null,
    fileSizeBytes: asset.fileSizeBytes,
    uploadStatus: asset.uploadStatus ?? "UPLOADED",
    processingStatus: asset.processingStatus,
    publicStatus: asset.publicStatus,
    failureCode: asset.failureCode ?? null,
    failureMessage: asset.failureMessage ?? null,
    altText: asset.altText,
    caption: asset.caption,
    focalPointX: asset.focalPointX,
    focalPointY: asset.focalPointY,
    usageCount: asset.usageCount,
    url: publicUrl || publicUrlFromStorageKey(asset.storageKey),
    variants,
    createdAt: asset.createdAt.toISOString(),
    updatedAt: asset.updatedAt.toISOString(),
  };
}

function toPublicationDTO(publication: {
  id: string;
  siteId: string;
  versionNumber: number;
  status: string;
  publishedBy: string;
  publishedAt: Date | null;
  sourceDraftVersion: number;
  publicAddress: string;
  buildStartedAt: Date | null;
  buildCompletedAt: Date | null;
  failureCode: string | null;
  failureMessage: string | null;
  createdAt: Date;
  updatedAt: Date;
}) {
  return {
    id: publication.id,
    siteId: publication.siteId,
    versionNumber: publication.versionNumber,
    status: publication.status,
    publishedBy: publication.publishedBy,
    publishedAt: publication.publishedAt?.toISOString() ?? null,
    sourceDraftVersion: publication.sourceDraftVersion,
    publicAddress: publication.publicAddress,
    buildStartedAt: publication.buildStartedAt?.toISOString() ?? null,
    buildCompletedAt: publication.buildCompletedAt?.toISOString() ?? null,
    failureCode: publication.failureCode,
    failureMessage: publication.failureMessage,
    createdAt: publication.createdAt.toISOString(),
    updatedAt: publication.updatedAt.toISOString(),
  };
}

function validateImageSignature(buffer: Buffer, mimeType: string): void {
  const head = buffer.subarray(0, 12);
  const hex = head.toString("hex");
  const ascii = head.toString("ascii");
  const valid =
    (mimeType === "image/jpeg" && hex.startsWith("ffd8ff"))
    || (mimeType === "image/png" && hex.startsWith("89504e470d0a1a0a"))
    || (mimeType === "image/webp" && ascii.startsWith("RIFF") && buffer.subarray(8, 12).toString("ascii") === "WEBP")
    || ((mimeType === "image/heic" || mimeType === "image/heif") && buffer.subarray(4, 12).toString("ascii").includes("ftyp"))
    || (mimeType === "image/gif" && (ascii.startsWith("GIF87a") || ascii.startsWith("GIF89a")));
  if (!valid) {
    throw new Error("The uploaded file does not match its image type.");
  }
}

function validateVideoSignature(buffer: Buffer, mimeType: string): void {
  const box = buffer.subarray(4, 12).toString("ascii");
  const valid = (mimeType === "video/mp4" || mimeType === "video/quicktime" || mimeType === "video/x-m4v") && box.includes("ftyp");
  if (!valid) {
    throw new Error("The uploaded file does not match its video type.");
  }
}

function validateMediaSignature(buffer: Buffer, mimeType: string, mediaType: "IMAGE" | "VIDEO"): void {
  if (mediaType === "VIDEO") {
    validateVideoSignature(buffer, mimeType);
    return;
  }
  validateImageSignature(buffer, mimeType);
}

function mediaTypeForMimeType(mimeType: string): "IMAGE" | "VIDEO" {
  return SITE_VIDEO_MIME_TYPES.includes(mimeType as typeof SITE_VIDEO_MIME_TYPES[number]) ? "VIDEO" : "IMAGE";
}

function mimeMatchesMediaType(mimeType: string, mediaType: "IMAGE" | "VIDEO"): boolean {
  return mediaType === "VIDEO"
    ? SITE_VIDEO_MIME_TYPES.includes(mimeType as typeof SITE_VIDEO_MIME_TYPES[number])
    : SITE_IMAGE_MIME_TYPES.includes(mimeType as typeof SITE_IMAGE_MIME_TYPES[number]);
}

function maxBytesForMediaType(mediaType: "IMAGE" | "VIDEO"): number {
  return mediaType === "VIDEO" ? MAX_SITE_VIDEO_BYTES : MAX_SITE_IMAGE_BYTES;
}

function responsiveVariants(url: string) {
  return {
    original: url,
    large: url,
    medium: url,
    small: url,
    thumbnail: url,
  };
}

function videoVariants(url: string) {
  return {
    original: url,
    playback: url,
    poster: url,
    thumbnail: url,
  };
}

function referencedMediaAssetIds(blocks: unknown[], html: string): Set<string> {
  const ids = new Set<string>();
  const visit = (value: unknown) => {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (value && typeof value === "object") {
      const object = value as Record<string, unknown>;
      if (typeof object.assetId === "string") ids.add(object.assetId);
      if (Array.isArray(object.imageAssetIDs)) {
        object.imageAssetIDs.forEach((assetId) => {
          if (typeof assetId === "string") ids.add(assetId);
        });
      }
      if (Array.isArray(object.videoAssetIDs)) {
        object.videoAssetIDs.forEach((assetId) => {
          if (typeof assetId === "string") ids.add(assetId);
        });
      }
      Object.values(object).forEach(visit);
    }
  };
  visit(blocks);
  for (const match of html.matchAll(/data-site-asset-id=["']([^"']+)["']/gi)) {
    ids.add(match[1]);
  }
  return ids;
}

function navigationForBlocks(site: { title: string; domain: string }) {
  return [{ title: site.title, slug: "home", href: `oneway://${slugFromDomain(site.domain)}` }];
}

function slugFromDomain(domain: string): string {
  return domain.replace(/\.oneway\.(app|site)$/, "").replace(/[^a-z0-9-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "site";
}

function publicUrlFromStorageKey(storageKey: string): string {
  if (storageKey.startsWith("/uploads/")) return storageKey;
  return `/uploads/${storageKey.replace(/^public\//, "")}`;
}

function parseJsonObject(raw: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function parseBlocks(raw: string): unknown[] {
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function validatePublicationManifest(contentManifest: Record<string, unknown>, assetManifest: Record<string, unknown>): string | null {
  if (!String(contentManifest.siteId ?? "").trim()) return "Publication manifest is missing a site id.";
  if (!String(contentManifest.slug ?? "").trim()) return "Publication manifest is missing its canonical slug.";
  if (!String(contentManifest.publicAddress ?? "").startsWith("oneway://")) return "Publication manifest is missing its OneWay address.";
  if (!String(contentManifest.publicWebAddress ?? "").startsWith("https://sites.oneway.app/")) return "Publication manifest is missing its web address.";
  if (!String(contentManifest.html ?? "").trim() && !Array.isArray(contentManifest.blocks)) return "Publication manifest has no renderable homepage.";
  if (!Array.isArray(assetManifest.assetIds)) return "Publication asset manifest is invalid.";
  if (!Array.isArray(assetManifest.variants)) return "Publication media variants are invalid.";
  return null;
}

function verifyPublicRouteCandidate(
  site: { id: string; title: string; description: string; domain: string; slug?: string | null; publicAddress?: string | null; visibility?: string; publishedAt?: Date | null },
  publication: { id: string; versionNumber: number; contentManifest: string; assetManifest: string; publicAddress: string; publishedAt: Date | null },
  contentManifest: Record<string, unknown>,
  assetManifest: Record<string, unknown>,
): { ok: true } | { ok: false; failureCode: string; message: string } {
  const manifestError = validatePublicationManifest(contentManifest, assetManifest);
  if (manifestError) {
    return { ok: false, failureCode: "publication_manifest_invalid", message: manifestError };
  }
  const responseManifest = parseJsonObject(publication.contentManifest);
  if (!responseManifest || typeof responseManifest !== "object") {
    return { ok: false, failureCode: "public_manifest_unreadable", message: "The public Site manifest could not be read." };
  }
  if (!String(responseManifest.html ?? "").trim() && !Array.isArray(responseManifest.blocks)) {
    return { ok: false, failureCode: "homepage_unavailable", message: "The public homepage has no renderable content." };
  }
  return { ok: true };
}

function validatePublishable(title: string, mode: SiteMode, html: string, blocks: unknown[]): string | null {
  const missing: string[] = [];
  if (!title.trim() || isGenericTitle(title)) missing.push("Add a real business or site name.");

  if (mode === "nocode" && blocks.length === 0) {
    missing.push("Add professional page sections.");
  }

  if (mode === "ai" && blocks.length > 0) {
    missing.push(...validateNoCodeBlocks(blocks));
  }

  if ((mode === "code" || (mode === "ai" && blocks.length === 0)) && !html.trim()) {
    missing.push("Add complete page content.");
  }

  if ((mode === "code" || (mode === "ai" && blocks.length === 0)) && !looksLikeHtml(html)) {
    missing.push("Add a complete responsive HTML page.");
  }

  if (mode === "nocode" && blocks.length > 0) {
    missing.push(...validateNoCodeBlocks(blocks));
  }

  if (mode === "code" || (mode === "ai" && blocks.length === 0)) {
    missing.push(...validateHtmlQuality(html));
  }

  if (missing.length === 0) return null;
  return `Your site is almost ready. Finish these items before publishing.\n• ${unique(missing).join("\n• ")}`;
}

function looksLikeHtml(html: string): boolean {
  const trimmed = html.trim().toLowerCase();
  return trimmed.includes("<html")
    || trimmed.includes("<body")
    || /<main[\s>]/.test(trimmed)
    || /<section[\s>]/.test(trimmed)
    || /<h1[\s>]/.test(trimmed);
}

function validateNoCodeBlocks(blocks: unknown[]): string[] {
  const typed = blocks
    .filter((block): block is Record<string, unknown> => Boolean(block) && typeof block === "object");
  const missing: string[] = [];
  const hasHero = typed.some((block) =>
    block.type === "hero"
    && hasSubstantialText(block.title)
    && hasSubstantialText(block.subtitle)
    && !hasPlaceholderCopy(block.title)
    && !hasPlaceholderCopy(block.subtitle)
  );
  const hasAbout = typed.some((block) => {
    if (block.type === "text" || block.type === "paragraph") {
      return hasSubstantialText(block.text) && !hasPlaceholderCopy(block.text);
    }
    if (block.type === "services") {
      return hasUsableServiceItems(block.items);
    }
    return false;
  });
  const hasContact = typed.some((block) =>
    (block.type === "contact" && (isUsableEmail(block.email) || isUsablePhone(block.phone)))
    || (block.type === "callText" && isUsablePhone(block.phoneNumber))
    || (block.type === "button" && isUsableHref(block.url))
    || (block.type === "link" && isUsableHref(block.href))
  );
  const hasOffer = typed.some((block) =>
    (block.type === "services" && hasUsableServiceItems(block.items))
    || ((block.type === "text" || block.type === "paragraph") && offerText(block.text))
  );
  const hasCTA = typed.some((block) =>
    (block.type === "button" && hasSubstantialText(block.label) && isUsableHref(block.url))
    || (block.type === "callText" && hasSubstantialText(block.label) && isUsablePhone(block.phoneNumber))
    || (block.type === "contact" && (isUsableEmail(block.email) || isUsablePhone(block.phone)))
  );
  const hasSupport = typed.some((block) =>
    block.type === "faq" && Array.isArray(block.items) && block.items.some((item) => {
      if (!item || typeof item !== "object") return false;
      const row = item as Record<string, unknown>;
      return hasSubstantialText(row.question) && hasSubstantialText(row.answer) && !hasPlaceholderCopy(row.answer);
    })
  ) || hasContact;

  if (!hasHero) missing.push("Complete the hero section.");
  if (!hasAbout) missing.push("Complete the About or description section.");
  if (!hasContact) missing.push("Enable a contact method.");
  if (!hasOffer) missing.push("Add at least one product/service or a clear business purpose.");
  if (!hasCTA) missing.push("Add a real CTA button.");
  if (!hasSupport) missing.push("Add a Support or FAQ section.");
  if (typed.some(hasEmptyRequiredContent)) missing.push("Remove empty placeholder sections.");
  if (typed.some(blockHasPlaceholderCopy)) missing.push("Replace unfinished placeholder copy.");

  return missing;
}

function validateHtmlQuality(html: string): string[] {
  const lower = html.trim().toLowerCase();
  const missing: string[] = [];
  if (!lower) return missing;
  if (!lower.includes("<meta name=\"viewport\"")) missing.push("Add mobile responsive viewport metadata.");
  if (!lower.includes("<title") || !lower.includes("meta name=\"description\"")) {
    missing.push("Add SEO title and description.");
  }
  if (!lower.includes("href=")) missing.push("Add real navigation, contact, or CTA links.");
  if (lower.includes("lorem ipsum") || lower.includes("example.com") || lower.includes("placeholder")) {
    missing.push("Replace unfinished placeholder copy.");
  }
  if (lower.includes("checkout") && !(lower.includes("payment") || lower.includes("contact seller") || lower.includes("mailto:") || lower.includes("tel:"))) {
    missing.push("Configure payments or show Contact Seller instead of fake checkout.");
  }
  return missing;
}

function hasEmptyRequiredContent(block: Record<string, unknown>): boolean {
  switch (String(block.type ?? "")) {
    case "hero":
      return !String(block.title ?? "").trim() || !String(block.subtitle ?? "").trim();
    case "text":
    case "paragraph":
      return !String(block.text ?? "").trim();
    case "button":
      return !String(block.label ?? "").trim() || !isUsableHref(block.url);
    case "contact":
      return !isUsableEmail(block.email) && !isUsablePhone(block.phone);
    case "callText":
      return !isUsablePhone(block.phoneNumber);
    case "services":
      return !hasUsableServiceItems(block.items);
    case "faq":
      return !Array.isArray(block.items) || block.items.length === 0;
    case "photo":
      return !String(block.url ?? "").trim();
    case "gallery":
      return !Array.isArray(block.images) || !block.images.some((image) =>
        Boolean(image) && typeof image === "object" && Boolean(String((image as Record<string, unknown>).url ?? "").trim())
      );
    case "testimonial":
      return !String(block.quote ?? "").trim() || !String(block.name ?? "").trim();
    default:
      return false;
  }
}

function blockHasPlaceholderCopy(block: Record<string, unknown>): boolean {
  return Object.values(block).some((value) => {
    if (typeof value === "string") return hasPlaceholderCopy(value) || isPlaceholderUrl(value);
    if (Array.isArray(value)) {
      return value.some((item) => item && typeof item === "object" && blockHasPlaceholderCopy(item as Record<string, unknown>));
    }
    return false;
  });
}

function hasUsableServiceItems(raw: unknown): boolean {
  return Array.isArray(raw) && raw.some((item) => {
    if (!item || typeof item !== "object") return false;
    const row = item as Record<string, unknown>;
    return hasSubstantialText(row.title) && hasSubstantialText(row.detail) && !hasPlaceholderCopy(row.detail);
  });
}

function offerText(raw: unknown): boolean {
  const text = String(raw ?? "").toLowerCase();
  return hasSubstantialText(text)
    && !hasPlaceholderCopy(text)
    && (text.includes("service") || text.includes("product") || text.includes("offer") || text.includes("book"));
}

function hasSubstantialText(raw: unknown): boolean {
  return String(raw ?? "").trim().length >= 12;
}

function isGenericTitle(value: string): boolean {
  return ["my oneway site", "my store", "my shop", "new product", "welcome"].includes(value.trim().toLowerCase());
}

function hasPlaceholderCopy(raw: unknown): boolean {
  const lower = String(raw ?? "").trim().toLowerCase();
  if (!lower) return false;
  return lower.includes("lorem ipsum")
    || lower.includes("add your")
    || lower.includes("add a ")
    || lower.includes("tell visitors")
    || lower.includes("tell people")
    || lower.includes("describe the")
    || lower.includes("write a short")
    || lower.includes("customer name")
    || lower.includes("happy customer")
    || lower.includes("gallery image")
    || lower.includes("first highlight")
    || lower.includes("second highlight")
    || lower.includes("third highlight")
    || lower.includes("main offer")
    || lower.includes("new product")
    || lower === "description";
}

function isPlaceholderUrl(raw: unknown): boolean {
  const lower = String(raw ?? "").trim().toLowerCase();
  return lower === "https://" || lower === "http://" || lower.includes("example.com");
}

function isUsableHref(raw: unknown): boolean {
  const lower = String(raw ?? "").trim().toLowerCase();
  return lower.startsWith("https://")
    || lower.startsWith("http://")
    || lower.startsWith("mailto:")
    || lower.startsWith("tel:")
    || lower.startsWith("oneway:")
    || lower.startsWith("#")
    || lower.startsWith("/");
}

function isUsableEmail(raw: unknown): boolean {
  const lower = String(raw ?? "").trim().toLowerCase();
  return lower.includes("@") && !lower.includes("example.com");
}

function isUsablePhone(raw: unknown): boolean {
  const value = String(raw ?? "");
  return value.replace(/\D/g, "").length >= 7 || value.toLowerCase().includes("oneway");
}

function unique(items: string[]): string[] {
  return [...new Set(items)];
}

function renderPublishedHtml(site: {
  domain: string;
  title: string;
  description: string;
  mode: string;
  html: string;
  blocksJson: string;
}): string {
  const blocks = parseBlocks(site.blocksJson);
  if (site.mode === "nocode" || (site.mode === "ai" && blocks.length > 0)) {
    return renderBlocksHtml({
      domain: site.domain,
      title: site.title,
      description: site.description,
      blocks,
    });
  }

  return sanitizeHtml(wrapHtmlIfNeeded(site.html, site.title, site.description));
}

function renderBlocksHtml(input: { domain: string; title: string; description: string; blocks: unknown[] }): string {
  const body = input.blocks.map(renderBlock).join("\n");
  return wrapHtmlIfNeeded(
    `<main class="page">${body}</main>`,
    input.title,
    input.description,
    input.domain,
  );
}

function renderBlock(raw: unknown): string {
  if (!raw || typeof raw !== "object") return "";
  const block = raw as Record<string, unknown>;
  const type = String(block.type ?? "");

  switch (type) {
    case "hero":
      return `<section class="hero"><p class="eyebrow">${escapeText(String(block.eyebrow ?? "Built on OneWay"))}</p><h1>${escapeText(String(block.title ?? "Welcome"))}</h1><p>${escapeText(String(block.subtitle ?? ""))}</p></section>`;
    case "text":
      return `<section class="card"><p>${escapeText(String(block.text ?? ""))}</p></section>`;
    case "button":
      return `<section class="cta"><a href="${escapeAttr(safeHref(String(block.url ?? "#")))}">${escapeText(String(block.label ?? "Learn more"))}</a></section>`;
    case "contact":
      return `<section class="card"><h2>Contact</h2><p>${escapeText(String(block.name ?? ""))}</p><p><a href="mailto:${escapeAttr(String(block.email ?? ""))}">${escapeText(String(block.email ?? ""))}</a></p><p><a href="tel:${escapeAttr(String(block.phone ?? ""))}">${escapeText(String(block.phone ?? ""))}</a></p></section>`;
    case "hours":
      return `<section class="card"><h2>Business hours</h2><p>${escapeText(String(block.hours ?? "Monday-Friday, 9 AM-5 PM"))}</p></section>`;
    case "callText":
      return `<section class="cta"><h2>${escapeText(String(block.label ?? "Ready to talk?"))}</h2><p>${escapeText(String(block.phoneNumber ?? ""))}</p></section>`;
    case "photo":
    case "image": {
      const url = safeImageUrl(String(block.url ?? ""));
      if (!url) return "";
      const alt = String(block.alt ?? "");
      const caption = String(block.caption ?? "");
      const figcaption = caption.trim() ? `<figcaption>${escapeText(caption)}</figcaption>` : "";
      return `<figure class="card image-card"><img src="${escapeAttr(url)}" alt="${escapeAttr(alt)}" loading="lazy" />${figcaption}</figure>`;
    }
    case "gallery": {
      const images = renderGalleryImages(block.images);
      if (!images) return "";
      return `<section class="card gallery"><h2>${escapeText(String(block.title ?? "Gallery"))}</h2><div class="gallery-grid">${images}</div></section>`;
    }
    case "testimonial":
      return `<section class="card testimonial"><p class="quote">&ldquo;${escapeText(String(block.quote ?? ""))}&rdquo;</p><p class="byline">${escapeText(String(block.name ?? ""))}${block.role ? ` <span>${escapeText(String(block.role))}</span>` : ""}</p></section>`;
    case "services": {
      const items = renderServiceItems(block.items);
      if (!items) return "";
      return `<section class="card services"><h2>${escapeText(String(block.title ?? "Services"))}</h2><div class="services-grid">${items}</div></section>`;
    }
    case "faq": {
      const items = renderFAQItems(block.items);
      if (!items) return "";
      return `<section class="card faq"><h2>${escapeText(String(block.title ?? "Questions"))}</h2><div class="faq-list">${items}</div></section>`;
    }
    case "heading":
      return `<section class="card"><h2>${escapeText(String(block.text ?? ""))}</h2></section>`;
    case "paragraph":
      return `<section class="card"><p>${escapeText(String(block.text ?? ""))}</p></section>`;
    case "link":
      return `<section class="cta"><a href="${escapeAttr(safeHref(String(block.href ?? "#")))}">${escapeText(String(block.label ?? "Open link"))}</a></section>`;
    case "divider":
      return `<hr />`;
    case "html":
      return sanitizeHtml(String(block.raw ?? ""));
    default:
      return "";
  }
}

function wrapHtmlIfNeeded(html: string, title: string, description = "", domain = "oneway.app"): string {
  const content = html.trim();
  if (/<!doctype html/i.test(content) || /<html[\s>]/i.test(content)) {
    return sanitizeHtml(content);
  }

  return sanitizeHtml(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeText(title || domain)}</title>
  <meta name="description" content="${escapeAttr(description)}" />
  <style>
    :root{color-scheme:dark;--bg:#13072d;--panel:rgba(255,255,255,.08);--text:#f7f2ff;--muted:#c9b9ee;--accent:#ffcc33;--blue:#3385ff}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,"Avenir Next",sans-serif;background:radial-gradient(circle at top left,#402079,transparent 38%),linear-gradient(150deg,#0b041b,#28105a 58%,#4e1f8f);color:var(--text);line-height:1.6}
    .page{width:min(920px,calc(100% - 32px));margin:0 auto;padding:64px 0}
    .hero{padding:56px 0}.eyebrow{color:var(--accent);font-weight:800;text-transform:uppercase;letter-spacing:.12em;font-size:.8rem}
    h1{font-size:clamp(2.4rem,9vw,5.8rem);line-height:.95;margin:.1em 0 .25em}h2{font-size:1.35rem;margin:0 0 10px}
    p{color:var(--muted);font-size:1.08rem}.card{background:var(--panel);border:1px solid rgba(255,255,255,.14);border-radius:24px;padding:24px;margin:18px 0;backdrop-filter:blur(14px)}
    .cta{border-radius:28px;padding:28px;margin:22px 0;background:linear-gradient(135deg,var(--blue),#7647ff);box-shadow:0 18px 50px rgba(51,133,255,.22)}
    .cta a{display:inline-flex;align-items:center;justify-content:center;border-radius:999px;padding:12px 18px;background:#fff;color:#13072d;font-weight:800;text-decoration:none}
    .image-card{overflow:hidden;padding:0}.image-card img{display:block;width:100%;height:auto}.image-card figcaption{padding:12px 18px;color:var(--muted);font-size:.95rem}
    .gallery h2{margin-bottom:18px}.gallery-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px}.gallery-grid figure{margin:0;overflow:hidden;border-radius:18px;background:rgba(255,255,255,.06)}.gallery-grid img{display:block;width:100%;aspect-ratio:4/3;object-fit:cover}.gallery-grid figcaption{padding:10px 12px;color:var(--muted);font-size:.92rem}
    .testimonial .quote{font-size:clamp(1.4rem,4vw,2.2rem);line-height:1.25;color:var(--text);font-weight:800}.testimonial .byline{font-weight:800;color:var(--accent)}.testimonial .byline span{display:block;color:var(--muted);font-weight:600}
    .services-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-top:16px}.service-item{border-radius:18px;padding:16px;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1)}.service-item h3{font-size:1.05rem;margin:0 0 6px}.service-item p{font-size:.98rem;margin:0}
    .faq-list{display:grid;gap:10px;margin-top:14px}.faq-item{border-radius:16px;padding:14px 16px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1)}.faq-item h3{font-size:1rem;margin:0 0 6px}.faq-item p{font-size:.98rem;margin:0}
    a{color:#fff}hr{border:0;border-top:1px solid rgba(255,255,255,.14);margin:28px 0}
    footer{border-top:1px solid rgba(255,255,255,.14);margin:40px auto 0;padding:22px 0;color:var(--muted);font-size:.92rem}
    footer nav{display:flex;flex-wrap:wrap;gap:14px;justify-content:center}
  </style>
</head>
<body>
${content}
<footer>
  <nav aria-label="Site links">
    <a href="https://oneway.is/privacy">Privacy</a>
    <a href="https://oneway.is/terms">Terms</a>
    <a href="https://oneway.is/support">Support</a>
  </nav>
</footer>
</body>
</html>`);
}

function sanitizeHtml(html: string): string {
  return html
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "")
    .replace(/\son[a-z]+\s*=\s*"[^"]*"/gi, "")
    .replace(/\son[a-z]+\s*=\s*'[^']*'/gi, "")
    .replace(/\son[a-z]+\s*=\s*[^\s>]+/gi, "")
    .replace(/javascript:/gi, "");
}

function safeHref(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "#";
  if (/^(https?:|mailto:|tel:)/i.test(trimmed)) return trimmed;
  if (trimmed.startsWith("/")) return trimmed;
  return `https://${trimmed}`;
}

function safeImageUrl(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  if (/^data:image\/(png|jpe?g|webp);base64,/i.test(trimmed)) return trimmed;
  if (trimmed.startsWith("/uploads/")) return trimmed;
  return "";
}

function renderGalleryImages(raw: unknown): string {
  if (!Array.isArray(raw)) return "";
  return raw
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "";
      const image = entry as Record<string, unknown>;
      const url = safeImageUrl(String(image.url ?? ""));
      if (!url) return "";
      const alt = String(image.alt ?? "");
      const caption = String(image.caption ?? "");
      const figcaption = caption.trim() ? `<figcaption>${escapeText(caption)}</figcaption>` : "";
      return `<figure><img src="${escapeAttr(url)}" alt="${escapeAttr(alt)}" loading="lazy" />${figcaption}</figure>`;
    })
    .filter(Boolean)
    .join("");
}

function renderServiceItems(raw: unknown): string {
  if (!Array.isArray(raw)) return "";
  return raw
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "";
      const item = entry as Record<string, unknown>;
      const title = String(item.title ?? "").trim();
      const detail = String(item.detail ?? "").trim();
      if (!title && !detail) return "";
      return `<article class="service-item"><h3>${escapeText(title || "Service")}</h3><p>${escapeText(detail)}</p></article>`;
    })
    .filter(Boolean)
    .join("");
}

function renderFAQItems(raw: unknown): string {
  if (!Array.isArray(raw)) return "";
  return raw
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "";
      const item = entry as Record<string, unknown>;
      const question = String(item.question ?? "").trim();
      const answer = String(item.answer ?? "").trim();
      if (!question && !answer) return "";
      return `<article class="faq-item"><h3>${escapeText(question || "Question")}</h3><p>${escapeText(answer)}</p></article>`;
    })
    .filter(Boolean)
    .join("");
}

function extensionForMimeType(mimeType: string): string {
  switch (mimeType) {
    case "image/png":
      return "png";
    case "image/webp":
      return "webp";
    case "image/heic":
      return "heic";
    case "image/heif":
      return "heif";
    case "image/gif":
      return "gif";
    case "video/mp4":
      return "mp4";
    case "video/quicktime":
      return "mov";
    case "video/x-m4v":
      return "m4v";
    default:
      return "jpg";
  }
}

function safeFileName(originalName: string, fallbackExtension: string): string {
  const base = path.basename(originalName || `site-photo.${fallbackExtension}`)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
  if (!base) return `site-media.${fallbackExtension}`;
  if (/\.(jpe?g|png|webp|heic|heif|gif|mp4|mov|m4v)$/i.test(base)) return base;
  return `${base}.${fallbackExtension}`;
}

function safeSegment(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 120) || "user";
}

async function uploadSiteAssetToObjectStorage(
  storage: S3ObjectStorage,
  key: string,
  buffer: Buffer,
  mimeType: string,
): Promise<string> {
  await storage.put(key, buffer, mimeType);
  return storage.presignedDownloadUrl(key, 60 * 60 * 24 * 365);
}

async function saveSiteAssetLocally(req: express.Request, key: string, buffer: Buffer): Promise<string> {
  const destination = path.join(process.cwd(), "uploads", key);
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.writeFile(destination, buffer);
  return `${req.protocol}://${req.get("host")}/uploads/${key}`;
}

function generateDeterministicSiteBlocks(input: {
  domain: string;
  title: string;
  description: string;
  prompt: string;
}): { title: string; description: string; blocks: Record<string, unknown>[] } {
  const title = inferBusinessName(input.prompt, input.title, input.domain);
  const description = input.description?.trim() || descriptionFromPrompt(input.prompt) || `${title} offers clear products, helpful service, and fast contact through OneWay.`;
  const services = inferServiceItems(input.prompt);

  return {
    title,
    description,
    blocks: [
      { type: "hero", eyebrow: "Now on OneWay", title, subtitle: description },
      {
        type: "text",
        text: `${title} gives visitors a clear place to understand the offer, browse services, and contact the business through OneWay.`,
      },
      { type: "services", title: "Products and services", items: services },
      { type: "button", label: "View Products", url: "#products" },
      { type: "contact", name: title, email: "support@oneway.is", phone: "" },
      { type: "callText", label: "Contact through OneWay", phoneNumber: "Contact through OneWay" },
      { type: "button", label: "Message Business", url: "https://oneway.is/contact" },
      { type: "button", label: "Contact on OneWay", url: "https://oneway.is/support" },
      {
        type: "gallery",
        title: "Featured images",
        images: [
          {
            url: "https://images.unsplash.com/photo-1497366754035-f200968a6e72?auto=format&fit=crop&w=900&q=80",
            alt: `${title} workspace`,
            caption: "A polished first impression",
          },
          {
            url: "https://images.unsplash.com/photo-1556761175-b413da4baf72?auto=format&fit=crop&w=900&q=80",
            alt: `${title} service preview`,
            caption: "Products and services",
          },
          {
            url: "https://images.unsplash.com/photo-1521791136064-7986c2920216?auto=format&fit=crop&w=900&q=80",
            alt: `${title} customer support`,
            caption: "Easy customer contact",
          },
        ],
      },
      {
        type: "faq",
        title: "Support",
        items: [
          {
            question: "How do customers get started?",
            answer: "Use the Contact on OneWay or Message Business button and the business will follow up with next steps.",
          },
          {
            question: "Can this site be updated later?",
            answer: "Yes. Images, products, services, copy, colors, and contact options can be edited in Site Studio.",
          },
        ],
      },
    ],
  };
}

function inferBusinessName(prompt: string, fallback: string, domain: string): string {
  const cleanFallback = fallback.trim();
  if (cleanFallback && cleanFallback.toLowerCase() !== "my oneway site") return cleanFallback;

  const words = prompt
    .replace(/\s+/g, " ")
    .split(" ")
    .map((word) => word.replace(/[^\w-]/g, ""))
    .filter(Boolean)
    .slice(0, 4);
  if (words.length > 0) return titleCase(words.join(" "));

  return titleCase(domain.replace(/\.oneway\.app$/, "").replace(/-/g, " "));
}

function inferServiceItems(prompt: string): Record<string, string>[] {
  const lower = prompt.toLowerCase();
  if (lower.includes("restaurant") || lower.includes("food") || lower.includes("cafe")) {
    return [
      { title: "Menu highlights", detail: "Feature signature dishes, specials, pickup options, and ordering details." },
      { title: "Catering or events", detail: "Let visitors ask about larger orders, private events, or custom requests." },
      { title: "Contact to order", detail: "Customers can message the business through OneWay for availability and next steps." },
    ];
  }
  if (lower.includes("photo") || lower.includes("portfolio") || lower.includes("creative")) {
    return [
      { title: "Featured work", detail: "Showcase selected projects, style, and the kind of work customers can book." },
      { title: "Creative services", detail: "Describe packages, deliverables, timelines, and collaboration options." },
      { title: "Project inquiries", detail: "Invite visitors to message through OneWay for rates and availability." },
    ];
  }
  return [
    { title: "Primary offer", detail: "A clear product or service customers can understand and ask about right away." },
    { title: "Fast follow-up", detail: "OneWay contact actions make it easy for visitors to message, call, or request help." },
    { title: "Professional support", detail: "Customers get a complete site with business details, contact options, and next steps." },
  ];
}

function titleCase(value: string): string {
  return value.replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function generateDeterministicSiteHtml(input: {
  domain: string;
  title: string;
  description: string;
  prompt: string;
}): string {
  const summary = input.prompt.length > 180 ? `${input.prompt.slice(0, 177)}...` : input.prompt;
  const cta = input.prompt.toLowerCase().includes("book") ? "Book now" : "Get in touch";
  return wrapHtmlIfNeeded(`
<main class="page">
  <section class="hero">
    <p class="eyebrow">${escapeText(input.domain)}</p>
    <h1>${escapeText(input.title)}</h1>
    <p>${escapeText(input.description || summary)}</p>
  </section>
  <section class="card">
    <h2>What we do</h2>
    <p>${escapeText(summary)}</p>
  </section>
  <section class="card">
    <h2>Why customers choose us</h2>
    <p>Clear information, fast follow-up, and a simple way to reach the business from any device.</p>
  </section>
  <section class="cta">
    <h2>${escapeText(cta)}</h2>
    <p>Reach this business through OneWay or the contact details they publish here.</p>
    <a href="#contact">Contact Seller</a>
  </section>
  <section class="card" id="contact">
    <h2>Contact</h2>
    <p>Message this business on OneWay for questions, bookings, or support.</p>
  </section>
</main>`,
    input.title,
    input.description,
    input.domain,
  );
}

function titleFromPrompt(prompt: string): string {
  const words = prompt.trim().split(/\s+/).slice(0, 5).join(" ");
  return words ? words.replace(/\b\w/g, (letter) => letter.toUpperCase()) : "My OneWay Site";
}

function descriptionFromPrompt(prompt: string): string {
  return prompt.trim().slice(0, 180) || "A simple site hosted on OneWay.";
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
