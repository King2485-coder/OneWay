import type { PrismaClient } from "@prisma/client";
import { PrismaClient as Prisma } from "@prisma/client";
import { z } from "zod";

export function createPrismaClient(): PrismaClient {
  return new Prisma();
}

export function getDevUserId(req: { headers: Record<string, string | string[] | undefined> }): string {
  const header = req.headers["x-dev-user-id"];
  const value = Array.isArray(header) ? header[0] : header;
  if (value && value.trim().length > 0) return value.trim();
  return process.env.DEFAULT_DEV_USER_ID || "00000000-0000-0000-0000-000000000000";
}

export function safeSlug(input: string): string {
  const base = input
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return base.length > 0 ? base : `store-${Date.now()}`;
}

export const uuidSchema = z.string().uuid();

