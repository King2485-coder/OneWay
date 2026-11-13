import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import express from 'express';
import {PrismaClient} from '@prisma/client';
import {communicationHubRouter} from '../src/routes/communicationHub';
import {mayCommunicate} from '../src/services/AccountVisibility';
const directory=mkdtempSync(join(tmpdir(),'oneway-hub-')),database=`file:${join(directory,'test.db')}`;
const db=new PrismaClient({datasources:{db:{url:database}}});let server:any,base:string;
const community=randomUUID(),message=randomUUID(),shop=randomUUID();
async function request(user:string,path='',method='GET',body?:unknown){return fetch(base+path,{method,headers:{'Content-Type':'application/json',...(user?{'x-test-user':user}:{})},body:body===undefined?undefined:JSON.stringify(body)});}
before(async()=>{
 writeFileSync(join(directory,'test.db'),'');const setup=spawnSync(process.execPath,[resolve('node_modules/prisma/build/index.js'),'db','push','--skip-generate','--schema','prisma/schema.prisma'],{env:{...process.env,DATABASE_URL:database},encoding:'utf8'});assert.equal(setup.status,0,setup.stderr);
 await db.$executeRawUnsafe('CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY,"userId" TEXT,"key" TEXT,"value" TEXT,"updatedAt" DATETIME,UNIQUE("userId","key"))');
 for(const id of ['alice','bob','outsider'])await db.user.create({data:{id,email:id+'@test.invalid',displayName:id}});
 await db.community.create({data:{id:community,ownerId:'alice',name:'Private test room',description:'test',visibility:'private'}});
 for(const userId of ['alice','bob'])await db.communityMember.create({data:{communityId:community,userId,createdAt:new Date(Date.now()-10000)}});
 await db.communityMessage.create({data:{id:message,communityId:community,senderId:'alice',senderHandle:'alice',senderDisplayName:'Alice',body:'SECRET_COMMUNITY_BODY'}});
 await db.shopConversation.create({data:{id:shop,shopId:'test-shop',buyerId:'bob',sellerId:'alice',conversationType:'generalShopQuestion'}});
 await db.shopMessage.create({data:{conversationId:shop,senderId:'alice',recipientId:'bob',senderRole:'seller',bodyEncrypted:'SECRET_SHOP_BODY',clientMessageId:randomUUID()}});
 const app=express();app.use(express.json());app.use('/hub',communicationHubRouter({db,authenticate:(req,res,next)=>{const user=req.header('x-test-user');if(!user){res.status(401).end();return;}(req as any).userId=user;next();}}));server=app.listen(0,'127.0.0.1');await new Promise<void>(r=>server.once('listening',r));base=`http://127.0.0.1:${server.address().port}/hub`;
});
after(async()=>{if(server)await new Promise<void>(r=>server.close(()=>r()));await db.$disconnect();rmSync(directory,{recursive:true,force:true});});
test('authorized inbox scopes providers and does not leak bodies',async()=>{
 assert.equal((await request('','/inbox')).status,401);const response=await request('bob','/inbox');assert.equal(response.headers.get('cache-control'),'no-store');const data=await response.json();assert.deepEqual(data.sourceErrors,[]);assert.equal(data.rows.length,2);assert.doesNotMatch(JSON.stringify(data),/SECRET_/);assert.equal(data.rows.find((r:any)=>r.kind==='community').unreadCount,1);assert.equal((await request('outsider','/inbox').then(r=>r.json())).rows.length,0);
});
test('listing never marks read; watermark requires membership and real message',async()=>{
 assert.equal(await db.communicationHubRead.count(),0);assert.equal((await request('outsider',`/communities/${community}/read`,'POST',{messageId:message})).status,404);assert.equal((await request('bob',`/communities/${community}/read`,'POST',{messageId:message})).status,204);assert.equal((await request('bob','/inbox').then(r=>r.json())).rows.find((r:any)=>r.kind==='community').unreadCount,0);assert.equal((await request('bob',`/communities/${community}/read`,'POST',{messageId:randomUUID()})).status,404);
});
test('banned membership cannot expose or mark community activity',async()=>{
 await db.community.update({where:{id:community},data:{bannedUserIdsJson:'["bob"]'}});assert.ok(!(await request('bob','/inbox').then(r=>r.json())).rows.some((r:any)=>r.kind==='community'));assert.equal((await request('bob',`/communities/${community}/read`,'POST',{messageId:message})).status,404);await db.community.update({where:{id:community},data:{bannedUserIdsJson:'[]'}});
});
test('blocks override messaging, Chirp, calls, video and shop permission',async()=>{
 for(const [userId,contactUserId] of [['alice','bob'],['bob','alice']])await db.oneWayContact.create({data:{userId,contactUserId,status:'connected'}});
 let access=await request('bob','/peers/alice').then(r=>r.json());assert.equal(access.canCall,true);assert.equal(access.canMessage,true);assert.equal(access.security,'LEGACY_NOT_E2EE');
 for(const userId of ['alice','bob'])await db.socialProfile.upsert({where:{userId},create:{userId,handle:userId,displayName:userId},update:{}});
 await db.socialBlock.create({data:{blockerId:'alice',blockedId:'bob'}});access=await request('bob','/peers/alice').then(r=>r.json());for(const key of ['canMessage','canChirp','canCall','canVideo'])assert.equal(access[key],false);assert.equal(await mayCommunicate(db,'alice','bob'),false);assert.equal(await mayCommunicate(db,'bob','alice'),false);assert.equal((await request('bob','/inbox').then(r=>r.json())).rows.find((r:any)=>r.kind==='shop').blocked,true);await db.socialBlock.deleteMany();
});
test('Chirp nobody permission stays off even for connected contacts',async()=>{
 await db.walkiePrivacySettings.upsert({where:{userId:'alice'},create:{userId:'alice',directChirpAudience:'nobody'},update:{directChirpAudience:'nobody'}});const access=await request('bob','/peers/alice').then(r=>r.json());assert.equal(access.canMessage,true);assert.equal(access.canChirp,false);
});
test('Chirp inbox collapses repeated peer activity but preserves incoming requests',async()=>{
 await db.user.update({where:{id:'alice'},data:{chirpId:'ALICE-CHIRP'}});
 for(const [index,status] of ['accepted','pending','accepted'].entries())await db.directChirpRequest.create({data:{senderUserId:'alice',recipientUserId:'bob',senderChirpId:'OLD-NAME',recipientChirpId:'BOB-CHIRP',status,clientRequestId:randomUUID(),expiresAt:new Date(Date.now()+60000),createdAt:new Date(Date.now()+index)}});
 const rows=(await request('bob','/inbox').then(r=>r.json())).rows.filter((r:any)=>r.kind==='chirp');assert.equal(rows.length,1);assert.equal(rows[0].status,'pending');assert.equal(rows[0].unreadCount,1);assert.equal(rows[0].peerHandle,'ALICE-CHIRP');
});
test('failed community provider does not block shop inbox',async()=>{
 await db.$executeRawUnsafe('ALTER TABLE "CommunicationHubRead" RENAME TO "UnavailableHubRead"');try{const data=await request('bob','/inbox').then(r=>r.json());assert.ok(data.sourceErrors.includes('communities'));assert.ok(data.rows.some((r:any)=>r.kind==='shop'));}finally{await db.$executeRawUnsafe('ALTER TABLE "UnavailableHubRead" RENAME TO "CommunicationHubRead"');}
});
