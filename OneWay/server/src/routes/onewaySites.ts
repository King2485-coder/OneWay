import express from "express";
import { prisma } from "../lib/db";

export function oneWaySitesRouter(): express.Router {
  const router = express.Router();

  router.get("/sites/:slug", async (req, res) => {
    const slug = normalizeSlug(String(req.params.slug ?? ""));
    if (!slug) return res.status(400).json({ error: "invalid_slug" });
    console.info("QUANTUM_SITE_RESOLVE_REQUESTED", { slug, stage: "public_resolver" });

    const site = await prisma.site.findFirst({
      where: {
        OR: [
          { slug },
          { domain: `${slug}.oneway.app` },
          { domain: `${slug}.oneway.site` },
        ],
      },
    });
    if (!site) {
      const proxied = await proxyProductionSiteIfLocal(req, slug);
      if (proxied) return res.status(proxied.status).json(proxied.body);
      console.warn("SITE_PUBLIC_ROUTE_FAILED", { slug, status: "not_found" });
      console.warn("QUANTUM_SITE_RESOLVE_FAILED", { slug, failureCode: "SITE_NOT_FOUND" });
      return res.status(404).json({ error: "SITE_NOT_FOUND", message: "This Site is not available on the OneWay Internet." });
    }
    if (!["PUBLIC", "UNLISTED"].includes(site.visibility ?? "PUBLIC")) {
      console.warn("QUANTUM_SITE_RESOLVE_FAILED", { slug, siteId: site.id, failureCode: "SITE_PRIVATE" });
      return res.status(404).json({ error: "SITE_PRIVATE", message: "This Site is private." });
    }
    if (site.status === "PAUSED") return res.status(404).json({ error: "SITE_PAUSED", message: "This Site is paused." });
    if (site.status === "UNPUBLISHED") return res.status(404).json({ error: "SITE_UNPUBLISHED", message: "This Site has been unpublished." });
    if (site.status === "ARCHIVED") return res.status(404).json({ error: "SITE_ARCHIVED", message: "This Site has been archived." });

    let activePublicationId = site.activePublicationId;
    if (!activePublicationId && site.status === "PUBLISHED") {
      activePublicationId = await repairActivePublication(site, slug);
    }

    if (!activePublicationId) {
      const code = site.status === "PUBLISHED" ? "PUBLICATION_STATE_INVALID" : "SITE_NOT_PUBLISHED";
      console.warn("SITE_PUBLIC_ROUTE_FAILED", { slug, siteId: site.id, status: site.status, failureCode: code });
      console.warn("QUANTUM_SITE_RESOLVE_FAILED", { slug, siteId: site.id, failureCode: code });
      return res.status(code === "PUBLICATION_STATE_INVALID" ? 409 : 404).json({
        error: code,
        message: code === "SITE_NOT_PUBLISHED" ? "This OneWay Site is not published yet." : "This Site publication needs repair.",
      });
    }

    const publication = await prisma.sitePublication.findFirst({
      where: { id: activePublicationId, siteId: site.id, status: "ACTIVE" },
    });
    if (!publication) {
      console.warn("SITE_PUBLIC_ROUTE_FAILED", { slug, siteId: site.id, status: "publication_missing" });
      console.warn("QUANTUM_SITE_RESOLVE_FAILED", { slug, siteId: site.id, failureCode: "PUBLICATION_UNAVAILABLE" });
      return res.status(409).json({ error: "PUBLICATION_UNAVAILABLE", message: "This Site is temporarily unavailable." });
    }

    console.info("SITE_PUBLIC_ROUTE_RESOLVED", { siteId: site.id, publicationId: publication.id, version: publication.versionNumber, status: "ok" });
    console.info("QUANTUM_SITE_RESOLVE_SUCCEEDED", { siteId: site.id, publicationId: publication.id, version: publication.versionNumber, stage: "manifest_loaded" });
    res.json(publicSiteDTO(site, publication));
  });

  router.get("/sites/:slug/pages/:pageSlug", async (req, res) => {
    const slug = normalizeSlug(String(req.params.slug ?? ""));
    const pageSlug = normalizeSlug(String(req.params.pageSlug ?? ""));
    if (!slug || !pageSlug) return res.status(400).json({ error: "invalid_slug" });
    const response = await resolvePublishedSite(slug);
    if (!response) return res.status(404).json({ error: "site_not_found" });
    res.json({ ...response, pageSlug });
  });

  router.get("/search/sites", async (req, res) => {
    const query = String(req.query.q ?? "").trim().toLowerCase();
    const sites = await prisma.site.findMany({
      where: {
        status: "PUBLISHED",
        visibility: "PUBLIC",
        activePublicationId: { not: null },
      },
      orderBy: { publishedAt: "desc" },
      take: 30,
    });
    const filtered = query
      ? sites.filter((site) => `${site.title} ${site.description} ${site.domain}`.toLowerCase().includes(query))
      : sites;
    res.json({
      results: filtered.map((site) => ({
        siteId: site.id,
        title: site.title,
        description: site.description,
        address: site.publicAddress ?? `oneway://${site.slug ?? normalizeSlug(site.domain)}`,
        slug: site.slug,
        publishedAt: site.publishedAt?.toISOString() ?? null,
      })),
    });
  });

  return router;
}

