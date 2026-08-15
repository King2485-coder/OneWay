import express from "express";
import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord } from "../services/identity";
import { generateUniqueOneWayNumber, userHasExtraNumberSubscription } from "../services/numbers";
import { resolveTwilioCampaignStatus } from "../services/sms/twilioCampaignStatus";

const createSchema = z.object({
  label: z.string().min(1).max(64).optional(),
});

const primarySchema = z.object({
  isPrimary: z.literal(true),
});

const searchSchema = z.object({
  areaCode: z.string().trim().regex(/^\d{3}$/).optional(),
  contains: z.string().trim().regex(/^\d{2,7}$/).optional(),
});

const purchaseSchema = z.object({
  phoneNumber: z.string().trim().regex(/^\+\d{10,15}$/),
  planId: z.string().trim().max(80).optional(),
  purchaseToken: z.string().trim().min(20).max(2000).optional(),
  confirmationAccepted: z.boolean().optional(),
});

const PURCHASE_TOKEN_TTL_MS = 10 * 60 * 1000;
const TWILIO_SEARCH_PAGE_SIZE = "12";
const LIVE_PURCHASE_ENABLED_VALUES = new Set(["1", "true", "yes", "on"]);
const NUMBER_PROVIDER_MODES = new Set(["auto", "live", "mock"]);

export function numbersRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/me", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const numbers = await prisma.userNumber.findMany({
      where: { userId },
      orderBy: [{ isPrimary: "desc" }, { createdAt: "asc" }],
    });
    const hasSubscription = await userHasExtraNumberSubscription(userId);
    res.json({
      numbers,
      billing: {
        freeIncluded: 2,
        extraNumberPriceMonthly: 7.99,
        hasExtraNumbersSubscription: hasSubscription,
      },
    });
  });

  router.get("/search", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const parsed = searchSchema.safeParse(req.query ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_query", issues: parsed.error.issues });
      return;
    }

    try {
      const results = await searchAvailableBusinessNumbers(parsed.data, userId);
      res.json(results);
    } catch (error) {
      logger.warn({ err: error }, "[numbers] business number search failed");
      res.status(502).json({
        error: "number_search_failed",
        message: publicErrorMessage(error, "We couldn't load available numbers right now. Try again in a moment."),
      });
    }
  });

  router.post("/purchase", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = purchaseSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const existing = await prisma.userNumber.findUnique({
      where: { number: parsed.data.phoneNumber },
    });

    if (existing && existing.userId !== userId) {
      res.status(409).json({
        error: "number_unavailable",
        message: "That number is no longer available.",
      });
      return;
    }

    if (existing) {
      res.json({
        number: existing,
        provider: "oneway",
        mode: "already_owned",
      });
      return;
    }

    try {
      if (shouldUseLiveNumberProvider()) {
        if (!liveNumberPurchasesEnabled()) {
          res.status(409).json({
            error: "live_number_purchase_disabled",
            message: "Live number claiming is in review mode. Turn it on after billing and approval checks are ready.",
          });
          return;
        }

        if (parsed.data.confirmationAccepted !== true) {
          res.status(400).json({
            error: "purchase_confirmation_required",
            message: "Review and confirm this number before claiming it.",
          });
          return;
        }

        const tokenCheck = verifyPurchaseToken(parsed.data.purchaseToken, {
          phoneNumber: parsed.data.phoneNumber,
          userId,
          provider: "twilio",
        });
        if (!tokenCheck.ok) {
          res.status(409).json({
            error: tokenCheck.error,
            message: tokenCheck.message,
          });
          return;
        }
      }

      const purchase = await purchaseBusinessNumber(parsed.data.phoneNumber);
      const messagingAttachment = await attachPurchasedNumberToMessagingService(purchase);
      const count = await prisma.userNumber.count({ where: { userId } });
      const created = await prisma.userNumber.create({
        data: {
          userId,
          number: parsed.data.phoneNumber,
          label: "Business",
          isPaid: true,
          isPrimary: count === 0,
        },
      });

      res.status(201).json({
        number: created,
        provider: purchase.provider,
        mode: purchase.mode,
        providerNumberId: purchase.providerNumberId,
        messagingAttachment,
      });
    } catch (error) {
      logger.warn({ err: error }, "[numbers] business number purchase failed");
      res.status(502).json({
        error: "number_purchase_failed",
        message: publicErrorMessage(error, "We couldn't claim this number. Search again and choose another number."),
      });
    }
  });

  router.post("/create", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const parsed = createSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const count = await prisma.userNumber.count({ where: { userId } });
    if (count >= 2) {
      const hasSubscription = await userHasExtraNumberSubscription(userId);
      if (!hasSubscription) {
        res.status(402).json({
          error: "subscription_required",
          message: "Extra numbers require $7.99/month",
        });
        return;
      }
    }

    const number = await generateUniqueOneWayNumber();
    const created = await prisma.userNumber.create({
      data: {
        userId,
        number,
        label: parsed.data.label,
        isPaid: count >= 2,
        isPrimary: count === 0,
      },
    });

    res.status(201).json(created);
  });

  router.post("/claim-free", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const existing = await prisma.userNumber.findMany({
      where: { userId },
      orderBy: [{ isPrimary: "desc" }, { createdAt: "asc" }],
    });

    const labels = ["Personal", "Fun"];
    const created: typeof existing = [...existing];

    while (created.length < 2) {
      const number = await generateUniqueOneWayNumber();
      const item = await prisma.userNumber.create({
        data: {
          userId,
          number,
          label: labels[created.length] ?? "OneWay number",
          isPaid: false,
          isPrimary: created.length === 0,
        },
      });
      created.push(item);
    }

    const normalized = await prisma.userNumber.findMany({
      where: { userId },
      orderBy: [{ isPrimary: "desc" }, { createdAt: "asc" }],
      take: 2,
    });
    res.status(201).json(normalized);
  });

  router.patch("/:id/primary", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const parsed = primarySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const number = await prisma.userNumber.findFirst({
      where: { id: req.params.id, userId },
    });

    if (!number) {
      res.status(404).json({ error: "number_not_found" });
      return;
    }

    await prisma.$transaction([
      prisma.userNumber.updateMany({
        where: { userId },
        data: { isPrimary: false },
      }),
      prisma.userNumber.update({
        where: { id: number.id },
        data: { isPrimary: true },
      }),
    ]);

    const updated = await prisma.userNumber.findUnique({ where: { id: number.id } });
    res.json(updated);
  });

  router.delete("/:id", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const number = await prisma.userNumber.findFirst({
      where: { id: req.params.id, userId },
      orderBy: { createdAt: "asc" },
    });

    if (!number) {
      res.status(404).json({ error: "number_not_found" });
      return;
    }

    const count = await prisma.userNumber.count({ where: { userId } });
    if (count <= 1) {
      res.status(400).json({
        error: "last_number_forbidden",
        message: "You must keep at least one OneWay number.",
      });
      return;
    }

    await prisma.userNumber.delete({ where: { id: number.id } });

    if (number.isPrimary) {
      const fallback = await prisma.userNumber.findFirst({
        where: { userId },
        orderBy: { createdAt: "asc" },
      });
      if (fallback) {
        await prisma.userNumber.update({
          where: { id: fallback.id },
          data: { isPrimary: true },
        });
      }
    }

    res.status(204).end();
  });

  return router;
}

