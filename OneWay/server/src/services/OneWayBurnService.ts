import { createHash, randomBytes } from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { logger } from "../lib/logger";

export const BURN_CONFIRMATION = "BURN MY ONEWAY ACCOUNT";
export const BURN_SUBSYSTEMS = [
  "subscriptions_and_telecom",
  "push_and_sessions",
  "messaging",
  "communities",
  "email",
  "sites_shops_and_cloud",
  "contacts_history_and_personal_data",
  "financial_retention",
  "backup_suppression",
  "account_credentials",
] as const;

const RETAINED_FINANCIAL_USER_ID = "oneway-retained-financial-records";

export function createRecoveryToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString("base64url");
  return { token, hash: hashRecoveryToken(token) };
}

export function hashRecoveryToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export async function buildBurnSummary(prisma: PrismaClient, userId: string) {
  const [
    messages, sites, shops, products, communities, subscriptions, numbers,
    emailMailboxes, cloudFiles, contacts, conversations, orders, ledgerAccounts,
  ] = await Promise.all([
    prisma.message.count({ where: { senderId: userId, deletedAt: null } }),
    prisma.site.count({ where: { userId } }),
    prisma.storefront.count({ where: { ownerId: userId } }),
    prisma.storefrontProduct.count({ where: { storefront: { ownerId: userId } } }),
    prisma.community.count({ where: { ownerId: userId } }),
    prisma.subscription.count({ where: { userId, status: { in: ["active", "trialing"] } } }),
    prisma.userNumber.count({ where: { userId } }),
    prisma.emailMailbox.count({ where: { userId } }),
    prisma.siteMediaAsset.count({ where: { ownerId: userId, deletedAt: null } }),
    prisma.oneWayContact.count({ where: { userId } }),
    prisma.conversationParticipant.count({ where: { userId } }),
    prisma.order.count({ where: { OR: [{ userId }, { sellerId: userId }] } }),
    prisma.ledgerAccount.count({ where: { userId } }),
  ]);
  return {
    identity: 1,
    messages,
    sites,
    shops,
    products,
    communities,
    activeSubscriptions: subscriptions,
    phoneNumbers: numbers,
    emailMailboxes,
    cloudFiles,
    contacts,
    conversations,
    retainedTransactionRecords: orders,
    retainedLedgerAccounts: ledgerAccounts,
    ownershipActionRequired: communities + shops > 0,
    warnings: [
      "Other people may retain content they copied, forwarded, saved, or screenshotted.",
      "Financial, tax, telecom, fraud, dispute, safety, and transaction records may be retained when required.",
      "Historical backups expire on the documented backup schedule and burned data is blocked from restoration.",
    ],
  };
}

export async function buildAccountExport(prisma: PrismaClient, userId: string) {
  const [user, identity, contacts, sites, storefronts, messages, mailbox, subscriptions, numbers] = await Promise.all([
    prisma.user.findUnique({ where: { id: userId }, select: { id: true, email: true, displayName: true, createdAt: true } }),
    prisma.oneWayIdentity.findUnique({ where: { userId } }),
    prisma.oneWayContact.findMany({ where: { userId } }),
    prisma.site.findMany({ where: { userId } }),
    prisma.storefront.findMany({ where: { ownerId: userId }, include: { products: true } }),
    prisma.message.findMany({ where: { senderId: userId, deletedAt: null }, select: { id: true, conversationId: true, createdAt: true } }),
    prisma.emailMailbox.findUnique({ where: { userId }, include: { messages: true } }),
    prisma.subscription.findMany({ where: { userId } }),
    prisma.userNumber.findMany({ where: { userId } }),
  ]);
  return {
    exportedAt: new Date().toISOString(),
    notice: "This export contains OneWay-managed data available at export time. Processor-held and legally retained records may be separate.",
    user, identity, contacts, sites, storefronts, messageIndex: messages, mailbox, subscriptions, numbers,
  };
}

