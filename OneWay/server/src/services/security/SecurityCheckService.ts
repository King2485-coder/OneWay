import type { PrismaClient } from "@prisma/client";
import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { logger } from "../../lib/logger";
import { auditStatus, verifyAuditLog } from "../audit/AuditEventService";
import { getEncryptionStatus } from "../privacy/EncryptionService";
import { buildPrivacyStatus, type PrivacyStatus } from "../privacy/PrivacyDiagnostics";
import { sendSecurityAlert } from "./SecurityAlertService";
import { latestSecurityCheckRuns, recordSecurityCheckRun, type SecurityCheckRunDTO, type SecuritySeverity } from "./SecurityCheckRunService";

const execFileAsync = promisify(execFile);

export type SecurityCheckOptions = {
  dryRun?: boolean;
  noAlert?: boolean;
  limit?: number;
};

export type SecurityCheckResult = {
  ok: boolean;
  run: SecurityCheckRunDTO;
  alert?: { delivered: boolean; provider: string; mode: "email" | "stub" | "none" } | null;
};

export async function runAuditSecurityCheck(prisma: PrismaClient, options: SecurityCheckOptions = {}): Promise<SecurityCheckResult> {
  const startedAt = new Date();
  const verification = await verifyAuditLog(prisma, { limit: options.limit ?? 10_000 });
  const finishedAt = new Date();
  const failed = !verification.ok;
  const run = await recordSecurityCheckRun(prisma, {
    checkType: "audit",
    status: failed ? "failed" : "passed",
    severity: failed ? "critical" : "info",
    summary: failed ? "Audit hash chain verification failed." : "Audit hash chain verified.",
    details: {
      checked: verification.checked,
      reason: verification.reason ?? null,
      firstBrokenEventId: verification.firstBrokenEventId ?? null,
      firstBrokenEventCreatedAt: verification.firstBrokenEventCreatedAt ?? null,
    },
    startedAt,
    finishedAt,
    dryRun: options.dryRun,
  });
  const alert = failed && !options.noAlert
    ? await sendSecurityAlert({ severity: "critical", title: "Audit chain broken", summary: run.summary, details: run.details })
    : null;
  return { ok: !failed, run, alert };
}

export async function runPrivacySecurityCheck(prisma: PrismaClient, options: SecurityCheckOptions = {}): Promise<SecurityCheckResult> {
  const startedAt = new Date();
  const privacy = await buildPrivacyStatus(prisma);
  const previousRuns = await latestSecurityCheckRuns(prisma).catch(() => null);
  const previousPlaintextLegacyValues = typeof previousRuns?.privacy?.details?.plaintextLegacyValues === "number"
    ? previousRuns.privacy.details.plaintextLegacyValues
    : null;
  const analysis = analyzePrivacyStatus(privacy, previousPlaintextLegacyValues);
  const finishedAt = new Date();
  const run = await recordSecurityCheckRun(prisma, {
    checkType: "privacy",
    status: analysis.status,
    severity: analysis.severity,
    summary: analysis.summary,
    details: analysis.details,
    startedAt,
    finishedAt,
    dryRun: options.dryRun,
  });
  const alert = analysis.severity !== "info" && !options.noAlert
    ? await sendSecurityAlert({ severity: analysis.severity, title: "Privacy diagnostics warning", summary: run.summary, details: run.details })
    : null;
  return { ok: analysis.status !== "failed", run, alert };
}

export async function runSecretScanSecurityCheck(prisma: PrismaClient, options: SecurityCheckOptions = {}): Promise<SecurityCheckResult> {
  const startedAt = new Date();
  const result = await runSecretScanner();
  const finishedAt = new Date();
  const run = await recordSecurityCheckRun(prisma, {
    checkType: "secrets",
    status: result.ok ? "passed" : "failed",
    severity: result.ok ? "info" : "critical",
    summary: result.ok ? "Secret scan passed." : "Secret scanner found possible committed secrets.",
    details: result,
    startedAt,
    finishedAt,
    dryRun: options.dryRun,
  });
  const alert = !result.ok && !options.noAlert
    ? await sendSecurityAlert({ severity: "critical", title: "Secret scanner failure", summary: run.summary, details: run.details })
    : null;
  return { ok: result.ok, run, alert };
}

export async function runAllSecurityChecks(prisma: PrismaClient, options: SecurityCheckOptions = {}): Promise<{ ok: boolean; results: Record<string, SecurityCheckResult> }> {
  const audit = await runAuditSecurityCheck(prisma, options);
  const privacy = await runPrivacySecurityCheck(prisma, options);
  const secrets = await runSecretScanSecurityCheck(prisma, options);
  return { ok: audit.ok && privacy.ok && secrets.ok, results: { audit, privacy, secrets } };
}

export async function buildAdminSecurityStatus(prisma: PrismaClient): Promise<Record<string, unknown>> {
  const [checks, audit] = await Promise.all([
    latestSecurityCheckRuns(prisma),
    auditStatus(prisma).catch(() => null),
  ]);
  return {
    ok: true,
    latestAuditVerification: checks.audit,
    latestPrivacyDiagnostics: checks.privacy,
    latestSecretScan: checks.secrets,
    latestAlerts: checks.latestAlerts,
    auditSummary: audit,
  };
}

