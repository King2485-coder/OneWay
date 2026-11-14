import type {PrismaClient} from '@prisma/client';
import {CommerceService} from './Commerce';
/** Inventory is allocated only after verified payment, once per Order, inside the same transaction as its marker. */
export async function allocateCommerceInventory(db:PrismaClient,order:any):Promise<any>{
 try{return await db.$transaction(async tx=>{
   const s=new CommerceService(tx as PrismaClient),state=await s.orderState(order);
   if(state.inventoryApplied)return state;
   for(const line of order.items){
     if(!line.productId){if(line.name!=='Tip')throw new Error('catalog_item_missing');continue;}
     const product=await tx.storefrontProduct.findFirst({where:{id:line.productId,storefrontId:order.storeId,published:true,status:'published'}});
     if(!product)throw new Error('catalog_item_missing');
     if(product.trackInventory){const result=await tx.storefrontProduct.updateMany({where:{id:product.id,inventory:{gte:line.quantity}},data:{inventory:{decrement:line.quantity}}});if(result.count!==1)throw new Error('insufficient_inventory');}
   }
   const updated={...state,inventoryApplied:true,inventoryIssue:false,status:state.status==='awaiting_payment'||state.status==='review_required'?'confirmed':state.status};
   await s.write(order.userId,'state',updated,order.id,order.storeId,order.id);return updated;
 });}catch{
   const s=new CommerceService(db),latest=await s.orderState(order);if(latest.inventoryApplied)return latest;
   const updated={...latest,inventoryApplied:false,inventoryIssue:true,status:'review_required'};
   await s.write(order.userId,'state',updated,order.id,order.storeId,order.id);return updated;
 }
}
