/**
 * Mints LiveKit access tokens server-side. We still require
 * livekit-server-sdk to be present because the rest of the calling stack uses
 * LiveKit server APIs, but room-join JWTs are signed manually so we can
 * backdate `nbf` a little and tolerate local/dev clock skew.
 *
 * Required env:
 *   LIVEKIT_URL          wss://your-livekit-host
 *   LIVEKIT_API_KEY
 *   LIVEKIT_API_SECRET
 *
 * The actual imports are wrapped in `require()` so missing-module errors at
 * boot are recoverable and clearly logged.
 */

import { logger } from "../lib/logger";
import { shortId } from "../lib/privacy/redaction";

interface AccessTokenLike {
  addGrant(grant: Record<string, unknown>): void;
  toJwt(): string | Promise<string>;
}

interface JwtModule {
  sign(
    payload: Record<string, unknown>,
    secret: string,
    options: { algorithm: "HS256"; noTimestamp?: boolean }
  ): string;
}

interface LiveKitSdk {
  AccessToken: new (
    apiKey: string,
    apiSecret: string,
    options: { identity: string; name?: string; ttl?: string | number; metadata?: string }
  ) => AccessTokenLike;
}

let sdkCache: LiveKitSdk | null | undefined;
let jwtCache: JwtModule | null | undefined;

function loadSdk(): LiveKitSdk | null {
  if (sdkCache !== undefined) return sdkCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const sdk = require("livekit-server-sdk") as LiveKitSdk;
    sdkCache = sdk;
    return sdk;
  } catch {
    sdkCache = null;
    if (process.env.NODE_ENV !== "test") {
      console.warn("[LiveKit] livekit-server-sdk not installed. LiveKit tokens cannot be issued.");
    }
    return null;
  }
}

function loadJwt(): JwtModule | null {
  if (jwtCache !== undefined) return jwtCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    jwtCache = require("jsonwebtoken") as JwtModule;
    return jwtCache;
  } catch {
    jwtCache = null;
    if (process.env.NODE_ENV !== "test") {
      console.warn("[LiveKit] jsonwebtoken not installed. LiveKit tokens cannot be issued.");
    }
    return null;
  }
}

export interface TokenIssueArgs {
  roomName: string;
  identity: string;
  displayName?: string;
  /** Seconds. Default 1 h — long enough for the longest plausible call. */
  ttlSeconds?: number;
  /** Subscribe-only viewers can be locked down with this. Default true. */
  canPublish?: boolean;
  metadata?: string;
}

export interface TokenIssueResult {
  url: string;
  liveKitUrl: string;
  token: string;
  roomName: string;
  participantIdentity: string;
}

export class LiveKitTokenService {
  constructor(
    private readonly url: string | undefined,
    private readonly apiKey: string | undefined,
    private readonly apiSecret: string | undefined
  ) {}

  static fromEnv(): LiveKitTokenService {
    return new LiveKitTokenService(
      process.env.LIVEKIT_URL,
      process.env.LIVEKIT_API_KEY,
      process.env.LIVEKIT_API_SECRET
    );
  }

  /** True when env is set AND the sdk is on disk. */
  isConfigured(): boolean {
    return !!(this.url && this.apiKey && this.apiSecret && loadSdk() && loadJwt());
  }

  async issue(args: TokenIssueArgs): Promise<TokenIssueResult> {
    const url = this.url ?? "";
    const jwt = loadJwt();
    const apiKey = this.apiKey;
    const apiSecret = this.apiSecret;
    if (!jwt || !url || !apiKey || !apiSecret) {
      throw new Error("LiveKit is not configured. Set LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.");
    }

    const ttlSeconds = clampTtl(args.ttlSeconds);
    const nowSeconds = Math.floor(Date.now() / 1000);
    const nbfSkewSeconds = clampClockSkew(Number(process.env.LIVEKIT_TOKEN_NBF_SKEW_SECONDS ?? 30));
    const payload: Record<string, unknown> = {
      iss: apiKey,
      sub: args.identity,
      exp: nowSeconds + ttlSeconds,
      nbf: Math.max(0, nowSeconds - nbfSkewSeconds),
      video: {
        room: args.roomName,
        roomJoin: true,
        canPublish: args.canPublish !== false,
        canSubscribe: true,
        canPublishData: true,
      },
    };
    if (args.metadata) {
      payload.metadata = args.metadata;
    }
    if (args.displayName) {
      payload.name = args.displayName;
    }

    const token = jwt.sign(payload, apiSecret, {
      algorithm: "HS256",
      noTimestamp: true,
    });

    if (process.env.NODE_ENV !== "production") {
      logger.info({
        url,
        roomName: shortId(args.roomName),
        identity: shortId(args.identity),
        ttlSeconds,
        nbfSkewSeconds,
        canPublish: args.canPublish !== false,
      }, "[LiveKit] issued token");
    }

    return { url, liveKitUrl: url, token, roomName: args.roomName, participantIdentity: args.identity };
  }
}

function clampTtl(value: number | undefined): number {
  if (!value || !Number.isFinite(value) || value <= 0) return 3600;
  return Math.min(value, 21600); // hard cap 6 h
}

function clampClockSkew(value: number | undefined): number {
  if (!value || !Number.isFinite(value) || value < 0) return 30;
  return Math.min(value, 300); // cap at 5 min so mistakes do not create too-wide windows
}

/*
 * Keep this reference shape close to LiveKit's SDK output:
 *
 * {
 *   iss: apiKey,
 *   sub: identity,
 *   exp,
 *   nbf,
 *   metadata,
 *   name,
 *   video: {
 *     room,
 *     roomJoin: true,
 *     canPublish,
 *     canSubscribe: true,
 *     canPublishData: true
 *   }
 * }
 */
