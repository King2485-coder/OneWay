import express, {type RequestHandler} from 'express';
import type {PrismaClient} from '@prisma/client';
import {z} from 'zod';
import {communicationBlocked} from '../services/AccountVisibility';

export const protectedDefaults = Object.freeze({enabled:true,screenshotDetection:true,screenshotAlerts:true,notifyParticipants:true,recordingProtection:true,mirroringProtection:true,appSwitcherPrivacy:true,viewOnceProtection:true,sensitiveMediaProtection:true,watermark:false});
export type ProtectedSettings = typeof protectedDefaults;
const settingsSchema = z.object(Object.fromEntries(Object.keys(protectedDefaults).map(k=>[k,z.boolean()])) as Record<keyof ProtectedSettings,z.ZodBoolean>).strict();
const kindSchema=z.enum(['conversation','peer','shop','community','channel','chirp','instant']);
const idSchema=z.string().min(1).max(128).regex(/^[A-Za-z0-9_.:-]+$/);
const overrideSchema=z.object({kind:kindSchema,id:idSchema,value:z.enum(['on','off'])}).strict();
const preferenceSchema=z.object({expectedVersion:z.number().int().min(0),settings:settingsSchema,overrides:z.array(overrideSchema).max(200)}).strict();
const eventSchema=z.object({eventId:z.string().uuid(),eventType:z.enum(['SCREENSHOT_DETECTED','VIEW_ONCE_CAPTURE_ATTEMPT'])}).strict();
const retentionMs=7*24*3600*1000;
const initialized=new WeakMap<object,Promise<void>>();
const canonicalID=(id:string)=>/^[a-f0-9-]{36}$/i.test(id)?id.toLowerCase():id;
const strings=(s:string|undefined)=>{try{return JSON.parse(s||'[]') as string[];}catch{return[];}};
class PrivacyFailure extends Error {constructor(readonly status:number,readonly code:string){super(code);}}

export async function ensureProtectedTables(db:PrismaClient){
 let pending=initialized.get(db);if(!pending){pending=(async()=>{
  await db.$executeRawUnsafe('CREATE TABLE IF NOT EXISTS "ProtectedConversationPreference" ("userId" TEXT PRIMARY KEY,"settingsJson" TEXT NOT NULL,"overridesJson" TEXT NOT NULL,"version" INTEGER NOT NULL,"updatedAtMs" BIGINT NOT NULL, FOREIGN KEY("userId") REFERENCES "User"("id") ON DELETE CASCADE)');
  await db.$executeRawUnsafe('CREATE TABLE IF NOT EXISTS "ConversationPrivacyEvent" ("eventId" TEXT PRIMARY KEY,"scope" TEXT NOT NULL,"reporterUserId" TEXT NOT NULL,"eventType" TEXT NOT NULL,"createdAtMs" BIGINT NOT NULL,"expiresAtMs" BIGINT NOT NULL,"notifiedParticipants" INTEGER NOT NULL DEFAULT 0, FOREIGN KEY("reporterUserId") REFERENCES "User"("id") ON DELETE CASCADE)');
  await db.$executeRawUnsafe('CREATE INDEX IF NOT EXISTS "ConversationPrivacyEvent_scope_time" ON "ConversationPrivacyEvent" ("scope","createdAtMs")');
  await db.$executeRawUnsafe('CREATE INDEX IF NOT EXISTS "ConversationPrivacyEvent_expiry" ON "ConversationPrivacyEvent" ("expiresAtMs")');
 })();initialized.set(db,pending);pending.catch(()=>initialized.delete(db));}await pending;
}
async function preferences(db:PrismaClient,owner:string){
 const rows=await db.$queryRawUnsafe<any[]>('SELECT * FROM "ProtectedConversationPreference" WHERE "userId"=?',owner),r=rows[0];
 return r?{settings:{...protectedDefaults,...JSON.parse(r.settingsJson)},overrides:JSON.parse(r.overridesJson) as z.infer<typeof overrideSchema>[],version:Number(r.version)}:{settings:{...protectedDefaults},overrides:[],version:0};
}
export async function protectedScopeMembers(db:PrismaClient,kind:string,id:string,owner:string):Promise<{scope:string,members:string[]}>{
 id=canonicalID(id);const anyDB=db as any;
 if(kind==='conversation'||kind==='peer'){
  const where=kind==='conversation'?{id,participants:{some:{userId:owner}}}:{type:'direct',AND:[{participants:{some:{userId:owner}}},{participants:{some:{userId:id}}}]};
  const c=await db.conversation.findFirst({where,include:{participants:{select:{userId:true}}}});
  if(c&&!c.type.startsWith('external'))return {scope:'conversation:'+c.id,members:c.participants.map(p=>p.userId)};
 }
 if(kind==='shop'){
  const c=await db.shopConversation.findFirst({where:{id,OR:[{buyerId:owner},{sellerId:owner}]}});
  if(c&&!strings(c.deletedByJson).includes(owner))return {scope:'shop:'+id,members:[c.buyerId,c.sellerId]};
 }
 if(kind==='community'||kind==='channel'){
  const channel=kind==='channel'&&anyDB.communityChannel?await anyDB.communityChannel.findUnique({where:{id},include:{permissions:true}}):null;
  const communityId=kind==='community'?id:channel?.communityId;
  if(communityId){const c=await db.community.findFirst({where:{id:communityId,deletedAt:null,members:{some:{userId:owner}}},include:{members:{select:{userId:true,role:true}}}});
   if(c&&!strings(c.bannedUserIdsJson).includes(owner)&&!strings(c.blockedUserIdsJson).includes(owner)){
    let members=c.members.filter(p=>!strings(c.bannedUserIdsJson).includes(p.userId)&&!strings(c.blockedUserIdsJson).includes(p.userId));
    if(channel){
     const allowed:string[]=[];
     for(const member of members){
      const role=c.ownerId===member.userId?'owner':member.role;
      const grants=await anyDB.communityRoleGrant.findMany({where:{userId:member.userId,role:{communityId}},select:{roleId:true}});
      const base=channel.permissions.find((p:any)=>p.roleKey===role)??channel.permissions.find((p:any)=>p.roleKey==='member');
      const overrides=channel.permissions.filter((p:any)=>grants.some((g:any)=>g.roleId===p.roleKey));
      if(role==='owner'||role==='admin'||(!overrides.some((p:any)=>!p.canView)&&(overrides.some((p:any)=>p.canView)||(base?.canView??true))))allowed.push(member.userId);
     }
     if(!allowed.includes(owner))throw new PrivacyFailure(404,'protected_scope_unavailable');
     members=members.filter(p=>allowed.includes(p.userId));
    }
    return {scope:kind+':'+id,members:members.map(p=>p.userId)};
   }
  }
 }
 if(kind==='chirp'){
  const r=(await db.$queryRawUnsafe<any[]>('SELECT "senderId","recipientId" FROM "RecordedChirp" WHERE "id"=? AND ("senderId"=? OR "recipientId"=?) AND "deletedAtMs" IS NULL AND ("expiresAtMs" IS NULL OR "expiresAtMs">?)',id,owner,owner,Date.now()))[0];
  if(r)return {scope:'chirp:'+id,members:[r.senderId,r.recipientId]};
 }
 if(kind==='instant'){
  const p=(await db.$queryRawUnsafe<any[]>('SELECT "senderId" FROM "InstantPhoto" WHERE "id"=? AND "expiresAtMs">?',id,Date.now()))[0];
  if(p){const recipients=await db.$queryRawUnsafe<any[]>('SELECT "userId" FROM "InstantRecipient" WHERE "instantId"=?',id);const members=[p.senderId,...recipients.map(x=>x.userId)];if(members.includes(owner))return {scope:'instant:'+id,members};}
 }
 throw new PrivacyFailure(404,'protected_scope_unavailable');
}

