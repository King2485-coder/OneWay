import "dotenv/config";

import cors from "cors";
import express from "express";
import http from "http";
import os from "os";
import crypto from "node:crypto";
import path from "node:path";
import * as Sentry from "@sentry/node";

import { prisma } from "./lib/db";
import { logger } from "./lib/logger";
import { redis, redisSubscriber } from "./lib/redis";

import { aiRouter } from "./routes/ai";
import { adsRouter } from "./routes/ads";
import { authRouter } from "./routes/auth";
import { callsRouter } from "./routes/calls";
import { historyRouter } from "./routes/history";
import { liveKitRouter } from "./routes/livekit";
import { featuredRouter } from "./routes/featured";
import { ordersRouter } from "./routes/orders";
import { productsRouter } from "./routes/products";
import { pushRouter } from "./routes/push";
import { recordingsRouter } from "./routes/recordings";
import { searchRouter } from "./routes/search";
import { storesRouter } from "./routes/stores";
import { storefrontsRouter } from "./routes/storefronts";
import { turnRouter } from "./routes/turn";
import { uploadsRouter } from "./routes/uploads";
import { voicemailRouter } from "./routes/voicemail";
import { pstnRouter } from "./routes/pstn";

import { CallRegistry } from "./services/CallRegistry";
import type { ICallRegistry } from "./services/CallRegistry";
import { RedisCallRegistry } from "./services/RedisCallRegistry";
import { LiveKitTokenService } from "./services/LiveKitTokenService";
import { PushTokenStore } from "./services/PushTokenStore";
import { VoIPPushService } from "./services/VoIPPushService";
import { CallHistoryService } from "./services/CallHistoryService";
import { VoicemailService } from "./services/VoicemailService";
import { StubPSTNProvider } from "./services/pstn/StubPSTNProvider";
import { TwilioPSTNProvider } from "./services/pstn/TwilioPSTNProvider";
import { TelnyxPSTNProvider } from "./services/pstn/TelnyxPSTNProvider";
import type { PSTNProvider } from "./services/pstn/PSTNProvider";

import { CallWebSocketServer } from "./realtime/CallWebSocketServer";
import { LocalObjectStorage } from "./lib/storage/LocalObjectStorage";
import { S3ObjectStorage } from "./lib/storage/S3ObjectStorage";
import type { ObjectStorage } from "./lib/storage/ObjectStorage";
import { authMiddleware, type AuthenticatedRequest } from "./middleware/auth";
import { sanitizeRoomName } from "./types/calls";

const PORT = Number(process.env.PORT ?? 3000);
const HOST = process.env.HOST ?? "0.0.0.0";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  tracesSampleRate: 1.0,
});

const app = express();
app.disable("x-powered-by");
app.use(cors({
  origin: process.env.CORS_ORIGIN?.split(",").map((value) => value.trim()).filter(Boolean) || true,
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
  credentials: true,
}));
app.use(express.json({ limit: "10mb" }));
app.use("/uploads", express.static(path.join(process.cwd(), "uploads")));

