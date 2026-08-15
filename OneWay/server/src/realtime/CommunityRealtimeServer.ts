import type { Server as HTTPServer, IncomingMessage } from "http";
import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";
import { parseAuthToken } from "../middleware/auth";
import { logger } from "../lib/logger";
import { loadPublicIdentity } from "../services/identity";
import type { VoIPPushService } from "../services/VoIPPushService";

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

type CommunityWireMessage = {
  type: string;
  payload?: Record<string, unknown>;
};

export type CommunityMessageBroadcast = {
  id: string;
  clientMessageId?: string | null;
  communityId: string;
  senderId: string;
  senderHandle: string;
  senderDisplayName: string;
  body: string;
  status?: string | null;
  createdAt: Date | string;
};

export type CommunityBroadcast = {
  id: string;
  name: string;
  normalizedName?: string | null;
  description?: string | null;
  ownerId: string;
  creatorHandle?: string | null;
  visibility?: string | null;
  blockedUserIdsJson?: string | null;
  bannedUserIdsJson?: string | null;
  members?: Array<Record<string, unknown>>;
  createdAt: Date | string;
  updatedAt: Date | string;
  deletedAt?: Date | string | null;
};

export class CommunityRealtimeServer {
  private wss: WSServerLike | null = null;
  private userOfSocket = new WeakMap<WSLike, string>();
  private socketsByCommunity = new Map<string, Set<WSLike>>();
  private communitiesBySocket = new WeakMap<WSLike, Set<string>>();
  private discoverySockets = new Set<WSLike>();
  private heartbeat: NodeJS.Timeout | null = null;
  private alive = new WeakSet<WSLike>();

  constructor(
    private readonly deps: {
      prisma: PrismaClient;
      push?: VoIPPushService;
      path?: string;
    }
  ) {}

  start(httpServer: HTTPServer): void {
    let WSConstructor: { new (opts: { server?: HTTPServer; path?: string; noServer?: boolean }): WSServerLike };
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const wsModule = require("ws");
      WSConstructor = (wsModule.WebSocketServer ?? wsModule.Server) as typeof WSConstructor;
    } catch {
      logger.warn({}, "[communities:realtime] ws package unavailable; realtime disabled");
      return;
    }

