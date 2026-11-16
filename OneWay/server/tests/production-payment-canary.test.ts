import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {productionCheckoutDecision,assertProductionCheckoutAllowed} from '../src/services/payments/ProductionPaymentGate';
const now=Date.now(),owner=randomUUID(),order=randomUUID(),merchant=randomUUID();
const context={userId:owner,orderId:order,merchantId:merchant,amountMinor:500,currency:'USD',entryPoint:'commerce_checkout' as const,paymentStatus:'pending_payment'};
const approval={ownerUserId:owner,orderId:order,merchantId:merchant,amountMinor:500,currency:'USD',stripeAccountId:'acct_owner_canary',entryPoint:'commerce_checkout',approvedAt:new Date(now-1000).toISOString(),expiresAt:new Date(now+60000).toISOString(),approvalReference:randomUUID()};
// Synthetic non-working fixture, never an actual provider credential.
const live={STRIPE_ENV:'production',STRIPE_SECRET_KEY:'sk_live_NONWORKING_LOCAL_FIXTURE',ONEWAY_LIVE_CHECKOUT_ENABLED:'false'};
const env=(override={})=>({...live,ONEWAY_PAYMENT_CANARY_APPROVAL:JSON.stringify({...approval,...override})});
test('production checkout defaults closed and malformed approval never opens it',()=>{
 assert.equal(productionCheckoutDecision(context,live,now).allowed,false);
 for(const value of ['', '{}','true','[]'])assert.equal(productionCheckoutDecision(context,{...live,ONEWAY_PAYMENT_CANARY_APPROVAL:value},now).allowed,false);
});
test('only the exact owner order, merchant, integer amount, currency and entry point match',()=>{
 assert.equal(productionCheckoutDecision(context,env(),now).canary,true);
 for(const changed of [{userId:randomUUID()},{orderId:randomUUID()},{merchantId:randomUUID()},{amountMinor:501},{currency:'EUR'},{entryPoint:'marketplace_checkout' as const},{entryPoint:'marketplace_intent' as const}])assert.equal(productionCheckoutDecision({...context,...changed},env(),now).allowed,false);
});
test('approval expires, cannot be future-dated or live longer than one hour',()=>{
 for(const changed of [{expiresAt:new Date(now).toISOString()},{approvedAt:new Date(now+1000).toISOString()},{expiresAt:new Date(now+7200000).toISOString()}])assert.equal(productionCheckoutDecision(context,env(changed),now).allowed,false);
});
test('paid, refunded and cancelled canaries close automatically; test mode stays separate',()=>{
 for(const paymentStatus of ['paid','captured','refunded','partially_refunded','canceled','completed'])assert.equal(productionCheckoutDecision({...context,paymentStatus},env(),now).allowed,false);
 assert.equal(productionCheckoutDecision(context,{STRIPE_ENV:'sandbox',STRIPE_SECRET_KEY:'sk_test_NONWORKING_LOCAL_FIXTURE'},now).canary,false);
 assert.equal(productionCheckoutDecision(context,{...live,STRIPE_ENV:'sandbox'},now).allowed,false);
});
test('approval cannot contain extra client-selected authorization fields',()=>{
 assert.equal(productionCheckoutDecision(context,{...live,ONEWAY_PAYMENT_CANARY_APPROVAL:JSON.stringify({...approval,skipOwnerApproval:true})},now).allowed,false);
});
test('account verification happens before canary use, and never for a blocked request',async()=>{
 const before={...process.env};let reads=0;
 try{
  Object.assign(process.env,live);delete process.env.ONEWAY_PAYMENT_CANARY_APPROVAL;
  await assert.rejects(assertProductionCheckoutAllowed(context,async()=>{reads++;return{id:'acct_owner_canary'};}),/live_checkout_not_approved/);assert.equal(reads,0);
  process.env.ONEWAY_PAYMENT_CANARY_APPROVAL=JSON.stringify(approval);
  await assert.rejects(assertProductionCheckoutAllowed(context,async()=>({id:'acct_wrong'})),/canary_stripe_account_mismatch/);
  const decision=await assertProductionCheckoutAllowed(context,async()=>({id:'acct_owner_canary'}));assert.equal(decision.canary,true);
  assert.equal(process.env.ONEWAY_LIVE_CHECKOUT_ENABLED,'false');
 }finally{for(const key of ['STRIPE_ENV','STRIPE_SECRET_KEY','ONEWAY_LIVE_CHECKOUT_ENABLED','ONEWAY_PAYMENT_CANARY_APPROVAL']){if(before[key]===undefined)delete process.env[key];else process.env[key]=before[key];}}
});
