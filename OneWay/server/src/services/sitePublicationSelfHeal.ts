import type { PrismaClient } from "@prisma/client";
import { logger } from "../lib/logger";

export const SITE_PUBLICATION_ROUTE_VERSION = "site-publication-active-v2";

type SiteLike = {
  id: string;
  userId: string;
  domain: string;
  title: string;
  description: string;
  mode: string;
  html: string;
  blocksJson: string;
  publishedHtml: string;
  publishedAt: Date | null;
  slug: string | null;
  publicAddress: string | null;
  visibility: string;
  status: string;
  activePublicationId: string | null;
  draftVersion: number;
};

type PublicationLike = {
  id: string;
  siteId: string;
  versionNumber: number;
  status: string;
  contentManifest: string;
  assetManifest: string;
  publicAddress: string;
  publishedAt: Date | null;
};

type ReconcileResult = {
  siteId: string;
  slug: string;
  status: "HEALTHY" | "REPAIRED" | "REBUILD_REQUIRED" | "INVALID_MANIFEST" | "MISSING_HOMEPAGE" | "FAILED";
  action: string;
  activePublicationId: string | null;
  publicationStatus: string | null;
  routeVerified: boolean;
  failureCode?: string;
};

export function assertSitePublicationRoutesRegistered(routeKeys: string[]): void {
  const required = [
    "GET /api/oneway/sites/:slug",
    "POST /api/sites/:domain/publication/reconcile",
    "POST /api/sites/:siteId/publication/reconcile-by-id",
    "GET /api/sites/:siteId/publication/health",
  ];
  const missing = required.filter((route) => !routeKeys.includes(route));
  if (missing.length > 0) {
    logger.error({ missing, routeVersion: SITE_PUBLICATION_ROUTE_VERSION }, "[sites] required publication routes missing");
    throw new Error(`Required OneWay Site publication routes missing: ${missing.join(", ")}`);
  }
  logger.info({ required, routeVersion: SITE_PUBLICATION_ROUTE_VERSION }, "[sites] required publication routes registered");
  console.info("PRODUCTION_ROUTE_REGISTERED", { required, routeVersion: SITE_PUBLICATION_ROUTE_VERSION });
}

export async function reconcileAllSitePublicationsOnStartup(prisma: PrismaClient): Promise<ReconcileResult[]> {
  const enabled = process.env.ONEWAY_SITE_PUBLICATION_SELF_HEAL !== "false";
  if (!enabled) {
    logger.warn({}, "[sites] publication self-heal skipped by ONEWAY_SITE_PUBLICATION_SELF_HEAL=false");
    return [];
  }

  await ensureSitePublicationSchema(prisma);

  const sites = await prisma.site.findMany({
    where: {
      OR: [
        { status: { in: ["PUBLISHED", "PUBLISH_FAILED", "DRAFT"] } },
        { publishedAt: { not: null } },
        { activePublicationId: { not: null } },
      ],
    },
    orderBy: { updatedAt: "desc" },
  }) as SiteLike[];

  const results: ReconcileResult[] = [];
  for (const site of sites) {
    try {
      results.push(await reconcileSitePublication(prisma, site, "startup_self_heal"));
    } catch (error) {
      const slug = canonicalSlug(site);
      logger.error({ err: error, siteId: site.id, slug }, "[sites] startup publication reconciliation failed");
      results.push({
        siteId: site.id,
        slug,
        status: "FAILED",
        action: "none",
        activePublicationId: site.activePublicationId,
        publicationStatus: null,
        routeVerified: false,
        failureCode: error instanceof Error ? error.message : "reconcile_failed",
      });
    }
  }

  const summary = results.reduce<Record<string, number>>((acc, item) => {
    acc[item.status] = (acc[item.status] ?? 0) + 1;
    return acc;
  }, {});
  logger.info({ summary, count: results.length }, "[sites] startup publication reconciliation completed");
  console.info("SITE_PUBLICATION_GLOBAL_RECONCILIATION_COMPLETED", { summary, count: results.length });
  return results;
}

