import assert from "node:assert/strict";
import test from "node:test";
import { EmailAlertPushService } from "../src/services/EmailAlertPushService";

function makeService(record: { previewMode: "sender_subject" | "sender" | "generic" | "none"; soundEnabled: boolean }) {
  const sent: Array<{ note: any; tokens: string[] }> = [];
  const tokens = {
    forUser: async () => [{ token: "a".repeat(64), environment: "sandbox" as const, ...record }],
    remove: async () => undefined,
  };
  const service = new EmailAlertPushService(tokens as any);
  (service as any).bundleId = "is.oneway.app";
  (service as any).provider = {
    send: async (note: any, deviceTokens: string[]) => {
      sent.push({ note, tokens: deviceTokens });
      return { sent: deviceTokens.map((device) => ({ device })), failed: [] };
    },
    shutdown: () => undefined,
  };
  return { service, sent };
}

test("direct message alert is generic even when a legacy preview preference requests content", async () => {
  const { service, sent } = makeService({ previewMode: "sender_subject", soundEnabled: true });
  await service.sendNewMessage({ userId: "recipient", conversationId: "conversation", messageId: "message", sender: "Alex", body: "Hello" });

  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].note.payload.aps.alert, { title: "OneWay", body: "New message" });
  assert.equal(JSON.stringify(sent[0].note.payload).includes("Alex"), false);
  assert.equal(JSON.stringify(sent[0].note.payload).includes("Hello"), false);
  assert.equal(sent[0].note.payload.aps.sound, "default");
  assert.equal(sent[0].note.payload.aps["thread-id"], "chat:conversation");
  assert.equal(sent[0].note.payload.deepLink, "oneway://messages");
  assert.equal(sent[0].note.payload.eventType, "chat.message.received");
});

test("disabled previews use generic copy and disabled sounds omit APNs sound", async () => {
  const { service, sent } = makeService({ previewMode: "generic", soundEnabled: false });
  await service.sendNewMessage({ userId: "recipient", conversationId: "conversation", messageId: "message", sender: "Alex", body: "Private text" });

  assert.deepEqual(sent[0].note.payload.aps.alert, { title: "OneWay", body: "New message" });
  assert.equal("sound" in sent[0].note.payload.aps, false);
});

test("disabled message notifications do not send an APNs alert", async () => {
  const { service, sent } = makeService({ previewMode: "none", soundEnabled: true });
  await service.sendNewMessage({ userId: "recipient", conversationId: "conversation", messageId: "message", sender: "Alex", body: "Hello" });
  assert.equal(sent.length, 0);
});

test("private sentinel text never appears in direct-message APNs payload", async () => {
  const sentinel = "ONEWAY-PRIVATE-SENTINEL-91c82d";
  const { service, sent } = makeService({ previewMode: "sender_subject", soundEnabled: true });
  await service.sendNewMessage({ userId: "recipient", conversationId: "conversation", messageId: "message", sender: sentinel, body: sentinel });
  assert.equal(JSON.stringify(sent[0].note.payload).includes(sentinel), false);
});
