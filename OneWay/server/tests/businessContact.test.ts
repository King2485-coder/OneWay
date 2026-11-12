import assert from 'node:assert/strict';
import {test,before,after} from 'node:test';
import {PrismaClient} from '@prisma/client';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID,randomBytes,createHmac} from 'node:crypto';
import {Type,Environment} from '@apple/app-store-server-library';
import {assignInitialFreeNumbers,allocateInternalNumber} from '../src/services/numbers';
import {BUSINESS_CONTACT_PRODUCT_ID,hasBusinessContactPlan} from '../src/services/billing/OneWayBusinessContactPlan';
import {applyBusinessTransaction,verifyAppleTransaction,ApplePurchaseError} from '../src/services/billing/AppleBusinessSubscription';
import {OneWayMailboxService} from '../src/services/email/OneWayMailboxService';
const dir=mkdtempSync(join(tmpdir(),'oneway-business-test-')),url='file:'+join(dir,'test.db');
const db=new PrismaClient({datasources:{db:{url}}}),sent:any[]=[];
const provider={name:'mailgun',sendOutboundMessage:async(input:any)=>{sent.push(input);return {status:'queued',providerMessageId:randomUUID()}}} as any;
const service=new OneWayMailboxService(db,{} as any,provider),a=randomUUID(),b=randomUUID();
before(async()=>{
 writeFileSync(join(dir,'test.db'),'');const r=spawnSync(process.execPath,[resolve('node_modules/prisma/build/index.js'),'db','push','--skip-generate','--schema','prisma/schema.prisma'],{env:{...process.env,DATABASE_URL:url},encoding:'utf8'});assert.equal(r.status,0,r.stderr);
 Object.assign(process.env,{FIELD_ENCRYPTION_ENABLED:'true',FIELD_ENCRYPTION_KEY_ID:'business-test',FIELD_ENCRYPTION_KEYS_JSON:JSON.stringify({'business-test':randomBytes(32).toString('base64')}),FIELD_HASH_KEY_BASE64:randomBytes(32).toString('base64'),EMAIL_PROVIDER:'mailgun',MAILGUN_API_KEY:'fake-local-only',MAILGUN_WEBHOOK_SIGNING_KEY:'fake-local-signing',ONEWAY_EMAIL_DOMAIN:'oneway.is',APPLE_APP_ID:'123456'});
 for(const k of ['DNS_VERIFIED','INBOUND_VERIFIED','GMAIL_DELIVERY_VERIFIED','OUTLOOK_DELIVERY_VERIFIED','BOUNCE_VERIFIED','COMPLAINT_VERIFIED','MALWARE_SCANNER_ENABLED','PUSH_ENABLED','TERMS_PUBLISHED','SUPPORT_READY','PRICING_COSTS_APPROVED','LIVE_DELIVERY_ENABLED'])process.env['ONEWAY_EMAIL_'+k]='true';
 for(const [id,local]of [[a,'businessalice'],[b,'businessbob']]) {await db.user.create({data:{id,email:id+'@example.invalid',displayName:'Test',passwordHash:'test'}});await db.oneWayIdentity.create({data:{userId:id,onewayId:'@'+local,emailAlias:local+'@oneway.app'}})}
});
after(async()=>{await db.$disconnect();rmSync(dir,{recursive:true,force:true})});
function payload(owner=a,extra:any={}) {return {productId:BUSINESS_CONTACT_PRODUCT_ID,type:Type.AUTO_RENEWABLE_SUBSCRIPTION,appAccountToken:owner,originalTransactionId:'order-'+owner,transactionId:randomUUID(),signedDate:Date.now(),expiresDate:Date.now()+3600000,bundleId:'com.king.OneWay',environment:Environment.PRODUCTION,...extra};}
test('one included number is idempotent; legacy numbers are retained',async()=>{
 await assignInitialFreeNumbers(a,2,db);await assignInitialFreeNumbers(a,2,db);assert.equal(await db.userNumber.count({where:{userId:a}}),1);await assert.rejects(()=>allocateInternalNumber(db,a),/subscription_required/);
 for(const number of ['OW-LEGACY1','OW-LEGACY2'])await db.userNumber.create({data:{userId:b,number,isPaid:false}});await assignInitialFreeNumbers(b,1,db);assert.equal(await db.userNumber.count({where:{userId:b}}),2);
});
test('Apple proof and account ownership are required; revocations cannot be replayed',async()=>{
 await assert.rejects(()=>verifyAppleTransaction('not-a-real-signed-transaction'),(e:any)=>e instanceof ApplePurchaseError&&e.code==='purchase_verification_failed');await assert.rejects(()=>applyBusinessTransaction(db,a,payload(b)),/purchase_account_mismatch/);
 const active=payload();await applyBusinessTransaction(db,a,active);assert.equal(await hasBusinessContactPlan(db,a),true);await assert.rejects(()=>applyBusinessTransaction(db,b,payload(b,{originalTransactionId:active.originalTransactionId})),/purchase_already_linked/);
 await applyBusinessTransaction(db,a,{...active,signedDate:active.signedDate+10,revocationDate:Date.now()});assert.equal(await hasBusinessContactPlan(db,a),false);await assert.rejects(()=>applyBusinessTransaction(db,a,active),/stale_purchase_update/);await applyBusinessTransaction(db,a,payload(a,{signedDate:active.signedDate+20}));
});
test('paid access allocates only one business number',async()=>{
 const n=await allocateInternalNumber(db,a);assert.equal(n.label,'OneWay Business Number');assert.equal(n.isPaid,true);await assert.rejects(()=>allocateInternalNumber(db,a),/business_number_already_owned/);assert.equal(await db.userNumber.count({where:{userId:a}}),2);
});
test('business email requires paid access and rejects unowned senders and drafts',async()=>{
 await assert.rejects(()=>service.claimBusinessAddress(b,'unpaidcompany'),(e:any)=>e.code==='business_subscription_required');const m:any=await service.claimBusinessAddress(a,'alicecompany');assert.equal(m.businessAddress.address,'alicecompany@oneway.is');assert.equal(m.address,'businessalice@oneway.is');await assert.rejects(()=>service.claim(b,'alicecompany@oneway.is'),/address_unavailable/);
 const d:any=await service.saveDraft(a,{fromAddress:'alicecompany@oneway.is',to:['test@example.invalid'],bodyText:'Business draft'});assert.deepEqual(d.from,['alicecompany@oneway.is']);const updated:any=await service.saveDraft(a,{id:d.id,fromAddress:'businessalice@oneway.is',to:[],bodyText:'Personal draft'});assert.deepEqual(updated.from,['businessalice@oneway.is']);
 const count=sent.length;await assert.rejects(()=>service.send(a,{fromAddress:'someoneelse@oneway.is',to:['test@example.invalid'],bodyText:'no'}),(e:any)=>e.code==='sender_not_available');await service.claim(b);await assert.rejects(()=>service.thread(b,d.threadId),/thread_not_found/);await assert.rejects(()=>service.send(b,{draftId:d.id,to:['test@example.invalid'],bodyText:'no'}),/draft_not_found/);assert.equal(sent.length,count);
 await service.send(a,{fromAddress:'alicecompany@oneway.is',to:['test@example.invalid'],bodyText:'Local provider test'});assert.equal(sent.at(-1).fromEmail,'alicecompany@oneway.is');
});
test('inbound business mail is isolated; provider IDs are deduplicated per mailbox',async()=>{
 async function inbound(recipient:string){const timestamp=String(Math.floor(Date.now()/1000)),token=randomUUID();return service.ingestMailgun({timestamp,token,signature:createHmac('sha256','fake-local-signing').update(timestamp+token).digest('hex'),recipient,sender:'sender@example.invalid',bodyText:'Local inbound',messageId:'same-provider-message'},[])}
 await inbound('alicecompany@oneway.is');await inbound('businessbob@oneway.is');assert.equal((await service.list(a,'inbox')).messages.length,1);assert.equal((await service.list(b,'inbox')).messages.length,1);
});
test('expiry retains addresses and history but disables business sending',async()=>{
 await applyBusinessTransaction(db,a,payload(a,{signedDate:Date.now()+100,expiresDate:Date.now()-1}));assert.equal(await hasBusinessContactPlan(db,a),false);const m:any=await service.getMailbox(a);assert.equal(m.businessAddress.active,false);assert.equal(m.businessAddress.address,'alicecompany@oneway.is');await assert.rejects(()=>service.send(a,{fromAddress:'alicecompany@oneway.is',to:['test@example.invalid'],bodyText:'no'}),(e:any)=>e.code==='sender_not_available');assert.equal((await service.list(a,'inbox')).messages.length,1);assert.equal(await db.userNumber.count({where:{userId:a}}),2);
});
