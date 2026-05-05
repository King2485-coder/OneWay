/**
 * Shared types for the OneWay calling system.
 *
 * Touched by REST routes, the WebSocket server, the in-memory CallRegistry,
 * and (through JSON-on-the-wire) the iOS NetworkCallSignalingClient. Keep
 * field names exactly in sync with the Swift `CallEnvelope` decoder.
 */

export type CallStatus =
  | "idle"
  | "ringing"
  | "accepted"
  | "declined"
  | "ended"
  | "missed"
  | "failed";

export interface CallSession {
  callId: string;          // UUID
  roomName: string;        // sanitized; lives in LiveKit
  callerId: string;
  calleeId: string;
  status: CallStatus;
  hasVideo: boolean;
  createdAt: number;       // unix ms
  acceptedAt?: number;     // unix ms
  endedAt?: number;        // unix ms
  liveKitRoom?: string;    // identical to roomName once joined; kept distinct
                           // so we can change room-naming policy later without
                           // breaking the on-the-wire shape.
  turnEnabled: boolean;    // hint to client; doesn't gate behavior
  participants: string[];  // userIds currently joined or invited
}

/** Server -> client event names. Exhaustive — clients may switch on this. */
export type ServerEvent =
  | "call:ringing"
  | "call:accepted"
  | "call:declined"
  | "call:ended"
  | "call:state"
  | "call:signal"
  | "presence:online"
  | "presence:offline"
  | "error";

/** Client -> server event names. */
export type ClientEvent =
  | "auth"
  | "call:invite"
  | "call:accept"
  | "call:decline"
  | "call:hangup"
  | "call:signal"
  | "call:ice-ready"
  | "presence:update";

export interface ServerMessage<TPayload = unknown> {
  type: ServerEvent;
  payload: TPayload;
}

export interface ClientMessage<TPayload = unknown> {
  type: ClientEvent;
  payload: TPayload;
}

// ---- Specific payload shapes -----------------------------------------------

export interface AuthPayload {
  /** Same shape the REST middleware accepts: "Bearer dev:<userId>" works in dev. */
  token: string;
}

export interface InvitePayload {
  callId: string;
  calleeId: string;
  hasVideo: boolean;
}

export interface CallIdPayload {
  callId: string;
}

export interface PresenceUpdatePayload {
  online: boolean;
}

export type CallSignalKind = "offer" | "answer" | "ice";

/**
 * Encrypted signalling payload. `ciphertext` must be base64 of an
 * AES-GCM combined sealed box. The server never decrypts; it only relays.
 */
export interface CallSignalPayload {
  callId: string;
  toUserId: string;
  fromUserId?: string;
  kind: CallSignalKind;
  ciphertext: string;
  senderEphemeralPub?: string;
  senderIdentityPub?: string;
}

export interface RingingPayload {
  call: CallSession;
}

export interface CallStatePayload {
  call: CallSession;
}

export interface ErrorPayload {
  code: string;
  message: string;
}

/** Shape returned by every REST endpoint that touches a call. */
export interface CallEnvelope {
  call: CallSession;
}

// ---- Helpers ---------------------------------------------------------------

/** LiveKit room names must be ASCII, ≤ 64 chars, no whitespace. */
export function sanitizeRoomName(input: string): string {
  const cleaned = input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_\-:.]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 64);
  return cleaned.length > 0 ? cleaned : `call-${Date.now()}`;
}

/** True if the user is the caller, callee, or a joined participant. */
export function isParticipant(call: CallSession, userId: string): boolean {
  return (
    call.callerId === userId ||
    call.calleeId === userId ||
    call.participants.includes(userId)
  );
}
