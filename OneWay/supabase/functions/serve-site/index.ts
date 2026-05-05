// supabase/functions/serve-site/index.ts
// Deploy: supabase functions deploy serve-site
// This Edge Function serves *.oneway.app sites stored in Supabase Storage.
// Configure your DNS wildcard: *.oneway.app → your Supabase project URL
// Then set a Custom Domain in Supabase dashboard pointing to this function.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

serve(async (req: Request) => {
  const url = new URL(req.url);
  const host = req.headers.get("host") ?? "";

  // Extract subdomain: "mira.oneway.app" → "mira"
  const parts = host.split(".");
  const slug = parts.length >= 3 ? parts[0] : "home";

  // Special system subdomains
  if (slug === "home") return serveHomePage();
  if (slug === "directory") return serveDirectory();

  // Lookup domain in DB
  const { data: domain } = await supabase
    .from("ow_domains")
    .select("id, status, site_id")
    .eq("slug", slug)
    .single();

  if (!domain) return serve404(slug);
  if (domain.status !== "active") return serveExpired(slug);

  // Fetch site HTML from Storage
  const path = `sites/${slug}/index.html`;
  const { data: file, error } = await supabase
    .storage
    .from("oneway-sites")
    .download(path);

  if (error || !file) return serve404(slug);

  const html = await file.text();

  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=60, stale-while-revalidate=600",
      "X-Powered-By": "OneWay",
      "X-Frame-Options": "SAMEORIGIN",
      "X-Content-Type-Options": "nosniff",
      // Only allow loading within OneWay apps
      "Content-Security-Policy": [
        "default-src 'self' *.oneway.app",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline' fonts.googleapis.com",
        "img-src * data: blob:",
        "font-src 'self' fonts.gstatic.com",
      ].join("; "),
    },
  });
});

function serveHomePage(): Response {
  return new Response(HOME_HTML, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

async function serveDirectory(): Promise<Response> {
  const { data: domains } = await supabase
    .from("ow_domains")
    .select("slug, ow_sites(title, description)")
    .eq("status", "active")
    .not("site_id", "is", null)
    .limit(50);

  const items = (domains ?? []).map((d: any) => `
    <div class="site-card">
      <a href="https://${d.slug}.oneway.app" class="site-name">${d.slug}.oneway.app</a>
      <p class="site-desc">${d.ow_sites?.description ?? ""}</p>
    </div>
  `).join("");

  return new Response(DIRECTORY_HTML(items), {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function serve404(slug: string): Response {
  return new Response(NOT_FOUND_HTML(slug), {
    status: 404,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function serveExpired(slug: string): Response {
  return new Response(EXPIRED_HTML(slug), {
    status: 402,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

// ── HTML Templates ──────────────────────────────────────────────────────────
const BASE_CSS = `
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,sans-serif;background:#06030f;color:#f0ebff;
  display:flex;flex-direction:column;align-items:center;min-height:100vh;padding:40px 20px;text-align:center;}
h1{font-size:2rem;font-weight:900;margin-bottom:10px;}
p{color:#9d8fc4;font-size:.95rem;line-height:1.6;max-width:400px;}
a{color:#a855f7;text-decoration:none;}
.logo{font-size:48px;margin-bottom:16px;}
.badge{display:inline-block;background:rgba(124,58,237,.15);border:1px solid rgba(124,58,237,.3);
  border-radius:100px;padding:5px 14px;font-size:.75rem;color:#a855f7;font-weight:700;margin-bottom:24px;}
`;

const HOME_HTML = `<!DOCTYPE html><html><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OneWay — Private Web</title>
<style>${BASE_CSS}
.search{display:flex;gap:8px;width:100%;max-width:340px;margin:24px 0;}
.search input{flex:1;background:#0f0820;border:1px solid rgba(124,58,237,.3);
  border-radius:10px;padding:12px 14px;color:#f0ebff;font-size:.9rem;outline:none;}
.search button{background:linear-gradient(135deg,#6d28d9,#9333ea);border:none;
  border-radius:10px;padding:12px 18px;color:#fff;font-weight:700;cursor:pointer;}
</style></head><body>
<div class="logo">✈️</div>
<div class="badge">OneWay Browser</div>
<h1>The private web,<br>yours to own.</h1>
<p>Every *.oneway.app site is encrypted, private, and owned by its creator.</p>
<div class="search">
  <input placeholder="name.oneway.app" id="q" onkeydown="if(event.key==='Enter')go()">
  <button onclick="go()">Go</button>
</div>
<a href="https://directory.oneway.app">Browse all sites →</a>
<script>
function go(){const q=document.getElementById('q').value.trim();
  if(q) window.location.href='https://'+q+(q.includes('.')? '':'.oneway.app');}
</script>
</body></html>`;

const DIRECTORY_HTML = (items: string) =>
  `<!DOCTYPE html><html><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OneWay Directory</title>
<style>${BASE_CSS}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px;
  width:100%;max-width:720px;margin-top:24px;text-align:left;}
.site-card{background:#0f0820;border:1px solid rgba(124,58,237,.15);border-radius:12px;padding:14px;}
.site-name{font-weight:700;color:#a855f7;display:block;margin-bottom:4px;}
.site-desc{font-size:.75rem;color:#9d8fc4;}
</style></head><body>
<div class="logo">✈️</div>
<div class="badge">Directory</div>
<h1>OneWay Sites</h1>
<p>All published sites on the OneWay private web.</p>
<div class="grid">${items}</div>
</body></html>`;

const NOT_FOUND_HTML = (slug: string) =>
  `<!DOCTYPE html><html><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Not Found</title>
<style>${BASE_CSS}</style></head><body>
<div class="logo">🔌</div>
<div class="badge">404</div>
<h1>${slug}.oneway.app</h1>
<p>This domain hasn't been registered yet.<br>
<a href="oneway://register?slug=${slug}">Register it in the OneWay app →</a></p>
</body></html>`;

const EXPIRED_HTML = (slug: string) =>
  `<!DOCTYPE html><html><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Domain Expired</title>
<style>${BASE_CSS}</style></head><body>
<div class="logo">⏱</div>
<div class="badge">Expired</div>
<h1>${slug}.oneway.app</h1>
<p>This domain has expired. The owner can renew it in the OneWay app.</p>
</body></html>`;
