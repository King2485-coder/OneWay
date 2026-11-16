import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import express from 'express';
import {protectedDefaults,protectedConversationsRouter} from '../src/routes/protectedConversations';
const dir=mkdtempSync(join(tmpdir(),'oneway-protected-'));
writeFileSync(join(dir,'test.db'),'');process.env.DATABASE_URL='file:'+join(dir,'test.db');process.env.NODE_ENV='test';
let db:any,server:ReturnType<express.Express['listen']>,base:string;
const users=[randomUUID(),randomUUID(),randomUUID()],conversation=randomUUID(),group=randomUUID(),community=randomUUID(),shop=randomUUID(),notices:any[]=[];
before(async()=>{
 const result=spawnSync(process.execPath,[resolve('node_modules/prisma/build/index.js'),'db','push','--skip-generate','--schema','prisma/schema.prisma'],{env:process.env,encoding:'utf8'});assert.equal(result.status,0,result.stderr);
 db=(await import('../src/lib/db')).prisma;
 for(const id of users)await db.user.create({data:{id,email:id+'@test.invalid',passwordHash:'qa',displayName:'Synthetic QA'}});
 await db.conversation.create({data:{id:conversation,type:'direct',participants:{create:users.slice(0,2).map(userId=>({userId}))}}});
 await db.conversation.create({data:{id:group,type:'group',participants:{create:users.map(userId=>({userId}))}}});
 await db.community.create({data:{id:community,ownerId:users[0],name:'QA',description:'QA',members:{create:users.slice(0,2).map(userId=>({userId}))}}});
 await db.shopConversation.create({data:{id:shop,shopId:randomUUID(),buyerId:users[0],sellerId:users[1],conversationType:'general'}});
 const app=express();app.use(express.json());app.use(protectedConversationsRouter({db,authenticate:(req,_res,next)=>{(req as any).userId=req.header('x-qa-user');next();},notify:async(userId,eventId)=>{notices.push({userId,eventId});}}));
 server=app.listen(0,'127.0.0.1');await new Promise<void>(r=>server.once('listening',r));base=`http://127.0.0.1:${(server.address() as any).port}`;
});
after(async()=>{if(server){server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));}await db?.$disconnect();rmSync(dir,{recursive:true,force:true});});
async function call(user:number,path:string,method='GET',body?:unknown,extra={}){const r=await fetch(base+path,{method,headers:{...(user>=0?{'x-qa-user':users[user]}:{}),'content-type':'application/json',...extra},body:body===undefined?undefined:JSON.stringify(body)});return{status:r.status,data:await r.json().catch(()=>null),cache:r.headers.get('cache-control')};}
const scope=(kind='conversation',id=conversation)=>`/scopes/${kind}/${id}/events`;
const event=()=>({eventId:randomUUID(),eventType:'SCREENSHOT_DETECTED'});
async function save(user:number,settings:Record<string,boolean>,overrides:any[]=[]){const prior=await call(user,'/preferences');return call(user,'/preferences','PUT',{expectedVersion:prior.data.version,settings:{...protectedDefaults,...settings},overrides});}

