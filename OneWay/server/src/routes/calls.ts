import express from "express";
import { randomUUID } from "crypto";
import { z } from "zod";
import type { ICallRegistry } from "../services/CallRegistry";
import { RegistryError, isTerminal } from "../services/CallRegistry";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { isParticipant, sameUserId } from "../types/calls";
import { inviteRateLimit } from "../lib/rateLimit";
import { logger } from "../lib/logger";
import { prisma } from "../lib/db";
import type { LiveKitTokenService } from "../services/LiveKitTokenService";

/**
 * REST counterpart to the WebSocket layer. Every call lifecycle action has a
 * REST endpoint *and* a WS event — they share the same `CallRegistry` so a
 * client can mix and match (REST-only as fallback, WS-only for low latency,
 * or both for resilience).
 */

interface CallsRouterDeps {
  registry: ICallRegistry;
  /** Hook the WebSocket server provides so we can fan-out REST-driven
   *  changes to any other connected sockets the user owns. */
  onCallChanged?: (call: ReturnType<ICallRegistry["get"]>) => void;
  /** Sends a VoIP push to wake the callee's app if it's backgrounded /
   *  killed. Optional — when missing, only the WS path notifies. */
  onCallInvited?: (callerId: string, calleeId: string, call: NonNullable<ReturnType<ICallRegistry["get"]>>) => void;
  isUserConnected?: (userId: string) => boolean;
  hasPushToken?: (userId: string) => Promise<boolean>;
  inviteRateLimit?: RateLimitConfig;
  livekit?: LiveKitTokenService;
}

interface RateLimitConfig {
  windowMs: number;
  max: number; // max invites per user per window
}

const createCallSchema = z.object({
  recipientUserId: z.string().min(1).max(128),
  type: z.enum(["audio", "video"]).optional().default("audio"),
});

const inviteSchema = z.object({
  calleeId: z.string().min(1).max(128),
  hasVideo: z.boolean().optional().default(false),
});

const callIdSchema = z.object({
  callId: z.string().uuid().transform((value) => value.toLowerCase()),
});

const endCallSchema = z.object({
  reason: z.string().optional().default("localHangup"),
  source: z.string().optional(),
  endedByUserId: z.string().optional(),
  clientOperationId: z.string().optional(),
  operationId: z.string().optional(),
});

const mediaReadySchema = z.object({
  audioPublished: z.boolean().optional().default(false),
  videoPublished: z.boolean().optional().default(false),
  audioPublicationSid: z.string().optional(),
  videoPublicationSid: z.string().optional(),
});

export const SUPPORTED_CALL_ROUTES = [
  "POST /api/calls",
  "GET /api/calls/:callId",
  "POST /api/calls/:callId/accept",
  "POST /api/calls/:callId/join",
  "POST /api/calls/:callId/media-ready",
  "POST /api/calls/:callId/end",
] as const;

