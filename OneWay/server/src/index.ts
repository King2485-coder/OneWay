import "dotenv/config";

import cors from "cors";
import express from "express";
import http from "http";
import os from "os";
import path from "node:path";
import { execSync } from "node:child_process";
import * as Sentry from "@sentry/node";

import { prisma } from "./lib/db";
import { logger } from "./lib/logger";
import { redis, redisSubscriber } from "./lib/redis";

import { aiRouter } from "./routes/ai";
import { adminAdsRouter, adsRouter } from "./routes/ads";
import { accountRouter } from "./routes/account";
import { adminAuditRouter } from "./routes/adminAudit";
import { adminPrivacyRouter } from "./routes/adminPrivacy";
import { adminSecurityRouter } from "./routes/adminSecurity";
import { adminPricingRouter } from "./routes/adminPricing";
import { authRouter } from "./routes/auth";
import { billingRouter } from "./routes/billing";
import { businessRouter } from "./routes/business";
import { callsRouter, SUPPORTED_CALL_ROUTES } from "./routes/calls";
import { contactsRouter, ensureOneWayContactLifecycleColumns } from "./routes/contacts";
import { ensureFriendshipTable, friendsRouter } from "./routes/friends";
import { communitiesRouter } from "./routes/communities";
import { emailRouter } from "./routes/email";
import { historyRouter } from "./routes/history";
import { identityRouter } from "./routes/identity";
import { listingsRouter } from "./routes/listings";
import { liveKitRouter } from "./routes/livekit";
import { ledgerRouter } from "./routes/ledger";
import { messagesRouter } from "./routes/messages";
import { featuredRouter } from "./routes/featured";
import { ordersRouter } from "./routes/orders";
import { paymentsRouter } from "./routes/payments";
import { platformRouter } from "./routes/platform";
import { productsRouter } from "./routes/products";
import { pushRouter } from "./routes/push";
import { recordingsRouter } from "./routes/recordings";
import { searchRouter } from "./routes/search";
import { searchCrawlRouter } from "./routes/searchCrawl";
import { sellerRouter } from "./routes/seller";
import { sellerMonetizationRouter } from "./routes/sellerMonetization";
import { shopMessagesRouter } from "./routes/shopMessages";
import { sitesRouter } from "./routes/sites";
import { oneWaySitesRouter } from "./routes/onewaySites";
import { publicSiteRouter } from "./routes/publicSite";
import { storesRouter } from "./routes/stores";
import { storefrontsRouter } from "./routes/storefronts";
import { subscriptionsRouter } from "./routes/subscriptions";
import { evaluatePSTNPreflight, pstnRouter } from "./routes/pstn";
import { turnRouter } from "./routes/turn";
import { twilioRouter } from "./routes/twilio";
import { validateTwilioProductionEnvironment } from "./services/twilio/TwilioSecurity";
import { uploadsRouter } from "./routes/uploads";
import { usersRouter } from "./routes/users";
import { voicemailRouter } from "./routes/voicemail";
import { walletRouter } from "./routes/wallet";
import { ensureDirectChirpTables, ensureWalkieFavoriteTable, walkieRouter } from "./routes/walkie";
import { numbersRouter } from "./routes/numbers";
import { isComplianceLayerEnabled, oneWayBankRouter } from "./routes/oneWayBank";
import { stripeWebhooksRouter } from "./routes/stripeWebhooks";
import { serviceOrdersRouter } from "./routes/serviceOrders";
import { safetyRouter } from "./routes/safety";

import { CallRegistry } from "./services/CallRegistry";
import type { ICallRegistry } from "./services/CallRegistry";
import { RedisCallRegistry } from "./services/RedisCallRegistry";
import { LiveKitTokenService } from "./services/LiveKitTokenService";
import { PushTokenStore } from "./services/PushTokenStore";
import { AlertPushTokenStore } from "./services/AlertPushTokenStore";
import { EmailAlertPushService } from "./services/EmailAlertPushService";
import { VoIPPushService } from "./services/VoIPPushService";
import { CallHistoryService } from "./services/CallHistoryService";
import { VoicemailService } from "./services/VoicemailService";
import { loadCallerIdentity } from "./services/numbers";
import { pstnProvider } from "./services/pstn/createPSTNProvider";
import { smsProvider } from "./services/sms/createSMSProvider";
import { emailProvider } from "./services/email/createEmailProvider";
import { PublicWebCrawler } from "./services/search/PublicWebCrawler";
import { startNightlyLedgerReconciliationJob } from "./services/ledger/LedgerReconciliationJob";
import { validateFieldEncryptionConfig } from "./services/privacy/EncryptionService";
import { ensureExternalConversationPrivacyColumns } from "./services/privacy/ConversationPrivacy";
import { startDailySecurityOperationsJob } from "./services/security/SecurityOperationsJob";
import { ensurePricingAgentTables } from "./services/pricing/PricingAgentTables";
import { startPricingAgentMonthlyJob } from "./services/pricing/PricingAgentScheduler";
import { ensureIdentityWalkieNameColumn } from "./services/identity";
import { ensureDevTestAccounts } from "./services/devTestAccounts";
import { ensurePlatformCapabilityTables } from "./services/platformCapabilities";
import { ensureCommunityTables } from "./services/communityTables";
import {
  assertSitePublicationRoutesRegistered,
  reconcileAllSitePublicationsOnStartup,
  SITE_PUBLICATION_ROUTE_VERSION,
} from "./services/sitePublicationSelfHeal";