type NumberSearchInput = z.infer<typeof searchSchema>;

type BusinessNumberSearchResult = {
  phoneNumber: string;
  displayName: string;
  locality: string | null;
  region: string | null;
  capabilities: {
    voice: boolean;
    sms: boolean;
  };
  monthlyPrice: number;
  setupPrice: number;
  provider: "twilio" | "mock";
  purchaseToken: string;
  purchaseTokenExpiresAt: string;
};

type UnsignedBusinessNumberSearchResult = Omit<BusinessNumberSearchResult, "purchaseToken" | "purchaseTokenExpiresAt">;

class NumberProviderError extends Error {
  constructor(
    message: string,
    readonly publicMessage: string,
  ) {
    super(message);
  }
}

async function searchAvailableBusinessNumbers(input: NumberSearchInput, userId: string): Promise<{
  results: BusinessNumberSearchResult[];
  provider: "twilio" | "mock";
  mode: "live" | "mock";
}> {
  if (shouldUseLiveNumberProvider()) {
    const response = await searchTwilioAvailableNumbers(input);
    return {
      ...response,
      results: response.results.map((result) => withPurchaseToken(result, userId)),
    };
  }
  if (shouldUseMockNumberProvider()) {
    const results = await mockAvailableNumbers(input);
    return {
      results: results.map((result) => withPurchaseToken(result, userId)),
      provider: "mock",
      mode: "mock",
    };
  }
  throw new NumberProviderError(
    "Business number search is not configured.",
    "Number search is not connected yet.",
  );
}

