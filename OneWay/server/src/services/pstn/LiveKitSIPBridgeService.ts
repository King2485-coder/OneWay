import {
  ConnectTwilioCallRequest_TwilioCallDirection,
  ConnectorClient,
  ParticipantInfo_State,
  RoomServiceClient,
  SipClient,
  TrackSource,
  TrackType,
} from "livekit-server-sdk";
import { logger } from "../../lib/logger";
import type { LiveKitTokenService } from "../LiveKitTokenService";

type BridgeProvider = "stub" | "twilio" | "telnyx" | "sinch";

export type MediaBridgeStatus = "connecting" | "connected" | "failed" | "not_configured";

export interface StartLiveKitSIPBridgeInput {
  callSessionId: string;
  roomName: string;
  userId: string;
  toPhoneNumber: string;
  fromPhoneNumber?: string;
  provider: BridgeProvider;
}

export interface StartLiveKitSIPBridgeResult {
  roomName: string;
  liveKitUrl?: string;
  token?: string;
  sipParticipantId?: string;
  participantIdentity?: string;
  providerCallId?: string;
  mediaBridgeStatus: MediaBridgeStatus;
  message?: string;
}

export interface LiveKitSIPCreateDiagnostics {
  liveKitHostConfigured: boolean;
  liveKitUrlConfigured: boolean;
  tokenServiceConfigured: boolean;
  roomClientConfigured: boolean;
  sipClientConfigured: boolean;
  sipTrunkId?: string;
  roomName: string;
  participantIdentity: string;
  toPhoneNumberIsE164: boolean;
  hasFromPhoneNumber: boolean;
  provider: BridgeProvider;
  requestPayload: Record<string, unknown>;
}

export interface PrepareLiveKitPSTNRoomInput {
  callSessionId: string;
  roomName: string;
  userId: string;
}

export interface PrepareLiveKitPSTNRoomResult {
  roomName: string;
  liveKitUrl?: string;
  token?: string;
  mediaBridgeStatus: MediaBridgeStatus;
  message?: string;
}

export interface ConnectExistingTwilioLegInput {
  callSessionId: string;
  roomName: string;
  providerCallId?: string;
  toPhoneNumber: string;
  fromPhoneNumber?: string;
}

export interface ConnectExistingTwilioLegResult {
  roomName: string;
  connectUrl?: string;
  participantIdentity: string;
  mediaBridgeStatus: MediaBridgeStatus;
  message?: string;
}

export interface LiveKitSIPParticipantSnapshot {
  found: boolean;
  connected: boolean;
  roomName: string;
  participantIdentity: string;
  identity?: string;
  sid?: string;
  state?: number;
  stateName?: string;
  kind?: number;
  kindName?: string;
  trackCount: number;
  tracks: Array<{
    sid: string;
    name: string;
    type: number;
    typeName?: string;
    source: number;
    sourceName?: string;
    muted: boolean;
    mimeType: string;
  }>;
  metadata?: string;
  attributes?: Record<string, string>;
  isPublisher?: boolean;
  disconnectReason?: number;
  error?: string;
}

type RoomParticipantInfo = Awaited<ReturnType<RoomServiceClient["getParticipant"]>>;

const PARTICIPANT_KIND_NAMES: Record<number, string> = {
  0: "STANDARD",
  1: "INGRESS",
  2: "EGRESS",
  3: "SIP",
  4: "AGENT",
  7: "CONNECTOR",
  8: "BRIDGE",
};

function normalizeLiveKitHost(value: string | undefined): string {
  const raw = (value ?? "").trim();
  if (!raw) return "";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol === "wss:") parsed.protocol = "https:";
    if (parsed.protocol === "ws:") parsed.protocol = "http:";
    return parsed.origin;
  } catch {
    return "";
  }
}

function readLiveKitUrl(): string {
  return (process.env.LIVEKIT_URL ?? "").trim();
}

function readLiveKitHost(): string {
  return normalizeLiveKitHost(process.env.LIVEKIT_HOST) || normalizeLiveKitHost(readLiveKitUrl());
}

