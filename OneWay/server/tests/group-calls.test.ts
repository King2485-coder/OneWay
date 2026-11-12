import test,{before,after} from "node:test";
import assert from "node:assert/strict";
import express from "express";
import {randomUUID} from "node:crypto";
import {CallRegistry} from "../src/services/CallRegistry";
import {liveKitRouter} from "../src/routes/livekit";
import {callsRouter} from "../src/routes/calls";
import {callForUser,canJoinCall,memberFor,groupAction,GROUP_CALL_LIMIT} from "../src/services/GroupCallMembership";
import {isParticipant} from "../src/types/calls";
import {CallWebSocketServer} from "../src/realtime/CallWebSocketServer";
process.env.ONEWAY_GROUP_INVITE_RATE_LIMIT_MAX="100";process.env.NODE_ENV="test";process.env.JWT_AUTH_REQUIRED="false";
const registry=new CallRegistry(),a=randomUUID(),b=randomUUID(),c=randomUUID(),outsider=randomUUID();
const removed:string[]=[],invited:string[]=[];let allowed=true,base:string,server:any;
const app=express();app.use(express.json());
app.use("/api/calls",callsRouter({registry,inviteRateLimit:{windowMs:60000,max:100},mayInvite:async()=>allowed,resolveRecipient:async(_,id)=>id,displayName:async()=>"Test participant",isUserConnected:()=>true,onCallInvited:(_,id)=>invited.push(id),livekit:{isConfigured:()=>true,issue:async(args:any)=>({token:"test-not-a-real-token",liveKitUrl:"wss://example.invalid",roomName:args.roomName}),removeParticipant:async(_,id:string)=>{removed.push(id)}} as any}));
app.use("/api/livekit",liveKitRouter({registry,tokens:{isConfigured:()=>true} as any}));
app.use((e:any,_q:any,r:any,_n:any)=>r.status(500).json({error:e.message}));
before(async()=>{server=app.listen(0,"127.0.0.1");await new Promise<void>(r=>server.once("listening",r));base=`http://127.0.0.1:${server.address().port}/api/calls`});
after(async()=>{for(const id of ids)registry.removeCall(id);await new Promise<void>(r=>server.close(()=>r()))});
const ids:string[]=[];
function leg(call:any,user:string){return callForUser(call,user).callId}
function connected(){for(const id of ids)registry.removeCall(id);const call=registry.createCall({callerId:a,calleeId:b,hasVideo:false,turnEnabled:true});ids.push(call.callId);registry.updateStatus(call.callId,"connected",x=>{x.callerJoinedAt=Date.now();x.recipientJoinedAt=Date.now();x.callerMediaReadyAt=Date.now();x.recipientMediaReadyAt=Date.now();x.participants=[a,b]});return call;}
async function api(user:string,path:string,body:any={},method="POST"){const r=await fetch(base+path,{method,headers:{"Content-Type":"application/json","X-Dev-User-Id":user},body:method==="GET"?undefined:JSON.stringify(body)});return {status:r.status,data:await r.json() as any};}
test("outsiders and blocked contacts cannot expand a call; promotion is idempotent",async()=>{
 const call=connected();assert.equal((await api(outsider,`/${call.callId}/participants`,{recipientUserId:c})).status,404);
 allowed=false;assert.equal((await api(a,`/${call.callId}/participants`,{recipientUserId:c})).status,403);allowed=true;
 assert.equal((await api(a,`/${call.callId}/participants`,{recipientUserId:c})).status,201);
 const n=invited.length;assert.equal((await api(a,`/${call.callId}/participants`,{recipientUserId:c})).data.alreadyInvited,true);assert.equal(invited.length,n);
 assert.equal(call.status,"connected");assert.equal(callForUser(call,a).status,"connected");assert.equal(callForUser(call,c).status,"ringing");assert.equal(callForUser(call,c).calleeId,c);
 assert.equal(canJoinCall(call,c),false);assert.equal((await api(c,`/${leg(call,c)}/join`)).status,403);
 assert.equal((await api(c,`/${leg(call,c)}/accept`)).status,200);assert.equal((await api(c,`/${leg(call,c)}/join`)).status,200);
 assert.equal(memberFor(call,c)?.state,"joined");assert.equal((await api(c,`/${leg(call,c)}/media-ready`,{audioPublished:true})).status,200);
 assert.equal((await api(c,`/${leg(call,c)}/end`)).status,200);assert.equal(call.status,"connected");assert.equal(callForUser(call,c).status,"ended");assert.equal(callForUser(call,c).groupMembers?.length,0);assert.equal(isParticipant(call,c),false);assert.equal((await api(c,`/${leg(call,c)}/join`)).status,403);assert.ok(removed.includes("oneway-user-"+c));
 assert.equal((await api(c,`/${leg(call,c)}`,{},"GET")).data.call.status,"ended");assert.equal((await api(c,"/active",{},"GET")).data.calls.length,0);
});
test("declining and leaving do not end remaining members; last pair closes cleanly",async()=>{
 const call=connected();await api(a,`/${call.callId}/participants`,{recipientUserId:c});await api(c,"/decline",{callId:leg(call,c)});assert.equal(call.status,"connected");assert.equal(callForUser(call,c).status,"ended");assert.equal((await api(c,`/${leg(call,c)}/accept`)).status,409);
 await api(a,`/${call.callId}/participants`,{recipientUserId:c});await api(c,`/${leg(call,c)}/accept`);await api(c,`/${leg(call,c)}/join`);
 await api(a,`/${call.callId}/end`);assert.equal(call.status,"connected");assert.equal(callForUser(call,b).status,"connected");assert.equal(callForUser(call,c).status,"connected");
 await api(b,`/${call.callId}/end`);assert.equal(call.status,"ended");assert.equal(callForUser(call,c).status,"ended");
});
test("participant limit is enforced and pending users cannot invite",async()=>{
 const call=connected();await api(a,`/${call.callId}/participants`,{recipientUserId:c});assert.equal((await api(c,`/${leg(call,c)}/participants`,{recipientUserId:randomUUID()})).status,409);
 for(let i=3;i<GROUP_CALL_LIMIT;i++)assert.equal((await api(a,`/${call.callId}/participants`,{recipientUserId:randomUUID()})).status,201);
 assert.equal((await api(a,`/${call.callId}/participants`,{recipientUserId:randomUUID()})).data.error,"group_call_full");
});
test("websocket group fanout is personalized and departed users cannot hang up others",async()=>{
 const call=connected();await api(a,`/${call.callId}/participants`,{recipientUserId:c});
 const ws:any=new CallWebSocketServer({registry});const received=new Map<string,any[]>();
 for(const id of [a,b,c]){const list:any[]=[];received.set(id,list);ws.indexSocket(id,{readyState:1,send:(v:string)=>list.push(JSON.parse(v))});}
 ws.notifyCallChanged(call);
 assert.equal(received.get(c)?.at(-1).type,"call:ringing");assert.equal(received.get(a)?.at(-1).payload.call.status,"connected");
 groupAction(registry,call,c,"decline");ws.notifyCallChanged(call);assert.equal(received.get(c)?.at(-1).type,"call:ended");assert.equal(received.get(b)?.at(-1).type,"call:state");
 ws.applyLifecycleAction({send:()=>{},readyState:1},c,"call:hangup",call.callId);assert.equal(call.status,"connected");
});
test("legacy two-person end semantics are preserved",async()=>{const call=connected();assert.equal((await api(b,`/${call.callId}/end`)).status,200);assert.equal(call.status,"ended");});

