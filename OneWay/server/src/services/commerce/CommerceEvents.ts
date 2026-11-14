import {EventEmitter} from 'node:events';
import type {PrismaClient} from '@prisma/client';
import {CommerceService,ensureCommerceTables} from './Commerce';
export const commerceEvents=new EventEmitter();
/** Approval reminders only. This job has no payment or dispatch capability. */
export async function remindDueCommerceRules(db:PrismaClient,notify:(userId:string)=>Promise<void>,clock=()=>Date.now()){
 await ensureCommerceTables(db);const rows=await db.$queryRawUnsafe<{id:string;userId:string}[]>(`SELECT "id","userId" FROM "CommerceDocument" WHERE "kind"='schedule' LIMIT 1000`);const service=new CommerceService(db,clock);
 for(const row of rows){const active=await db.user.findFirst({where:{id:row.userId,accountStatus:'active'}});if(!active)continue;const rule=await service.get(row.userId,'schedule',row.id);if(rule.paused||new Date(rule.nextRun).getTime()>clock()||rule.lastRemindedFor===rule.nextRun)continue;await notify(row.userId);await service.write(row.userId,'schedule',{...rule,lastRemindedFor:rule.nextRun},rule.id,rule.merchantId);}
}