import { CallWebSocketServer } from "./realtime/CallWebSocketServer";
import { CommunityRealtimeServer } from "./realtime/CommunityRealtimeServer";
import { MessageRealtimeServer } from "./realtime/MessageRealtimeServer";
import { startMessageExpirationWorker } from "./services/MessageExpirationService";
import { startBurnWorker } from "./services/OneWayBurnService";
import { ensurePrivacyLifecycleSchema } from "./services/privacy/PrivacyLifecycleSchema";
import { FriendRealtimeServer } from "./realtime/FriendRealtimeServer";
import { LocalObjectStorage } from "./lib/storage/LocalObjectStorage";
import { S3ObjectStorage } from "./lib/storage/S3ObjectStorage";
import type { ObjectStorage } from "./lib/storage/ObjectStorage";
import { authMiddleware, type AuthenticatedRequest } from "./middleware/auth";
import { isParticipant, sameUserId, sanitizeRoomName } from "./types/calls";

const PORT = Number(process.env.PORT ?? 3000);
const HOST = process.env.HOST ?? "0.0.0.0";
const ONEWAY_API_VERSION = "calls-v2";
const ONEWAY_BACKEND_BUILD = process.env.ONEWAY_BACKEND_BUILD ?? new Date().toISOString();
const ONEWAY_BACKEND_GIT_SHA = process.env.GIT_COMMIT_SHA
  ?? process.env.RAILWAY_GIT_COMMIT_SHA
  ?? process.env.VERCEL_GIT_COMMIT_SHA
  ?? safeGitSha();

type RegisteredRoute = {
  method: string;
  path: string;
};

function safeGitSha(): string {
  try {
    return execSync("git rev-parse HEAD", { cwd: process.cwd(), stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    return "unknown";
  }
}

const registeredRoutes: RegisteredRoute[] = [];

function routeKey(route: RegisteredRoute): string {
  return `${route.method} ${route.path}`;
}

function joinRoutePath(prefix: string, path: unknown): string {
  const routePath = String(path ?? "/");
  const cleanPrefix = prefix === "/" ? "" : prefix.replace(/\/+$/, "");
  const cleanRoute = routePath === "/" ? "" : routePath.replace(/^\/+/, "");
  return `${cleanPrefix}/${cleanRoute}`.replace(/\/+/g, "/") || "/";
}

function collectRouterRoutes(prefix: string, router: express.Router): RegisteredRoute[] {
  const stack = (router as unknown as { stack?: any[] }).stack ?? [];
  const routes: RegisteredRoute[] = [];

  for (const layer of stack) {
    if (!layer.route) continue;
    const methods = Object.keys(layer.route.methods ?? {});
    for (const method of methods) {
      routes.push({
        method: method.toUpperCase(),
        path: joinRoutePath(prefix, layer.route.path),
      });
    }
  }

  return routes;
}

function trackRoutes(routes: RegisteredRoute[]): void {
  const seen = new Set(registeredRoutes.map(routeKey));
  for (const route of routes) {
    if (seen.has(routeKey(route))) continue;
    registeredRoutes.push(route);
    seen.add(routeKey(route));
  }
  registeredRoutes.sort((a, b) => routeKey(a).localeCompare(routeKey(b)));
}

function mountRouter(path: string, router: express.Router): void {
  app.use(path, router);
  trackRoutes(collectRouterRoutes(path, router));
}

function logRegisteredRoutes(): void {
  const routeCount = registeredRoutes.length;

  if (process.env.NODE_ENV === "production") {
    logger.info({ routeCount }, "[server] registered Express routes");
    return;
  }

  logger.info({
    routeCount,
    routes: registeredRoutes.map(routeKey),
  }, "[server] registered Express routes");

  for (const route of registeredRoutes) {
    console.log(`${route.method.padEnd(6)} ${route.path}`);
  }
}

function registeredRouteKeys(): string[] {
  return registeredRoutes.map(routeKey);
}

type PSTNRolloutState =
  | "normal_livekit_sip_path"
  | "stub_provider_only"
  | "direct_provider_fallback_explicitly_enabled"
  | "misconfigured_provider_or_fallback_state";

function envFlagEnabled(value: string | undefined): boolean {
  return (value ?? "").trim().toLowerCase() === "true";
}

function buildPSTNStartupRolloutSnapshot(): {
  PSTN_PROVIDER: string;
  PSTN_ENABLE_DIRECT_PROVIDER_FALLBACK: boolean;
  liveKitSipBridgeConfigured: boolean;
  liveKitSipBridgeEnabled: boolean;
  directProviderFallbackActive: boolean;
  rolloutState: PSTNRolloutState;
  activeOutboundPath: "livekit_sip" | "stub" | "livekit_sip_plus_direct_provider_fallback" | "misconfigured";
} {
  const preflight = evaluatePSTNPreflight(pstnProvider.name);
  const directProviderFallbackEnabled = envFlagEnabled(process.env.PSTN_ENABLE_DIRECT_PROVIDER_FALLBACK);
  const liveKitSipBridgeConfigured = preflight.liveKitConfigured && preflight.sipTrunkConfigured;
  const liveKitSipBridgeEnabled = preflight.mediaBridgeEnabled && pstnProvider.name !== "stub";
  const directProviderFallbackActive = pstnProvider.name !== "stub"
    && directProviderFallbackEnabled
    && preflight.ok;

  let rolloutState: PSTNRolloutState;
  if (pstnProvider.name === "stub") {
    rolloutState = "stub_provider_only";
  } else if (!preflight.ok) {
    rolloutState = "misconfigured_provider_or_fallback_state";
  } else if (directProviderFallbackEnabled) {
    rolloutState = "direct_provider_fallback_explicitly_enabled";
  } else {
    rolloutState = "normal_livekit_sip_path";
  }

  const activeOutboundPath = rolloutState === "stub_provider_only"
    ? "stub"
    : rolloutState === "normal_livekit_sip_path"
      ? "livekit_sip"
      : rolloutState === "direct_provider_fallback_explicitly_enabled"
        ? "livekit_sip_plus_direct_provider_fallback"
        : "misconfigured";

  return {
    PSTN_PROVIDER: pstnProvider.name,
    PSTN_ENABLE_DIRECT_PROVIDER_FALLBACK: directProviderFallbackEnabled,
    liveKitSipBridgeConfigured,
    liveKitSipBridgeEnabled,
    directProviderFallbackActive,
    rolloutState,
    activeOutboundPath,
  };
}

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  tracesSampleRate: 1.0,
});

