import type { Server as HTTPServer, IncomingMessage } from "http";
import { parseAuthToken } from "../middleware/auth";
import { logger } from "../lib/logger";

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
}

type WireMessage = {
  type: string;
  payload?: Record<string, unknown>;
};

export type DirectMessageRealtimePayload = {
  id: string;
  conversationId: string;
  senderId: string;
  body: string;
  attachment?: unknown;
  replyToMessageId?: string | null;
  editedAt?: string | null;
  external?: unknown;
  expirationMode?: string;
  expirationDurationSeconds?: number | null;
  readAt?: string | null;
  expiresAt?: string | null;
  deletedAt?: string | null;
  deletionReason?: string | null;
  tombstoneVersion?: number;
  attachmentExpirationState?: string;
  isTombstone?: boolean;
  createdAt: string;
  updatedAt: string;
};

const WS_OPEN = 1;

export class MessageRealtimeServer {
  private wss: WSServerLike | null = null;
  private userOfSocket = new WeakMap<WSLike, string>();
  private socketsByUser = new Map<string, Set<WSLike>>();
  private heartbeat: NodeJS.Timeout | null = null;
  private alive = new WeakSet<WSLike>();

  constructor(private readonly deps: { path?: string } = {}) {}

  start(httpServer: HTTPServer): void {
    let WSConstructor: { new (opts: { noServer?: boolean }): WSServerLike };
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const wsModule = require("ws");
      WSConstructor = (wsModule.WebSocketServer ?? wsModule.Server) as typeof WSConstructor;
    } catch {
      logger.warn({}, "[messages:realtime] ws package unavailable; realtime disabled");
      return;
    }

    const path = this.deps.path ?? "/ws/messages";
    this.wss = new WSConstructor({ noServer: true });
    httpServer.on("upgrade", (req, socket, head) => {
      if (!this.isPathMatch(req.url, path)) return;
      this.wss?.handleUpgrade(req, socket, head, (ws) => {
        this.wss?.emit("connection", ws, req);
      });
    });
    this.wss.on("connection", (socket, req) => this.onConnection(socket, req));
    this.heartbeat = setInterval(() => this.runHeartbeat(), 25_000);
    this.heartbeat.unref();
    logger.info({ path }, "[messages:realtime] websocket ready");
  }

  broadcastMessageCreated(participantUserIds: string[], message: DirectMessageRealtimePayload): void {
    this.broadcastMessageEvent("message.created", participantUserIds, message);
  }

  broadcastMessageUpdated(participantUserIds: string[], message: DirectMessageRealtimePayload): void {
    this.broadcastMessageEvent("message.updated", participantUserIds, message);
  }

  private broadcastMessageEvent(type: "message.created" | "message.updated", participantUserIds: string[], message: DirectMessageRealtimePayload): void {
    const startedAt = Date.now();
    const delivered = new Set<string>();
    for (const userIdValue of participantUserIds) {
      const userId = userIdValue.toLowerCase();
      const sockets = this.socketsByUser.get(userId);
      if (!sockets?.size) continue;
      for (const socket of sockets) {
        this.send(socket, type, { message });
        delivered.add(userId);
      }
    }
    logger.info({
      event: type,
      conversationId: message.conversationId,
      senderUserId: message.senderId,
      participantCount: participantUserIds.length,
      deliveredUsers: delivered.size,
      elapsedMs: Date.now() - startedAt,
    }, "[messages:realtime] dispatched");
  }

  private onConnection(socket: WSLike, req: IncomingMessage): void {
    this.alive.add(socket);
    let authedUserId = this.authenticateSocketFromRequest(socket, req);
    socket.on("pong", () => this.alive.add(socket));

    socket.on("message", (raw) => {
      let message: WireMessage;
      try {
        message = JSON.parse(raw.toString());
      } catch {
        this.send(socket, "error", { code: "bad_json", message: "could not parse message" });
        return;
      }

      if (!authedUserId) {
        if (message.type !== "auth") {
          this.send(socket, "error", { code: "not_authed", message: "send auth first" });
          return;
        }
        const token = typeof message.payload?.token === "string" ? message.payload.token : undefined;
        const userId = parseAuthToken(token);
        if (!userId) {
          this.send(socket, "error", { code: "bad_token", message: "auth rejected" });
          socket.close(4401, "auth_failed");
          return;
        }
        authedUserId = this.authenticateSocket(socket, userId);
        this.send(socket, "message.connected", {});
        return;
      }

      if (message.type === "auth") return;
      if (message.type === "ping") {
        this.send(socket, "pong", {});
        return;
      }
      this.send(socket, "error", { code: "unknown_event", message: message.type });
    });

    socket.on("close", () => this.removeSocket(socket));
  }

  private authenticateSocketFromRequest(socket: WSLike, req: IncomingMessage): string | null {
    const id = parseAuthToken(bearerToken(req.headers.authorization)) ?? parseAuthToken(tokenFromRequestUrl(req.url));
    if (!id) return null;
    const userId = this.authenticateSocket(socket, id);
    this.send(socket, "message.connected", {});
    return userId;
  }

  private authenticateSocket(socket: WSLike, userIdValue: string): string {
    const userId = userIdValue.toLowerCase();
    this.userOfSocket.set(socket, userId);
    if (!this.socketsByUser.has(userId)) {
      this.socketsByUser.set(userId, new Set());
    }
    this.socketsByUser.get(userId)!.add(socket);
    return userId;
  }

  private removeSocket(socket: WSLike): void {
    const userId = this.userOfSocket.get(socket);
    if (userId) {
      const sockets = this.socketsByUser.get(userId);
      sockets?.delete(socket);
      if (sockets?.size === 0) this.socketsByUser.delete(userId);
    }
  }

  private runHeartbeat(): void {
    for (const socket of this.wss?.clients ?? []) {
      if (!this.alive.has(socket)) {
        socket.terminate();
        this.removeSocket(socket);
        continue;
      }
      this.alive.delete(socket);
      try { socket.ping(); } catch { this.removeSocket(socket); }
    }
  }

  private send(socket: WSLike, type: string, payload: Record<string, unknown>): void {
    if (socket.readyState !== WS_OPEN) return;
    socket.send(JSON.stringify({ type, payload }));
  }

  private isPathMatch(url: string | undefined, path: string): boolean {
    return (url ?? "").split("?")[0] === path;
  }
}

function bearerToken(value: string | string[] | undefined): string | undefined {
  const raw = Array.isArray(value) ? value[0] : value;
  if (!raw) return undefined;
  return raw.startsWith("Bearer ") ? raw.slice("Bearer ".length).trim() : raw.trim();
}

function tokenFromRequestUrl(url: string | undefined): string | undefined {
  if (!url) return undefined;
  try {
    const parsed = new URL(url, "http://localhost");
    return parsed.searchParams.get("token") ?? undefined;
  } catch {
    return undefined;
  }
}
