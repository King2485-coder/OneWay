import { randomUUID } from "crypto";
import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import type {
  CallHistoryEntry,
  CallHistoryDirection,
  CallHistoryStatus,
} from "../types/history";
import type { CallSession } from "../types/calls";

/**
 * Prisma-backed call history. Two rows per terminated call (incoming for
 * the callee, outgoing for the caller) so each user's view is a simple
 * `WHERE userId = ?` lookup.
 */
export class CallHistoryService {
  /** Convert a terminated `CallSession` into history rows. */
  async recordFromSession(session: CallSession): Promise<CallHistoryEntry> {
    const status = mapStatus(session.status);
    const startedAt = new Date(session.createdAt);
    const endedAt = new Date(session.endedAt ?? Date.now());
    const acceptedAt = session.acceptedAt ? new Date(session.acceptedAt) : null;
    const durationSeconds = acceptedAt
      ? Math.max(0, Math.floor((endedAt.getTime() - acceptedAt.getTime()) / 1000))
      : 0;

    // Persist the underlying `Call` row first. If it already exists (e.g.
    // re-record on a registry replay), upsert.
    await prisma.call.upsert({
      where: { id: session.callId },
      create: {
        id: session.callId,
        callerId: session.callerId,
        calleeId: session.calleeId,
        status: session.status,
        roomName: session.roomName,
        hasVideo: session.hasVideo,
        createdAt: startedAt,
        acceptedAt,
        endedAt,
      },
      update: {
        status: session.status,
        acceptedAt,
        endedAt,
      },
    });

    const outgoing: CallHistoryEntry = {
      id: randomUUID(),
      callId: session.callId,
      callerId: session.callerId,
      calleeId: session.calleeId,
      direction: "outgoing",
      status,
      durationSeconds,
      startedAt: startedAt.getTime(),
      endedAt: endedAt.getTime(),
      hasVideo: session.hasVideo,
    };
    const incoming: CallHistoryEntry = {
      ...outgoing,
      id: randomUUID(),
      direction: "incoming",
    };

    // Two rows, one per user-facing direction. createMany is single-statement.
    await prisma.callHistoryEntry.createMany({
      data: [
        rowFromEntry(outgoing, session.callerId),
        rowFromEntry(incoming, session.calleeId),
      ],
    });
    logger.info({ callId: session.callId, status }, "[history] recorded");
    return outgoing;
  }

  async forUser(userId: string, options?: { limit?: number }): Promise<CallHistoryEntry[]> {
    const limit = options?.limit && options.limit > 0 ? Math.min(options.limit, 500) : 100;
    const rows = await prisma.callHistoryEntry.findMany({
      where: { userId },
      orderBy: { createdAt: "desc" },
      take: limit,
      include: { call: true },
    });
    return rows.map(rowToEntry);
  }

  async forCallId(callId: string, viewerId: string): Promise<CallHistoryEntry | undefined> {
    const row = await prisma.callHistoryEntry.findFirst({
      where: { callId, userId: viewerId },
      include: { call: true },
    });
    return row ? rowToEntry(row) : undefined;
  }

  async attachVoicemail(callId: string, voicemailId: string): Promise<void> {
    await prisma.callHistoryEntry.updateMany({
      where: { callId, direction: "incoming" },
      data: { voicemailId },
    });
  }
}

function mapStatus(callStatus: CallSession["status"]): CallHistoryStatus {
  switch (callStatus) {
    case "ended":    return "completed";
    case "missed":   return "missed";
    case "declined": return "declined";
    case "failed":   return "failed";
    default:         return "failed";
  }
}

interface PrismaCallHistoryRow {
  id: string;
  callId: string;
  userId: string;
  direction: string;
  status: string;
  durationSeconds: number;
  hasVideo: boolean;
  createdAt: Date;
  voicemailId: string | null;
  call: { callerId: string; calleeId: string; endedAt: Date | null; createdAt: Date } | null;
}

function rowFromEntry(entry: CallHistoryEntry, userId: string) {
  return {
    id: entry.id,
    callId: entry.callId,
    userId,
    direction: entry.direction,
    status: entry.status,
    durationSeconds: entry.durationSeconds,
    hasVideo: entry.hasVideo,
    createdAt: new Date(entry.startedAt),
    voicemailId: entry.voicemailId ?? null,
  };
}

function rowToEntry(row: PrismaCallHistoryRow): CallHistoryEntry {
  const startedAt = row.call?.createdAt.getTime() ?? row.createdAt.getTime();
  const endedAt = row.call?.endedAt?.getTime() ?? row.createdAt.getTime();
  return {
    id: row.id,
    callId: row.callId,
    callerId: row.call?.callerId ?? "",
    calleeId: row.call?.calleeId ?? "",
    direction: row.direction as CallHistoryDirection,
    status: row.status as CallHistoryStatus,
    durationSeconds: row.durationSeconds,
    startedAt,
    endedAt,
    hasVideo: row.hasVideo,
    voicemailId: row.voicemailId ?? undefined,
  };
}