function analyzePrivacyStatus(privacy: PrivacyStatus, previousPlaintextLegacyValues: number | null): { status: "passed" | "warning" | "failed"; severity: SecuritySeverity; summary: string; details: Record<string, unknown> } {
  const encryption = getEncryptionStatus();
  const plaintextLegacyValues = totalPlaintextLegacyValues(privacy);
  const externalUnprotected = privacy.sensitiveData.externalConversations.plaintextLegacy
    + privacy.sensitiveData.externalConversations.missingHash
    + privacy.sensitiveData.externalConversations.missingCiphertext;
  const issues: string[] = [];
  let severity: SecuritySeverity = "info";
  let status: "passed" | "warning" | "failed" = "passed";

  if (encryption.invalidKeyIds.length > 0 || (encryption.requested && !encryption.enabled)) {
    issues.push("Encryption key configuration is invalid.");
    severity = "critical";
    status = "failed";
  }
  if (encryption.hashKeyRequired && !encryption.hashKeyConfigured) {
    issues.push("Lookup hash key is missing.");
    severity = "critical";
    status = "failed";
  }
  if (!encryption.enabled && isProductionLike()) {
    issues.push("Field encryption is disabled in a production-like environment.");
    severity = process.env.NODE_ENV === "production" ? "critical" : maxSeverity(severity, "warning");
    status = process.env.NODE_ENV === "production" ? "failed" : status === "failed" ? "failed" : "warning";
  }
  if (plaintextLegacyValues > 0) {
    issues.push("Plaintext legacy sensitive values remain.");
    severity = maxSeverity(severity, "warning");
    if (status === "passed") status = "warning";
  }
  if (previousPlaintextLegacyValues !== null && plaintextLegacyValues > previousPlaintextLegacyValues) {
    issues.push("Plaintext legacy sensitive value count increased.");
    severity = maxSeverity(severity, "warning");
    if (status === "passed") status = "warning";
  }
  if (externalUnprotected > 0) {
    issues.push("External conversation protection is incomplete.");
    severity = maxSeverity(severity, "warning");
    if (status === "passed") status = "warning";
  }
  if (oneWayBankAccidentallyEnabled()) {
    issues.push("OneWay Bank appears enabled without explicit production approval.");
    severity = "critical";
    status = "failed";
  }

  return {
    status,
    severity,
    summary: issues.length > 0 ? issues.join(" ") : "Privacy diagnostics are healthy.",
    details: {
      encryptionEnabled: encryption.enabled,
      currentKeyId: encryption.currentKeyId,
      availableKeyCount: encryption.availableKeyCount,
      hashKeyConfigured: encryption.hashKeyConfigured,
      invalidKeyCount: encryption.invalidKeyIds.length,
      plaintextLegacyValues,
      previousPlaintextLegacyValues,
      externalConversationProtected: privacy.sensitiveData.externalConversations.protected,
      externalConversationUnprotected: externalUnprotected,
      oneWayBankEnabled: envFlag("ONEWAY_BANK_ENABLED", false),
      oneWayBankProductionApproved: envFlag("ONEWAY_BANK_PRODUCTION_APPROVED", false),
    },
  };
}

function totalPlaintextLegacyValues(privacy: PrivacyStatus): number {
  const sensitive = privacy.sensitiveData;
  return sensitive.storefrontInquiries.plaintextLegacyValues
    + sensitive.storefrontOrders.plaintextLegacyValues
    + sensitive.storeNotifications.plaintextLegacyValues
    + sensitive.storeEmailMessages.plaintextLegacyValues
    + sensitive.oneWayMessages.plaintextLegacyValues
    + sensitive.externalConversations.plaintextLegacy;
}

async function runSecretScanner(): Promise<{ ok: boolean; findings: number; error?: string }> {
  const scriptPath = path.join(process.cwd(), "scripts", "scan-secrets.js");
  try {
    const { stdout } = await execFileAsync(process.execPath, [scriptPath], { cwd: process.cwd(), maxBuffer: 1024 * 1024 });
    const parsed = JSON.parse(stdout.trim() || "{}") as { ok?: boolean; findings?: unknown };
    return { ok: parsed.ok === true, findings: typeof parsed.findings === "number" ? parsed.findings : 0 };
  } catch (error: any) {
    const output = String(error?.stdout || error?.stderr || error?.message || "secret_scan_failed");
    try {
      const parsed = JSON.parse(output) as { findings?: unknown[] };
      return { ok: false, findings: Array.isArray(parsed.findings) ? parsed.findings.length : 1 };
    } catch {
      logger.warn({ err: error }, "[security] secret scan failed");
      return { ok: false, findings: 1, error: "secret_scan_failed" };
    }
  }
}

function isProductionLike(): boolean {
  const env = String(process.env.NODE_ENV || process.env.APP_ENV || process.env.ONEWAY_ENV || "development").toLowerCase();
  return !["development", "dev", "local", "test"].includes(env);
}

function oneWayBankAccidentallyEnabled(): boolean {
  return envFlag("ONEWAY_BANK_ENABLED", false) && !envFlag("ONEWAY_BANK_PRODUCTION_APPROVED", false);
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function maxSeverity(current: SecuritySeverity, next: SecuritySeverity): SecuritySeverity {
  const order: Record<SecuritySeverity, number> = { info: 0, warning: 1, critical: 2 };
  return order[next] > order[current] ? next : current;
}
