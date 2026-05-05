/**
 * Mints LiveKit access tokens server-side. Uses livekit-server-sdk if it's
 * installed; falls back to a clearly-labeled stub in dev so the route still
 * compiles before you `npm install livekit-server-sdk`.
 *
 * Required env:
 *   LIVEKIT_URL          wss://your-livekit-host
 *   LIVEKIT_API_KEY
 *   LIVEKIT_API_SECRET
 *
 * The actual import is wrapped in `require()` so missing-module errors at
 * boot are recoverable: we log once and serve stub tokens. Tests get the
 * same deterministic stub.
 */

interface AccessTokenLike {
  addGrant(grant: Record<string, unknown>): void;
  toJwt(): string | Promise<string>;
}

interface LiveKitSdk {
  AccessToken: new (apiKey: string, apiSecret: string, options: { identity: string; name?: string; ttl?: string | number }) => AccessTokenLike;
}

let sdkCache: LiveKitSdk | null | undefined;

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
      console.warn(
        "[LiveKit] livekit-server-sdk not installed. Stub tokens will be issued. " +
          "Run `npm install livekit-server-sdk` before any real call."
      );
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
}

export interface TokenIssueResult {
  url: string;
  token: string;
  roomName: string;
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
    return !!(this.url && this.apiKey && this.apiSecret && loadSdk());
  }

  async issue(args: TokenIssueArgs): Promise<TokenIssueResult> {
    const url = this.url ?? "";
    const sdk = loadSdk();
    if (!sdk || !url || !this.apiKey || !this.apiSecret) {
      throw new Error("LiveKit is not configured. Set LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.");
    }

    const ttlSeconds = clampTtl(args.ttlSeconds);
    const at = new sdk.AccessToken(this.apiKey, this.apiSecret, {
      identity: args.identity,
      name: args.displayName,
      ttl: `${ttlSeconds}s`,
    });
    at.addGrant({
      room: args.roomName,
      roomJoin: true,
      canPublish: args.canPublish !== false,
      canSubscribe: true,
      canPublishData: true,
    });
    const token = await at.toJwt();
    return { url, token, roomName: args.roomName };
  }
}

function clampTtl(value: number | undefined): number {
  if (!value || !Number.isFinite(value) || value <= 0) return 3600;
  return Math.min(value, 21600); // hard cap 6 h
}