export function callsRouter(deps: CallsRouterDeps): express.Router {
  const router = express.Router();
  const limiter = makeLimiter(deps.inviteRateLimit ?? { windowMs: 60_000, max: 20 });

  // Every route below requires auth.
  router.use(authMiddleware);

  // POST /api/calls ---------------------------------------------------------
  router.post("/", inviteRateLimit(), async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    if (!limiter.consume(userId)) {
      res.status(429).json({ error: "rate_limited", message: "too many calls" });
      return;
    }
    const parsed = createCallSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    await createCall(req, res, deps, {
      requestedRecipientId: parsed.data.recipientUserId,
      type: parsed.data.type,
    });
  });

  // POST /api/calls/invite ---------------------------------------------------
  router.post("/invite", inviteRateLimit(), async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    if (!limiter.consume(userId)) {
      res.status(429).json({ error: "rate_limited", message: "too many invites" });
      return;
    }
    const parsed = inviteSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    await createCall(req, res, deps, {
      requestedRecipientId: parsed.data.calleeId,
      type: parsed.data.hasVideo ? "video" : "audio",
    });
  });

  // POST /api/calls/:callId/accept -----------------------------------------
  router.post("/:callId/accept", async (req, res) => {
    const callId = req.params.callId.toLowerCase();
    if (!/^[0-9a-fA-F-]{36}$/.test(callId)) {
      res.status(400).json({ error: "invalid_call_id" });
      return;
    }
    await acceptCall(req, res, deps, callId);
  });

  // POST /api/calls/accept ---------------------------------------------------
  router.post("/accept", async (req, res) => {
    const parsed = callIdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    await acceptCall(req, res, deps, parsed.data.callId);
  });

  // POST /api/calls/:callId/join -------------------------------------------
  // Authoritative media-join handshake. Accepting the invitation is not the
  // same thing as joining LiveKit; each device must fetch a fresh token for
  // the stored roomName before it attempts media.
  router.post("/:callId/join", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const callId = req.params.callId.toLowerCase();
    if (!/^[0-9a-fA-F-]{36}$/.test(callId)) {
      res.status(400).json({ error: "invalid_call_id" });
      return;
    }
    const call = deps.registry.get(callId);
    if (!call) {
      logger.warn({ userId, callId }, "[calls] join failed: not found");
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isParticipant(call, userId)) {
      logger.warn({ userId, callId, callerId: call.callerId, calleeId: call.calleeId }, "[calls] join failed: not participant");
      res.status(403).json({ error: "not_participant" });
      return;
    }
    if (isTerminal(call.status)) {
      res.status(409).json({ error: "call_terminal", state: call.status });
      return;
    }
    const now = Date.now();
    const updated = deps.registry.updateStatus(
      call.callId,
      call.status === "connected" ? "connected" : "joining",
      (c) => {
        if (!c.participants.some((participant) => sameUserId(participant, userId))) {
          c.participants.push(userId);
        }
        if (sameUserId(c.callerId, userId)) c.callerJoinedAt = c.callerJoinedAt ?? now;
        if (sameUserId(c.calleeId, userId)) c.recipientJoinedAt = c.recipientJoinedAt ?? now;
      }
    );
    deps.onCallChanged?.(updated);
    await respondJoin(res, deps, updated, userId);
  });

  // POST /api/calls/:callId/media-ready ------------------------------------
  router.post("/:callId/media-ready", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const callId = req.params.callId.toLowerCase();
    if (!/^[0-9a-fA-F-]{36}$/.test(callId)) {
      res.status(400).json({ error: "invalid_call_id" });
      return;
    }
    const parsed = mediaReadySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const call = deps.registry.get(callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isParticipant(call, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }
    if (isTerminal(call.status)) {
      res.status(409).json({ error: "call_terminal", state: call.status });
      return;
    }
    const now = Date.now();
    const role = sameUserId(call.callerId, userId) ? "caller" : "recipient";
    const shouldConnect = (candidate: typeof call): boolean => {
      const callerAudioReady = sameUserId(call.callerId, userId)
        ? parsed.data.audioPublished
        : Boolean(candidate.callerMediaReadyAt);
      const recipientAudioReady = sameUserId(call.calleeId, userId)
        ? parsed.data.audioPublished
        : Boolean(candidate.recipientMediaReadyAt);
      return Boolean(candidate.callerJoinedAt && candidate.recipientJoinedAt && callerAudioReady && recipientAudioReady);
    };
    const nextStatus = shouldConnect(call) ? "connected" : call.status === "connected" ? "connected" : "joining";
    const updated = deps.registry.updateStatus(call.callId, nextStatus, (c) => {
      if (sameUserId(c.callerId, userId)) {
        if (parsed.data.audioPublished) c.callerMediaReadyAt = c.callerMediaReadyAt ?? now;
        if (parsed.data.audioPublicationSid) c.callerAudioPublicationSid = parsed.data.audioPublicationSid;
        if (parsed.data.videoPublicationSid) c.callerVideoPublicationSid = parsed.data.videoPublicationSid;
      } else {
        if (parsed.data.audioPublished) c.recipientMediaReadyAt = c.recipientMediaReadyAt ?? now;
        if (parsed.data.audioPublicationSid) c.recipientAudioPublicationSid = parsed.data.audioPublicationSid;
        if (parsed.data.videoPublicationSid) c.recipientVideoPublicationSid = parsed.data.videoPublicationSid;
      }
      if (nextStatus === "connected") c.connectedAt = c.connectedAt ?? now;
    });
    deps.onCallChanged?.(updated);
    logger.info({
      callId: updated.callId,
      userId,
      role,
      roomName: updated.roomName,
      status: updated.status,
      version: updated.version,
      audioPublished: parsed.data.audioPublished,
      videoPublished: parsed.data.videoPublished,
      audioPublicationSid: parsed.data.audioPublicationSid,
      videoPublicationSid: parsed.data.videoPublicationSid,
    }, "[calls] participant media ready");
    res.json({
      call: updated,
      callId: updated.callId,
      status: updated.status,
      version: updated.version ?? 1,
      connected: updated.status === "connected",
    });
  });

  // POST /api/calls/decline --------------------------------------------------
  router.post("/decline", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = callIdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const call = deps.registry.get(parsed.data.callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!sameUserId(call.calleeId, userId)) {
      res.status(403).json({ error: "not_callee" });
      return;
    }
    if (isTerminal(call.status)) {
      res.json({ call });
      return;
    }
    try {
      const updated = deps.registry.updateStatus(call.callId, "declined");
      deps.onCallChanged?.(updated);
      res.json({ call: updated });
    } catch (err) {
      respondRegistryError(res, err);
    }
  });

  // POST /api/calls/hangup ---------------------------------------------------
  router.post("/hangup", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = callIdSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    endCall(req, res, deps, parsed.data.callId, {
      reason: "localHangup",
      clientOperationId: undefined,
    });
  });

  // POST /api/calls/:callId/end ---------------------------------------------
  router.post("/:callId/end", (req, res) => {
    const callId = req.params.callId.toLowerCase();
    if (!/^[0-9a-fA-F-]{36}$/.test(callId)) {
      res.status(400).json({ error: "invalid_call_id" });
      return;
    }
    const parsed = endCallSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    endCall(req, res, deps, callId, parsed.data);
  });

  // GET /api/calls/active ----------------------------------------------------
  // Note: this MUST come before the /:callId route so Express doesn't
  // capture "active" as a UUID.
  router.get("/active", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    res.json({ calls: deps.registry.activeForUser(userId) });
  });

  // GET /api/calls/:callId ---------------------------------------------------
  router.get("/:callId", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const callId = req.params.callId.toLowerCase();
    if (!/^[0-9a-fA-F-]{36}$/.test(callId)) {
      res.status(400).json({ error: "invalid_call_id" });
      return;
    }
    const call = deps.registry.get(callId);
    if (!call) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    if (!isParticipant(call, userId)) {
      res.status(403).json({ error: "not_participant" });
      return;
    }
    res.json({ call });
  });

  return router;
}