async function resolvePublishedSite(slug: string) {
  const site = await prisma.site.findFirst({
    where: { slug, status: "PUBLISHED", visibility: { in: ["PUBLIC", "UNLISTED"] }, activePublicationId: { not: null } },
  });
  if (!site?.activePublicationId) return null;
  const publication = await prisma.sitePublication.findFirst({ where: { id: site.activePublicationId, siteId: site.id, status: "ACTIVE" } });
  return publication ? publicSiteDTO(site, publication) : null;
}

async function repairActivePublication(site: any, slug: string): Promise<string | null> {
  const reusable = await prisma.sitePublication.findFirst({
    where: { siteId: site.id, status: { in: ["ACTIVE", "READY", "BUILT", "SUPERSEDED"] } },
    orderBy: { versionNumber: "desc" },
  });
  if (reusable && publicationHasRenderableManifest(reusable.contentManifest)) {
    await prisma.$transaction(async (tx) => {
      await tx.sitePublication.updateMany({ where: { siteId: site.id, status: "ACTIVE" }, data: { status: "SUPERSEDED" } });
      await tx.sitePublication.update({ where: { id: reusable.id }, data: { status: "ACTIVE", failureCode: null, failureMessage: null, publishedAt: reusable.publishedAt ?? new Date() } });
      await tx.site.update({ where: { id: site.id }, data: { activePublicationId: reusable.id, status: "PUBLISHED", slug, publicAddress: `oneway://${slug}`, publishedAt: site.publishedAt ?? reusable.publishedAt ?? new Date() } });
    });
    console.info("SITE_PUBLICATION_RECONCILE_SUCCEEDED", { siteId: site.id, publicationId: reusable.id, slug, action: "activated_existing_publication" });
    return reusable.id;
  }

  if (String(site.publishedHtml ?? "").trim()) {
    const versionNumber = (await prisma.sitePublication.findFirst({ where: { siteId: site.id }, orderBy: { versionNumber: "desc" } }))?.versionNumber ?? 0;
    const contentManifest = {
      siteId: site.id,
      domain: site.domain,
      slug,
      publicAddress: `oneway://${slug}`,
      publicWebAddress: `https://sites.oneway.app/${slug}`,
      title: site.title,
      description: site.description,
      html: site.publishedHtml,
      blocks: [],
      homepage: "home",
      visibility: site.visibility ?? "PUBLIC",
      publishedAt: new Date().toISOString(),
      cacheVersion: `${versionNumber + 1}-${Date.now()}`,
      reconciliationReason: "legacy_published_html",
    };
    const publication = await prisma.sitePublication.create({
      data: {
        siteId: site.id,
        versionNumber: versionNumber + 1,
        status: "ACTIVE",
        publishedBy: site.userId,
        publishedAt: new Date(),
        sourceDraftVersion: Number(site.draftVersion ?? 1),
        contentManifest: JSON.stringify(contentManifest),
        assetManifest: JSON.stringify({ assetIds: [], variants: [] }),
        publicAddress: `oneway://${slug}`,
        buildStartedAt: new Date(),
        buildCompletedAt: new Date(),
      },
    });
    await prisma.site.update({ where: { id: site.id }, data: { activePublicationId: publication.id, status: "PUBLISHED", slug, publicAddress: `oneway://${slug}`, publishedAt: site.publishedAt ?? new Date() } });
    console.info("SITE_PUBLICATION_RECONCILE_SUCCEEDED", { siteId: site.id, publicationId: publication.id, slug, action: "created_from_legacy_html" });
    return publication.id;
  }

  return null;
}

