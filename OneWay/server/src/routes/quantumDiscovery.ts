import express, {type RequestHandler} from "express";
import type {PrismaClient} from "@prisma/client";
import {z} from "zod";
import rateLimit from "express-rate-limit";
import {ghostUsers} from "../services/AccountVisibility";
import {decryptString} from "../services/privacy/EncryptionService";

export const quantumTypes = ["people","posts","video","communities","shops","sites","live"] as const;
export type QuantumType = typeof quantumTypes[number];
export interface QuantumResult {
  id:string; type:QuantumType; title:string; subtitle:string; source:string;
  privacyClass:"public"|"memberMetadata"; destination:string; relevanceScore:number;
  userId?:string; handle?:string; relationshipContext?:string; actionSet:string[];
  createdAt?:string; expiresAt?:string; liveState?:string;
}
const input=z.object({type:z.enum(quantumTypes),q:z.string().trim().min(1).max(100),limit:z.coerce.number().int().min(1).max(50).default(20),offset:z.coerce.number().int().min(0).max(1000).default(0)});
const active={accountStatus:"active",publicProfileHiddenAt:null};
/** Metadata-only indexes. No private conversation, encrypted title, or message-body index. */
export async function ensureQuantumDiscoveryIndexes(db:PrismaClient) {
  const statements=[
    `CREATE INDEX IF NOT EXISTS "Quantum_profile_discovery" ON "SocialProfile"("discoverable","handle")`,
    `CREATE INDEX IF NOT EXISTS "Quantum_shop_discovery" ON "Storefront"("published","status","searchable","publicVisible")`,
    `CREATE INDEX IF NOT EXISTS "Quantum_video_expiry" ON "SocialStory"("visibility","mediaType","expiresAtMs")`,
    `CREATE INDEX IF NOT EXISTS "Quantum_live_visibility" ON "LiveStorySession"("visibility","state","leaseUntilMs")`
  ];
  // Optional providers may have no table yet. Their individual endpoint reports unavailable.
  for(const sql of statements) try { await db.$executeRawUnsafe(sql); } catch { /* source-specific status handles absent provider schema */ }
}
export function quantumDiscoveryRouter(deps:{db:PrismaClient;authenticate:RequestHandler;clock?:()=>number}) {
 const {db}=deps,now=deps.clock??Date.now,router=express.Router();
 router.get("/status",(_req,res)=>res.json({enabled:true,version:1,types:quantumTypes,privateCommunicationIndexed:false,web:"browser-handoff"}));
 router.use(deps.authenticate);
 router.use((_req,res,next)=>{res.set({"Cache-Control":"private, no-store, max-age=0","Pragma":"no-cache","X-Content-Type-Options":"nosniff"});next();});
 router.use(rateLimit({windowMs:60000,limit:180,standardHeaders:true,legacyHeaders:false,keyGenerator:req=>(req as any).userId,message:{error:"search_rate_limited"}}));
 const uid=(req:express.Request)=>(req as express.Request&{userId:string}).userId;
 const wrap=(fn:(req:express.Request,res:express.Response)=>Promise<unknown>):RequestHandler=>(req,res)=>{void fn(req,res).catch(e=>{res.status(e instanceof z.ZodError?400:503).json({error:e instanceof z.ZodError?"invalid_search":"provider_unavailable"});});};
 async function context(viewer:string) {
  const valid=await db.user.findFirst({where:{id:viewer,...active},select:{id:true}});
  if(!valid)return null;
  // Read relationship states, never conversation contents.
  const [social,contacts,friends,hidden,following,shopBlocks,inactive]=await Promise.all([
   db.socialBlock.findMany({where:{OR:[{blockerId:viewer},{blockedId:viewer}]}}),
   db.oneWayContact.findMany({where:{OR:[{userId:viewer},{contactUserId:viewer}],status:{in:["blocked","connected"]}},select:{userId:true,contactUserId:true,status:true}}),
   db.friendship.findMany({where:{OR:[{requesterUserId:viewer},{recipientUserId:viewer}],status:{in:["blocked","accepted","connected"]}},select:{requesterUserId:true,recipientUserId:true,status:true}}),
   ghostUsers(db),db.socialFollow.findMany({where:{followerId:viewer},select:{followingId:true}}),
   db.shopBlockedUser.findMany({where:{OR:[{userId:viewer},{blockedUserId:viewer}]},select:{userId:true,blockedUserId:true}}),
   db.user.findMany({where:{OR:[{accountStatus:{not:"active"}},{publicProfileHiddenAt:{not:null}}]},select:{id:true}})
  ]);
  const blocked=new Set(social.map(b=>b.blockerId===viewer?b.blockedId:b.blockerId));
  for(const b of contacts)if(b.status==="blocked")blocked.add(b.userId===viewer?b.contactUserId:b.userId);
  for(const b of friends)if(b.status==="blocked")blocked.add(b.requesterUserId===viewer?b.recipientUserId:b.requesterUserId);
  for(const b of shopBlocks)blocked.add(b.userId===viewer?b.blockedUserId:b.userId);
  for(const user of inactive)blocked.add(user.id);
  const related=new Map<string,string>();
  for(const f of following)related.set(f.followingId,"Following");
  for(const c of contacts)if(c.userId===viewer&&c.status==="connected")related.set(c.contactUserId,"Your contact");
  for(const f of friends)if(f.status!=="blocked")related.set(f.requesterUserId===viewer?f.recipientUserId:f.requesterUserId,"Friend");
  return {blocked:[...blocked],hidden,related};
 }
 async function search(viewer:string,type:QuantumType,q:string,limit:number,offset:number,id?:string):Promise<QuantumResult[]|null>{
  const ctx=await context(viewer);if(!ctx)return null;
  const excluded=[...new Set([...ctx.blocked,...ctx.hidden])];
  const result=(objectId:string,title:string,subtitle:string,extra:Partial<QuantumResult>={}):QuantumResult=>({id:objectId,type,title,subtitle,source:"OneWay",privacyClass:"public",destination:`oneway://${type==="people"?"profile":type==="communities"?"community":type==="shops"?"shop":type==="sites"?"site":type==="posts"?"post":type}/${encodeURIComponent(objectId)}`,relevanceScore:0,actionSet:["open"],...extra});
  let items:QuantumResult[]=[];
  if(type==="people"){
   const profiles=await db.socialProfile.findMany({where:{user:{...active},discoverable:true,userId:{notIn:excluded},...(id?{AND:[{userId:id}]}:{OR:[{handle:{contains:q.replace(/^@/,"").toLowerCase()}},{displayName:{contains:q}}]})},select:{userId:true,handle:true,displayName:true,bio:true,updatedAt:true},orderBy:[{handle:"asc"}],take:limit,skip:offset});
   items=profiles.map(p=>result(p.userId,p.displayName,"@"+p.handle,{userId:p.userId,handle:p.handle,relationshipContext:ctx.related.get(p.userId),actionSet:["open","message","chirp","call","video"],createdAt:p.updatedAt.toISOString()}));
  }else if(type==="posts"){
   const posts=await db.socialPost.findMany({where:{audience:"public",author:{discoverable:true,userId:{notIn:excluded},user:active},...(id?{id}:{body:{contains:q}})},select:{id:true,body:true,createdAt:true,author:{select:{userId:true,handle:true,displayName:true}}},orderBy:[{createdAt:"desc"},{id:"desc"}],take:limit,skip:offset});
   items=posts.map(p=>result(p.id,p.body.slice(0,200),p.author.displayName+" · Public post",{userId:p.author.userId,handle:p.author.handle,createdAt:p.createdAt.toISOString()}));
  }else if(type==="communities"){
   const rows=await db.community.findMany({where:{deletedAt:null,ownerId:{notIn:ctx.blocked},AND:[{OR:[{visibility:"public"},{ownerId:viewer},{members:{some:{userId:viewer}}}]},id?{id}:{OR:[{name:{contains:q}},{description:{contains:q}},{normalizedName:{contains:q.toLowerCase()}}]}]},include:{members:{where:{userId:viewer},select:{userId:true}}},orderBy:[{updatedAt:"desc"},{id:"asc"}],take:limit,skip:offset});
   for(const c of rows){
    const lists=[c.blockedUserIdsJson,c.bannedUserIdsJson];let denied=false;
    for(const value of lists){try{const a=JSON.parse(value);if(!Array.isArray(a)||a.includes(viewer))denied=true;}catch{denied=true;}}
    if(denied)continue;
    const member=c.ownerId===viewer||c.members.length>0;
    items.push(result(c.id,c.name,c.description.slice(0,180),{privacyClass:c.visibility==="public"?"public":"memberMetadata",relationshipContext:member?"Member":undefined,createdAt:c.updatedAt.toISOString()}));
   }
  }else if(type==="shops"){
   const shops=await db.storefront.findMany({where:{published:true,status:"published",publicVisible:true,searchable:true,owner:{...active,id:{notIn:excluded}},...(id?{id}:{OR:[{name:{contains:q}},{description:{contains:q}},{handle:{contains:q.toLowerCase()}},{category:{contains:q}},{location:{contains:q}},{products:{some:{published:true,OR:[{name:{contains:q}},{description:{contains:q}}]}}}]})},select:{id:true,name:true,description:true,handle:true,updatedAt:true},orderBy:[{updatedAt:"desc"},{id:"asc"}],take:limit,skip:offset});
   items=shops.map(s=>result(s.id,s.name,s.description.slice(0,180),{handle:s.handle,createdAt:s.updatedAt.toISOString()}));
  }else if(type==="sites"){
   const sites=await db.site.findMany({where:{status:"PUBLISHED",visibility:"PUBLIC",activePublicationId:{not:null},user:{...active,id:{notIn:excluded}},...(id?{id}:{OR:[{title:{contains:q}},{description:{contains:q}},{domain:{contains:q}}]})},select:{id:true,title:true,description:true,slug:true,domain:true,activePublicationId:true,publishedAt:true},orderBy:[{publishedAt:"desc"},{id:"asc"}],take:limit,skip:offset});
   for(const s of sites){if(!await db.sitePublication.findFirst({where:{id:s.activePublicationId!,siteId:s.id,status:"ACTIVE"},select:{id:true}}))continue;
    items.push(result(s.id,s.title||s.domain,s.description.slice(0,180),{destination:`oneway://${s.slug??s.domain}`,createdAt:s.publishedAt?.toISOString()}));}
  }else if(type==="video"||type==="live"){
   const profiles=await db.socialProfile.findMany({where:{discoverable:true,userId:{notIn:excluded},user:active},select:{userId:true,handle:true,displayName:true}});
   const owners=new Map(profiles.map(p=>[p.userId,p]));
   if(type==="video"){
    // Public video Moments are the currently supported video format. No private media lookup.
    const ownerIds=profiles.filter(p=>id||`${p.displayName} ${p.handle}`.toLowerCase().includes(q.toLowerCase())).map(p=>p.userId);
    const rows=await db.socialStory.findMany({where:{visibility:"everyone",mediaType:"video",expiresAtMs:{gt:BigInt(now())},ownerId:{in:ownerIds},...(id?{id}:{})},select:{id:true,ownerId:true,createdAtMs:true,expiresAtMs:true},orderBy:[{createdAtMs:"desc"},{id:"asc"}],take:limit,skip:offset});
    items=rows.map(s=>{const p=owners.get(s.ownerId)!;return result(s.id,"Video Moment by "+p.displayName,"Public · 24-hour video",{userId:p.userId,handle:p.handle,createdAt:new Date(Number(s.createdAtMs)).toISOString(),expiresAt:new Date(Number(s.expiresAtMs)).toISOString()});});
   }else{
    const rows=await db.liveStorySession.findMany({where:{visibility:"everyone",state:"live",leaseUntilMs:{gt:BigInt(now())},startedAtMs:{gt:BigInt(now()-7200000)},ownerId:{in:[...owners.keys()]},...(id?{id}:{})},select:{id:true,ownerId:true,titleCiphertext:true,startedAtMs:true,leaseUntilMs:true},orderBy:[{startedAtMs:"desc"},{id:"asc"}],take:100});
    for(const s of rows){const p=owners.get(s.ownerId)!;let title:string;try{title=decryptString(s.titleCiphertext,{purpose:"live-title",id:s.id,owner:s.ownerId});}catch{continue;}
     if(!id&&!`${title} ${p.displayName} ${p.handle}`.toLowerCase().includes(q.toLowerCase()))continue;
     items.push(result(s.id,title,p.displayName+" · Public Live",{userId:p.userId,handle:p.handle,createdAt:new Date(Number(s.startedAtMs)).toISOString(),expiresAt:new Date(Number(s.leaseUntilMs)).toISOString(),liveState:"live"}));}
    items=items.slice(offset,offset+limit);
   }
  }
  const query=q.toLowerCase().replace(/^@/,"");
  return items.map(item=>{const title=item.title.toLowerCase(),handle=item.handle?.toLowerCase();item.relevanceScore=(title===query||handle===query?1000:title.startsWith(query)?600:300)+(item.relationshipContext?80:0)+(item.createdAt?Math.max(0,20-(now()-Date.parse(item.createdAt))/86400000):0);return item;}).sort((a,b)=>b.relevanceScore-a.relevanceScore||a.id.localeCompare(b.id));
 }
 router.get("/search",wrap(async(req,res)=>{const p=input.parse(req.query),viewer=uid(req);const started=now();const results=await search(viewer,p.type,p.q,p.limit,p.offset);if(results===null)return res.status(401).json({error:"account_not_active"});return res.json({results,hasMore:results.length===p.limit,elapsedMs:now()-started,privateCommunicationIndexed:false});}));
 router.get("/resolve/:type/:id",wrap(async(req,res)=>{const type=z.enum(quantumTypes).parse(req.params.type),id=z.string().min(1).max(128).parse(req.params.id);const results=await search(uid(req),type,"",1,0,id);if(results===null)return res.status(401).json({error:"account_not_active"});if(!results[0])return res.status(404).json({error:"result_unavailable"});return res.json({result:results[0]});}));
 return router;
}