async function ensureSitePublicationSchema(prisma: PrismaClient): Promise<void> {
  const dbUrl = process.env.DATABASE_URL ?? "";
  if (!dbUrl.trim().startsWith("file:")) return;

  const siteColumns = await sqliteColumns(prisma, "Site");
  if (siteColumns.size === 0) {
    logger.warn({}, "[sites] publication schema repair skipped: Site table is missing");
    return;
  }

  await addSqliteColumnIfMissing(prisma, "Site", siteColumns, "slug", "TEXT");
  await addSqliteColumnIfMissing(prisma, "Site", siteColumns, "publicAddress", "TEXT");
  await addSqliteColumnIfMissing(prisma, "Site", siteColumns, "visibility", "TEXT NOT NULL DEFAULT 'PUBLIC'");
  await addSqliteColumnIfMissing(prisma, "Site", siteColumns, "status", "TEXT NOT NULL DEFAULT 'DRAFT'");
  await addSqliteColumnIfMissing(prisma, "Site", siteColumns, "activePublicationId", "TEXT");
  await addSqliteColumnIfMissing(prisma, "Site", siteColumns, "draftVersion", "INTEGER NOT NULL DEFAULT 1");

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "SitePublication" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "siteId" TEXT NOT NULL,
      "versionNumber" INTEGER NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'BUILDING',
      "publishedBy" TEXT NOT NULL,
      "publishedAt" DATETIME,
      "sourceDraftVersion" INTEGER NOT NULL DEFAULT 1,
      "contentManifest" TEXT NOT NULL,
      "assetManifest" TEXT NOT NULL,
      "publicAddress" TEXT NOT NULL,
      "buildStartedAt" DATETIME,
      "buildCompletedAt" DATETIME,
      "failureCode" TEXT,
      "failureMessage" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT "SitePublication_siteId_fkey" FOREIGN KEY ("siteId") REFERENCES "Site" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
      CONSTRAINT "SitePublication_publishedBy_fkey" FOREIGN KEY ("publishedBy") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "SitePublication_siteId_versionNumber_key" ON "SitePublication"("siteId", "versionNumber")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SitePublication_siteId_status_idx" ON "SitePublication"("siteId", "status")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SitePublication_publicAddress_idx" ON "SitePublication"("publicAddress")`);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "Site_slug_key" ON "Site"("slug") WHERE "slug" IS NOT NULL`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Site_status_visibility_idx" ON "Site"("status", "visibility")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "Site_userId_updatedAt_idx" ON "Site"("userId", "updatedAt")`);

  logger.info({}, "[sites] publication schema repair complete");
  console.info("SITE_PUBLICATION_SCHEMA_READY");
}

async function sqliteColumns(prisma: PrismaClient, tableName: string): Promise<Set<string>> {
  const rows = await prisma.$queryRawUnsafe<Array<{ name?: string }>>(`PRAGMA table_info("${tableName}")`);
  return new Set(rows.map((row) => String(row.name ?? "")).filter(Boolean));
}

async function addSqliteColumnIfMissing(
  prisma: PrismaClient,
  tableName: string,
  columns: Set<string>,
  columnName: string,
  definition: string,
): Promise<void> {
  if (columns.has(columnName)) return;
  await prisma.$executeRawUnsafe(`ALTER TABLE "${tableName}" ADD COLUMN "${columnName}" ${definition}`);
  columns.add(columnName);
  logger.info({ tableName, columnName }, "[sites] publication schema repair column added");
}

async function reconcileSitePublication(prisma: PrismaClient, site: SiteLike, reason: string): Promise<ReconcileResult> {
  const slug = canonicalSlug(site);

  if (site.activePublicationId) {
    const active = await prisma.sitePublication.findFirst({
      where: { id: site.activePublicationId, siteId: site.id, status: "ACTIVE" },
    }) as PublicationLike | null;
    if (active && publicationHasRenderableManifest(active)) {
      return {
        siteId: site.id,
        slug,
        status: "HEALTHY",
        action: "none",
        activePublicationId: active.id,
        publicationStatus: active.status,
        routeVerified: true,
      };
    }
  }

  const activePublications = await prisma.sitePublication.findMany({
    where: { siteId: site.id, status: "ACTIVE" },
    orderBy: { versionNumber: "desc" },
  }) as PublicationLike[];
  const reusable = activePublications.find(publicationHasRenderableManifest)
    ?? await latestReusablePublication(prisma, site.id);

  if (reusable) {
    await prisma.$transaction(async (tx) => {
      await tx.sitePublication.updateMany({
        where: { siteId: site.id, status: "ACTIVE", NOT: { id: reusable.id } },
        data: { status: "SUPERSEDED" },
      });
      await tx.sitePublication.update({
        where: { id: reusable.id },
        data: {
          status: "ACTIVE",
          failureCode: null,
          failureMessage: null,
          publishedAt: reusable.publishedAt ?? new Date(),
        },
      });
      await tx.site.update({
        where: { id: site.id },
        data: {
          status: "PUBLISHED",
          activePublicationId: reusable.id,
          slug,
          publicAddress: `oneway://${slug}`,
          publishedAt: site.publishedAt ?? reusable.publishedAt ?? new Date(),
          visibility: publicVisibility(site.visibility),
        },
      });
    });
    console.info("SITE_PUBLICATION_SELF_HEAL_REPAIRED", { siteId: site.id, slug, publicationId: reusable.id, action: "activated_existing_publication" });
    return {
      siteId: site.id,
      slug,
      status: "REPAIRED",
      action: "activated_existing_publication",
      activePublicationId: reusable.id,
      publicationStatus: "ACTIVE",
      routeVerified: true,
    };
  }

  if (!hasPublishableDraft(site)) {
    return {
      siteId: site.id,
      slug,
      status: "REBUILD_REQUIRED",
      action: "none",
      activePublicationId: null,
      publicationStatus: null,
      routeVerified: false,
      failureCode: "missing_publishable_draft",
    };
  }

  const publication = await buildPublicationFromDraft(prisma, site, slug, reason);
  console.info("SITE_PUBLICATION_SELF_HEAL_REPAIRED", { siteId: site.id, slug, publicationId: publication.id, action: "built_from_draft" });
  return {
    siteId: site.id,
    slug,
    status: "REPAIRED",
    action: "built_from_draft",
    activePublicationId: publication.id,
    publicationStatus: "ACTIVE",
    routeVerified: true,
  };
}

