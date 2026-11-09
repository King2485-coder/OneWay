import type { PrismaClient } from "@prisma/client";
import { randomUUID } from "node:crypto";
import { redactSensitiveObject, shortId } from "../../lib/privacy/redaction";

export type SecuritySeverity = "info" | "warning" | "critical";
export type SecurityCheckStatus = "passed" | "warning" | "failed";

export type SecurityCheckRunInput = {
  checkType: string;
  status: SecurityCheckStatus;
  severity: SecuritySeverity;
  summary: string;
  details?: Record<string, unknown>;
  startedAt: Date;
  finishedAt: Date;
  dryRun?: boolean;
};

export type SecurityCheckRunDTO = {
  id: string;
  checkType: string;
  status: SecurityCheckStatus;
  severity: SecuritySeverity;
  summary: string;
  details: Record<string, unknown>;
  startedAt: string;
  finishedAt: string;
};

let securityCheckTableReady = false;

export async function ensureSecurityCheckRunTable(prisma: PrismaClient): Promise<void> {
  if (securityCheckTableReady) return;
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "SecurityCheckRun" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "checkType" TEXT NOT NULL,
      "status" TEXT NOT NULL,
      "severity" TEXT NOT NULL,
      "summary" TEXT NOT NULL,
      "detailsJson" TEXT NOT NULL DEFAULT '{}',
      "startedAt" DATETIME NOT NULL,
      "finishedAt" DATETIME NOT NULL
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SecurityCheckRun_checkType_finishedAt_idx" ON "SecurityCheckRun"("checkType", "finishedAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SecurityCheckRun_severity_finishedAt_idx" ON "SecurityCheckRun"("severity", "finishedAt")`);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "SecurityCheckRun_status_finishedAt_idx" ON "SecurityCheckRun"("status", "finishedAt")`);
  securityCheckTableReady = true;
}

export async function recordSecurityCheckRun(prisma: PrismaClient, input: SecurityCheckRunInput): Promise<SecurityCheckRunDTO> {
  const details = redactSensitiveObject(input.details ?? {}) as Record<string, unknown>;
  const dto: SecurityCheckRunDTO = {
    id: randomUUID(),
    checkType: input.checkType,
    status: input.status,
    severity: input.severity,
    summary: input.summary.slice(0, 500),
    details,
    startedAt: input.startedAt.toISOString(),
    finishedAt: input.finishedAt.toISOString(),
  };
  if (!input.dryRun) {
    await ensureSecurityCheckRunTable(prisma);
    await prisma.securityCheckRun.create({
      data: {
        id: dto.id,
        checkType: dto.checkType,
        status: dto.status,
        severity: dto.severity,
        summary: dto.summary,
        detailsJson: JSON.stringify(details),
        startedAt: input.startedAt,
        finishedAt: input.finishedAt,
      },
    });
  }
  return { ...dto, id: shortId(dto.id, 8) ?? dto.id };
}

export async function latestSecurityCheckRuns(prisma: PrismaClient): Promise<{
  audit: SecurityCheckRunDTO | null;
  privacy: SecurityCheckRunDTO | null;
  secrets: SecurityCheckRunDTO | null;
  latestAlerts: SecurityCheckRunDTO[];
}> {
  await ensureSecurityCheckRunTable(prisma);
  const [audit, privacy, secrets, latestAlerts] = await Promise.all([
    latestByType(prisma, "audit"),
    latestByType(prisma, "privacy"),
    latestByType(prisma, "secrets"),
    prisma.securityCheckRun.findMany({
      where: { severity: { in: ["warning", "critical"] } },
      orderBy: { finishedAt: "desc" },
      take: 10,
    }),
  ]);
  return {
    audit: audit ? toDTO(audit) : null,
    privacy: privacy ? toDTO(privacy) : null,
    secrets: secrets ? toDTO(secrets) : null,
    latestAlerts: latestAlerts.map(toDTO),
  };
}

async function latestByType(prisma: PrismaClient, checkType: string) {
  return prisma.securityCheckRun.findFirst({ where: { checkType }, orderBy: { finishedAt: "desc" } });
}

function toDTO(run: {
  id: string;
  checkType: string;
  status: string;
  severity: string;
  summary: string;
  detailsJson: string;
  startedAt: Date;
  finishedAt: Date;
}): SecurityCheckRunDTO {
  return {
    id: shortId(run.id, 8) ?? run.id,
    checkType: run.checkType,
    status: normalizeStatus(run.status),
    severity: normalizeSeverity(run.severity),
    summary: run.summary,
    details: parseDetails(run.detailsJson),
    startedAt: run.startedAt.toISOString(),
    finishedAt: run.finishedAt.toISOString(),
  };
}

function parseDetails(value: string): Record<string, unknown> {
  try {
    return redactSensitiveObject(JSON.parse(value) as Record<string, unknown>) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function normalizeStatus(value: string): SecurityCheckStatus {
  return value === "failed" || value === "warning" ? value : "passed";
}

function normalizeSeverity(value: string): SecuritySeverity {
  return value === "critical" || value === "warning" ? value : "info";
}
