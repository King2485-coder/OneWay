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

type FriendEventType =
  | "chirp.request.received"
  | "chirp.request.accepted"
  | "chirp.request.denied"
  | "chirp.request.ignored"
  | "chirp.request.blocked"
  | "chirp.friend.removed"
  | "chirp.friend.online"
  | "chirp.friend.offline"
  | "friend.request.received"
  | "friend.request.accepted"
  | "friend.request.declined"
  | "friend.removed"
  | "friend.blocked";

const WS_OPEN = 1;

export class FriendRealtimeServer {
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
      logger.warn({}, "[friends:realtime] ws package unavailable; realtime disabled");
      return;
    }

    const path = this.deps.path ?? "/ws/friends";
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
    logger.info({ path }, "[friends:realtime] websocket ready");
  }

  isUserConnected(userId: string): boolean {
    return (this.socketsByUser.get(normalizeUserId(userId))?.size ?? 0) > 0;
  }

  sendToUser(userId: string, type: FriendEventType, payload: Record<string, unknown>): number {
    const normalizedUserId = normalizeUserId(userId);
    const sockets = this.socketsByUser.get(normalizedUserId);
    let delivered = 0;
    for (const socket of sockets ?? []) {
      if (this.send(socket, type, payload)) delivered += 1;
    }
    logger.info({
      socketEventName: type,
      targetSocketUser: normalizedUserId,
      deliveredSockets: delivered,
      friendshipId: typeof payload.friendshipId === "string" ? payload.friendshipId : undefined,
    }, "[friends:realtime] event dispatched");
    return delivered;
  }

  private onConnection(socket: WSLike, req: IncomingMessage): void {
    this.alive.add(socket);
    let authedUserId = this.authenticateSocketFromRequest(socket, req);
    socket.on("pong", () => this.alive.add(socket));

    socket.on("message", (raw) => {
      let message: { type?: string; payload?: Record<string, unknown> };
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
        this.send(socket, "friend.connected", {});
        return;
      }

      if (message.type === "auth") return;
      if (message.type === "ping") {
        this.send(socket, "pong", {});
        return;
      }
      this.send(socket, "error", { code: "unknown_event", message: message.type ?? "unknown" });
    });

    socket.on("close", () => this.removeSocket(socket));
  }

  private authenticateSocketFromRequest(socket: WSLike, req: IncomingMessage): string | null {
    const id = parseAuthToken(bearerToken(req.headers.authorization)) ?? parseAuthToken(tokenFromRequestUrl(req.url));
    if (!id) return null;
    const userId = this.authenticateSocket(socket, id);
    this.send(socket, "friend.connected", {});
    return userId;
  }

  private authenticateSocket(socket: WSLike, userIdValue: string): string {
    const userId = normalizeUserId(userIdValue);
    this.userOfSocket.set(socket, userId);
    if (!this.socketsByUser.has(userId)) {
      this.socketsByUser.set(userId, new Set());
    }
    this.socketsByUser.get(userId)!.add(socket);
    logger.info({
      receiverCurrentUserId: userId,
      socketCount: this.socketsByUser.get(userId)?.size ?? 0,
    }, "[friends:realtime] socket authenticated");
    return userId;
  }

  private removeSocket(socket: WSLike): void {
    const userId = this.userOfSocket.get(socket);
    if (!userId) return;
    const sockets = this.socketsByUser.get(userId);
    sockets?.delete(socket);
    if (sockets?.size === 0) this.socketsByUser.delete(userId);
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

  private send(socket: WSLike, type: string, payload: Record<string, unknown>): boolean {
    if (socket.readyState !== WS_OPEN) return false;
    socket.send(JSON.stringify({ type, payload }));
    return true;
  }

  private isPathMatch(url: string | undefined, path: string): boolean {
    return (url ?? "").split("?")[0] === path;
  }
}

function normalizeUserId(userId: string): string {
  return userId.toLowerCase();
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
