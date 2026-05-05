/**
 * Redis-backed `ICallRegistry`. Same surface as the in-memory `CallRegistry`
 * — `index.ts` picks one at boot based on `REDIS_URL`.
 *
 * Storage layout:
 *   call:<callId>          (string) JSON-serialized CallSession        TTL ≈ 24h
 *   user:<userId>:calls    (set)    callIds the user is involved in    TTL ≈ 24h
 *   room:<name>            (string) callId mapped to a room name        TTL ≈ 24h
 *   ringing:<callId>       (string) "1" while in ringing state          TTL ≈ 50s
 *
 * Cross-instance fan-out: every mutation publishes the new CallSession to
 * channel `oneway.call.changed` (or `removed`). Each instance subscribes
 * and re-emits as a local EventEmitter event, which the WebSocket server
 * already listens to. The publishing instance also fires the local event
 * directly so a single-instance deployment doesn't pay the round-trip.
 *
 * This implementation prefers correctness over throughput — every mutation
 * is one round-trip, and a write-then-publish race is possible. For MVP
 * traffic (< few hundred concurrent calls) it's fine. Future: pipeline
 * and use Lua for atomicity.
 */

import { EventEmitter } from "events";
import { randomUUID } from "crypto";
import type { ICallRegistry } from "./CallRegistry";
import { isTerminal } from "./CallRegistry";
import type { CallSession, CallStatus } from "../types/calls";
import { sanitizeRoomName } from "../types/calls";
import type { RedisClientLike } from "../lib/redis";
import { logger } from "../lib/logger";

const TTL_SECONDS = 60 * 60 * 24;
const RINGING_TTL_SECONDS = 50;
const CHANGED_CHANNEL = "oneway.call.changed";
const REMOVED_CHANNEL = "oneway.call.removed";

export class RedisCallRegistry extends EventEmitter implements ICallRegistry {
  static readonly RING_TIMEOUT_MS = 45_000;

  // Local cache of the most recent state — not authoritative, just a hot
  // path for `get()` and `findByRoom()`. Cleared on `removeCall`.
  private cache = new Map<string, CallSession>();
  private byRoomCache = new Map<string, string>();
  private ringTimers = new Map<string, NodeJS.Timeout>();

  constructor(
    private readonly client: RedisClientLike,
    private readonly subscriber: RedisClientLike
  ) {
    super();
    this.bootstrapSubscriber();
  }

  // ---- ICallRegistry ----------------------------------------------------

  createCall(args: { callerId: string; calleeId: string; hasVideo: boolean; turnEnabled: boolean }): CallSession {
    const callId = randomUUID();
    const roomName = sanitizeRoomName(`${args.callerId}-${args.calleeId}-${callId.slice(0, 8)}`);
    const now = Date.now();
    const call: CallSession = {
      callId,
      roomName,
      callerId: args.callerId,
      calleeId: args.calleeId,
      status: "ringing",
      hasVideo: args.hasVideo,
      createdAt: now,
      turnEnabled: args.turnEnabled,
      participants: [],
    };
    void this.persist(call, /*isNew*/ true);
    this.armRingTimeout(callId);
    return call;
  }

  get(callId: string): CallSession | undefined {
    // Local cache first; routes can `await` an explicit refresh if they
    // need strict consistency, but for typical access patterns the cache
    // suffices because pub/sub keeps it warm.
    return this.cache.get(callId);
  }

  findByRoom(roomName: string): CallSession | undefined {
    const id = this.byRoomCache.get(roomName);
    if (!id) return undefined;
    return this.cache.get(id);
  }

  activeForUser(userId: string): CallSession[] {
    const out: CallSession[] = [];
    for (const call of this.cache.values()) {
      if (isTerminal(call.status)) continue;
      if (call.callerId === userId || call.calleeId === userId || call.participants.includes(userId)) {
        out.push(call);
      }
    }
    return out;
  }

  updateStatus(callId: string, status: CallStatus, mutator?: (call: CallSession) => void): CallSession {
    const existing = this.cache.get(callId);
    if (!existing) throw new RegistryNotFound("not_found", "call not found");
    if (isTerminal(existing.status) && status !== existing.status) {
      throw new RegistryNotFound("already_terminal", `call already ${existing.status}`);
    }
    existing.status = status;
    if (status === "accepted" && existing.acceptedAt === undefined) existing.acceptedAt = Date.now();
    if (isTerminal(status) && existing.endedAt === undefined) existing.endedAt = Date.now();
    mutator?.(existing);
    void this.persist(existing, false);
    if (isTerminal(status)) {
      this.disarm(callId);
      // Evict shortly after termination so late polls still see it.
      setTimeout(() => void this.removeCall(callId), 30_000).unref();
    }
    return existing;
  }

