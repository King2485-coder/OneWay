import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import express from 'express';
import { PrismaClient } from '@prisma/client';
import { instantsRouter } from '../src/routes/instants';
process.env.FIELD_ENCRYPTION_ENABLED='true';process.env.FIELD_ENCRYPTION_MASTER_KEY_BASE64=randomBytes(32).toString('base64');
const directory=mkdtempSync(join(tmpdir(),'oneway-instants-')),database=`file:${join(directory,'test.db')}`;
const db=new PrismaClient({datasources:{db:{url:database}}});let server:any,base:string,time=Date.now(),id:string;
const photo=Buffer.from([255,216,255,224,0,16,74,70,73,70,0,1,1,1,0,0,255,217]).toString('base64'),alerts:string[]=[];
const body=(key=randomUUID(),recipients=['bob','charlie'])=>({id:key,photo,caption:'Synthetic test photo',recipients});
async function request(user:string,path='',method='GET',data?:unknown){return fetch(base+path,{method,headers:{'Content-Type':'application/json',...(user?{'x-test-user':user}:{})},body:data===undefined?undefined:JSON.stringify(data)});}
before(async()=>{
 writeFileSync(join(directory,'test.db'),'');
 const setup=spawnSync(process.execPath,[resolve('node_modules/prisma/build/index.js'),'db','push','--skip-generate','--schema','prisma/schema.prisma'],{env:{...process.env,DATABASE_URL:database},encoding:'utf8'});assert.equal(setup.status,0,setup.stderr);
 await db.$executeRawUnsafe('CREATE TABLE "PrivacySetting" ("id" TEXT PRIMARY KEY,"userId" TEXT,"key" TEXT,"value" TEXT,"updatedAt" DATETIME,UNIQUE("userId","key"))');
 for(const user of ['alice','bob','charlie','outsider'])await db.user.create({data:{id:user,displayName:user,email:user+'@test.invalid'}});
 for(const user of ['bob','charlie'])for(const [a,b] of [['alice',user],[user,'alice']])await db.oneWayContact.create({data:{userId:a,contactUserId:b,status:'connected'}});
 const app=express();app.use(express.json({limit:'2mb'}));app.use('/instants',instantsRouter({db,clock:()=>time,alerts:{sendInstant:async(input:any)=>{alerts.push(input.userId);}} as any,authenticate:(req,res,next)=>{const user=req.header('x-test-user');if(!user){res.status(401).end();return;}(req as any).userId=user;next();}}));
 server=app.listen(0,'127.0.0.1');await new Promise<void>(r=>server.once('listening',r));base=`http://127.0.0.1:${server.address().port}/instants`;
});
after(async()=>{await new Promise<void>(r=>server.close(()=>r()));await db.$disconnect();rmSync(directory,{recursive:true,force:true});});
test('authentication, approved contacts and JPEG required; storage encrypted, lists contain no photo',async()=>{
 assert.equal((await request('','','POST',body())).status,401);
 assert.equal((await request('alice','','POST',body(randomUUID(),['outsider']))).status,403);
 assert.equal((await request('alice','','POST',{...body(),photo:Buffer.from('not a photo').toString('base64')})).status,400);
 const input=body();id=input.id;assert.equal((await request('alice','','POST',input)).status,201);
 const rows=await db.$queryRawUnsafe<any[]>('SELECT * FROM "InstantPhoto" WHERE "id"=?',id);assert.doesNotMatch(rows[0].ciphertext,/Synthetic test photo/);assert.notEqual(rows[0].ciphertext,photo);
 const result=await request('bob');assert.equal(result.headers.get('cache-control'),'private, no-store, max-age=0');const list=await result.json();assert.equal(list.incoming.length,1);assert.equal(list.incoming[0].photo,undefined);assert.equal(list.incoming[0].caption,undefined);
 assert.equal((await request('alice','','POST',input)).status,200);assert.equal(alerts.length,2);assert.equal((await request('alice','','POST',{...input,caption:'changed'})).status,409);
});
test('one opening per recipient; sender and outsiders cannot use the open endpoint',async()=>{
 for(const user of ['alice','outsider'])assert.equal((await request(user,'/'+id+'/open','POST')).status,404);
 const first=await request('bob','/'+id+'/open','POST');assert.equal(first.status,200);assert.equal((await first.json()).photo,photo);assert.equal((await request('bob','/'+id+'/open','POST')).status,410);
 assert.equal((await request('bob').then(r=>r.json())).incoming[0].opened,true);
 assert.equal((await request('charlie','/'+id+'/open','POST')).status,200);
 const rows=await db.$queryRawUnsafe<any[]>('SELECT "ciphertext" FROM "InstantPhoto" WHERE "id"=?',id);assert.equal(rows[0].ciphertext,null);assert.equal((await request('alice').then(r=>r.json())).sent[0].openedCount,2);
});
test('simultaneous opens never return photo twice',async()=>{
 const input=body(randomUUID(),['bob']);assert.equal((await request('alice','','POST',input)).status,201);
 const results=await Promise.all([request('bob','/'+input.id+'/open','POST'),request('bob','/'+input.id+'/open','POST')]);assert.equal(results.filter(r=>r.status===200).length,1);
});
test('sender-only unsend and contact block revoke access',async()=>{
 const input=body(randomUUID(),['bob']);assert.equal((await request('alice','','POST',input)).status,201);assert.equal((await request('bob','/'+input.id,'DELETE')).status,404);
 await db.oneWayContact.updateMany({where:{userId:'bob',contactUserId:'alice'},data:{status:'blocked'}});assert.equal((await request('bob','/'+input.id+'/open','POST')).status,404);assert.deepEqual((await request('bob').then(r=>r.json())).incoming,[]);
 await db.oneWayContact.updateMany({where:{userId:'bob',contactUserId:'alice'},data:{status:'connected'}});assert.equal((await request('alice','/'+input.id,'DELETE')).status,204);assert.equal((await request('bob','/'+input.id+'/open','POST')).status,404);
});
test('expiry and deactivated sender remove access and stored photo',async()=>{
 const input=body(randomUUID(),['bob']);assert.equal((await request('alice','','POST',input)).status,201);time+=24*60*60*1000;assert.equal((await request('bob','/'+input.id+'/open','POST')).status,404);
 assert.equal((await db.$queryRawUnsafe<any[]>('SELECT * FROM "InstantPhoto"')).length,0);
 const next=body(randomUUID(),['bob']);assert.equal((await request('alice','','POST',next)).status,201);await db.user.update({where:{id:'alice'},data:{accountStatus:'deleted'}});assert.equal((await request('bob','/'+next.id+'/open','POST')).status,404);assert.equal((await request('alice')).status,401);
});
