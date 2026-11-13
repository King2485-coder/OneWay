import test,{before,after} from "node:test";
import assert from "node:assert/strict";
import {mkdtempSync,rmSync,writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join,resolve} from "node:path";
import {spawnSync} from "node:child_process";
import {randomUUID} from "node:crypto";
import express from "express";
const dir=mkdtempSync(join(tmpdir(),"oneway-chirp-consent-"));
writeFileSync(join(dir,"test.db"), "");
process.env.DATABASE_URL="file:"+join(dir,"test.db");process.env.JWT_AUTH_REQUIRED="false";process.env.NODE_ENV="test";
let db:any,server:ReturnType<express.Express["listen"]>,base:string;const users=[randomUUID(),randomUUID(),randomUUID()];const notifications:any[]=[];
before(async()=>{
 const setup=spawnSync(process.execPath,[resolve("node_modules/prisma/build/index.js"),"db","push","--skip-generate","--schema","prisma/schema.prisma"],{env:process.env,encoding:"utf8"});assert.equal(setup.status,0,setup.stderr);
 db=(await import("../src/lib/db")).prisma;
 await db.$executeRawUnsafe('CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY,"userId" TEXT,"key" TEXT,"value" TEXT,"updatedAt" DATETIME,UNIQUE("userId","key"))');
 const {walkieRouter,ensureDirectChirpTables}=await import("../src/routes/walkie");await ensureDirectChirpTables(db);
 for(let i=0;i<users.length;i++){await db.user.create({data:{id:users[i],email:users[i]+"@test.invalid",passwordHash:"qa",displayName:"QA"}});await db.oneWayIdentity.create({data:{userId:users[i],onewayId:"@chirp_"+i,emailAlias:users[i]+"@test.invalid",displayName:"QA "+i}});}
 for(const recipient of users.slice(1))for(const [a,b] of [[users[0],recipient],[recipient,users[0]]])await db.oneWayContact.create({data:{userId:a,contactUserId:b,status:"connected"}});
 const app=express();app.use(express.json());const routes=walkieRouter({prisma:db,tokens:{isConfigured:()=>true,issue:async()=>({token:"synthetic-test-token",url:"wss://example.invalid",expiresAt:new Date(Date.now()+60000).toISOString()})} as any,alerts:{sendChirpInvitation:async value=>{notifications.push(value);}}});app.use("/walkie",routes);app.use("/chirp",routes);app.use((e:any,_q:any,r:any,_n:any)=>r.status(500).json({error:e.message}));server=app.listen(0,"127.0.0.1");await new Promise<void>(r=>server.once("listening",r));base=`http://127.0.0.1:${(server.address() as any).port}`;
});
after(async()=>{if(server){server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));}await db?.$disconnect();rmSync(dir,{recursive:true,force:true});});
async function call(i:number,path:string,method="GET",body?:unknown){const r=await fetch(base+path,{method,headers:{"X-Dev-User-Id":users[i],"Content-Type":"application/json"},body:body===undefined?undefined:JSON.stringify(body)});const t=await r.text();return{status:r.status,data:t?JSON.parse(t):null};}
const invite=()=>call(0,"/chirp/direct/request","POST",{recipientChirpId:"@chirp_1",clientRequestId:randomUUID(),mode:"private"});
test("Chirp requires invitation, explicit acceptance and connected participants before transmission",async()=>{
 assert.equal((await call(0,"/walkie/sessions","POST",{target:"@chirp_1"})).status,409);
 const pending=await invite();assert.equal(pending.status,201,JSON.stringify(pending.data));const request=pending.data.request.id;
 assert.equal((await call(1,"/chirp/direct/incoming")).data.requests[0].id,request);
 assert.equal((await invite()).data.request.id,request);assert.equal(notifications.length,1);
 assert.equal((await call(2,"/chirp/direct/"+request)).status,404);
 assert.equal((await call(0,"/chirp/direct/"+request+"/accept","POST",{})).status,403);
 assert.equal((await call(1,"/chirp/direct/"+request+"/decline","POST",{})).status,200);
 assert.equal((await call(0,"/chirp/direct/"+request)).data.request.status,"declined");
 const next=(await invite()).data.request.id;const accepted=await call(1,"/chirp/direct/"+next+"/accept","POST",{});assert.equal(accepted.status,200);const session=accepted.data.session;
 assert.equal((await call(1,`/walkie/sessions/${session.sessionId}/transmit/start`,"POST",{})).status,409);
 assert.equal((await call(0,`/walkie/sessions/${session.sessionId}/join`,"POST",{})).status,409);
 assert.equal((await call(0,`/walkie/sessions/${session.sessionId}/join`,"POST",{acceptInvitation:true})).status,200);
 assert.equal((await call(0,`/walkie/sessions/${session.sessionId}/transmit/start`,"POST",{})).status,200);
 await call(0,`/walkie/sessions/${session.sessionId}/transmit/end`,"POST",{});
 const again=await call(1,"/chirp/direct/"+next+"/accept","POST",{});assert.equal(again.data.session.sessionId,session.sessionId);
 await call(0,`/walkie/sessions/${session.sessionId}/end`,"POST",{});
 assert.equal((await call(1,"/chirp/direct/"+next+"/accept","POST",{})).status,410);
 const fresh=(await invite()).data.request.id;const freshAccepted=await call(1,"/chirp/direct/"+fresh+"/accept","POST",{});assert.notEqual(freshAccepted.data.session.roomName,session.roomName);
 await call(0,`/walkie/sessions/${freshAccepted.data.session.sessionId}/end`,"POST",{});
 const expired=(await invite()).data.request.id;await db.$executeRawUnsafe(`UPDATE "DirectChirpRequest" SET "expiresAt" = datetime('now','-1 minute') WHERE "id"=?`,expired);
 assert.equal((await call(1,"/chirp/direct/incoming")).data.requests.length,0);
 assert.equal((await call(1,"/chirp/direct/"+expired+"/accept","POST",{})).status,409);
});

test("group invitations stay visible until explicit join and require a listener before transmission",async()=>{
 const started=await call(0,"/walkie/sessions","POST",{targets:["@chirp_1","@chirp_2"],groupName:"QA group"});assert.equal(started.status,201,JSON.stringify(started.data));const session=started.data.sessionId;
 const incoming=(await call(1,"/walkie/channels")).data.channels.find((c:any)=>c.sessionId===session);assert.equal(incoming.isIncoming,true);
 assert.equal((await call(0,`/walkie/sessions/${session}/transmit/start`,"POST",{})).status,409);
 assert.equal((await call(1,`/walkie/sessions/${session}/join`,"POST",{})).status,409);
 assert.equal((await call(1,`/walkie/sessions/${session}/join`,"POST",{acceptInvitation:true})).status,200);
 assert.equal((await call(1,"/walkie/channels")).data.channels.find((c:any)=>c.sessionId===session).isIncoming,false);
 assert.equal((await call(0,`/walkie/sessions/${session}/transmit/start`,"POST",{})).status,200);
 await call(0,`/walkie/sessions/${session}/end`,"POST",{});
});
