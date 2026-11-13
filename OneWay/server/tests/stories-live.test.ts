import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomBytes,randomUUID} from 'node:crypto';
import {Readable} from 'node:stream';
import express from 'express';
import {PrismaClient} from '@prisma/client';
import {storiesRouter} from '../src/routes/stories';
import {LiveKitTokenService} from '../src/services/LiveKitTokenService';
process.env.FIELD_ENCRYPTION_ENABLED='true';process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64=randomBytes(32).toString('base64');
const directory=mkdtempSync(join(tmpdir(),'oneway-stories-')),database=`file:${join(directory,'test.db')}`;
const db=new PrismaClient({datasources:{db:{url:database}}});let server:any,base:string,time=Date.now();
const objects=new Map<string,Buffer>(),issued:any[]=[],deleted:string[]=[],removed:string[]=[];
const photo=Buffer.from([255,216,255,224,0,16,74,70,73,70,0,1,1,1,0,0,255,217]);
const video=Buffer.from([0,0,0,24,102,116,121,112,105,115,111,109,0,0,0,0,105,115,111,109,0,0,0,0]);
const storage={put:async(key:string,bytes:Buffer)=>{objects.set(key,bytes);return{key,bytes:bytes.length};},read:async(key:string)=>objects.has(key)?{stream:Readable.from(objects.get(key)!),bytes:objects.get(key)!.length,contentType:'application/octet-stream'}:null,delete:async(key:string)=>{objects.delete(key);}} as any;
const tokens={isConfigured:()=>true,issue:async(args:any)=>{issued.push(args);return{url:'wss://live.test.invalid',liveKitUrl:'wss://live.test.invalid',token:'synthetic-test-token',roomName:args.roomName,participantIdentity:args.identity};},deleteRoom:async(room:string)=>{deleted.push(room);},removeParticipant:async(_room:string,identity:string)=>{removed.push(identity);}};
async function request(user:string,path='',method='GET',body?:unknown){return fetch(base+path,{method,headers:{...(user?{'x-test-user':user}:{}),...(body instanceof FormData?{}:{'Content-Type':'application/json'})},body:body===undefined?undefined:body instanceof FormData?body:JSON.stringify(body)});}
function story(scope='friends',bytes:Buffer|null=photo,mime='image/jpeg'){
 const form=new FormData();form.set('id',randomUUID());form.set('caption','Synthetic private Story');form.set('visibility',scope);if(bytes)form.set('file',new Blob([bytes],{type:mime}),'story');return form;
}
async function ghost(on:boolean){await db.$executeRawUnsafe(`INSERT INTO "PrivacySetting" ("id","userId","key","value","updatedAt") VALUES (?,'alice','account.ghostMode',?,CURRENT_TIMESTAMP) ON CONFLICT("userId","key") DO UPDATE SET "value"=excluded."value"`,randomUUID(),String(on));}
before(async()=>{
 writeFileSync(join(directory,'test.db'),'');const setup=spawnSync(process.execPath,[resolve('node_modules/prisma/build/index.js'),'db','push','--skip-generate','--schema','prisma/schema.prisma'],{env:{...process.env,DATABASE_URL:database},encoding:'utf8'});assert.equal(setup.status,0,setup.stderr);
 await db.$executeRawUnsafe('CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY,"userId" TEXT,"key" TEXT,"value" TEXT,"updatedAt" DATETIME,UNIQUE("userId","key"))');
 for(const user of ['alice','bob','outsider'])await db.user.create({data:{id:user,displayName:user,email:user+'@test.invalid'}});
 for(const [a,b] of [['alice','bob'],['bob','alice']])await db.oneWayContact.create({data:{userId:a,contactUserId:b,status:'connected'}});
 await db.socialProfile.create({data:{userId:'alice',handle:'alice_test',displayName:'Alice test',discoverable:true}});
 const app=express();app.use(express.json());app.use('/stories',storiesRouter({db,tokens,storage,clock:()=>time,authenticate:(req,res,next)=>{const user=req.header('x-test-user');if(!user){res.status(401).end();return;}(req as any).userId=user;next();}}));
 server=app.listen(0,'127.0.0.1');await new Promise<void>(r=>server.once('listening',r));base=`http://127.0.0.1:${server.address().port}/stories`;
});
after(async()=>{await new Promise<void>(r=>server.close(()=>r()));await db.$disconnect();rmSync(directory,{recursive:true,force:true});});
test('Stories require auth, encrypt content and respect selected audience on every read',async()=>{
 assert.equal((await request('')).status,401);
 const form=story(),response=await request('alice','','POST',form);assert.equal(response.status,201);const saved=await response.json();assert.equal(saved.mediaType,'photo');assert.equal(saved.caption,'');
 assert.equal((await request('alice','','POST',form)).status,200);
 assert.equal((await request('bob','/'+saved.id+'/content')).status,200);assert.equal((await request('outsider','/'+saved.id+'/content')).status,404);
 assert.equal((await request('outsider').then(r=>r.json())).stories.length,0);
 assert.doesNotMatch([...objects.values()][0].toString(),/Synthetic private Story/);
 assert.equal((await request('bob','/'+saved.id,'DELETE')).status,404);
 assert.equal((await request('alice','/'+saved.id,'DELETE')).status,204);assert.equal(objects.size,0);
});
test('Ghost mode, Only me and blocks govern Stories; short video bytes are stored privately',async()=>{
 const publicStory=await request('alice','','POST',story('everyone')).then(r=>r.json());assert.equal((await request('outsider','/'+publicStory.id+'/content')).status,200);
 await ghost(true);assert.equal((await request('outsider','/'+publicStory.id+'/content')).status,404);assert.equal((await request('alice','','POST',story('everyone'))).status,403);
 const privateStory=await request('alice','','POST',story('onlyMe',null)).then(r=>r.json());assert.equal((await request('bob','/'+privateStory.id+'/content')).status,404);assert.equal((await request('alice','/'+privateStory.id+'/content')).status,200);
 const clip=await request('alice','','POST',story('friends',video,'video/mp4')).then(r=>r.json());assert.equal(clip.mediaType,'video');const content=await request('bob','/'+clip.id+'/content').then(r=>r.json());assert.equal(content.media.payloadBase64,video.toString('base64'));
 await db.oneWayContact.updateMany({where:{userId:'bob',contactUserId:'alice'},data:{status:'blocked'}});assert.equal((await request('bob','/'+clip.id+'/content')).status,404);
 await db.oneWayContact.updateMany({where:{userId:'bob',contactUserId:'alice'},data:{status:'connected'}});await ghost(false);
 time+=86400001;assert.equal((await request('bob','/'+clip.id+'/content')).status,404);assert.equal(objects.size,0);
});
test('live host is owner-only, viewers are subscribe-only and unknown users cannot join Contacts streams',async()=>{
 const input={id:randomUUID(),title:'Synthetic live stream',visibility:'friends'};assert.equal((await request('alice','/live','POST',input)).status,201);
 assert.equal((await request('bob','/live/'+input.id+'/join','POST')).status,404);
 const host=await request('alice','/live/'+input.id+'/join','POST');assert.equal(host.status,200);assert.equal(issued.at(-1).canPublish,true);assert.equal(issued.at(-1).canPublishData,false);
 assert.equal((await request('bob','/live/'+input.id+'/heartbeat','POST')).status,404);
 assert.equal((await request('alice','/live/'+input.id+'/heartbeat','POST')).status,200);
 assert.equal((await request('outsider','/live/'+input.id+'/join','POST')).status,404);
 assert.equal((await request('bob','/live/'+input.id+'/join','POST')).status,200);assert.equal(issued.at(-1).canPublish,false);assert.equal(issued.at(-1).canPublishData,false);assert.equal(issued.at(-1).ttlSeconds,30);assert.doesNotMatch(issued.at(-1).identity,/bob/);assert.equal(issued.at(-1).displayName,'Viewer');
 assert.equal((await request('bob','/live/'+input.id+'/end','POST')).status,404);assert.equal((await request('alice','/live/'+input.id+'/end','POST')).status,200);assert.ok(deleted.includes('oneway-live-'+input.id));assert.equal((await request('bob','/live/'+input.id+'/join','POST')).status,404);
});
test('active host uniqueness, heartbeat expiry and public Ghost changes close access',async()=>{
 const first={id:randomUUID(),title:'First',visibility:'friends'};assert.equal((await request('alice','/live','POST',first)).status,201);assert.equal((await request('alice','/live','POST',{...first,id:randomUUID()})).status,409);
 time+=61000;assert.equal((await request('alice','/live/'+first.id)).status,404);assert.ok(deleted.includes('oneway-live-'+first.id));
 const pub={id:randomUUID(),title:'Public test',visibility:'everyone'};assert.equal((await request('alice','/live','POST',pub)).status,201);await request('alice','/live/'+pub.id+'/heartbeat','POST');assert.equal((await request('outsider','/live/'+pub.id+'/join','POST')).status,200);
 await ghost(true);assert.equal((await request('outsider','/live/'+pub.id)).status,404);assert.equal((await request('alice','/live/'+pub.id+'/heartbeat','POST')).status,404);assert.ok(deleted.includes('oneway-live-'+pub.id));await ghost(false);
});
test('actual token builder honors viewer restrictions without changing default call grants',async()=>{
 const service=new LiveKitTokenService('wss://live.test.invalid','test-key','test-only-secret-not-a-production-key');
 const viewer=await service.issue({roomName:'test-room',identity:'test-viewer',canPublish:false,canPublishData:false,ttlSeconds:30});
 const payload=JSON.parse(Buffer.from(viewer.token.split('.')[1],'base64url').toString());assert.equal(payload.video.canPublish,false);assert.equal(payload.video.canPublishData,false);
 const call=await service.issue({roomName:'call-room',identity:'test-caller'});const original=JSON.parse(Buffer.from(call.token.split('.')[1],'base64url').toString());assert.equal(original.video.canPublish,true);assert.equal(original.video.canPublishData,true);
});
test('viewers can report and block a Story account through the existing safety audit',async()=>{
 const saved=await request('alice','','POST',story('everyone')).then(r=>r.json());
 assert.equal((await request('outsider','/story/'+saved.id+'/report','POST',{reason:'spam'})).status,201);
 assert.equal((await request('outsider','/story/'+saved.id+'/block','POST')).status,200);
 assert.equal((await request('outsider','/'+saved.id+'/content')).status,404);
 assert.equal((await request('alice','/mine','DELETE')).status,204);
});