async function searchTwilioAvailableNumbers(input: NumberSearchInput): Promise<{
  results: UnsignedBusinessNumberSearchResult[];
  provider: "twilio";
  mode: "live";
}> {
  const accountSid = env("TWILIO_ACCOUNT_SID");
  const authToken = env("TWILIO_AUTH_TOKEN");
  const params = new URLSearchParams();
  params.set("SmsEnabled", "true");
  params.set("VoiceEnabled", "true");
  params.set("PageSize", TWILIO_SEARCH_PAGE_SIZE);
  if (input.areaCode) params.set("AreaCode", input.areaCode);
  if (input.contains) params.set("Contains", input.contains);

  const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/AvailablePhoneNumbers/US/Local.json?${params.toString()}`;
  const response = await fetch(endpoint, {
    headers: {
      Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString("base64")}`,
    },
  });
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    const message = typeof body.message === "string" ? body.message : `Twilio HTTP ${response.status}`;
    throw new NumberProviderError(
      `Available number search failed: ${message}`,
      "We couldn't load available numbers right now. Try again in a moment.",
    );
  }

  const available = Array.isArray(body.available_phone_numbers) ? body.available_phone_numbers : [];
  return {
    provider: "twilio",
    mode: "live",
    results: available
      .map((item) => toTwilioSearchResult(item))
      .filter((item): item is UnsignedBusinessNumberSearchResult => Boolean(item)),
  };
}

function toTwilioSearchResult(value: unknown): UnsignedBusinessNumberSearchResult | null {
  if (!value || typeof value !== "object") return null;
  const item = value as Record<string, unknown>;
  const phoneNumber = typeof item.phone_number === "string" ? item.phone_number : "";
  if (!phoneNumber) return null;
  const capabilities = item.capabilities && typeof item.capabilities === "object"
    ? item.capabilities as Record<string, unknown>
    : {};
  return {
    phoneNumber,
    displayName: typeof item.friendly_name === "string" ? item.friendly_name : phoneNumber,
    locality: typeof item.locality === "string" ? item.locality : null,
    region: typeof item.region === "string" ? item.region : null,
    capabilities: {
      voice: capabilities.voice === true,
      sms: capabilities.SMS === true || capabilities.sms === true,
    },
    monthlyPrice: 3,
    setupPrice: 0,
    provider: "twilio",
  };
}

