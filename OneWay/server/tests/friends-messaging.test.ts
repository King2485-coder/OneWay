import test, { after, before } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import express from "express";

const directory = mkdtempSync(join(tmpdir(), "oneway-friends-messaging-"));
writeFileSync(join(directory, "test.db"), "");
process.env.DATABASE_URL = "file:" + join(directory, "test.db");
process.env.JWT_AUTH_REQUIRED = "false";
process.env.NODE_ENV = "test";

let db: any;
let server: ReturnType<express.Express["listen"]>;
let baseURL: string;
const users = [randomUUID(), randomUUID(), randomUUID()];

before(async () => {
  const setup = spawnSync(
    process.execPath,
    [resolve("node_modules/prisma/build/index.js"), "db", "push", "--skip-generate", "--schema", "prisma/schema.prisma"],
    { env: process.env, encoding: "utf8" },
  );
  assert.equal(setup.status, 0, setup.stderr);

  db = (await import("../src/lib/db")).prisma;
  await db.$executeRawUnsafe(
    'CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY,"userId" TEXT,"key" TEXT,"value" TEXT,"updatedAt" DATETIME,UNIQUE("userId","key"))',
  );
  for (let index = 0; index < users.length; index += 1) {
    await db.user.create({
      data: {
        id: users[index],
        email: `${users[index]}@test.invalid`,
        passwordHash: "synthetic-test-only",
        displayName: `Synthetic User ${index + 1}`,
      },
    });
    await db.oneWayIdentity.create({
      data: {
        userId: users[index],
        onewayId: `@synthetic_${index + 1}`,
        emailAlias: `${users[index]}@test.invalid`,
        displayName: `Synthetic User ${index + 1}`,
      },
    });
  }

  const [{ friendsRouter }, { messagesRouter }, { walkieRouter, ensureDirectChirpTables }] = await Promise.all([
    import("../src/routes/friends"),
    import("../src/routes/messages"),
    import("../src/routes/walkie"),
  ]);
  await ensureDirectChirpTables(db);
  const app = express();
  app.use(express.json());
  app.use("/friends", friendsRouter({ prisma: db }));
  app.use("/messages", messagesRouter());
  app.use("/chirp", walkieRouter({
    prisma: db,
    tokens: {
      isConfigured: () => true,
      issue: async () => ({
        token: "synthetic-test-token",
        url: "wss://example.invalid",
        expiresAt: new Date(Date.now() + 60_000).toISOString(),
      }),
    } as any,
  }));
  app.use((error: any, _request: any, response: any, _next: any) => {
    response.status(500).json({ error: error.message });
  });
  server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolveListening) => server.once("listening", resolveListening));
  baseURL = `http://127.0.0.1:${(server.address() as any).port}`;
});

after(async () => {
  if (server) {
    server.closeAllConnections();
    await new Promise<void>((resolveClosed) => server.close(() => resolveClosed()));
  }
  await db?.$disconnect();
  rmSync(directory, { recursive: true, force: true });
});

async function call(userIndex: number, path: string, method = "GET", body?: unknown) {
  const response = await fetch(baseURL + path, {
    method,
    headers: {
      "X-Dev-User-Id": users[userIndex],
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, data: text ? JSON.parse(text) : null };
}

test("approval creates reciprocal contacts, enables Chirp acceptance and delivers a direct text", async () => {
  const pending = await call(0, "/friends/request", "POST", { recipientUserId: users[1] });
  assert.equal(pending.status, 201, JSON.stringify(pending.data));
  const friendshipID = pending.data.friendship.id;

  const accepted = await call(1, `/friends/${friendshipID}/accept`, "POST", {});
  assert.equal(accepted.status, 200, JSON.stringify(accepted.data));

  for (const userIndex of [0, 1]) {
    const overview = await call(userIndex, "/friends/overview");
    assert.equal(overview.status, 200);
    assert.equal(overview.data.contacts.length, 1);
    assert.equal(overview.data.incomingRequests.length, 0);
    assert.equal(overview.data.outgoingRequests.length, 0);
  }

  const chirpRequest = await call(0, "/chirp/direct/request", "POST", {
    recipientChirpId: "@synthetic_2",
    clientRequestId: randomUUID(),
    mode: "private",
  });
  assert.equal(chirpRequest.status, 201, JSON.stringify(chirpRequest.data));
  const chirpRequestID = chirpRequest.data.request.id;

  const incomingChirps = await call(1, "/chirp/direct/incoming");
  assert.equal(incomingChirps.status, 200);
  assert.equal(incomingChirps.data.requests[0].id, chirpRequestID);

  const acceptedChirp = await call(1, `/chirp/direct/${chirpRequestID}/accept`, "POST", {});
  assert.equal(acceptedChirp.status, 200, JSON.stringify(acceptedChirp.data));
  assert.equal(acceptedChirp.data.request.status, "accepted");
  assert.deepEqual(
    acceptedChirp.data.session.participants.map((participant: any) => participant.userId).sort(),
    [users[0], users[1]].sort(),
  );

  const conversation = await call(0, "/messages/conversations/direct", "POST", { participantUserId: users[1] });
  assert.equal(conversation.status, 200, JSON.stringify(conversation.data));
  const conversationID = conversation.data.conversation.id;

  const sent = await call(0, `/messages/conversations/${conversationID}/messages`, "POST", {
    contentMode: "LEGACY_NOT_E2EE",
    body: "Synthetic delivery check",
    clientMessageId: randomUUID(),
    disappearing: "inherit",
  });
  assert.equal(sent.status, 201, JSON.stringify(sent.data));

  const received = await call(1, `/messages/conversations/${conversationID}/messages`);
  assert.equal(received.status, 200, JSON.stringify(received.data));
  assert.equal(received.data.messages.length, 1);
  assert.equal(received.data.messages[0].body, "Synthetic delivery check");
  assert.equal(received.data.messages[0].senderId, users[0].toLowerCase());

  const receipts = await db.messageReceipt.findMany({ where: { messageId: sent.data.message.id } });
  assert.deepEqual(receipts.map((item: any) => [item.userId, item.status]), [[users[1].toLowerCase(), "delivered"]]);
});

test("an unapproved user cannot create or reuse a direct conversation", async () => {
  const chirp = await call(2, "/chirp/direct/request", "POST", {
    recipientChirpId: "@synthetic_1",
    clientRequestId: randomUUID(),
    mode: "private",
  });
  assert.equal(chirp.status, 404);
  assert.equal(chirp.data.error, "direct_chirp_unavailable");

  const create = await call(2, "/messages/conversations/direct", "POST", { participantUserId: users[0] });
  assert.equal(create.status, 403);
  assert.equal(create.data.error, "contact_not_connected");

  const existing = await db.conversation.findFirst({ where: { type: "direct" } });
  await db.conversationParticipant.create({ data: { conversationId: existing.id, userId: users[2] } });
  const bypass = await call(2, `/messages/conversations/${existing.id}/messages`, "POST", {
    body: "This must not send",
    clientMessageId: randomUUID(),
    disappearing: "inherit",
  });
  assert.equal(bypass.status, 403);
  assert.equal(bypass.data.error, "contact_approval_required");
});
