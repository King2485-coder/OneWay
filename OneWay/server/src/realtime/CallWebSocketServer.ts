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
  clients: Set<WSLike>;
  close(): void;
}
const WS_OPEN = 1;

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

  constructor(private readonly deps: CallWebSocketServerDeps) {}

  start(httpServer: HTTPServer): void {
    // `ws` historically exported the server class as `Server`. Newer
    // versions also expose `WebSocketServer`. Support both shapes.
    let WSConstructor: { new (opts: { server: HTTPServer; path?: string }): WSServerLike };
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

    this.wss = new WSConstructor({ server: httpServer, path: this.deps.path ?? "/ws/calls" });
    this.wss.on("connection", (socket, req) => this.onConnection(socket, req));

    this.deps.registry.on("call:changed", (call: CallSession) => this.fanOutCallChange(call));
    this.deps.registry.on("call:removed", (call: CallSession) => this.fanOutCallEnded(call));

    this.heartbeat = setInterval(() => this.runHeartbeat(), 25_000);
    this.heartbeat.unref();
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

  // ---- Connection lifecycle ---------------------------------------------

  private onConnection(socket: WSLike, _req: IncomingMessage): void {
    this.alive.add(socket);
    let authedUserId: string | null = null;

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
        authedUserId = id;
        this.userOfSocket.set(socket, id);
        this.indexSocket(id, socket);
        this.broadcastPresence(id, true);
        // Reply with current active calls so the client can recover state
        // after a reconnect.
        for (const call of this.deps.registry.activeForUser(id)) {
          this.send(socket, "call:state", { call });
        }
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

  private handleAuthed(socket: WSLike, userId: string, msg: ClientMessage): void {
    switch (msg.type) {
      case "call:invite": {
        const p = msg.payload as InvitePayload | undefined;
        if (!p?.calleeId) {
          this.send(socket, "error", { code: "bad_payload", message: "calleeId required" });
          return;
        }
        if (p.calleeId === userId) {
          this.send(socket, "error", { code: "self_invite_forbidden", message: "cannot call yourself" });
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
          const call = this.deps.registry.get(p.callId);
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
        const call = this.deps.registry.get(p.callId);
        if (!call) {
          this.send(socket, "error", { code: "not_found", message: "no such call" });
          return;
        }
        const isParticipant = call.callerId === userId || call.calleeId === userId || call.participants.includes(userId);
        if (!isParticipant) {
          this.send(socket, "error", { code: "not_participant", message: "not a call participant" });
          return;
        }
        // Only relay to the other party / participants of this call.
        const recipients = this.recipientsForCall(call);
        if (!recipients.has(p.toUserId)) {
          this.send(socket, "error", { code: "bad_recipient", message: "recipient not in call" });
          return;
        }
        // Relay without inspecting payload. Server never decrypts.
        this.sendToUser(p.toUserId, "call:signal", {
          signal: {
            callId: p.callId,
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
    const call = this.deps.registry.get(callId);
    if (!call) {
      this.send(socket, "error", { code: "not_found", message: "no such call" });
      return;
    }
    const isCallee = call.calleeId === userId;
    const isParticipant = isCallee || call.callerId === userId || call.participants.includes(userId);

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
        this.deps.registry.updateStatus(callId, "accepted", (c) => {
          if (!c.participants.includes(userId)) c.participants.push(userId);
        });
      } else if (type === "call:decline") {
        this.deps.registry.updateStatus(callId, "declined");
      } else {
        this.deps.registry.updateStatus(callId, "ended");
      }
    } catch (err) {
      const code = err instanceof Error ? err.message : "internal_error";
      this.send(socket, "error", { code: "registry_error", message: code });
    }
  }

  // ---- Fan-out ----------------------------------------------------------

  private fanOutCallChange(call: CallSession): void {
    const evt: ServerEvent = mapStatusToEvent(call.status);
    const recipients = this.recipientsForCall(call);
    for (const userId of recipients) {
      this.sendToUser(userId, evt, { call });
    }
  }

  private fanOutCallEnded(call: CallSession): void {
    // Some calls are evicted before any terminal status was broadcast (rare,
    // belt-and-suspenders). Send ended just in case.
    const recipients = this.recipientsForCall(call);
    for (const userId of recipients) {
      this.sendToUser(userId, "call:ended", { call });
    }
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

  // ---- Socket bookkeeping ----------------------------------------------

  private indexSocket(userId: string, socket: WSLike): void {
    let set = this.socketsByUser.get(userId);
    if (!set) {
      set = new Set();
      this.socketsByUser.set(userId, set);
    }
    set.add(socket);
  }

  private unindexSocket(userId: string, socket: WSLike): void {
    const set = this.socketsByUser.get(userId);
    if (!set) return;
    set.delete(socket);
    if (set.size === 0) this.socketsByUser.delete(userId);
  }

  private sendToUser(userId: string, type: ServerEvent, payload: unknown): void {
    const set = this.socketsByUser.get(userId);
    if (!set) return;
    for (const s of set) this.send(s, type, payload);
  }

  private send(socket: WSLike, type: ServerEvent, payload: unknown): void {
    if (socket.readyState !== WS_OPEN) return;
    const msg: ServerMessage = { type, payload };
    try {
      socket.send(JSON.stringify(msg));
    } catch (err) {
      console.error("[ws] send failed", err);
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
