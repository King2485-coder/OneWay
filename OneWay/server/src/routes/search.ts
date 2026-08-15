import type { PrismaClient } from "@prisma/client";
import express from "express";
import { z } from "zod";

import { parseAuthToken } from "../middleware/auth";
import { getDevUserId } from "./helpers";
import { toStoreDTO, toProductDTO } from "../services/catalog";
import type { PublicWebCrawler } from "../services/search/PublicWebCrawler";

const querySchema = z.object({
  q: z.string().min(1),
  scope: z.enum(["shop", "manage"]).optional(),
  mode: z.enum(["api", "html"]).optional()
});

export function searchRouter({ prisma, crawler }: { prisma: PrismaClient; crawler?: PublicWebCrawler }) {
  const router = express.Router();

  router.get("/", async (req, res) => {
    const parsed = querySchema.safeParse(req.query);
    if (!parsed.success) return res.status(400).json({ error: "bad_request", issues: parsed.error.issues });

    const bearer = typeof req.headers.authorization === "string" && req.headers.authorization.startsWith("Bearer ")
      ? req.headers.authorization.slice("Bearer ".length).trim()
      : undefined;
    const maybeUserId = parseAuthToken(bearer) ?? getDevUserId(req);
    const rawQ = parsed.data.q.trim();
    const q = rawQ.toLowerCase();
    const manageScope = parsed.data.scope === "manage";

    const [stores, identities, publicWebResults] = await Promise.all([
      prisma.storefront.findMany({
        where: {
          ...(manageScope ? { ownerId: maybeUserId } : { published: true }),
          OR: [
            { name: { contains: q } },
            { category: { contains: q } },
            { slug: { contains: q } },
            { handle: { contains: q } },
            { description: { contains: q } },
            { tagline: { contains: q } }
          ]
        },
        include: {
          products: {
            where: manageScope ? undefined : { published: true },
          },
          collections: true,
          theme: true,
        },
        take: 25
      }),
      prisma.oneWayIdentity.findMany({
        where: {
          OR: [
            { displayName: { contains: rawQ } },
            { username: { contains: q } },
            { onewayId: { contains: normalizeOneWaySearchId(q) } },
            { emailAlias: { contains: q } }
          ]
        },
        include: {
          user: {
            include: {
              numbers: {
                orderBy: [{ isPrimary: "desc" }, { createdAt: "asc" }],
                take: 1
              }
            }
          }
        },
        take: 20
      }),
      parsed.data.scope
        ? Promise.resolve([])
        : crawler?.search(rawQ, 20).catch(() => []) ?? Promise.resolve([])
    ]);

    const results: OneWaySearchResult[] = [];
    for (const identity of identities) {
      results.push({
        id: cryptoRandomUUID(),
        title: identity.displayName || identity.onewayId,
        subtitle: identity.showOneWayId ? identity.onewayId : "OneWay profile",
        kind: "profile",
        url: `https://profile.oneway.app/${encodeURIComponent(identity.onewayId.replace(/^@/, ""))}`,
        category: "People",
        storefront: null,
        product: null,
        profile: {
          userId: identity.userId,
          displayName: identity.displayName,
          onewayId: identity.showOneWayId ? identity.onewayId : null,
          emailAlias: identity.showEmailAlias ? identity.emailAlias : null,
          username: identity.usernameHidden ? null : identity.username,
          primaryNumber: identity.showNumbers ? identity.user.numbers[0]?.number ?? null : null
        }
      });
    }

    for (const store of stores) {
      const storeDTO = toStoreDTO(store);
      results.push({
        id: cryptoRandomUUID(),
        title: store.name,
        subtitle: store.tagline || store.description || null,
        kind: "storefront",
        url: `https://${store.slug}.oneway.app`,
        storefront: storeDTO,
        product: null,
        profile: null,
        category: store.category
      });

      for (const product of store.products) {
        if (product.name.toLowerCase().includes(q) || product.description.toLowerCase().includes(q)) {
          results.push({
            id: cryptoRandomUUID(),
            title: product.name,
            subtitle: store.name,
            kind: "product",
            url: `https://${store.slug}.oneway.app/products/${product.id}`,
            storefront: storeDTO,
            product: toProductDTO(product),
            profile: null,
            category: store.category
          });
        }
      }
    }

    for (const page of publicWebResults) {
      results.push({
        id: page.id,
        title: page.title,
        subtitle: page.subtitle,
        kind: "publicWeb",
        url: page.url,
        storefront: null,
        product: null,
        profile: null,
        category: page.category,
      });
    }

    if (parsed.data.mode === "html" || wantsHTML(req)) {
      res.type("html").send(renderSearchHTML(rawQ, results));
      return;
    }

    if (parsed.data.scope) {
      res.json(results.filter((result) => result.kind === "storefront" || result.kind === "product"));
      return;
    }

    res.json({
      provider: "oneway",
      query: rawQ,
      results
    });
  });

  return router;
}

