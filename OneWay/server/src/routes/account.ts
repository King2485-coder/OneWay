import express from "express";
import bcrypt from "bcryptjs";
import { z } from "zod";
import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord } from "../services/identity";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";
import {
  BURN_CONFIRMATION,
  BURN_SUBSYSTEMS,
  buildAccountExport,
  buildBurnSummary,
  createRecoveryToken,
  executeBurnRequest,
  hashRecoveryToken,
} from "../services/OneWayBurnService";

const resetProfileSchema = z.object({
  deleteImportedContacts: z.boolean().optional(),
});

const burnRequestSchema = z.object({
  password: z.string().min(1).max(256),
  confirmation: z.literal(BURN_CONFIRMATION),
  recoveryHours: z.union([z.literal(0), z.literal(24), z.literal(168), z.literal(720)]).default(168),
  exportRequested: z.boolean().default(false),
  ownedResourceAction: z.literal("delete"),
  phoneNumbersAcknowledged: z.boolean().default(false),
});

const recoverySchema = z.object({ recoveryToken: z.string().min(32).max(256) });

export function accountRouter(): express.Router {
  const router = express.Router();

  router.get("/burn/recovery/:requestId", async (req, res) => {
    const token = String(req.query.token ?? "");
    const request = await prisma.accountBurnRequest.findUnique({
      where: { id: req.params.requestId },
      include: { steps: { orderBy: { subsystem: "asc" } }, retentionRecords: true },
    });
    if (!request?.recoveryTokenHash || hashRecoveryToken(token) !== request.recoveryTokenHash) {
      res.status(404).json({ error: "burn_request_not_found" });
      return;
    }
    res.json({ request: publicBurnRequest(request) });
  });

  router.post("/burn/recovery/:requestId/cancel", async (req, res) => {
    const parsed = recoverySchema.safeParse(req.body ?? {});
    const request = parsed.success ? await prisma.accountBurnRequest.findUnique({ where: { id: req.params.requestId } }) : null;
    if (!request?.recoveryTokenHash || !parsed.success || hashRecoveryToken(parsed.data.recoveryToken) !== request.recoveryTokenHash) {
      res.status(404).json({ error: "burn_request_not_found" });
      return;
    }
    if (request.status !== "cooling_off" || request.scheduledFor <= new Date()) {
      res.status(409).json({ error: "burn_no_longer_cancellable" });
      return;
    }
    await prisma.$transaction([
      prisma.accountBurnRequest.update({ where: { id: request.id }, data: { status: "cancelled", cancelledAt: new Date(), recoveryTokenHash: null } }),
      prisma.accountBurnStep.updateMany({ where: { burnRequestId: request.id, status: "pending" }, data: { status: "cancelled" } }),
      prisma.user.update({ where: { id: request.userId }, data: { accountStatus: "active", loginDisabledAt: null, publicProfileHiddenAt: null } }),
      prisma.accountBurnAuditLog.create({ data: { burnRequestId: request.id, event: "burn.cancelled_by_recovery_token" } }),
    ]);
    res.json({ ok: true, status: "cancelled" });
  });

  router.use(authMiddleware);

  router.get("/profile-status", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const [identity, freeNumbers] = await Promise.all([
      prisma.oneWayIdentity.findUnique({
        where: { userId },
        select: { displayName: true, onewayId: true, emailAlias: true },
      }),
      prisma.userNumber.count({
        where: { userId, isPaid: false },
      }),
    ]);

    const hasDisplayName = Boolean(identity?.displayName?.trim());
    const hasOneWayId = Boolean(identity?.onewayId?.trim());
    const hasEmailAlias = Boolean(identity?.emailAlias?.trim());
    const hasIdentity = hasDisplayName && hasOneWayId && hasEmailAlias;
    const hasNumber = freeNumbers >= 1;
    const hasTwoFreeNumbers = freeNumbers >= 2;

    res.json({
      complete: hasIdentity && hasTwoFreeNumbers,
      hasIdentity,
      hasNumber,
      hasTwoFreeNumbers,
      hasDisplayName,
      hasOneWayId,
      hasEmailAlias,
    });
  });

  router.post("/reset-profile", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = resetProfileSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    await prisma.$transaction([
      prisma.userNumber.deleteMany({ where: { userId } }),
      prisma.oneWayIdentity.deleteMany({ where: { userId } }),
    ]);

    res.status(204).end();
  });

  router.get("/burn/summary", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);
    res.json({ summary: await buildBurnSummary(prisma, userId), confirmationPhrase: BURN_CONFIRMATION, recommendedRecoveryHours: 168 });
  });

  router.get("/burn/export", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const payload = await buildAccountExport(prisma, userId);
    res.setHeader("Content-Disposition", `attachment; filename="oneway-export-${new Date().toISOString().slice(0, 10)}.json"`);
    res.json(payload);
  });

  router.post("/burn/request", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = burnRequestSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_burn_request", issues: parsed.error.issues });
      return;
    }
    const user = await prisma.user.findUnique({ where: { id: userId }, select: { passwordHash: true, accountStatus: true } });
    if (!user?.passwordHash || user.accountStatus !== "active" || !(await bcrypt.compare(parsed.data.password, user.passwordHash))) {
      res.status(401).json({ error: "authentication_failed" });
      return;
    }
    const existing = await prisma.accountBurnRequest.findFirst({
      where: { userId, status: { notIn: ["completed", "cancelled", "failed"] } },
      orderBy: { requestedAt: "desc" },
    });
    if (existing) {
      res.status(409).json({ error: "burn_already_requested" });
      return;
    }
    const phoneNumberCount = await prisma.userNumber.count({ where: { userId } });
    if (phoneNumberCount > 0 && !parsed.data.phoneNumbersAcknowledged) {
      res.status(409).json({
        error: "phone_number_release_not_acknowledged",
        message: "Port any number you need first, then explicitly acknowledge that remaining OneWay-managed numbers will be released.",
      });
      return;
    }

    const now = new Date();
    const scheduledFor = new Date(now.getTime() + parsed.data.recoveryHours * 3_600_000);
    const recovery = createRecoveryToken();
    const request = await prisma.$transaction(async (tx) => {
      const created = await tx.accountBurnRequest.create({
        data: {
          userId,
          status: parsed.data.recoveryHours === 0 ? "scheduled" : "cooling_off",
          scheduledFor,
          authenticationMethod: "password",
          immediateBurn: parsed.data.recoveryHours === 0,
          exportRequested: parsed.data.exportRequested,
          recoveryTokenHash: parsed.data.recoveryHours === 0 ? null : recovery.hash,
          steps: { create: BURN_SUBSYSTEMS.map((subsystem) => ({ subsystem })) },
          exports: parsed.data.exportRequested ? { create: { status: "available_via_authenticated_export" } } : undefined,
          auditLog: { create: { event: "burn.requested", detailsJson: JSON.stringify({ recoveryHours: parsed.data.recoveryHours, ownedResourceAction: parsed.data.ownedResourceAction }) } },
        },
        include: { steps: true },
      });
      await tx.pushToken.deleteMany({ where: { userId } });
      await tx.alertPushToken.deleteMany({ where: { userId } });
      await tx.user.update({ where: { id: userId }, data: { accountStatus: "burn_pending", loginDisabledAt: now, publicProfileHiddenAt: now } });
      return created;
    });

    res.status(202).json({
      request: publicBurnRequest(request),
      recoveryToken: parsed.data.recoveryHours === 0 ? null : recovery.token,
      message: parsed.data.recoveryHours === 0
        ? "Permanent deletion has been scheduled and recovery may not be possible."
        : "The account is disabled and hidden during the recovery window. Keep the recovery token to cancel.",
    });
    if (parsed.data.recoveryHours === 0) setImmediate(() => void executeBurnRequest(prisma, request.id));
  });

  router.delete("/", async (req, res) => {
    res.status(410).json({ error: "burn_flow_required", message: "Use the authenticated multi-step Burn My OneWay Account flow." });
    return;
    const userId = (req as AuthenticatedRequest).userId;
    const user = await prisma.user.findUnique({ where: { id: userId }, select: { id: true } });
    if (!user) {
      res.status(204).end();
      return;
    }

    // Preserve only a redacted, non-reversible compliance event. The audit
    // service shortens actor identifiers before persisting them.
    await recordAuditEventSafe(prisma, {
      actorId: userId,
      actorType: "user",
      action: "account.deletion.requested",
      resourceType: "account",
    });

    await prisma.$transaction(async (tx) => {
      // Remove user-authored data that isn't connected to User with a Prisma
      // cascade relation. User-owned records with cascade relations are
      // removed by the final user.delete call below.
      await tx.communityMessage.deleteMany({ where: { senderId: userId } });
      await tx.communityMember.deleteMany({ where: { userId } });
      await tx.community.deleteMany({ where: { ownerId: userId } });

      await tx.shopConversation.deleteMany({
        where: { OR: [{ buyerId: userId }, { sellerId: userId }] },
      });
      await tx.shopMessage.deleteMany({
        where: { OR: [{ senderId: userId }, { recipientId: userId }] },
      });
      await tx.shopConversationRead.deleteMany({ where: { userId } });
      await tx.shopBlockedUser.deleteMany({
        where: { OR: [{ userId }, { blockedUserId: userId }] },
      });
      await tx.shopMessageSettings.deleteMany({ where: { userId } });

      await tx.directChirpRequest.deleteMany({
        where: { OR: [{ senderUserId: userId }, { recipientUserId: userId }] },
      });
      await tx.chirpTrustPermission.deleteMany({
        where: { OR: [{ ownerUserId: userId }, { permittedUserId: userId }] },
      });
      await tx.oneWayContact.deleteMany({
        where: { OR: [{ userId }, { contactUserId: userId }] },
      });
      await tx.friendship.deleteMany({
        where: { OR: [{ requesterUserId: userId }, { recipientUserId: userId }] },
      });
      await tx.walkieFavorite.deleteMany({
        where: { OR: [{ userId }, { contactUserId: userId }] },
      });

      await tx.callSession.deleteMany({
        where: { OR: [{ callerUserId: userId }, { calleeUserId: userId }] },
      });
      await tx.oneWayNetworkEvent.deleteMany({ where: { userId } });
      await tx.messageReceipt.deleteMany({ where: { userId } });
      await tx.message.deleteMany({ where: { senderId: userId } });
      await tx.conversationParticipant.deleteMany({ where: { userId } });

      await tx.productImage.deleteMany({ where: { sellerId: userId } });
      await tx.order.updateMany({ where: { sellerId: userId }, data: { sellerId: null } });
      await tx.storeOrderRequest.updateMany({
        where: { buyerWalletUserId: userId },
        data: { buyerWalletUserId: null },
      });
      await tx.storeOrderRequest.updateMany({
        where: { sellerWalletUserId: userId },
        data: { sellerWalletUserId: null },
      });
      await tx.ledgerAccount.updateMany({ where: { userId }, data: { userId: null } });
      await tx.auditEvent.updateMany({ where: { actorId: userId }, data: { actorId: null } });

      await tx.user.delete({ where: { id: userId } });

      const emptyConversations = await tx.conversation.findMany({
        where: { participants: { none: {} } },
        select: { id: true },
      });
      if (emptyConversations.length > 0) {
        await tx.conversation.deleteMany({
          where: { id: { in: emptyConversations.map((conversation) => conversation.id) } },
        });
      }
    });

    res.status(204).end();
  });

  return router;
}

function publicBurnRequest(request: any) {
  return {
    id: request.id,
    status: request.status,
    requestedAt: request.requestedAt,
    scheduledFor: request.scheduledFor,
    immediateBurn: request.immediateBurn,
    exportRequested: request.exportRequested,
    completedAt: request.completedAt,
    cancelledAt: request.cancelledAt,
    failureSummary: request.failureSummary,
    legalHoldStatus: request.legalHoldStatus,
    backupDeletionScheduledFor: request.backupDeletionScheduledFor,
    steps: request.steps ?? [],
    retentionRecords: request.retentionRecords ?? [],
  };
}
