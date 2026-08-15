import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord } from "../services/identity";
import { resolveTwilioCampaignStatus } from "../services/sms/twilioCampaignStatus";
import { evaluatePSTNPreflight } from "./pstn";

type BusinessPresenceRow = {
  id: string;
  userId: string;
  businessName: string | null;
  industry: string | null;
  publicPhoneNumber: string | null;
  businessHours: string | null;
  greeting: string | null;
  missedCallAutoReply: string | null;
  aiReceptionistEnabled: boolean | number | null;
  planId: string | null;
  smsStatus: string | null;
  voiceStatus: string | null;
  setupStep: string | null;
  onboardingProgress: number | null;
  createdAt: Date | string;
  updatedAt: Date | string;
};

type PresenceStatus = "ready" | "pending" | "needsSetup" | "demo";

const profilePatchSchema = z.object({
  businessName: z.string().trim().max(120).optional(),
  industry: z.string().trim().max(80).optional(),
  businessHours: z.string().trim().max(400).optional(),
  greeting: z.string().trim().max(800).optional(),
  missedCallAutoReply: z.string().trim().max(500).optional(),
  aiReceptionistEnabled: z.boolean().optional(),
  planId: z.string().trim().max(80).optional(),
  smsStatus: z.string().trim().max(40).optional(),
  voiceStatus: z.string().trim().max(40).optional(),
  setupStep: z.string().trim().max(80).optional(),
  onboardingProgress: z.number().int().min(0).max(100).optional(),
});

type BusinessPresencePatch = z.infer<typeof profilePatchSchema> & {
  publicPhoneNumber?: string;
};

const assignNumberSchema = z.object({
  numberId: z.string().trim().min(1).max(120).optional(),
  phoneNumber: z.string().trim().min(7).max(40).optional(),
}).refine((value) => Boolean(value.numberId || value.phoneNumber), {
  message: "numberId or phoneNumber is required",
});

const BUSINESS_PLANS = [
  {
    id: "starter",
    name: "Starter",
    monthlyPrice: 19,
    tagline: "A business number, voicemail, and simple customer replies.",
    features: ["Business number", "Calling readiness", "Voicemail greeting", "Basic text setup"],
    recommended: false,
  },
  {
    id: "growth",
    name: "Growth",
    monthlyPrice: 39,
    tagline: "For teams that want calls, texts, voicemail, and faster follow-up.",
    features: ["Everything in Starter", "Texting readiness", "Missed-call auto-reply", "Priority setup checks"],
    recommended: true,
  },
  {
    id: "concierge",
    name: "AI Concierge",
    monthlyPrice: 79,
    tagline: "Add an AI receptionist for answering questions and capturing leads.",
    features: ["Everything in Growth", "AI receptionist", "Lead capture", "After-hours response"],
    recommended: false,
  },
];

let tableReady: Promise<void> | null = null;

export function businessRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/plans", (_req, res) => {
    res.json({ plans: BUSINESS_PLANS });
  });

  router.get("/profile", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    const profile = await findOrCreateBusinessPresence(userId);
    res.json(toProfileDTO(profile));
  });

  router.put("/profile", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = profilePatchSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    await findOrCreateBusinessPresence(userId);
    const next = await updateBusinessPresence(userId, parsed.data);
    res.json(toProfileDTO(next));
  });

  router.post("/profile/assign-number", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = assignNumberSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const ownedNumber = parsed.data.numberId
      ? await prisma.userNumber.findFirst({ where: { id: parsed.data.numberId, userId } })
      : await prisma.userNumber.findFirst({ where: { number: parsed.data.phoneNumber, userId } });

    if (!ownedNumber) {
      res.status(404).json({
        error: "number_not_found",
        message: "Choose a number owned by this OneWay account.",
      });
      return;
    }

    const profile = await updateBusinessPresence(userId, {
      publicPhoneNumber: ownedNumber.number,
      setupStep: "calling",
    });
    res.json(toProfileDTO(profile));
  });

  router.get("/setup/status", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const profile = await findOrCreateBusinessPresence(userId);
    const status = await buildBusinessSetupStatus(userId, profile);
    res.json(status);
  });

  return router;
}