async function latestReusablePublication(prisma: PrismaClient, siteId: string): Promise<PublicationLike | null> {
  const publications = await prisma.sitePublication.findMany({
    where: { siteId, status: { in: ["ACTIVE", "READY", "BUILT", "SUPERSEDED"] } },
    orderBy: { versionNumber: "desc" },
  }) as PublicationLike[];
  return publications.find(publicationHasRenderableManifest) ?? null;
}

async function buildPublicationFromDraft(
  prisma: PrismaClient,
  site: SiteLike,
  slug: string,
  reason: string,
): Promise<PublicationLike> {
  const versionNumber = await nextPublicationVersion(prisma, site.id);
  const html = renderPublishableHTML(site);
  const manifest = {
    siteId: site.id,
    domain: site.domain,
    slug,
    publicAddress: `oneway://${slug}`,
    publicWebAddress: `https://sites.oneway.app/${slug}`,
    title: site.title,
    description: site.description,
    html,
    blocks: safeParseArray(site.blocksJson),
    homepage: "home",
    visibility: publicVisibility(site.visibility),
    publishedAt: new Date().toISOString(),
    cacheVersion: `${versionNumber}-${Date.now()}`,
    reconciliationReason: reason,
  };
  if (!String(manifest.html).trim() && manifest.blocks.length === 0) {
    throw new Error("MISSING_HOMEPAGE");
  }

  const publication = await prisma.sitePublication.create({
    data: {
      siteId: site.id,
      versionNumber,
      status: "READY",
      publishedBy: site.userId,
      publishedAt: new Date(),
      sourceDraftVersion: Number(site.draftVersion ?? 1),
      contentManifest: JSON.stringify(manifest),
      assetManifest: JSON.stringify({ assetIds: [], variants: [] }),
      publicAddress: `oneway://${slug}`,
      buildStartedAt: new Date(),
      buildCompletedAt: new Date(),
    },
  }) as PublicationLike;

  await prisma.$transaction(async (tx) => {
    await tx.sitePublication.updateMany({
      where: { siteId: site.id, status: "ACTIVE" },
      data: { status: "SUPERSEDED" },
    });
    await tx.sitePublication.update({
      where: { id: publication.id },
      data: { status: "ACTIVE" },
    });
    await tx.site.update({
      where: { id: site.id },
      data: {
        status: "PUBLISHED",
        activePublicationId: publication.id,
        publishedHtml: html,
        publishedAt: new Date(),
        slug,
        publicAddress: `oneway://${slug}`,
        visibility: publicVisibility(site.visibility),
      },
    });
  });

  return { ...publication, status: "ACTIVE" };
}

async function nextPublicationVersion(prisma: PrismaClient, siteId: string): Promise<number> {
  const latest = await prisma.sitePublication.findFirst({
    where: { siteId },
    orderBy: { versionNumber: "desc" },
  });
  return Number(latest?.versionNumber ?? 0) + 1;
}

function canonicalSlug(site: SiteLike): string {
  return slugFromValue(site.slug || site.domain || site.title || "site");
}

