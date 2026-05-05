import { randomUUID } from "crypto";
import type { Readable } from "stream";
import { prisma } from "../lib/db";
import type { ObjectStorage } from "../lib/storage/ObjectStorage";
import { logger } from "../lib/logger";
import type { VoicemailEntry, PublicVoicemail } from "../types/history";

/**
 * Voicemail metadata in Postgres (Prisma); audio in `ObjectStorage`
 * (S3, R2, or local disk). The route layer used to write directly to disk
 * — that path is gone. Reads now mint short-lived signed URLs and the
 * client fetches them directly from object storage when possible.
 */
export interface IngestArgs {
  callId: string;
  callerId: string;
  calleeId: string;
  durationSeconds: number;
  mimeType: string;
  source: { kind: "buffer"; data: Buffer } | { kind: "stream"; data: Readable };
}

export class VoicemailService {
  constructor(private readonly storage: ObjectStorage) {}

  async ingest(args: IngestArgs): Promise<VoicemailEntry> {
    const id = randomUUID();
    const ext = mimeToExt(args.mimeType);
    const key = `voicemail/${args.calleeId}/${id}.${ext}`;

    const body: Buffer | Readable =
      args.source.kind === "buffer" ? args.source.data : args.source.data;
    const { bytes } = await this.storage.put(key, body, args.mimeType);

    const row = await prisma.voicemail.create({
      data: {
        id,
        callId: args.callId,
        callerId: args.callerId,
        calleeId: args.calleeId,
        storageKey: key,
        durationSeconds: Math.max(0, Math.floor(args.durationSeconds)),
        mimeType: args.mimeType,
        bytes,
      },
    });
    logger.info({ voicemailId: id, callId: args.callId }, "[voicemail] ingested");
    return rowToEntry(row);
  }

  async get(id: string): Promise<VoicemailEntry | undefined> {
    const row = await prisma.voicemail.findUnique({ where: { id } });
    return row ? rowToEntry(row) : undefined;
  }

  async forCallee(userId: string, options?: { limit?: number }): Promise<VoicemailEntry[]> {
    const limit = options?.limit && options.limit > 0 ? Math.min(options.limit, 500) : 200;
    const rows = await prisma.voicemail.findMany({
      where: { calleeId: userId },
      orderBy: { createdAt: "desc" },
      take: limit,
    });
    return rows.map(rowToEntry);
  }

  async markListened(id: string): Promise<VoicemailEntry | undefined> {
    try {
      const row = await prisma.voicemail.update({
        where: { id },
        data: { listened: true },
      });
      return rowToEntry(row);
    } catch {
      return undefined;
    }
  }

  /** Mint a download URL the client can fetch directly. */
  async signedUrl(id: string, expiresSeconds = 600): Promise<string | null> {
    const entry = await this.get(id);
    if (!entry) return null;
    return this.storage.presignedDownloadUrl(entry.storagePath, expiresSeconds);
  }

  /** Fall-through reader for local storage: streams the audio file back
   *  through the API. */
  async stream(id: string): Promise<{ stream: Readable; entry: VoicemailEntry } | null> {
    const entry = await this.get(id);
    if (!entry) return null;
    const r = await this.storage.read(entry.storagePath);
    if (!r) return null;
    return { stream: r.stream, entry };
  }

  /** Convert internal row to a public-safe shape (drops storageKey). */
  toPublic(entry: VoicemailEntry): PublicVoicemail {
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { storagePath, ...rest } = entry;
    return rest;
  }
}

interface VoicemailRow {
  id: string;
  callId: string;
  callerId: string;
  calleeId: string;
  storageKey: string;
  durationSeconds: number;
  mimeType: string;
  bytes: number;
  listened: boolean;
  createdAt: Date;
}

function rowToEntry(row: VoicemailRow): VoicemailEntry {
  return {
    id: row.id,
    callId: row.callId,
    callerId: row.callerId,
    calleeId: row.calleeId,
    audioUrl: `/api/voicemail/audio/${row.id}`,
    durationSeconds: row.durationSeconds,
    createdAt: row.createdAt.getTime(),
    listened: row.listened,
    storagePath: row.storageKey,
    mimeType: row.mimeType,
    bytes: row.bytes,
  };
}

function mimeToExt(mime: string): string {
  switch (mime) {
    case "audio/m4a":
    case "audio/x-m4a":
      return "m4a";
    case "audio/aac":
      return "aac";
    case "audio/mpeg":
      return "mp3";
    case "audio/wav":
    case "audio/x-wav":
      return "wav";
    default:
      return "bin";
  }
}