    const path = this.deps.path ?? "/ws/communities";
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
    logger.info({ path: this.deps.path ?? "/ws/communities" }, "[communities:realtime] websocket ready");
  }

  async broadcastMessageCreated(message: CommunityMessageBroadcast): Promise<void> {
    const startedAt = Date.now();
    const communityId = message.communityId.toLowerCase();
    profile("server.broadcast.start", message.clientMessageId, communityId, startedAt, {
      messageId: message.id,
      senderUserId: message.senderId,
    });
    const sockets = this.socketsByCommunity.get(communityId);
    if (!sockets?.size) {
      profile("server.broadcast.noRoomSockets", message.clientMessageId, communityId, startedAt);
      logger.info({
        event: "community.message.created",
        communityId,
        senderUserId: message.senderId,
        recipientCount: 0,
        elapsedMs: Date.now() - startedAt,
      }, "[communities:realtime] dispatch skipped");
      return;
    }

    const memberRows = await this.deps.prisma.communityMember.findMany({
      where: { communityId },
      select: { userId: true },
    });
    profile("server.broadcast.membersLoaded", message.clientMessageId, communityId, startedAt, {
      memberCount: memberRows.length,
    });
    const memberIds = new Set(memberRows.map((row) => row.userId.toLowerCase()));
    const deliveredUserIds = new Set<string>();
    let recipientCount = 0;

    for (const socket of sockets) {
      const userId = this.userOfSocket.get(socket)?.toLowerCase();
      if (!userId || !memberIds.has(userId)) {
        this.unsubscribe(socket, communityId);
        continue;
      }
      this.send(socket, "community.message.created", { message: mapMessage(message) });
      deliveredUserIds.add(userId);
      recipientCount += 1;
    }
    profile("server.broadcast.roomSent", message.clientMessageId, communityId, startedAt, {
      recipientCount,
    });
    await this.pushOfflineMembers(message, memberRows.map((row) => row.userId), deliveredUserIds);
    profile("server.broadcast.complete", message.clientMessageId, communityId, startedAt, {
      recipientCount,
    });
    logger.info({
      event: "community.message.created",
      communityId,
      senderUserId: message.senderId,
      recipientCount,
      elapsedMs: Date.now() - startedAt,
    }, "[communities:realtime] dispatched");
  }

  broadcastCommunityCreated(community: CommunityBroadcast): void {
    this.broadcastDiscoveryEvent("community.created", community);
  }

  broadcastCommunityUpdated(community: CommunityBroadcast): void {
    this.broadcastDiscoveryEvent("community.updated", community);
    this.broadcastToCommunityMembers("community.updated", community.id, { community: mapCommunity(community) }).catch((error) => {
      logger.warn({ err: error, communityId: community.id }, "[communities:realtime] community update broadcast failed");
    });
  }

  broadcastCommunityDeleted(community: CommunityBroadcast): void {
    this.broadcastDiscoveryEvent("community.deleted", community);
    this.broadcastToCommunityMembers("community.deleted", community.id, { community: mapCommunity(community) }).catch((error) => {
      logger.warn({ err: error, communityId: community.id }, "[communities:realtime] community delete broadcast failed");
    });
  }

  async broadcastMemberJoined(community: CommunityBroadcast, senderUserId: string): Promise<void> {
    this.broadcastCommunityUpdated(community);
    await this.broadcastToCommunityMembers("community.member.joined", community.id, { community: mapCommunity(community) }, senderUserId);
  }

  private broadcastDiscoveryEvent(type: string, community: CommunityBroadcast): void {
    const startedAt = Date.now();
    if ((community.visibility ?? "public") !== "public" || community.deletedAt) return;

    let recipientCount = 0;
    for (const socket of this.discoverySockets) {
      if (!this.userOfSocket.get(socket)) {
        this.discoverySockets.delete(socket);
        continue;
      }
      this.send(socket, type, { community: mapCommunity(community) });
      recipientCount += 1;
    }
    logger.info({
      event: type,
      communityId: community.id,
      senderUserId: community.ownerId,
      recipientCount,
      elapsedMs: Date.now() - startedAt,
    }, "[communities:realtime] discovery dispatched");
  }

  private async broadcastToCommunityMembers(
    type: string,
    communityIdValue: string,
    payload: Record<string, unknown>,
    senderUserId?: string
  ): Promise<void> {
    const startedAt = Date.now();
    const communityId = communityIdValue.toLowerCase();
    const sockets = this.socketsByCommunity.get(communityId);
    if (!sockets?.size) return;

    const memberRows = await this.deps.prisma.communityMember.findMany({
      where: { communityId },
      select: { userId: true },
    });
    const memberIds = new Set(memberRows.map((row) => row.userId.toLowerCase()));
    let recipientCount = 0;
    for (const socket of sockets) {
      const userId = this.userOfSocket.get(socket)?.toLowerCase();
      if (!userId || !memberIds.has(userId)) {
        this.unsubscribe(socket, communityId);
        continue;
      }
      this.send(socket, type, payload);
      recipientCount += 1;
    }
    logger.info({
      event: type,
      communityId,
      senderUserId,
      recipientCount,
      elapsedMs: Date.now() - startedAt,
    }, "[communities:realtime] member dispatched");
  }

  private onConnection(socket: WSLike, req: IncomingMessage): void {
    this.alive.add(socket);
    let authedUserId = this.authenticateSocketFromRequest(socket, req);

    socket.on("pong", () => this.alive.add(socket));

    socket.on("message", async (raw) => {
      let message: CommunityWireMessage;
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
        return;
      }

      if (message.type === "auth") return;
      if (message.type === "community.subscribe" || message.type === "community.joinRoom") {
        await this.subscribe(socket, authedUserId, message.payload);
        return;
      }
      if (message.type === "community.discovery.subscribe") {
        this.discoverySockets.add(socket);
        this.send(socket, "community.discovery.subscribed", {});
        return;
      }
      if (message.type === "community.unsubscribe" || message.type === "community.leaveRoom") {
        const communityId = normalizeCommunityId(message.payload?.communityId);
        if (communityId) this.unsubscribe(socket, communityId);
        return;
      }
      if (message.type === "community.message.send") {
        await this.sendCommunityMessage(socket, authedUserId, message.payload);
        return;
      }
      if (message.type === "community.typing.started" || message.type === "community.typing.stopped") {
        await this.broadcastTyping(socket, authedUserId, message.type, message.payload);
        return;
      }
      if (message.type === "community.read") {
        await this.broadcastRead(socket, authedUserId, message.payload);
        return;
      }

      this.send(socket, "error", { code: "unknown_event", message: message.type });
    });

    socket.on("close", () => this.removeSocket(socket));
  }

  private authenticateSocketFromRequest(socket: WSLike, req: IncomingMessage): string | null {
    const id = parseAuthToken(bearerToken(req.headers.authorization)) ?? parseAuthToken(tokenFromRequestUrl(req.url));
    if (!id) return null;
    return this.authenticateSocket(socket, id);
  }

  private authenticateSocket(socket: WSLike, userId: string): string {
    this.userOfSocket.set(socket, userId);
    return userId;
  }

  private async subscribe(socket: WSLike, userId: string, payload: Record<string, unknown> | undefined): Promise<void> {
    const communityId = normalizeCommunityId(payload?.communityId);
    if (!communityId) {
      this.send(socket, "error", { code: "bad_payload", message: "communityId required" });
      return;
    }

    const member = await this.deps.prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
      select: { id: true },
    });
    if (!member) {
      this.send(socket, "error", { code: "community_membership_required", message: "Join this community to receive messages." });
      return;
    }

    if (!this.socketsByCommunity.has(communityId)) {
      this.socketsByCommunity.set(communityId, new Set());
    }
    this.socketsByCommunity.get(communityId)!.add(socket);

    const subscriptions = this.communitiesBySocket.get(socket) ?? new Set<string>();
    subscriptions.add(communityId);
    this.communitiesBySocket.set(socket, subscriptions);
    this.send(socket, "community.subscribed", { communityId });
    await this.broadcastToCommunityMembers("community.user.online", communityId, { communityId, userId }, userId);
  }

  private async sendCommunityMessage(
    socket: WSLike,
    userId: string,
    payload: Record<string, unknown> | undefined
  ): Promise<void> {
    const startedAt = Date.now();
    const communityId = normalizeCommunityId(payload?.communityId);
    const clientMessageId = normalizeClientMessageId(payload?.clientMessageId);
    const body = typeof payload?.body === "string" ? payload.body.trim() : "";
    profile("server.socket.messageReceived", clientMessageId, communityId, startedAt, { senderUserId: userId });
    if (!communityId || !clientMessageId || !body) {
      this.send(socket, "error", {
        code: "invalid_message",
        message: "communityId, clientMessageId, and body are required",
        communityId: communityId ?? "",
        clientMessageId: clientMessageId ?? "",
      });
      return;
    }
    if (body.length > 4_000) {
      this.send(socket, "error", {
        code: "message_too_long",
        message: "Message is too long.",
        communityId,
        clientMessageId,
      });
      return;
    }

    const member = await this.deps.prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
      select: { id: true },
    });
    profile("server.membership.checked", clientMessageId, communityId, startedAt, { ok: Boolean(member) });
    if (!member) {
      this.send(socket, "error", {
        code: "community_membership_required",
        message: "Join this community to send messages.",
        communityId,
        clientMessageId,
      });
      return;
    }

    const identity = await loadPublicIdentity(userId);
    profile("server.identity.loaded", clientMessageId, communityId, startedAt);
    const communityMessageDelegate = this.deps.prisma.communityMessage as any;
    const existing = await communityMessageDelegate.findFirst({
      where: { communityId, senderId: userId, clientMessageId },
    });
    profile("server.db.duplicateLookup.done", clientMessageId, communityId, startedAt, { duplicate: Boolean(existing) });
    const message = existing ?? await communityMessageDelegate.create({
      data: {
        id: randomUUID(),
        clientMessageId,
        communityId,
        senderId: userId,
        senderHandle: identity.onewayId,
        senderDisplayName: identity.displayName || identity.onewayId,
        body,
        status: "sent",
      },
    });
    profile("server.db.messageWrite.done", clientMessageId, communityId, startedAt, {
      messageId: message.id,
      duplicate: Boolean(existing),
    });
    await this.deps.prisma.community.update({
      where: { id: communityId },
      data: { updatedAt: new Date() },
    });
    profile("server.db.communityUpdated.done", clientMessageId, communityId, startedAt);

    await this.broadcastMessageCreated(message);
    profile("server.socket.send.complete", clientMessageId, communityId, startedAt, {
      messageId: message.id,
    });
    logger.info({
      event: "community.message.send",
      communityId,
      senderUserId: userId,
      clientMessageId,
      elapsedMs: Date.now() - startedAt,
    }, "[communities:realtime] socket send committed");
  }

  private async pushOfflineMembers(
    message: CommunityMessageBroadcast,
    memberIds: string[],
    deliveredUserIds: Set<string>
  ): Promise<void> {
    if (!this.deps.push) return;
    const startedAt = Date.now();
    const community = await this.deps.prisma.community.findUnique({
      where: { id: message.communityId.toLowerCase() },
      select: { name: true },
    });
    const recipients = memberIds
      .filter((userId) => userId.toLowerCase() !== message.senderId.toLowerCase())
      .filter((userId) => !deliveredUserIds.has(userId.toLowerCase()));

    await Promise.all(recipients.map((userId) => this.deps.push!.sendCommunityMessage({
      userId,
      communityId: message.communityId,
      communityName: community?.name ?? "OneWay Community",
      messageId: message.id,
      senderHandle: message.senderHandle,
      senderDisplayName: message.senderDisplayName,
      body: message.body,
    })));
    profile("server.pushFallback.queued", message.clientMessageId, message.communityId, startedAt, {
      recipientCount: recipients.length,
    });
  }

  private async broadcastTyping(
    socket: WSLike,
    userId: string,
    type: string,
    payload: Record<string, unknown> | undefined
  ): Promise<void> {
    const communityId = normalizeCommunityId(payload?.communityId);
    if (!communityId) {
      this.send(socket, "error", { code: "bad_payload", message: "communityId required" });
      return;
    }
    const member = await this.deps.prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
      select: { handle: true, displayName: true },
    });
    if (!member) return;
    await this.broadcastToCommunityMembers(type, communityId, {
      communityId,
      userId,
      handle: member.handle,
      displayName: member.displayName,
    }, userId);
  }

  private unsubscribe(socket: WSLike, communityId: string): void {
    const userId = this.userOfSocket.get(socket);
    this.socketsByCommunity.get(communityId)?.delete(socket);
    if (!this.socketsByCommunity.get(communityId)?.size) {
      this.socketsByCommunity.delete(communityId);
    }
    this.communitiesBySocket.get(socket)?.delete(communityId);
    if (userId) {
      this.broadcastToCommunityMembers("community.user.offline", communityId, { communityId, userId }, userId).catch((error) => {
        logger.warn({ err: error, communityId }, "[communities:realtime] offline broadcast failed");
      });
    }
  }

  private async broadcastRead(
    socket: WSLike,
    userId: string,
    payload: Record<string, unknown> | undefined
  ): Promise<void> {
    const communityId = normalizeCommunityId(payload?.communityId);
    const messageId = normalizeClientMessageId(payload?.messageId);
    if (!communityId || !messageId) {
      this.send(socket, "error", { code: "bad_payload", message: "communityId and messageId required" });
      return;
    }
    const member = await this.deps.prisma.communityMember.findUnique({
      where: { communityId_userId: { communityId, userId } },
      select: { id: true },
    });
    if (!member) return;
    await this.broadcastToCommunityMembers("community.message.read", communityId, {
      communityId,
      messageId,
      userId,
    }, userId);
  }

  private removeSocket(socket: WSLike): void {
    for (const communityId of this.communitiesBySocket.get(socket) ?? []) {
      this.unsubscribe(socket, communityId);
    }
    this.discoverySockets.delete(socket);
  }

  private send(socket: WSLike, type: string, payload: Record<string, unknown>): void {
    if (socket.readyState !== WS_OPEN) return;
    socket.send(JSON.stringify({ type, payload }));
  }

  private runHeartbeat(): void {
    for (const socket of this.wss?.clients ?? []) {
      if (!this.alive.has(socket)) {
        socket.terminate();
        continue;
      }
      this.alive.delete(socket);
      socket.ping();
    }
  }

  private isPathMatch(url: string | undefined, expectedPath: string): boolean {
    try {
      return new URL(url ?? "", "http://oneway.local").pathname === expectedPath;
    } catch {
      return false;
    }
  }
}

