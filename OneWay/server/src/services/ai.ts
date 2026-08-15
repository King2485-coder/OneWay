import { logger } from "../lib/logger";

type DraftInput = {
  prompt: string;
  businessName?: string;
  category?: string;
  preferredColors?: string[];
};

type Draft = {
  name: string;
  tagline: string;
  category: string;
  description: string;
  hero: { title: string; subtitle: string };
  products: { name: string; description: string; price: string; isSubscription: boolean }[];
  collections: { title: string }[];
  theme: { primaryHex: string; accentHex: string; background: string; font: string };
};

type StorefrontHelpInput = {
  type: "shopName" | "shopDescription" | "sellerStory" | "category" | "productCopy" | "storePolicies";
  context?: {
    shopName?: string;
    category?: string;
    sellerStory?: string;
    shopDescription?: string;
    productName?: string;
    productDescription?: string;
  };
};

export async function generateStorefrontDraft(input: DraftInput): Promise<Draft> {
  const apiKey = (process.env.OPENAI_API_KEY || "").trim();
  if (apiKey) {
    try {
      const draft = await generateWithOpenAI(apiKey, input);
      if (process.env.NODE_ENV !== "production") {
        logger.info({
          provider: "openai",
          model: (process.env.OPENAI_MODEL || "gpt-4o-mini").trim() || "gpt-4o-mini",
        }, "[AI] storefront draft generated");
      }
      return draft;
    } catch (e) {
      logger.warn({ err: e }, "[AI] OpenAI failed, falling back to local generator");
      return localFallback(input);
    }
  }
  if (process.env.NODE_ENV !== "production") {
    logger.warn({}, "[AI] OPENAI_API_KEY not set; using local fallback generator");
  }
  return localFallback(input);
}

export async function generateStorefrontHelp(input: StorefrontHelpInput): Promise<string> {
  const apiKey = (process.env.OPENAI_API_KEY || "").trim();
  if (apiKey) {
    try {
      return await generateStorefrontHelpWithOpenAI(apiKey, input);
    } catch (error) {
      logger.warn({ err: error }, "[AI] storefront help failed, falling back to local copy");
    }
  }
  return storefrontHelpFallback(input);
}