export function protectedConversationsRouter(deps:{db:PrismaClient,authenticate:RequestHandler,notify?:(userId:string,eventId:string)=>Promise<void>}){
 const {db}=deps,router=express.Router();
 // Retention is enforced even when clients stop requesting events. Never log event contents.
 const cleanup=setInterval(()=>{void ensureProtectedTables(db).then(()=>db.$executeRawUnsafe('DELETE FROM "ConversationPrivacyEvent" WHERE "expiresAtMs"<=?',Date.now())).catch(()=>undefined);},3600000);cleanup.unref();
 router.use(deps.authenticate);router.use((_req,res,next)=>{res.setHeader('Cache-Control','private, no-store');next();});
 const handle=(fn:(req:express.Request,res:express.Response,owner:string)=>Promise<void>):RequestHandler=>async(req,res)=>{try{await ensureProtectedTables(db);const owner=(req as any).userId;if(typeof owner!=='string'||!owner){res.status(401).end();return;}const expected=req.header('x-oneway-expected-user');if(expected&&expected!==owner){res.status(409).json({error:'account_changed'});return;}await fn(req,res,owner);}catch(e){if(e instanceof PrivacyFailure)res.status(e.status).json({error:e.code});else res.status(503).json({error:'protected_privacy_unavailable'});}};
 router.get('/preferences',handle(async(_req,res,owner)=>{res.json(await preferences(db,owner));}));
 router.put('/preferences',handle(async(req,res,owner)=>{
  const body=preferenceSchema.safeParse(req.body);if(!body.success){res.status(400).json({error:'invalid_privacy_preferences'});return;}
  const b=body.data,unique=new Set(b.overrides.map(o=>o.kind+':'+canonicalID(o.id)));if(unique.size!==b.overrides.length){res.status(400).json({error:'duplicate_privacy_override'});return;}
  for(const o of b.overrides)await protectedScopeMembers(db,o.kind,o.id,owner);
  const updated=await db.$transaction(async tx=>{
   const prior=await preferences(tx as PrismaClient,owner);if(prior.version!==b.expectedVersion)throw new PrivacyFailure(409,'privacy_changed_refresh_first');
   const next=prior.version+1,overrides=b.overrides.map(o=>({...o,id:canonicalID(o.id)}));
   await tx.$executeRawUnsafe('INSERT INTO "ProtectedConversationPreference" ("userId","settingsJson","overridesJson","version","updatedAtMs") VALUES (?,?,?,?,?) ON CONFLICT("userId") DO UPDATE SET "settingsJson"=excluded."settingsJson","overridesJson"=excluded."overridesJson","version"=excluded."version","updatedAtMs"=excluded."updatedAtMs"',owner,JSON.stringify(b.settings),JSON.stringify(overrides),next,Date.now());
   return {settings:b.settings,overrides,version:next};
  });res.json(updated);
 }));
 const scope=(req:express.Request,owner:string)=>{const k=kindSchema.safeParse(req.params.kind),id=idSchema.safeParse(req.params.id);if(!k.success||!id.success)throw new PrivacyFailure(400,'invalid_privacy_scope');return protectedScopeMembers(db,k.data,id.data,owner);};
 router.get('/scopes/:kind/:id/events',handle(async(req,res,owner)=>{
  const c=await scope(req,owner),now=Date.now();await db.$executeRawUnsafe('DELETE FROM "ConversationPrivacyEvent" WHERE "expiresAtMs"<=?',now);
  const rows=await db.$queryRawUnsafe<any[]>('SELECT "eventId","eventType","createdAtMs","reporterUserId" FROM "ConversationPrivacyEvent" WHERE "scope"=? AND "expiresAtMs">? AND ("reporterUserId"=? OR "notifiedParticipants"=1) ORDER BY "createdAtMs" DESC LIMIT 30',c.scope,now,owner);
  const prefs=await preferences(db,owner);const visible=[];if(prefs.settings.enabled&&prefs.settings.screenshotAlerts)for(const r of rows){if(r.reporterUserId!==owner&&await communicationBlocked(db,owner,r.reporterUserId))continue;visible.push(r);}
  res.json({events:visible.map(r=>({eventId:r.eventId,eventType:r.eventType,createdAt:new Date(Number(r.createdAtMs)).toISOString(),isMine:r.reporterUserId===owner,source:'IOS_CLIENT_REPORT',reliability:'CLIENT_REPORTED_OS_SIGNAL',message:'A screenshot was detected in this conversation.'})),retentionDays:7});
 }));
 router.post('/scopes/:kind/:id/events',handle(async(req,res,owner)=>{
  const body=eventSchema.safeParse(req.body);if(!body.success){res.status(400).json({error:'invalid_privacy_event'});return;}
  const c=await scope(req,owner),prefs=await preferences(db,owner),override=prefs.overrides.find(o=>o.kind===req.params.kind&&o.id===canonicalID(String(req.params.id)));
  // Master off deactivates everything while preserving the individual preferences.
  const enabled=prefs.settings.enabled&&override?.value!=='off';
  if(!enabled||!prefs.settings.screenshotDetection){res.status(409).json({error:'screenshot_detection_disabled'});return;}
  const now=Date.now();await db.$executeRawUnsafe('DELETE FROM "ConversationPrivacyEvent" WHERE "expiresAtMs"<=?',now);
  const duplicate=(await db.$queryRawUnsafe<any[]>('SELECT "scope","reporterUserId" FROM "ConversationPrivacyEvent" WHERE "eventId"=?',body.data.eventId))[0];
  if(duplicate){if(duplicate.scope!==c.scope||duplicate.reporterUserId!==owner)throw new PrivacyFailure(409,'privacy_event_conflict');res.json({ok:true,duplicate:true});return;}
  const count=(await db.$queryRawUnsafe<any[]>('SELECT COUNT(*) AS n FROM "ConversationPrivacyEvent" WHERE "reporterUserId"=? AND "createdAtMs">?',owner,now-60000))[0];
  if(Number(count.n)>=12){res.status(429).json({error:'privacy_event_rate_limited'});return;}
  const notify=prefs.settings.notifyParticipants;
  await db.$executeRawUnsafe('INSERT INTO "ConversationPrivacyEvent" ("eventId","scope","reporterUserId","eventType","createdAtMs","expiresAtMs","notifiedParticipants") VALUES (?,?,?,?,?,?,?)',body.data.eventId,c.scope,owner,body.data.eventType,now,now+retentionMs,notify?1:0);
  let notified=0;if(notify&&deps.notify)for(const member of [...new Set(c.members)].filter(x=>x!==owner)){
   if(await communicationBlocked(db,owner,member))continue;
   const recipient=await preferences(db,member);if(!recipient.settings.enabled||!recipient.settings.screenshotAlerts)continue;
   await deps.notify(member,body.data.eventId).then(()=>{notified++;}).catch(()=>undefined);
  }
  res.status(201).json({ok:true,eventId:body.data.eventId,notifiedParticipants:notified});
 }));
 return router;
}
