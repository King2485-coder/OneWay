import test from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { Readable } from "node:stream";
import { randomBytes, randomUUID } from "node:crypto";
import { communityAttachmentsRouter, communityAttachmentKind, reservedCommunityAttachmentBody } from "../src/routes/communityAttachments";
process.env.FIELD_ENCRYPTION_ENABLED = "true";
process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64 = randomBytes(32).toString("base64");

test("community attachment allowlist rejects executable, HTML and forged images", () => {
  assert.equal(communityAttachmentKind(Buffer.from("MZ executable"), "application/octet-stream"), null);
  assert.equal(communityAttachmentKind(Buffer.from("<script>bad()</script>"), "text/html"), null);
  assert.equal(communityAttachmentKind(Buffer.from("not jpeg"), "image/jpeg"), null);
  assert.equal(communityAttachmentKind(Buffer.from("hello"), "text/plain"), "file");
  assert.equal(communityAttachmentKind(Buffer.from("%PDF-1.4\n%%EOF"), "application/pdf"), "file");
  assert.equal(communityAttachmentKind(Buffer.alloc(20 * 1024 * 1024 + 1), "text/plain"), null);
  assert.equal(reservedCommunityAttachmentBody('{"onewayCommunityAttachment":true,"key":"other"}'), true);
  assert.equal(reservedCommunityAttachmentBody("ordinary chat"), false);
});

test("community uploads are encrypted, idempotent and available only to current members", async () => {
  const communityId = randomUUID(); const rows: any[] = []; const objects = new Map<string, Buffer>(); const members = new Set(["alice", "bob"]);
  const prisma = {
    community: { findFirst: async ({where}: any) => where.id === communityId && members.has(where.members.some.userId) ? { id: communityId, bannedUserIdsJson: "[]", blockedUserIdsJson: "[]" } : null, update: async () => ({}) },
    communityMessage: { findMany: async () => rows, findFirst: async ({where}: any) => rows.find(r => Object.entries(where).every(([k,v]) => r[k] === v)), create: async ({data}: any) => { const row = {...data, createdAt: new Date()}; rows.push(row); return row; } },
  };
  const storage = { put: async (key: string, data: Buffer) => { objects.set(key,data); return {key,bytes:data.length}; }, read: async (key: string) => objects.has(key) ? {stream:Readable.from(objects.get(key)!),bytes:objects.get(key)!.length,contentType:"application/octet-stream"} : null, delete: async (key: string) => {objects.delete(key);} };
  const app = express(); app.use("/communities", communityAttachmentsRouter({prisma:prisma as any,storage:storage as any,identity:async () => ({onewayId:"@qa",displayName:"QA"}) as any,authenticate:(req,res,next) => {const owner=req.header("x-test-owner");if(!owner){res.status(401).end();return;}(req as any).userId=owner;next();}}));
  const server=app.listen(0,"127.0.0.1");await new Promise<void>(r=>server.on("listening",r));const base=`http://127.0.0.1:${(server.address() as any).port}/communities/${communityId}/attachments`;
  const png=Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+yY7sAAAAASUVORK5CYII=","base64");
  const clientId=randomUUID();
  const form=()=>{const f=new FormData();f.set("file",new Blob([png],{type:"image/png"}),"photo.png");f.set("clientMessageId",clientId);return f;};
  try {
    assert.equal((await fetch(base,{method:"POST",headers:{"x-test-owner":"outsider"},body:form()})).status,403);
    const sent=await fetch(base,{method:"POST",headers:{"x-test-owner":"alice"},body:form()});assert.equal(sent.status,201);const {message}=await sent.json() as any;
    const info=JSON.parse(message.body);assert.equal(info.kind,"photo");assert.equal(objects.get(info.key)!.toString().includes(png.toString("base64")),false);
    assert.equal((await fetch(base,{method:"POST",headers:{"x-test-owner":"alice"},body:form()})).status,200);assert.equal(rows.length,1);assert.equal(objects.size,1);
    const got=await fetch(base+"/"+message.id,{headers:{"x-test-owner":"bob"}});assert.equal(got.status,200);assert.deepEqual(Buffer.from(await got.arrayBuffer()),png);
    members.delete("bob");assert.equal((await fetch(base+"/"+message.id,{headers:{"x-test-owner":"bob"}})).status,403);
    assert.equal((await fetch(base+"/"+message.id)).status,401);
    assert.equal((await fetch(base+"/"+randomUUID(),{headers:{"x-test-owner":"alice"}})).status,404);
    const bad=new FormData();bad.set("file",new Blob(["<html>"],{type:"text/html"}),"bad.html");bad.set("clientMessageId",randomUUID());assert.equal((await fetch(base,{method:"POST",headers:{"x-test-owner":"alice"},body:bad})).status,400);
  }finally{server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));}
});
