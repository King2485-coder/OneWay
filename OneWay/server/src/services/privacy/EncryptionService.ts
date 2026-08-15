import { createCipheriv, createDecipheriv, createHmac, randomBytes } from "node:crypto";
import { logger } from "../../lib/logger";

const ENVELOPE_VERSION = 1;
const ENCRYPTION_ALGORITHM = "aes-256-gcm";
const IV_LENGTH_BYTES = 12;
const TAG_LENGTH_BYTES = 16;
const MASTER_KEY_BYTES = 32;

export type EncryptionContext = string | Record<string, unknown>;

export type EncryptedEnvelope = {
  v: 1;
  alg: "aes-256-gcm";
  kid: string;
  iv: string;
  tag: string;
  ciphertext: string;
};

export type EncryptionStatus = {
  requested: boolean;
  enabled: boolean;
  currentKeyId: string;
  availableKeyCount: number;
  availableKeyIds: string[];
  missingCurrentKey: boolean;
  invalidKeyIds: string[];
  hashKeyConfigured: boolean;
  hashKeyRequired: boolean;
  legacyMasterKeyConfigured: boolean;
};

type Config = {
  requested: boolean;
  enabled: boolean;
  keys: Map<string, Buffer>;
  kid: string;
  hashKey: Buffer | null;
  hashKeyRequired: boolean;
  invalidKeyIds: string[];
  legacyMasterKeyConfigured: boolean;
  warnedMissingKey: boolean;
  warnedMissingHashKey: boolean;
};

let cachedConfig: Config | null = null;

export function validateFieldEncryptionConfig(): void {
  const config = loadConfig();

  if (!config.requested) {
    const message = "FIELD_ENCRYPTION_ENABLED=false; sensitive fields may remain plaintext until field encryption is enabled.";
    if (process.env.NODE_ENV === "production") logger.warn({}, `[privacy] ${message}`);
    return;
  }

  const errors: string[] = [];
  if (!config.enabled) {
    errors.push("FIELD_ENCRYPTION_ENABLED=true but the current FIELD_ENCRYPTION_KEY_ID is missing or invalid.");
  }
  if (config.hashKeyRequired && !config.hashKey) {
    errors.push("FIELD_HASH_KEY_BASE64 is required for encrypted lookup hashes but is missing or invalid.");
  }

  if (errors.length > 0) {
    const message = `${errors.join(" ")} Configure FIELD_ENCRYPTION_KEYS_JSON or FIELD_ENCRYPTION_MASTER_KEY_BASE64 with 32-byte base64 keys.`;
    if (process.env.NODE_ENV === "production") throw new Error(message);
    logger.warn({ currentKeyId: config.kid, invalidKeyCount: config.invalidKeyIds.length }, `[privacy] ${message}`);
    return;
  }

  logger.info({ currentKeyId: config.kid, availableKeyCount: config.keys.size, hashKeyConfigured: Boolean(config.hashKey) }, "[privacy] field-level encryption enabled");
}

export function getEncryptionStatus(): EncryptionStatus {
  const config = loadConfig();
  return {
    requested: config.requested,
    enabled: config.enabled,
    currentKeyId: config.kid,
    availableKeyCount: config.keys.size,
    availableKeyIds: Array.from(config.keys.keys()).sort(),
    missingCurrentKey: config.requested && !config.keys.has(config.kid),
    invalidKeyIds: [...config.invalidKeyIds].sort(),
    hashKeyConfigured: Boolean(config.hashKey),
    hashKeyRequired: config.hashKeyRequired,
    legacyMasterKeyConfigured: config.legacyMasterKeyConfigured,
  };
}

export function isFieldEncryptionEnabled(): boolean {
  return loadConfig().enabled;
}

export function encryptString(plaintext: string, context: EncryptionContext): string {
  return encryptStringWithKid(plaintext, context, loadConfig().kid);
}

export function decryptString(ciphertext: string, context: EncryptionContext): string {
  const envelope = parseEncryptedEnvelope(ciphertext);
  if (!envelope) throw new Error("invalid_encrypted_payload");
  return decryptEnvelope(envelope, context);
}

export function encryptJson(obj: unknown, context: EncryptionContext): string {
  return encryptString(JSON.stringify(obj ?? null), context);
}

export function decryptJson<T = unknown>(ciphertext: string, context: EncryptionContext): T {
  return JSON.parse(decryptString(ciphertext, context)) as T;
}

export function isEncryptedPayload(value: unknown): value is string {
  return typeof value === "string" && parseEncryptedEnvelope(value) !== null;
}

export function getEncryptedPayloadKid(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return parseEncryptedEnvelope(value)?.kid ?? null;
}

