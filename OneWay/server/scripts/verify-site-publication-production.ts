const baseURL = (process.env.PRODUCTION_API_BASE_URL ?? "https://api.oneway.is").replace(/\/+$/, "");
const slug = process.env.SITE_PUBLICATION_SMOKE_SLUG ?? "kinglogistics";
const expectedRouteVersion = process.env.SITE_PUBLICATION_ROUTE_VERSION ?? "site-publication-active-v2";
const requirePublished = process.env.REQUIRE_SITE_PUBLISHED !== "false";

type JsonObject = Record<string, unknown>;

async function readResponse(path: string, init?: RequestInit): Promise<{ status: number; text: string; json: JsonObject | null }> {
  const response = await fetch(`${baseURL}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init?.headers ?? {}),
    },
  });
  const text = await response.text();
  let json: JsonObject | null = null;
  try {
    json = text ? JSON.parse(text) as JsonObject : null;
  } catch {
    json = null;
  }
  return { status: response.status, text, json };
}

function fail(message: string, details?: unknown): never {
  console.error("SITE_PUBLICATION_PRODUCTION_SMOKE_FAILED", JSON.stringify({ message, details }, null, 2));
  process.exit(1);
}

function assertNotLegacyCannotGet(path: string, result: { status: number; text: string }): void {
  if (result.status === 404 && /Cannot GET/i.test(result.text)) {
    fail("Production is still serving the old Express route set.", { path, status: result.status, body: result.text.slice(0, 300) });
  }
}

async function main(): Promise<void> {
  const health = await readResponse("/health");
  if (health.status !== 200) {
    fail("Health check did not return HTTP 200.", { status: health.status, body: health.text.slice(0, 500) });
  }
  if (health.json?.sitePublicationRouteVersion !== expectedRouteVersion) {
    fail("Production API is not running the required Site publication route version.", {
      expectedRouteVersion,
      actualRouteVersion: health.json?.sitePublicationRouteVersion ?? null,
    });
  }

  const publicResolver = await readResponse(`/api/oneway/sites/${encodeURIComponent(slug)}`);
  assertNotLegacyCannotGet(`/api/oneway/sites/${slug}`, publicResolver);
  if (requirePublished && publicResolver.status !== 200) {
    fail("Public OneWay Site resolver did not return HTTP 200.", {
      slug,
      status: publicResolver.status,
      body: publicResolver.text.slice(0, 800),
    });
  }

  const legacyResolver = await readResponse(`/api/sites/${encodeURIComponent(slug)}/public`);
  assertNotLegacyCannotGet(`/api/sites/${slug}/public`, legacyResolver);
  if (requirePublished && legacyResolver.status !== 200) {
    fail("Legacy public Site resolver did not return HTTP 200.", {
      slug,
      status: legacyResolver.status,
      body: legacyResolver.text.slice(0, 800),
    });
  }

  console.log("SITE_PUBLICATION_PRODUCTION_SMOKE_PASSED", JSON.stringify({
    baseURL,
    slug,
    routeVersion: health.json?.sitePublicationRouteVersion,
    publicResolverStatus: publicResolver.status,
    legacyResolverStatus: legacyResolver.status,
  }, null, 2));
}

main().catch((error) => {
  fail("Production smoke test crashed.", error instanceof Error ? { message: error.message, stack: error.stack } : error);
});
