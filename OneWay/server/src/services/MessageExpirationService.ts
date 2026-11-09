import type { PrismaClient } from "@prisma/client";
import { logger } from "../lib/logger";
import type { MessageRealtimeServer } from "../realtime/MessageRealtimeServer";

const TOMBSTONE_VERSION = 1;

export async function expireDueMessages(
  prisma: PrismaClient,
  realtime?: MessageRealtimeServer,
  now = new Date(),
): Promise<number> {
  const due = await prisma.message.findMany({
    where: { expiresAt: { lte: now }, deletedAt: null },
    include: {
      conversation: { include: { participants: { select: { userId: true } } } },
    },
    take: 250,
  });

  let expired = 0;
  for (const message of due) {
    const deletedAt = new Date();
    const updated = await prisma.$transaction(async (tx) => {
      const claimed = await tx.message.updateMany({
        where: { id: message.id, deletedAt: null, expiresAt: { lte: now } },
        data: {
          ciphertext: JSON.stringify({
            body: "",
            attachment: null,
            replyToMessageId: null,
            tombstone: { version: TOMBSTONE_VERSION, reason: "expired_after_read" },
          }),
          deletedAt,
          deletionReason: "expired_after_read",
          tombstoneVersion: TOMBSTONE_VERSION,
          attachmentExpirationState: "deleted",
        },
      });
      if (claimed.count === 0) return null;
      await tx.messageAttachment.deleteMany({ where: { messageId: message.id } });
      await tx.messageReceipt.updateMany({
        where: { messageId: message.id },
        data: { deletedAt },
      });
      return tx.message.findUnique({ where: { id: message.id } });
    });
    if (!updated) continue;
    expired += 1;
    realtime?.broadcastMessageUpdated(
      message.conversation.participants.map((participant) => participant.userId),
      {
        id: updated.id,
        conversationId: updated.conversationId,
        senderId: updated.senderId,
        body: "",
        attachment: null,
        replyToMessageId: null,
        editedAt: null,
        expirationMode: updated.expirationMode,
        expirationDurationSeconds: updated.expirationDurationSeconds,
        readAt: updated.readAt?.toISOString() ?? null,
        expiresAt: updated.expiresAt?.toISOString() ?? null,
        deletedAt: updated.deletedAt?.toISOString() ?? null,
        deletionReason: updated.deletionReason,
        tombstoneVersion: updated.tombstoneVersion,
        attachmentExpirationState: updated.attachmentExpirationState,
        isTombstone: true,
        createdAt: updated.createdAt.toISOString(),
        updatedAt: updated.updatedAt.toISOString(),
      },
    );
  }
  return expired;
}

export function startMessageExpirationWorker(
  prisma: PrismaClient,
  realtime?: MessageRealtimeServer,
): void {
  const intervalMs = Math.max(2_000, Number(process.env.MESSAGE_EXPIRATION_INTERVAL_MS ?? 10_000));
  const run = async () => {
    try {
      const expired = await expireDueMessages(prisma, realtime);
      if (expired > 0) logger.info({ expired }, "[messages:expiration] expired messages removed");
    } catch (error) {
      logger.error({ err: error }, "[messages:expiration] cleanup failed; retrying");
    }
  };
  void run();
  setInterval(() => void run(), intervalMs).unref();
  logger.info({ intervalMs }, "[messages:expiration] worker scheduled");
}
