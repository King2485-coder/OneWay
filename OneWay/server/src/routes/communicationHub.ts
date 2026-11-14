import express from "express";
import type { PrismaClient } from "@prisma/client";
import { approvedContacts, communicationBlocked, mayCommunicate } from "../services/AccountVisibility";

import { isDirectChirpDiscoverable } from "./walkie";

type Row = {id:string;kind:string;threadId:string;peerId?:string;peerHandle?:string;title:string;preview:string;timestamp:string;unreadCount:number|null;blocked:boolean;isSeller?:boolean;shopId?:string;status?:string};
const array = (text:string|null|undefined):string[]=>{try{const a=JSON.parse(text??"[]");return Array.isArray(a)?a.filter(x=>typeof x==="string"):[];}catch{return[];}};
const iso=(date:Date|string)=>new Date(date).toISOString();
const uid=(req:express.Request)=>(req as any).userId as string;
const valid=(id:string)=>/^[A-Za-z0-9_:.\-]{1,128}$/.test(id);
export function communicationHubRouter(deps:{db:PrismaClient;authenticate:express.RequestHandler}) {
  const db=deps.db,router=express.Router();
  router.get('/status',(_req,res)=>res.json({enabled:true,version:1,security:'LEGACY_NOT_E2EE'}));
  router.use(deps.authenticate);
  router.use((_req,res,next)=>{res.setHeader('Cache-Control','no-store');next();});
  router.get('/peers/:id',async(req,res)=>{
    try {
      const owner=uid(req),peer=String(req.params.id);if(!valid(peer)||peer===owner){res.status(400).json({error:'invalid_peer'});return;}
      const [exists,blocked,contacts,friendship,following,privacy]=await Promise.all([
        db.user.findUnique({where:{id:peer},select:{id:true}}),communicationBlocked(db,owner,peer),approvedContacts(db,owner),
        db.friendship.findFirst({where:{status:'accepted',OR:[{requesterUserId:owner,recipientUserId:peer},{requesterUserId:peer,recipientUserId:owner}]},select:{id:true}}),
        db.socialFollow.findUnique({where:{followerId_followingId:{followerId:owner,followingId:peer}},select:{followingId:true}}),
        db.walkiePrivacySettings.findUnique({where:{userId:peer}})
      ]);
      const friend=Boolean(friendship),contact=contacts.includes(peer),allowed=Boolean(exists)&&!blocked&&await mayCommunicate(db,owner,peer);
      const chirp=allowed&&await isDirectChirpDiscoverable(db,owner,peer,{allowDirectChirp:privacy?.allowDirectChirp??true,directChirpAudience:privacy?.directChirpAudience??'everyone'});
      res.json({canMessage:allowed,canChirp:chirp,canCall:allowed&&(friend||contact),canVideo:allowed&&(friend||contact),unavailable:!allowed,context:blocked?'Communication unavailable':friend?'Friend':contact?'Contact':following?'Following':'OneWay member',security:'LEGACY_NOT_E2EE'});
    } catch {res.status(503).json({error:'permissions_unavailable'});}
  });
  router.get('/inbox',async(req,res)=>{
    const owner=uid(req);const rows:Row[]=[];const errors:string[]=[];
    const sources: [string,()=>Promise<Row[]>][]=[
      ['communities',async()=>{
        const memberships=await db.communityMember.findMany({where:{userId:owner,community:{deletedAt:null}},include:{community:{include:{messages:{orderBy:{createdAt:'desc'},take:1,select:{id:true,createdAt:true}}}}},take:100});
        const watermarks=await db.$queryRawUnsafe<{communityId:string;lastReadAtMs:bigint|number}[]>('SELECT "communityId","lastReadAtMs" FROM "CommunicationHubRead" WHERE "userId"=?',owner);
        const result:Row[]=[];
        for(const membership of memberships){
          const c=membership.community;if(array(c.blockedUserIdsJson).includes(owner)||array(c.bannedUserIdsJson).includes(owner))continue;
          const cutoff=Math.max(membership.createdAt.getTime(),Number(watermarks.find(w=>w.communityId===c.id)?.lastReadAtMs??0));
          const unread=await db.communityMessage.count({where:{communityId:c.id,senderId:{not:owner},createdAt:{gt:new Date(cutoff)}}});
          const latest=c.messages[0];result.push({id:'community:'+c.id,kind:'community',threadId:c.id,title:c.name,preview:latest?'New community message':'Community conversation',timestamp:iso(latest?.createdAt??membership.createdAt),unreadCount:unread,blocked:false});
        }return result;
      }],
      ['shops',async()=>{
        const conversations=await db.shopConversation.findMany({where:{OR:[{buyerId:owner},{sellerId:owner}]},orderBy:{lastMessageAt:'desc'},take:100,include:{messages:{where:{deletedAt:null},orderBy:{createdAt:'desc'},take:1,select:{createdAt:true,messageType:true}},reads:{where:{userId:owner}}}});
        const shops=await db.storefront.findMany({where:{id:{in:conversations.map(c=>c.shopId)}},select:{id:true,name:true}});
        const result:Row[]=[];
        for(const c of conversations){
          if(array(c.deletedByJson).includes(owner)||array(c.archivedByJson).includes(owner))continue;
          const seller=c.sellerId===owner,peer=seller?c.buyerId:c.sellerId;
          const blocked=c.status==='blocked'||await communicationBlocked(db,owner,peer)||Boolean(await db.shopBlockedUser.findFirst({where:{OR:[{userId:owner,blockedUserId:peer},{userId:peer,blockedUserId:owner}]}}));
          const unread=await db.shopMessage.count({where:{conversationId:c.id,deletedAt:null,senderId:{not:owner},createdAt:{gt:c.reads[0]?.lastReadAt??new Date(0)}}});
          result.push({id:'shop:'+c.id,kind:'shop',threadId:c.id,peerId:peer,shopId:c.shopId,isSeller:seller,title:shops.find(s=>s.id===c.shopId)?.name??'Shop conversation',preview:blocked?'Shop messaging unavailable':seller?'Customer conversation':'Conversation with shop',timestamp:iso(c.lastMessageAt),unreadCount:unread,blocked});
        }return result;
      }],
      ['calls',async()=>{
        const entries=await db.callHistoryEntry.findMany({where:{userId:owner},orderBy:{createdAt:'desc'},take:30,include:{call:{include:{caller:{select:{id:true,displayName:true,chirpId:true}},callee:{select:{id:true,displayName:true,chirpId:true}}}}}});
        const result:Row[]=[];
        for(const e of entries){const peer=e.call.callerId===owner?e.call.callee:e.call.caller;
          result.push({id:'call:'+e.id,kind:'call',threadId:e.callId,peerId:peer.id,peerHandle:peer.chirpId??undefined,title:peer.displayName||'OneWay call',preview:(e.hasVideo?'Video call · ':'Voice call · ')+e.status,timestamp:iso(e.createdAt),unreadCount:null,blocked:await communicationBlocked(db,owner,peer.id),status:e.status});}
        return result;
      }],
      ['recordedChirps',async()=>{
        const result:Row[]=[];
        const table=await db.$queryRawUnsafe<{name:string}[]>("SELECT name FROM sqlite_master WHERE type='table' AND name='RecordedChirp'");
        if(!table.length)return result;
        const items=await db.$queryRawUnsafe<{id:string;senderId:string;recipientId:string;chirpType:string;createdAtMs:bigint;openedAtMs:bigint|null;expiresAtMs:bigint|null}[]>('SELECT c."id",c."senderId",c."recipientId",c."chirpType",c."createdAtMs",c."expiresAtMs",r."openedAtMs" FROM "RecordedChirp" c LEFT JOIN "RecordedChirpReceipt" r ON r."chirpId"=c."id" WHERE (c."senderId"=? OR c."recipientId"=?) AND c."deletedAtMs" IS NULL AND (r."hiddenAtMs" IS NULL OR c."senderId"=?) AND (c."expiresAtMs" IS NULL OR c."expiresAtMs">?) ORDER BY c."createdAtMs" DESC LIMIT 30',owner,owner,owner,Date.now());
        const requests=await db.$queryRawUnsafe<{id:string;senderId:string;recipientId:string;createdAtMs:bigint}[]>(`SELECT "id","senderId","recipientId","createdAtMs" FROM "RecordedChirpRequest" WHERE "recipientId"=? AND "state"='pending' AND "expiresAtMs">? ORDER BY "createdAtMs" DESC LIMIT 20`,owner,Date.now());
        for(const item of [...requests.map(r=>({...r,chirpType:'REQUEST',openedAtMs:null,expiresAtMs:null})),...items]){
          const peer=item.senderId===owner?item.recipientId:item.senderId;
          if(!await mayCommunicate(db,owner,peer))continue;
          const recipient=await db.walkiePrivacySettings.findUnique({where:{userId:item.recipientId}});
          if(!await isDirectChirpDiscoverable(db,item.senderId,item.recipientId,{allowDirectChirp:recipient?.allowDirectChirp??true,directChirpAudience:recipient?.directChirpAudience??'everyone'}))continue;
          const profile=await db.user.findUnique({where:{id:peer},select:{displayName:true,chirpId:true,accountStatus:true}});if(!profile||profile.accountStatus!=='active')continue;
          result.push({id:'recorded:'+item.id,kind:'chirp',threadId:item.id,peerId:peer,peerHandle:profile.chirpId??undefined,title:profile.displayName||'OneWay contact',preview:item.chirpType==='REQUEST'?'Recorded Chirp request':item.chirpType.charAt(0)+item.chirpType.slice(1).toLowerCase()+' Chirp',timestamp:new Date(Number(item.createdAtMs)).toISOString(),unreadCount:item.recipientId===owner&&item.openedAtMs===null?1:0,blocked:false});
        }return result;
      }],
      ['chirps',async()=>{
        const requests=await db.directChirpRequest.findMany({where:{OR:[{senderUserId:owner},{recipientUserId:owner}],status:{in:['pending','accepted','declined','cancelled']}},orderBy:{createdAt:'desc'},take:50});
        const ids=[...new Set(requests.map(r=>r.senderUserId===owner?r.recipientUserId:r.senderUserId))];
        const profiles=await db.user.findMany({where:{id:{in:ids}},select:{id:true,displayName:true,chirpId:true}});
        const result:Row[]=[],seen=new Set<string>();
        requests.sort((a,b)=>Number(b.status==='pending'&&b.recipientUserId===owner)-Number(a.status==='pending'&&a.recipientUserId===owner)||b.createdAt.getTime()-a.createdAt.getTime());
        for(const r of requests){
          if(r.status==='pending'&&r.expiresAt.getTime()<Date.now())continue;
          const peer=r.senderUserId===owner?r.recipientUserId:r.senderUserId;
          if(seen.has(peer)||await communicationBlocked(db,owner,peer))continue;
          seen.add(peer);
          result.push({id:'chirp:'+r.id,kind:'chirp',threadId:r.id,peerId:peer,peerHandle:profiles.find(p=>p.id===peer)?.chirpId??undefined,title:profiles.find(p=>p.id===peer)?.displayName||'OneWay contact',preview:r.status==='pending'?(r.recipientUserId===owner?'Chirp request received':'Waiting for Chirp response'):'Chirp request '+r.status,timestamp:iso(r.createdAt),unreadCount:r.status==='pending'&&r.recipientUserId===owner?1:0,blocked:false,status:r.status});
        }return result;
      }]
    ];
    await Promise.all(sources.map(async([name,load])=>{try{rows.push(...await load());}catch{errors.push(name);}}));
    rows.sort((a,b)=>b.timestamp.localeCompare(a.timestamp));res.json({rows,sourceErrors:errors,security:'LEGACY_NOT_E2EE'});
  });
  router.post('/communities/:id/read',async(req,res)=>{
    try {
      const owner=uid(req),id=String(req.params.id),messageId=String(req.body?.messageId??'');
      const membership=await db.communityMember.findFirst({where:{userId:owner,communityId:id,community:{deletedAt:null}},include:{community:true}});
      if(!membership||array(membership.community.blockedUserIdsJson).includes(owner)||array(membership.community.bannedUserIdsJson).includes(owner)){res.status(404).json({error:'community_unavailable'});return;}
      const message=await db.communityMessage.findFirst({where:{id:messageId,communityId:id},select:{createdAt:true}});
      if(!message){res.status(404).json({error:'message_unavailable'});return;}
      await db.$executeRawUnsafe('INSERT INTO "CommunicationHubRead" ("userId","communityId","lastReadAtMs") VALUES (?,?,?) ON CONFLICT("userId","communityId") DO UPDATE SET "lastReadAtMs"=MAX("CommunicationHubRead"."lastReadAtMs",excluded."lastReadAtMs")',owner,id,message.createdAt.getTime());
      res.status(204).end();
    } catch{res.status(503).json({error:'read_state_unavailable'});}
  });
  return router;
}