validateFieldEncryptionConfig();

const app = express();
app.disable("x-powered-by");
app.use(cors({
  origin: process.env.CORS_ORIGIN?.split(",").map((value) => value.trim()).filter(Boolean) || true,
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
  credentials: true,
}));
app.use("/api/stripe/webhooks", express.raw({ type: "application/json", limit: "2mb" }), stripeWebhooksRouter({ prisma }));
app.use(express.urlencoded({ extended: false }));
app.use(express.json({
  limit: "10mb",
  verify: (req, _res, buf) => {
    const originalUrl = (req as any).originalUrl as string | undefined;
    if (originalUrl?.startsWith("/api/webhooks/stripe") || originalUrl?.startsWith("/api/stripe/webhooks")) {
      (req as any).rawBody = Buffer.from(buf);
    }
  },
}));
app.use("/uploads", express.static(process.env.UPLOADS_DIR?.trim() || path.join(process.cwd(), "uploads")));

logger.info(buildPSTNStartupRolloutSnapshot(), "[pstn] startup configuration");
logger.info({
  ONEWAY_BACKEND_BUILD,
  ONEWAY_BACKEND_GIT_SHA,
  ONEWAY_API_VERSION,
  ONEWAY_CALL_ROUTES: SUPPORTED_CALL_ROUTES,
}, "[server] OneWay backend build");
console.log("ONEWAY_BACKEND_BUILD", ONEWAY_BACKEND_BUILD);
console.log("ONEWAY_BACKEND_GIT_SHA", ONEWAY_BACKEND_GIT_SHA);
console.log("ONEWAY_API_VERSION", ONEWAY_API_VERSION);
console.log("ONEWAY_CALL_ROUTES", SUPPORTED_CALL_ROUTES.join(", "));
console.log("💬 SMS provider:", smsProvider.name);
console.log("📧 Email provider:", emailProvider.name);

// -------------------------------------------------------------------------
// Public compliance pages (no auth)
// -------------------------------------------------------------------------
app.use(publicSiteRouter());
app.use("/api/oneway", oneWaySitesRouter());

// -------------------------------------------------------------------------
// Health
// -------------------------------------------------------------------------
app.get("/health", (_req, res) => {
  res.status(200).json({
    status: "ok",
    ok: true,
    app: "oneway-server",
    apiVersion: ONEWAY_API_VERSION,
    environment: process.env.NODE_ENV ?? "development",
    gitSha: ONEWAY_BACKEND_GIT_SHA,
    buildTime: ONEWAY_BACKEND_BUILD,
    sitePublicationRouteVersion: SITE_PUBLICATION_ROUTE_VERSION,
    time: new Date().toISOString(),
  });
});
trackRoutes([{ method: "GET", path: "/health" }]);

app.get("/api/version", (_req, res) => {
  res.status(200).json({
    apiVersion: ONEWAY_API_VERSION,
    gitSha: ONEWAY_BACKEND_GIT_SHA,
    buildTime: ONEWAY_BACKEND_BUILD,
    sitePublicationRouteVersion: SITE_PUBLICATION_ROUTE_VERSION,
    supportedCallRoutes: SUPPORTED_CALL_ROUTES,
  });
});
trackRoutes([{ method: "GET", path: "/api/version" }]);

app.get("/livekit-token", authMiddleware, async (req, res) => {
  const userId = (req as AuthenticatedRequest).userId;
  const room = typeof req.query.room === "string" ? req.query.room : "";

  if (!room) {
    res.status(400).json({ error: "room_required" });
    return;
  }

  if (!livekit.isConfigured()) {
    res.status(503).json({ error: "livekit_not_configured" });
    return;
  }

  try {
    const knownCall = registry.findByRoom(sanitizeRoomName(room));
    if (!knownCall) {
      res.status(403).json({
        error: "room_not_authorized",
        message: "OneWay network unavailable. Try again when connected.",
      });
      return;
    }
    if (!isParticipant(knownCall, userId)) {
      res.status(403).json({
        error: "not_participant",
        message: "This OneWay room is not authorized for your account.",
      });
      return;
    }
    const callerIdentity = await loadCallerIdentity(userId);
    const result = await livekit.issue({
      roomName: knownCall.roomName,
      identity: userId,
      metadata: JSON.stringify({
        userId,
        roomName: knownCall.roomName,
        callerName: callerIdentity.callerName,
        callerNumber: callerIdentity.callerNumber,
      }),
      ttlSeconds: 3600,
    });
    res.json({ token: result.token });
  } catch (error) {
    logger.error({ err: error }, "[livekit] query token issue failed");
    res.status(500).json({ error: "token_failed" });
  }
});
trackRoutes([{ method: "GET", path: "/livekit-token" }]);