function normalizeCommunityId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(normalized)
    ? normalized
    : null;
}

function normalizeClientMessageId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(normalized)
    ? normalized
    : null;
}

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

function mapMessage(message: CommunityMessageBroadcast) {
  return {
    id: message.id,
    clientMessageId: message.clientMessageId ?? null,
    communityId: message.communityId,
    senderId: message.senderId,
    senderHandle: message.senderHandle,
    senderDisplayName: message.senderDisplayName,
    body: message.body,
    status: message.status ?? "sent",
    createdAt: typeof message.createdAt === "string" ? message.createdAt : message.createdAt.toISOString(),
  };
}

function mapCommunity(community: CommunityBroadcast) {
  const members = Array.isArray(community.members) ? community.members.map(mapMember) : [];
  return {
    id: community.id,
    name: community.name,
    normalizedName: community.normalizedName || normalizeName(community.name),
    description: community.description ?? "",
    creatorUserId: community.ownerId,
    creatorHandle: community.creatorHandle ?? "@oneway",
    visibility: community.visibility ?? "public",
    blockedUserIds: parseJsonArray(community.blockedUserIdsJson),
    bannedUserIds: parseJsonArray(community.bannedUserIdsJson),
    memberCount: members.length,
    members,
    createdAt: toISOString(community.createdAt),
    updatedAt: toISOString(community.updatedAt),
    deletedAt: community.deletedAt ? toISOString(community.deletedAt) : null,
  };
}

