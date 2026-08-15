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
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS SMSConsent (
      phoneNumber TEXT NOT NULL,
      userId TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'granted',
      source TEXT NOT NULL,
      evidenceAt DATETIME NOT NULL,
      updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (phoneNumber, userId)
    )
  `);
  ensured = true;
}

export async function recordSMSConsent(input: {
  phoneNumber: string;
  userId: string;
  granted: boolean;
  source: string;
  evidenceAt?: Date;
}): Promise<void> {
  const normalized = normalizeSMSPhoneNumber(input.phoneNumber);
  if (!normalized || !input.userId) throw new Error("invalid_sms_consent_record");
  await ensureSMSOptOutTable();
  await prisma.$executeRawUnsafe(
    `INSERT INTO SMSConsent (phoneNumber, userId, status, source, evidenceAt, updatedAt)
     VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
     ON CONFLICT(phoneNumber, userId) DO UPDATE SET
       status = excluded.status, source = excluded.source,
       evidenceAt = excluded.evidenceAt, updatedAt = CURRENT_TIMESTAMP`,
    normalized,
    input.userId,
    input.granted ? "granted" : "revoked",
    input.source.slice(0, 80),
    (input.evidenceAt ?? new Date()).toISOString(),
  );
}

export async function hasSMSConsent(phoneNumber: string, userId: string): Promise<boolean> {
  const normalized = normalizeSMSPhoneNumber(phoneNumber);
  if (!normalized || !userId) return false;
  try {
    await ensureSMSOptOutTable();
    const rows = await prisma.$queryRawUnsafe<Array<{ status: string }>>(
      "SELECT status FROM SMSConsent WHERE phoneNumber = ? AND userId = ? LIMIT 1",
      normalized,
      userId,
    );
    return rows[0]?.status === "granted";
  } catch (error) {
    logger.warn({ error, phoneNumber: normalized.slice(-4) }, "[sms] consent lookup failed");
    return false;
  }
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
  if (optedOut) {
    await prisma.$executeRawUnsafe(
      "UPDATE SMSConsent SET status = 'revoked', source = ?, updatedAt = CURRENT_TIMESTAMP WHERE phoneNumber = ?",
      `${provider}:${keyword}`,
      normalized,
    );
  } else {
    await prisma.$executeRawUnsafe(
      "UPDATE SMSConsent SET status = 'granted', source = ?, evidenceAt = CURRENT_TIMESTAMP, updatedAt = CURRENT_TIMESTAMP WHERE phoneNumber = ?",
      `${provider}:${keyword}`,
      normalized,
    );
  }
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
    return process.env.NODE_ENV === "production";
  }
}
