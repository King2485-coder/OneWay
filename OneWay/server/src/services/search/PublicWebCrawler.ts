import type { PrismaClient } from "@prisma/client";
import { createHash } from "node:crypto";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

import { logger } from "../../lib/logger";
import { PublicWebSearchIndex, type PublicWebCrawlJob } from "./PublicWebSearchIndex";

export type PublicWebCrawlInput = {
  seeds: string[];
  maxPages?: number;
  maxDepth?: number;
  force?: boolean;
};

type QueueItem = {
  url: URL;
  depth: number;
};

type RobotsRules = {
  fetchedAt: number;
  crawlDelayMs: number | null;
  rules: Array<{ directive: "allow" | "disallow"; path: string }>;
};

type FetchPageResult = {
  finalUrl: URL;
  statusCode: number;
  contentType: string;
  robotsTag: string;
  html: string;
};

type ParsedHTML = {
  title: string | null;
  description: string | null;
  textSnippet: string | null;
  language: string | null;
  noindex: boolean;
  nofollow: boolean;
  links: URL[];
};

const DEFAULT_USER_AGENT = "OneWayBot/0.1 (+https://search.oneway.app/bot)";
const DEFAULT_MAX_PAGES = 50;
const DEFAULT_MAX_DEPTH = 1;
const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_BYTES = 1_500_000;
const DEFAULT_CRAWL_DELAY_MS = 1_200;

export class PublicWebCrawler {
  private readonly index: PublicWebSearchIndex;
  private readonly robotsCache = new Map<string, RobotsRules>();
  private readonly lastFetchByHost = new Map<string, number>();
  private readonly runningJobs = new Set<string>();

  constructor(private readonly prisma: PrismaClient) {
    this.index = new PublicWebSearchIndex(prisma);
  }

  async initialize(): Promise<void> {
    await this.index.initialize();
  }

  async start(input: PublicWebCrawlInput): Promise<PublicWebCrawlJob> {
    const seeds = normalizeSeedUrls(input.seeds);
    if (seeds.length === 0) {
      throw new Error("crawl_seed_required");
    }

    const job = await this.index.createJob({
      seedUrls: seeds.map((url) => url.toString()),
      maxPages: clampInt(input.maxPages, DEFAULT_MAX_PAGES, 1, 2_000),
      maxDepth: clampInt(input.maxDepth, DEFAULT_MAX_DEPTH, 0, 8),
    });

    void this.runJob(job.id, seeds, {
      maxPages: job.maxPages,
      maxDepth: job.maxDepth,
      force: Boolean(input.force),
    });

    return job;
  }

  async stats() {
    const [indexStats, jobs] = await Promise.all([
      this.index.stats(),
      this.index.recentJobs(10),
    ]);
    return {
      ...indexStats,
      runningJobs: Array.from(this.runningJobs),
      recentJobs: jobs,
    };
  }

  async search(query: string, limit = 20) {
    return this.index.search(query, limit);
  }

