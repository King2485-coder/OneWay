import test from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { PrismaClient } from "@prisma/client";
import { cloudMediaRouter } from "../src/routes/cloudMedia";

test("profile cloud selection survives router recreation and cannot reference another account's media", async () => {
  const dir=await mkdtemp(join(tmpdir(),"oneway-cloud-profile-"));
  const prisma=new PrismaClient({datasources:{db:{url:`file:${join(dir,"test.db")}`}}});
  let server: ReturnType<express.Express["listen"]> | undefined;
  const fileId="11111111-1111-4111-8111-111111111111";
  const start=async()=>{const app=express();app.use(express.json());app.use(cloudMediaRouter({prisma,storage:null,authenticate:(req,res,next)=>{(req as any).userId=req.header("x-test-owner")??"bob";next();}}));server=app.listen(0,"127.0.0.1");await new Promise<void>(r=>server!.on("listening",r));return `http://127.0.0.1:${(server!.address() as any).port}`;};
  const stop=async()=>{if(server){server.closeAllConnections();await new Promise<void>(r=>server!.close(()=>r()));server=undefined;}};
  try {
    await prisma.$executeRawUnsafe('CREATE TABLE "CloudFile" ("id" TEXT PRIMARY KEY, "ownerId" TEXT, "name" TEXT, "mimeType" TEXT, "byteCount" INTEGER, "storageKey" TEXT, "encrypted" BOOLEAN, "createdAt" DATETIME, "updatedAt" DATETIME)');
    await prisma.$executeRawUnsafe('CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY, "userId" TEXT, "key" TEXT, "value" TEXT, "updatedAt" DATETIME NOT NULL, UNIQUE("userId","key"))');
    await prisma.$executeRawUnsafe('INSERT INTO "CloudFile" VALUES (?, ?, ?, ?, ?, ?, true, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)',fileId,"alice","profile.png","image/png",64,`private-media/${createHash("sha256").update("alice").digest("hex")}/${fileId}`);
    let base=await start();
    const result=await fetch(base+"/profile-photo",{method:"POST",headers:{"x-test-owner":"alice","Content-Type":"application/json"},body:JSON.stringify({fileId})});assert.equal(result.status,204);
    await stop();base=await start();
    const own=await fetch(base+"/profile-photo",{headers:{"x-test-owner":"alice"}});assert.equal((await own.json() as any).file.id,fileId);
    const other=await fetch(base+"/profile-photo",{headers:{"x-test-owner":"bob"}});assert.equal((await other.json() as any).file,null);
    const claim=await fetch(base+"/profile-photo",{method:"POST",headers:{"x-test-owner":"bob","Content-Type":"application/json"},body:JSON.stringify({fileId})});assert.equal(claim.status,404);
  } finally {await stop();await prisma.$disconnect();await rm(dir,{recursive:true,force:true});}
});