function slugFromValue(value: string): string {
  return String(value)
    .trim()
    .toLowerCase()
    .replace(/^oneway:\/\/site\//, "")
    .replace(/^oneway:\/\//, "")
    .replace(/^https?:\/\/sites\.oneway\.app\//, "")
    .replace(/\.oneway\.(app|site)$/, "")
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "site";
}

function publicVisibility(value: string | null | undefined): string {
  return value === "UNLISTED" ? "UNLISTED" : "PUBLIC";
}

function hasPublishableDraft(site: SiteLike): boolean {
  if (!site.title.trim()) return false;
  if (String(site.publishedHtml ?? "").trim()) return true;
  if (String(site.html ?? "").trim()) return true;
  return safeParseArray(site.blocksJson).length > 0;
}

function renderPublishableHTML(site: SiteLike): string {
  const existing = String(site.publishedHtml ?? "").trim();
  if (existing) return existing;
  const customHTML = String(site.html ?? "").trim();
  if (customHTML) return wrapHTML(customHTML, site);
  const blocks = safeParseArray(site.blocksJson);
  return wrapHTML(`<main class="page">${blocks.map(renderBlock).join("\n")}</main>`, site);
}

function renderBlock(raw: unknown): string {
  if (!raw || typeof raw !== "object") return "";
  const block = raw as Record<string, unknown>;
  const type = String(block.type ?? "");
  if (type === "hero") {
    return `<section class="hero"><p class="eyebrow">${escapeText(String(block.eyebrow ?? "OneWay Site"))}</p><h1>${escapeText(String(block.title ?? "Welcome"))}</h1><p>${escapeText(String(block.subtitle ?? ""))}</p></section>`;
  }
  if (type === "services") {
    const items = Array.isArray(block.items) ? block.items : [];
    return `<section class="card"><h2>${escapeText(String(block.title ?? "Services"))}</h2>${items.map((item) => {
      const object = item && typeof item === "object" ? item as Record<string, unknown> : {};
      return `<article><h3>${escapeText(String(object.title ?? ""))}</h3><p>${escapeText(String(object.detail ?? ""))}</p></article>`;
    }).join("")}</section>`;
  }
  if (type === "contact") {
    return `<section class="card" id="contact"><h2>Contact</h2><p>${escapeText(String(block.name ?? ""))}</p><p>${escapeText(String(block.email ?? ""))}</p><p>${escapeText(String(block.phone ?? ""))}</p></section>`;
  }
  if (type === "button") {
    return `<section class="cta"><a href="${escapeAttr(String(block.url ?? "#"))}">${escapeText(String(block.label ?? "Learn more"))}</a></section>`;
  }
  return `<section class="card"><h2>${escapeText(String(block.title ?? "Details"))}</h2><p>${escapeText(String(block.text ?? block.body ?? ""))}</p></section>`;
}

function wrapHTML(body: string, site: Pick<SiteLike, "title" | "description" | "domain">): string {
  const html = body.trim().toLowerCase().includes("<html") ? body : `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeText(site.title)}</title>
  <meta name="description" content="${escapeAttr(site.description)}">
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Inter", sans-serif; color: #171321; background: #fafafc; }
    .page { min-height: 100vh; }
    section { padding: 56px 22px; max-width: 1040px; margin: 0 auto; }
    .hero { background: linear-gradient(135deg, #151021, #5b2dd8); color: white; max-width: none; padding: 84px 22px; }
    .hero > * { max-width: 920px; margin-left: auto; margin-right: auto; }
    .hero h1 { font-size: clamp(2.4rem, 8vw, 5rem); line-height: .95; margin: 12px auto; }
    .hero p { font-size: 1.15rem; color: rgba(255,255,255,.84); }
    .eyebrow { text-transform: uppercase; letter-spacing: .12em; font-weight: 800; }
    .card { background: white; border: 1px solid #e4d9fa; border-radius: 24px; margin-top: 26px; box-shadow: 0 18px 44px rgba(48, 34, 85, .12); }
    .cta a { display: inline-flex; background: linear-gradient(135deg, #7b3ff2, #a855f7); color: white; padding: 14px 22px; border-radius: 999px; text-decoration: none; font-weight: 800; }
  </style>
</head>
<body>${body}</body>
</html>`;
  return html;
}

function publicationHasRenderableManifest(publication: PublicationLike): boolean {
  const manifest = safeParseObject(publication.contentManifest);
  return Boolean(String(manifest.html ?? "").trim() || Array.isArray(manifest.blocks));
}

function safeParseArray(raw: string): unknown[] {
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function safeParseObject(raw: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function escapeText(value: string): string {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeAttr(value: string): string {
  return escapeText(value).replace(/"/g, "&quot;");
}
