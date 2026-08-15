import fs from "node:fs/promises";
import path from "node:path";
import { PUBLIC_SITE_PAGES, renderPage } from "../src/routes/publicSite";

const outDir = path.resolve(process.cwd(), "netlify-public");
const assetDir = path.resolve(process.cwd(), "public-assets");

async function writePage(routePath: string): Promise<void> {
  const page = PUBLIC_SITE_PAGES[routePath];
  if (!page) {
    throw new Error(`Missing public site page for ${routePath}`);
  }

  const filePath =
    routePath === "/"
      ? path.join(outDir, "index.html")
      : path.join(outDir, routePath.replace(/^\//, ""), "index.html");

  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, renderPage(page), "utf8");
}

async function main(): Promise<void> {
  await fs.rm(outDir, { recursive: true, force: true });

  await Promise.all(Object.keys(PUBLIC_SITE_PAGES).map(writePage));
  await fs.cp(assetDir, path.join(outDir, "assets"), { recursive: true });
  await fs.writeFile(path.join(outDir, "robots.txt"), "User-agent: *\nAllow: /\n", "utf8");
  await fs.writeFile(
    path.join(outDir, "_redirects"),
    [
      "/ /index.html 200!",
      "/about/ /about 301",
      "/start/ /start 301",
      "/contact/ /contact 301",
      "/support/ /support 301",
      "/delete-account/ /delete-account 301",
      "/privacy/ /privacy 301",
      "/terms/ /terms 301",
      "/sms/ /sms 301",
      "/sms-consent/ /sms-consent 301",
      "/acceptable-use/ /acceptable-use 301",
      "/* /index.html 200",
      "",
    ].join("\n"),
    "utf8",
  );

  console.log(`Exported ${Object.keys(PUBLIC_SITE_PAGES).length} pages to ${outDir}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
