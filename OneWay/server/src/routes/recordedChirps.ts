import express,{type RequestHandler} from 'express';
import type {PrismaClient} from '@prisma/client';
import {z} from 'zod';
import rateLimit from 'express-rate-limit';
import {createHash,randomUUID} from 'node:crypto';
import {isDirectChirpDiscoverable} from './walkie';
import {mayCommunicate} from '../services/AccountVisibility';
import {encryptString,decryptString,isFieldEncryptionEnabled} from '../services/privacy/EncryptionService';
import type {ObjectStorage} from '../lib/storage/ObjectStorage';
import {LocalObjectStorage} from '../lib/storage/LocalObjectStorage';
import {S3ObjectStorage} from '../lib/storage/S3ObjectStorage';
import {validCloudMedia} from './cloudMedia';
import type {EmailAlertPushService} from '../services/EmailAlertPushService';
const id=z.string().uuid().transform(s=>s.toLowerCase()),who=z.string().trim().min(1).max(128).transform(s=>z.string().uuid().safeParse(s).success?s.toLowerCase():s);
const life=z.enum(['KEEP','VIEW_ONCE','ONE_HOUR','TWENTY_FOUR_HOURS']);
const kind=z.enum(['VOICE','PHOTO','VIDEO','LOCATION']);
const location=z.object({name:z.string().trim().min(1).max(160),latitude:z.number().min(-90).max(90),longitude:z.number().min(-180).max(180)}).strict();
const input=z.object({id,senderDeviceId:id,recipientType:z.literal('person'),recipientId:who,chirpType:kind,lifetimePolicy:life,createdAtMs:z.number().int().positive(),caption:z.string().trim().max(280).default(''),mimeType:z.enum(['audio/mp4','image/jpeg','video/mp4']).optional(),payloadBase64:z.string().max(8500000).optional(),durationMs:z.number().int().min(0).max(60000).default(0),location:location.optional(),replyToChirpId:id.optional()}).strict();
// Read the bounded MP4 movie header, rather than trusting client-declared duration.
function mediaDuration(bytes:Buffer):number|null {
 const scan=(start:number,end:number,depth:number):number|null=>{
  if(depth>2)return null;
  for(let at=start;at+8<=end;){
   const size=bytes.readUInt32BE(at),type=bytes.toString('ascii',at+4,at+8);
   if(size<8||at+size>end)return null;
   if(type==='mvhd'){
    const p=at+8,version=bytes[p];if(version!==0&&version!==1)return null;
    const scaleAt=p+(version===1?20:12),durationAt=scaleAt+4;
    if(durationAt+(version===1?8:4)>at+size)return null;
    const scale=bytes.readUInt32BE(scaleAt),duration=version===1?Number(bytes.readBigUInt64BE(durationAt)):bytes.readUInt32BE(durationAt);
    return scale>0?duration*1000/scale:null;
   }
   if(type==='moov'){const found=scan(at+8,at+size,depth+1);if(found!==null)return found;}
   at+=size;
  }return null;
 };return scan(0,bytes.length,0);
}
type Row={id:string;senderId:string;senderDeviceId:string;recipientId:string;recipientType:string;chirpType:string;lifetimePolicy:string;createdAtMs:bigint|number;expiresAtMs:bigint|number|null;storageKey:string|null;fingerprint:string;durationMs:number;byteCount:number;replyToChirpId:string|null;deletedAtMs:bigint|number|null};
type Receipt={deliveredAtMs:bigint|number|null;openedAtMs:bigint|number|null;playedAtMs:bigint|number|null;consumedAtMs:bigint|number|null;hiddenAtMs:bigint|number|null;reaction:string|null};
type RequestRow={id:string;senderId:string;recipientId:string;state:string;createdAtMs:bigint|number;expiresAtMs:bigint|number};
class ChirpError extends Error{constructor(readonly status:number,readonly code:string){super(code);}}
const iso=(v:bigint|number|null)=>v==null?null:new Date(Number(v)).toISOString();
export function recordedChirpsRouter(deps:{db:PrismaClient;authenticate:RequestHandler;alerts?:Pick<EmailAlertPushService,'sendRecordedChirp'|'sendChirpInvitation'>;storage?:ObjectStorage|null;clock?:()=>number}){
 const {db}=deps,now=deps.clock??Date.now,router=express.Router();
 const storage=deps.storage===undefined?(process.env.ONEWAY_PRIVATE_CLOUD_DIR?new LocalObjectStorage({root:process.env.ONEWAY_PRIVATE_CLOUD_DIR}):S3ObjectStorage.fromEnv()):deps.storage;
 const uid=(req:express.Request)=>(req as any).userId as string;
 const wrap=(fn:(req:express.Request,res:express.Response)=>Promise<unknown>):RequestHandler=>(req,res)=>{void fn(req,res).catch(e=>res.status(e instanceof ChirpError?e.status:e instanceof z.ZodError?400:503).json({error:e instanceof ChirpError?e.code:e instanceof z.ZodError?'invalid_chirp':'chirps_unavailable'}));};
 async function pref(user:string){const rows=await db.$queryRawUnsafe<any[]>('SELECT * FROM "RecordedChirpPreference" WHERE "userId"=?',user);return rows[0]??{receipts:1,defaultLifetime:'KEEP',locationEnabled:1};}
 async function eligible(sender:string,recipient:string){
  if(sender===recipient||!await mayCommunicate(db,sender,recipient))return false;
  if(await db.user.count({where:{id:{in:[sender,recipient]},accountStatus:'active'}})!==2)return false;
  const p=await db.walkiePrivacySettings.findUnique({where:{userId:recipient}});
  return isDirectChirpDiscoverable(db,sender,recipient,{allowDirectChirp:p?.allowDirectChirp??true,directChirpAudience:p?.directChirpAudience??'everyone'});
 }
 async function grant(a:string,b:string){return (await db.$queryRawUnsafe<RequestRow[]>('SELECT * FROM "RecordedChirpRequest" WHERE (("senderId"=? AND "recipientId"=?) OR ("senderId"=? AND "recipientId"=?)) ORDER BY "createdAtMs" DESC,"id" DESC LIMIT 1',a,b,b,a))[0];}
 async function ready(a:string,b:string){if(!await eligible(a,b))return false;const g=await grant(a,b);return g?.state==='accepted'&&Number(g.expiresAtMs)>now();}
 async function names(user:string){return (await db.socialProfile.findUnique({where:{userId:user},select:{displayName:true}}))?.displayName||(await db.user.findUnique({where:{id:user},select:{displayName:true}}))?.displayName||'OneWay contact';}
 async function find(item:string,viewer:string){const r=(await db.$queryRawUnsafe<Row[]>('SELECT * FROM "RecordedChirp" WHERE "id"=? AND ("senderId"=? OR "recipientId"=?)',item,viewer,viewer))[0];if(!r||!await eligible(r.senderId,r.recipientId))throw new ChirpError(404,'chirp_unavailable');return r;}
 async function receipt(item:string){return (await db.$queryRawUnsafe<Receipt[]>('SELECT * FROM "RecordedChirpReceipt" WHERE "chirpId"=?',item))[0];}
 function expired(r:Row){return r.expiresAtMs!=null&&Number(r.expiresAtMs)<=now();}
 async function dto(r:Row,viewer:string){const q=await receipt(r.id),mine=r.senderId===viewer,ex=expired(r),privateReceipts=Boolean((await pref(r.recipientId)).receipts);
  return {id:r.id,senderId:r.senderId,recipientId:r.recipientId,peerId:mine?r.recipientId:r.senderId,peerName:await names(mine?r.recipientId:r.senderId),chirpType:r.chirpType,lifetimePolicy:r.lifetimePolicy,createdAt:iso(r.createdAtMs),expiresAt:iso(r.expiresAtMs),isMine:mine,durationMs:r.durationMs,replyToChirpId:r.replyToChirpId,available:(!mine||r.lifetimePolicy!=='VIEW_ONCE')&&!ex&&!r.deletedAtMs&&Boolean(r.storageKey)&&!(r.lifetimePolicy==='VIEW_ONCE'&&q?.consumedAtMs!=null),status:r.deletedAtMs?'Deleted':ex?'Expired':q?.consumedAtMs!=null&&(!mine||privateReceipts)?(r.chirpType==='VOICE'?(q.playedAtMs!=null?'Played':'Opened'):'Viewed'):q?.playedAtMs!=null&&(!mine||privateReceipts)?'Played':q?.openedAtMs!=null&&(!mine||privateReceipts)?(r.chirpType==='VOICE'?'Opened':'Viewed'):q?.deliveredAtMs!=null?'Delivered':'Sent',reaction:q?.reaction??null};
 }
 async function cleanup(){if(!storage)return;const old=await db.$queryRawUnsafe<Row[]>('SELECT * FROM "RecordedChirp" WHERE "storageKey" IS NOT NULL AND (("expiresAtMs" IS NOT NULL AND "expiresAtMs"<=?) OR "deletedAtMs" IS NOT NULL OR ("lifetimePolicy"=\'VIEW_ONCE\' AND "id" IN (SELECT "chirpId" FROM "RecordedChirpReceipt" WHERE "consumedAtMs" IS NOT NULL)) OR "senderId" NOT IN (SELECT "id" FROM "User" WHERE "accountStatus"=\'active\')) LIMIT 40',now());for(const r of old){try{await storage.delete(r.storageKey!);await db.$executeRawUnsafe('UPDATE "RecordedChirp" SET "storageKey"=NULL WHERE "id"=?',r.id);}catch{/* retry cleanup without exposing body */}}}
 const timer=setInterval(()=>void cleanup().catch(()=>undefined),30000);timer.unref();
 router.get('/status',(_req,res)=>res.json({enabled:Boolean(storage)&&isFieldEncryptionEnabled(),version:1,securityMode:'LEGACY_NOT_E2EE'}));
 router.use(deps.authenticate);router.use((_req,res,next)=>{res.set({'Cache-Control':'private, no-store, max-age=0','Pragma':'no-cache','X-Content-Type-Options':'nosniff'});next();});
 router.use((req,res,next)=>{void(async()=>{if(!storage||!isFieldEncryptionEnabled())throw new ChirpError(503,'chirps_unavailable');if(!await db.user.findFirst({where:{id:uid(req),accountStatus:'active'}}))throw new ChirpError(401,'account_not_active');next();})().catch(e=>res.status(e instanceof ChirpError?e.status:503).json({error:e instanceof ChirpError?e.code:'chirps_unavailable'}));});
 const writes=rateLimit({windowMs:60000,limit:30,standardHeaders:true,legacyHeaders:false,keyGenerator:req=>uid(req)});
 router.get('/privacy',wrap(async(req,res)=>{const user=uid(req),p=await pref(user),legacy=await db.walkiePrivacySettings.findUnique({where:{userId:user}});res.json({audience:legacy?.directChirpAudience??'everyone',receipts:Boolean(p.receipts),defaultLifetime:p.defaultLifetime,locationEnabled:Boolean(p.locationEnabled)});}));
 router.put('/privacy',writes,wrap(async(req,res)=>{const v=z.object({audience:z.enum(['everyone','following','friends','contacts','friendsOfFriends','verified','nobody']),receipts:z.boolean(),defaultLifetime:life,locationEnabled:z.boolean()}).strict().parse(req.body),user=uid(req);await db.$transaction(async tx=>{await tx.walkiePrivacySettings.upsert({where:{userId:user},create:{userId:user,directChirpAudience:v.audience,allowDirectChirp:v.audience!=='nobody'},update:{directChirpAudience:v.audience,allowDirectChirp:v.audience!=='nobody'}});await tx.$executeRawUnsafe('INSERT INTO "RecordedChirpPreference" ("userId","receipts","defaultLifetime","locationEnabled") VALUES (?,?,?,?) ON CONFLICT("userId") DO UPDATE SET "receipts"=excluded."receipts","defaultLifetime"=excluded."defaultLifetime","locationEnabled"=excluded."locationEnabled"',user,Number(v.receipts),v.defaultLifetime,Number(v.locationEnabled));});res.json(v);}));
 router.get('/permission/:peer',wrap(async(req,res)=>{const peer=who.parse(req.params.peer),user=uid(req),canRequest=await eligible(user,peer);res.json({canRequest,canSend:canRequest&&await ready(user,peer),securityMode:'LEGACY_NOT_E2EE'});}));
 router.get('/requests',wrap(async(req,res)=>{const user=uid(req),rows=await db.$queryRawUnsafe<RequestRow[]>('SELECT * FROM "RecordedChirpRequest" WHERE "recipientId"=? AND "state"=\'pending\' AND "expiresAtMs">? ORDER BY "createdAtMs" DESC LIMIT 30',user,now());const result=[];for(const r of rows)if(await eligible(r.senderId,user))result.push({id:r.id,senderId:r.senderId,senderName:await names(r.senderId)});res.json({requests:result});}));
 router.post('/requests',writes,wrap(async(req,res)=>{const peer=who.parse(req.body?.recipientId),sender=uid(req);if(!await eligible(sender,peer))throw new ChirpError(403,'chirp_not_allowed');const existing=await grant(sender,peer);if(existing?.state==='pending'&&existing.senderId===sender&&Number(existing.expiresAtMs)>now())return res.json({id:existing.id});const requestId=randomUUID();await db.$executeRawUnsafe('INSERT INTO "RecordedChirpRequest" ("id","senderId","recipientId","state","createdAtMs","expiresAtMs") VALUES (?,?,?,\'pending\',?,?)',requestId,sender,peer,now(),now()+900000);void deps.alerts?.sendChirpInvitation({userId:peer,requestId}).catch(()=>undefined);res.status(201).json({id:requestId});}));
 router.post('/requests/:id/answer',writes,wrap(async(req,res)=>{const requestId=id.parse(req.params.id),accept=z.boolean().parse(req.body?.accept),r=(await db.$queryRawUnsafe<RequestRow[]>('SELECT * FROM "RecordedChirpRequest" WHERE "id"=? AND "recipientId"=? AND "state"=\'pending\' AND "expiresAtMs">?',requestId,uid(req),now()))[0];if(!r||!await eligible(r.senderId,r.recipientId))throw new ChirpError(404,'request_unavailable');await db.$executeRawUnsafe('UPDATE "RecordedChirpRequest" SET "state"=?,"expiresAtMs"=? WHERE "id"=? AND "state"=\'pending\'',accept?'accepted':'declined',accept?now()+86400000:now(),requestId);res.json({accepted:accept});}));
 router.delete('/permission/:peer',writes,wrap(async(req,res)=>{const peer=who.parse(req.params.peer),owner=uid(req);await db.$executeRawUnsafe('UPDATE "RecordedChirpRequest" SET "state"=\'revoked\' WHERE ("senderId"=? AND "recipientId"=?) OR ("senderId"=? AND "recipientId"=?)',owner,peer,peer,owner);res.status(204).end();}));
 router.get('/',wrap(async(req,res)=>{const owner=uid(req),peer=typeof req.query.peer==='string'?who.parse(req.query.peer):null,rows=await db.$queryRawUnsafe<Row[]>('SELECT * FROM "RecordedChirp" WHERE ("senderId"=? OR "recipientId"=?) ORDER BY "createdAtMs" DESC LIMIT 150',owner,owner),items=[];for(const r of rows){if(peer&&r.senderId!==peer&&r.recipientId!==peer)continue;if(!await eligible(r.senderId,r.recipientId))continue;const q=await receipt(r.id);if(r.recipientId===owner&&q?.hiddenAtMs!=null)continue;items.push(await dto(r,owner));}res.json({items});}));
 router.post('/',writes,wrap(async(req,res)=>{
  const v=input.parse(req.body),sender=uid(req),created=v.createdAtMs,time=now(),expires=v.lifetimePolicy==='ONE_HOUR'?created+3600000:v.lifetimePolicy==='TWENTY_FOUR_HOURS'?created+86400000:null;
  if(created>time+300000||created<time-7*86400000||expires!=null&&expires<=time)throw new ChirpError(410,'chirp_expired');
  if(!await ready(sender,v.recipientId))throw new ChirpError(403,'chirp_request_required');
  if(v.chirpType==='LOCATION'&&!(await pref(sender)).locationEnabled)throw new ChirpError(403,'location_sharing_disabled');
  const bytes=Buffer.from(v.payloadBase64??'','base64');
  if(v.chirpType==='LOCATION'){if(!v.location||v.payloadBase64||v.mimeType)throw new ChirpError(400,'invalid_location');}
  else{const photo=v.chirpType==='PHOTO',voice=v.chirpType==='VOICE';if(v.location||!v.payloadBase64||bytes.toString('base64')!==v.payloadBase64||bytes.length<16||bytes.length>(photo||voice?524288:6291456)||v.mimeType!==(photo?'image/jpeg':voice?'audio/mp4':'video/mp4')||(photo?!validCloudMedia(bytes,'image/jpeg'):bytes.toString('ascii',4,8)!=='ftyp')||(!photo&&(v.durationMs<100||v.durationMs>(voice?60000:15000))))throw new ChirpError(400,'invalid_chirp_media');if(!photo){const actual=mediaDuration(bytes);if(actual===null||actual<100||actual>(voice?60500:15500)||Math.abs(actual-v.durationMs)>1500)throw new ChirpError(400,'invalid_chirp_duration');}}
  if(v.replyToChirpId){const reply=await find(v.replyToChirpId,sender);if(![reply.senderId,reply.recipientId].includes(v.recipientId))throw new ChirpError(403,'invalid_reply');}
  const fingerprint=createHash('sha256').update(JSON.stringify(v)).digest('hex'),previous=(await db.$queryRawUnsafe<Row[]>('SELECT * FROM "RecordedChirp" WHERE "id"=?',v.id))[0];
  if(previous){if(previous.senderId!==sender||previous.fingerprint!==fingerprint)throw new ChirpError(409,'chirp_conflict');if(expired(previous)||previous.deletedAtMs)throw new ChirpError(410,'chirp_unavailable');return res.json(await dto(previous,sender));}
  const usage=await db.$queryRawUnsafe<{n:bigint;bytes:bigint}[]>('SELECT COUNT(*) AS n,COALESCE(SUM("byteCount"),0) AS bytes FROM "RecordedChirp" WHERE "senderId"=? AND "storageKey" IS NOT NULL',sender);if(Number(usage[0].n)>=250||Number(usage[0].bytes)+bytes.length>250*1024*1024)throw new ChirpError(429,'chirp_storage_limit');
  const key='chirps/'+createHash('sha256').update(sender).digest('hex')+'/'+randomUUID(),payload={caption:v.caption,mimeType:v.mimeType??null,payloadBase64:v.payloadBase64??null,location:v.location??null};
  await storage!.put(key,Buffer.from(encryptString(JSON.stringify(payload),{purpose:'recorded-chirp',id:v.id,sender})),'application/octet-stream');
  try{await db.$transaction(async tx=>{await tx.$executeRawUnsafe('INSERT INTO "RecordedChirp" ("id","senderId","senderDeviceId","recipientType","recipientId","chirpType","lifetimePolicy","createdAtMs","expiresAtMs","storageKey","fingerprint","durationMs","byteCount","replyToChirpId") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',v.id,sender,v.senderDeviceId,v.recipientType,v.recipientId,v.chirpType,v.lifetimePolicy,created,expires,key,fingerprint,v.durationMs,bytes.length,v.replyToChirpId??null);await tx.$executeRawUnsafe('INSERT INTO "RecordedChirpReceipt" ("chirpId","userId") VALUES (?,?)',v.id,v.recipientId);});}catch(e){await storage!.delete(key).catch(()=>undefined);throw e;}
  const r=(await db.$queryRawUnsafe<Row[]>('SELECT * FROM "RecordedChirp" WHERE "id"=?',v.id))[0];void deps.alerts?.sendRecordedChirp({userId:v.recipientId,chirpId:v.id,expiresAtMs:expires}).catch(()=>undefined);res.status(201).json(await dto(r,sender));
 }));
 router.post('/:id/delivered',wrap(async(req,res)=>{const r=await find(id.parse(req.params.id),uid(req));if(r.recipientId!==uid(req))throw new ChirpError(404,'chirp_unavailable');await db.$executeRawUnsafe('UPDATE "RecordedChirpReceipt" SET "deliveredAtMs"=COALESCE("deliveredAtMs",?) WHERE "chirpId"=? AND "userId"=?',now(),r.id,uid(req));res.json({ok:true});}));
 router.get('/:id/preview',wrap(async(req,res)=>{
  const viewer=uid(req),r=await find(id.parse(req.params.id),viewer),q=await receipt(r.id);
  if(r.chirpType!=='PHOTO'||r.lifetimePolicy==='VIEW_ONCE'||r.deletedAtMs||expired(r)||!r.storageKey||(r.recipientId===viewer&&q?.hiddenAtMs!=null))throw new ChirpError(404,'preview_unavailable');
  const object=await storage!.read(r.storageKey);if(!object)throw new ChirpError(404,'preview_unavailable');const chunks:Buffer[]=[];let count=0;
  for await(const chunk of object.stream){const b=Buffer.from(chunk);count+=b.length;if(count>1000000){object.stream.destroy();throw new ChirpError(503,'invalid_stored_chirp');}chunks.push(b);}
  const payload=JSON.parse(decryptString(Buffer.concat(chunks).toString(),{purpose:'recorded-chirp',id:r.id,sender:r.senderId}));
  if(!await eligible(r.senderId,r.recipientId)||expired(r))throw new ChirpError(410,'chirp_unavailable');
  res.json({payloadBase64:payload.payloadBase64});
 }));
 router.post('/:id/open',writes,wrap(async(req,res)=>{
  const viewer=uid(req),r=await find(id.parse(req.params.id),viewer),q=await receipt(r.id);if((r.senderId===viewer&&r.lifetimePolicy==='VIEW_ONCE')||(r.recipientId===viewer&&q?.hiddenAtMs!=null)||r.deletedAtMs||expired(r)||!r.storageKey||r.lifetimePolicy==='VIEW_ONCE'&&q?.consumedAtMs!=null)throw new ChirpError(410,'chirp_unavailable');
  const object=await storage!.read(r.storageKey);if(!object)throw new ChirpError(410,'chirp_unavailable');const chunks:Buffer[]=[];let count=0;for await(const chunk of object.stream){const b=Buffer.from(chunk);count+=b.length;if(count>13000000){object.stream.destroy();throw new ChirpError(503,'invalid_stored_chirp');}chunks.push(b);}
  const payload=JSON.parse(decryptString(Buffer.concat(chunks).toString(),{purpose:'recorded-chirp',id:r.id,sender:r.senderId}));
  if(!await eligible(r.senderId,r.recipientId)||expired(r))throw new ChirpError(410,'chirp_unavailable');
  if(r.senderId===viewer){res.json(payload);return;}
  const changed=await db.$executeRawUnsafe('UPDATE "RecordedChirpReceipt" SET "deliveredAtMs"=COALESCE("deliveredAtMs",?),"openedAtMs"=COALESCE("openedAtMs",?),"consumedAtMs"=CASE WHEN ?=\'VIEW_ONCE\' THEN ? ELSE "consumedAtMs" END WHERE "chirpId"=? AND "userId"=? AND "hiddenAtMs" IS NULL AND (?!=\'VIEW_ONCE\' OR "consumedAtMs" IS NULL) AND EXISTS (SELECT 1 FROM "RecordedChirp" WHERE "id"=? AND "deletedAtMs" IS NULL AND "storageKey" IS NOT NULL AND ("expiresAtMs" IS NULL OR "expiresAtMs">?))',now(),now(),r.lifetimePolicy,now(),r.id,viewer,r.lifetimePolicy,r.id,now());
  if(changed!==1)throw new ChirpError(410,'chirp_unavailable');
  // View Once access is atomically consumed above. Cleanup retains metadata until storage deletion succeeds.
  if(r.lifetimePolicy==='VIEW_ONCE')void cleanup().catch(()=>undefined);
  res.json(payload);
 }));
 router.post('/:id/played',wrap(async(req,res)=>{const r=await find(id.parse(req.params.id),uid(req)),q=await receipt(r.id);if(r.recipientId!==uid(req)||r.chirpType!=='VOICE'||!q?.openedAtMs||r.deletedAtMs!=null||expired(r))throw new ChirpError(404,'chirp_unavailable');await db.$executeRawUnsafe('UPDATE "RecordedChirpReceipt" SET "playedAtMs"=COALESCE("playedAtMs",?) WHERE "chirpId"=? AND "userId"=?',now(),r.id,uid(req));res.json({ok:true});}));
 router.post('/:id/reaction',writes,wrap(async(req,res)=>{const r=await find(id.parse(req.params.id),uid(req));if(r.recipientId!==uid(req)||expired(r))throw new ChirpError(404,'chirp_unavailable');const reaction=z.enum(['heart','laugh','thumbsUp','wow']).nullable().parse(req.body?.reaction);await db.$executeRawUnsafe('UPDATE "RecordedChirpReceipt" SET "reaction"=? WHERE "chirpId"=? AND "userId"=?',reaction,r.id,uid(req));res.json({ok:true});}));
 router.delete('/:id',writes,wrap(async(req,res)=>{const r=await find(id.parse(req.params.id),uid(req));if(r.senderId===uid(req)){await db.$executeRawUnsafe('UPDATE "RecordedChirp" SET "deletedAtMs"=? WHERE "id"=?',now(),r.id);await cleanup();}else await db.$executeRawUnsafe('UPDATE "RecordedChirpReceipt" SET "hiddenAtMs"=? WHERE "chirpId"=? AND "userId"=?',now(),r.id,uid(req));res.status(204).end();}));
 return router;
}
