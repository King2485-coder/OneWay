import {Environment, SignedDataVerifier, Type, type JWSTransactionDecodedPayload} from "@apple/app-store-server-library";
import type {PrismaClient} from "@prisma/client";
import {randomUUID} from "node:crypto";
import {appleTrustRoots} from "./AppleTrustRoots";
import {BUSINESS_CONTACT_PRODUCT_ID} from "./OneWayBusinessContactPlan";
export class ApplePurchaseError extends Error { constructor(public code: string, public status = 400) { super(code); } }
const appAppleId = () => Number(process.env.APPLE_APP_ID || "6759179961"); // OneWay App Store Connect app, verified in its Apps page.
export function applePurchaseReadiness() { const valid = Number.isSafeInteger(appAppleId()) && appAppleId() > 0; return {configured: valid && process.env.ONEWAY_BUSINESS_APP_STORE_READY === "true", verificationConfigured: valid, sandboxAllowed: process.env.APPLE_ALLOW_SANDBOX_IAP === "true"}; }
function verifier(environment: Environment) {
  const appId = appAppleId();
  if (!Number.isSafeInteger(appId) || appId <= 0) throw new ApplePurchaseError("app_store_not_configured", 503);
  return new SignedDataVerifier(appleTrustRoots, true, environment, "com.king.OneWay", appId);
}
export async function verifyAppleTransaction(signed: string): Promise<JWSTransactionDecodedPayload> {
  try { return await verifier(Environment.PRODUCTION).verifyAndDecodeTransaction(signed); }
  catch (error) {
    if (error instanceof ApplePurchaseError) throw error;
    if (process.env.APPLE_ALLOW_SANDBOX_IAP === "true") {
      try { return await verifier(Environment.SANDBOX).verifyAndDecodeTransaction(signed); } catch {}
    }
    throw new ApplePurchaseError("purchase_verification_failed", 403);
  }
}
export async function ensureApplePurchaseTable(db: PrismaClient) {
  await db.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS "AppleBusinessPurchase" ("originalTransactionId" TEXT PRIMARY KEY,"userId" TEXT NOT NULL,"productId" TEXT NOT NULL,"transactionId" TEXT NOT NULL,"signedDate" BIGINT NOT NULL,"expiresAt" BIGINT NOT NULL,"revoked" BOOLEAN NOT NULL DEFAULT false,"updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY("userId") REFERENCES "User"("id") ON DELETE CASCADE)`);
}
export function validateBusinessTransaction(payload: JWSTransactionDecodedPayload, userId: string) {
  if (payload.productId !== BUSINESS_CONTACT_PRODUCT_ID || payload.type !== Type.AUTO_RENEWABLE_SUBSCRIPTION) throw new ApplePurchaseError("wrong_subscription", 403);
  if (!payload.appAccountToken || payload.appAccountToken.toLowerCase() !== userId.toLowerCase()) throw new ApplePurchaseError("purchase_account_mismatch", 403);
  if (!payload.originalTransactionId || !payload.transactionId || !Number.isFinite(payload.signedDate) || !Number.isFinite(payload.expiresDate)) throw new ApplePurchaseError("invalid_transaction", 403);
  if ((payload.signedDate || 0) > Date.now() + 300000) throw new ApplePurchaseError("invalid_transaction_date", 403);
}
export async function applyBusinessTransaction(db: PrismaClient, userId: string, payload: JWSTransactionDecodedPayload) {
  validateBusinessTransaction(payload, userId);
  await ensureApplePurchaseTable(db);
  return db.$transaction(async tx => {
    const prior = (await tx.$queryRawUnsafe<Array<{userId: string; signedDate: bigint | number}>>(`SELECT "userId","signedDate" FROM "AppleBusinessPurchase" WHERE "originalTransactionId"=?`, payload.originalTransactionId!))[0];
    if (prior && prior.userId.toLowerCase() !== userId.toLowerCase()) throw new ApplePurchaseError("purchase_already_linked", 409);
    if (prior && Number(prior.signedDate) > payload.signedDate!) throw new ApplePurchaseError("stale_purchase_update", 409);
    await tx.$executeRawUnsafe(`INSERT INTO "AppleBusinessPurchase" ("originalTransactionId","userId","productId","transactionId","signedDate","expiresAt","revoked") VALUES (?,?,?,?,?,?,?) ON CONFLICT("originalTransactionId") DO UPDATE SET "transactionId"=excluded."transactionId","signedDate"=excluded."signedDate","expiresAt"=excluded."expiresAt","revoked"=excluded."revoked","updatedAt"=CURRENT_TIMESTAMP`, payload.originalTransactionId!,userId,payload.productId!,payload.transactionId!,payload.signedDate!,payload.expiresDate!,Boolean(payload.revocationDate));
    const current=(await tx.$queryRawUnsafe<Array<{expiration:bigint|number|null}>>(`SELECT MAX("expiresAt") AS expiration FROM "AppleBusinessPurchase" WHERE "userId"=? AND "productId"=? AND "revoked"=false AND "expiresAt">?`,userId,BUSINESS_CONTACT_PRODUCT_ID,Date.now()))[0];
    const expiration=Number(current?.expiration || 0);
    const active=expiration > Date.now();
    const existing = await tx.subscription.findFirst({where: {userId,productId:BUSINESS_CONTACT_PRODUCT_ID}});
    const data = {status:active ? "active" : "expired",expiresAt:new Date(expiration || payload.expiresDate!)};
    return existing ? tx.subscription.update({where:{id:existing.id},data}) : tx.subscription.create({data:{...data,id:randomUUID(),userId,productId:BUSINESS_CONTACT_PRODUCT_ID}});
  });
}
export async function applyAppleNotification(db: PrismaClient, signedPayload: string) {
  let decoded;
  try { decoded = await verifier(Environment.PRODUCTION).verifyAndDecodeNotification(signedPayload); }
  catch(error) {
    if (error instanceof ApplePurchaseError) throw error;
    if (process.env.APPLE_ALLOW_SANDBOX_IAP !== "true") throw new ApplePurchaseError("invalid_apple_notification", 403);
    try { decoded = await verifier(Environment.SANDBOX).verifyAndDecodeNotification(signedPayload); } catch { throw new ApplePurchaseError("invalid_apple_notification", 403); }
  }
  if (!decoded.data?.signedTransactionInfo) return {ignored:true};
  const transaction = await verifyAppleTransaction(decoded.data.signedTransactionInfo);
  if (transaction.productId !== BUSINESS_CONTACT_PRODUCT_ID) return {ignored:true};
  if (!transaction.appAccountToken) throw new ApplePurchaseError("purchase_account_mismatch",403);
  const owner = transaction.appAccountToken.toLowerCase();
  if (!await db.user.findUnique({where:{id:owner},select:{id:true}})) return {ignored:true};
  await applyBusinessTransaction(db,owner,transaction);
  return {accepted:true};
}
