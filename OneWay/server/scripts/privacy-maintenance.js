#!/usr/bin/env node
require("dotenv/config");

const allowed = new Set([
  "status",
  "backfill-storefront-sensitive-fields",
  "backfill-external-conversations",
  "rotate-encrypted-fields",
  "dry-run",
]);

function parseArgs(argv) {
  const args = [...argv];
  const command = args.shift() || "status";
  const options = { limit: undefined, dryRun: false, targetKid: undefined };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--limit") options.limit = Number.parseInt(args[++index] || "", 10);
    else if (arg.startsWith("--limit=")) options.limit = Number.parseInt(arg.slice("--limit=".length), 10);
    else if (arg === "--target-kid") options.targetKid = args[++index];
    else if (arg.startsWith("--target-kid=")) options.targetKid = arg.slice("--target-kid=".length);
  }
  if (!Number.isFinite(options.limit) || options.limit <= 0) options.limit = undefined;
  return { command, options };
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2));
  if (!allowed.has(command)) {
    console.error(JSON.stringify({ ok: false, error: "unknown_command", allowed: Array.from(allowed).sort() }));
    process.exitCode = 1;
    return;
  }

  const encryption = require("../dist/services/privacy/EncryptionService");
  encryption.validateFieldEncryptionConfig();

  const startedAt = new Date().toISOString();
  const { prisma } = require("../dist/lib/db");
  const { buildPrivacyStatus } = require("../dist/services/privacy/PrivacyDiagnostics");
  const { runPrivacyMaintenance } = require("../dist/services/privacy/PrivacyMaintenance");
  const { writePrivacyMaintenanceRun } = require("../dist/services/privacy/PrivacyMaintenanceState");
  const { recordAuditEventSafe } = require("../dist/services/audit/AuditEventService");

  try {
    if (command === "status") {
      const status = await buildPrivacyStatus(prisma);
      console.log(JSON.stringify(status, null, 2));
      return;
    }

    const result = await runPrivacyMaintenance(prisma, command, options);
    const finishedAt = new Date().toISOString();
    await recordAuditEventSafe(prisma, {
      actorType: "system",
      action: command === "rotate-encrypted-fields" ? "encryption_key.rotation_run" : "privacy.maintenance_run",
      resourceType: "privacy",
      resourceId: result.targetKid,
      metadata: {
        command,
        dryRun: result.dryRun,
        limit: options.limit ?? null,
        scanned: result.scanned,
        updated: result.updated,
        sections: result.sections,
      },
    });
    await writePrivacyMaintenanceRun({
      command,
      dryRun: Boolean(result.dryRun),
      limit: options.limit ?? null,
      scanned: result.scanned,
      updated: result.updated,
      startedAt,
      finishedAt,
      ok: true,
    });
    console.log(JSON.stringify({ ok: true, ...result }, null, 2));
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }));
  process.exitCode = 1;
});
