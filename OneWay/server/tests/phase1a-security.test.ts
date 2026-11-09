import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  assertLegacyDecryptable,
  communityMessageRequestSchema,
  directMessageRequestSchema,
  encryptedAttachmentManifestV1Schema,
  encryptedMessageEnvelopeV1Schema,
  LegacyDecryptIsolationError,
} from "../src/services/security/MessageContentBoundary";
import { VoIPPushService } from "../src/services/VoIPPushService";

const id = "11111111-1111-4111-8111-111111111111";
const otherId = "22222222-2222-4222-8222-222222222222";

function directEnvelope() {
  return {
    contentMode: "E2EE_V1",
    protocolVersion: 1,
    messageId: id,
    conversationId: otherId,
    senderUserId: "sender",
    senderDeviceId: id,
    recipientDeviceIds: [otherId],
    ciphertext: "opaque-ciphertext-value-0001",
    attachmentManifests: [],
    createdAt: "2026-10-22T00:00:00.000Z",
    contentType: "message",
    protocolMetadata: {},
    replayId: "replay-identifier-0001",
  };
}

test("future direct envelope has no plaintext field and rejects injected body", () => {
  assert.equal(encryptedMessageEnvelopeV1Schema.safeParse(directEnvelope()).success, true);
  assert.equal(encryptedMessageEnvelopeV1Schema.safeParse({ ...directEnvelope(), body: "plaintext" }).success, false);
  assert.equal(directMessageRequestSchema.safeParse({ ...directEnvelope(), body: "plaintext" }).success, false);
});

test("future E2EE envelope cannot enter legacy decrypt boundary", () => {
  assert.throws(() => assertLegacyDecryptable(directEnvelope()), LegacyDecryptIsolationError);
  assert.doesNotThrow(() => assertLegacyDecryptable({ contentMode: "LEGACY_NOT_E2EE", body: "legacy" }));
});

test("future attachment manifest cannot contain inline bytes or filename", () => {
  const valid = {
    version: 1,
    objectId: id,
    ciphertextByteCount: 100,
    ciphertextSHA256: "a".repeat(64),
    encryptedManifest: "opaque-encrypted-manifest-0001",
  };
  assert.equal(encryptedAttachmentManifestV1Schema.safeParse(valid).success, true);
  assert.equal(encryptedAttachmentManifestV1Schema.safeParse({ ...valid, payloadBase64: "private" }).success, false);
  assert.equal(encryptedAttachmentManifestV1Schema.safeParse({ ...valid, fileName: "private.jpg" }).success, false);
});

test("future Community envelope cannot contain plaintext body", () => {
  const envelope = {
    contentMode: "GROUP_E2EE_V1",
    protocolVersion: 1,
    groupId: id,
    groupEpoch: 1,
    messageId: otherId,
    senderUserId: "sender",
    senderDeviceId: id,
    ciphertext: "opaque-group-ciphertext-0001",
    createdAt: "2026-10-22T00:00:00.000Z",
    contentType: "message",
    protocolMetadata: {},
    replayId: "group-replay-identifier-0001",
    encryptedAttachmentManifests: [],
  };
  assert.equal(communityMessageRequestSchema.safeParse(envelope).success, true);
  assert.equal(communityMessageRequestSchema.safeParse({ ...envelope, body: "plaintext" }).success, false);
});

test("Community APNs payload is generic and excludes sender, body, and filename sentinels", () => {
  const sentinel = "ONEWAY-PRIVATE-SENTINEL-91c82d";
  const service = Object.create(VoIPPushService.prototype) as VoIPPushService;
  const payload = (service as any).buildCommunityPayload({
    userId: id,
    communityId: id,
    communityName: sentinel,
    messageId: otherId,
    senderHandle: sentinel,
    senderDisplayName: sentinel,
    body: sentinel,
  });
  assert.equal(JSON.stringify(payload).includes(sentinel), false);
  assert.deepEqual(payload.aps.alert, { title: "OneWay", body: "New community message" });
});

test("Supabase hardening preserves owner checks and least-privilege grants", () => {
  const migration = fs.readFileSync(path.resolve(__dirname, "../../supabase/migrations/20261022013000_phase1a_authorization_hardening.sql"), "utf8");
  assert.match(migration, /storage\.objects for update[\s\S]*using[\s\S]*with check/i);
  assert.doesNotMatch(migration, /auth\.role\(\)/);
  assert.match(migration, /revoke all on function public\.expire_domains\(\) from public, anon, authenticated/i);
});

test("private-content paths do not pass body values to loggers", () => {
  const files = [
    "src/services/EmailAlertPushService.ts",
    "src/services/VoIPPushService.ts",
    "src/routes/messages.ts",
    "src/routes/communities.ts",
  ];
  for (const file of files) {
    const source = fs.readFileSync(path.resolve(__dirname, "..", file), "utf8");
    const loggerObjects = source.matchAll(/logger\.(?:info|warn|error|debug)\s*\(\s*\{([\s\S]*?)\}\s*,/g);
    for (const match of loggerObjects) {
      assert.doesNotMatch(match[1], /(?:^|,)\s*(?:body|ciphertext|payloadBase64)\s*:/m, file);
    }
  }
});
