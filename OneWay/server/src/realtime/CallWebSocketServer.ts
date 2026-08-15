/**
 * WebSocket signalling for the OneWay calling system.
 *
 * Wraps the `ws` package and re-exposes a small interface tailored to the
 * call lifecycle. Every message is JSON: `{ type: ClientEvent | ServerEvent,
 * payload: ... }`. Auth is performed *after* the connection upgrades — the
 * client's first message must be `{ type: "auth", payload: { token } }` or
 * we close the socket. Until that handshake completes the socket is in a
 * limbo state and cannot send other events.
 *
 * The server is the only place that fan-outs `call:ringing` /
 * `call:accepted` / `call:declined` / `call:ended` events. The REST routes
 * mutate the registry; this class subscribes to `call:changed` /
 * `call:removed` events from the registry and pushes them to every socket
 * the affected users own.
 *
 * Heartbeat: every 25 s we send a `ping` frame; sockets that don't reply
 * within 5 s get terminated. The iOS client transparently reconnects.
 *
 * This file uses a typed shape for `ws` *without* importing the package at
 * module load — that way the server still compiles even before
 * `npm install ws` runs. At runtime the package is required inside `start()`
 * and a clear log line points the operator at the install command.
 */

import type { Server as HTTPServer, IncomingMessage } from "http";
import type { ICallRegistry } from "../services/CallRegistry";
import { parseAuthToken } from "../middleware/auth";
import { logger } from "../lib/logger";
import type {
  CallSession,
  ClientMessage,
  ServerEvent,
  ServerMessage,
  AuthPayload,
  CallIdPayload,
  InvitePayload,
  CallSignalPayload,
  PresenceUpdatePayload,
} from "../types/calls";
import { normalizeUserIdForCompare, sameUserId } from "../types/calls";

// ---- Minimal local typings for `ws` ---------------------------------------
// Bundling our own typings keeps the file compiling without @types/ws.
interface WSLike {
  readyState: number;
  on(event: "message", cb: (data: Buffer | string) => void): void;
  on(event: "close", cb: () => void): void;
  on(event: "pong", cb: () => void): void;
  send(data: string): void;
  ping(): void;
  terminate(): void;
  close(code?: number, reason?: string): void;
}
interface WSServerLike {
  on(event: "connection", cb: (ws: WSLike, req: IncomingMessage) => void): void;
  emit(event: "connection", ws: WSLike, req: IncomingMessage): void;
  handleUpgrade(req: IncomingMessage, socket: any, head: Buffer, cb: (ws: WSLike) => void): void;
  clients: Set<WSLike>;
  close(): void;
}
const WS_OPEN = 1;

function bearerToken(value: string | string[] | undefined): string | undefined {
  const raw = Array.isArray(value) ? value[0] : value;
  if (!raw) return undefined;
  return raw.replace(/^Bearer\s+/i, "").trim() || undefined;
}

function tokenFromRequestUrl(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const parsed = new URL(value, "http://oneway.local");
    return bearerToken(parsed.searchParams.get("token") ?? parsed.searchParams.get("access_token") ?? undefined);
  } catch {
    return undefined;
  }
}

// ---- Public API -----------------------------------------------------------

export interface CallWebSocketServerDeps {
  registry: ICallRegistry;
  /** Path under the HTTP server. Default `/ws/calls`. */
  path?: string;
  /** Fired when a call is created via the WS `call:invite` event. Hosts
   *  use this to send a VoIP push to the callee, mirroring the REST hook. */
  onCallInvited?: (callerId: string, calleeId: string, call: CallSession) => void;
}

export class CallWebSocketServer {
  private wss: WSServerLike | null = null;
  private socketsByUser = new Map<string, Set<WSLike>>();
  private userOfSocket = new WeakMap<WSLike, string>();
  private heartbeat: NodeJS.Timeout | null = null;
  private alive = new WeakSet<WSLike>();
  private ringingFanoutCallIds = new Set<string>();
  private lastFanoutFingerprintByCallId = new Map<string, string>();

  constructor(private readonly deps: CallWebSocketServerDeps) {}

