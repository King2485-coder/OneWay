import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PrismaClient } from "@prisma/client";
import { expireDueMessages } from "./MessageExpirationService";
import { BURN_SUBSYSTEMS, executeBurnRequest } from "./OneWayBurnService";
import { ensurePrivacyLifecycleSchema } from "./privacy/PrivacyLifecycleSchema";

async function main() {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "oneway-privacy-lifecycle-"));
  const databasePath = join(temporaryDirectory, "self-test.db");
  closeSync(openSync(databasePath, "w"));
  process.env.DATABASE_URL = `file:${databasePath}`;
  const pushSchema = () => execFileSync("npx", ["prisma", "db", "push", "--skip-generate"], {
    cwd: process.cwd(), env: process.env, stdio: "ignore",
  });
  try { pushSchema(); }
  catch { pushSchema(); } // Prisma's SQLite engine can require a second open immediately after creating the file.
  const prisma = new PrismaClient();
  const suffix = Date.now().toString(36);
  const senderId = `privacy-sender-${suffix}`;
  const recipientId = `privacy-recipient-${suffix}`;
  const burnUserId = `burn-user-${suffix}`;
  try {
    await ensurePrivacyLifecycleSchema(prisma);
    await prisma.user.createMany({ data: [
      { id: senderId, displayName: "Privacy Sender" },
      { id: recipientId, displayName: "Privacy Recipient" },
      { id: burnUserId, displayName: "Burn User" },
    ] });
    const conversation = await prisma.conversation.create({
      data: { type: "direct", participants: { create: [{ userId: senderId }, { userId: recipientId }] } },
    });
    const message = await prisma.message.create({
      data: {
        conversationId: conversation.id,
        senderId,
        ciphertext: JSON.stringify({ body: "must-not-survive", attachment: { fileName: "secret.txt" } }),
        expirationMode: "after_read",
        expirationDurationSeconds: 0,
        readAt: new Date(Date.now() - 2_000),
        expiresAt: new Date(Date.now() - 1_000),
        attachmentExpirationState: "active",
        attachments: { create: { mimeType: "text/plain", url: "https://invalid.test/secret" } },
        receipts: { create: { userId: recipientId, status: "read", readAt: new Date(Date.now() - 2_000) } },
      },
    });

    assert.equal(await expireDueMessages(prisma), 1);
    assert.equal(await expireDueMessages(prisma), 0, "expiration must be idempotent");
    const expired = await prisma.message.findUnique({ where: { id: message.id }, include: { attachments: true } });
    assert(expired?.deletedAt);
    assert.equal(expired?.attachments.length, 0);
    assert(!expired?.ciphertext.includes("must-not-survive"));
    assert(!expired?.ciphertext.includes("secret.txt"));

    const burn = await prisma.accountBurnRequest.create({
      data: {
        userId: burnUserId,
        status: "scheduled",
        scheduledFor: new Date(),
        authenticationMethod: "password",
        immediateBurn: true,
        steps: { create: BURN_SUBSYSTEMS.map((subsystem) => ({ subsystem })) },
      },
    });
    await executeBurnRequest(prisma, burn.id);
    assert.equal(await prisma.user.findUnique({ where: { id: burnUserId } }), null);
    const completed = await prisma.accountBurnRequest.findUnique({ where: { id: burn.id }, include: { steps: true } });
    assert.equal(completed?.status, "completed");
    assert(completed?.steps.every((step) => step.status === "completed"));
    await prisma.accountBurnRequest.deleteMany({ where: { userId: burnUserId } });
    await prisma.conversation.delete({ where: { id: conversation.id } });
    await prisma.user.deleteMany({ where: { id: { in: [senderId, recipientId] } } });
    console.log("privacy lifecycle self-test passed");
  } finally {
    await prisma.$disconnect();
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
