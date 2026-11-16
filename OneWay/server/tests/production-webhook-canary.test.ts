import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import express from 'express';
import Stripe from 'stripe';
const dir=mkdtempSync(join(tmpdir(),'oneway-webhook-canary-')),owner=randomUUID();
process.env.DATABASE_URL='file:'+join(dir,'test.db');process.env.NODE_ENV='test';process.env.STRIPE_ENV='test';
process.env.STRIPE_SECRET_KEY='sk_test_NONWORKING_LOCAL_FIXTURE';process.env.STRIPE_WEBHOOK_SECRET='whsec_LOCAL_CANARY_FIXTURE';
const stripe=new Stripe(process.env.STRIPE_SECRET_KEY);
let db:any,server:ReturnType<express.Express['listen']>,base:string;
before(async()=>{
 writeFileSync(join(dir,'test.db'),'');const setup=spawnSync(process.execPath,[resolve('node_modules/prisma/build/index.js'),'db','push','--skip-generate','--schema','prisma/schema.prisma'],{env:process.env,encoding:'utf8'});assert.equal(setup.status,0,setup.stderr);
 db=(await import('../src/lib/db')).prisma;await db.user.create({data:{id:owner,email:owner+'@test.invalid',passwordHash:'fixture',displayName:'Synthetic canary user'}});
 const {stripeWebhooksRouter}=await import('../src/routes/stripeWebhooks');const app=express();app.use(express.raw({type:'application/json'}));app.use(stripeWebhooksRouter({prisma:db}));server=app.listen(0,'127.0.0.1');await new Promise<void>(r=>server.once('listening',r));base='http://127.0.0.1:'+(server.address()as any).port;
});
after(async()=>{server?.closeAllConnections();if(server)await new Promise<void>(r=>server.close(()=>r()));await db?.$disconnect();rmSync(dir,{recursive:true,force:true});});
function event(orderId:string,type='payment_intent.succeeded'){return{id:'evt_'+randomUUID(),livemode:false,type,data:{object:{id:'pi_'+randomUUID(),amount_received:500,currency:'usd',metadata:{orderId}}}};}
async function deliver(value:any,valid=true){const payload=JSON.stringify(value),signature=valid?stripe.webhooks.generateTestHeaderString({payload,secret:process.env.STRIPE_WEBHOOK_SECRET!}):'t=1,v1=invalid';const r=await fetch(base,{method:'POST',headers:{'content-type':'application/json','stripe-signature':signature},body:payload});return{status:r.status,data:await r.json()as any};}
test('signature rejection, durable failure retry, one event and one order on replay',async()=>{
 const id=randomUUID(),e=event(id);assert.equal((await deliver(e,false)).status,400);
 assert.equal((await deliver(e)).status,500);
 await db.order.create({data:{id,userId:owner,total:5,customerTotalMinor:500,currency:'USD',paymentStatus:'pending_payment',status:'pending_payment'}});
 assert.equal((await deliver(e)).status,200);assert.equal((await db.order.findUniqueOrThrow({where:{id}})).paymentStatus,'paid');
 assert.equal((await deliver(e)).data.duplicate,true);
 await db.$executeRawUnsafe("UPDATE StripeWebhookEvent SET status='RECEIVED',updatedAt=CURRENT_TIMESTAMP WHERE stripeEventId=?",e.id);
 assert.equal((await deliver(e)).status,503);
 await db.$executeRawUnsafe("UPDATE StripeWebhookEvent SET updatedAt=datetime('now','-6 minutes') WHERE stripeEventId=?",e.id);
 assert.equal((await deliver(e)).status,200);
 assert.equal(Number((await db.$queryRawUnsafe('SELECT COUNT(*) n FROM StripeWebhookEvent WHERE stripeEventId=?',e.id))[0].n),1);
});
test('late failed, processing and unpaid checkout events cannot downgrade paid order or Wallet payment',async()=>{
 const id=randomUUID();await db.order.create({data:{id,userId:owner,total:5,customerTotalMinor:500,currency:'USD',paymentStatus:'paid',status:'paid'}});
 await db.$executeRawUnsafe('INSERT INTO ShopPayment (id,orderId,buyerId,amountMinor,currency,status) VALUES (?,?,?,?,?,?)',randomUUID(),id,owner,500,'USD','SUCCEEDED');
 for(const type of ['payment_intent.payment_failed','payment_intent.processing','checkout.session.completed']){assert.equal((await deliver(event(id,type))).status,200);assert.equal((await db.order.findUniqueOrThrow({where:{id}})).paymentStatus,'paid');assert.equal((await db.$queryRawUnsafe('SELECT status FROM ShopPayment WHERE orderId=?',id))[0].status,'SUCCEEDED');}
 await db.order.update({where:{id},data:{paymentStatus:'refunded',refundedAmountMinor:500,status:'refunded'}});
 assert.equal((await deliver(event(id))).status,200);assert.equal((await db.order.findUniqueOrThrow({where:{id}})).paymentStatus,'refunded');
});
