import type {PrismaClient} from '@prisma/client';
import {CommerceService} from './Commerce';
import {calculateMarketplaceOrderLedger,type MarketplaceFeeConfiguration} from '../marketplaceFee';
import {allocateCommerceInventory} from './CommerceInventory';
import {commerceEvents} from './CommerceEvents';
import {LedgerBalanceService} from '../ledger/LedgerBalanceService';

/** Called only after the existing Stripe signature verifier. Applies only to Layer-6 orders. */
export async function handleCommerceStripeEvent(db:PrismaClient,event:Record<string,any>):Promise<boolean>{
 const type=String(event.type??''),session=event.data?.object??{},id=String(session.metadata?.orderId??session.client_reference_id??'');
 if(!id||!['checkout.session.completed','checkout.session.async_payment_succeeded','checkout.session.async_payment_failed','payment_intent.succeeded','payment_intent.processing','payment_intent.payment_failed','payment_intent.canceled'].includes(type))return false;
 let records:any[];try{records=await db.$queryRawUnsafe<any[]>(`SELECT "id" FROM "CommerceDocument" WHERE "id"=? AND "kind"='state'`,id);}catch{return false;}if(!records.length)return false;
 const order=await db.order.findUnique({where:{id},include:{items:true}});if(!order)return false;
 const service=new CommerceService(db),state=await service.orderState(order);if(!state.quoteId)return false;
 // New orders always use Checkout. Intent events alone cannot authorize fulfillment.
 if(type.startsWith('payment_intent.'))return true;
 if(event.account)throw new Error('commerce_checkout_wrong_account');
 if(order.stripeCheckoutId&&order.stripeCheckoutId!==session.id)throw new Error('commerce_checkout_session_mismatch');
 if(type==='checkout.session.async_payment_failed'){
  await db.order.updateMany({where:{id,paymentStatus:{notIn:['paid','captured','refunded']}},data:{paymentStatus:'failed',status:'failed'}});return true;
 }
 if(session.payment_status!=='paid')return true;
 if(Number(session.amount_total)!==order.customerTotalMinor||String(session.currency).toUpperCase()!==order.currency.toUpperCase())throw new Error('commerce_checkout_amount_mismatch');
 if(order.refundedAmountMinor>0||order.paymentStatus==='refunded')return true;
 let config:MarketplaceFeeConfiguration|undefined;try{config=JSON.parse(order.feeConfigSnapshotJson??'null')??undefined;}catch{throw new Error('commerce_fee_snapshot_invalid');}
 const ledger=calculateMarketplaceOrderLedger({currency:order.currency,subtotalMinor:order.subtotalMinor,shippingAmountMinor:order.shippingAmountMinor,taxAmountMinor:order.taxAmountMinor,discountAmountMinor:order.discountAmountMinor,paymentProcessingFeeMinor:order.paymentProcessingFeeMinor,paymentStatus:'paid'},config);
 const {feeConfigSnapshot,...columns}=ledger;
 await db.order.update({where:{id},data:{...columns,status:'paid',stripeCheckoutId:String(session.id),paymentIntentId:typeof session.payment_intent==='string'?session.payment_intent:null,feeConfigSnapshotJson:JSON.stringify(feeConfigSnapshot)}});
 // Stable per-order external ID makes retries and out-of-order provider events idempotent.
 if(order.sellerId&&ledger.sellerNetAmountMinor>0){await new LedgerBalanceService(db).postLedgerTransaction({accountId:`wallet:${order.sellerId}:seller`,amountCents:ledger.sellerNetAmountMinor,type:'storefront_payment',direction:'credit',balanceBucket:'pending',currency:order.currency,externalId:`commerce-order:${id}:seller`,metadata:{orderId:id}});}
 // The first verified payment event establishes the timeline, never the app's success page.
 const allocated=await allocateCommerceInventory(db,order);
 if(!(allocated.events??[]).some((e:any)=>e.status==='confirmed')&&!allocated.inventoryIssue)await service.event(order,allocated,'confirmed');
 commerceEvents.emit('updated',{userId:order.userId,orderId:id,review:Boolean(allocated.inventoryIssue)});
 if(state.scheduleId){try{const rule=await service.get(order.userId,'schedule',state.scheduleId);let next=new Date(rule.nextRun).getTime();if(rule.nextRun===state.scheduledFor)next+=rule.intervalDays*86400000;while(next<=Date.now())next+=rule.intervalDays*86400000;await service.write(order.userId,'schedule',{...rule,nextRun:new Date(next).toISOString()},rule.id,rule.merchantId);}catch{ /* A buyer may have removed the schedule after placing the order. */ }}
 return true;
}
