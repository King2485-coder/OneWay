import { prisma } from "../../lib/db";
import { logger } from "../../lib/logger";

let ensured = false;

export function normalizeSMSPhoneNumber(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  const digits = trimmed.replace(/[^\d]/g, "");
  if (!digits) return "";
  return trimmed.startsWith("+") ? `+${digits}` : digits;
}

async function ensureSMSOptOutTable(): Promise<void> {
  if (ensured) return;
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS SMSOptOut (
      phoneNumber TEXT PRIMARY KEY,
      optedOut BOOLEAN NOT NULL DEFAULT 1,
      keyword TEXT,
      provider TEXT NOT NULL DEFAULT 'twilio',
      updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  ensured = true;
}

export async function setSMSOptOut(
  phoneNumber: string,
  optedOut: boolean,
  keyword: string,
  provider = "twilio",
): Promise<void> {
  const normalized = normalizeSMSPhoneNumber(phoneNumber);
  if (!normalized) return;
  await ensureSMSOptOutTable();
  await prisma.$executeRawUnsafe(
    `
      INSERT INTO SMSOptOut (phoneNumber, optedOut, keyword, provider, updatedAt)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
      ON CONFLICT(phoneNumber) DO UPDATE SET
        optedOut = excluded.optedOut,
        keyword = excluded.keyword,
        provider = excluded.provider,
        updatedAt = CURRENT_TIMESTAMP
    `,
    normalized,
    optedOut ? 1 : 0,
    keyword,
    provider,
  );
}

export async function isSMSOptedOut(phoneNumber: string): Promise<boolean> {
  const normalized = normalizeSMSPhoneNumber(phoneNumber);
  if (!normalized) return false;
  try {
    await ensureSMSOptOutTable();
    const rows = await prisma.$queryRawUnsafe<Array<{ optedOut: boolean | number | string }>>(
      "SELECT optedOut FROM SMSOptOut WHERE phoneNumber = ? LIMIT 1",
      normalized,
    );
    const raw = rows[0]?.optedOut;
    return raw === true || raw === 1 || raw === "1";
  } catch (error) {
    logger.warn({ error, phoneNumber: normalized.slice(-4) }, "[sms] opt-out lookup failed");
    return false;
  }
}
