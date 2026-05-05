// supabase/functions/generate-site/index.ts
// Deploy: supabase functions deploy generate-site
// Proxies a no-code prompt to Claude and returns a single-file HTML site.
// Required env: ANTHROPIC_API_KEY

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body: { prompt?: string; domain?: string; title?: string };
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const { prompt = "", domain = "site", title = "My OneWay Site" } = body;
  if (!prompt) return new Response("Missing prompt", { status: 400 });

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      messages: [
        {
          role: "user",
          content: `Generate a complete, beautiful, single-file HTML website for:
Domain: ${domain}.oneway.app
Title: ${title}
Description: ${prompt}

Requirements:
- Single HTML file with embedded CSS and minimal JS
- Dark theme matching OneWay brand (#06030f background, #a855f7 accent)
- Mobile responsive
- Clean, professional design
- Include a footer: "Hosted on OneWay" linking to home.oneway.app
- Return ONLY the HTML, no explanation`,
        },
      ],
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    return new Response(`Anthropic error: ${text}`, { status: 502 });
  }

  const data = await response.json();
  const html = data.content?.[0]?.text ?? "";

  return new Response(JSON.stringify({ html }), {
    headers: { "Content-Type": "application/json" },
  });
});