async function createCall(
  req: express.Request,
  res: express.Response,
  deps: CallsRouterDeps,
  input: { requestedRecipientId: string; type: "audio" | "video" }
): Promise<void> {
  const userId = (req as unknown as AuthenticatedRequest).userId;
  const requestedRecipientId = input.requestedRecipientId.trim();
  const recipientId = await resolveCalleeIdForInvite(userId, requestedRecipientId);

  if (!recipientId) {
    logger.warn({ callerId: userId, requestedRecipientId }, "[calls] create failed: recipient not found");
    res.status(404).json({
      error: "recipient_not_found",
      message: "That OneWay contact is not signed in on this backend.",
    });
    return;
  }

  if (sameUserId(recipientId, userId)) {
    res.status(400).json({ error: "self_call_forbidden" });
    return;
  }

  const [recipientHasActiveSocket, recipientHasPushToken] = await Promise.all([
    Promise.resolve(deps.isUserConnected?.(recipientId) ?? false),
    deps.hasPushToken?.(recipientId) ?? Promise.resolve(false),
  ]);
  logger.info({
    callerUserId: userId,
    requestedRecipientId,
    recipientUserId: recipientId,
    type: input.type,
    recipientHasActiveSocket,
    recipientHasPushToken,
  }, "[calls] create reachability");

  if (!recipientHasActiveSocket && !recipientHasPushToken) {
    res.status(409).json({
      error: "recipient_unreachable",
      message: "That OneWay contact is not connected right now. Open OneWay on both phones and try again.",
    });
    return;
  }

  const existingCall = findActiveCallBetween(deps.registry, userId, recipientId);
  if (existingCall) {
    logger.info({
      callerUserId: userId,
      requestedRecipientId,
      recipientUserId: recipientId,
      callId: existingCall.callId,
      status: existingCall.status,
    }, "[calls] create reused active call");
    res.status(200).json(callSummaryResponse(existingCall));
    return;
  }

  const call = deps.registry.createCall({
    callerId: userId,
    calleeId: recipientId,
    hasVideo: input.type === "video",
    turnEnabled: true,
  });
  logVideoCallTimeline("video.call.created", call, userId, {
    conversationId: requestedRecipientId,
    participantIdentity: liveKitParticipantIdentity(userId),
    callStatus: call.status,
  });
  deps.onCallChanged?.(call);
  logVideoCallTimeline("video.call.invite.sent", call, userId, {
    conversationId: requestedRecipientId,
    callStatus: call.status,
  });
  deps.onCallInvited?.(userId, recipientId, call);
  res.status(201).json(callSummaryResponse(call));
}

