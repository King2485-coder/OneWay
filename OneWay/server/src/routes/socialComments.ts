import express, { type RequestHandler } from "express";
import type { Prisma, PrismaClient } from "@prisma/client";
import multer from "multer";
import { z } from "zod";
import { statfs } from "node:fs/promises";
import { encryptString, decryptString, isFieldEncryptionEnabled } from "../services/privacy/EncryptionService";
import type { ObjectStorage } from "../lib/storage/ObjectStorage";
import { validCloudMedia } from "./cloudMedia";
import { ghostMode } from "../services/AccountVisibility";
const maxBytes = 10 * 1024 * 1024;
const id = z.string().uuid();
const text = z.object({body:z.string().trim().min(1).max(2000),clientId:id}).strict();
const reasons=z.object({reason:z.enum(["spam","harassment","harmful_content","other"])}).strict();
const authorSelect={userId:true,handle:true,displayName:true} as const;
export function commentMediaKind(bytes:Buffer,mime:string):"image"|"gif"|"audio"|null {
  if(!bytes.length||bytes.length>maxBytes)return null;
  if(mime==="image/gif")return ["GIF87a","GIF89a"].includes(bytes.toString("ascii",0,6))&&bytes.length>=14&&bytes.readUInt16LE(6)>0&&bytes.readUInt16LE(8)>0&&bytes.readUInt16LE(6)<=4096&&bytes.readUInt16LE(8)<=4096?"gif":null;
  if(["image/jpeg","image/png","image/webp"].includes(mime))return validCloudMedia(bytes,mime)?"image":null;
  if(["audio/mp4","audio/x-m4a"].includes(mime))return bytes.length>=16&&bytes.toString("ascii",4,8)==="ftyp"?"audio":null;
  return null;
}
export function socialCommentsRouter(deps:{prisma:PrismaClient;storage:ObjectStorage|null;writes:RequestHandler;visiblePosts:(viewer:string)=>Promise<Prisma.SocialPostWhereInput>;visibleProfiles:(viewer:string)=>Promise<Prisma.SocialProfileWhereInput>;authorDTO:(author:any)=>Promise<any>}) {
 const {prisma,storage}=deps;const router=express.Router();const upload=multer({storage:multer.memoryStorage(),limits:{fileSize:maxBytes,files:1,fields:2,fieldSize:9000}});const uploading=new Set<string>();
 const uid=(req:express.Request)=>(req as any).userId as string;
 const wrap=(fn:(req:express.Request,res:express.Response)=>Promise<unknown>):RequestHandler=>(req,res,next)=>{fn(req,res).catch(e=>{if(e instanceof z.ZodError){res.status(400).json({error:"invalid_comment"});return;}if(e?.code==="P2002"){res.status(409).json({error:"comment_conflict"});return;}next(e);});};
 async function post(viewer:string,postId:string){return prisma.socialPost.findFirst({where:{AND:[await deps.visiblePosts(viewer),{id:postId,audience:"public"}]}});}
 async function mayComment(viewer:string){const p=await prisma.socialProfile.findUnique({where:{userId:viewer}});return p?.discoverable===true&&!await ghostMode(prisma,viewer);}
 async function dto(c:any,viewer:string,postOwner:string){return {id:c.id,postId:c.postId,body:c.body,kind:c.kind,fileName:c.fileName,mimeType:c.mimeType,byteCount:c.byteCount,createdAt:new Date(c.createdAt).toISOString(),author:await deps.authorDTO(c.author),canDelete:c.authorId===viewer||postOwner===viewer};}
 const readable:RequestHandler=(req,res,next)=>{post(uid(req),String(req.params.postId)).then(p=>{if(!p){res.status(404).json({error:"post_not_found"});return;}res.locals.post=p;next();}).catch(next);};
 router.get("/posts/:postId/comments",readable,wrap(async(req,res)=>{
  const query=z.object({before:z.string().datetime().optional(),beforeId:id.optional()}).refine(v=>!!v.before===!!v.beforeId).parse(req.query);
  const where:Prisma.SocialCommentWhereInput={postId:id.parse(req.params.postId),author:await deps.visibleProfiles(uid(req))};
  const rows=await prisma.socialComment.findMany({where:{AND:[where,...(query.before?[{OR:[{createdAt:{lt:new Date(query.before)}},{createdAt:new Date(query.before),id:{lt:query.beforeId}}]}]:[])]},orderBy:[{createdAt:"desc"},{id:"desc"}],take:51,include:{author:{select:authorSelect}}});
  const more=rows.length>50;const page=rows.slice(0,50);const last=page.at(-1);
  res.json({comments:await Promise.all(page.reverse().map(c=>dto(c,uid(req),res.locals.post.authorId))),total:await prisma.socialComment.count({where}),next:more&&last?{before:last.createdAt.toISOString(),beforeId:last.id}:null});
 }));
 router.post("/posts/:postId/comments",deps.writes,readable,wrap(async(req,res)=>{
  if(!await mayComment(uid(req)))return res.status(409).json({error:"public_profile_required",message:"Choose a visible social profile before commenting publicly."});
  const data=text.parse(req.body),postId=id.parse(req.params.postId);
  const previous=await prisma.socialComment.findUnique({where:{id:data.clientId},include:{author:{select:authorSelect}}});
  if(previous){if(previous.authorId!==uid(req)||previous.postId!==postId||previous.body!==data.body||previous.kind!=="text")return res.status(409).json({error:"comment_conflict"});return res.json({comment:await dto(previous,uid(req),res.locals.post.authorId)});}
  const c=await prisma.socialComment.create({data:{id:data.clientId,postId,authorId:uid(req),body:data.body,kind:"text"},include:{author:{select:authorSelect}}});res.status(201).json({comment:await dto(c,uid(req),res.locals.post.authorId)});
 }));
 router.post("/posts/:postId/comments/media",deps.writes,readable,(req,res,next)=>{
  if(!storage||!isFieldEncryptionEnabled()){res.status(503).json({error:"comment_media_unavailable"});return;}
  if(uploading.has(uid(req))||uploading.size>=2){res.status(429).json({error:"comment_upload_busy"});return;}uploading.add(uid(req));const release=()=>uploading.delete(uid(req));res.once("finish",release);res.once("close",release);
  upload.single("file")(req,res,e=>{if(e){res.status(e instanceof multer.MulterError&&e.code==="LIMIT_FILE_SIZE"?413:400).json({error:"invalid_comment_media"});return;}next();});
 },wrap(async(req,res)=>{
  if(!await mayComment(uid(req)))return res.status(409).json({error:"public_profile_required"});
  const file=req.file,kind=file&&commentMediaKind(file.buffer,file.mimetype);if(!file||!kind)return res.status(400).json({error:"unsupported_comment_media"});
  const clientId=id.parse(req.body?.clientId),body=z.string().trim().max(2000).parse(req.body?.body??""),postId=id.parse(req.params.postId);
  const previous=await prisma.socialComment.findUnique({where:{id:clientId},include:{author:{select:authorSelect}}});if(previous){if(previous.authorId!==uid(req)||previous.postId!==postId||previous.kind!==kind||previous.body!==body)return res.status(409).json({error:"comment_conflict"});return res.json({comment:await dto(previous,uid(req),res.locals.post.authorId)});}
  if(!await post(uid(req),postId))return res.status(404).json({error:"post_not_found"});
  const sum=await prisma.socialComment.aggregate({where:{postId},_sum:{byteCount:true}});if((sum._sum.byteCount??0)+file.size>250*1024*1024)return res.status(413).json({error:"comment_storage_full"});
  if(process.env.ONEWAY_PRIVATE_CLOUD_DIR){const disk=await statfs(process.env.ONEWAY_PRIVATE_CLOUD_DIR);if(disk.bavail*disk.bsize<256*1024*1024+file.size*2)return res.status(503).json({error:"comment_storage_busy"});}
  const key=`social-comments/${postId}/${clientId}`;const encrypted=encryptString(file.buffer.toString("base64"),{purpose:"social-comment",postId,id:clientId});await storage!.put(key,Buffer.from(encrypted),"application/octet-stream");
  let c;try{c=await prisma.socialComment.create({data:{id:clientId,postId,authorId:uid(req),body,kind,storageKey:key,mimeType:file.mimetype,fileName:file.originalname.replace(/[\x00-\x1f/\\]/g,"_").slice(0,180)||"reply",byteCount:file.size},include:{author:{select:authorSelect}}});}catch(e){await storage!.delete(key).catch(()=>undefined);throw e;}
  res.status(201).json({comment:await dto(c,uid(req),res.locals.post.authorId)});
 }));
 router.get("/posts/:postId/comments/:commentId/media",readable,wrap(async(req,res)=>{
  const c=await prisma.socialComment.findFirst({where:{id:id.parse(req.params.commentId),postId:id.parse(req.params.postId),author:await deps.visibleProfiles(uid(req))}});
  if(!c?.storageKey||!storage||c.storageKey!==`social-comments/${c.postId}/${c.id}`)return res.status(404).end();
  const o=await storage.read(c.storageKey);if(!o)return res.status(404).end();const chunks:Buffer[]=[];let n=0;for await(const chunk of o.stream){const b=Buffer.from(chunk);n+=b.length;if(n>maxBytes*2){o.stream.destroy();return res.status(503).end();}chunks.push(b);}
  const bytes=Buffer.from(decryptString(Buffer.concat(chunks).toString(),{purpose:"social-comment",postId:c.postId,id:c.id}),"base64");if(bytes.length!==c.byteCount||commentMediaKind(bytes,c.mimeType!)!==c.kind)return res.status(503).end();
  res.set({"Content-Type":c.mimeType!,"Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff","Content-Disposition":"attachment"}).send(bytes);
 }));
 router.delete("/posts/:postId/comments/:commentId",deps.writes,readable,wrap(async(req,res)=>{
  const c=await prisma.socialComment.findFirst({where:{id:id.parse(req.params.commentId),postId:id.parse(req.params.postId)}});if(!c||(c.authorId!==uid(req)&&res.locals.post.authorId!==uid(req)))return res.status(404).end();
  await prisma.socialComment.delete({where:{id:c.id}});if(c.storageKey)await storage?.delete(c.storageKey).catch(()=>undefined);res.status(204).end();
 }));
 router.post("/posts/:postId/comments/:commentId/reports",deps.writes,readable,wrap(async(req,res)=>{
  const data=reasons.parse(req.body);const c=await prisma.socialComment.findFirst({where:{id:id.parse(req.params.commentId),postId:id.parse(req.params.postId),author:await deps.visibleProfiles(uid(req))}});if(!c)return res.status(404).end();
  await prisma.socialCommentReport.upsert({where:{reporterId_commentId:{reporterId:uid(req),commentId:c.id}},create:{reporterId:uid(req),commentId:c.id,reason:data.reason},update:{reason:data.reason}});res.status(202).json({status:"received"});
 }));
 return router;
}
