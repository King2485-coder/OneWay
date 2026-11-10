import assert from "node:assert/strict";
import { before, after, test } from "node:test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import express from "express";
import { PrismaClient } from "@prisma/client";
import { socialRouter } from "../src/routes/social";

const directory = mkdtempSync(join(tmpdir(), "oneway-social-test-"));
const database = `file:${join(directory, "social.db")}`;
const prisma = new PrismaClient({ datasources: { db: { url: database } } });
let server: ReturnType<express.Express["listen"]>;
let base: string;
let enabled = true;
const alice = "social-test-alice", bob = "social-test-bob", charlie = "social-test-charlie";

before(async () => {
  writeFileSync(join(directory, "social.db"), "");
  const setup = spawnSync(process.execPath, [resolve("node_modules/prisma/build/index.js"), "db", "push", "--skip-generate", "--schema", "prisma/schema.prisma"],
    { cwd: resolve("."), env: { ...process.env, DATABASE_URL: database }, encoding: "utf8" });
  assert.equal(setup.status, 0, setup.stderr);
  for (const id of [alice, bob, charlie]) await prisma.user.create({ data: { id, displayName: "PRIVATE NAME", email: `${id}@private.test`, passwordHash: "secret-hash" } });
  const app = express(); app.use(express.json());
  app.use("/api/social", socialRouter({ prisma, enabled: () => enabled, authenticate: (req, res, next) => {
    const id = req.header("x-test-user"); if (!id) { res.status(401).end(); return; }
    (req as any).userId = id; next();
  } }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => { console.error(error); res.status(500).json({ error: "test_server_error" }); });
  server = app.listen(0, "127.0.0.1"); await new Promise<void>(resolve => server.once("listening", resolve));
  base = `http://127.0.0.1:${(server.address() as any).port}/api/social`;
});
after(async () => { if (server) await new Promise<void>(resolve => server.close(() => resolve())); await prisma.$disconnect(); rmSync(directory, { recursive: true, force: true }); });

async function call(user: string | null, path: string, method = "GET", body?: unknown) {
  const result = await fetch(base + path, { method, headers: { ...(user ? { "x-test-user": user } : {}), "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await result.text(); return { status: result.status, data: text ? JSON.parse(text) : null };
}
const profile = (handle: string, discoverable = true) => ({ handle, displayName: handle.toUpperCase(), bio: "Test bio", website: "", discoverable });

test("social feature is gated and requires authentication", async () => {
  enabled = false; assert.equal((await call(alice, "/posts", "POST", { body: "blocked" })).status, 503);
  enabled = true; assert.equal((await call(null, "/people")).status, 401);
  assert.equal((await call(alice, "/me")).data.profile, null);
});
test("profiles opt into discovery and never expose account credentials", async () => {
  assert.equal((await call(alice, "/me", "PUT", profile("alice"))).status, 200);
  await call(bob, "/me", "PUT", profile("bob"));
  await call(charlie, "/me", "PUT", profile("charlie", false));
  const response = await call(alice, "/people");
  assert.deepEqual(response.data.profiles.map((p: any) => p.handle), ["alice", "bob"]);
  assert.doesNotMatch(JSON.stringify(response.data), /private.test|secret-hash|PRIVATE NAME/);
  assert.equal((await call(alice, "/profiles/charlie")).status, 404);
  assert.equal((await call(charlie, "/profiles/charlie")).status, 200);
});
test("handles are unique and validation rejects invalid URLs and oversized posts", async () => {
  assert.equal((await call(bob, "/me", "PUT", profile("alice"))).status, 409);
  assert.equal((await call(alice, "/me", "PUT", { ...profile("alice"), website: "javascript:alert(1)" })).status, 400);
  assert.equal((await call(alice, "/posts", "POST", { body: "x".repeat(2001) })).status, 400);
  assert.equal((await call(alice, "/posts", "POST", { body: "hi", audience: "friends" })).status, 400);
});
let privatePost: string, publicPost: string;
test("posts default to followers; public posting requires a discoverable profile", async () => {
  const created = await call(alice, "/posts", "POST", { body: "For followers" });
  assert.equal(created.status, 201); assert.equal(created.data.post.audience, "followers"); privatePost = created.data.post.id;
  const payload = { body: "Public update", audience: "public", clientId: randomUUID() };
  const published = await call(alice, "/posts", "POST", payload); publicPost = published.data.post.id;
  const repeated = await call(alice, "/posts", "POST", payload);
  assert.equal(repeated.status, 200); assert.equal(repeated.data.post.id, publicPost);
  assert.equal((await call(charlie, "/posts", "POST", { body: "Not public", audience: "public" })).status, 409);
  const discover = await call(bob, "/feed?mode=discover");
  assert.deepEqual(discover.data.posts.map((p: any) => p.id), [publicPost]);
  const page = await call(bob, "/profiles/alice"); assert.equal(page.data.profile.postCount, 1);
  assert.equal(page.data.posts.some((p: any) => p.id === privatePost), false);
});
test("follow is idempotent and unlocks follower posts; unfollow revokes visibility", async () => {
  assert.equal((await call(bob, `/following/${alice}`, "PUT")).status, 204);
  assert.equal((await call(bob, `/following/${alice}`, "PUT")).status, 204);
  assert.equal(await prisma.socialFollow.count(), 1);
  const feed = await call(bob, "/feed?mode=following"); assert.equal(feed.data.posts.length, 2);
  assert.equal((await call(bob, "/profiles/alice")).data.profile.postCount, 2);
  assert.equal((await call(bob, `/following/${bob}`, "PUT")).status, 400);
  await call(bob, `/following/${alice}`, "DELETE");
  assert.equal((await call(bob, "/feed?mode=following")).data.posts.length, 0);
  assert.equal((await call(bob, "/profiles/alice")).data.posts.length, 1);
});
test("post ownership and report visibility are enforced", async () => {
  assert.equal((await call(bob, `/posts/${publicPost}`, "DELETE")).status, 404);
  assert.equal((await call(bob, `/posts/${privatePost}/reports`, "POST", { reason: "spam" })).status, 404);
  assert.equal((await call(bob, `/posts/${publicPost}/reports`, "POST", { reason: "spam" })).status, 202);
  assert.equal((await call(bob, `/posts/${publicPost}/reports`, "POST", { reason: "harassment" })).status, 202);
  assert.equal(await prisma.socialReport.count(), 1);
});
test("blocking removes follows in both directions and hides both profiles and posts", async () => {
  await call(bob, `/following/${alice}`, "PUT"); await call(alice, `/following/${bob}`, "PUT");
  assert.equal((await call(bob, `/blocks/${alice}`, "PUT")).status, 204);
  assert.equal(await prisma.socialFollow.count(), 0);
  assert.equal((await call(alice, "/profiles/bob")).status, 404);
  assert.equal((await call(bob, "/profiles/alice")).status, 404);
  assert.equal((await call(alice, `/following/${bob}`, "PUT")).status, 404);
  assert.equal((await call(bob, "/feed?mode=discover")).data.posts.length, 0);
  assert.equal((await call(bob, "/blocks")).data.profiles[0].handle, "alice");
  await call(bob, `/blocks/${alice}`, "DELETE"); assert.equal((await call(bob, "/profiles/alice")).status, 200);
});
test("stable cursor pagination neither repeats nor skips equal-timestamp posts", async () => {
  for (const id of ["social-page-1", "social-page-2", "social-page-3"]) await prisma.socialPost.create({ data: { id, authorId: alice, body: id, audience: "public", createdAt: new Date("2099-01-01T00:00:00Z") } });
  const first = await call(bob, "/feed?mode=discover&limit=2"); assert.equal(first.data.posts.length, 2);
  const { before, beforeId } = first.data.next;
  const second = await call(bob, `/feed?mode=discover&limit=2&before=${encodeURIComponent(before)}&beforeId=${beforeId}`);
  assert.equal(new Set([...first.data.posts, ...second.data.posts].map((p: any) => p.id)).size, 4);
  assert.equal((await call(bob, "/feed?beforeId=missing")).status, 400);
  assert.equal((await call(bob, "/feed?limit=9999")).status, 400);
});
test("inactive accounts disappear and cannot read or publish", async () => {
  await prisma.user.update({ where: { id: alice }, data: { accountStatus: "deletion_pending" } });
  assert.equal((await call(bob, "/profiles/alice")).status, 404);
  assert.equal((await call(bob, "/feed?mode=discover")).data.posts.length, 0);
  assert.equal((await call(alice, "/posts", "POST", { body: "No" })).status, 401);
});
test("the additive migration applies and deleting an account cascades social data", async () => {
  const path = join(directory, "migration.db"); writeFileSync(path, "");
  const db = new PrismaClient({ datasources: { db: { url: `file:${path}` } } });
  try {
    await db.$executeRawUnsafe('CREATE TABLE "User" ("id" TEXT PRIMARY KEY NOT NULL)');
    const sql = readFileSync(resolve("prisma/migrations/20261110000000_enable_social_service/migration.sql"), "utf8");
    await db.$executeRawUnsafe('INSERT INTO "User" ("id") VALUES (?)', "existing-account-to-preserve");
    for (let pass = 0; pass < 2; pass++) {
      for (const statement of sql.split(";").map(s => s.trim()).filter(Boolean)) await db.$executeRawUnsafe(statement);
    }
    const preserved = await db.$queryRawUnsafe<Array<{id:string}>>('SELECT "id" FROM "User" WHERE "id"=?', "existing-account-to-preserve");
    assert.equal(preserved.length, 1);
    await db.$executeRaw`INSERT INTO "User" ("id") VALUES ('migration-author')`;
    await db.socialProfile.create({ data: { userId: "migration-author", handle: "migration_author", displayName: "Author" } });
    await db.socialPost.create({ data: { authorId: "migration-author", body: "Cascade test" } });
    await db.$executeRaw`DELETE FROM "User" WHERE "id" = 'migration-author'`;
    assert.equal(await db.socialProfile.count(), 0); assert.equal(await db.socialPost.count(), 0);
  } finally { await db.$disconnect(); }
});
