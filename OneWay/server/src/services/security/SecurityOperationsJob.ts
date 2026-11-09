import type { PrismaClient } from "@prisma/client";
import { logger } from "../../lib/logger";
import { runAuditSecurityCheck, runPrivacySecurityCheck } from "./SecurityCheckService";

const DAY_MS = 24 * 60 * 60 * 1000;

export function startDailySecurityOperationsJob(prisma: PrismaClient): void {
  if (!envFlag("SECURITY_OPERATIONS_JOB_ENABLED", true)) {
    logger.info({}, "[security] daily security operations job disabled");
    return;
  }

  const intervalMs = Number.parseInt(String(process.env.SECURITY_OPERATIONS_INTERVAL_MS ?? DAY_MS), 10) || DAY_MS;
  const runOnStartup = envFlag("SECURITY_OPERATIONS_RUN_ON_STARTUP", false);
  const initialDelayMs = runOnStartup ? 5_000 : intervalMs;

  const run = async () => {
    try {
      await runAuditSecurityCheck(prisma);
      await runPrivacySecurityCheck(prisma);
    } catch (error) {
      logger.error({ err: error }, "[security] daily security operations job failed");
    }
  };

  setTimeout(() => {
    void run();
    setInterval(() => void run(), intervalMs).unref();
  }, initialDelayMs).unref();

  logger.info({ intervalMs, runOnStartup }, "[security] daily security operations job scheduled");
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}
