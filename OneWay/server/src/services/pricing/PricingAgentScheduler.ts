import type { PrismaClient } from "@prisma/client";
import { logger } from "../../lib/logger";
import { PricingAgent } from "./PricingAgent";

const MAX_TIMER_MS = 24 * 60 * 60 * 1000;

export function startPricingAgentMonthlyJob(prisma: PrismaClient): void {
  if (!envFlag("PRICING_AGENT_JOB_ENABLED", true)) {
    logger.info({}, "PRICING_AGENT_MONTHLY_JOB_DISABLED");
    return;
  }
  const scheduleNext = () => {
    const now = new Date();
    const target = nextPhoenixRun(now);
    const delay = Math.min(MAX_TIMER_MS, Math.max(1_000, target.getTime() - now.getTime()));
    setTimeout(async () => {
      const current = new Date();
      if (Math.abs(current.getTime() - target.getTime()) < 15 * 60 * 1000) {
        try { await new PricingAgent(prisma).run({ actorId: "pricing-agent-scheduler", now: current }); }
        catch (error) { logger.error({ err: error }, "PRICING_AGENT_MONTHLY_JOB_FAILED"); }
      }
      scheduleNext();
    }, delay).unref();
    logger.info({ nextRunAt: target.toISOString(), timezone: "America/Phoenix" }, "PRICING_AGENT_MONTHLY_JOB_SCHEDULED");
  };
  scheduleNext();
}

export function nextPhoenixRun(now: Date): Date {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Phoenix", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", hourCycle: "h23" }).formatToParts(now);
  const value = (type: string) => Number(parts.find((part) => part.type === type)?.value);
  let year = value("year"); let month = value("month");
  const day = value("day"); const hour = value("hour");
  if (day > 5 || (day === 5 && hour >= 9)) { month += 1; if (month === 13) { month = 1; year += 1; } }
  return new Date(Date.UTC(year, month - 1, 5, 16, 0, 0)); // Phoenix is UTC-7 year-round.
}

function envFlag(name: string, fallback: boolean): boolean { const value = process.env[name]; return value == null || !value.trim() ? fallback : ["1", "true", "yes", "on"].includes(value.trim().toLowerCase()); }