export async function executeBurnRequest(prisma: PrismaClient, burnRequestId: string): Promise<void> {
  const request = await prisma.accountBurnRequest.findUnique({ where: { id: burnRequestId } });
  if (!request || ["completed", "cancelled", "legally_restricted"].includes(request.status)) return;

  const holdIds = new Set((process.env.ONEWAY_BURN_LEGAL_HOLD_USER_IDS ?? "").split(",").map((id) => id.trim()).filter(Boolean));
  if (holdIds.has(request.userId) || request.legalHoldStatus === "active") {
    await prisma.accountBurnRequest.update({ where: { id: request.id }, data: { status: "legally_restricted", legalHoldStatus: "active" } });
    await audit(prisma, request.id, "burn.legally_restricted");
    return;
  }

  await prisma.accountBurnRequest.update({ where: { id: request.id }, data: { status: "in_progress", failureSummary: null } });
  const userId = request.userId;
  try {
    await runStep(prisma, request.id, "subscriptions_and_telecom", async () => {
      await prisma.subscription.updateMany({ where: { userId, status: { notIn: ["cancelled", "expired"] } }, data: { status: "cancelled" } });
    });
    await runStep(prisma, request.id, "push_and_sessions", async () => {
      await prisma.$transaction([
        prisma.pushToken.deleteMany({ where: { userId } }),
        prisma.alertPushToken.deleteMany({ where: { userId } }),
      ]);
    });
    await runStep(prisma, request.id, "messaging", async () => {
      await prisma.$transaction(async (tx) => {
        await tx.shopConversation.deleteMany({ where: { OR: [{ buyerId: userId }, { sellerId: userId }] } });
        await tx.shopMessage.deleteMany({ where: { OR: [{ senderId: userId }, { recipientId: userId }] } });
        await tx.shopConversationRead.deleteMany({ where: { userId } });
        await tx.shopBlockedUser.deleteMany({ where: { OR: [{ userId }, { blockedUserId: userId }] } });
        await tx.shopMessageSettings.deleteMany({ where: { userId } });
        await tx.messageReceipt.deleteMany({ where: { userId } });
        await tx.message.deleteMany({ where: { senderId: userId } });
        await tx.conversationParticipant.deleteMany({ where: { userId } });
      });
    });
    await runStep(prisma, request.id, "communities", async () => {
      await prisma.$transaction([
        prisma.communityMessage.deleteMany({ where: { senderId: userId } }),
        prisma.communityMember.deleteMany({ where: { userId } }),
        prisma.community.deleteMany({ where: { ownerId: userId } }),
      ]);
    });
    await runStep(prisma, request.id, "email", async () => {
      await prisma.emailMailbox.deleteMany({ where: { userId } });
    });
    await runStep(prisma, request.id, "sites_shops_and_cloud", async () => {
      await prisma.storefront.updateMany({ where: { ownerId: userId }, data: { published: false, searchable: false, publicVisible: false, status: "burn_scheduled" } });
      await prisma.site.updateMany({ where: { userId }, data: { visibility: "PRIVATE", status: "BURN_SCHEDULED", publishedHtml: "", publishedAt: null } });
    });
    await runStep(prisma, request.id, "contacts_history_and_personal_data", async () => {
      await prisma.$transaction(async (tx) => {
        await tx.directChirpRequest.deleteMany({ where: { OR: [{ senderUserId: userId }, { recipientUserId: userId }] } });
        await tx.chirpTrustPermission.deleteMany({ where: { OR: [{ ownerUserId: userId }, { permittedUserId: userId }] } });
        await tx.oneWayContact.deleteMany({ where: { OR: [{ userId }, { contactUserId: userId }] } });
        await tx.friendship.deleteMany({ where: { OR: [{ requesterUserId: userId }, { recipientUserId: userId }] } });
        await tx.walkieFavorite.deleteMany({ where: { OR: [{ userId }, { contactUserId: userId }] } });
        await tx.callSession.deleteMany({ where: { OR: [{ callerUserId: userId }, { calleeUserId: userId }] } });
        await tx.oneWayNetworkEvent.deleteMany({ where: { userId } });
      });
    });
    await runStep(prisma, request.id, "financial_retention", async () => {
      const retainUntil = new Date(Date.now() + 7 * 365 * 24 * 60 * 60 * 1_000);
      await prisma.$transaction(async (tx) => {
        await tx.user.upsert({
          where: { id: RETAINED_FINANCIAL_USER_ID },
          update: {},
          create: { id: RETAINED_FINANCIAL_USER_ID, displayName: "Deleted account", accountStatus: "retained_records" },
        });
        await tx.order.updateMany({ where: { userId }, data: { userId: RETAINED_FINANCIAL_USER_ID } });
        await tx.order.updateMany({ where: { sellerId: userId }, data: { sellerId: null } });
        await tx.storeOrderRequest.updateMany({
          where: { userId },
          data: { userId: RETAINED_FINANCIAL_USER_ID, customerName: "", customerEmail: "", customerPhone: "", buyerWalletUserId: null, sellerWalletUserId: null },
        });
        await tx.storeOrderRequest.updateMany({ where: { OR: [{ buyerWalletUserId: userId }, { sellerWalletUserId: userId }] }, data: { buyerWalletUserId: null, sellerWalletUserId: null } });
        await tx.ledgerAccount.updateMany({ where: { userId }, data: { userId: null } });
        await tx.auditEvent.updateMany({ where: { actorId: userId }, data: { actorId: null } });
        await tx.accountBurnRetentionRecord.createMany({ data: [
          { burnRequestId: request.id, subsystem: "orders", recordType: "transaction_records", legalBasis: "financial_tax_fraud_and_dispute_retention", retainUntil },
          { burnRequestId: request.id, subsystem: "ledger", recordType: "financial_ledger", legalBasis: "financial_integrity_and_regulatory_retention", retainUntil },
        ] });
      });
    });
    await runStep(prisma, request.id, "backup_suppression", async () => {
      const scheduledFor = new Date(Date.now() + Math.max(1, Number(process.env.BACKUP_RETENTION_DAYS ?? 35)) * 86_400_000);
      await prisma.accountBurnRequest.update({ where: { id: request.id }, data: { backupDeletionScheduledFor: scheduledFor } });
      await prisma.accountBurnRetentionRecord.create({
        data: { burnRequestId: request.id, subsystem: "backups", recordType: "encrypted_backup_generations", legalBasis: "scheduled_backup_expiry_and_non_restoration", retainUntil: scheduledFor },
      });
    });
    await runStep(prisma, request.id, "account_credentials", async () => {
      await prisma.$transaction(async (tx) => {
        await tx.user.delete({ where: { id: userId } });
        const empty = await tx.conversation.findMany({ where: { participants: { none: {} } }, select: { id: true } });
        if (empty.length) await tx.conversation.deleteMany({ where: { id: { in: empty.map((item) => item.id) } } });
      });
    });
    await prisma.accountBurnRequest.update({ where: { id: request.id }, data: { status: "completed", completedAt: new Date(), recoveryTokenHash: null } });
    await audit(prisma, request.id, "burn.completed");
  } catch (error) {
    const summary = error instanceof Error ? error.message.slice(0, 500) : "unknown_failure";
    await prisma.accountBurnRequest.update({ where: { id: request.id }, data: { status: "partially_completed", failureSummary: summary } });
    await audit(prisma, request.id, "burn.partial_failure", { summary });
    throw error;
  }
}

