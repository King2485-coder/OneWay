import type { PrismaClient } from "@prisma/client";

import { logger } from "../../lib/logger";
import { LedgerBalanceService } from "./LedgerBalanceService";

const ONE_DAY_MS = 24 * 60 * 60 * 1_000;

export async function runLedgerReconciliationOnce(prisma: PrismaClient, limit = 1_000): Promise<{
  checked: number;
  autoHealed: number;
  escalated: number;
}> {
  const ledger = new LedgerBalanceService(prisma);
  const accountIds = await ledger.listAccountIds(limit);
  let autoHealed = 0;
  let escalated = 0;

  for (const accountId of accountIds) {
    try {
      const result = await ledger.reconcileAccountBalance(accountId);
      if (result.action === "auto_healed") autoHealed += 1;
      if (result.action === "escalated") escalated += 1;
    } catch (error) {
      escalated += 1;
      logger.error({ err: error, accountId }, "[ledger] reconciliation failed");
    }
  }

  return { checked: accountIds.length, autoHealed, escalated };
}

export function startNightlyLedgerReconciliationJob(prisma: PrismaClient): NodeJS.Timeout | null {
  if (process.env.LEDGER_RECONCILIATION_JOB_ENABLED !== "true") {
    logger.info({}, "[ledger] nightly reconciliation job disabled");
    return null;
  }

  const run = () => {
    runLedgerReconciliationOnce(prisma, parseLimit())
      .then((result) => logger.info(result, "[ledger] nightly reconciliation completed"))
      .catch((error) => logger.error({ err: error }, "[ledger] nightly reconciliation failed"));
  };

  const timer = setInterval(run, ONE_DAY_MS);
  timer.unref?.();
  logger.info({}, "[ledger] nightly reconciliation job scheduled");
  return timer;
}

function parseLimit(): number {
  const parsed = Number.parseInt(process.env.LEDGER_RECONCILIATION_ACCOUNT_LIMIT ?? "1000", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1_000;
}
