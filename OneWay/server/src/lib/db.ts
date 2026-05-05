/**
 * Shared Prisma client. Single instance app-wide; do NOT instantiate
 * `new PrismaClient()` anywhere else — connection-pool-per-import is a
 * common production pitfall.
 */
import { PrismaClient } from "@prisma/client";

declare global {
  // eslint-disable-next-line no-var
  var __prisma: PrismaClient | undefined;
}

export const prisma: PrismaClient =
  global.__prisma ??
  new PrismaClient({
    log: process.env.NODE_ENV === "production" ? ["warn", "error"] : ["info", "warn", "error"],
  });

if (process.env.NODE_ENV !== "production") {
  // Hot-reload guard: tsx restarts re-import this module without exiting
  // the parent process, which would otherwise leak Prisma clients.
  global.__prisma = prisma;
}

export async function shutdownDb(): Promise<void> {
  await prisma.$disconnect();
}