app.post("/token", authMiddleware, async (req, res) => {
  const userId = (req as AuthenticatedRequest).userId;
  const roomName = typeof req.body?.roomName === "string" ? sanitizeRoomName(req.body.roomName) : "";

  if (!roomName) {
    res.status(400).json({ error: "room_required" });
    return;
  }

  if (!livekit.isConfigured()) {
    res.status(503).json({ error: "livekit_not_configured" });
    return;
  }

  try {
    const knownCall = registry.findByRoom(roomName);
    if (!knownCall) {
      res.status(403).json({
        error: "room_not_authorized",
        message: "OneWay network unavailable. Try again when connected.",
      });
      return;
    }
    if (!isParticipant(knownCall, userId)) {
      res.status(403).json({
        error: "not_participant",
        message: "This OneWay room is not authorized for your account.",
      });
      return;
    }
    const callerIdentity = await loadCallerIdentity(userId);
    const result = await livekit.issue({
      roomName: knownCall.roomName,
      identity: userId,
      metadata: JSON.stringify({
        userId,
        roomName: knownCall.roomName,
        callerName: callerIdentity.callerName,
        callerNumber: callerIdentity.callerNumber,
      }),
      ttlSeconds: 3600,
    });
    res.json({ token: result.token, url: result.url, roomName: result.roomName });
  } catch (error) {
    logger.error({ err: error }, "[livekit] /token issue failed");
    res.status(500).json({ error: "token_failed" });
  }
});

app.post("/push/voip-token", authMiddleware, async (req, res) => {
  const userId = (req as AuthenticatedRequest).userId;
  const token = typeof req.body?.token === "string" ? req.body.token.toLowerCase() : "";
  const environment = req.body?.environment === "production" ? "production" : "sandbox";

  if (!token) {
    res.status(400).json({ error: "token_required" });
    return;
  }

  try {
    await pushTokens.set({
      userId,
      voipToken: token,
      environment,
      updatedAt: Date.now(),
    });
    res.status(204).end();
  } catch (error) {
    logger.error({ err: error }, "[push] voip token store failed");
    res.status(500).json({ error: "token_store_failed" });
  }
});

app.post("/calls/invite", authMiddleware, async (req, res) => {
  const userId = (req as AuthenticatedRequest).userId;
  const requestedCallee = typeof req.body?.calleeUserId === "string" ? req.body.calleeUserId.trim() : "";
  const hasVideo = typeof req.body?.hasVideo === "boolean" ? req.body.hasVideo : true;

  if (!requestedCallee) {
    res.status(400).json({ error: "calleeUserId_required", message: "A OneWay recipient is required." });
    return;
  }

  const calleeUserId = await resolveUserIdForCallTarget(requestedCallee, userId);
  if (!calleeUserId) {
    logger.warn({
      callerId: userId,
      requestedCallee,
    }, "[calls] legacy invite callee_not_found");
    res.status(404).json({
      error: "callee_not_found",
      message: "That OneWay recipient could not be found.",
    });
    return;
  }

  if (sameUserId(calleeUserId, userId)) {
    res.status(400).json({ error: "self_invite_forbidden", message: "You can't call yourself." });
    return;
  }

  const calleeHasActiveSocket = ws.isUserConnected(calleeUserId);
  const calleePushToken = await pushTokens.get(calleeUserId);

  if (!calleeHasActiveSocket && !calleePushToken) {
    res.status(404).json({
      error: "callee_unreachable",
      message: "That contact is not reachable on OneWay yet. Use a connected OneWay user ID, or have them open OneWay first."
    });
    return;
  }

  try {
    const callerIdentity = await loadCallerIdentity(userId);
    const existingCall = findActiveCallBetween(userId, calleeUserId);
    if (existingCall) {
      logger.info({
        callerId: userId,
        requestedCallee,
        calleeId: calleeUserId,
        callId: existingCall.callId,
        status: existingCall.status,
      }, "[calls] legacy invite reused active call");
      res.json({
        ok: true,
        callId: existingCall.callId,
        roomName: existingCall.roomName,
        callerName: callerIdentity.callerName,
        callerNumber: callerIdentity.callerNumber,
        callerDisplay: callerIdentity.callerDisplay,
      });
      return;
    }

    const call = registry.createCall({
      callerId: userId,
      calleeId: calleeUserId,
      hasVideo,
      turnEnabled: true,
    });

    ws.notifyCallChanged(call);

    if (calleePushToken) {
      await voipPush.send({
        userId: calleeUserId,
        callId: call.callId,
        callerId: userId,
        hasVideo,
        displayName: callerIdentity.callerDisplay,
        roomName: call.roomName,
        callerNumber: callerIdentity.callerNumber,
        callerName: callerIdentity.callerName,
      });
    }

    res.json({
      ok: true,
      callId: call.callId,
      roomName: call.roomName,
      callerName: callerIdentity.callerName,
      callerNumber: callerIdentity.callerNumber,
      callerDisplay: callerIdentity.callerDisplay,
    });
  } catch (error) {
    logger.error({ err: error }, "[calls] invite push failed");
    res.status(500).json({ error: "invite_failed", message: "OneWay couldn't deliver that call invite." });
  }
});