async function acceptCall(
  req: express.Request,
  res: express.Response,
  deps: CallsRouterDeps,
  callId: string
): Promise<void> {
  const userId = (req as unknown as AuthenticatedRequest).userId;
  const call = deps.registry.get(callId);
  if (!call) {
    logger.warn({ userId, callId }, "[calls] accept failed: not found");
    res.status(404).json({ error: "not_found" });
    return;
  }
  if (!sameUserId(call.calleeId, userId)) {
    logger.warn({ userId, callId: call.callId, callerId: call.callerId, calleeId: call.calleeId }, "[calls] accept failed: not recipient");
    res.status(403).json({ error: "not_recipient" });
    return;
  }
  if (isTerminal(call.status)) {
    res.status(409).json({ error: "call_terminal", state: call.status });
    return;
  }
  logVideoCallTimeline("video.call.accept.requested", call, userId, {
    participantIdentity: liveKitParticipantIdentity(userId),
    callStatus: call.status,
  });
  if (call.status !== "ringing" && call.status !== "accepting" && call.status !== "accepted" && call.status !== "joining" && call.status !== "connected") {
    logger.warn({ userId, callId: call.callId, status: call.status }, "[calls] accept failed: wrong state");
    res.status(409).json({ error: "wrong_state", state: call.status });
    return;
  }
  try {
    const updated = deps.registry.updateStatus(
      call.callId,
      call.status === "connected" ? "connected" : call.status === "joining" ? "joining" : "accepting",
      (c) => {
        c.recipientAcceptedAt = c.recipientAcceptedAt ?? Date.now();
        c.acceptedAt = c.acceptedAt ?? c.recipientAcceptedAt;
        if (!c.participants.some((participant) => sameUserId(participant, userId))) {
          c.participants.push(userId);
        }
      }
    );
    deps.onCallChanged?.(updated);
    logVideoCallTimeline("video.call.accepted.backend", updated, userId, {
      participantIdentity: liveKitParticipantIdentity(userId),
      callStatus: updated.status,
    });
    logger.info({
      userId,
      callId: updated.callId,
      roomName: updated.roomName,
      callerId: updated.callerId,
      calleeId: updated.calleeId,
      status: updated.status,
      version: updated.version,
    }, "[calls] accepted");
    respondAccepted(res, updated);
  } catch (err) {
    logger.error({ err, userId, callId: call.callId }, "[calls] accept failed");
    respondRegistryError(res, err);
  }
}

