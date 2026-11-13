import express, {type RequestHandler} from "express";
import type {PrismaClient} from "@prisma/client";
import multer from "multer";
import rateLimit from "express-rate-limit";
import {z} from "zod";
import {randomUUID,createHash} from "node:crypto";
import {statfs} from "node:fs/promises";
import type {ObjectStorage} from "../lib/storage/ObjectStorage";
import {LocalObjectStorage} from "../lib/storage/LocalObjectStorage";
import {S3ObjectStorage} from "../lib/storage/S3ObjectStorage";
import {approvedContacts,ghostMode,mayCommunicate} from "../services/AccountVisibility";
import {encryptString,decryptString,isFieldEncryptionEnabled} from "../services/privacy/EncryptionService";
import type {LiveKitTokenService} from "../services/LiveKitTokenService";
import {validCloudMedia} from "./cloudMedia";
import {recordAuditEvent} from "../services/audit/AuditEventService";

const id=z.string().uuid().transform(s=>s.toLowerCase());
const visibility=z.enum(["onlyMe","friends","everyone"]);
const storyInput=z.object({id,caption:z.string().trim().max(2000).default(""),visibility:visibility.default("friends")}).strict();
const liveInput=z.object({title:z.string().trim().min(1).max(100),visibility:z.enum(["friends","everyone"]).default("friends")}).strict();
const ttl=86400000,maxBytes=20*1024*1024;
type Story={id:string;ownerId:string;visibility:string;storageKey:string;fingerprint:string;mediaType:string|null;mimeType:string|null;byteCount:number;createdAtMs:bigint;expiresAtMs:bigint};
type Live={id:string;ownerId:string;titleCiphertext:string;visibility:string;state:string;startedAtMs:bigint;leaseUntilMs:bigint;endedAtMs:bigint|null};
class StoryError extends Error {constructor(readonly status:number,readonly code:string){super(code);}}
export function storiesRouter(deps:{db:PrismaClient;authenticate:RequestHandler;tokens:Pick<LiveKitTokenService,"isConfigured"|"issue"|"deleteRoom"|"removeParticipant">;storage?:ObjectStorage|null;clock?:()=>number}) {
 const {db,tokens}=deps,now=deps.clock??Date.now,router=express.Router();
 const storage=deps.storage===undefined?(process.env.ONEWAY_PRIVATE_CLOUD_DIR?new LocalObjectStorage({root:process.env.ONEWAY_PRIVATE_CLOUD_DIR}):S3ObjectStorage.fromEnv()):deps.storage;
 const uid=(req:express.Request)=>(req as express.Request&{userId:string}).userId;
 const wrap=(fn:(req:express.Request,res:express.Response)=>Promise<unknown>):RequestHandler=>(req,res)=>{fn(req,res).catch(e=>{
  if(e instanceof z.ZodError){res.status(400).json({error:"invalid_story"});return;}
  res.status(e instanceof StoryError?e.status:503).json({error:e instanceof StoryError?e.code:"stories_unavailable"});
 });};
 const closingRooms=new Set<string>();
 const room=(sessionId:string)=>"oneway-live-"+sessionId;
 async function publicAllowed(owner:string){return !await ghostMode(db,owner)&&Boolean(await db.socialProfile.findFirst({where:{userId:owner,discoverable:true}}));}
 async function visible(owner:string,scope:string,viewer:string){
  if(!await db.user.findFirst({where:{id:owner,accountStatus:"active",publicProfileHiddenAt:null},select:{id:true}}))return false;
  if(owner===viewer)return true;
  const blocked=await db.oneWayContact.count({where:{status:"blocked",OR:[{userId:owner,contactUserId:viewer},{userId:viewer,contactUserId:owner}]}})+await db.socialBlock.count({where:{OR:[{blockerId:owner,blockedId:viewer},{blockerId:viewer,blockedId:owner}]}});
  if(blocked)return false;
  if(scope==="everyone")return publicAllowed(owner);
  return scope==="friends"&&(await approvedContacts(db,owner)).includes(viewer)&&await mayCommunicate(db,owner,viewer);
 }
 async function mayPublish(owner:string,scope:string){if(scope==="everyone"&&!await publicAllowed(owner))throw new StoryError(403,"public_profile_required");}
 async function name(owner:string){return (await db.socialProfile.findUnique({where:{userId:owner},select:{displayName:true}}))?.displayName||(await db.user.findUnique({where:{id:owner},select:{displayName:true}}))?.displayName||"OneWay contact";}
 async function storyDTO(s:Story,viewer:string){return {id:s.id,authorId:s.ownerId,authorDisplayName:await name(s.ownerId),caption:"",visibility:s.visibility,mediaType:s.mediaType,createdAt:new Date(Number(s.createdAtMs)).toISOString(),expiresAt:new Date(Number(s.expiresAtMs)).toISOString(),isMine:s.ownerId===viewer};}
 async function liveDTO(s:Live,viewer:string){
  const count=await db.$queryRawUnsafe<{n:bigint}[]>(`SELECT COUNT(*) AS n FROM "LiveStoryViewer" WHERE "sessionId"=? AND "lastSeenMs">?`,s.id,now()-30000);
  return {id:s.id,authorId:s.ownerId,authorDisplayName:await name(s.ownerId),title:decryptString(s.titleCiphertext,{purpose:"live-title",id:s.id,owner:s.ownerId}),visibility:s.visibility,state:s.state,startedAt:new Date(Number(s.startedAtMs)).toISOString(),isMine:s.ownerId===viewer,viewerCount:Number(count[0]?.n??0)};
 }
 async function findLive(sessionId:string){return (await db.$queryRawUnsafe<Live[]>(`SELECT * FROM "LiveStorySession" WHERE "id"=?`,sessionId))[0];}
 async function expire(){
  if(storage){const old=await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "expiresAtMs"<=? OR "ownerId" NOT IN (SELECT "id" FROM "User" WHERE "accountStatus"='active' AND "publicProfileHiddenAt" IS NULL) LIMIT 50`,now());
   for(const s of old)try{await storage.delete(s.storageKey);await db.$executeRawUnsafe(`DELETE FROM "SocialStory" WHERE "id"=?`,s.id);}catch{/*retain cleanup metadata for retry*/}
  }
  await db.$executeRawUnsafe(`UPDATE "LiveStorySession" SET "state"='ended',"activeOwnerId"=NULL,"endedAtMs"=? WHERE "state"!='ended' AND ("leaseUntilMs"<=? OR "startedAtMs"<=? OR "ownerId" NOT IN (SELECT "id" FROM "User" WHERE "accountStatus"='active' AND "publicProfileHiddenAt" IS NULL))`,now(),now(),now()-7200000);
  const ended=await db.$queryRawUnsafe<Live[]>(`SELECT * FROM "LiveStorySession" WHERE "state"='ended' AND "endedAtMs">? LIMIT 50`,now()-60000);
  for(const s of ended)if(!closingRooms.has(s.id)){
   closingRooms.add(s.id);void tokens.deleteRoom(room(s.id)).catch(()=>undefined).finally(()=>closingRooms.delete(s.id));
  }
  await db.$executeRawUnsafe(`DELETE FROM "LiveStorySession" WHERE "state"='ended' AND "endedAtMs"<?`,now()-86400000);
 }
 const cleanup=setInterval(()=>{void expire().catch(()=>undefined);},15000);cleanup.unref();
 router.get("/status",(_req,res)=>res.json({stories:Boolean(storage)&&isFieldEncryptionEnabled(),live:tokens.isConfigured()&&isFieldEncryptionEnabled(),version:1}));
 router.use(deps.authenticate);
 router.use((_req,res,next)=>{res.set({"Cache-Control":"private, no-store, max-age=0","Pragma":"no-cache","X-Content-Type-Options":"nosniff"});next();});
 router.use((req,res,next)=>{(async()=>{
  if(!isFieldEncryptionEnabled())throw new StoryError(503,"stories_unavailable");
  if(!await db.user.findFirst({where:{id:uid(req),accountStatus:"active",publicProfileHiddenAt:null},select:{id:true}}))throw new StoryError(401,"account_not_active");
  await expire();next();
 })().catch(e=>res.status(e instanceof StoryError?e.status:503).json({error:e instanceof StoryError?e.code:"stories_unavailable"}));});
 const writes=rateLimit({windowMs:60000,limit:20,standardHeaders:true,legacyHeaders:false,keyGenerator:req=>uid(req)});
 const upload=multer({storage:multer.memoryStorage(),limits:{fileSize:maxBytes,files:1,fields:3,fieldSize:9000}});
 router.get("/",wrap(async(req,res)=>{
  const viewer=uid(req),all=await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "expiresAtMs">? ORDER BY "createdAtMs" DESC LIMIT 300`,now());
  const stories=[];for(const s of all)if(await visible(s.ownerId,s.visibility,viewer))stories.push(await storyDTO(s,viewer));
  const sessions=await db.$queryRawUnsafe<Live[]>(`SELECT * FROM "LiveStorySession" WHERE "state"='live' AND "leaseUntilMs">? ORDER BY "startedAtMs" DESC LIMIT 100`,now());
  const live=[];for(const s of sessions)if(await visible(s.ownerId,s.visibility,viewer))live.push(await liveDTO(s,viewer));
  res.json({stories,live});
 }));
 router.post("/",writes,(req,res,next)=>{
  if(!storage){res.status(503).json({error:"stories_unavailable"});return;}
  upload.single("file")(req,res,e=>{if(e){res.status(e instanceof multer.MulterError&&e.code==="LIMIT_FILE_SIZE"?413:400).json({error:"invalid_story_media"});return;}next();});
 },wrap(async(req,res)=>{
  const value=storyInput.parse(req.body),owner=uid(req),file=req.file;
  if(!file&&!value.caption)throw new StoryError(400,"story_content_required");
  if(file&&!["image/jpeg","image/png","video/mp4","video/quicktime"].includes(file.mimetype))throw new StoryError(400,"invalid_story_media");
  if(file&&!validCloudMedia(file.buffer,file.mimetype))throw new StoryError(400,"invalid_story_media");
  await mayPublish(owner,value.visibility);
  const fingerprint=createHash("sha256").update(JSON.stringify([value.caption,value.visibility,file?.mimetype??null])).update(file?.buffer??Buffer.alloc(0)).digest("hex");
  const previous=(await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "id"=?`,value.id))[0];
  if(previous){if(previous.ownerId!==owner||previous.fingerprint!==fingerprint)throw new StoryError(409,"story_conflict");return res.json(await storyDTO(previous,owner));}
  const usage=await db.$queryRawUnsafe<{n:bigint;bytes:bigint}[]>(`SELECT COUNT(*) AS n,COALESCE(SUM("byteCount"),0) AS bytes FROM "SocialStory" WHERE "ownerId"=? AND "expiresAtMs">?`,owner,now());
  if(Number(usage[0].n)>=25||Number(usage[0].bytes)+(file?.size??0)>150*1024*1024)throw new StoryError(429,"story_limit");
  if(process.env.ONEWAY_PRIVATE_CLOUD_DIR){const disk=await statfs(process.env.ONEWAY_PRIVATE_CLOUD_DIR);if(disk.bavail*disk.bsize<512*1024*1024+(file?.size??0)*2)throw new StoryError(503,"story_storage_busy");}
  const key=`stories/${createHash("sha256").update(owner).digest("hex")}/${randomUUID()}`;
  const payload={caption:value.caption,media:file?{mediaType:file.mimetype.startsWith("image/")?"photo":"video",fileName:file.originalname.replace(/[\x00-\x1f/\\]/g,"_").slice(0,120),mimeType:file.mimetype,byteCount:file.size,payloadBase64:file.buffer.toString("base64")}:null};
  const encrypted=encryptString(JSON.stringify(payload),{purpose:"story",id:value.id,owner});await storage!.put(key,Buffer.from(encrypted),"application/octet-stream");
  const time=now();try{await db.$executeRawUnsafe(`INSERT INTO "SocialStory" ("id","ownerId","visibility","storageKey","fingerprint","mediaType","mimeType","byteCount","createdAtMs","expiresAtMs") VALUES (?,?,?,?,?,?,?,?,?,?)`,value.id,owner,value.visibility,key,fingerprint,payload.media?.mediaType??null,file?.mimetype??null,file?.size??0,time,time+ttl);}catch(e){await storage!.delete(key).catch(()=>undefined);throw e;}
  const s=(await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "id"=?`,value.id))[0];res.status(201).json(await storyDTO(s,owner));
 }));
 router.get("/:id/content",wrap(async(req,res)=>{
  const s=(await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "id"=? AND "expiresAtMs">?`,id.parse(req.params.id),now()))[0];
  if(!s||!storage||!await visible(s.ownerId,s.visibility,uid(req)))throw new StoryError(404,"story_not_found");
  const object=await storage.read(s.storageKey);if(!object)throw new StoryError(404,"story_not_found");
  const chunks:Buffer[]=[];let bytes=0;for await(const chunk of object.stream){const b=Buffer.from(chunk);bytes+=b.length;if(bytes>maxBytes*2+16384){object.stream.destroy();throw new StoryError(503,"story_media_invalid");}chunks.push(b);}
  const content=JSON.parse(decryptString(Buffer.concat(chunks).toString(),{purpose:"story",id:s.id,owner:s.ownerId}));
  if(Number(s.expiresAtMs)<=now()||!await visible(s.ownerId,s.visibility,uid(req)))throw new StoryError(404,"story_not_found");
  res.json(content);
 }));
 router.delete("/mine",writes,wrap(async(req,res)=>{
  const rows=await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "ownerId"=?`,uid(req));
  for(const s of rows){await storage?.delete(s.storageKey);await db.$executeRawUnsafe(`DELETE FROM "SocialStory" WHERE "id"=?`,s.id);}res.status(204).end();
 }));
 router.delete("/:id",writes,wrap(async(req,res)=>{
  const s=(await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "id"=? AND "ownerId"=?`,id.parse(req.params.id),uid(req)))[0];
  if(!s)throw new StoryError(404,"story_not_found");await storage?.delete(s.storageKey);await db.$executeRawUnsafe(`DELETE FROM "SocialStory" WHERE "id"=?`,s.id);res.status(204).end();
 }));
 router.post("/live",writes,wrap(async(req,res)=>{
  if(!tokens.isConfigured())throw new StoryError(503,"live_not_configured");
  const value=liveInput.extend({id}).parse(req.body),owner=uid(req);await mayPublish(owner,value.visibility);
  const existing=await findLive(value.id);
  if(existing){if(existing.ownerId!==owner||existing.visibility!==value.visibility||decryptString(existing.titleCiphertext,{purpose:"live-title",id:existing.id,owner})!==value.title||existing.state==="ended")throw new StoryError(409,"live_conflict");return res.json(await liveDTO(existing,owner));}
  const active=await db.$queryRawUnsafe<Live[]>(`SELECT * FROM "LiveStorySession" WHERE "ownerId"=? AND "state"!='ended' AND "leaseUntilMs">?`,owner,now());
  if(active.length)throw new StoryError(409,"already_live");
  const encrypted=encryptString(value.title,{purpose:"live-title",id:value.id,owner});
  await db.$executeRawUnsafe(`INSERT INTO "LiveStorySession" ("id","ownerId","activeOwnerId","titleCiphertext","visibility","state","startedAtMs","leaseUntilMs") VALUES (?,?,?,?,?,'starting',?,?)`,value.id,owner,owner,encrypted,value.visibility,now(),now()+60000);
  res.status(201).json(await liveDTO((await findLive(value.id))!,owner));
 }));
 async function readableLive(sessionId:string,viewer:string){
  const s=await findLive(sessionId);
  if(!s||s.state==="ended"||Number(s.leaseUntilMs)<=now()||Number(s.startedAtMs)+7200000<=now()||!await visible(s.ownerId,s.visibility,viewer))throw new StoryError(404,"live_ended");
  if(s.state!=="live"&&s.ownerId!==viewer)throw new StoryError(404,"live_not_started");
  if(s.visibility==="everyone"&&!await publicAllowed(s.ownerId)){
   await db.$executeRawUnsafe(`UPDATE "LiveStorySession" SET "state"='ended',"activeOwnerId"=NULL,"endedAtMs"=? WHERE "id"=?`,now(),s.id);await tokens.deleteRoom(room(s.id));throw new StoryError(404,"live_ended");
  }
  return s;
 }
 router.post("/live/:id/join",writes,wrap(async(req,res)=>{
  const viewer=uid(req),s=await readableLive(id.parse(req.params.id),viewer),host=s.ownerId===viewer;
  const identity=host?"host-"+s.ownerId:"viewer-"+createHash("sha256").update(s.id+":"+viewer).digest("hex").slice(0,32);
  if(!host){
   const count=await db.$queryRawUnsafe<{n:bigint}[]>(`SELECT COUNT(*) AS n FROM "LiveStoryViewer" WHERE "sessionId"=? AND "lastSeenMs">? AND "userId"!=?`,s.id,now()-30000,viewer);
   if(Number(count[0].n)>=100)throw new StoryError(429,"live_audience_full");
   await db.$executeRawUnsafe(`INSERT INTO "LiveStoryViewer" ("sessionId","userId","identity","lastSeenMs") VALUES (?,?,?,?) ON CONFLICT("sessionId","userId") DO UPDATE SET "lastSeenMs"=excluded."lastSeenMs"`,s.id,viewer,identity,now());
  }
  const token=await tokens.issue({roomName:room(s.id),identity,displayName:host?await name(s.ownerId):"Viewer",canPublish:host,canPublishData:false,ttlSeconds:30});
  res.json({...token,isHost:host,hostIdentity:"host-"+s.ownerId,session:await liveDTO(s,viewer)});
 }));
 router.get("/live/:id",wrap(async(req,res)=>{
  const s=await readableLive(id.parse(req.params.id),uid(req));
  if(s.ownerId!==uid(req))await db.$executeRawUnsafe(`UPDATE "LiveStoryViewer" SET "lastSeenMs"=? WHERE "sessionId"=? AND "userId"=?`,now(),s.id,uid(req));
  res.json(await liveDTO(s,uid(req)));
 }));
 router.post("/live/:id/heartbeat",wrap(async(req,res)=>{
  const s=await readableLive(id.parse(req.params.id),uid(req));if(s.ownerId!==uid(req))throw new StoryError(403,"host_only");
  await db.$executeRawUnsafe(`UPDATE "LiveStorySession" SET "state"='live',"leaseUntilMs"=? WHERE "id"=? AND "state"!='ended'`,Math.min(now()+60000,Number(s.startedAtMs)+7200000),s.id);
  const viewers=await db.$queryRawUnsafe<{userId:string;identity:string}[]>(`SELECT "userId","identity" FROM "LiveStoryViewer" WHERE "sessionId"=?`,s.id);
  for(const viewer of viewers)if(!await visible(s.ownerId,s.visibility,viewer.userId)){
   try{await tokens.removeParticipant(room(s.id),viewer.identity);await db.$executeRawUnsafe(`DELETE FROM "LiveStoryViewer" WHERE "sessionId"=? AND "userId"=?`,s.id,viewer.userId);}catch{/*retry revocation on heartbeat*/}
  }
  res.json(await liveDTO((await findLive(s.id))!,uid(req)));
 }));
 router.post("/live/:id/end",writes,wrap(async(req,res)=>{
  const s=await findLive(id.parse(req.params.id));if(!s||s.ownerId!==uid(req))throw new StoryError(404,"live_not_found");
  await db.$executeRawUnsafe(`UPDATE "LiveStorySession" SET "state"='ended',"activeOwnerId"=NULL,"endedAtMs"=? WHERE "id"=?`,now(),s.id);
  await tokens.deleteRoom(room(s.id));res.json({ok:true});
 }));
 router.post("/:kind/:id/report",writes,wrap(async(req,res)=>{
  const kind=z.enum(["story","live"]).parse(req.params.kind),resourceId=id.parse(req.params.id),reason=z.enum(["spam","harassment","harmful_content","other"]).parse(req.body?.reason);
  const row=kind==="live"?await findLive(resourceId):(await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "id"=? AND "expiresAtMs">?`,resourceId,now()))[0];
  if(!row||!await visible(row.ownerId,row.visibility,uid(req)))throw new StoryError(404,"story_not_found");
  const event=await recordAuditEvent(db,{actorId:uid(req),actorType:"user",action:"safety.report.created",resourceType:kind==="live"?"live_broadcast":"story",resourceId,metadata:{reason,ownerId:row.ownerId,reviewStatus:"pending"}});
  res.status(201).json({ok:true,reportId:event.id});
 }));
 router.post("/:kind/:id/block",writes,wrap(async(req,res)=>{
  const kind=z.enum(["story","live"]).parse(req.params.kind),resourceId=id.parse(req.params.id),viewer=uid(req);
  const row=kind==="live"?await findLive(resourceId):(await db.$queryRawUnsafe<Story[]>(`SELECT * FROM "SocialStory" WHERE "id"=? AND "expiresAtMs">?`,resourceId,now()))[0];
  if(!row||row.ownerId===viewer||!await visible(row.ownerId,row.visibility,viewer))throw new StoryError(404,"story_not_found");
  await db.oneWayContact.upsert({where:{userId_contactUserId:{userId:viewer,contactUserId:row.ownerId}},create:{userId:viewer,contactUserId:row.ownerId,status:"blocked",direction:"blocked",blockedAt:new Date()},update:{status:"blocked",direction:"blocked",blockedAt:new Date()}});
  if(kind==="live")try{const identity="viewer-"+createHash("sha256").update(resourceId+":"+viewer).digest("hex").slice(0,32);await tokens.removeParticipant(room(resourceId),identity);}catch{/*new access is denied immediately; heartbeat retries removal*/}
  res.json({ok:true});
 }));
 return router;
}