test("expired invitations are reconciled after a timer loss or restart",async()=>{
 const call=connected();await api(a,`/${call.callId}/participants`,{recipientUserId:c});
 memberFor(call,c)!.invitedAt=Date.now()-50000;
 assert.equal((await api(c,`/${leg(call,c)}/accept`)).status,409);assert.equal(memberFor(call,c)?.state,"declined");assert.equal(call.status,"connected");
});
test("raw token endpoint rejects invited, departed and outside accounts",async()=>{
 const call=connected();await api(a,`/${call.callId}/participants`,{recipientUserId:c});
 for(const user of [c,outsider]){const r=await fetch(base.replace("/api/calls","/api/livekit/token"),{method:"POST",headers:{"Content-Type":"application/json","X-Dev-User-Id":user},body:JSON.stringify({roomName:call.roomName})});assert.equal(r.status,403);}
 groupAction(registry,call,c,"decline");const r=await fetch(base.replace("/api/calls","/api/livekit/token"),{method:"POST",headers:{"Content-Type":"application/json","X-Dev-User-Id":c},body:JSON.stringify({roomName:call.roomName})});assert.equal(r.status,403);
});

test("a fresh invitation gets a new call identity; stale hangups cannot cancel it",async()=>{
 const call=connected();await api(a,`/${call.callId}/participants`,{recipientUserId:c});const old=leg(call,c);
 await api(c,"/decline",{callId:old});await api(a,`/${call.callId}/participants`,{recipientUserId:c});const fresh=leg(call,c);assert.notEqual(old,fresh);
 assert.equal((await api(c,`/${old}/end`)).status,200);assert.equal(memberFor(call,c)?.state,"invited");assert.equal((await api(c,`/${fresh}/accept`)).status,200);
});
