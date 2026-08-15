#!/usr/bin/env node
require("dotenv/config");

const commands = new Set(["all", "audit", "privacy", "secrets"]);

function parseArgs(argv) {
  const args = [...argv];
  const command = args.shift() || "all";
  const options = { dryRun: false, noAlert: false, limit: undefined };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--no-alert") options.noAlert = true;
    else if (arg === "--limit") options.limit = Number.parseInt(args[++index] || "", 10);
    else if (arg.startsWith("--limit=")) options.limit = Number.parseInt(arg.slice("--limit=".length), 10);
  }
  if (!Number.isFinite(options.limit) || options.limit <= 0) options.limit = undefined;
  return { command, options };
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2));
  if (!commands.has(command)) {
    console.error(JSON.stringify({ ok: false, error: "unknown_command", allowed: Array.from(commands).sort() }));
    process.exitCode = 1;
    return;
  }

  const { prisma } = require("../dist/lib/db");
  const {
    runAllSecurityChecks,
    runAuditSecurityCheck,
    runPrivacySecurityCheck,
    runSecretScanSecurityCheck,
  } = require("../dist/services/security/SecurityCheckService");

  try {
    const result = command === "all"
      ? await runAllSecurityChecks(prisma, options)
      : command === "audit"
        ? await runAuditSecurityCheck(prisma, options)
        : command === "privacy"
          ? await runPrivacySecurityCheck(prisma, options)
          : await runSecretScanSecurityCheck(prisma, options);
    console.log(JSON.stringify(result, null, 2));
    if (result.ok === false) process.exitCode = 1;
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }));
  process.exitCode = 1;
});