function endCall(
  req: express.Request,
  res: express.Response,
  deps: CallsRouterDeps,
  callId: string,
  input: { reason?: string; source?: string; endedByUserId?: string; clientOperationId?: string; operationId?: string }
): void {
  const userId = (req as unknown as AuthenticatedRequest).userId;
  const call = deps.registry.get(callId);
  const operationId = input.operationId ?? input.clientOperationId ?? randomUUID();
  if (!call) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  if (!isParticipant(call, userId)) {
    res.status(403).json({ error: "not_participant" });
    return;
  }
  if (isTerminal(call.status)) {
    deps.onCallChanged?.(call);
    logger.info({
      userId,
      callId: call.callId,
      status: call.status,
      reason: input.reason,
      source: input.source,
      operationId,
    }, "[calls] end idempotent replay");
    res.json({
      call,
      callId: call.callId,
      status: call.status,
      version: call.version ?? 1,
      alreadyEnded: true,
      endedByUserId: input.endedByUserId ?? userId,
      reason: input.reason ?? "localHangup",
      operationId,
      endedAt: call.endedAt ? new Date(call.endedAt).toISOString() : new Date().toISOString(),
    });
    return;
  }
  try {
    const previousStatus = call.status;
    const updated = deps.registry.updateStatus(call.callId, "ended", (c) => {
      c.endedByUserId = input.endedByUserId ?? userId;
      c.endReason = input.reason ?? "localHangup";
      if (operationId) {
        c.endOperationIds = Array.from(new Set([...(c.endOperationIds ?? []), operationId]));
      }
    });
    deps.onCallChanged?.(updated);
    logger.info({
      userId,
      callId: updated.callId,
      roomName: updated.roomName,
      previousStatus,
      currentStatus: updated.status,
      endedByUserId: input.endedByUserId ?? userId,
      reason: input.reason ?? "localHangup",
      source: input.source ?? "unknown",
      operationId,
    }, "[calls] ended");
    res.json({
      call: updated,
      callId: updated.callId,
      status: updated.status,
      version: updated.version ?? 1,
      alreadyEnded: false,
      endedByUserId: input.endedByUserId ?? userId,
      reason: input.reason ?? "localHangup",
      operationId,
      endedAt: updated.endedAt ? new Date(updated.endedAt).toISOString() : new Date().toISOString(),
    });
  } catch (err) {
    respondRegistryError(res, err);
  }
}

function respondAccepted(
  res: express.Response,
  call: NonNullable<ReturnType<ICallRegistry["get"]>>
): void {
  res.json(callSummaryResponse(call));
}

async function respondJoin(
  res: express.Response,
  deps: CallsRouterDeps,
  call: NonNullable<ReturnType<ICallRegistry["get"]>>,
  userId: string
): Promise<void> {
  if (!deps.livekit?.isConfigured()) {
    res.status(503).json({ error: "livekit_not_configured" });
    return;
  }
  try {
    const participantIdentity = liveKitParticipantIdentity(userId);
    const token = await deps.livekit.issue({
      roomName: call.roomName,
      identity: participantIdentity,
      metadata: JSON.stringify({
        userId,
        callId: call.callId,
        roomName: call.roomName,
        role: sameUserId(call.callerId, userId) ? "caller" : "recipient",
        joinType: "authoritative",
      }),
      ttlSeconds: 3600,
    });
    const role = sameUserId(call.callerId, userId) ? "caller" : "recipient";
    const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();
    logVideoCallTimeline("call.participant.join.credentialsIssued", call, userId, {
      participantIdentity,
      callStatus: call.status,
      liveKitUrl: token.liveKitUrl,
    });
    res.json({
      call,
      callId: call.callId,
      liveKitToken: token.token,
      token: token.token,
      liveKitUrl: token.liveKitUrl,
      roomName: token.roomName,
      participantIdentity,
      role,
      type: call.hasVideo ? "video" : "audio",
      status: call.status,
      version: call.version ?? 1,
      expiresAt,
      sessionVersion: call.version ?? 1,
    });
  } catch (err) {
    logger.error({ err, userId, callId: call.callId, roomName: call.roomName }, "[calls] join token issue failed");
    res.status(500).json({ error: "token_issue_failed" });
  }
}