export function startBurnWorker(prisma: PrismaClient): void {
  const intervalMs = Math.max(10_000, Number(process.env.BURN_WORKER_INTERVAL_MS ?? 60_000));
  const run = async () => {
    const due = await prisma.accountBurnRequest.findMany({
      where: { status: { in: ["scheduled", "cooling_off", "partially_completed", "failed"] }, scheduledFor: { lte: new Date() } },
      take: 20,
    });
    for (const request of due) {
      try { await executeBurnRequest(prisma, request.id); }
      catch (error) { logger.error({ err: error, burnRequestId: request.id }, "[burn] execution failed; will retry"); }
    }
  };
  void run();
  setInterval(() => void run(), intervalMs).unref();
  logger.info({ intervalMs }, "[burn] orchestrator scheduled");
}

async function runStep(prisma: PrismaClient, burnRequestId: string, subsystem: string, operation: () => Promise<void>): Promise<void> {
  const step = await prisma.accountBurnStep.findUnique({ where: { burnRequestId_subsystem: { burnRequestId, subsystem } } });
  if (step?.status === "completed") return;
  await prisma.accountBurnStep.update({
    where: { burnRequestId_subsystem: { burnRequestId, subsystem } },
    data: { status: "in_progress", startedAt: new Date(), retryCount: { increment: 1 }, errorCode: null, errorSummary: null },
  });
  try {
    await operation();
    await prisma.accountBurnStep.update({ where: { burnRequestId_subsystem: { burnRequestId, subsystem } }, data: { status: "completed", completedAt: new Date() } });
  } catch (error) {
    const summary = error instanceof Error ? error.message.slice(0, 500) : "unknown_failure";
    await prisma.accountBurnStep.update({ where: { burnRequestId_subsystem: { burnRequestId, subsystem } }, data: { status: "failed", errorCode: "subsystem_failure", errorSummary: summary } });
    throw error;
  }
}

async function audit(prisma: PrismaClient, burnRequestId: string, event: string, details: Record<string, unknown> = {}): Promise<void> {
  await prisma.accountBurnAuditLog.create({ data: { burnRequestId, event, detailsJson: JSON.stringify(details) } });
}
