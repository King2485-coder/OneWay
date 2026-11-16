import {z} from 'zod';

export interface ProductionCheckoutContext {
  userId: string; orderId: string; merchantId: string; amountMinor: number; currency: string;
  entryPoint: 'commerce_checkout'|'marketplace_checkout'|'marketplace_intent';
  paymentStatus?: string;
}
// Server-held approval only. No request header/body can supply or change this grant.
const approvalSchema=z.object({
  ownerUserId:z.string().uuid(),orderId:z.string().uuid(),merchantId:z.string().uuid(),
  amountMinor:z.number().int().positive(),currency:z.string().regex(/^[A-Z]{3}$/),
  stripeAccountId:z.string().startsWith('acct_'),
  entryPoint:z.literal('commerce_checkout'),
  approvedAt:z.string().datetime(),expiresAt:z.string().datetime(),
  approvalReference:z.string().uuid(),
}).strict();

export class ProductionCheckoutBlocked extends Error {
  readonly status=503;
  constructor(readonly code:string){super(code);}
}
export function productionCheckoutDecision(context:ProductionCheckoutContext,env:NodeJS.ProcessEnv=process.env,now=Date.now()) {
  const mode=(env.STRIPE_ENV??env.STRIPE_ENVIRONMENT??(env.NODE_ENV==='production'?'production':'sandbox')).toLowerCase();
  const liveMode=['production','live'].includes(mode),liveKey=/^(sk|rk)_live_/.test(env.STRIPE_SECRET_KEY?.trim()??'');
  if(!liveMode&&!liveKey)return {allowed:true,canary:false,reason:null};
  if(!liveMode||!liveKey)return {allowed:false,canary:false,reason:'stripe_environment_mismatch'};
  if(env.ONEWAY_LIVE_CHECKOUT_ENABLED==='true')return {allowed:true,canary:false,reason:null};
  let input:unknown;try{input=JSON.parse(env.ONEWAY_PAYMENT_CANARY_APPROVAL??'');}catch{return {allowed:false,canary:false,reason:'live_checkout_not_approved'};}
  const parsed=approvalSchema.safeParse(input);
  if(!parsed.success)return {allowed:false,canary:false,reason:'live_checkout_not_approved'};
  const a=parsed.data,approved=Date.parse(a.approvedAt),expiry=Date.parse(a.expiresAt);
  const matches=a.ownerUserId===context.userId&&a.orderId===context.orderId&&a.merchantId===context.merchantId&&a.amountMinor===context.amountMinor&&a.currency===context.currency.toUpperCase()&&a.entryPoint===context.entryPoint;
  const timeValid=approved<=now&&expiry>now&&expiry>approved&&expiry-approved<=3600000;
  const terminal=['paid','captured','refunded','partially_refunded','canceled','cancelled','completed'].includes((context.paymentStatus??'').toLowerCase());
  if(!matches||!timeValid||terminal)return {allowed:false,canary:false,reason:'live_checkout_not_approved'};
  return {allowed:true,canary:true,reason:null,expectedStripeAccountId:a.stripeAccountId,approvalReference:a.approvalReference};
}
export async function assertProductionCheckoutAllowed(context:ProductionCheckoutContext,retrieveAccount:()=>Promise<{id?:unknown}>) {
  const decision=productionCheckoutDecision(context);
  if(!decision.allowed)throw new ProductionCheckoutBlocked(decision.reason??'live_checkout_not_approved');
  if(decision.canary){
    const account=await retrieveAccount();
    if(account.id!==decision.expectedStripeAccountId)throw new ProductionCheckoutBlocked('canary_stripe_account_mismatch');
  }
  return decision;
}