  private async runJob(
    jobId: string,
    seeds: URL[],
    options: { maxPages: number; maxDepth: number; force: boolean }
  ): Promise<void> {
    if (this.runningJobs.has(jobId)) return;
    this.runningJobs.add(jobId);

    let pagesVisited = 0;
    let pagesIndexed = 0;
    let pagesSkipped = 0;

    try {
      await this.index.updateJob(jobId, {
        status: "running",
        startedAt: new Date().toISOString(),
      });

      const queue: QueueItem[] = seeds.map((url) => ({ url, depth: 0 }));
      const seen = new Set<string>();

      while (queue.length > 0 && pagesVisited < options.maxPages) {
        const item = queue.shift()!;
        const normalized = normalizeCrawlURL(item.url);
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);

        try {
          await this.assertPublicURL(item.url);
          if (!options.force && !(await this.canFetch(item.url))) {
            pagesSkipped += 1;
            continue;
          }

          await this.waitForHostPacing(item.url);
          const fetched = await this.fetchHTML(item.url);
          pagesVisited += 1;

          const robotsHeader = fetched.robotsTag.toLowerCase();
          const parsed = parseHTML(fetched.html, fetched.finalUrl);
          const headerRobots = robotsHeader.includes("noindex") || robotsHeader.includes("nofollow");
          if (!parsed.noindex && !headerRobots) {
            await this.index.upsertPage({
              url: fetched.finalUrl.toString(),
              normalizedUrl: normalizeCrawlURL(fetched.finalUrl) ?? fetched.finalUrl.toString(),
              host: fetched.finalUrl.host.toLowerCase(),
              title: parsed.title,
              description: parsed.description,
              textSnippet: parsed.textSnippet,
              contentHash: createHash("sha256").update(fetched.html).digest("hex"),
              statusCode: fetched.statusCode,
              contentType: fetched.contentType,
              language: parsed.language,
            });
            pagesIndexed += 1;
          } else {
            pagesSkipped += 1;
          }

          if (!parsed.nofollow && item.depth < options.maxDepth) {
            for (const link of parsed.links) {
              const linkKey = normalizeCrawlURL(link);
              if (linkKey && !seen.has(linkKey) && queue.length < options.maxPages * 20) {
                queue.push({ url: link, depth: item.depth + 1 });
              }
            }
          }
        } catch (error) {
          pagesSkipped += 1;
          logger.debug({ err: error, url: item.url.toString(), jobId }, "[search:crawler] skipped url");
        }

        await this.index.updateJob(jobId, {
          pagesVisited,
          pagesIndexed,
          pagesSkipped,
        });
      }

      await this.index.updateJob(jobId, {
        status: "completed",
        pagesVisited,
        pagesIndexed,
        pagesSkipped,
        completedAt: new Date().toISOString(),
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.index.updateJob(jobId, {
        status: "failed",
        pagesVisited,
        pagesIndexed,
        pagesSkipped,
        error: message,
        completedAt: new Date().toISOString(),
      });
      logger.error({ err: error, jobId }, "[search:crawler] job failed");
    } finally {
      this.runningJobs.delete(jobId);
    }
  }

  private async fetchHTML(url: URL, redirects = 0): Promise<FetchPageResult> {
    if (redirects > 5) throw new Error("too_many_redirects");
    await this.assertPublicURL(url);

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), envInt("ONEWAY_CRAWLER_TIMEOUT_MS", DEFAULT_TIMEOUT_MS));
    try {
      const response = await fetch(url, {
        redirect: "manual",
        signal: controller.signal,
        headers: {
          "User-Agent": process.env.ONEWAY_CRAWLER_USER_AGENT || DEFAULT_USER_AGENT,
          "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.2",
        },
      });

      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("location");
        if (!location) throw new Error("redirect_without_location");
        return this.fetchHTML(new URL(location, url), redirects + 1);
      }

      const contentType = response.headers.get("content-type") || "";
      if (!contentType.toLowerCase().includes("text/html") && !contentType.toLowerCase().includes("application/xhtml+xml")) {
        throw new Error(`unsupported_content_type:${contentType || "unknown"}`);
      }

      const contentLength = Number(response.headers.get("content-length") || 0);
      const maxBytes = envInt("ONEWAY_CRAWLER_MAX_BYTES", DEFAULT_MAX_BYTES);
      if (contentLength > maxBytes) throw new Error("response_too_large");
      if (!response.ok) throw new Error(`http_${response.status}`);