  start(httpServer: HTTPServer): void {
    // `ws` historically exported the server class as `Server`. Newer
    // versions also expose `WebSocketServer`. Support both shapes.
    let WSConstructor: { new (opts: { server?: HTTPServer; path?: string; noServer?: boolean }): WSServerLike };
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const wsModule = require("ws");
      WSConstructor = (wsModule.WebSocketServer ?? wsModule.Server) as typeof WSConstructor;
    } catch {
      console.warn(
        "[ws] `ws` package not installed. WebSocket signalling disabled. " +
          "Run `npm install ws` to enable real-time call events."
      );
      return;
    }

    if (!WSConstructor) {
      console.warn(
        "[ws] `ws` loaded but did not export a WebSocket server constructor. WebSocket signalling disabled."
      );
      return;
    }

    const path = this.deps.path ?? "/ws/calls";
    this.wss = new WSConstructor({ noServer: true });
    httpServer.on("upgrade", (req, socket, head) => {
      if (!this.isPathMatch(req.url, path)) return;
      this.wss?.handleUpgrade(req, socket, head, (ws) => {
        this.wss?.emit?.("connection", ws, req);
      });
    });
    this.wss.on("connection", (socket, req) => this.onConnection(socket, req));

    this.deps.registry.on("call:changed", (call: CallSession) => this.fanOutCallChange(call));
    this.deps.registry.on("call:removed", (call: CallSession) => this.fanOutCallEnded(call));

