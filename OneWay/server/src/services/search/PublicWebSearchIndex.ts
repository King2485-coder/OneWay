import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";

export type PublicWebIndexPageInput = {
  url: string;
  normalizedUrl: string;
  host: string;
  title: string | null;
  description: string | null;
  textSnippet: string | null;
  contentHash: string | null;
  statusCode: number | null;
  contentType: string | null;
  language: string | null;
};

export type PublicWebSearchResult = {
  id: string;
  title: string;
  subtitle: string | null;
  kind: "publicWeb";
  url: string;
  category: string | null;
  crawledAt: string;
  host: string;
};

export type PublicWebCrawlJob = {
  id: string;
  status: "queued" | "running" | "completed" | "failed";
  seedUrlsJson: string;
  maxPages: number;
  maxDepth: number;
  pagesVisited: number;
  pagesIndexed: number;
  pagesSkipped: number;
  error: string | null;
  startedAt: string | null;
  completedAt: string | null;
  createdAt: string;
  updatedAt: string;
};

type PublicWebPageRow = {
  id: string;
  url: string;
  normalizedUrl: string;
  host: string;
  title: string | null;
  description: string | null;
  textSnippet: string | null;
  lastCrawledAt: string;
};

type PublicWebStatsRow = {
  pageCount: bigint | number;
  hostCount: bigint | number;
  lastCrawledAt: string | null;
};

export class PublicWebSearchIndex {
  private initPromise: Promise<void> | null = null;

  constructor(private readonly prisma: PrismaClient) {}

  async initialize(): Promise<void> {
    if (!this.initPromise) {
      this.initPromise = this.createTables();
    }
    await this.initPromise;
  }

  async upsertPage(input: PublicWebIndexPageInput): Promise<void> {
    await this.initialize();
    const now = new Date().toISOString();
    await this.prisma.$executeRawUnsafe(
      `INSERT INTO PublicWebPage (
        id, url, normalizedUrl, host, title, description, textSnippet,
        contentHash, statusCode, contentType, language, lastCrawledAt,
        createdAt, updatedAt
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(normalizedUrl) DO UPDATE SET
        url = excluded.url,
        host = excluded.host,
        title = excluded.title,
        description = excluded.description,
        textSnippet = excluded.textSnippet,
        contentHash = excluded.contentHash,
        statusCode = excluded.statusCode,
        contentType = excluded.contentType,
        language = excluded.language,
        lastCrawledAt = excluded.lastCrawledAt,
        updatedAt = excluded.updatedAt`,
      randomUUID(),
      input.url,
      input.normalizedUrl,
      input.host,
      input.title,
      input.description,
      input.textSnippet,
      input.contentHash,
      input.statusCode,
      input.contentType,
      input.language,
      now,
      now,
      now
    );
  }

  async createJob(input: { seedUrls: string[]; maxPages: number; maxDepth: number }): Promise<PublicWebCrawlJob> {
    await this.initialize();
    const now = new Date().toISOString();
    const id = randomUUID();
    await this.prisma.$executeRawUnsafe(
      `INSERT INTO PublicWebCrawlJob (
        id, status, seedUrlsJson, maxPages, maxDepth, pagesVisited,
        pagesIndexed, pagesSkipped, error, startedAt, completedAt,
        createdAt, updatedAt
      ) VALUES (?, 'queued', ?, ?, ?, 0, 0, 0, NULL, NULL, NULL, ?, ?)`,
      id,
      JSON.stringify(input.seedUrls),
      input.maxPages,
      input.maxDepth,
      now,
      now
    );
    const job = await this.getJob(id);
    if (!job) throw new Error("crawl_job_create_failed");
    return job;
  }

  async getJob(id: string): Promise<PublicWebCrawlJob | null> {
    await this.initialize();
    const rows = await this.prisma.$queryRawUnsafe<PublicWebCrawlJob[]>(
      `SELECT * FROM PublicWebCrawlJob WHERE id = ? LIMIT 1`,
      id
    );
    return rows[0] ?? null;
  }

  async recentJobs(limit = 10): Promise<PublicWebCrawlJob[]> {
    await this.initialize();
    return this.prisma.$queryRawUnsafe<PublicWebCrawlJob[]>(
      `SELECT * FROM PublicWebCrawlJob ORDER BY createdAt DESC LIMIT ?`,
      limit
    );
  }