      const html = await response.text();
      if (Buffer.byteLength(html, "utf8") > maxBytes) throw new Error("response_too_large");
      return {
        finalUrl: new URL(response.url || url.toString()),
        statusCode: response.status,
        contentType,
        robotsTag: response.headers.get("x-robots-tag") || "",
        html,
      };
    } finally {
      clearTimeout(timeout);
    }
  }

  private async canFetch(url: URL): Promise<boolean> {
    if (process.env.ONEWAY_CRAWLER_RESPECT_ROBOTS === "false") return true;
    const robots = await this.getRobots(url);
    const path = `${url.pathname || "/"}${url.search || ""}`;
    let winner: { directive: "allow" | "disallow"; path: string } | null = null;

    for (const rule of robots.rules) {
      if (!rule.path) continue;
      if (path.startsWith(rule.path) && (!winner || rule.path.length > winner.path.length)) {
        winner = rule;
      }
    }

    return winner?.directive !== "disallow";
  }

  private async getRobots(url: URL): Promise<RobotsRules> {
    const origin = url.origin;
    const cached = this.robotsCache.get(origin);
    if (cached && Date.now() - cached.fetchedAt < 60 * 60 * 1000) return cached;

    const fallback: RobotsRules = { fetchedAt: Date.now(), crawlDelayMs: null, rules: [] };
    try {
      const robotsURL = new URL("/robots.txt", origin);
      await this.assertPublicURL(robotsURL);
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 5_000);
      try {
        const response = await fetch(robotsURL, {
          signal: controller.signal,
          headers: { "User-Agent": process.env.ONEWAY_CRAWLER_USER_AGENT || DEFAULT_USER_AGENT },
        });
        if (!response.ok) {
          this.robotsCache.set(origin, fallback);
          return fallback;
        }
        const body = await response.text();
        const parsed = parseRobots(body);
        this.robotsCache.set(origin, parsed);
        return parsed;
      } finally {
        clearTimeout(timeout);
      }
    } catch {
      this.robotsCache.set(origin, fallback);
      return fallback;
    }
  }

  private async waitForHostPacing(url: URL): Promise<void> {
    const robots = await this.getRobots(url);
    const delay = Math.max(
      robots.crawlDelayMs ?? 0,
      envInt("ONEWAY_CRAWLER_DELAY_MS", DEFAULT_CRAWL_DELAY_MS)
    );
    const key = url.host.toLowerCase();
    const last = this.lastFetchByHost.get(key) ?? 0;
    const elapsed = Date.now() - last;
    if (elapsed < delay) await sleep(delay - elapsed);
    this.lastFetchByHost.set(key, Date.now());
  }

  private async assertPublicURL(url: URL): Promise<void> {
    if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("unsupported_protocol");
    const host = url.hostname.toLowerCase();
    if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
      throw new Error("private_host_blocked");
    }

    const literalVersion = isIP(host);
    if (literalVersion && isPrivateIP(host)) throw new Error("private_ip_blocked");

    if (!literalVersion) {
      const addresses = await lookup(host, { all: true, verbatim: false });
      if (addresses.some((address) => isPrivateIP(address.address))) {
        throw new Error("private_dns_target_blocked");
      }
    }
  }
}

function normalizeSeedUrls(seeds: string[]): URL[] {
  const urls: URL[] = [];
  const seen = new Set<string>();
  for (const seed of seeds) {
    const trimmed = seed.trim();
    if (!trimmed) continue;
    const candidate = trimmed.includes("://") ? trimmed : `https://${trimmed}`;
    try {
      const url = new URL(candidate);
      if (url.protocol !== "http:" && url.protocol !== "https:") continue;
      const key = normalizeCrawlURL(url);
      if (key && !seen.has(key)) {
        seen.add(key);
        urls.push(url);
      }
    } catch {
      // Ignore malformed seed URLs; the route validates that at least one survived.
    }
  }
  return urls.slice(0, 100);
}

function normalizeCrawlURL(url: URL): string | null {
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  const clone = new URL(url.toString());
  clone.hash = "";
  clone.hostname = clone.hostname.toLowerCase();
  for (const key of Array.from(clone.searchParams.keys())) {
    if (/^(utm_|fbclid$|gclid$|mc_)/i.test(key)) clone.searchParams.delete(key);
  }
  const value = clone.toString();
  return value.endsWith("/") && clone.pathname === "/" && !clone.search ? value.slice(0, -1) : value;
}

