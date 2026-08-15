#!/usr/bin/env node
require("dotenv/config");

const { validateFieldEncryptionConfig, isFieldEncryptionEnabled, getEncryptionStatus } = require("../dist/services/privacy/EncryptionService");

function parseArgs(argv) {
  const options = { limit: undefined, dryRun: false, targetKid: undefined };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--limit") options.limit = Number.parseInt(argv[++index] || "", 10);
    else if (arg.startsWith("--limit=")) options.limit = Number.parseInt(arg.slice("--limit=".length), 10);
    else if (arg === "--target-kid") options.targetKid = argv[++index];
    else if (arg.startsWith("--target-kid=")) options.targetKid = arg.slice("--target-kid=".length);
  }
  if (!Number.isFinite(options.limit) || options.limit <= 0) options.limit = undefined;
  return options;
}

async function main() {
  validateFieldEncryptionConfig();
  if (!isFieldEncryptionEnabled()) {
    console.log(JSON.stringify({ ok: true, skipped: true, reason: "field_encryption_not_enabled" }));
    return;
  }

  const options = parseArgs(process.argv.slice(2));
  options.targetKid = options.targetKid || getEncryptionStatus().currentKeyId;
  const { prisma } = require("../dist/lib/db");
  const { backfillExternalConversationPrivacy } = require("../dist/services/privacy/ConversationPrivacy");
  const { recordAuditEventSafe } = require("../dist/services/audit/AuditEventService");
  try {
    const result = await backfillExternalConversationPrivacy(prisma, options);
    await recordAuditEventSafe(prisma, {
      actorType: "system",
      action: "privacy.external_conversation_backfill_run",
      resourceType: "privacy",
      resourceId: result.targetKid,
      metadata: {
        dryRun: result.dryRun,
        scanned: result.scanned,
        updated: result.updated,
      },
    });
    console.log(JSON.stringify({ ok: true, ...result }));
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }));
  process.exitCode = 1;
});