async function purchaseBusinessNumber(phoneNumber: string): Promise<{
  provider: "twilio" | "mock";
  mode: "live" | "mock";
  providerNumberId: string;
}> {
  if (shouldUseLiveNumberProvider()) {
    const accountSid = env("TWILIO_ACCOUNT_SID");
    const authToken = env("TWILIO_AUTH_TOKEN");
    const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/IncomingPhoneNumbers.json`;
    const params = new URLSearchParams();
    params.set("PhoneNumber", phoneNumber);
    params.set("FriendlyName", "OneWay Business");
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString("base64")}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });
    const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    if (!response.ok) {
      const message = typeof body.message === "string" ? body.message : `Twilio HTTP ${response.status}`;
      throw new NumberProviderError(
        `Number claim failed: ${message}`,
        "We couldn't claim this number. It may have just been taken. Search again and choose another number.",
      );
    }
    return {
      provider: "twilio",
      mode: "live",
      providerNumberId: typeof body.sid === "string" ? body.sid : `twilio_${randomUUID()}`,
    };
  }

  if (!shouldUseMockNumberProvider()) {
    throw new NumberProviderError(
      "Business number purchase is not configured.",
      "Number claiming is not connected yet.",
    );
  }

  return {
    provider: "mock",
    mode: "mock",
    providerNumberId: `mock_${randomUUID()}`,
  };
}

async function mockAvailableNumbers(input: NumberSearchInput): Promise<UnsignedBusinessNumberSearchResult[]> {
  const areaCode = input.areaCode ?? "520";
  const contains = input.contains ?? "";
  const existing = await prisma.userNumber.findMany({
    where: { number: { startsWith: `+1${areaCode}` } },
    select: { number: true },
  });
  const used = new Set(existing.map((item) => item.number));
  const results: UnsignedBusinessNumberSearchResult[] = [];
  let suffixSeed = 2000;

  while (results.length < 12 && suffixSeed < 9999) {
    const suffix = String(suffixSeed).padStart(4, "0");
    const middle = String(200 + results.length).padStart(3, "0");
    const last4 = contains && contains.length <= 4
      ? `${contains}${suffix}`.slice(0, 4)
      : suffix;
    const phoneNumber = `+1${areaCode}${middle}${last4}`;
    suffixSeed += 37;
    if (used.has(phoneNumber)) continue;
    results.push({
      phoneNumber,
      displayName: formatPhone(phoneNumber),
      locality: "Local",
      region: "US",
      capabilities: { voice: true, sms: true },
      monthlyPrice: 3,
      setupPrice: 0,
      provider: "mock",
    });
  }

  return results;
}

function withPurchaseToken(result: UnsignedBusinessNumberSearchResult, userId: string): BusinessNumberSearchResult {
  const exp = Date.now() + PURCHASE_TOKEN_TTL_MS;
  return {
    ...result,
    purchaseToken: signPurchaseToken({
      phoneNumber: result.phoneNumber,
      userId,
      provider: result.provider,
      monthlyPrice: result.monthlyPrice,
      setupPrice: result.setupPrice,
      exp,
      nonce: randomUUID(),
    }),
    purchaseTokenExpiresAt: new Date(exp).toISOString(),
  };
}

type PurchaseTokenPayload = {
  phoneNumber: string;
  userId: string;
  provider: "twilio" | "mock";
  monthlyPrice: number;
  setupPrice: number;
  exp: number;
  nonce: string;
};

const purchaseTokenPayloadSchema = z.object({
  phoneNumber: z.string().regex(/^\+\d{10,15}$/),
  userId: z.string().min(1),
  provider: z.enum(["twilio", "mock"]),
  monthlyPrice: z.number().finite().nonnegative(),
  setupPrice: z.number().finite().nonnegative(),
  exp: z.number().int().positive(),
  nonce: z.string().min(8),
});

function signPurchaseToken(payload: PurchaseTokenPayload): string {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = createHmac("sha256", purchaseTokenSecret())
    .update(encoded)
    .digest("base64url");
  return `${encoded}.${signature}`;
}

function verifyPurchaseToken(
  token: string | undefined,
  expected: { phoneNumber: string; userId: string; provider?: PurchaseTokenPayload["provider"] },
): { ok: true; payload: PurchaseTokenPayload } | { ok: false; error: string; message: string } {
  if (!token) {
    return {
      ok: false,
      error: "purchase_token_required",
      message: "Search again and confirm the latest number quote before claiming it.",
    };
  }

  const parts = token.split(".");
  if (parts.length !== 2) {
    return {
      ok: false,
      error: "purchase_token_invalid",
      message: "This number quote could not be verified. Search again and retry.",
    };
  }

  const [encoded, signature] = parts;
  if (!encoded || !signature) {
    return {
      ok: false,
      error: "purchase_token_invalid",
      message: "This number quote could not be verified. Search again and retry.",
    };
  }

  const expectedSignature = createHmac("sha256", purchaseTokenSecret())
    .update(encoded)
    .digest("base64url");
  const signatureBuffer = Buffer.from(signature, "base64url");
  const expectedBuffer = Buffer.from(expectedSignature, "base64url");
  if (signatureBuffer.length !== expectedBuffer.length || !timingSafeEqual(signatureBuffer, expectedBuffer)) {
    return {
      ok: false,
      error: "purchase_token_invalid",
      message: "This number quote could not be verified. Search again and retry.",
    };
  }

  try {
    const payload = purchaseTokenPayloadSchema.parse(JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")));
    if (payload.phoneNumber !== expected.phoneNumber || payload.userId !== expected.userId) {
      return {
        ok: false,
        error: "purchase_token_mismatch",
        message: "This quote does not match the selected number. Search again and retry.",
      };
    }
    if (expected.provider && payload.provider !== expected.provider) {
      return {
        ok: false,
        error: "purchase_token_mismatch",
        message: "This quote does not match the current number-claiming mode. Search again and retry.",
      };
    }
    if (!payload.exp || Date.now() > payload.exp) {
      return {
        ok: false,
        error: "purchase_token_expired",
        message: "This number quote expired. Search again for current availability.",
      };
    }
    if (payload.exp - Date.now() > PURCHASE_TOKEN_TTL_MS + 60_000) {
      return {
        ok: false,
        error: "purchase_token_invalid",
        message: "This quote is no longer current. Search again and retry.",
      };
    }
    return {
      ok: true,
      payload,
    };
  } catch {
    return {
      ok: false,
      error: "purchase_token_invalid",
      message: "This number quote could not be verified. Search again and retry.",
    };
  }
}

function purchaseTokenSecret(): string {
  return env("ONEWAY_NUMBER_PURCHASE_TOKEN_SECRET")
    || env("JWT_SECRET")
    || env("ONEWAY_DEV_AUTH_TOKEN")
    || "oneway-local-number-purchase-token";
}

function publicErrorMessage(error: unknown, fallback: string): string {
  return error instanceof NumberProviderError ? error.publicMessage : fallback;
}

type NumberPurchaseResult = Awaited<ReturnType<typeof purchaseBusinessNumber>>;

async function attachPurchasedNumberToMessagingService(purchase: NumberPurchaseResult): Promise<{
  status: "attached" | "pendingCampaign" | "notConfigured" | "skipped" | "failed";
  message: string;
  serviceSid?: string;
}> {
  if (purchase.provider !== "twilio" || purchase.mode !== "live") {
    return {
      status: "skipped",
      message: "Messaging attachment is not needed for local test numbers.",
    };
  }

  const messagingServiceSid = env("TWILIO_MESSAGING_SERVICE_SID");
  if (!messagingServiceSid) {
    return {
      status: "notConfigured",
      message: "Texting will be available after OneWay Messaging setup is connected.",
    };
  }

  const campaign = await resolveTwilioCampaignStatus(messagingServiceSid);
  if (campaign.campaignStatus !== "VERIFIED") {
    return {
      status: "pendingCampaign",
      serviceSid: messagingServiceSid,
      message: "Texting will turn on after OneWay Messaging approval is complete.",
    };
  }

  const accountSid = env("TWILIO_ACCOUNT_SID");
  const authToken = env("TWILIO_AUTH_TOKEN");
  const endpoint = `https://messaging.twilio.com/v1/Services/${encodeURIComponent(messagingServiceSid)}/PhoneNumbers`;
  const params = new URLSearchParams();
  params.set("PhoneNumberSid", purchase.providerNumberId);

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString("base64")}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });
    const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    if (!response.ok) {
      const message = typeof body.message === "string" ? body.message : `Twilio HTTP ${response.status}`;
      if (response.status === 409 && /already|exists|in use/i.test(message)) {
        return {
          status: "attached",
          serviceSid: messagingServiceSid,
          message: "Texting is connected for this number.",
        };
      }
      logger.warn({
        providerNumberId: purchase.providerNumberId,
        status: response.status,
        message,
      }, "[numbers] messaging attachment failed");
      return {
        status: "failed",
        serviceSid: messagingServiceSid,
        message: "Texting setup needs attention. Approval may still be finishing.",
      };
    }
    return {
      status: "attached",
      serviceSid: messagingServiceSid,
      message: "Texting is connected for this number.",
    };
  } catch (error) {
    logger.warn({ err: error }, "[numbers] messaging attachment request failed");
    return {
      status: "failed",
      serviceSid: messagingServiceSid,
      message: "Texting setup could not finish automatically.",
    };
  }
}