type OneWaySearchResult = {
  id: string;
  title: string;
  subtitle: string | null;
  kind: "profile" | "storefront" | "product" | "publicWeb";
  url: string;
  category: string | null;
  storefront: ReturnType<typeof toStoreDTO> | null;
  product: ReturnType<typeof toProductDTO> | null;
  profile: {
    userId: string;
    displayName: string | null;
    onewayId: string | null;
    emailAlias: string | null;
    username: string | null;
    primaryNumber: string | null;
  } | null;
};

function normalizeOneWaySearchId(value: string): string {
  const trimmed = value.trim().toLowerCase();
  return trimmed.startsWith("@") ? trimmed : `@${trimmed}`;
}

function wantsHTML(req: express.Request): boolean {
  const accept = req.headers.accept ?? "";
  return accept.includes("text/html") && !accept.includes("application/json");
}

function renderSearchHTML(query: string, results: OneWaySearchResult[]): string {
  const rows = results.map(renderResult).join("\n") || `
    <section class="empty">
      <h2>No OneWay results yet</h2>
      <p>OneWay Search is live, but this query has not matched people, domains, stores, products, or crawled public web pages yet.</p>
    </section>`;

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OneWay Search: ${escapeHTML(query)}</title>
  <style>
    *{box-sizing:border-box}body{margin:0;min-height:100vh;background:
    radial-gradient(circle at 16% 10%,rgba(245,197,66,.20),transparent 22rem),
    linear-gradient(135deg,#07030e,#16092d 56%,#2a1252);color:#f7f1ff;
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif}
    .shell{width:min(760px,100%);margin:0 auto;padding:38px 18px 72px}
    .eyebrow{letter-spacing:.18em;color:#f5c542;font-size:.7rem;font-weight:900}
    h1{font-size:clamp(2.2rem,10vw,4.8rem);line-height:.92;margin:.35rem 0 1rem;letter-spacing:-.07em}
    .searchbox{display:flex;gap:10px;margin:24px 0 22px}.searchbox input{min-width:0;flex:1;border:1px solid rgba(255,255,255,.14);
    background:rgba(255,255,255,.08);color:#fff;border-radius:18px;padding:14px 16px;font-size:1rem}
    .searchbox button{border:0;border-radius:18px;padding:0 18px;background:#2f7bff;color:white;font-weight:900}
    .meta{color:rgba(247,241,255,.65);line-height:1.5}.result{display:block;text-decoration:none;color:white;
    border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.075);border-radius:22px;padding:16px;margin:12px 0}
    .result:hover{background:rgba(255,255,255,.12)}.kind{display:inline-flex;margin-bottom:10px;padding:4px 9px;border-radius:999px;
    color:#f5c542;background:rgba(245,197,66,.13);font-size:.68rem;font-weight:900;letter-spacing:.1em}
    .result h2{font-size:1.2rem;margin:0 0 5px}.result p{margin:0;color:rgba(247,241,255,.68);line-height:1.4}
    .url{margin-top:10px;color:rgba(245,197,66,.82);font-size:.82rem;word-break:break-all}.empty{border:1px dashed rgba(255,255,255,.18);
    border-radius:24px;padding:22px;color:rgba(247,241,255,.72)}footer{margin-top:32px;color:rgba(247,241,255,.42);font-size:.78rem}
  </style>
</head>
<body>
  <main class="shell">
    <p class="eyebrow">ONEWAY SEARCH</p>
    <h1>Search without renting someone else's front door.</h1>
    <p class="meta">Results come from OneWay people, domains, storefronts, products, network content, and the growing public web index.</p>
    <form class="searchbox" action="/api/search" method="get">
      <input name="q" value="${escapeHTML(query)}" placeholder="Search OneWay">
      <input type="hidden" name="mode" value="html">
      <button type="submit">Search</button>
    </form>
    ${rows}
    <footer>OneWay Search provider: oneway</footer>
  </main>
</body>
</html>`;
}

function renderResult(result: OneWaySearchResult): string {
  return `<a class="result" href="${escapeHTML(result.url)}">
    <span class="kind">${escapeHTML(result.kind.toUpperCase())}</span>
    <h2>${escapeHTML(result.title)}</h2>
    <p>${escapeHTML(result.subtitle ?? result.category ?? "OneWay result")}</p>
    <div class="url">${escapeHTML(result.url)}</div>
  </a>`;
}

function escapeHTML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function cryptoRandomUUID(): string {
  // Node 18+ exposes crypto.randomUUID, but keep a tiny fallback.
  const c: any = globalThis.crypto as any;
  if (c?.randomUUID) return c.randomUUID();
  return "00000000-0000-0000-0000-000000000000";
}