  addParticipant(callId: string, userId: string): CallSession {
    const existing = this.cache.get(callId);
    if (!existing) throw new RegistryNotFound("not_found", "call not found");
    if (!existing.participants.includes(userId)) {
      existing.participants.push(userId);
      void this.persist(existing, false);
    }
    return existing;
  }

  removeCall(callId: string): void {
    void this.delete(callId);
  }

  // ---- Internals -------------------------------------------------------

  private async persist(call: CallSession, isNew: boolean): Promise<void> {
    const body = JSON.stringify(call);
    try {
      await this.client.set(`call:${call.callId}`, body, "EX", TTL_SECONDS);
      await this.client.sadd(`user:${call.callerId}:calls`, call.callId);
      await this.client.sadd(`user:${call.calleeId}:calls`, call.callId);
      for (const p of call.participants) {
        await this.client.sadd(`user:${p}:calls`, call.callId);
      }
      await this.client.expire(`user:${call.callerId}:calls`, TTL_SECONDS);
      await this.client.expire(`user:${call.calleeId}:calls`, TTL_SECONDS);
      await this.client.set(`room:${call.roomName}`, call.callId, "EX", TTL_SECONDS);
      if (isNew && call.status === "ringing") {
        await this.client.set(`ringing:${call.callId}`, "1", "EX", RINGING_TTL_SECONDS);
      }
      this.cache.set(call.callId, call);
      this.byRoomCache.set(call.roomName, call.callId);
      await this.client.publish(CHANGED_CHANNEL, body);
      this.emit("call:changed", call);
    } catch (err) {
      logger.error({ err }, "[redis-registry] persist failed");
      // Re-throw to keep route handlers honest.
      throw err;
    }
  }

  private async delete(callId: string): Promise<void> {
    const call = this.cache.get(callId);
    this.disarm(callId);
    if (!call) return;
    try {
      await this.client.del(`call:${callId}`);
      await this.client.srem(`user:${call.callerId}:calls`, callId);
      await this.client.srem(`user:${call.calleeId}:calls`, callId);
      await this.client.del(`room:${call.roomName}`, `ringing:${callId}`);
      this.cache.delete(callId);
      this.byRoomCache.delete(call.roomName);
      await this.client.publish(REMOVED_CHANNEL, JSON.stringify(call));
      this.emit("call:removed", call);
    } catch (err) {
      logger.error({ err }, "[redis-registry] delete failed");
    }
  }

  private armRingTimeout(callId: string): void {
    const timer = setTimeout(() => {
      const call = this.cache.get(callId);
      if (!call || call.status !== "ringing") return;
      try { this.updateStatus(callId, "missed"); }
      catch { /* terminal — ignore */ }
    }, RedisCallRegistry.RING_TIMEOUT_MS);
    timer.unref();
    this.ringTimers.set(callId, timer);
  }

  private disarm(callId: string): void {
    const t = this.ringTimers.get(callId);
    if (t) {
      clearTimeout(t);
      this.ringTimers.delete(callId);
    }
  }

  private bootstrapSubscriber(): void {
    void this.subscriber.subscribe(CHANGED_CHANNEL);
    void this.subscriber.subscribe(REMOVED_CHANNEL);
    this.subscriber.on("message", (channel, message) => {
      try {
        const call = JSON.parse(message) as CallSession;
        if (channel === CHANGED_CHANNEL) {
          this.cache.set(call.callId, call);
          this.byRoomCache.set(call.roomName, call.callId);
          this.emit("call:changed", call);
        } else if (channel === REMOVED_CHANNEL) {
          this.cache.delete(call.callId);
          this.byRoomCache.delete(call.roomName);
          this.emit("call:removed", call);
        }
      } catch (err) {
        logger.warn({ err }, "[redis-registry] bad pub/sub message");
      }
    });
  }
}

class RegistryNotFound extends Error {
  constructor(public readonly code: string, message: string) {
    super(message);
    this.name = "RegistryError";
  }
}
