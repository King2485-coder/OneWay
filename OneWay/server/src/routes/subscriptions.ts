import {emailReadiness} from "../services/email/OneWayMailboxService";
import {emailProvider} from "../services/email/createEmailProvider";
import express from "express";
import {z} from "zod";
import {prisma} from "../lib/db";
import {authMiddleware,type AuthenticatedRequest} from "../middleware/auth";
import {applePurchaseReadiness,verifyAppleTransaction,applyBusinessTransaction,applyAppleNotification,ApplePurchaseError} from "../services/billing/AppleBusinessSubscription";
import {BUSINESS_CONTACT_PLAN,hasBusinessContactPlan} from "../services/billing/OneWayBusinessContactPlan";
export function subscriptionsRouter(): express.Router {
  const router=express.Router();
  router.post("/app-store/notifications",async(req,res,next)=>{try {
    const input=z.object({signedPayload:z.string().min(20).max(100000)}).strict().parse(req.body);
    res.json(await applyAppleNotification(prisma,input.signedPayload));
  } catch(e){respond(res,next,e);}});
  router.use(authMiddleware);
  router.get("/business",async(req,res,next)=>{try {res.set("Cache-Control","private, no-store").json({plan:BUSINESS_CONTACT_PLAN,active:await hasBusinessContactPlan(prisma,(req as AuthenticatedRequest).userId),emailDomain:process.env.ONEWAY_EMAIL_DOMAIN || "oneway.is",purchase:{...applePurchaseReadiness(),available:applePurchaseReadiness().configured && emailReadiness(emailProvider.name).liveDeliveryEnabled,reason:!applePurchaseReadiness().configured ? "app_store_not_configured" : !emailReadiness(emailProvider.name).liveDeliveryEnabled ? "email_setup_incomplete" : null}});}catch(e){next(e);}});
  router.post("/app-store/sync",async(req,res,next)=>{try {
    // Client transaction IDs and expiration dates cannot grant paid access.
    const input=z.object({signedTransaction:z.string().min(20).max(100000)}).strict().parse(req.body);
    const payload=await verifyAppleTransaction(input.signedTransaction);
    const subscription=await applyBusinessTransaction(prisma,(req as AuthenticatedRequest).userId,payload);
    res.json({subscription,transactionId:payload.transactionId});
  }catch(e){respond(res,next,e);}});
  return router;
}
function respond(res:express.Response,next:express.NextFunction,e:unknown){if(e instanceof ApplePurchaseError)return res.status(e.status).json({error:e.code});if(e instanceof z.ZodError)return res.status(400).json({error:"signed_apple_transaction_required"});next(e);}