  async updateJob(
    id: string,
    patch: Partial<Pick<PublicWebCrawlJob,
      "status" | "pagesVisited" | "pagesIndexed" | "pagesSkipped" | "error" | "startedAt" | "completedAt"
    >>
  ): Promise<void> {
    await this.initialize();
    const entries = Object.entries(patch).filter(([, value]) => value !== undefined);
    if (entries.length === 0) return;
    const assignments = entries.map(([key]) => `${key} = ?`).join(", ");
    const values = entries.map(([, value]) => value);
    await this.prisma.$executeRawUnsafe(
      `UPDATE PublicWebCrawlJob SET ${assignments}, updatedAt = ? WHERE id = ?`,
      ...values,
      new Date().toISOString(),
      id
    );
  }

  async search(query: string, limit = 20): Promise<PublicWebSearchResult[]> {
    await this.initialize();
    const terms = tokenize(query).slice(0, 8);
    if (terms.length === 0) return [];

    const like = `%${escapeLike(query.trim())}%`;
    const rows = await this.prisma.$queryRawUnsafe<PublicWebPageRow[]>(
      `SELECT id, url, normalizedUrl, host, title, description, textSnippet, lastCrawledAt
       FROM PublicWebPage
       WHERE title LIKE ? ESCAPE '\\'
          OR description LIKE ? ESCAPE '\\'
          OR textSnippet LIKE ? ESCAPE '\\'
          OR host LIKE ? ESCAPE '\\'
       ORDER BY lastCrawledAt DESC
       LIMIT 120`,
      like,
      like,
      like,
      like
    );

    return rows
      .map((row) => ({ row, score: scoreRow(row, terms) }))
      .filter(({ score }) => score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map(({ row }) => ({
        id: row.id,
        title: row.title || row.host,
        subtitle: row.description || row.textSnippet || row.host,
        kind: "publicWeb" as const,
        url: row.url,
        category: "Public Web",
        crawledAt: row.lastCrawledAt,
        host: row.host,
      }));
  }

  async stats(): Promise<{ pageCount: number; hostCount: number; lastCrawledAt: string | null }> {
    await this.initialize();
    const rows = await this.prisma.$queryRawUnsafe<PublicWebStatsRow[]>(
      `SELECT COUNT(*) AS pageCount, COUNT(DISTINCT host) AS hostCount, MAX(lastCrawledAt) AS lastCrawledAt
       FROM PublicWebPage`
    );
    const row = rows[0];
    return {
      pageCount: Number(row?.pageCount ?? 0),
      hostCount: Number(row?.hostCount ?? 0),
      lastCrawledAt: row?.lastCrawledAt ?? null,
    };
  }

  private async createTables(): Promise<void> {
    await this.prisma.$executeRawUnsafe(
      `CREATE TABLE IF NOT EXISTS PublicWebPage (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        normalizedUrl TEXT NOT NULL UNIQUE,
        host TEXT NOT NULL,
        title TEXT,
        description TEXT,
        textSnippet TEXT,
        contentHash TEXT,
        statusCode INTEGER,
        contentType TEXT,
        language TEXT,
        lastCrawledAt TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )`
    );
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS PublicWebPage_host_idx ON PublicWebPage(host)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS PublicWebPage_lastCrawledAt_idx ON PublicWebPage(lastCrawledAt)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS PublicWebPage_title_idx ON PublicWebPage(title)`);
    await this.prisma.$executeRawUnsafe(
      `CREATE TABLE IF NOT EXISTS PublicWebCrawlJob (
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        seedUrlsJson TEXT NOT NULL,
        maxPages INTEGER NOT NULL,
        maxDepth INTEGER NOT NULL,
        pagesVisited INTEGER NOT NULL DEFAULT 0,
        pagesIndexed INTEGER NOT NULL DEFAULT 0,
        pagesSkipped INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        startedAt TEXT,
        completedAt TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )`
    );
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS PublicWebCrawlJob_createdAt_idx ON PublicWebCrawlJob(createdAt)`);
    await this.prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS PublicWebCrawlJob_status_idx ON PublicWebCrawlJob(status)`);
  }
}

function tokenize(value: string): string[] {
  return value
    .toLowerCase()
    .split(/[^a-z0-9]+/i)
    .map((term) => term.trim())
    .filter((term) => term.length >= 2);
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (match) => `\\${match}`);
}

function scoreRow(row: PublicWebPageRow, terms: string[]): number {
  const title = (row.title ?? "").toLowerCase();
  const description = (row.description ?? "").toLowerCase();
  const body = (row.textSnippet ?? "").toLowerCase();
  const host = row.host.toLowerCase();
  let score = 0;

  for (const term of terms) {
    if (title.includes(term)) score += 8;
    if (description.includes(term)) score += 4;
    if (host.includes(term)) score += 3;
    if (body.includes(term)) score += 1;
  }

  if (title === terms.join(" ")) score += 20;
  if (host.includes(terms[0])) score += 2;
  return score;
}
