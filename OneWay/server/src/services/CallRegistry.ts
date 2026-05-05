import { EventEmitter } from "events";
import { randomUUID } from "crypto";
import type { CallSession, CallStatus } from "../types/calls";
import { sanitizeRoomName } from "../types/calls";

/**
 * In-memory store of every active CallSession. Single source of truth for
 * REST + WebSocket layers — both read and mutate through here so observers
 * get consistent fan-out.
 *
 * The interface is deliberately Redis-shaped (everything async). Swap the
 * backing Map for ioredis when the cluster grows past one node — call sites
 * don't change.
 *
 * Two indexes are maintained:
 *   - calls       : callId           -> CallSession
 *   - byUser      : userId           -> Set<callId>
 * Both are kept in lock-step inside `setCall` / `removeCall`, so they can't
 * drift mid-flight.
 *
 * EventEmitter fires `'call:changed'` and `'call:removed'` so the WebSocket
 * server can fan-out without polling.
 */
/**
 * Common surface every registry implementation exposes. The in-memory
 * `CallRegistry` and the `RedisCallRegistry` both conform to this so the
 * routes / WebSocket server don't care which one is wired.
 */
export interface ICallRegistry {
  createCall(args: { callerId: string; calleeId: string; hasVideo: boolean; turnEnabled: boolean }): CallSession;
  get(callId: string): CallSession | undefined;
  findByRoom(roomName: string): CallSession | undefined;
  activeForUser(userId: string): CallSession[];
  updateStatus(callId: string, status: CallStatus, mutator?: (call: CallSession) => void): CallSession;
  addParticipant(callId: string, userId: string): CallSession;
  removeCall(callId: string): void;
  on(event: "call:changed", listener: (call: CallSession) => void): void;
  on(event: "call:removed", listener: (call: CallSession) => void): void;
}

export class CallRegistry extends EventEmitter implements ICallRegistry {
  private calls = new Map<string, CallSession>();
  private byUser = new Map<string, Set<string>>();
  private timers = new Map<string, NodeJS.Timeout>();

  /** Default ringing timeout. Calls still in `ringing` state past this become
   *  `missed` and are evicted. Tunable via env on the route layer. */
  static readonly RING_TIMEOUT_MS = 45_000;

  /** Create a fresh ringing call. Validates and sanitizes inputs. */
  createCall(args: {
    callerId: string;
    calleeId: string;
    hasVideo: boolean;
    turnEnabled: boolean;
  }): CallSession {
    const callId = randomUUID();
    // Room name combines both identities so even if the same caller-callee
    // pair places back-to-back calls, they each get a unique room.
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
    this.setCall(call);
    this.armRingTimeout(callId);
    return call;
  }

  get(callId: string): CallSession | undefined {
    return this.calls.get(callId);
  }

  /** Look up by LiveKit room name. Linear scan; fine at typical concurrency. */
  findByRoom(roomName: string): CallSession | undefined {
    for (const call of this.calls.values()) {
      if (call.roomName === roomName) return call;
    }
    return undefined;
  }

  /** Active = anything not in a terminal state (ended/missed/declined/failed). */
  activeForUser(userId: string): CallSession[] {
    const ids = this.byUser.get(userId);
    if (!ids) return [];
    const out: CallSession[] = [];
    for (const id of ids) {
      const call = this.calls.get(id);
      if (!call) continue;
      if (isTerminal(call.status)) continue;
      out.push(call);
    }
    return out;
  }

  /** Mutate a call. Returns the new value. Throws if it's already terminal. */
  updateStatus(callId: string, status: CallStatus, mutator?: (call: CallSession) => void): CallSession {
    const call = this.calls.get(callId);
    if (!call) throw new RegistryError("not_found", "call not found");
    if (isTerminal(call.status) && status !== call.status) {
      throw new RegistryError("already_terminal", `call already ${call.status}`);
    }
    call.status = status;
    if (status === "accepted" && call.acceptedAt === undefined) {
      call.acceptedAt = Date.now();
    }
    if (isTerminal(status) && call.endedAt === undefined) {
      call.endedAt = Date.now();
    }
    mutator?.(call);
    this.setCall(call);
    if (isTerminal(status)) {
      this.disarm(callId);
      this.emit("call:changed", call);
      // Keep the record around briefly so late REST polls can still see the
      // terminal state, then evict.
      setTimeout(() => this.removeCall(callId), 30_000).unref();
    } else {
      this.emit("call:changed", call);
    }
    return call;
  }

  addParticipant(callId: string, userId: string): CallSession {
    return this.updateStatus(callId, this.calls.get(callId)?.status ?? "ringing", (call) => {
      if (!call.participants.includes(userId)) {
        call.participants.push(userId);
      }
    });
  }

  /** Hard-remove a call regardless of state. Use sparingly — prefer
   *  `updateStatus(..., "ended")` so observers see the transition. */
  removeCall(callId: string): void {
    const call = this.calls.get(callId);
    if (!call) return;
    this.disarm(callId);
    this.calls.delete(callId);
    this.removeFromUserIndex(call.callerId, callId);
    this.removeFromUserIndex(call.calleeId, callId);
    for (const p of call.participants) this.removeFromUserIndex(p, callId);
    this.emit("call:removed", call);
  }

  // ---- Internals --------------------------------------------------------

  private setCall(call: CallSession): void {
    this.calls.set(call.callId, call);
    this.indexUser(call.callerId, call.callId);
    this.indexUser(call.calleeId, call.callId);
    for (const p of call.participants) this.indexUser(p, call.callId);
  }

  private indexUser(userId: string, callId: string): void {
    let set = this.byUser.get(userId);
    if (!set) {
      set = new Set();
      this.byUser.set(userId, set);
    }
    set.add(callId);
  }

  private removeFromUserIndex(userId: string, callId: string): void {
    const set = this.byUser.get(userId);
    if (!set) return;
    set.delete(callId);
    if (set.size === 0) this.byUser.delete(userId);
  }

  private armRingTimeout(callId: string): void {
    const timer = setTimeout(() => {
      const call = this.calls.get(callId);
      if (!call || call.status !== "ringing") return;
      try {
        this.updateStatus(callId, "missed");
      } catch {
        /* already terminal — ignore */
      }
    }, CallRegistry.RING_TIMEOUT_MS);
    timer.unref();
    this.timers.set(callId, timer);
  }

  private disarm(callId: string): void {
    const t = this.timers.get(callId);
    if (t) {
      clearTimeout(t);
      this.timers.delete(callId);
    }
  }
}

export class RegistryError extends Error {
  constructor(public readonly code: string, message: string) {
    super(message);
    this.name = "RegistryError";
  }
}

export function isTerminal(status: CallStatus): boolean {
  return status === "ended" || status === "declined" || status === "missed" || status === "failed";
}