function parseHTML(html: string, baseURL: URL): ParsedHTML {
  const head = html.slice(0, 120_000);
  const title = extractFirst(head, /<title[^>]*>([\s\S]*?)<\/title>/i);
  const description = extractMeta(head, "description") || extractMeta(head, "og:description");
  const robots = [extractMeta(head, "robots"), extractMeta(head, "googlebot")].filter(Boolean).join(",").toLowerCase();
  const language = extractFirst(head, /<html[^>]+lang=["']?([^"'\s>]+)/i);
  const noindex = robots.includes("noindex") || robots.includes("none");
  const nofollow = robots.includes("nofollow") || robots.includes("none");
  const textSnippet = htmlToText(html).slice(0, 4_000);
  const links = extractLinks(html, baseURL).slice(0, 100);

  return {
    title: cleanText(title),
    description: cleanText(description),
    textSnippet: cleanText(textSnippet),
    language: cleanText(language),
    noindex,
    nofollow,
    links,
  };
}

function extractLinks(html: string, baseURL: URL): URL[] {
  const links: URL[] = [];
  const seen = new Set<string>();
  const anchorPattern = /<a\s+[^>]*href=["']([^"']+)["'][^>]*>/gi;
  let match: RegExpExecArray | null;
  while ((match = anchorPattern.exec(html)) !== null && links.length < 160) {
    const href = decodeHTML(match[1]).trim();
    if (!href || /^(mailto:|tel:|sms:|javascript:|data:|blob:)/i.test(href)) continue;
    try {
      const url = new URL(href, baseURL);
      const key = normalizeCrawlURL(url);
      if (key && !seen.has(key)) {
        seen.add(key);
        links.push(url);
      }
    } catch {
      // Skip malformed links.
    }
  }
  return links;
}

function parseRobots(body: string): RobotsRules {
  const groups: Array<{ agents: string[]; rules: RobotsRules["rules"]; crawlDelayMs: number | null }> = [];
  let current: { agents: string[]; rules: RobotsRules["rules"]; crawlDelayMs: number | null } | null = null;

  for (const rawLine of body.split(/\r?\n/)) {
    const line = rawLine.replace(/#.*/, "").trim();
    if (!line) continue;
    const [rawKey, ...valueParts] = line.split(":");
    const key = rawKey.trim().toLowerCase();
    const value = valueParts.join(":").trim();

    if (key === "user-agent") {
      if (!current || current.rules.length > 0) {
        current = { agents: [], rules: [], crawlDelayMs: null };
        groups.push(current);
      }
      current.agents.push(value.toLowerCase());
      continue;
    }

    if (!current) continue;
    if ((key === "allow" || key === "disallow") && value) {
      current.rules.push({ directive: key, path: value });
    } else if (key === "crawl-delay") {
      const seconds = Number(value);
      if (Number.isFinite(seconds) && seconds >= 0) current.crawlDelayMs = seconds * 1000;
    }
  }

  const selected = groups.find((group) => group.agents.some((agent) => agent.includes("onewaybot")))
    ?? groups.find((group) => group.agents.includes("*"));

  return {
    fetchedAt: Date.now(),
    crawlDelayMs: selected?.crawlDelayMs ?? null,
    rules: selected?.rules ?? [],
  };
}

function extractFirst(value: string, pattern: RegExp): string | null {
  const match = pattern.exec(value);
  return match?.[1] ?? null;
}

function extractMeta(head: string, name: string): string | null {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`<meta[^>]+(?:name|property)=["']${escaped}["'][^>]+content=["']([^"']*)["'][^>]*>`, "i");
  const reversePattern = new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+(?:name|property)=["']${escaped}["'][^>]*>`, "i");
  return extractFirst(head, pattern) ?? extractFirst(head, reversePattern);
}

function htmlToText(html: string): string {
  return decodeHTML(
    html
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
  ).trim();
}

function cleanText(value: string | null | undefined): string | null {
  const cleaned = decodeHTML(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned.length > 0 ? cleaned : null;
}

function decodeHTML(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number.parseInt(dec, 10)));
}

function isPrivateIP(address: string): boolean {
  const version = isIP(address);
  if (version === 4) {
    const parts = address.split(".").map(Number);
    const [a, b] = parts;
    return a === 10
      || a === 127
      || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || a === 0;
  }
  if (version === 6) {
    const normalized = address.toLowerCase();
    return normalized === "::1"
      || normalized.startsWith("fc")
      || normalized.startsWith("fd")
      || normalized.startsWith("fe80")
      || normalized.startsWith("::ffff:10.")
      || normalized.startsWith("::ffff:127.")
      || normalized.startsWith("::ffff:192.168.");
  }
  return false;
}

function clampInt(value: number | undefined, fallback: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(Math.max(Math.floor(Number(value)), min), max);
}

function envInt(key: string, fallback: number): number {
  const value = Number(process.env[key]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