function publicationHasRenderableManifest(raw: string): boolean {
  const manifest = parseJson(raw);
  return Boolean(String(manifest.html ?? "").trim() || Array.isArray(manifest.blocks));
}

function publicSiteDTO(site: {
  id: string;
  title: string;
  description: string;
  domain: string;
  slug: string | null;
  publicAddress: string | null;
  visibility: string;
  status?: string;
  activePublicationId?: string | null;
  publishedAt: Date | null;
}, publication: {
  id: string;
  versionNumber: number;
  status?: string;
  contentManifest: string;
  assetManifest: string;
  publicAddress: string;
  publishedAt: Date | null;
}) {
  const manifest = parseJson(publication.contentManifest);
  const slug = site.slug ?? normalizeSlug(site.domain);
  const summary = publicManifestSummary(manifest);
  return {
    siteId: site.id,
    canonicalSlug: slug,
    siteStatus: site.status ?? "PUBLISHED",
    activePublicationId: site.activePublicationId ?? publication.id,
    publicationId: publication.id,
    activePublication: {
      id: publication.id,
      status: publication.status ?? "ACTIVE",
      version: publication.versionNumber,
      publishedAt: publication.publishedAt?.toISOString() ?? null,
    },
    publicationStatus: publication.status ?? "ACTIVE",
    publicationVersion: publication.versionNumber,
    version: publication.versionNumber,
    title: site.title,
    description: site.description,
    domain: site.domain,
    slug,
    address: site.publicAddress ?? publication.publicAddress,
    publicURL: `https://sites.oneway.app/${slug}`,
    routeVerified: (publication.status ?? "ACTIVE") === "ACTIVE" && (site.status ?? "PUBLISHED") === "PUBLISHED",
    visibility: site.visibility,
    publishedAt: publication.publishedAt?.toISOString() ?? site.publishedAt?.toISOString() ?? null,
    html: String(manifest.html ?? ""),
    homepage: summary.homepage,
    pages: summary.pages,
    sections: summary.sections,
    components: summary.components,
    manifest,
    assets: parseJson(publication.assetManifest),
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

function normalizeSlug(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/^oneway:\/\/site\//, "")
    .replace(/^oneway:\/\//, "")
    .replace(/^https?:\/\/sites\.oneway\.app\//, "")
    .replace(/\.oneway\.(app|site)$/, "")
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

async function proxyProductionSiteIfLocal(
  req: express.Request,
  slug: string,
): Promise<{ status: number; body: unknown } | null> {
  if (!isLocalDebugRequest(req)) return null;

  const endpoint = `https://api.oneway.is/api/oneway/sites/${encodeURIComponent(slug)}`;
  try {
    const response = await fetch(endpoint, {
      method: "GET",
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(6000),
    });
    const text = await response.text();
    const body = text ? JSON.parse(text) : {};
    console.info("QUANTUM_SITE_LOCAL_PROXY_RESULT", {
      slug,
      status: response.status,
      proxiedFrom: "production",
    });
    return { status: response.status, body };
  } catch (error) {
    console.warn("QUANTUM_SITE_LOCAL_PROXY_FAILED", {
      slug,
      message: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

function isLocalDebugRequest(req: express.Request): boolean {
  const host = String(req.headers.host ?? "").toLowerCase();
  return host.startsWith("localhost:")
    || host.startsWith("127.0.0.1:")
    || host.startsWith("192.168.")
    || host.startsWith("10.")
    || host.includes(".local:");
}

function parseJson(raw: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}
