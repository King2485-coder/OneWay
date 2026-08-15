export interface ApnsTokenConfig {
  key: string;
  keyId: string;
  teamId: string;
}

/**
 * Resolves APNs token authentication without ever logging key material.
 * Railway should use APNS_KEY_P8_BASE64; APNS_KEY_PATH remains supported for
 * hosts that mount Apple's .p8 file directly.
 */
export function apnsTokenConfigFromEnv(
  env: NodeJS.ProcessEnv = process.env,
): ApnsTokenConfig | null {
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  if (!keyId || !teamId) return null;

  const encodedKey = env.APNS_KEY_P8_BASE64?.trim();
  if (encodedKey) {
    const key = Buffer.from(encodedKey, "base64").toString("utf8").trim();
    const beginMarker = ["-----BEGIN", "PRIVATE KEY-----"].join(" ");
    const endMarker = ["-----END", "PRIVATE KEY-----"].join(" ");
    if (!key.includes(beginMarker) || !key.includes(endMarker)) {
      return null;
    }
    return { key, keyId, teamId };
  }

  const keyPath = env.APNS_KEY_PATH?.trim();
  return keyPath ? { key: keyPath, keyId, teamId } : null;
}
