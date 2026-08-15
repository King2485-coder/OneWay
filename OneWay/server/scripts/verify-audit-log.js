#!/usr/bin/env node
require("dotenv/config");

function parseArgs(argv) {
  const options = { limit: undefined };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--limit") options.limit = Number.parseInt(argv[++index] || "", 10);
    else if (arg.startsWith("--limit=")) options.limit = Number.parseInt(arg.slice("--limit=".length), 10);
  }
  if (!Number.isFinite(options.limit) || options.limit <= 0) options.limit = undefined;
  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const { prisma } = require("../dist/lib/db");
  const { verifyAuditLog } = require("../dist/services/audit/AuditEventService");
  try {
    const result = await verifyAuditLog(prisma, options);
    console.log(JSON.stringify(result, null, 2));
    if (!result.ok) process.exitCode = 1;
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }));
  process.exitCode = 1;
});
