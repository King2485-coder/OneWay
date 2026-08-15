import dns from "node:dns/promises";
import https from "node:https";

const slug = process.env.ONEWAY_SITE_SMOKE_SLUG ?? "kinglogistics";
const apiBaseURL = (process.env.ONEWAY_API_BASE_URL ?? "https://api.oneway.is").replace(/\/+$/, "");
const publicURL = `https://sites.oneway.app/${slug}`;

async function main() {
  const dnsResult = await resolvePublicDNS("sites.oneway.app");
  const api = await fetchJSON(`${apiBaseURL}/api/oneway/sites/${encodeURIComponent(slug)}`);
  const publicPage = await fetchText(publicURL);

  const apiPublicationId = String(api.publicationId ?? api.activePublicationId ?? "");
  const apiStatus = String(api.siteStatus ?? "");
  const publicationStatus = String(api.publicationStatus ?? "");
  const bodyContainsSite = publicPage.body.includes(String(api.title ?? "King Logistics"))
    || publicPage.body.includes("King Logistics");

  const result = {
    slug,
    publicURL,
    dns: dnsResult,
    tlsAuthorized: publicPage.tlsAuthorized,
    tlsAuthorizationError: publicPage.tlsAuthorizationError,
    publicHTTPStatus: publicPage.status,
    publicContentType: publicPage.contentType,
    bodyContainsSite,
    apiPublicationId,
    apiStatus,
    publicationStatus,
  };

  if (
    dnsResult.addresses.length === 0
    || !publicPage.tlsAuthorized
    || publicPage.status !== 200
    || !bodyContainsSite
    || apiStatus !== "PUBLISHED"
    || publicationStatus !== "ACTIVE"
    || !apiPublicationId
  ) {
    console.error("SITES_PUBLIC_HOST_SMOKE_FAILED", JSON.stringify(result, null, 2));
    process.exit(1);
  }

  console.log("SITES_PUBLIC_HOST_SMOKE_PASSED", JSON.stringify(result, null, 2));
}

async function resolvePublicDNS(hostname: string) {
  const [addresses, cnames] = await Promise.all([
    dns.resolve4(hostname).catch(() => [] as string[]),
    dns.resolveCname(hostname).catch(() => [] as string[]),
  ]);
  return { hostname, addresses, cnames };
}

async function fetchJSON(url: string): Promise<Record<string, unknown>> {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return await response.json() as Record<string, unknown>;
}

function fetchText(url: string): Promise<{
  status: number;
  contentType: string;
  body: string;
  tlsAuthorized: boolean;
  tlsAuthorizationError: string | null;
}> {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { timeout: 8_000 }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        const socket = response.socket as import("node:tls").TLSSocket;
        resolve({
          status: response.statusCode ?? 0,
          contentType: String(response.headers["content-type"] ?? ""),
          body,
          tlsAuthorized: socket.authorized,
          tlsAuthorizationError: socket.authorizationError ?? null,
        });
      });
    });
    request.on("timeout", () => request.destroy(new Error(`${url} timed out`)));
    request.on("error", reject);
  });
}

main().catch((error) => {
  console.error("SITES_PUBLIC_HOST_SMOKE_FAILED", error instanceof Error ? error.message : error);
  process.exit(1);
});