function twilioConfigured(): boolean {
  return Boolean(env("TWILIO_ACCOUNT_SID") && env("TWILIO_AUTH_TOKEN"));
}

function numberProviderMode(): "auto" | "live" | "mock" {
  const mode = env("ONEWAY_NUMBER_PROVIDER_MODE").toLowerCase();
  return NUMBER_PROVIDER_MODES.has(mode) ? mode as "auto" | "live" | "mock" : "auto";
}

function shouldUseLiveNumberProvider(): boolean {
  const mode = numberProviderMode();
  if (mode === "mock") return false;
  return twilioConfigured();
}

function shouldUseMockNumberProvider(): boolean {
  const mode = numberProviderMode();
  if (!isDevelopmentRuntime()) return false;
  if (mode === "mock") return true;
  return mode !== "live" && !twilioConfigured();
}

function liveNumberPurchasesEnabled(): boolean {
  return LIVE_PURCHASE_ENABLED_VALUES.has(env("ONEWAY_LIVE_NUMBER_PURCHASES_ENABLED").toLowerCase());
}

function isDevelopmentRuntime(): boolean {
  return process.env.NODE_ENV !== "production";
}

function env(name: string): string {
  return (process.env[name] ?? "").trim();
}

function formatPhone(phoneNumber: string): string {
  const match = phoneNumber.match(/^\+1(\d{3})(\d{3})(\d{4})$/);
  return match ? `(${match[1]}) ${match[2]}-${match[3]}` : phoneNumber;
}