export function reencryptPayload(payload: string, targetKid: string, context: EncryptionContext): string {
  const plaintext = isEncryptedPayload(payload) ? decryptString(payload, context) : payload;
  return encryptStringWithKid(plaintext, context, targetKid);
}

export function encryptIfEnabled(value: string | null | undefined, context: EncryptionContext): string {
  const normalized = String(value ?? "");
  if (!normalized || isEncryptedPayload(normalized)) return normalized;

  const config = loadConfig();
  if (!config.enabled) {
    warnIfRequestedWithoutKey(config);
    return normalized;
  }
  return encryptString(normalized, context);
}

export function decryptIfEncrypted(value: string | null | undefined, context: EncryptionContext): string {
  const normalized = String(value ?? "");
  if (!isEncryptedPayload(normalized)) return normalized;
  return decryptString(normalized, context);
}

export function encryptJsonIfEnabled(value: unknown, context: EncryptionContext): string {
  const config = loadConfig();
  if (!config.enabled) {
    warnIfRequestedWithoutKey(config);
    return JSON.stringify(value ?? null);
  }
  return encryptJson(value, context);
}

export function decryptJsonIfEncrypted<T = unknown>(value: string | null | undefined, context: EncryptionContext): T | string | null {
  if (value == null) return null;
  if (!isEncryptedPayload(value)) return value;
  return decryptJson<T>(value, context);
}

export function hmacLookup(value: string, context: EncryptionContext): string {
  const config = loadConfig();
  if (!config.hashKey) throw new Error("field_hash_key_not_configured");
  const mac = createHmac("sha256", config.hashKey)
    .update(stableContext(context))
    .update("\0")
    .update(value)
    .digest("base64url");
  return `v1:${mac}`;
}

export function hmacLookupIfEnabled(value: string | null | undefined, context: EncryptionContext): string | null {
  const normalized = String(value ?? "");
  if (!normalized) return null;
  const config = loadConfig();
  if (!config.enabled) {
    warnIfRequestedWithoutKey(config);
    return null;
  }
  if (!config.hashKey) {
    warnIfMissingHashKey(config);
    return null;
  }
  return hmacLookup(normalized, context);
}

export const fieldEncryptionService = {
  encryptString,
  decryptString,
  encryptJson,
  decryptJson,
  isEncryptedPayload,
  getEncryptedPayloadKid,
  reencryptPayload,
  encryptIfEnabled,
  decryptIfEncrypted,
  encryptJsonIfEnabled,
  decryptJsonIfEncrypted,
  hmacLookup,
  hmacLookupIfEnabled,
  getEncryptionStatus,
  isFieldEncryptionEnabled,
  validateFieldEncryptionConfig,
};

function encryptStringWithKid(plaintext: string, context: EncryptionContext, kid: string): string {
  const config = loadConfig();
  const key = config.keys.get(kid);
  if (!config.requested || !key) throw new Error("field_encryption_key_unavailable");

  const iv = randomBytes(IV_LENGTH_BYTES);
  const cipher = createCipheriv(ENCRYPTION_ALGORITHM, key, iv, { authTagLength: TAG_LENGTH_BYTES });
  cipher.setAAD(contextAAD(context));
  const encrypted = Buffer.concat([cipher.update(String(plaintext), "utf8"), cipher.final()]);
  const envelope: EncryptedEnvelope = {
    v: ENVELOPE_VERSION,
    alg: ENCRYPTION_ALGORITHM,
    kid,
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    ciphertext: encrypted.toString("base64"),
  };
  return JSON.stringify(envelope);
}

function decryptEnvelope(envelope: EncryptedEnvelope, context: EncryptionContext): string {
  const config = loadConfig();
  const key = config.keys.get(envelope.kid);
  if (!key) throw new Error("field_encryption_key_unavailable");

  const decipher = createDecipheriv(ENCRYPTION_ALGORITHM, key, Buffer.from(envelope.iv, "base64"), { authTagLength: TAG_LENGTH_BYTES });
  decipher.setAAD(contextAAD(context));
  decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
  const decrypted = Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertext, "base64")),
    decipher.final(),
  ]);
  return decrypted.toString("utf8");
}

