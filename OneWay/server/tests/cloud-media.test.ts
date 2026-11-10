import test from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { Readable } from "node:stream";
import { randomBytes } from "node:crypto";
import { cloudMediaRouter } from "../src/routes/cloudMedia";

process.env.FIELD_ENCRYPTION_ENABLED = "true";
process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64 = randomBytes(32).toString("base64");

test("private cloud uploads real encrypted media and downloads only for its owner", async () => {
  const rows: any[] = []; const objects = new Map<string, Buffer>();
  const prisma = {
    $executeRawUnsafe: async (_sql: string, id: string, ownerId: string, name: string, mimeType: string, byteCount: number, storageKey: string) => { rows.push({ id, ownerId, name, mimeType, byteCount, storageKey }); },
    $queryRawUnsafe: async (sql: string, id: string, ownerId: string) => sql.includes("SUM(") ? [{ bytes: 0 }] : rows.filter(row => row.id === id && row.ownerId === ownerId),
  };
  const storage = {
    put: async (key: string, data: Buffer) => { objects.set(key, data); return { key, bytes: data.length }; },
    read: async (key: string) => objects.has(key) ? { stream: Readable.from(objects.get(key)!), bytes: objects.get(key)!.length, contentType: "application/octet-stream" } : null,
    delete: async (key: string) => { objects.delete(key); },
  };
  const app = express();
  app.use("/cloud", cloudMediaRouter({ prisma: prisma as any, storage: storage as any, authenticate: (req, res, next) => {
    const owner = req.header("x-test-owner"); if (!owner) { res.status(401).end(); return; } (req as any).userId = owner; next();
  } }));
  const server = app.listen(0, "127.0.0.1"); await new Promise<void>(resolve => server.on("listening", resolve));
  const base = `http://127.0.0.1:${(server.address() as any).port}/cloud/files`;
  try {
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+yY7sAAAAASUVORK5CYII=", "base64");
    const form = new FormData(); form.set("file", new Blob([png], { type: "image/png" }), "profile.png");
    const upload = await fetch(base + "/upload", { method: "POST", headers: { "x-test-owner": "alice" }, body: form });
    assert.equal(upload.status, 201); const { file } = await upload.json() as any;
    assert.equal(file.byteCount, png.length); assert.equal(file.encrypted, true);
    const stored = objects.get(file.storageKey)!;
    assert.equal(stored.includes(png), false); assert.equal(stored.toString().includes(png.toString("base64")), false);
    const own = await fetch(base + `/${file.id}/content`, { headers: { "x-test-owner": "alice" } });
    assert.equal(own.status, 200); assert.deepEqual(Buffer.from(await own.arrayBuffer()), png); assert.equal(own.headers.get("cache-control"), "no-store");
    assert.equal((await fetch(base + `/${file.id}/content`, { headers: { "x-test-owner": "bob" } })).status, 404);
    assert.equal((await fetch(base + `/${file.id}/content`)).status, 401);
    const bad = new FormData(); bad.set("file", new Blob(["not an image"], { type: "image/png" }), "bad.png");
    assert.equal((await fetch(base + "/upload", { method: "POST", headers: { "x-test-owner": "alice" }, body: bad })).status, 400);
    assert.equal(rows.length, 1);
  } finally { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); }
});