app.post("/calls/start", authMiddleware, async (req, res) => {
  const userId = (req as AuthenticatedRequest).userId;
  const fromIdentity = typeof req.body?.fromIdentity === "string" ? req.body.fromIdentity.trim() : "";
  const fromNumber = typeof req.body?.fromNumber === "string" ? req.body.fromNumber.trim() : "";
  const target = typeof req.body?.to === "string" ? req.body.to.trim() : "";
  const hasVideo = typeof req.body?.hasVideo === "boolean" ? req.body.hasVideo : true;

  if (!target || (!fromIdentity && !fromNumber)) {
    res.status(400).json({
      error: "invalid_call_request",
      message: "A OneWay caller identity and OneWay recipient are required.",
    });
    return;
  }

  const ownedIdentity = fromIdentity
    ? await prisma.oneWayIdentity.findFirst({
        where: { userId, onewayId: normalizeOneWayTarget(fromIdentity) },
        select: { onewayId: true },
      })
    : null;
  const ownedNumber = fromNumber
    ? await prisma.userNumber.findFirst({
        where: { userId, number: normalizeOneWayTarget(fromNumber) },
        select: { number: true },
      })
    : null;

  if (fromIdentity && !ownedIdentity) {
    res.status(403).json({
      error: "from_identity_not_owned",
      message: "You can only call from a OneWay identity you own.",
    });
    return;
  }
  if (fromNumber && !ownedNumber) {
    res.status(403).json({
      error: "from_number_not_owned",
      message: "You can only call from a OneWay number you own.",
    });
    return;
  }
  if (!ownedIdentity && !ownedNumber) {
    res.status(403).json({
      error: "no_valid_outgoing_identity",
      message: "Choose a valid OneWay ID or OneWay number before calling.",
    });
    return;
  }

  const resolvedTarget = await resolveOneWayNetworkTarget(target);
  if (!resolvedTarget) {
    res.status(403).json({
      error: "oneway_target_required",
      message: "This call must use a OneWay ID or OneWay number.",
    });
    return;
  }

  if (sameUserId(resolvedTarget.userId, userId)) {
    res.status(400).json({
      error: "self_call_forbidden",
      message: "You can't call yourself on OneWay.",
    });
    return;
  }

  const calleeHasActiveSocket = ws.isUserConnected(resolvedTarget.userId);
  const calleePushToken = await pushTokens.get(resolvedTarget.userId);
  if (!calleeHasActiveSocket && !calleePushToken) {
    res.status(403).json({
      error: "callee_unreachable",
      message: "That OneWay recipient is not reachable right now.",
    });
    return;
  }

  try {
    const callerIdentity = await loadCallerIdentity(userId);
    const existingCall = findActiveCallBetween(userId, resolvedTarget.userId);
    if (existingCall) {
      const existingCallerValue = callerIdentity.callerNumber;
      const existingCallerDisplay = ["OneWay", callerIdentity.callerName, existingCallerValue].join("\n");
      res.json({
        ok: true,
        callId: existingCall.callId,
        roomName: existingCall.roomName,
        callerName: callerIdentity.callerName,
        callerNumber: existingCallerValue,
        callerDisplay: existingCallerDisplay,
      });
      return;
    }

    const selectedCallerValue =
      ownedIdentity?.onewayId ??
      ownedNumber?.number ??
      callerIdentity.callerNumber;
    const selectedCallerDisplay = ["OneWay", callerIdentity.callerName, selectedCallerValue].join("\n");
    const call = registry.createCall({
      callerId: userId,
      calleeId: resolvedTarget.userId,
      hasVideo,
      turnEnabled: true,
    });
    await prisma.call.create({
      data: {
        id: call.callId,
        callerId: userId,
        calleeId: resolvedTarget.userId,
        status: "ringing",
        roomName: call.roomName,
        hasVideo,
      },
    });
    ws.notifyCallChanged(call);

    if (calleePushToken) {
      await voipPush.send({
        userId: resolvedTarget.userId,
        callId: call.callId,
        callerId: userId,
        hasVideo,
        displayName: selectedCallerDisplay,
        roomName: call.roomName,
        callerNumber: selectedCallerValue,
        callerName: callerIdentity.callerName,
      });
    }

    res.json({
      ok: true,
      callId: call.callId,
      roomName: call.roomName,
      callerName: callerIdentity.callerName,
      callerNumber: selectedCallerValue,
      callerDisplay: selectedCallerDisplay,
    });
  } catch (error) {
    logger.error({ err: error }, "[calls] start by number failed");
    res.status(500).json({
      error: "call_start_failed",
      message: "OneWay network unavailable. Try again when connected.",
    });
  }
});

// -------------------------------------------------------------------------
// Registry selection (in-memory by default; Redis when configured)
// -------------------------------------------------------------------------
const registry: ICallRegistry = (() => {
  const client = redis();
  const subscriber = redisSubscriber();
  if (client && subscriber) {
    logger.info({}, "[calls] using RedisCallRegistry");
    return new RedisCallRegistry(client, subscriber);
  }
  logger.info({}, "[calls] using in-memory CallRegistry");
  return new CallRegistry();
})();

// -------------------------------------------------------------------------
// Services (best-effort: if config missing, routes still mount but degrade)
// -------------------------------------------------------------------------
const pushTokens = new PushTokenStore();
const alertPushTokens = new AlertPushTokenStore(prisma);
const emailAlerts = new EmailAlertPushService(alertPushTokens);
const voipPush = new VoIPPushService(pushTokens);
const history = new CallHistoryService();

// Object storage for voicemail audio: S3/R2 if configured, otherwise local disk.
const s3 = S3ObjectStorage.fromEnv();
const localStorage = s3 ? null : new LocalObjectStorage({
  root: process.env.OBJECT_STORAGE_LOCAL_ROOT?.trim() || undefined,
});
const storage: ObjectStorage = s3 ?? localStorage!;
const voicemail = new VoicemailService(storage);

const livekit = LiveKitTokenService.fromEnv();
const publicWebCrawler = new PublicWebCrawler(prisma);
publicWebCrawler.initialize()
  .then(() => logger.info({}, "[search:crawler] public web index ready"))
  .catch((err) => logger.error({ err }, "[search:crawler] public web index init failed"));