function resolveSipTrunkId(provider: BridgeProvider): string {
  const globalTrunk = (process.env.LIVEKIT_SIP_TRUNK_ID ?? "").trim();
  const twilioEnvTrunk = (process.env.TWILIO_SIP_TRUNK_SID ?? "").trim();
  const telnyxEnvTrunk = (process.env.TELNYX_SIP_TRUNK_ID ?? "").trim();

  // LiveKit SIP trunk IDs are `ST_...`.
  const normalizeLiveKitTrunkId = (value: string): string => (value.startsWith("ST_") ? value : "");

  switch (provider) {
    case "telnyx":
      return normalizeLiveKitTrunkId(telnyxEnvTrunk) || normalizeLiveKitTrunkId(globalTrunk);
    case "twilio":
      // TWILIO_SIP_TRUNK_SID is Twilio's TK_* SID and not valid for LiveKit SIP APIs.
      return normalizeLiveKitTrunkId(globalTrunk) || normalizeLiveKitTrunkId(twilioEnvTrunk);
    case "sinch":
      return normalizeLiveKitTrunkId(globalTrunk);
    case "stub":
    default:
      return "";
  }
}

function safeBridgeIdentifier(value: string): string {
  return value.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 48);
}

function isE164PhoneNumber(value: string): boolean {
  return /^\+[1-9]\d{6,14}$/.test(value);
}

function phoneHint(value: string): string {
  const digits = value.replace(/\D/g, "");
  return digits ? `...${digits.slice(-4)}` : "[invalid]";
}

function maybeString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function maybeStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const strings = value.filter((item): item is string => typeof item === "string");
  return strings.length > 0 ? strings : undefined;
}

function sanitizeSipTrunkInfo(trunk: unknown): Record<string, unknown> {
  const record = trunk && typeof trunk === "object" ? trunk as Record<string, unknown> : {};
  const authUsername = maybeString(record.authUsername);
  const authPassword = maybeString(record.authPassword);
  return {
    sipTrunkId: maybeString(record.sipTrunkId),
    name: maybeString(record.name),
    address: maybeString(record.address),
    numbers: maybeStringArray(record.numbers),
    transport: record.transport,
    destinationCountry: maybeString(record.destinationCountry),
    metadata: maybeString(record.metadata),
    hasAuthUsername: Boolean(authUsername),
    hasAuthPassword: Boolean(authPassword),
    authUsernameLength: authUsername?.length ?? 0,
    authPasswordLength: authPassword?.length ?? 0,
  };
}

function enumName(enumValue: Record<string, string | number>, value: number): string | undefined {
  const resolved = enumValue[value];
  return typeof resolved === "string" ? resolved : undefined;
}

export function liveKitSIPParticipantIdentity(callSessionId: string): string {
  return `pstn-${safeBridgeIdentifier(callSessionId)}`;
}

export class LiveKitSIPBridgeService {
  private readonly liveKitHost = readLiveKitHost();
  private readonly liveKitUrl = readLiveKitUrl();
  private readonly apiKey = (process.env.LIVEKIT_API_KEY ?? "").trim();
  private readonly apiSecret = (process.env.LIVEKIT_API_SECRET ?? "").trim();
  private readonly roomClient: RoomServiceClient | null;
  private readonly sipClient: SipClient | null;
  private readonly connectorClient: ConnectorClient | null;

  constructor(private readonly tokens: LiveKitTokenService) {
    if (!this.liveKitHost || !this.apiKey || !this.apiSecret) {
      this.roomClient = null;
      this.sipClient = null;
      this.connectorClient = null;
      return;
    }
    this.roomClient = new RoomServiceClient(this.liveKitHost, this.apiKey, this.apiSecret);
    this.sipClient = new SipClient(this.liveKitHost, this.apiKey, this.apiSecret);
    this.connectorClient = new ConnectorClient(this.liveKitHost, this.apiKey, this.apiSecret);
  }

  isConfigured(): boolean {
    return Boolean(
      this.tokens.isConfigured()
        && this.roomClient
        && this.sipClient
        && this.liveKitUrl
    );
  }