test('defaults ON, watermark OFF, authenticated account isolation and no-store',async()=>{
 assert.equal((await call(-1,'/preferences')).status,401);
 const a=await call(0,'/preferences');assert.deepEqual(a.data.settings,protectedDefaults);assert.equal(a.cache,'private, no-store');
 assert.equal((await save(0,{enabled:false})).status,200);
 assert.equal((await call(1,'/preferences')).data.settings.enabled,true);
 assert.equal((await call(0,'/preferences','GET',undefined,{'x-oneway-expected-user':users[1]})).status,409);
 const old=await call(0,'/preferences');assert.equal((await save(0,{enabled:true})).status,200);
 assert.equal((await call(0,'/preferences','PUT',{...old.data,expectedVersion:old.data.version})).status,400);
 assert.equal((await call(0,'/preferences','PUT',{expectedVersion:old.data.version,settings:protectedDefaults,overrides:[]})).status,409);
});
test('minimal screenshot event, generic notice, server clock and idempotent peer alias',async()=>{
 const e=event(),before=Date.now(),created=await call(0,scope(),'POST',e);assert.equal(created.status,201,JSON.stringify(created.data));assert.equal(created.data.notifiedParticipants,1);
 const duplicate=await call(0,scope('peer',users[1]),'POST',e);assert.equal(duplicate.data.duplicate,true);assert.equal(notices.length,1);
 const received=(await call(1,scope())).data.events[0];assert.equal(received.message,'A screenshot was detected in this conversation.');assert.equal(received.isMine,false);assert.ok(Date.parse(received.createdAt)>=before);
 for(const key of ['actorUserId','reporterUserId','deviceId','plaintext','body'])assert.equal(key in received,false);
 assert.equal((await call(2,scope())).status,404);assert.equal((await call(2,scope(),'POST',event())).status,404);
 assert.equal((await call(0,scope(),'POST',{...event(),plaintext:'PRIVATE'})).status,400);
 assert.equal((await call(0,scope(),'POST',{...event(),actorUserId:users[1]})).status,400);
});
test('master off, conversation off, preserved subsettings and authorized overrides',async()=>{
 assert.equal((await save(0,{enabled:false,screenshotAlerts:false})).status,200);
 assert.equal((await call(0,scope(),'POST',event())).status,409);
 assert.equal((await call(0,'/preferences')).data.settings.screenshotDetection,true);
 assert.equal((await save(0,{enabled:true},[{kind:'conversation',id:conversation,value:'off'}])).status,200);
 assert.equal((await call(0,scope(),'POST',event())).status,409);
 assert.equal((await save(2,{},[{kind:'conversation',id:conversation,value:'off'}])).status,404);
 await save(0,{});
});
test('private event when sharing disabled; recipient opt out and blocks respected',async()=>{
 await save(0,{notifyParticipants:false});const e=event();assert.equal((await call(0,scope(),'POST',e)).status,201);
 assert.equal((await call(1,scope())).data.events.some((x:any)=>x.eventId===e.eventId),false);
 await save(0,{});await save(1,{screenshotAlerts:false});const count=notices.length;await call(0,scope(),'POST',event());assert.equal(notices.length,count);assert.deepEqual((await call(1,scope())).data.events,[]);
 await save(1,{});await db.oneWayContact.create({data:{userId:users[1],contactUserId:users[0],status:'blocked'}});
 await call(0,scope(),'POST',event());assert.equal(notices.length,count);assert.deepEqual((await call(1,scope())).data.events,[]);
 await db.oneWayContact.deleteMany();
});
test('group, shop, private community membership and removed-member access',async()=>{
 for(const [kind,id] of [['conversation',group],['shop',shop],['community',community]])assert.equal((await call(0,scope(kind,id),'POST',event())).status,201);
 assert.equal((await call(2,scope('shop',shop))).status,404);assert.equal((await call(2,scope('community',community))).status,404);
 await save(1,{},[{kind:'community',id:community,value:'off'}]);
 await db.communityMember.deleteMany({where:{communityId:community,userId:users[1]}});assert.equal((await call(1,scope('community',community))).status,404);
 const saved=await save(1,{enabled:false},[{kind:'community',id:community,value:'off'}]);assert.equal(saved.status,200);assert.deepEqual(saved.data.overrides,[]);await save(1,{});
});
test('seven-day retention and rate limit bound minimal event history',async()=>{
 const expired=randomUUID();await db.$executeRawUnsafe('INSERT INTO "ConversationPrivacyEvent" VALUES (?,?,?,?,?,?,?)',expired,'conversation:'+conversation,users[0],'SCREENSHOT_DETECTED',Date.now()-8*86400000,Date.now()-1,1);
 assert.equal((await call(1,scope())).data.events.some((x:any)=>x.eventId===expired),false);
 assert.equal(Number((await db.$queryRawUnsafe('SELECT COUNT(*) n FROM "ConversationPrivacyEvent" WHERE "eventId"=?',expired))[0].n),0);
 let limited=false;for(let i=0;i<15;i++){const r=await call(0,scope(),'POST',event());if(r.status===429){limited=true;break;}assert.equal(r.status,201);}assert.equal(limited,true);
});