let ws: CallWebSocketServer;
const communityRealtime = new CommunityRealtimeServer({ prisma, push: voipPush, path: "/ws/communities" });
const messageRealtime = new MessageRealtimeServer({ path: "/ws/messages" });
const friendRealtime = new FriendRealtimeServer({ path: "/ws/friends" });

// -------------------------------------------------------------------------
// REST routes
// -------------------------------------------------------------------------
mountRouter("/auth", authRouter());
mountRouter("/api/auth", authRouter());
mountRouter("/stores", storesRouter({ prisma }));
mountRouter("/api/stores", storesRouter({ prisma }));
mountRouter("/products", productsRouter({ prisma }));
mountRouter("/api/products", productsRouter({ prisma }));
mountRouter("/featured", featuredRouter({ prisma }));
mountRouter("/api/featured", featuredRouter({ prisma }));
mountRouter("/orders", ordersRouter({ prisma }));
mountRouter("/api/orders", ordersRouter({ prisma }));
mountRouter("/uploads", uploadsRouter());
mountRouter("/api/uploads", uploadsRouter());
mountRouter("/api/storefronts", storefrontsRouter({ prisma }));
mountRouter("/api/seller", sellerMonetizationRouter({ prisma }));
mountRouter("/api/seller", sellerRouter({ prisma }));
mountRouter("/api/listings", listingsRouter({ prisma }));
mountRouter("/api/numbers", numbersRouter());
mountRouter("/api/subscriptions", subscriptionsRouter());
mountRouter("/api/account", accountRouter());
mountRouter("/api/safety", safetyRouter());
mountRouter("/api/contacts", contactsRouter());
mountRouter("/api/friends", friendsRouter({ prisma, realtime: friendRealtime }));
const communityRoutes = communitiesRouter({ realtime: communityRealtime });
mountRouter("/api/communities", communityRoutes);
console.log("Community routes loaded ✓");
logger.info({
  routes: collectRouterRoutes("/api/communities", communityRoutes).map(routeKey),
}, "[communities] routes loaded");
mountRouter("/api/users", usersRouter());
mountRouter("/api/identity", identityRouter());
mountRouter("/api/messages", messagesRouter({ realtime: messageRealtime }));
mountRouter("/api/shops/messages", shopMessagesRouter({ prisma }));
mountRouter("/api/platform", platformRouter({ prisma }));
mountRouter("/api/twilio", twilioRouter());
mountRouter("/api/webhooks", stripeWebhooksRouter({ prisma }));
mountRouter("/api/service-orders", serviceOrdersRouter({ prisma }));
mountRouter("/api/email", emailRouter({ prisma, storage, provider: emailProvider, alerts: emailAlerts }));
mountRouter("/api/admin/audit", adminAuditRouter({ prisma }));
mountRouter("/api/admin/privacy", adminPrivacyRouter({ prisma }));
mountRouter("/api/admin/security", adminSecurityRouter({ prisma }));
mountRouter("/api/admin/pricing", adminPricingRouter({ prisma }));
mountRouter("/api/business", businessRouter());
mountRouter("/api/wallet", walletRouter({ prisma }));
mountRouter("/api/payments", paymentsRouter({ prisma }));
mountRouter("/api/billing", billingRouter({ prisma }));
mountRouter("/api/ledger", ledgerRouter({ prisma }));
mountRouter("/api/v1/ledger", oneWayBankRouter("ledger"));
mountRouter("/api/v1/disputes", oneWayBankRouter("disputes"));
mountRouter("/api/search/crawl", searchCrawlRouter({ crawler: publicWebCrawler }));
mountRouter("/search", searchRouter({ prisma, crawler: publicWebCrawler }));
mountRouter("/api/search", searchRouter({ prisma, crawler: publicWebCrawler }));
mountRouter("/api/sites", sitesRouter());
mountRouter("/api/oneway", oneWaySitesRouter());
mountRouter("/api/ai", aiRouter({ prisma }));
mountRouter("/api/ads", adsRouter({ prisma }));
mountRouter("/api/admin/ads", adminAdsRouter({ prisma }));
mountRouter("/api/turn-credentials", turnRouter());
mountRouter("/api/pstn", pstnRouter({
  provider: pstnProvider,
  livekit,
  isUserConnected: (userId) => ws?.isUserConnected(userId) ?? false,
  hasPushToken: async (userId) => Boolean(await pushTokens.get(userId)),
  isUserBusy: (userId) => registry.activeForUser(userId).length > 0,
  startInboundAppCall: async (args) => {
    const existingCall = registry.activeForUser(args.calleeId).find((call) =>
      call.callerId === args.callerId && call.status === "ringing"
    );
    const call = existingCall ?? registry.createCall({
      callerId: args.callerId,
      calleeId: args.calleeId,
      hasVideo: false,
      turnEnabled: true,
    });

    const callerIdIsUserId = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(args.callerId);
    if (!existingCall && callerIdIsUserId) {
      await prisma.call.create({
        data: {
          id: call.callId,
          callerId: args.callerId,
          calleeId: args.calleeId,
          status: "ringing",
          roomName: call.roomName,
          hasVideo: false,
        },
      }).catch((error) => {
        logger.warn({ err: error, callId: call.callId }, "[pstn] inbound native call persistence skipped");
      });
    }

    ws?.notifyCallChanged(call);
    await voipPush.send({
      userId: args.calleeId,
      callId: call.callId,
      callerId: args.callerId,
      hasVideo: false,
      displayName: args.callerDisplayName,
      roomName: call.roomName,
      callerNumber: args.callerNumber,
      callerName: args.callerName,
    });

    return { callId: call.callId, roomName: call.roomName };
  },
}));
mountRouter("/recordings", recordingsRouter());
mountRouter("/api/recordings", recordingsRouter());
mountRouter("/api/calls", callsRouter({
  registry,
  livekit,
  onCallChanged: (call) => ws?.notifyCallChanged(call),
  isUserConnected: (userId) => ws.isUserConnected(userId),
  hasPushToken: async (userId) => Boolean(await pushTokens.get(userId)),
  onCallInvited: (callerId, calleeId, call) => {
    // Best-effort VoIP push fan-out (does nothing if APNs creds missing).
    loadCallerIdentity(callerId)
      .then((callerIdentity) =>
        voipPush.send({
          userId: calleeId,
          callId: call.callId,
          callerId,
          hasVideo: call.hasVideo,
          displayName: callerIdentity.callerDisplay,
          roomName: call.roomName,
          callerNumber: callerIdentity.callerNumber,
          callerName: callerIdentity.callerName,
        })
      )
      .catch(() => {});
  }
}));
mountRouter("/api/livekit", liveKitRouter({ registry, tokens: livekit }));
mountRouter("/livekit", liveKitRouter({ registry, tokens: livekit }));
const chirpRoutes = walkieRouter({
  prisma,
  tokens: livekit,
  isUserOnline: (userId) =>
    (ws?.isUserConnected(userId) ?? false) || friendRealtime.isUserConnected(userId),
});
mountRouter("/api/walkie", chirpRoutes);
mountRouter("/api/chirp", chirpRoutes);
mountRouter("/api/push", pushRouter({ tokens: pushTokens, alertTokens: alertPushTokens }));
mountRouter("/api/history", historyRouter({ history }));
mountRouter("/api/voicemail", voicemailRouter({
  voicemails: voicemail,
  history,
  preferSignedRedirect: Boolean(s3),
  localStorage: localStorage ?? undefined,
}));

