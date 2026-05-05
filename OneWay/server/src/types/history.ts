/**
 * Call history + voicemail wire types. Same JSON shape goes out over the
 * REST API and into the on-disk store, so adding a field here ripples
 * through both — keep names stable.
 */

export type CallHistoryDirection = "incoming" | "outgoing";
export type CallHistoryStatus = "completed" | "missed" | "declined" | "failed";

export interface CallHistoryEntry {
  id: string;            // history-entry id, distinct from callId
  callId: string;
  callerId: string;
  calleeId: string;
  direction: CallHistoryDirection;
  status: CallHistoryStatus;
  durationSeconds: number;
  startedAt: number;     // unix ms
  endedAt: number;       // unix ms
  hasVideo: boolean;
  voicemailId?: string;  // present when caller left a voicemail after a miss
}

export interface VoicemailEntry {
  id: string;
  callId: string;
  callerId: string;
  calleeId: string;
  /** Server-relative URL the caller can hit to play back the audio. */
  audioUrl: string;
  durationSeconds: number;
  createdAt: number;
  listened: boolean;
  /** Internal — the on-disk path. NEVER serialize to clients. */
  storagePath: string;
  /** MIME type of the audio. m4a or aac in practice. */
  mimeType: string;
  /** Bytes — handy for client-side prefetch decisions. */
  bytes: number;
}

/** Public response shape for `/api/voicemail/:userId`. Strips storagePath. */
export type PublicVoicemail = Omit<VoicemailEntry, "storagePath">;

export function toPublicVoicemail(entry: VoicemailEntry): PublicVoicemail {
  // Destructuring drops `storagePath` so it never leaves the server.
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const { storagePath, ...rest } = entry;
  return rest;
}
