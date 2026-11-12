import type { CallSession } from "../types/calls";
import { sameUserId } from "../types/calls";
import type { ICallRegistry } from "./CallRegistry";
import { isTerminal } from "./CallRegistry";

export type GroupMemberState = "invited" | "accepted" | "joined" | "left" | "declined";
export interface GroupCallMember {
  userId: string; invitationCallId?: string; previousCallIds?: string[]; removalPending?: boolean; state: GroupMemberState; invitedBy: string; invitedAt: number;
  joinedAt?: number; mediaReadyAt?: number; leftAt?: number; tokenNotBefore?: number;
}
export const GROUP_CALL_LIMIT = 8;
export const GROUP_INVITE_TIMEOUT_MS = 45_000;
export const memberFor = (call: CallSession, userId: string) => call.groupMembers?.find(m => sameUserId(m.userId,userId));
export const memberCallMatches = (call:CallSession,userId:string,callId:string) => (memberFor(call,userId)?.invitationCallId ?? call.callId).toLowerCase() === callId.toLowerCase();
export const isActiveMember = (m: GroupCallMember) => m.state !== "left" && m.state !== "declined";
export const canJoinCall = (call: CallSession,userId: string) => !call.groupMembers || ["accepted","joined"].includes(memberFor(call,userId)?.state ?? "");
export function membersForPromotion(call: CallSession): GroupCallMember[] {
  return call.groupMembers ?? [
    {userId:call.callerId,state:call.callerJoinedAt ? "joined" : "accepted",invitedBy:call.callerId,invitedAt:call.createdAt,joinedAt:call.callerJoinedAt,mediaReadyAt:call.callerMediaReadyAt},
    {userId:call.calleeId,state:call.recipientJoinedAt ? "joined" : call.recipientAcceptedAt ? "accepted" : "invited",invitedBy:call.callerId,invitedAt:call.createdAt,joinedAt:call.recipientJoinedAt,mediaReadyAt:call.recipientMediaReadyAt}
  ];
}
/** Each account receives its own ringing/ended state; remaining members stay connected. */
export function callForUser(call: CallSession,userId: string): CallSession {
  const member=memberFor(call,userId);
  if(!member)return call;
  const ownTerminal=member.state==="left"||member.state==="declined";
  return {...call,
    callId:member.invitationCallId ?? call.callId,id:member.invitationCallId ?? call.callId,
    groupMembers:ownTerminal ? [] : call.groupMembers,
    participants:ownTerminal ? [] : call.participants,
    callerId:sameUserId(userId,call.callerId)?call.callerId:member.invitedBy,
    callerUserId:sameUserId(userId,call.callerId)?call.callerId:member.invitedBy,
    calleeId:sameUserId(userId,call.callerId)?call.calleeId:userId,
    recipientUserId:sameUserId(userId,call.callerId)?call.calleeId:userId,
    status:isTerminal(call.status)?call.status:ownTerminal?"ended":member.state==="invited"?"ringing":member.state==="accepted"?"accepting":call.status,
    endedByUserId:ownTerminal?userId:call.endedByUserId,
    endedAt:ownTerminal?member.leftAt:call.endedAt
  };
}
export function groupAction(registry: ICallRegistry,call: CallSession,userId: string,action:"accept"|"decline"|"leave"): CallSession {
  const member=memberFor(call,userId);
  if(!member)throw new Error("not_participant");
  if(isTerminal(call.status))return call;
  if(action==="accept") {
    if(member.state==="invited" && Date.now()-member.invitedAt>GROUP_INVITE_TIMEOUT_MS){groupAction(registry,call,userId,"decline");throw new Error("invitation_closed");}
    if(!isActiveMember(member))throw new Error("invitation_closed");
    if(member.state!=="invited")return call;
  } else if(!isActiveMember(member))return call;
  if(action==="decline" && member.state!=="invited")throw new Error("already_joined");
  const now=Date.now();
  const next=call.groupMembers!.map(m=>sameUserId(m.userId,userId)?{...m,state:action==="accept"?"accepted" as const:action==="decline"?"declined" as const:"left" as const,...(action==="accept"?{}:{leftAt:now,...(action==="leave"?{removalPending:true}:{})})}:m);
  const active=next.filter(isActiveMember);
  const end=action!=="accept" && active.length<2;
  return registry.updateStatus(call.callId,end?"ended":call.status,c=>{
    c.groupMembers=next;c.participants=next.filter(m=>m.state==="accepted"||m.state==="joined").map(m=>m.userId);
    if(end){c.endedByUserId=userId;c.endReason="lastParticipantLeft";}
  });
}
export function scheduleGroupInviteExpiry(registry: ICallRegistry,callId:string,userId:string,invitedAt:number) {
  const timer=setTimeout(()=>{
    const call=registry.get(callId);if(!call||isTerminal(call.status))return;
    const member=memberFor(call,userId);
    if(member?.state==="invited"&&member.invitedAt===invitedAt)groupAction(registry,call,userId,"decline");
  },GROUP_INVITE_TIMEOUT_MS);timer.unref();
}

export function currentCall(registry:ICallRegistry,callId:string):CallSession|undefined {
  let call=registry.get(callId);
  if(!call||isTerminal(call.status))return call;
  for(const member of [...(call.groupMembers??[])]) {
    if(member.state==="invited" && Date.now()-member.invitedAt>GROUP_INVITE_TIMEOUT_MS)call=groupAction(registry,call,member.userId,"decline");
    if(isTerminal(call.status))break;
  }
  return call;
}

/** Block reinvitation until the previous media grant has been revoked. */
export async function completeGroupRemoval(registry:ICallRegistry,callId:string,userId:string,remove:()=>Promise<void>):Promise<void> {
  const initial=registry.get(callId);if(!initial)return;
  const expected=memberFor(initial,userId)?.invitationCallId;
  for(let attempt=0;attempt<3;attempt++) {
    const call=registry.get(callId);const member=call?memberFor(call,userId):undefined;
    if(!call||!member||member.state!=="left"||member.invitationCallId!==expected||!member.removalPending)return;
    try {
      await remove();
      const latest=registry.get(callId);const current=latest?memberFor(latest,userId):undefined;
      if(latest&&current?.state==="left"&&current.invitationCallId===expected)registry.updateStatus(latest.callId,latest.status,c=>{c.groupMembers=c.groupMembers!.map(m=>sameUserId(m.userId,userId)?{...m,removalPending:false,tokenNotBefore:Math.floor(Date.now()/1000)+1}:m)});
      return;
    } catch { if(attempt<2)await new Promise(r=>setTimeout(r,500*(attempt+1))); }
  }
}
