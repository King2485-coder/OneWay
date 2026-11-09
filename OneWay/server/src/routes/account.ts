import express from "express";
import { z } from "zod";
import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { ensureUserRecord } from "../services/identity";
import { recordAuditEventSafe } from "../services/audit/AuditEventService";

const resetProfileSchema = z.object({
  deleteImportedContacts: z.boolean().optional(),
});

export function accountRouter(): express.Router {
  const router = express.Router();

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


  router.delete("/", async (req, res) => {
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
      // Financial, tax, fraud, refund, and dispute records must remain
      // internally consistent without retaining the deleted customer's
      // identity. Move buyer ownership to the shared, non-personal retention
      // principal before the user's cascade relations are removed.
      const retainedFinancialUserId = "oneway-retained-financial-records";
      await tx.user.upsert({
        where: { id: retainedFinancialUserId },
        update: {},
        create: {
          id: retainedFinancialUserId,
          displayName: "Deleted account",
          accountStatus: "retained_records",
        },
      });
      await tx.order.updateMany({
        where: { userId },
        data: { userId: retainedFinancialUserId },
      });

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
        where: { userId },
        data: {
          userId: retainedFinancialUserId,
          customerName: "",
          customerEmail: "",
          customerPhone: "",
          buyerWalletUserId: null,
          sellerWalletUserId: null,
        },
      });
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

      // This final delete cascades profile, credentials, tokens, storefronts,
      // products, drafts, site media metadata, subscriptions, and all other
      // modeled user-owned records. It deliberately runs last so a failed
      // dependent cleanup rolls the transaction back and leaves login usable.
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
