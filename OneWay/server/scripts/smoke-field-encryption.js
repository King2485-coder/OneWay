#!/usr/bin/env node
const crypto = require("node:crypto");

const v1Key = crypto.randomBytes(32).toString("base64");
const v2Key = crypto.randomBytes(32).toString("base64");
const hashKey = crypto.randomBytes(32).toString("base64");

process.env.FIELD_ENCRYPTION_ENABLED = "true";
process.env.FIELD_ENCRYPTION_KEYS_JSON = JSON.stringify({
  "smoke-v1": v1Key,
  "smoke-v2": v2Key,
});
process.env.FIELD_ENCRYPTION_KEY_ID = "smoke-v2";
process.env.FIELD_HASH_KEY_BASE64 = hashKey;
process.env.FIELD_HASH_KEY_REQUIRED = "true";

const encryption = require("../dist/services/privacy/EncryptionService");

const context = "smoke:storefront:buyerEmail";
const plaintext = "buyer@example.com";

const status = encryption.getEncryptionStatus();
if (!status.enabled || status.currentKeyId !== "smoke-v2" || status.availableKeyCount !== 2) {
  throw new Error("key registry status failed");
}

const oldPayload = encryption.reencryptPayload(plaintext, "smoke-v1", context);
if (encryption.getEncryptedPayloadKid(oldPayload) !== "smoke-v1") {
  throw new Error("old-key payload was not created with smoke-v1");
}
if (encryption.decryptString(oldPayload, context) !== plaintext) {
  throw new Error("old-key decrypt failed");
}

const encrypted = encryption.encryptString(plaintext, context);
if (encryption.getEncryptedPayloadKid(encrypted) !== "smoke-v2") {
  throw new Error("new payload did not use current key");
}
if (encryption.decryptString(encrypted, context) !== plaintext) {
  throw new Error("encrypt/decrypt round-trip failed");
}

const rotated = encryption.reencryptPayload(oldPayload, "smoke-v2", context);
if (encryption.getEncryptedPayloadKid(rotated) !== "smoke-v2") {
  throw new Error("rotation did not move payload to current key");
}
if (encryption.decryptString(rotated, context) !== plaintext) {
  throw new Error("rotated payload decrypt failed");
}

const envelope = JSON.parse(encrypted);
envelope.ciphertext = envelope.ciphertext.slice(0, -2) + "AA";
let tamperFailed = false;
try {
  encryption.decryptString(JSON.stringify(envelope), context);
} catch {
  tamperFailed = true;
}
if (!tamperFailed) {
  throw new Error("tamper detection did not fail");
}

if (encryption.decryptIfEncrypted("legacy plaintext", context) !== "legacy plaintext") {
  throw new Error("legacy plaintext fallback failed");
}

const stored = encryption.encryptIfEnabled("private buyer message", "store:sandbox.oneway.app:inquiry:message");
if (!encryption.isEncryptedPayload(stored)) {
  throw new Error("encryptIfEnabled did not produce an encrypted envelope");
}
if (encryption.decryptIfEncrypted(stored, "store:sandbox.oneway.app:inquiry:message") !== "private buyer message") {
  throw new Error("encrypted storefront field did not decrypt");
}

const firstHash = encryption.hmacLookup("buyer@example.com", "conversation:external_email:target");
const secondHash = encryption.hmacLookup("buyer@example.com", "conversation:external_email:target");
if (firstHash !== secondHash || !firstHash.startsWith("v1:")) {
  throw new Error("deterministic lookup hash failed");
}

console.log(JSON.stringify({
  ok: true,
  keyRegistry: { currentKeyId: "smoke-v2", availableKeyCount: 2 },
  oldKeyDecrypt: "passed",
  newWritesUseCurrentKey: "passed",
  rotation: "passed",
  tamperDetection: "passed",
  legacyPlaintextRead: "passed",
  stableLookupHash: "passed",
}));