  async endCallRoom(roomName: string): Promise<void> {
    if (!this.roomClient || !roomName) return;
    try {
      await this.roomClient.deleteRoom(roomName);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!/not found|does not exist/i.test(message)) throw error;
    }
  }

  diagnosticsForCreate(input: StartLiveKitSIPBridgeInput): LiveKitSIPCreateDiagnostics {
    const participantIdentity = liveKitSIPParticipantIdentity(input.callSessionId);
    const sipTrunkId = resolveSipTrunkId(input.provider);
    return {
      liveKitHostConfigured: Boolean(this.liveKitHost),
      liveKitUrlConfigured: Boolean(this.liveKitUrl),
      tokenServiceConfigured: this.tokens.isConfigured(),
      roomClientConfigured: Boolean(this.roomClient),
      sipClientConfigured: Boolean(this.sipClient),
      sipTrunkId: sipTrunkId || undefined,
      roomName: input.roomName,
      participantIdentity,
      toPhoneNumberIsE164: isE164PhoneNumber(input.toPhoneNumber),
      hasFromPhoneNumber: Boolean(input.fromPhoneNumber),
      provider: input.provider,
      requestPayload: {
        sipTrunkId: sipTrunkId || "[missing]",
        toPhoneNumberHint: phoneHint(input.toPhoneNumber),
        toPhoneNumberIsE164: isE164PhoneNumber(input.toPhoneNumber),
        roomName: input.roomName,
        fromNumberHint: input.fromPhoneNumber ? phoneHint(input.fromPhoneNumber) : null,
        participantIdentity,
        participantName: "OneWay PSTN Bridge",
        displayName: "External Network",
        participantMetadataKeys: ["callSessionId", "provider", "externalPhoneNumber"],
        participantAttributeKeys: ["callSessionId", "networkType", "provider"],
        playDialtone: true,
        waitUntilAnswered: false,
      },
    };
  }

  async prepareCallerRoom(input: PrepareLiveKitPSTNRoomInput): Promise<PrepareLiveKitPSTNRoomResult> {
    if (!this.tokens.isConfigured()) {
      return {
        roomName: input.roomName,
        mediaBridgeStatus: "failed",
        message: "LiveKit token service is not configured.",
      };
    }

    const tokenIssue = await this.tokens.issue({
      roomName: input.roomName,
      identity: input.userId,
      metadata: JSON.stringify({
        userId: input.userId,
        roomName: input.roomName,
        networkType: "pstnBridge",
        callSessionId: input.callSessionId,
      }),
      ttlSeconds: 3600,
      canPublish: true,
    });

    if (this.roomClient) {
      await this.ensureRoom(input.roomName);
    }

    return {
      roomName: input.roomName,
      liveKitUrl: tokenIssue.url,
      token: tokenIssue.token,
      mediaBridgeStatus: "connecting",
    };
  }

  async connectExistingTwilioLeg(input: ConnectExistingTwilioLegInput): Promise<ConnectExistingTwilioLegResult> {
    const participantIdentity = liveKitSIPParticipantIdentity(input.callSessionId);

    if (!this.connectorClient || !this.roomClient) {
      return {
        roomName: input.roomName,
        participantIdentity,
        mediaBridgeStatus: "failed",
        message: "LiveKit Twilio connector is not configured.",
      };
    }

    await this.ensureRoom(input.roomName);

    try {
      logger.info({
        callSessionId: input.callSessionId.slice(0, 8),
        roomName: input.roomName.slice(0, 16),
        providerCallId: input.providerCallId?.slice(0, 12),
        participantIdentity,
        hasFromPhoneNumber: Boolean(input.fromPhoneNumber),
      }, "[pstn:livekit] connecting existing Twilio leg");

      const connector = await this.connectorClient.connectTwilioCall({
        twilioCallDirection: ConnectTwilioCallRequest_TwilioCallDirection.INBOUND,
        roomName: input.roomName,
        participantIdentity,
        participantName: "OneWay PSTN Bridge",
        participantMetadata: JSON.stringify({
          callSessionId: input.callSessionId,
          provider: "twilio",
          providerCallId: input.providerCallId,
          externalPhoneNumber: input.toPhoneNumber,
        }),
        participantAttributes: {
          callSessionId: input.callSessionId,
          networkType: "pstnBridge",
          provider: "twilio",
          providerCallId: input.providerCallId ?? "",
          role: "pstn_recipient",
        },
      });

      if (!connector.connectUrl) {
        return {
          roomName: input.roomName,
          participantIdentity,
          mediaBridgeStatus: "failed",
          message: "LiveKit Twilio connector returned no stream URL.",
        };
      }

      logger.info({
        callSessionId: input.callSessionId.slice(0, 8),
        roomName: input.roomName.slice(0, 16),
        providerCallId: input.providerCallId?.slice(0, 12),
        participantIdentity,
      }, "[pstn:livekit] existing Twilio leg connector created");

      return {
        roomName: input.roomName,
        connectUrl: connector.connectUrl,
        participantIdentity,
        mediaBridgeStatus: "connecting",
      };
    } catch (error) {
      logger.error({
        err: error,
        callSessionId: input.callSessionId.slice(0, 8),
        roomName: input.roomName.slice(0, 16),
        providerCallId: input.providerCallId?.slice(0, 12),
        participantIdentity,
        liveKitErrorName: error instanceof Error ? error.name : undefined,
        liveKitErrorMessage: error instanceof Error ? error.message : String(error),
      }, "[pstn:livekit] existing Twilio leg connector failed");

      return {
        roomName: input.roomName,
        participantIdentity,
        mediaBridgeStatus: "failed",
        message: error instanceof Error ? error.message : "Failed to connect existing Twilio leg.",
      };
    }
  }

  async setupBridge(input: StartLiveKitSIPBridgeInput): Promise<StartLiveKitSIPBridgeResult> {
    if (!this.isConfigured()) {
      return {
        roomName: input.roomName,
        mediaBridgeStatus: "failed",
        message: "LiveKit SIP bridge is not configured. Set LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, and LIVEKIT_SIP_TRUNK_ID.",
      };
    }

    const tokenIssue = await this.tokens.issue({
      roomName: input.roomName,
      identity: input.userId,
      metadata: JSON.stringify({
        userId: input.userId,
        roomName: input.roomName,
        networkType: "pstnBridge",
        callSessionId: input.callSessionId,
      }),
      ttlSeconds: 3600,
      canPublish: true,
    });

    await this.ensureRoom(input.roomName);

    if (input.provider === "stub") {
      return {
        roomName: input.roomName,
        liveKitUrl: tokenIssue.url,
        token: tokenIssue.token,
        mediaBridgeStatus: "not_configured",
        message: "OneWay Bridge test mode. Add provider credentials.",
      };
    }

    const sipTrunkId = resolveSipTrunkId(input.provider);
    const diagnostics = this.diagnosticsForCreate(input);
    if (!sipTrunkId) {
      return {
        roomName: input.roomName,
        liveKitUrl: tokenIssue.url,
        token: tokenIssue.token,
        mediaBridgeStatus: "failed",
        message: `Missing SIP trunk ID for provider ${input.provider}. Configure LIVEKIT_SIP_TRUNK_ID or provider-specific SIP trunk env.`,
      };
    }

    await this.logSipTrunkDiagnostics(sipTrunkId, input);

    try {
      const participantIdentity = liveKitSIPParticipantIdentity(input.callSessionId);
      logger.info({
        callSessionId: input.callSessionId.slice(0, 8),
        roomName: input.roomName.slice(0, 16),
        sipTrunkId,
        requestPayload: diagnostics.requestPayload,
        sipCallToE164: isE164PhoneNumber(input.toPhoneNumber),
        hasFromPhoneNumber: Boolean(input.fromPhoneNumber),
        provider: input.provider,
        playDialtone: true,
        waitUntilAnswered: false,
      }, "[pstn:livekit] creating SIP participant");
      const sipParticipant = await this.sipClient!.createSipParticipant(
        sipTrunkId,
        input.toPhoneNumber,
        input.roomName,
        {
          fromNumber: input.fromPhoneNumber,
          participantIdentity,
          participantName: "OneWay PSTN Bridge",
          displayName: "External Network",
          participantMetadata: JSON.stringify({
            callSessionId: input.callSessionId,
            provider: input.provider,
            externalPhoneNumber: input.toPhoneNumber,
          }),
          participantAttributes: {
            callSessionId: input.callSessionId,
            networkType: "pstnBridge",
            provider: input.provider,
          },
          playDialtone: true,
          waitUntilAnswered: false,
        },
      );

      logger.info({
        callSessionId: input.callSessionId.slice(0, 8),
        roomName: input.roomName.slice(0, 16),
        sipParticipantId: sipParticipant.participantId,
        sipCallId: sipParticipant.sipCallId,
        sipCallStatus: (sipParticipant as unknown as Record<string, unknown>).callStatus,
        sipTrunkId,
        playDialtone: true,
        provider: input.provider,
      }, "[pstn:livekit] SIP participant created");

      return {
        roomName: input.roomName,
        liveKitUrl: tokenIssue.url,
        token: tokenIssue.token,
        sipParticipantId: sipParticipant.participantId,
        participantIdentity,
        providerCallId: sipParticipant.sipCallId || sipParticipant.participantId,
        mediaBridgeStatus: "connecting",
      };
    } catch (error) {
      logger.error({
        err: error,
        callSessionId: input.callSessionId.slice(0, 8),
        roomName: input.roomName.slice(0, 16),
        provider: input.provider,
        diagnostics,
        liveKitErrorName: error instanceof Error ? error.name : undefined,
        liveKitErrorMessage: error instanceof Error ? error.message : String(error),
        liveKitErrorStack: error instanceof Error ? error.stack : undefined,
      }, "[pstn:livekit] SIP participant create failed");

      return {
        roomName: input.roomName,
        liveKitUrl: tokenIssue.url,
        token: tokenIssue.token,
        mediaBridgeStatus: "failed",
        message: error instanceof Error ? error.message : "Failed to create SIP participant.",
      };
    }
  }

  private async logSipTrunkDiagnostics(sipTrunkId: string, input: StartLiveKitSIPBridgeInput): Promise<void> {
    if (!this.sipClient) return;

    try {
      const [outboundMatches, inboundMatches] = await Promise.all([
        this.sipClient.listSipOutboundTrunk({ trunkIds: [sipTrunkId] }),
        this.sipClient.listSipInboundTrunk({ trunkIds: [sipTrunkId] }),
      ]);

      logger.info({
        callSessionId: input.callSessionId,
        provider: input.provider,
        sipTrunkId,
        outboundMatchCount: outboundMatches.length,
        inboundMatchCount: inboundMatches.length,
        outboundTrunks: outboundMatches.map(sanitizeSipTrunkInfo),
        inboundTrunks: inboundMatches.map(sanitizeSipTrunkInfo),
      }, "[pstn:livekit] SIP trunk diagnostics");

      if (outboundMatches.length === 0) {
        logger.warn({
          callSessionId: input.callSessionId,
          provider: input.provider,
          sipTrunkId,
          inboundMatchCount: inboundMatches.length,
        }, "[pstn:livekit] configured SIP trunk is not an outbound trunk");
      }
    } catch (error) {
      logger.warn({
        err: error,
        callSessionId: input.callSessionId,
        provider: input.provider,
        sipTrunkId,
      }, "[pstn:livekit] SIP trunk diagnostics failed");
    }
  }

  private async ensureRoom(roomName: string): Promise<void> {
    try {
      const rooms = await this.roomClient!.listRooms([roomName]);
      const exists = rooms.some((room) => room.name === roomName);
      if (exists) return;
      await this.roomClient!.createRoom({
        name: roomName,
        emptyTimeout: 300,
        departureTimeout: 60,
        maxParticipants: 8,
      });
      logger.info({ roomName }, "[pstn:livekit] room created");
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown";
      if (/already exists/i.test(message)) {
        return;
      }
      throw error;
    }
  }

  async participantSnapshot(roomName: string, participantIdentity: string): Promise<LiveKitSIPParticipantSnapshot> {
    if (!this.roomClient) {
      return {
        found: false,
        connected: false,
        roomName,
        participantIdentity,
        trackCount: 0,
        tracks: [],
        error: "livekit_room_client_not_configured",
      };
    }

    try {
      const participant = await this.roomClient.getParticipant(roomName, participantIdentity);
      return this.snapshotFromParticipant(roomName, participantIdentity, participant);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logger.debug({
        err: error,
        roomName,
        participantIdentity,
      }, "[pstn:livekit] SIP participant not connected yet");
      return {
        found: false,
        connected: false,
        roomName,
        participantIdentity,
        trackCount: 0,
        tracks: [],
        error: message,
      };
    }
  }

  async findSIPParticipantForTwilioLeg(input: {
    roomName: string;
    callSessionId: string;
    providerCallId?: string;
  }): Promise<LiveKitSIPParticipantSnapshot> {
    if (!this.roomClient) {
      return {
        found: false,
        connected: false,
        roomName: input.roomName,
        participantIdentity: liveKitSIPParticipantIdentity(input.callSessionId),
        trackCount: 0,
        tracks: [],
        error: "livekit_room_client_not_configured",
      };
    }

    try {
      const participants = await this.roomClient.listParticipants(input.roomName);
      const sipParticipants = participants.filter((participant) => this.isSIPParticipant(participant));
      const matchingParticipant = sipParticipants.find((participant) =>
        this.participantMatchesTwilioLeg(participant, input.callSessionId, input.providerCallId)
      ) ?? (sipParticipants.length === 1 ? sipParticipants[0] : undefined);

      if (!matchingParticipant) {
        return {
          found: false,
          connected: false,
          roomName: input.roomName,
          participantIdentity: liveKitSIPParticipantIdentity(input.callSessionId),
          trackCount: 0,
          tracks: [],
          error: sipParticipants.length > 1 ? "ambiguous_sip_participant" : "sip_participant_not_found",
        };
      }

      return this.snapshotFromParticipant(input.roomName, matchingParticipant.identity, matchingParticipant);
    } catch (error) {
      return {
        found: false,
        connected: false,
        roomName: input.roomName,
        participantIdentity: liveKitSIPParticipantIdentity(input.callSessionId),
        trackCount: 0,
        tracks: [],
        error: error instanceof Error ? error.message : "sip_participant_lookup_failed",
      };
    }
  }

  private snapshotFromParticipant(
    roomName: string,
    participantIdentity: string,
    participant: RoomParticipantInfo,
  ): LiveKitSIPParticipantSnapshot {
    const trackCount = participant.tracks.length;
    const connected = participant.identity === participantIdentity
      && (
        participant.state === ParticipantInfo_State.ACTIVE
        || trackCount > 0
      );

    return {
      found: true,
      connected,
      roomName,
      participantIdentity,
      identity: participant.identity,
      sid: participant.sid,
      state: participant.state,
      stateName: enumName(ParticipantInfo_State, participant.state),
      kind: participant.kind,
      kindName: PARTICIPANT_KIND_NAMES[participant.kind],
      trackCount,
      tracks: participant.tracks.map((track) => ({
        sid: track.sid,
        name: track.name,
        type: track.type,
        typeName: enumName(TrackType, track.type),
        source: track.source,
        sourceName: enumName(TrackSource, track.source),
        muted: track.muted,
        mimeType: track.mimeType,
      })),
      metadata: participant.metadata || undefined,
      attributes: participant.attributes,
      isPublisher: participant.isPublisher,
      disconnectReason: participant.disconnectReason,
    };
  }

  private isSIPParticipant(participant: RoomParticipantInfo): boolean {
    if (participant.kind === 3 || PARTICIPANT_KIND_NAMES[participant.kind] === "SIP") return true;
    const attributes = participant.attributes ?? {};
    return Object.keys(attributes).some((key) => key.startsWith("sip."));
  }

  private participantMatchesTwilioLeg(
    participant: RoomParticipantInfo,
    callSessionId: string,
    providerCallId: string | undefined,
  ): boolean {
    const attributes = participant.attributes ?? {};
    const metadata = participant.metadata ?? "";
    const callSessionCandidates = [
      attributes.callSessionId,
      attributes["oneway.callSessionId"],
      attributes["sip.h.X-OneWay-CallSessionId"],
      attributes["X-OneWay-CallSessionId"],
    ];
    if (callSessionCandidates.some((value) => value === callSessionId)) {
      return true;
    }

    if (!providerCallId) {
      return false;
    }

    const providerCandidates = [
      attributes["sip.twilio.callSid"],
      attributes["sip.h.X-OneWay-ProviderCallId"],
      attributes["X-OneWay-ProviderCallId"],
    ];
    return providerCandidates.some((value) => value === providerCallId)
      || metadata.includes(callSessionId)
      || metadata.includes(providerCallId);
  }

  async participantIsConnected(roomName: string, participantIdentity: string): Promise<boolean> {
    const snapshot = await this.participantSnapshot(roomName, participantIdentity);
    return snapshot.connected;
  }
}