function loadConfig(): Config {
  if (cachedConfig) return cachedConfig;

  const requested = envFlag("FIELD_ENCRYPTION_ENABLED", false);
  const kid = process.env.FIELD_ENCRYPTION_KEY_ID?.trim() || "local-dev-v1";
  const loaded = loadEncryptionKeys(kid);
  const hashKey = loadHashKey();
  const hashKeyRequired = envFlag("FIELD_HASH_KEY_REQUIRED", requested);

  cachedConfig = {
    requested,
    enabled: requested && loaded.keys.has(kid),
    keys: loaded.keys,
    kid,
    hashKey,
    hashKeyRequired,
    invalidKeyIds: loaded.invalidKeyIds,
    legacyMasterKeyConfigured: loaded.legacyMasterKeyConfigured,
    warnedMissingKey: false,
    warnedMissingHashKey: false,
  };
  return cachedConfig;
}

function loadEncryptionKeys(currentKid: string): { keys: Map<string, Buffer>; invalidKeyIds: string[]; legacyMasterKeyConfigured: boolean } {
  const keys = new Map<string, Buffer>();
  const invalidKeyIds: string[] = [];
  const registryRaw = process.env.FIELD_ENCRYPTION_KEYS_JSON?.trim();

  if (registryRaw) {
    try {
      const parsed = JSON.parse(registryRaw) as Record<string, unknown>;
      for (const [kid, raw] of Object.entries(parsed)) {
        const cleanKid = kid.trim();
        if (!cleanKid || typeof raw !== "string") {
          invalidKeyIds.push(cleanKid || "<empty>");
          continue;
        }
        const key = decodeBase64Key(raw);
        if (key) keys.set(cleanKid, key);
        else invalidKeyIds.push(cleanKid);
      }
    } catch {
      invalidKeyIds.push("FIELD_ENCRYPTION_KEYS_JSON");
    }
  }

  const legacyRaw = process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64?.trim();
  const legacyKey = legacyRaw ? decodeBase64Key(legacyRaw) : null;
  if (legacyRaw && legacyKey && !keys.has(currentKid)) keys.set(currentKid, legacyKey);
  if (legacyRaw && !legacyKey) invalidKeyIds.push(currentKid);

  return { keys, invalidKeyIds, legacyMasterKeyConfigured: Boolean(legacyKey) };
}

function loadHashKey(): Buffer | null {
  const explicit = process.env.FIELD_HASH_KEY_BASE64?.trim();
  const explicitKey = explicit ? decodeBase64Key(explicit) : null;
  if (explicitKey) return explicitKey;

  // Non-production compatibility only. Production validation requires an explicit hash key when encryption is enabled.
  if (process.env.NODE_ENV !== "production") {
    return decodeBase64Key(process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64?.trim() || "")
      ?? loadEncryptionKeys(process.env.FIELD_ENCRYPTION_KEY_ID?.trim() || "local-dev-v1").keys.get(process.env.FIELD_ENCRYPTION_KEY_ID?.trim() || "local-dev-v1")
      ?? null;
  }
  return null;
}

function decodeBase64Key(raw: string): Buffer | null {
  if (!raw) return null;
  try {
    const key = Buffer.from(raw, "base64");
    return key.length === MASTER_KEY_BYTES ? key : null;
  } catch {
    return null;
  }
}

function warnIfRequestedWithoutKey(config: Config): void {
  if (!config.requested || config.enabled || config.warnedMissingKey) return;
  config.warnedMissingKey = true;
  logger.warn({ kid: config.kid }, "[privacy] field encryption requested but no valid current key is configured; leaving write plaintext in this non-production process");
}

function warnIfMissingHashKey(config: Config): void {
  if (config.warnedMissingHashKey) return;
  config.warnedMissingHashKey = true;
  logger.warn({ kid: config.kid }, "[privacy] field encryption is enabled but FIELD_HASH_KEY_BASE64 is missing; encrypted lookup hashes will not be created");
}

function parseEncryptedEnvelope(value: string): EncryptedEnvelope | null {
  try {
    const parsed = JSON.parse(value) as Partial<EncryptedEnvelope>;
    if (!parsed || typeof parsed !== "object") return null;
    if (parsed.v !== ENVELOPE_VERSION || parsed.alg !== ENCRYPTION_ALGORITHM) return null;
    if (typeof parsed.kid !== "string" || typeof parsed.iv !== "string" || typeof parsed.tag !== "string" || typeof parsed.ciphertext !== "string") return null;
    return parsed as EncryptedEnvelope;
  } catch {
    return null;
  }
}

function contextAAD(context: EncryptionContext): Buffer {
  return Buffer.from(stableContext(context), "utf8");
}

function stableContext(context: EncryptionContext): string {
  if (typeof context === "string") return context;
  return stableStringify(context);
}

function stableStringify(value: unknown): string {
  if (value == null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const objectValue = value as Record<string, unknown>;
  return `{${Object.keys(objectValue).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(objectValue[key])}`).join(",")}}`;
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}