if (process.env.NODE_ENV !== "production") {
  app.get("/api/debug/routes", (_req, res) => {
    res.status(200).json({
      app: "oneway-server",
      commit: process.env.GIT_COMMIT_SHA ?? process.env.RAILWAY_GIT_COMMIT_SHA ?? process.env.VERCEL_GIT_COMMIT_SHA ?? "unknown",
      baseURL: process.env.API_BASE_URL ?? null,
      routes: registeredRoutes,
    });
  });
  trackRoutes([{ method: "GET", path: "/api/debug/routes" }]);
}

// -------------------------------------------------------------------------
// WebSocket signalling
// -------------------------------------------------------------------------
const httpServer = http.createServer(app);
ws = new CallWebSocketServer({
  registry,
  path: "/ws/calls",
  onCallInvited: (callerId, calleeId, call) => {
    loadCallerIdentity(callerId)
      .then((callerIdentity) =>
        voipPush.send({
          userId: calleeId,
          callId: call.callId,
          callerId,
          hasVideo: call.hasVideo,
          displayName: callerIdentity.callerDisplay,
          roomName: call.roomName,
          callerNumber: callerIdentity.callerNumber,
          callerName: callerIdentity.callerName,
        })
      )
      .catch(() => {});
  }
});
ws.start(httpServer);
communityRealtime.start(httpServer);
messageRealtime.start(httpServer);
friendRealtime.start(httpServer);

// -------------------------------------------------------------------------
// Startup logging (Local + LAN URL)
// -------------------------------------------------------------------------
initializeServer()
  .then(() => {
    httpServer.listen(PORT, HOST, () => {
      const local = `http://127.0.0.1:${PORT}/health`;
      const lan = detectLanIPv4();
      const lanUrl = lan ? `http://${lan}:${PORT}/health` : null;

      logger.info({ local, lan: lanUrl }, "[server] listening");
      console.log(`[server] Local URL: ${local}`);
      if (lanUrl) console.log(`[server] LAN URL:   ${lanUrl}`);
      logRegisteredRoutes();
    });

    startNightlyLedgerReconciliationJob(prisma);
    startDailySecurityOperationsJob(prisma);
    startPricingAgentMonthlyJob(prisma);
    startMessageExpirationWorker(prisma, messageRealtime);
    startBurnWorker(prisma);
  })
  .catch((error) => {
    logger.error({ err: error }, "[compliance] startup failed");
    process.exitCode = 1;
  });

async function initializeServer(): Promise<void> {
  if (process.env.NODE_ENV === "production"
    && [process.env.PSTN_PROVIDER, process.env.SMS_PROVIDER].some((value) => value?.trim().toLowerCase() === "twilio")) {
    const twilioValidation = validateTwilioProductionEnvironment();
    if (!twilioValidation.ok) {
      const validationMessage = `Twilio production configuration invalid: ${[
        ...twilioValidation.missing.map((name) => `missing ${name}`),
        ...twilioValidation.warnings,
      ].join("; ")}`;
      logger.error(
        {
          missing: twilioValidation.missing,
          warnings: twilioValidation.warnings,
          liveKitSipPathPreserved: true,
        },
        `[twilio] ${validationMessage}`,
      );
      if ((process.env.TWILIO_FAIL_STARTUP_ON_INVALID_CONFIG ?? "").trim().toLowerCase() === "true") {
        throw new Error(validationMessage);
      }
    }
  }
  assertSitePublicationRoutesRegistered(registeredRouteKeys());
  await ensureIdentityWalkieNameColumn(prisma);
  await ensureOneWayContactLifecycleColumns(prisma);
  await ensureFriendshipTable(prisma);
  await ensureWalkieFavoriteTable(prisma);
  await ensureDirectChirpTables(prisma);
  await ensureDevTestAccounts(prisma);
  await ensureExternalConversationPrivacyColumns(prisma);
  await ensurePrivacyLifecycleSchema(prisma);
  await ensurePlatformCapabilityTables(prisma);
  await ensureCommunityTables(prisma);
  await ensurePricingAgentTables(prisma);
  await reconcileAllSitePublicationsOnStartup(prisma);
  await initializeDormantComplianceLayer();
}