function mapMember(member: Record<string, unknown>) {
  return {
    id: stringValue(member.id),
    userId: stringValue(member.userId),
    displayName: stringValue(member.displayName) || "OneWay User",
    handle: stringValue(member.handle) || "@oneway",
    role: stringValue(member.role) || "member",
    createdAt: toISOString(member.createdAt as Date | string | null | undefined),
  };
}

function normalizeName(value: string): string {
  return value.trim().toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

function parseJsonArray(value: string | null | undefined): string[] {
  try {
    const parsed = JSON.parse(value ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((item) => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function toISOString(value: Date | string | null | undefined): string {
  if (!value) return new Date().toISOString();
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function profile(
  stage: string,
  clientMessageId: string | null | undefined,
  communityId: string | null | undefined,
  startedAt: number,
  metadata: Record<string, unknown> = {}
): void {
  const elapsedMs = Date.now() - startedAt;
  logger.info({
    marker: "COMMUNITY_PROFILE",
    stage,
    clientMessageId: clientMessageId ?? null,
    communityId: communityId ?? null,
    tsMs: Date.now(),
    elapsedMs,
    ...metadata,
  }, "[communities:profile]");
  console.log([
    "COMMUNITY_PROFILE",
    `stage=${stage}`,
    `clientMessageId=${clientMessageId ?? "nil"}`,
    `communityId=${communityId ?? "nil"}`,
    `tsMs=${Date.now()}`,
    `elapsedMs=${elapsedMs}`,
    ...Object.entries(metadata).map(([key, value]) => `${key}=${String(value)}`),
  ].join(" "));
}
