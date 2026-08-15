import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { PrismaClient } from "@prisma/client";
import { LocalObjectStorage } from "../../lib/storage/LocalObjectStorage";
import type { EmailOutboundMessageInput, EmailOutboundMessageResult, EmailProvider } from "./EmailProvider";
import { MailboxError, OneWayMailboxService } from "./OneWayMailboxService";

class CapturingMailgunProvider implements EmailProvider {
  name = "mailgun" as const;
  sent: EmailOutboundMessageInput[] = [];

  async sendOutboundMessage(input: EmailOutboundMessageInput): Promise<EmailOutboundMessageResult> {
    this.sent.push(input);
    return { providerMessageId: `test-mailgun-${this.sent.length}`, provider: this.name, status: "queued" };
  }
}

async function main() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "oneway-email-test-"));
  const databasePath = path.join(root, "mailbox.sqlite");
  process.env.DATABASE_URL = `file:${databasePath}`;
  const encryptionKey = Buffer.alloc(32, 1).toString("base64");
  const hashKey = Buffer.alloc(32, 2).toString("base64");
  process.env.FIELD_ENCRYPTION_ENABLED = "true";
  process.env.FIELD_ENCRYPTION_KEY_ID = "email-test-v1";
  process.env.FIELD_ENCRYPTION_KEYS_JSON = JSON.stringify({ "email-test-v1": encryptionKey });
  process.env.FIELD_HASH_KEY_BASE64 = hashKey;
  process.env.MAILGUN_API_KEY = "test-api-key";
  process.env.MAILGUN_WEBHOOK_SIGNING_KEY = "test-signing-key";
  process.env.ONEWAY_EMAIL_DOMAIN = "oneway.is";
  process.env.ONEWAY_EMAIL_DNS_VERIFIED = "true";
  process.env.ONEWAY_EMAIL_LIVE_DELIVERY_ENABLED = "false";
  process.env.ONEWAY_EMAIL_VERIFICATION_MODE = "true";
  process.env.ONEWAY_EMAIL_VERIFICATION_RECIPIENTS = "verified@example.com";
  execFileSync("sqlite3", [databasePath], {
    input: `PRAGMA foreign_keys=ON;
      CREATE TABLE "User" ("id" TEXT NOT NULL PRIMARY KEY, "displayName" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
      CREATE TABLE "OneWayIdentity" ("id" TEXT NOT NULL PRIMARY KEY, "userId" TEXT NOT NULL UNIQUE, "emailAlias" TEXT UNIQUE);`,
  });
  const prisma = new PrismaClient({ datasources: { db: { url: process.env.DATABASE_URL } } });
  const provider = new CapturingMailgunProvider();
  const service = new OneWayMailboxService(prisma, new LocalObjectStorage({ root, secret: "test-secret" }), provider);
  const alice = "00000000-0000-4000-8000-000000000001";
  const bob = "00000000-0000-4000-8000-000000000002";
  try {
    await prisma.user.createMany({ data: [{ id: alice, displayName: "Alice" }, { id: bob, displayName: "Bob" }] });
    const claimed = await service.claim(alice, "alice@oneway.is");
    assert.equal(claimed.address, "alice@oneway.is");
    assert.equal((await service.claim(alice, "other@oneway.is")).address, "alice@oneway.is", "claim is idempotent");

    await assert.rejects(() => service.claim(bob, "admin@oneway.is"), (error: unknown) => error instanceof MailboxError && error.code === "invalid_or_reserved_address");
    assert.equal(await service.getMailbox(bob), null);

    const draft = await service.saveDraft(alice, { to: ["friend@example.com"], subject: "Private hello", bodyText: "Mailbox body" }) as any;
    assert.equal(draft.folder, "drafts");
    assert.equal(draft.subject, "Private hello");
    const drafts = await service.list(alice, "drafts");
    assert.equal(drafts.messages.length, 1);

    const archived = await service.update(alice, draft.id, { folder: "archive", isStarred: true }) as any;
    assert.equal(archived.folder, "archive");
    assert.equal(archived.isStarred, true);

    const label = await service.createLabel(alice, "Receipts", "blue");
    const labeled = await service.setMessageLabels(alice, draft.id, [label.id]) as any;
    assert.deepEqual(labeled.labels, [label]);
    assert.deepEqual(await service.labels(alice), [label]);
    await assert.rejects(() => service.setMessageLabels(alice, draft.id, ["not-alices-label"]), (error: unknown) => error instanceof MailboxError && error.code === "invalid_label");
    await service.deleteLabel(alice, label.id);
    assert.deepEqual((await service.update(alice, draft.id, { isRead: true }) as any).labels, []);

    await assert.rejects(() => service.thread(bob, draft.threadId), (error: unknown) => error instanceof MailboxError && error.code === "mailbox_not_claimed");

    const sent = await service.send(alice, { to: ["verified@example.com"], subject: "Verification", bodyText: "Hello" }) as any;
    assert.equal(sent.status, "queued");
    assert.equal(provider.sent.length, 1);
    await assert.rejects(
      () => service.send(alice, { to: ["not-allowed@example.com"], subject: "Blocked", bodyText: "Hello" }),
      (error: unknown) => error instanceof MailboxError && error.code === "email_verification_recipient_not_allowed",
    );

    console.log("OneWay mailbox self-test passed");
  } finally {
    await prisma.$disconnect();
    fs.rmSync(root, { recursive: true, force: true });
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