// -------------------------------------------------------------------------
// Health
// -------------------------------------------------------------------------
app.get("/health", (_req, res) => {
  res.status(200).json({
    ok: true,
    status: "live",
    app: "oneway-server",
    time: new Date().toISOString(),
  });
});

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
    const result = await livekit.issue({
      roomName: sanitizeRoomName(room),
      identity: userId,
      ttlSeconds: 3600,
    });
    res.json({ token: result.token });
  } catch (error) {
    logger.error({ err: error }, "[livekit] query token issue failed");
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
  const calleeUserId = typeof req.body?.calleeUserId === "string" ? req.body.calleeUserId : "";
  const callerName = typeof req.body?.callerName === "string" ? req.body.callerName : userId;
  const roomName = typeof req.body?.roomName === "string" ? sanitizeRoomName(req.body.roomName) : "";
  const hasVideo = typeof req.body?.hasVideo === "boolean" ? req.body.hasVideo : true;

  if (!calleeUserId || !roomName) {
    res.status(400).json({ error: "calleeUserId_and_roomName_required" });
    return;
  }

  const callId = crypto.randomUUID();

  try {
    await voipPush.send({
      userId: calleeUserId,
      callId,
      callerId: userId,
      hasVideo,
      displayName: callerName,
      roomName,
    });

    res.json({
      ok: true,
      callId,
      roomName,
      callerName,
    });
  } catch (error) {
    logger.error({ err: error }, "[calls] invite push failed");
    res.status(500).json({ error: "invite_failed" });
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
const voipPush = new VoIPPushService(pushTokens);
const history = new CallHistoryService();

// Object storage for voicemail audio: S3/R2 if configured, otherwise local disk.
const s3 = S3ObjectStorage.fromEnv();
const localStorage = s3 ? null : new LocalObjectStorage();
const storage: ObjectStorage = s3 ?? localStorage!;
const voicemail = new VoicemailService(storage);

const livekit = LiveKitTokenService.fromEnv();

const pstnProvider: PSTNProvider = (() => {
  const provider = (process.env.PSTN_PROVIDER ?? "stub").toLowerCase();
  switch (provider) {
    case "twilio":
      return new TwilioPSTNProvider();
    case "telnyx":
      return new TelnyxPSTNProvider();
    default:
      return new StubPSTNProvider();
  }
})();

// -------------------------------------------------------------------------
// REST routes
// -------------------------------------------------------------------------
app.use("/auth", authRouter());
app.use("/api/auth", authRouter());
app.use("/stores", storesRouter({ prisma }));
app.use("/api/stores", storesRouter({ prisma }));
app.use("/products", productsRouter({ prisma }));
app.use("/api/products", productsRouter({ prisma }));
app.use("/featured", featuredRouter({ prisma }));
app.use("/api/featured", featuredRouter({ prisma }));
app.use("/orders", ordersRouter({ prisma }));
app.use("/api/orders", ordersRouter({ prisma }));
app.use("/uploads", uploadsRouter());
app.use("/api/uploads", uploadsRouter());
app.use("/api/storefronts", storefrontsRouter({ prisma }));
app.use("/search", searchRouter({ prisma }));
app.use("/api/search", searchRouter({ prisma }));
app.use("/api/ai", aiRouter({ prisma }));
app.use("/api/ads", adsRouter({ prisma }));
app.use("/api/turn-credentials", turnRouter());
app.use("/recordings", recordingsRouter());
app.use("/api/recordings", recordingsRouter());
app.use("/api/calls", callsRouter({
  registry,
  onCallInvited: (callerId, calleeId, call) => {
    // Best-effort VoIP push fan-out (does nothing if APNs creds missing).
    voipPush
      .send({
        userId: calleeId,
        callId: call.callId,
        callerId,
        hasVideo: call.hasVideo,
        displayName: callerId,
        roomName: call.roomName,
      })
      .catch(() => {});
  }
}));
app.use("/api/livekit", liveKitRouter({ registry, tokens: livekit }));
app.use("/api/push", pushRouter({ tokens: pushTokens }));
app.use("/api/history", historyRouter({ history }));
app.use("/api/voicemail", voicemailRouter({
  voicemails: voicemail,
  history,
  preferSignedRedirect: Boolean(s3),
  localStorage: localStorage ?? undefined,
}));
app.use("/api/pstn", pstnRouter(pstnProvider));

// -------------------------------------------------------------------------
// WebSocket signalling
// -------------------------------------------------------------------------
const httpServer = http.createServer(app);
const ws = new CallWebSocketServer({
  registry,
  path: "/ws/calls",
  onCallInvited: (callerId, calleeId, call) => {
    voipPush
      .send({
        userId: calleeId,
        callId: call.callId,
        callerId,
        hasVideo: call.hasVideo,
        displayName: callerId,
        roomName: call.roomName,
      })
      .catch(() => {});
  }
});
ws.start(httpServer);

// -------------------------------------------------------------------------
// Startup logging (Local + LAN URL)
// -------------------------------------------------------------------------
httpServer.listen(PORT, HOST, () => {
  const local = `http://127.0.0.1:${PORT}/health`;
  const lan = detectLanIPv4();
  const lanUrl = lan ? `http://${lan}:${PORT}/health` : null;

  logger.info({ local, lan: lanUrl }, "[server] listening");
  console.log(`[server] Local URL: ${local}`);
  if (lanUrl) console.log(`[server] LAN URL:   ${lanUrl}`);
});

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