function callSummaryResponse(call: NonNullable<ReturnType<ICallRegistry["get"]>>): Record<string, unknown> {
  return {
    call,
    callId: call.callId,
    callerUserId: call.callerId,
    recipientUserId: call.calleeId,
    type: call.hasVideo ? "video" : "audio",
    status: call.status,
    roomName: call.roomName,
    version: call.version ?? 1,
    callerJoinedAt: call.callerJoinedAt ? new Date(call.callerJoinedAt).toISOString() : null,
    recipientJoinedAt: call.recipientJoinedAt ? new Date(call.recipientJoinedAt).toISOString() : null,
    callerMediaReadyAt: call.callerMediaReadyAt ? new Date(call.callerMediaReadyAt).toISOString() : null,
    recipientMediaReadyAt: call.recipientMediaReadyAt ? new Date(call.recipientMediaReadyAt).toISOString() : null,
    connectedAt: call.connectedAt ? new Date(call.connectedAt).toISOString() : null,
    endedAt: call.endedAt ? new Date(call.endedAt).toISOString() : null,
  };
}

function liveKitParticipantIdentity(userId: string): string {
  return `oneway-user-${userId.toLowerCase()}`;
}

function logVideoCallTimeline(
  event: string,
  call: NonNullable<ReturnType<ICallRegistry["get"]>>,
  currentUserId: string,
  extra: Record<string, unknown> = {}
): void {
  if (!call.hasVideo) return;
  logger.info({
    event,
    callId: call.callId,
    conversationId: extra.conversationId ?? call.calleeId,
    callerUserId: call.callerId,
    recipientUserId: call.calleeId,
    currentUserId,
    roomName: call.roomName,
    callStatus: call.status,
    timestamp: new Date().toISOString(),
    durationMs: Date.now() - call.createdAt,
    ...extra,
  }, "[video-call] timeline");
}

// ---- Helpers ---------------------------------------------------------------

function respondRegistryError(res: express.Response, err: unknown): void {
  if (err instanceof RegistryError) {
    const status = err.code === "not_found" ? 404 : 409;
    res.status(status).json({ error: err.code, message: err.message });
    return;
  }
  logger.error({ err }, "[calls] unexpected error");
  res.status(500).json({ error: "internal_error" });
}

async function resolveCalleeIdForInvite(callerId: string, target: string): Promise<string | null> {
  const trimmed = target.trim();
  if (!trimmed) return null;
  const normalizedUuid = normalizeUUID(trimmed);

  const directUser = await prisma.user.findUnique({
    where: { id: normalizedUuid ?? trimmed },
    select: { id: true },
  });
  if (directUser) return directUser.id;

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

  const normalizedIdentity = trimmed.startsWith("@") ? trimmed.toLowerCase() : `@${trimmed.toLowerCase()}`;
  const identity = await prisma.oneWayIdentity.findUnique({
    where: { onewayId: normalizedIdentity },
    select: { userId: true },
  });
  if (identity) return identity.userId;

  const normalizedNumber = trimmed.toUpperCase();
  const number = await prisma.userNumber.findUnique({
    where: { number: normalizedNumber },
    select: { userId: true },
  });
  return number?.userId ?? null;
}

function normalizeUUID(value: string): string | null {
  return /^[0-9a-fA-F-]{36}$/.test(value) ? value.toLowerCase() : null;
}

function findActiveCallBetween(registry: ICallRegistry, userA: string, userB: string) {
  return registry.activeForUser(userA).find((call) =>
    (sameUserId(call.callerId, userA) && sameUserId(call.calleeId, userB)) ||
    (sameUserId(call.callerId, userB) && sameUserId(call.calleeId, userA))
  );
}

interface Limiter {
  consume(userId: string): boolean;
}

/** Token-bucket-ish per-user invite limiter. Memory-only; per-process. */
function makeLimiter(cfg: RateLimitConfig): Limiter {
  const buckets = new Map<string, { count: number; resetAt: number }>();
  return {
    consume(userId: string): boolean {
      const now = Date.now();
      let b = buckets.get(userId);
      if (!b || b.resetAt < now) {
        b = { count: 0, resetAt: now + cfg.windowMs };
        buckets.set(userId, b);
      }
      if (b.count >= cfg.max) return false;
      b.count += 1;
      return true;
    },
  };
}