async function ensureBusinessPresenceTable(): Promise<void> {
  tableReady ??= (async () => {
    await prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS "BusinessPresence" (
        "id" TEXT PRIMARY KEY,
        "userId" TEXT NOT NULL UNIQUE,
        "businessName" TEXT NOT NULL DEFAULT '',
        "industry" TEXT NOT NULL DEFAULT '',
        "publicPhoneNumber" TEXT NOT NULL DEFAULT '',
        "businessHours" TEXT NOT NULL DEFAULT '',
        "greeting" TEXT NOT NULL DEFAULT '',
        "missedCallAutoReply" TEXT NOT NULL DEFAULT '',
        "aiReceptionistEnabled" BOOLEAN NOT NULL DEFAULT false,
        "planId" TEXT NOT NULL DEFAULT '',
        "smsStatus" TEXT NOT NULL DEFAULT 'notConfigured',
        "voiceStatus" TEXT NOT NULL DEFAULT 'notConfigured',
        "setupStep" TEXT NOT NULL DEFAULT 'businessIdentity',
        "onboardingProgress" INTEGER NOT NULL DEFAULT 0,
        "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);
    await prisma.$executeRawUnsafe(`
      CREATE INDEX IF NOT EXISTS "BusinessPresence_userId_idx"
      ON "BusinessPresence" ("userId")
    `);
    const columns = await prisma.$queryRaw<Array<{ name: string }>>`
      PRAGMA table_info("BusinessPresence")
    `;
    if (!columns.some((column) => column.name === "planId")) {
      await prisma.$executeRawUnsafe(`
        ALTER TABLE "BusinessPresence"
        ADD COLUMN "planId" TEXT NOT NULL DEFAULT ''
      `);
    }
  })();
  await tableReady;
}

async function findBusinessPresence(userId: string): Promise<BusinessPresenceRow | null> {
  await ensureBusinessPresenceTable();
  const rows = await prisma.$queryRaw<BusinessPresenceRow[]>`
    SELECT * FROM "BusinessPresence" WHERE "userId" = ${userId} LIMIT 1
  `;
  return rows[0] ?? null;
}

async function findOrCreateBusinessPresence(userId: string): Promise<BusinessPresenceRow> {
  const existing = await findBusinessPresence(userId);
  if (existing) return existing;

  const [storefront, primaryNumber] = await Promise.all([
    prisma.storefront.findFirst({
      where: { ownerId: userId },
      orderBy: { updatedAt: "desc" },
      select: { name: true, category: true },
    }),
    prisma.userNumber.findFirst({
      where: { userId, isPrimary: true },
      select: { number: true },
    }),
  ]);
  const voice = buildVoiceStatus();
  const sms = await buildSMSStatus();

  await ensureBusinessPresenceTable();
  await prisma.$executeRaw`
    INSERT OR IGNORE INTO "BusinessPresence" (
      "id",
      "userId",
      "businessName",
      "industry",
      "publicPhoneNumber",
      "businessHours",
      "greeting",
      "missedCallAutoReply",
      "aiReceptionistEnabled",
      "planId",
      "smsStatus",
      "voiceStatus",
      "setupStep",
      "onboardingProgress",
      "createdAt",
      "updatedAt"
    ) VALUES (
      ${randomUUID()},
      ${userId},
      ${storefront?.name ?? ""},
      ${storefront?.category ?? ""},
      ${primaryNumber?.number ?? ""},
      ${"Monday-Friday, 9 AM-5 PM"},
      ${storefront?.name ? `Thanks for calling ${storefront.name}. We will be right with you.` : ""},
      ${"Thanks for reaching out. We missed your call and will get back to you soon."},
      ${false},
      ${""},
      ${sms.status},
      ${voice.status},
      ${"businessIdentity"},
      ${0},
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP
    )
  `;

  const created = await findBusinessPresence(userId);
  if (!created) {
    throw new Error("business_presence_create_failed");
  }
  return created;
}

async function updateBusinessPresence(
  userId: string,
  patch: BusinessPresencePatch,
): Promise<BusinessPresenceRow> {
  const current = await findOrCreateBusinessPresence(userId);
  const next = {
    businessName: patch.businessName ?? current.businessName ?? "",
    industry: patch.industry ?? current.industry ?? "",
    publicPhoneNumber: patch.publicPhoneNumber ?? current.publicPhoneNumber ?? "",
    businessHours: patch.businessHours ?? current.businessHours ?? "",
    greeting: patch.greeting ?? current.greeting ?? "",
    missedCallAutoReply: patch.missedCallAutoReply ?? current.missedCallAutoReply ?? "",
    aiReceptionistEnabled: patch.aiReceptionistEnabled ?? Boolean(current.aiReceptionistEnabled),
    planId: patch.planId ?? current.planId ?? "",
    smsStatus: patch.smsStatus ?? current.smsStatus ?? "notConfigured",
    voiceStatus: patch.voiceStatus ?? current.voiceStatus ?? "notConfigured",
    setupStep: patch.setupStep ?? current.setupStep ?? "businessIdentity",
    onboardingProgress: patch.onboardingProgress ?? current.onboardingProgress ?? 0,
  };

  await prisma.$executeRaw`
    UPDATE "BusinessPresence"
    SET
      "businessName" = ${next.businessName},
      "industry" = ${next.industry},
      "publicPhoneNumber" = ${next.publicPhoneNumber},
      "businessHours" = ${next.businessHours},
      "greeting" = ${next.greeting},
      "missedCallAutoReply" = ${next.missedCallAutoReply},
      "aiReceptionistEnabled" = ${next.aiReceptionistEnabled},
      "planId" = ${next.planId},
      "smsStatus" = ${next.smsStatus},
      "voiceStatus" = ${next.voiceStatus},
      "setupStep" = ${next.setupStep},
      "onboardingProgress" = ${next.onboardingProgress},
      "updatedAt" = CURRENT_TIMESTAMP
    WHERE "userId" = ${userId}
  `;

  const updated = await findBusinessPresence(userId);
  if (!updated) {
    throw new Error("business_presence_update_failed");
  }
  return updated;
}

async function buildBusinessSetupStatus(userId: string, profile: BusinessPresenceRow) {
  const [primaryNumber, ownedProfileNumber, voicemailCount] = await Promise.all([
    prisma.userNumber.findFirst({
      where: { userId, isPrimary: true },
      select: { number: true },
    }),
    cleanString(profile.publicPhoneNumber)
      ? prisma.userNumber.findFirst({
        where: { userId, number: cleanString(profile.publicPhoneNumber) },
        select: { number: true },
      })
      : Promise.resolve(null),
    prisma.voicemail.count({ where: { calleeId: userId } }),
  ]);

  const phoneNumber = ownedProfileNumber?.number || primaryNumber?.number || "";
  const voice = buildVoiceStatus();
  const sms = await buildSMSStatus();
  const voicemailConfigured = Boolean(cleanString(profile.greeting)) || voicemailCount > 0;
  const numberConfigured = Boolean(phoneNumber);
  const aiReceptionistEnabled = Boolean(profile.aiReceptionistEnabled);
  const next = nextRecommendedAction({
    profile,
    numberConfigured,
    planSelected: Boolean(cleanString(profile.planId)),
    voiceStatus: voice.status,
    smsStatus: sms.status,
    voicemailConfigured,
    aiReceptionistEnabled,
  });

  return {
    profile: toProfileDTO({
      ...profile,
      publicPhoneNumber: phoneNumber,
      smsStatus: sms.status,
      voiceStatus: voice.status,
      setupStep: next.step,
      onboardingProgress: onboardingProgress({
        profile,
        numberConfigured,
        planSelected: Boolean(cleanString(profile.planId)),
        voiceReady: voice.status === "ready" || voice.status === "demo",
        smsReady: sms.status === "ready" || sms.status === "demo",
        voicemailConfigured,
        aiReceptionistEnabled,
      }),
    }),
    numberConfigured,
    selectedPlan: BUSINESS_PLANS.find((plan) => plan.id === cleanString(profile.planId)) ?? null,
    pstnPreflightStatus: voice,
    smsStatus: sms,
    voicemailConfigured,
    aiReceptionistEnabled,
    nextRecommendedAction: next,
  };
}

function toProfileDTO(row: BusinessPresenceRow) {
  return {
    id: row.id,
    userId: row.userId,
    businessName: cleanString(row.businessName),
    industry: cleanString(row.industry),
    publicPhoneNumber: cleanString(row.publicPhoneNumber),
    businessHours: cleanString(row.businessHours),
    greeting: cleanString(row.greeting),
    missedCallAutoReply: cleanString(row.missedCallAutoReply),
    aiReceptionistEnabled: Boolean(row.aiReceptionistEnabled),
    planId: cleanString(row.planId),
    smsStatus: cleanString(row.smsStatus) || "notConfigured",
    voiceStatus: cleanString(row.voiceStatus) || "notConfigured",
    setupStep: cleanString(row.setupStep) || "businessIdentity",
    onboardingProgress: Number(row.onboardingProgress ?? 0),
    createdAt: toISOString(row.createdAt),
    updatedAt: toISOString(row.updatedAt),
  };
}

function nextRecommendedAction(input: {
  profile: BusinessPresenceRow;
  numberConfigured: boolean;
  planSelected: boolean;
  voiceStatus: PresenceStatus;
  smsStatus: PresenceStatus;
  voicemailConfigured: boolean;
  aiReceptionistEnabled: boolean;
}) {
  if (!cleanString(input.profile.businessName)) {
    return {
      step: "businessIdentity",
      title: "Add your business identity",
      message: "Start with your business name and industry so customers know who they reached.",
      actionLabel: "Add business details",
    };
  }
  if (!input.planSelected) {
    return {
      step: "plan",
      title: "Choose a business plan",
      message: "Pick the OneWay plan that fits how customers reach your business.",
      actionLabel: "Choose plan",
    };
  }
  if (!input.numberConfigured) {
    return {
      step: "phoneNumber",
      title: "Choose your business number",
      message: "Pick the number customers will see when they call or text your business.",
      actionLabel: "Choose number",
    };
  }
  if (input.voiceStatus === "needsSetup") {
    return {
      step: "calling",
      title: "Finish calling setup",
      message: "Connect business calling so customers can reach you from any phone.",
      actionLabel: "Review calling setup",
    };
  }
  if (input.smsStatus === "needsSetup" || input.smsStatus === "pending") {
    return {
      step: "texting",
      title: "Finish texting registration",
      message: "Finish registration so customer texts can be delivered reliably.",
      actionLabel: "Review texting setup",
    };
  }
  if (!input.voicemailConfigured) {
    return {
      step: "voicemail",
      title: "Add your greeting",
      message: "Create the greeting customers hear when you miss a call.",
      actionLabel: "Add greeting",
    };
  }
  if (!input.aiReceptionistEnabled) {
    return {
      step: "aiReceptionist",
      title: "Turn on your AI receptionist",
      message: "Let OneWay answer common questions and capture follow-ups when you are busy.",
      actionLabel: "Enable AI receptionist",
    };
  }
  return {
    step: "complete",
    title: "Your business is reachable",
    message: "OneWay is ready to help customers call, text, leave messages, and get answers.",
    actionLabel: "View dashboard",
  };
}

function onboardingProgress(input: {
  profile: BusinessPresenceRow;
  numberConfigured: boolean;
  planSelected: boolean;
  voiceReady: boolean;
  smsReady: boolean;
  voicemailConfigured: boolean;
  aiReceptionistEnabled: boolean;
}): number {
  const checks = [
    Boolean(cleanString(input.profile.businessName)),
    input.planSelected,
    input.numberConfigured,
    input.voiceReady,
    input.smsReady,
    input.voicemailConfigured,
    input.aiReceptionistEnabled,
  ];
  const complete = checks.filter(Boolean).length;
  return Math.round((complete / checks.length) * 100);
}

function buildVoiceStatus(): { status: PresenceStatus; provider: string; configured: boolean; missing: string[]; warnings: string[] } {
  const preflight = evaluatePSTNPreflight(env("PSTN_PROVIDER") || "stub");
  return {
    status: preflight.mode === "stub" ? "demo" : preflight.ok ? "ready" : "needsSetup",
    provider: preflight.provider,
    configured: preflight.ok,
    missing: preflight.missing,
    warnings: preflight.warnings,
  };
}

async function buildSMSStatus(): Promise<{
  status: PresenceStatus;
  provider: string;
  configured: boolean;
  registrationRequired: boolean;
  missing: string[];
  campaignStatus?: string | null;
}> {
  const provider = env("SMS_PROVIDER") || env("PSTN_PROVIDER") || "stub";
  if (provider === "stub") {
    return { status: "demo", provider, configured: true, registrationRequired: false, missing: [] };
  }

  const missing: string[] = [];
  if (provider === "twilio") {
    if (!env("TWILIO_ACCOUNT_SID")) missing.push("TWILIO_ACCOUNT_SID");
    if (!env("TWILIO_AUTH_TOKEN")) missing.push("TWILIO_AUTH_TOKEN");
    const sender = env("SMS_FROM_NUMBER") || env("TWILIO_FROM_NUMBER") || env("PSTN_FROM_NUMBER");
    const messagingService = env("TWILIO_MESSAGING_SERVICE_SID");
    if (!messagingService && !sender) missing.push("TWILIO_MESSAGING_SERVICE_SID or SMS_FROM_NUMBER");
    const needsRegistration = isRawUSLongCode(sender) && !messagingService;
    const campaign = messagingService ? await resolveTwilioCampaignStatus(messagingService) : { campaignStatus: null };
    const campaignVerified = messagingService ? campaign.campaignStatus === "VERIFIED" : true;
    const pendingRegistration = Boolean(messagingService) && !campaignVerified;
    return {
      status: missing.length > 0 ? "needsSetup" : needsRegistration ? "needsSetup" : pendingRegistration ? "pending" : "ready",
      provider,
      configured: missing.length === 0 && !needsRegistration && !pendingRegistration,
      registrationRequired: needsRegistration || pendingRegistration,
      missing,
      campaignStatus: campaign.campaignStatus,
    };
  }

  if (provider === "telnyx") {
    if (!env("TELNYX_API_KEY")) missing.push("TELNYX_API_KEY");
    if (!env("TELNYX_MESSAGING_PROFILE_ID") && !env("TELNYX_MESSAGING_FROM_NUMBER") && !env("SMS_FROM_NUMBER")) {
      missing.push("TELNYX_MESSAGING_PROFILE_ID or TELNYX_MESSAGING_FROM_NUMBER");
    }
  }
  if (provider === "sinch") {
    if (!env("SINCH_SERVICE_PLAN_ID")) missing.push("SINCH_SERVICE_PLAN_ID");
    if (!env("SINCH_API_TOKEN")) missing.push("SINCH_API_TOKEN");
    if (!env("SINCH_SMS_FROM_NUMBER") && !env("SMS_FROM_NUMBER")) {
      missing.push("SINCH_SMS_FROM_NUMBER or SMS_FROM_NUMBER");
    }
  }

  return {
    status: missing.length === 0 ? "ready" : "needsSetup",
    provider,
    configured: missing.length === 0,
    registrationRequired: false,
    missing,
  };
}

function isRawUSLongCode(value: string): boolean {
  return /^\+1\d{10}$/.test(value.trim());
}

function env(name: string): string {
  return (process.env[name] ?? "").trim();
}

function cleanString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function toISOString(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}
