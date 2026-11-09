const defaultPublicWebBaseUrl = "https://oneway.is";

export function storefrontPublicWebBaseUrl(): string {
  const value = String(process.env.PUBLIC_WEB_BASE_URL ?? "").trim();
  if (!value) return defaultPublicWebBaseUrl;

  try {
    const url = new URL(value);
    if (url.protocol !== "http:" && url.protocol !== "https:") return defaultPublicWebBaseUrl;
    return value.replace(/\/+$/, "");
  } catch {
    return defaultPublicWebBaseUrl;
  }
}

export function storefrontPublicShopUrl(handle: string): string {
  return `${storefrontPublicWebBaseUrl()}/shop/${handle}`;
}