async function generateWithOpenAI(apiKey: string, input: DraftInput): Promise<Draft> {
  const schemaHint = {
    name: "string",
    tagline: "string",
    category: "string",
    description: "string",
    hero: { title: "string", subtitle: "string" },
    products: [{ name: "string", description: "string", price: "string", isSubscription: "boolean" }],
    collections: [{ title: "string" }],
    theme: { primaryHex: "string", accentHex: "string", background: "string", font: "string" }
  };

  const system = [
    "You are an in-app storefront builder for OneWay.",
    "Return JSON only (no markdown), matching this schema shape:",
    JSON.stringify(schemaHint)
  ].join("\n");

  const user = [
    `Prompt: ${input.prompt}`,
    input.businessName ? `Business name: ${input.businessName}` : "",
    input.category ? `Category hint: ${input.category}` : "",
    input.preferredColors?.length ? `Preferred colors: ${input.preferredColors.join(", ")}` : ""
  ]
    .filter(Boolean)
    .join("\n");

  // Use a cheap model by default; caller can override via env later.
  const model = (process.env.OPENAI_MODEL || "gpt-4o-mini").trim();

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`
    },
    body: JSON.stringify({
      model,
      temperature: 0.7,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: system },
        { role: "user", content: user }
      ]
    })
  });

  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    throw new Error(`OpenAI HTTP ${resp.status}: ${text.slice(0, 200)}`);
  }

  const json: any = await resp.json();
  const content = json?.choices?.[0]?.message?.content;
  if (!content || typeof content !== "string") throw new Error("Empty OpenAI response");
  const parsed = JSON.parse(content);
  return normalizeDraft(parsed, input);
}

function localFallback(input: DraftInput): Draft {
  const prompt = input.prompt.toLowerCase();
  const colors = input.preferredColors?.length ? input.preferredColors : ["#111827", "#2563EB"];

  let category = input.category || "General";
  if (prompt.includes("tea")) category = "Food & Drink";
  if (prompt.includes("card") || prompt.includes("stationery")) category = "Stationery";
  if (prompt.includes("dog") || prompt.includes("pet")) category = "Pets";

  const baseName = input.businessName?.trim() || inferNameFromPrompt(input.prompt);
  const name = baseName.length ? baseName : "OneWay Storefront";

  const products =
    prompt.includes("tea")
      ? [
          { name: "Signature Loose Leaf Blend", description: "Small-batch blend with bright aromatics.", price: "$18", isSubscription: false },
          { name: "Brooklyn Matcha Kit", description: "Ceremonial grade matcha + whisk set.", price: "$42", isSubscription: false },
          { name: "Iced Tea Variety Pack", description: "Refreshing sampler for spring and summer.", price: "$24", isSubscription: false }
        ]
      : [
          { name: "Starter Product", description: "A great first item to sell.", price: "$19", isSubscription: false },
          { name: "Premium Bundle", description: "A higher-value bundle deal.", price: "$49", isSubscription: false }
        ];

  return {
    name,
    tagline: "Built with OneWay",
    category,
    description: `A modern storefront for ${name}.`,
    hero: { title: `Welcome to ${name}`, subtitle: "Discover curated picks and seasonal deals." },
    products,
    collections: [{ title: "Featured" }, { title: "New arrivals" }],
    theme: { primaryHex: colors[0] || "#111827", accentHex: colors[1] || "#2563EB", background: "light", font: "SFPro" }
  };
}

function inferNameFromPrompt(prompt: string): string {
  const trimmed = prompt.trim();
  if (!trimmed) return "";
  // First 3-ish words, Title Cased.
  const words = trimmed.split(/\s+/).slice(0, 3);
  return words.map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(" ");
}

function normalizeDraft(raw: any, input: DraftInput): Draft {
  const fallback = localFallback(input);
  const draft: Draft = {
    name: typeof raw?.name === "string" ? raw.name : fallback.name,
    tagline: typeof raw?.tagline === "string" ? raw.tagline : fallback.tagline,
    category: typeof raw?.category === "string" ? raw.category : fallback.category,
    description: typeof raw?.description === "string" ? raw.description : fallback.description,
    hero: {
      title: typeof raw?.hero?.title === "string" ? raw.hero.title : fallback.hero.title,
      subtitle: typeof raw?.hero?.subtitle === "string" ? raw.hero.subtitle : fallback.hero.subtitle
    },
    products: Array.isArray(raw?.products)
      ? raw.products
          .filter((p: any) => p && typeof p.name === "string")
          .slice(0, 12)
          .map((p: any) => ({
            name: String(p.name),
            description: String(p.description || ""),
            price: String(p.price || "$0"),
            isSubscription: Boolean(p.isSubscription)
          }))
      : fallback.products,
    collections: Array.isArray(raw?.collections)
      ? raw.collections
          .filter((c: any) => c && typeof c.title === "string")
          .slice(0, 12)
          .map((c: any) => ({ title: String(c.title) }))
      : fallback.collections,
    theme: {
      primaryHex: typeof raw?.theme?.primaryHex === "string" ? raw.theme.primaryHex : fallback.theme.primaryHex,
      accentHex: typeof raw?.theme?.accentHex === "string" ? raw.theme.accentHex : fallback.theme.accentHex,
      background: typeof raw?.theme?.background === "string" ? raw.theme.background : fallback.theme.background,
      font: typeof raw?.theme?.font === "string" ? raw.theme.font : fallback.theme.font
    }
  };
  return draft;
}

async function generateStorefrontHelpWithOpenAI(apiKey: string, input: StorefrontHelpInput): Promise<string> {
  const model = (process.env.OPENAI_MODEL || "gpt-4o-mini").trim();
  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`
    },
    body: JSON.stringify({
      model,
      temperature: 0.7,
      messages: [
        {
          role: "system",
          content: "You write short, usable storefront copy for an ecommerce setup wizard. Return plain text only."
        },
        {
          role: "user",
          content: JSON.stringify(input)
        }
      ]
    })
  });

  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    throw new Error(`OpenAI HTTP ${resp.status}: ${text.slice(0, 200)}`);
  }

  const json: any = await resp.json();
  const content = json?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("Empty OpenAI storefront help response");
  }
  return content.trim();
}

function storefrontHelpFallback(input: StorefrontHelpInput): string {
  const context = input.context ?? {};
  const shopName = (context.shopName || "").trim();
  const category = (context.category || "").trim();
  const sellerStory = (context.sellerStory || "").trim();
  const shopDescription = (context.shopDescription || "").trim();
  const productName = (context.productName || "").trim();
  const productDescription = (context.productDescription || "").trim();

  switch (input.type) {
    case "shopName":
      if (shopName) return shopName;
      if (category) return `${category} Studio`;
      return "OneWay Shop";
    case "shopDescription":
      return shopDescription || `Welcome to my OneWay shop. Discover products selected with care, clear details, and fast support.`;
    case "sellerStory":
      return sellerStory || "I started this shop to share carefully chosen products, clear communication, and dependable support with every buyer.";
    case "category":
      return category || "Lifestyle";
    case "productCopy":
      if (productName) return `${productName} is selected for quality, practical value, and a smooth buying experience on OneWay.`;
      return productDescription || "Thoughtfully chosen product with clear details, dependable quality, and responsive support.";
    case "storePolicies":
      return "We process orders quickly, share clear shipping updates, accept eligible returns, and reply fast when buyers need help.";
  }
}
