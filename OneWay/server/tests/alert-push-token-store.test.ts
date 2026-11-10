import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PrismaClient } from "@prisma/client";
import { AlertPushTokenStore } from "../src/services/AlertPushTokenStore";

test("token registration handles the live legacy schema and concurrent refreshes without losing ownership", async () => {
  const root = await mkdtemp(join(tmpdir(), "oneway-alert-registration-"));
  const prisma = new PrismaClient({ datasources: { db: { url: `file:${join(root, "test.db")}` } } });
  try {
    await prisma.$executeRawUnsafe('CREATE TABLE "User" ("id" TEXT PRIMARY KEY)');
    await prisma.$executeRawUnsafe('INSERT INTO "User" ("id") VALUES (?), (?)', "alice", "bob");
    // Existing production schema: timestamps are required and have no default.
    await prisma.$executeRawUnsafe('CREATE TABLE "AlertPushToken" ("id" TEXT PRIMARY KEY, "userId" TEXT NOT NULL, "token" TEXT UNIQUE NOT NULL, "environment" TEXT NOT NULL, "previewMode" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL)');
    const store = new AlertPushTokenStore(prisma);
    const record = { token: "a".repeat(64), environment: "sandbox" as const, previewMode: "generic" as const, soundEnabled: true };
    await Promise.all([store.set("alice", record), store.set("alice", record)]);
    assert.equal((await store.forUser("alice")).length, 1);
    const timestamps = await prisma.$queryRawUnsafe<any[]>('SELECT "createdAt", "updatedAt" FROM "AlertPushToken"');
    assert.ok(timestamps[0].createdAt); assert.ok(timestamps[0].updatedAt);
    await store.set("bob", { ...record, environment: "production" });
    assert.equal((await store.forUser("alice")).length, 0);
    await store.remove(record.token, "alice");
    assert.equal((await store.forUser("bob")).length, 1);
    await store.remove(record.token, "bob");
    assert.equal((await store.forUser("bob")).length, 0);
  } finally { await prisma.$disconnect(); await rm(root, { recursive: true, force: true }); }
});