async function initializeDormantComplianceLayer(): Promise<void> {
  if (!isComplianceLayerEnabled()) {
    logger.info({}, "OneWay Bank compliance layer disabled. Stripe remains active.");
    console.log("OneWay Bank compliance layer disabled. Stripe remains active.");
    return;
  }

  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const missingSecureEnv = complianceSecureEnvWarnings();
  if (missingSecureEnv.length > 0) {
    logger.warn({
      missingSecureEnv,
      oneWayBankEnabled: process.env.ONEWAY_BANK_ENABLED === "true",
    }, "[compliance] enabled without complete secure provider env; live money movement remains gated");
  }

  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const compliance = require("./services/compliance/complianceService");
  await compliance.initializeCompliance();
}

function complianceSecureEnvWarnings(): string[] {
  const missing = new Set<string>();
  const enabled = (name: string) => ["1", "true", "yes", "on"].includes(String(process.env[name] ?? "").trim().toLowerCase());
  const has = (name: string) => Boolean(String(process.env[name] ?? "").trim());

  if (enabled("LEDGER_ENABLED")) {
    if (!has("MODERN_TREASURY_API_KEY")) missing.add("MODERN_TREASURY_API_KEY");
    if (!has("MODERN_TREASURY_ORG_ID")) missing.add("MODERN_TREASURY_ORG_ID");
  }
  if (enabled("RECONCILIATION_ENABLED")) {
    if (!has("UNIT_API_TOKEN")) missing.add("UNIT_API_TOKEN");
    if (!has("MODERN_TREASURY_API_KEY")) missing.add("MODERN_TREASURY_API_KEY");
    if (!has("MODERN_TREASURY_ORG_ID")) missing.add("MODERN_TREASURY_ORG_ID");
  }
  if (enabled("DISPUTES_ENABLED") && !has("COMPLIANCE_EMAIL")) missing.add("COMPLIANCE_EMAIL");

  return Array.from(missing).sort();
}

function detectLanIPv4(): string | null {
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    const addrs = nets[name] || [];
    for (const addr of addrs) {
      if (addr.family === "IPv4" && !addr.internal) return addr.address;
    }
  }
  return null;
}

async function resolveUserIdForCallTarget(target: string, callerId?: string): Promise<string | null> {
  const trimmed = target.trim();
  if (!trimmed) return null;
  const normalizedUuid = normalizeUUID(trimmed);

  const directUser = await prisma.user.findUnique({
    where: { id: normalizedUuid ?? trimmed },
    select: { id: true },
  });
  if (directUser) return directUser.id;

  if (callerId) {
    const connectedContact = await prisma.oneWayContact.findFirst({
      where: {
        id: normalizedUuid ?? trimmed,
        status: "connected",
        OR: [
          { userId: callerId },
          { contactUserId: callerId },
        ],
      },
      select: { userId: true, contactUserId: true },
    });
    if (connectedContact) {
      return connectedContact.userId === callerId
        ? connectedContact.contactUserId
        : connectedContact.userId;
    }
  }

  const onewayId = trimmed.startsWith("@") ? trimmed.toLowerCase() : `@${trimmed.toLowerCase()}`;
  const identity = await prisma.oneWayIdentity.findUnique({
    where: { onewayId },
    select: { userId: true },
  });
  if (identity) return identity.userId;

  const number = await prisma.userNumber.findUnique({
    where: { number: trimmed.toUpperCase() },
    select: { userId: true },
  });
  return number?.userId ?? null;
}

function normalizeUUID(value: string): string | null {
  return /^[0-9a-fA-F-]{36}$/.test(value) ? value.toLowerCase() : null;
}

function findActiveCallBetween(userA: string, userB: string) {
  return registry.activeForUser(userA).find((call) =>
    (sameUserId(call.callerId, userA) && sameUserId(call.calleeId, userB)) ||
    (sameUserId(call.callerId, userB) && sameUserId(call.calleeId, userA))
  );
}

function normalizeOneWayTarget(value: string): string {
  const trimmed = value.trim();
  if (trimmed.toUpperCase().startsWith("OW-")) {
    return trimmed.toUpperCase();
  }
  if (trimmed.startsWith("@")) {
    return trimmed.toLowerCase();
  }
  return trimmed;
}

async function resolveOneWayNetworkTarget(target: string): Promise<{ userId: string; type: "identity" | "number"; value: string } | null> {
  const normalized = normalizeOneWayTarget(target);

  if (normalized.startsWith("@")) {
    const identity = await prisma.oneWayIdentity.findUnique({
      where: { onewayId: normalized },
      select: { userId: true, onewayId: true },
    });
    if (!identity) return null;
    return { userId: identity.userId, type: "identity", value: identity.onewayId };
  }

  if (normalized.toUpperCase().startsWith("OW-")) {
    const number = await prisma.userNumber.findUnique({
      where: { number: normalized.toUpperCase() },
      select: { userId: true, number: true },
    });
    if (!number) return null;
    return { userId: number.userId, type: "number", value: number.number };
  }

  return null;
}