    this.heartbeat = setInterval(() => this.runHeartbeat(), 25_000);
    this.heartbeat.unref();
  }

  private isPathMatch(url: string | undefined, expectedPath: string): boolean {
    try {
      return new URL(url ?? "", "http://oneway.local").pathname === expectedPath;
    } catch {
      return false;
    }
  }

  stop(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
    this.wss?.close();
    this.wss = null;
  }

  /** Hook the REST layer calls after it mutates a call so connected sockets
   *  see the same events even if the registry already broadcast them. The
   *  registry's own emitter is the canonical fan-out path; this exists for
   *  REST-only flows that need belt-and-suspenders delivery. */
  notifyCallChanged(call: CallSession | undefined): void {
    if (!call) return;
    this.fanOutCallChange(call);
  }

  isUserConnected(userId: string): boolean {
    return (this.socketsByUser.get(normalizeUserIdForCompare(userId))?.size ?? 0) > 0;
  }

  // ---- Connection lifecycle ---------------------------------------------

  private onConnection(socket: WSLike, req: IncomingMessage): void {
    this.alive.add(socket);
    let authedUserId: string | null = this.authenticateSocketFromRequest(socket, req);

    socket.on("pong", () => this.alive.add(socket));

    socket.on("message", (raw) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        this.send(socket, "error", { code: "bad_json", message: "could not parse message" });
        return;
      }
      if (!msg || typeof msg.type !== "string") {
        this.send(socket, "error", { code: "bad_message", message: "missing type" });
        return;
      }

      if (authedUserId && msg.type === "auth") {
        // Already authenticated from the WebSocket upgrade header/query.
        // Keep accepting the legacy first-message auth packet as a harmless no-op.
        return;
      }

      // Pre-auth: only `auth` is acceptable.
      if (!authedUserId) {
        if (msg.type !== "auth") {
          this.send(socket, "error", { code: "not_authed", message: "send auth first" });
          return;
        }
        const id = parseAuthToken((msg.payload as AuthPayload | undefined)?.token);
        if (!id) {
          this.send(socket, "error", { code: "bad_token", message: "auth rejected" });
          socket.close(4401, "auth_failed");
          return;
        }
        authedUserId = this.authenticateSocket(socket, id);
        return;
      }

      this.handleAuthed(socket, authedUserId, msg);
    });

    socket.on("close", () => {
      if (authedUserId) {
        this.unindexSocket(authedUserId, socket);
        // If this was the user's last socket, broadcast offline presence.
        if (!this.socketsByUser.get(authedUserId)?.size) {
          this.broadcastPresence(authedUserId, false);
        }
      }
    });
  }

  private authenticateSocketFromRequest(socket: WSLike, req: IncomingMessage): string | null {
    const headerToken = bearerToken(req.headers.authorization);
    const queryToken = tokenFromRequestUrl(req.url);
    const id = parseAuthToken(headerToken) ?? parseAuthToken(queryToken);
    if (!id) return null;
    return this.authenticateSocket(socket, id);
  }

  private authenticateSocket(socket: WSLike, userId: string): string {
    this.userOfSocket.set(socket, userId);
    this.indexSocket(userId, socket);
    logger.info({
      userId,
      socketCount: this.socketsByUser.get(normalizeUserIdForCompare(userId))?.size ?? 0,
    }, "[calls:realtime] socket authenticated");
    this.broadcastPresence(userId, true);
    // Reply with current calls so the client can recover state after a
    // reconnect. Recent terminal calls are replayed as `call:ended` to clear
    // any local CallKit/LiveKit ghost if the realtime event was missed.
    for (const call of this.deps.registry.callsForUser(userId)) {
      if (call.status === "ended" || call.status === "missed" || call.status === "failed" || call.status === "declined") {
        logger.info({
          eventType: "call.ended",
          callId: call.callId,
          targetUserId: userId,
          endedByUserId: call.endedByUserId,
          operationId: lastOperationId(call),
          sessionVersion: call.version ?? 1,
          endedAt: call.endedAt ? new Date(call.endedAt).toISOString() : undefined,
          sourceFunction: "CallWebSocketServer.authenticateSocket",
          reason: "terminal_replay_on_reconnect",
        }, "[calls:realtime] call.ended replayed");
        this.send(socket, "call:ended", callEndedPayload(call));
      } else {
        this.send(socket, "call:state", { call });
      }
    }
    return userId;
  }

  private handleAuthed(socket: WSLike, userId: string, msg: ClientMessage): void {
    switch (msg.type) {
      case "call:invite": {
        const p = msg.payload as InvitePayload | undefined;
        if (!p?.calleeId) {
          this.send(socket, "error", { code: "bad_payload", message: "calleeId required" });
          return;
        }
        if (sameUserId(p.calleeId, userId)) {
          this.send(socket, "error", { code: "self_invite_forbidden", message: "cannot call yourself" });
          return;
        }
        const existingCall = this.findActiveCallBetween(userId, p.calleeId);
        if (existingCall) {
          this.send(socket, "call:state", { call: existingCall });
          return;
        }
        const call = this.deps.registry.createCall({
          callerId: userId,
          calleeId: p.calleeId,
          hasVideo: !!p.hasVideo,
          turnEnabled: true,
        });
        // Registry emits 'call:changed' which fans out to the callee. We
        // additionally echo back the created call so the caller's socket
        // sees the canonical id immediately.
        this.send(socket, "call:state", { call });
        // Fan-out a VoIP push if the host wired one in.
        this.deps.onCallInvited?.(userId, p.calleeId, call);
        return;
      }
      case "call:accept":
      case "call:decline":
      case "call:hangup": {
        const p = msg.payload as CallIdPayload | undefined;
        if (!p?.callId) {
          this.send(socket, "error", { code: "bad_payload", message: "callId required" });
          return;
        }
        this.applyLifecycleAction(socket, userId, msg.type, p.callId);
        return;
      }
      case "call:ice-ready": {
        // Informational only — useful telemetry hook. We acknowledge so
        // clients can measure RTT.
        const p = msg.payload as CallIdPayload | undefined;
        if (p?.callId) {
          const call = this.deps.registry.get(normalizeCallId(p.callId));
          if (call) this.send(socket, "call:state", { call });
        }
        return;
      }
      case "presence:update": {
        const p = msg.payload as PresenceUpdatePayload | undefined;
        if (typeof p?.online === "boolean") this.broadcastPresence(userId, p.online);
        return;
      }
      case "call:signal": {
        const p = msg.payload as CallSignalPayload | undefined;
        if (!p?.callId || !p.toUserId || !p.kind || !p.ciphertext) {
          this.send(socket, "error", { code: "bad_payload", message: "callId/toUserId/kind/ciphertext required" });
          return;
        }
        const normalizedCallId = normalizeCallId(p.callId);
        const call = this.deps.registry.get(normalizedCallId);
        if (!call) {
          this.send(socket, "error", { code: "not_found", message: "no such call" });
          return;
        }
        const isParticipant =
          sameUserId(call.callerId, userId) ||
          sameUserId(call.calleeId, userId) ||
          call.participants.some((participant) => sameUserId(participant, userId));
        if (!isParticipant) {
          this.send(socket, "error", { code: "not_participant", message: "not a call participant" });
          return;
        }
        // Only relay to the other party / participants of this call.
        const recipients = this.recipientsForCall(call);
        if (![...recipients].some((recipient) => sameUserId(recipient, p.toUserId))) {
          this.send(socket, "error", { code: "bad_recipient", message: "recipient not in call" });
          return;
        }
        // Relay without inspecting payload. Server never decrypts.
        this.sendToUser(p.toUserId, "call:signal", {
          signal: {
            callId: normalizedCallId,
            fromUserId: userId,
            kind: p.kind,
            ciphertext: p.ciphertext,
            senderEphemeralPub: p.senderEphemeralPub,
            senderIdentityPub: p.senderIdentityPub,
          },
        });
        return;
      }
      case "auth": {
        // Re-auth on the same socket is a no-op.
        return;
      }
      default: {
        this.send(socket, "error", { code: "unknown_event", message: msg.type });
      }
    }
  }

  private applyLifecycleAction(
    socket: WSLike,
    userId: string,
    type: "call:accept" | "call:decline" | "call:hangup",
    callId: string
  ): void {
    const normalizedCallId = normalizeCallId(callId);
    const call = this.deps.registry.get(normalizedCallId);
    if (!call) {
      this.send(socket, "error", { code: "not_found", message: "no such call" });
      return;
    }
    const isCallee = sameUserId(call.calleeId, userId);
    const isParticipant =
      isCallee ||
      sameUserId(call.callerId, userId) ||
      call.participants.some((participant) => sameUserId(participant, userId));

    if (type === "call:accept" || type === "call:decline") {
      if (!isCallee) {
        this.send(socket, "error", { code: "not_callee", message: "only callee may accept/decline" });
        return;
      }
      if (call.status !== "ringing") {
        this.send(socket, "error", { code: "wrong_state", message: `call is ${call.status}` });
        return;
      }
    }
    if (type === "call:hangup" && !isParticipant) {
      this.send(socket, "error", { code: "not_participant", message: "not a call participant" });
      return;
    }

    try {
      if (type === "call:accept") {
        this.deps.registry.updateStatus(normalizedCallId, "accepting", (c) => {
          if (!c.participants.some((participant) => sameUserId(participant, userId))) {
            c.participants.push(userId);
          }
          c.acceptedAt = c.acceptedAt ?? Date.now();
        });
      } else if (type === "call:decline") {
        this.deps.registry.updateStatus(normalizedCallId, "declined", (c) => {
          c.endedAt = c.endedAt ?? Date.now();
          c.endedByUserId = userId;
          c.endReason = "remoteDeclined";
        });
      } else {
        this.deps.registry.updateStatus(normalizedCallId, "ended", (c) => {
          c.endedAt = c.endedAt ?? Date.now();
          c.endedByUserId = userId;
          c.endReason = "explicitParticipantHangup";
          c.endOperationIds = [
            ...(c.endOperationIds ?? []),
            `${normalizedCallId}:${userId}:${Date.now()}`,
          ];
        });
      }
    } catch (err) {
      const code = err instanceof Error ? err.message : "internal_error";
      this.send(socket, "error", { code: "registry_error", message: code });
    }
  }

  // ---- Fan-out ----------------------------------------------------------

  private fanOutCallChange(call: CallSession): void {
    const fingerprint = this.fanoutFingerprint(call);
    if (this.lastFanoutFingerprintByCallId.get(call.callId) === fingerprint) {
      return;
    }
    this.lastFanoutFingerprintByCallId.set(call.callId, fingerprint);

    if (call.status === "ringing") {
      if (this.ringingFanoutCallIds.has(call.callId)) return;
      this.ringingFanoutCallIds.add(call.callId);
      this.logVideoTimeline("video.call.invite.received", call, call.calleeId, {
        callStatus: call.status,
        targetUserId: call.calleeId,
      });
      logger.info({
        eventType: "incoming_oneway_call",
        callSessionId: call.callId,
        actorRole: "oneway_user",
        targetUserId: call.calleeId,
        initiatorUserId: call.callerId,
        sourceFunction: "CallWebSocketServer.fanOutCallChange",
        reason: "callee_ring",
      }, "[calls] incoming call event sent");
      this.sendToUser(call.calleeId, "call:ringing", { call });
      this.sendToUser(call.callerId, "call:state", { call });
      for (const userId of call.participants) {
        if (userId !== call.calleeId && userId !== call.callerId) {
          this.sendToUser(userId, "call:state", { call });
        }
      }
      return;
    }

    this.ringingFanoutCallIds.delete(call.callId);
    const evt: ServerEvent = mapStatusToEvent(call.status);
    if (evt === "call:ended") {
      this.fanOutAuthoritativeCallEnded(call, "CallWebSocketServer.fanOutCallChange");
      return;
    }
    const recipients = this.recipientsForCall(call);
    for (const userId of recipients) {
      if (evt === "call:accepted") {
        this.logVideoTimeline(
          sameUserId(userId, call.callerId)
            ? "video.call.accepted.event.sent"
            : "video.call.connecting.event.sent",
          call,
          userId,
          { callStatus: call.status, targetUserId: userId }
        );
      }
      this.sendToUser(userId, evt, { call });
    }
  }

  private fanOutCallEnded(call: CallSession): void {
    this.ringingFanoutCallIds.delete(call.callId);
    this.lastFanoutFingerprintByCallId.delete(call.callId);
    // Some calls are evicted before any terminal status was broadcast (rare,
    // belt-and-suspenders). Send ended just in case.
    this.fanOutAuthoritativeCallEnded(call, "CallWebSocketServer.fanOutCallEnded");
  }

  private fanOutAuthoritativeCallEnded(call: CallSession, sourceFunction: string): void {
    const recipients = this.recipientsForCall(call);
    const payload = callEndedPayload(call);
    logger.info({
      marker: "CALL_ENDED_BROADCAST_STARTED",
      callId: call.callId,
      endedByUserId: call.endedByUserId,
      callerUserId: call.callerId,
      recipientUserId: call.calleeId,
      operationId: lastOperationId(call),
      version: call.version ?? 1,
      recipientCount: recipients.size,
      sourceFunction,
    }, "[calls:realtime] call.ended broadcast started");
    const callerSocketsReached = this.sendToUser(call.callerId, "call:ended", payload);
    logger.info({
      marker: "CALL_ENDED_SENT_TO_CALLER",
      callId: call.callId,
      endedByUserId: call.endedByUserId,
      callerUserId: call.callerId,
      recipientUserId: call.calleeId,
      operationId: lastOperationId(call),
      version: call.version ?? 1,
      socketsReached: callerSocketsReached,
      sourceFunction,
    }, "[calls:realtime] call.ended sent to caller");
    const recipientSocketsReached = this.sendToUser(call.calleeId, "call:ended", payload);
    logger.info({
      marker: "CALL_ENDED_SENT_TO_RECIPIENT",
      callId: call.callId,
      endedByUserId: call.endedByUserId,
      callerUserId: call.callerId,
      recipientUserId: call.calleeId,
      operationId: lastOperationId(call),
      version: call.version ?? 1,
      socketsReached: recipientSocketsReached,
      sourceFunction,
    }, "[calls:realtime] call.ended sent to recipient");
    for (const userId of recipients) {
      if (sameUserId(userId, call.callerId) || sameUserId(userId, call.calleeId)) continue;
      this.sendToUser(userId, "call:ended", payload);
    }
    logger.info({
      marker: "CALL_ENDED_BROADCAST_COMPLETED",
      callId: call.callId,
      endedByUserId: call.endedByUserId,
      callerUserId: call.callerId,
      recipientUserId: call.calleeId,
      operationId: lastOperationId(call),
      version: call.version ?? 1,
      callerSocketsReached,
      recipientSocketsReached,
      sourceFunction,
    }, "[calls:realtime] call.ended broadcast completed");
  }

  private recipientsForCall(call: CallSession): Set<string> {
    const out = new Set<string>();
    out.add(call.callerId);
    out.add(call.calleeId);
    for (const p of call.participants) out.add(p);
    return out;
  }

  private broadcastPresence(userId: string, online: boolean): void {
    // Presence broadcast scope is intentionally narrow: only to the
    // counterparty of any active call. Real apps would key this off the
    // friend graph; we don't have one yet.
    const calls = this.deps.registry.activeForUser(userId);
    const recipients = new Set<string>();
    for (const c of calls) {
      recipients.add(c.callerId);
      recipients.add(c.calleeId);
    }
    recipients.delete(userId);
    const evt: ServerEvent = online ? "presence:online" : "presence:offline";
    for (const r of recipients) this.sendToUser(r, evt, { userId });
  }

  private findActiveCallBetween(userA: string, userB: string): CallSession | undefined {
    return this.deps.registry.activeForUser(userA).find((call) =>
      (sameUserId(call.callerId, userA) && sameUserId(call.calleeId, userB)) ||
      (sameUserId(call.callerId, userB) && sameUserId(call.calleeId, userA))
    );
  }

  // ---- Socket bookkeeping ----------------------------------------------

  private indexSocket(userId: string, socket: WSLike): void {
    const key = normalizeUserIdForCompare(userId);
    let set = this.socketsByUser.get(key);
    if (!set) {
      set = new Set();
      this.socketsByUser.set(key, set);
    }
    set.add(socket);
  }

  private unindexSocket(userId: string, socket: WSLike): void {
    const key = normalizeUserIdForCompare(userId);
    const set = this.socketsByUser.get(key);
    if (!set) return;
    set.delete(socket);
    if (set.size === 0) this.socketsByUser.delete(key);
  }

  private sendToUser(userId: string, type: ServerEvent, payload: unknown): number {
    const key = normalizeUserIdForCompare(userId);
    const set = this.socketsByUser.get(key);
    if (!set) {
      const call = (payload as { call?: CallSession } | undefined)?.call;
      if (call?.hasVideo) {
        this.logVideoTimeline("video.call.event.no_socket", call, userId, {
          eventType: type,
          targetUserId: userId,
          callStatus: call.status,
        });
      }
      return 0;
    }
    let sent = 0;
    for (const s of set) {
      if (this.send(s, type, payload)) sent += 1;
    }
    return sent;
  }

  private send(socket: WSLike, type: ServerEvent, payload: unknown): boolean {
    if (socket.readyState !== WS_OPEN) return false;
    const msg: ServerMessage = { type, payload };
    try {
      socket.send(JSON.stringify(msg));
      return true;
    } catch (err) {
      logger.warn({ err }, "[ws] send failed");
      return false;
    }
  }

  private runHeartbeat(): void {
    if (!this.wss) return;
    for (const socket of this.wss.clients) {
      if (!this.alive.has(socket)) {
        socket.terminate();
        continue;
      }
      this.alive.delete(socket);
      try {
        socket.ping();
      } catch {
        socket.terminate();
      }
    }
  }

  private fanoutFingerprint(call: CallSession): string {
    return [
      call.callId,
      call.status,
      call.acceptedAt ?? "",
      call.endedAt ?? "",
      call.participants.join(","),
    ].join("|");
  }

  private logVideoTimeline(
    event: string,
    call: CallSession,
    currentUserId: string,
    extra: Record<string, unknown> = {}
  ): void {
    if (!call.hasVideo) return;
    logger.info({
      event,
      callId: call.callId,
      conversationId: call.calleeId,
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
}

function mapStatusToEvent(status: CallSession["status"]): ServerEvent {
  switch (status) {
    case "ringing":
      return "call:ringing";
    case "accepted":
      return "call:accepted";
    case "declined":
      return "call:declined";
    case "ended":
    case "missed":
    case "failed":
      return "call:ended";
    default:
      return "call:state";
  }
}

function normalizeCallId(callId: string): string {
  return callId.toLowerCase();
}

function lastOperationId(call: CallSession): string | undefined {
  const ids = call.endOperationIds;
  return ids && ids.length > 0 ? ids[ids.length - 1] : undefined;
}

function callEndedPayload(call: CallSession): {
  call: CallSession;
  event: {
    type: "call.ended";
    callId: string;
    endedByUserId?: string;
    operationId?: string;
    reason: string;
    status: "ended" | "missed" | "failed" | "declined";
    sessionVersion: number;
    endedAt?: string;
  };
} {
  return {
    call,
    event: {
      type: "call.ended",
      callId: call.callId,
      endedByUserId: call.endedByUserId,
      operationId: lastOperationId(call),
      reason: call.endReason ?? "hangup",
      status: call.status === "missed" || call.status === "failed" || call.status === "declined"
        ? call.status
        : "ended",
      sessionVersion: call.version ?? 1,
      endedAt: call.endedAt ? new Date(call.endedAt).toISOString() : undefined,
    },
  };
}
