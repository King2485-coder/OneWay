import {ghostMode, setGhostMode, mayCommunicate} from "../src/services/AccountVisibility";
import {accountVisibilityRouter} from "../src/routes/accountVisibility";
import {usersRouter} from "../src/routes/users";
import assert from "node:assert/strict";
import { before, after, test } from "node:test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { Readable } from "node:stream";
import { cloudMediaRouter } from "../src/routes/cloudMedia";
import { randomBytes, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import express from "express";
import { PrismaClient } from "@prisma/client";
import { socialRouter } from "../src/routes/social";

process.env.FIELD_ENCRYPTION_ENABLED = "true";
process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64 = randomBytes(32).toString("base64");
const objects = new Map<string, Buffer>();
const storage = {
  put: async (key: string, bytes: Buffer) => { objects.set(key, bytes); return { key, bytes: bytes.length }; },
  read: async (key: string) => objects.has(key) ? { stream: Readable.from(objects.get(key)!), bytes: objects.get(key)!.length, contentType: "application/octet-stream" } : null,
  delete: async (key: string) => { objects.delete(key); },
} as any;
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
  await prisma.$executeRawUnsafe('CREATE TABLE "CloudFile" ("id" TEXT PRIMARY KEY, "ownerId" TEXT, "name" TEXT, "mimeType" TEXT, "byteCount" INTEGER, "storageKey" TEXT, "encrypted" BOOLEAN, "createdAt" DATETIME, "updatedAt" DATETIME)');
  await prisma.$executeRawUnsafe('CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY, "userId" TEXT, "key" TEXT, "value" TEXT, "updatedAt" DATETIME NOT NULL, UNIQUE("userId","key"))');
  const app = express(); app.use(express.json());
  const authenticate: express.RequestHandler = (req, res, next) => { const id = req.header("x-test-user"); if (!id) { res.status(401).end(); return; } (req as any).userId = id; next(); };
  app.use("/api/account-visibility", authenticate, accountVisibilityRouter(prisma));
  app.use("/api/users", usersRouter({db: prisma, authenticate}));
  app.use("/api/platform/cloud", cloudMediaRouter({ prisma, storage, authenticate }));
  app.use("/api/social", socialRouter({ prisma, storage, enabled: () => enabled, authenticate: (req, res, next) => {
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
  assert.equal((await fetch(base + "/feed", {headers: {"x-test-user": alice}})).headers.get("cache-control"), "private, no-store");
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
test("profile media publishes only a selected copy and respects visibility, blocks, removal and ownership", async () => {
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+yY7sAAAAASUVORK5CYII=", "base64");
  async function upload(user: string, name: string) {
    const form = new FormData(); form.set("file", new Blob([png], { type: "image/png" }), name);
    const response = await fetch(base.replace("/api/social", "/api/platform/cloud/files/upload"), { method: "POST", headers: { "x-test-user": user }, body: form });
    assert.equal(response.status, 201); return (await response.json() as any).file;
  }
  const original = await upload(alice, "private-original.png");
  const copy = await upload(alice, "selected-social-copy.png");
  const other = await upload(bob, "other-owner.png");
  assert.equal((await call(alice, "/me", "PUT", { ...profile("alice"), avatarFileId: other.id })).status, 400);
  assert.equal((await call(alice, "/me", "PUT", { ...profile("alice"), avatarFileId: copy.id, coverFileId: copy.id })).status, 200);
  let own = (await call(alice, "/me")).data.profile;
  assert.ok(own.avatarVersion && own.coverVersion);
  assert.doesNotMatch(JSON.stringify(own), new RegExp(copy.id + "|private-media/|storageKey|ownerId"));
  const route = `/profiles/alice/media/avatar?v=${own.avatarVersion}`;
  const read = async (user: string | null, path = route) => fetch(base + path, { headers: user ? { "x-test-user": user } : {} });
  assert.equal((await read(null)).status, 401);
  let fetched = await read(bob); assert.equal(fetched.status, 200); assert.deepEqual(Buffer.from(await fetched.arrayBuffer()), png);
  assert.equal(fetched.headers.get("cache-control"), "private, no-store");
  assert.equal((await read(bob, route.replace(own.avatarVersion, "stale-version"))).status, 404);
  const privatePath = base.replace("/api/social", `/api/platform/cloud/files/${original.id}/content`);
  assert.equal((await fetch(privatePath, { headers: { "x-test-user": bob } })).status, 404);
  assert.equal((await fetch(privatePath, { headers: { "x-test-user": alice } })).status, 200);
  // A text-only update from an older client preserves the image link.
  await call(alice, "/me", "PUT", profile("alice", false));
  assert.equal((await call(alice, "/me")).data.profile.avatarVersion, own.avatarVersion);
  assert.equal((await read(bob)).status, 404); assert.equal((await read(alice)).status, 200);
  await call(alice, "/me", "PUT", profile("alice", true));
  await call(bob, `/blocks/${alice}`, "PUT"); assert.equal((await read(bob)).status, 404);
  await call(bob, `/blocks/${alice}`, "DELETE"); assert.equal((await read(bob)).status, 200);
  await call(alice, "/me", "PUT", { ...profile("alice"), avatarFileId: null, coverFileId: null });
  assert.equal((await read(alice)).status, 404);
  // Removing the public copy never deletes the user's private original.
  assert.equal((await fetch(privatePath, { headers: { "x-test-user": alice } })).status, 200);
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

test("profile accents and owned publication pins persist without exposing drafts", async () => {
  const owner = randomUUID(), viewer = randomUUID();
  for (const id of [owner, viewer]) await prisma.user.create({data: {id, displayName: "Pin test", email: `${id}@example.invalid`, passwordHash: "test"}});
  const ownProfile = profile("pin_owner");
  await call(owner, "/me", "PUT", ownProfile);
  await call(viewer, "/me", "PUT", profile("pin_viewer"));
  async function makeSite(userId: string, slug: string, published: boolean) {
    const site = await prisma.site.create({data: {userId, domain: slug, slug, title: "My creative space", status: published ? "PUBLISHED" : "DRAFT", publishedAt: published ? new Date() : null}});
    if (published) {
      const pub = await prisma.sitePublication.create({data: {siteId: site.id, versionNumber: 1, status: "ACTIVE", publishedBy: userId, contentManifest: "{}", assetManifest: "[]", publicAddress: `oneway://${slug}`}});
      await prisma.site.update({where: {id: site.id}, data: {activePublicationId: pub.id}});
    }
    return site;
  }
  const own = await makeSite(owner, "pin-own", true), draft = await makeSite(owner, "pin-draft", false), other = await makeSite(viewer, "pin-other", true);
  assert.deepEqual((await call(owner, "/pin-sites")).data.sites.map((s: any) => s.id), [own.id]);
  assert.equal((await call(owner, "/me", "PUT", {...ownProfile, accent: "custom-css"})).status, 400);
  for (const id of [draft.id, other.id, randomUUID()]) assert.equal((await call(owner, "/me", "PUT", {...ownProfile, pinnedSiteId: id})).status, 400);
  const saved = await call(owner, "/me", "PUT", {...ownProfile, accent: "amber", pinnedSiteId: own.id});
  assert.equal(saved.status, 200); assert.equal(saved.data.profile.accent, "amber"); assert.equal(saved.data.profile.pinnedWebsite.address, "oneway://pin-own");
  assert.equal((await call(viewer, "/profiles/pin_owner")).data.profile.pinnedWebsite.id, own.id);
  await call(owner, "/me", "PUT", ownProfile);
  assert.equal((await call(owner, "/me")).data.profile.accent, "amber");
  assert.equal((await call(owner, "/me")).data.profile.pinnedWebsite.id, own.id);
  await prisma.site.update({where: {id: own.id}, data: {status: "UNPUBLISHED"}});
  assert.equal((await call(viewer, "/profiles/pin_owner")).data.profile.pinnedWebsite, null);
  assert.deepEqual((await call(owner, "/pin-sites")).data.sites, []);
  await call(owner, "/me", "PUT", {...ownProfile, pinnedSiteId: null});
  assert.equal((await call(owner, "/me")).data.profile.pinnedWebsite, null);
});

test("authors can edit their own posts with audience choices, preserving ownership and stale-write protection", async () => {
  const owner = randomUUID(), viewer = randomUUID();
  for (const id of [owner, viewer]) await prisma.user.create({data: {id, displayName: "Edit test", email: `${id}@example.invalid`, passwordHash: "test"}});
  await call(owner, "/me", "PUT", profile("edit_owner")); await call(viewer, "/me", "PUT", profile("edit_viewer"));
  const created = await call(owner, "/posts", "POST", {body: "Community first", audience: "public"});
  const id = created.data.post.id;
  assert.ok((await call(viewer, "/feed?mode=discover")).data.posts.some((p: any) => p.id === id)); // No follow needed.
  const changes = {body: "Updated community post", audience: "public", expectedBody: "Community first", expectedAudience: "public"};
  assert.equal((await call(viewer, `/posts/${id}`, "PATCH", changes)).status, 404);
  assert.equal((await call(owner, `/posts/${id}`, "PATCH", changes)).status, 200);
  assert.equal((await call(owner, `/posts/${id}`, "PATCH", changes)).status, 200); // Retry is safe.
  assert.equal((await call(owner, `/posts/${id}`, "PATCH", {...changes, body: "Stale overwrite"})).status, 409);
  assert.equal((await call(owner, `/posts/${id}`, "PATCH", {...changes, body: "", expectedBody: changes.body})).status, 400);
  assert.equal((await call(owner, `/posts/${id}`, "PATCH", {...changes, body: "Only followers", audience: "followers", expectedBody: changes.body})).status, 200);
  assert.equal((await call(viewer, "/feed?mode=discover")).data.posts.some((p: any) => p.id === id), false);
  assert.equal((await call(viewer, "/profiles/edit_owner")).data.posts.some((p: any) => p.id === id), false);
  await call(viewer, `/following/${owner}`, "PUT");
  assert.equal((await call(viewer, "/feed?mode=following")).data.posts.find((p: any) => p.id === id).body, "Only followers");
  const privatePost = await call(owner, "/posts", "POST", {body: "Legacy private"});
  assert.equal(privatePost.data.post.audience, "followers"); // Old clients never silently publish private posts.
  await call(owner, "/me", "PUT", profile("edit_owner", false));
  assert.equal((await call(owner, `/posts/${id}`, "PATCH", {body: "Publish hidden profile", audience: "public", expectedBody: "Only followers", expectedAudience: "followers"})).status, 409);
});

test("every feed and profile post carries the author's current opaque avatar version and public identity", async () => {
  const owner = randomUUID(), viewer = randomUUID();
  for (const id of [owner, viewer]) await prisma.user.create({data: {id, displayName: "Avatar test", email: `${id}@example.invalid`, passwordHash: "test"}});
  await call(owner, "/me", "PUT", profile("photo_owner")); await call(viewer, "/me", "PUT", profile("photo_viewer"));
  async function upload() {
    const form = new FormData(); form.set("file", new Blob([Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+yY7sAAAAASUVORK5CYII=", "base64")], {type: "image/png"}), "avatar.png");
    const res = await fetch(base.replace("/api/social", "/api/platform/cloud/files/upload"), {method: "POST", headers: {"x-test-user": owner}, body: form});
    assert.equal(res.status, 201); return (await res.json() as any).file;
  }
  const first = await upload(); const p = {...profile("photo_owner"), avatarFileId: first.id};
  const saved = (await call(owner, "/me", "PUT", p)).data.profile;
  const created = await call(owner, "/posts", "POST", {body: "Photo on every post", audience: "public"});
  assert.equal(created.data.post.author.avatarVersion, saved.avatarVersion);
  const id = created.data.post.id;
  const feedAuthor = (await call(viewer, "/feed?mode=discover")).data.posts.find((p: any) => p.id === id).author;
  assert.equal(feedAuthor.avatarVersion, saved.avatarVersion);
  assert.doesNotMatch(JSON.stringify(feedAuthor), new RegExp(first.id + "|private-media/|storageKey|passwordHash"));
  const second = await upload();
  const changed = (await call(owner, "/me", "PUT", {...p, displayName: "Updated public name", avatarFileId: second.id})).data.profile;
  assert.notEqual(changed.avatarVersion, saved.avatarVersion);
  const author = (await call(viewer, "/profiles/photo_owner")).data.posts.find((p: any) => p.id === id).author;
  assert.equal(author.avatarVersion, changed.avatarVersion); assert.equal(author.displayName, "Updated public name");
  await call(owner, "/me", "PUT", {...p, avatarFileId: null});
  assert.equal((await call(viewer, "/feed?mode=discover")).data.posts.find((p: any) => p.id === id).author.avatarVersion, null);
  await call(viewer, `/blocks/${owner}`, "PUT");
  assert.equal((await call(viewer, "/feed?mode=discover")).data.posts.some((p: any) => p.id === id), false);
});

test("Ghost mode removes discovery, blocks unapproved communication and requires two-sided approval", async () => {
  const owner = randomUUID(), viewer = randomUUID();
  for (const id of [owner, viewer]) await prisma.user.create({data: {id, email: `${id}@example.invalid`, displayName: "Ghost fixture", passwordHash: "test"}});
  await call(owner, "/me", "PUT", profile("ghost_owner")); await call(viewer, "/me", "PUT", profile("ghost_viewer"));
  const pub = await call(owner, "/posts", "POST", {body: "Public before Ghost", audience: "public"});
  await setGhostMode(prisma, owner, true); assert.equal(await ghostMode(prisma, owner), true);
  assert.equal((await call(viewer, "/people?q=ghost_owner")).data.profiles.length, 0);
  assert.equal((await call(viewer, "/profiles/ghost_owner")).status, 404);
  assert.equal((await call(viewer, "/feed?mode=discover")).data.posts.some((p: any) => p.id === pub.data.post.id), false);
  assert.equal((await call(owner, "/posts", "POST", {body: "Must not silently leave Ghost", audience: "public"})).data.error, "ghost_mode_active");
  assert.equal((await call(owner, "/posts", "POST", {body: "Still private", audience: "followers"})).status, 201);
  assert.equal(await mayCommunicate(prisma, viewer, owner), false); assert.equal(await mayCommunicate(prisma, owner, viewer), false);
  assert.equal(await mayCommunicate(prisma, viewer.toUpperCase(), owner.toUpperCase()), false);
  await prisma.oneWayContact.create({data: {userId: owner, contactUserId: viewer, status: "connected", direction: "incoming"}});
  assert.equal(await mayCommunicate(prisma, viewer, owner), false);
  await prisma.oneWayContact.create({data: {userId: viewer, contactUserId: owner, status: "connected", direction: "outgoing"}});
  assert.equal(await mayCommunicate(prisma, viewer, owner), true);
  assert.equal(await mayCommunicate(prisma, viewer.toUpperCase(), owner.toUpperCase()), true);
  assert.equal((await call(viewer, "/profiles/ghost_owner")).status, 200);
  await prisma.oneWayContact.update({where: {userId_contactUserId: {userId: owner, contactUserId: viewer}}, data: {status: "blocked"}});
  assert.equal(await mayCommunicate(prisma, viewer, owner), false);
  await setGhostMode(prisma, owner, false);
  assert.equal((await call(viewer, "/profiles/ghost_owner")).status, 200); // Discovery preference was preserved, not silently rewritten.
});

test("Ghost accounts cannot be found by partial names or IDs; exact shared identifiers reveal only a request target", async () => {
  const owner = randomUUID(), viewer = randomUUID();
  for (const id of [owner, viewer]) await prisma.user.create({data: {id, email: `${id}@example.invalid`, displayName: "Private Secret Name", passwordHash: "test", chirpId: id === owner ? "OW87654321" : "OW87654322", chirpIdNormalized: id === owner ? "OW87654321" : "OW87654322"}});
  await prisma.oneWayIdentity.create({data: {userId: owner, onewayId: "@quiet_hidden_fixture", emailAlias: "hiddenfixture@oneway.app", displayName: "Private Secret Name", showOneWayId: false, showNumbers: false, showEmailAlias: false}});
  await prisma.userNumber.create({data: {userId: owner, number: "+15205551234"}});
  await setGhostMode(prisma, owner, true);
  for (const user of await prisma.user.findMany({where: {identity: {is: null}}, select: {id: true}})) await prisma.oneWayIdentity.create({data: {userId: user.id, onewayId: "@fixture_" + user.id.replaceAll("-", "").slice(0,20), emailAlias: user.id + "@oneway.app", displayName: "Fixture"}});
  async function search(q: string) { const r = await fetch(base.replace("/api/social", "/api/users/search?q=" + encodeURIComponent(q)), {headers: {"x-test-user": viewer}}); assert.equal(r.status, 200); return (await r.json() as any).users; }
  for (const query of ["Private", "quiet_hidden", "OW8765", "520555", owner]) assert.equal((await search(query)).some((u: any) => u.id === owner), false);
  for (const query of ["@quiet_hidden_fixture", "OW87654321", "hiddenfixture@oneway.app", "+15205551234", "5205551234"]) {
    const target = (await search(query)).find((u: any) => u.id === owner); assert.ok(target, query);
    assert.equal(target.displayName, "Private OneWay account"); assert.equal(target.username, null); assert.equal(target.primaryNumber, null);
    assert.doesNotMatch(JSON.stringify(target), /Private Secret Name|passwordHash|@example.invalid/);
  }
});

test("profile contact disclosure defaults to nothing, validates ownership and preserves explicit choices for older clients", async () => {
  const owner = randomUUID(), other = randomUUID();
  for (const id of [owner, other]) await prisma.user.create({data: {id, email: `${id}@example.invalid`, displayName: "Contact fixture", passwordHash: "test"}});
  await prisma.oneWayIdentity.create({data: {userId: owner, onewayId: "@contact_fixture", emailAlias: "contactfixture@oneway.app"}});
  const mine = await prisma.userNumber.create({data: {userId: owner, number: "+15205551235"}}), theirs = await prisma.userNumber.create({data: {userId: other, number: "+15205551236"}});
  const p = profile("contact_fixture");
  assert.equal((await call(owner, "/me", "PUT", p)).data.profile.publicContact, null);
  const options = (await call(owner, "/contact-options")).data.options;
  assert.equal(options[0].key, "none"); assert.equal(options.some((o: any) => o.key === `number:${theirs.id}`), false);
  assert.equal((await call(owner, "/me", "PUT", {...p, contactDisplay: `number:${theirs.id}`})).status, 400);
  const selected = await call(owner, "/me", "PUT", {...p, contactDisplay: `number:${mine.id}`});
  assert.equal(selected.data.profile.publicContact.value, mine.number);
  await call(owner, "/me", "PUT", p);
  assert.equal((await call(owner, "/me")).data.profile.publicContact.value, mine.number);
  await call(owner, "/me", "PUT", {...p, contactDisplay: "none"});
  assert.equal((await call(other, "/profiles/contact_fixture")).data.profile.publicContact, null);
});

test("visibility saves belong only to the authenticated owner and reject spoofed owner fields", async () => {
  const owner = randomUUID(), other = randomUUID();
  for (const id of [owner, other]) await prisma.user.create({data: {id, email: `${id}@example.invalid`, displayName: "Visibility fixture", passwordHash: "test"}});
  const endpoint = base.replace("/api/social", "/api/account-visibility");
  let r = await fetch(endpoint, {method: "PATCH", headers: {"x-test-user": owner,"Content-Type":"application/json"}, body: JSON.stringify({ghostMode: true, userId: other})}); assert.equal(r.status, 400);
  r = await fetch(endpoint, {method: "PATCH", headers: {"x-test-user": owner,"Content-Type":"application/json"}, body: JSON.stringify({ghostMode: true})}); assert.equal(r.status, 200);
  assert.equal(await ghostMode(prisma, owner), true); assert.equal(await ghostMode(prisma, other), false);
  assert.equal((await fetch(endpoint)).status, 401);
});

test("communication privacy fails closed if policy storage is unavailable", async () => {
  const broken = {oneWayContact: {findFirst: async () => null}, $queryRawUnsafe: async () => {throw new Error("offline");}};
  assert.equal(await mayCommunicate(broken as any, randomUUID(), randomUUID()), false);
});
