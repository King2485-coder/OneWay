import express from "express";
import { z } from "zod";

import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import type { PublicWebCrawler } from "../services/search/PublicWebCrawler";

const startSchema = z.object({
  seeds: z.array(z.string().min(1)).min(1).max(100).optional(),
  maxPages: z.number().int().min(1).max(2_000).optional(),
  maxDepth: z.number().int().min(0).max(8).optional(),
  force: z.boolean().optional(),
});

export function searchCrawlRouter({ crawler }: { crawler: PublicWebCrawler }): express.Router {
  const router = express.Router();

  router.use(requireCrawlerAccess);

  router.get("/status", requireCrawlerAdmin, async (_req, res) => {
    res.json({ ok: true, ...(await crawler.stats()) });
  });

  router.post("/start", requireCrawlerAdmin, async (req, res) => {
    const parsed = startSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "bad_request", issues: parsed.error.issues });
      return;
    }

    const seeds = parsed.data.seeds ?? envSeeds();
    if (seeds.length === 0) {
      res.status(400).json({
        error: "crawl_seed_required",
        message: "Provide seeds in the request body or set ONEWAY_SEARCH_SEEDS.",
      });
      return;
    }

    try {
      const job = await crawler.start({
        seeds,
        maxPages: parsed.data.maxPages,
        maxDepth: parsed.data.maxDepth,
        force: parsed.data.force,
      });
      res.status(202).json({ ok: true, job });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      res.status(400).json({ error: message });
    }
  });

  return router;
}

function requireCrawlerAccess(req: express.Request, res: express.Response, next: express.NextFunction): void {
  if (hasValidCrawlerAdminToken(req)) {
    next();
    return;
  }

  authMiddleware(req, res, () => requireCrawlerAdmin(req, res, next));
}

function requireCrawlerAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  if (hasValidCrawlerAdminToken(req)) {
    next();
    return;
  }

  if (process.env.NODE_ENV !== "production" && (req as AuthenticatedRequest).authMode === "dev") {
    next();
    return;
  }

  res.status(403).json({
    error: "crawler_admin_required",
    message: "Public web crawling is protected. Use a crawler admin token or dev auth locally.",
  });
}

function hasValidCrawlerAdminToken(req: express.Request): boolean {
  const adminToken = process.env.ONEWAY_SEARCH_ADMIN_TOKEN;
  const provided = req.headers["x-oneway-search-admin-token"];
  const providedToken = Array.isArray(provided) ? provided[0] : provided;
  return Boolean(adminToken && providedToken === adminToken);
}

function envSeeds(): string[] {
  return (process.env.ONEWAY_SEARCH_SEEDS ?? "")
    .split(",")
    .map((seed) => seed.trim())
    .filter(Boolean);
}
