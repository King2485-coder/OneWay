import type { PrismaClient } from "@prisma/client";

import { logger } from "./logger";

type RuntimeDatabaseProvider = "sqlite" | "postgres" | "unknown";
export type RuntimeSchemaPatchResult = "applied" | "skipped";

export async function addColumnIfMissing(prisma: PrismaClient, input: {
  table: string;
  columnDefinition: string;
  logPrefix?: string;
}): Promise<RuntimeSchemaPatchResult> {
  const table = input.table;
  const columnDefinition = input.columnDefinition;
  const logPrefix = input.logPrefix ?? "storefront schema patch";
  const provider = detectRuntimeProvider(process.env.DATABASE_URL);
  const columnName = parseColumnName(columnDefinition);

  if (columnName) {
    const exists = await columnExists(prisma, provider, table, columnName);
    if (exists) {
      logger.info({
        provider,
        table,
        column: columnName,
      }, `${logPrefix} skipped: column already exists`);
      return "skipped";
    }
  }

  try {
    await prisma.$executeRawUnsafe(`ALTER TABLE "${table}" ADD COLUMN ${columnDefinition}`);
    logger.info({
      provider,
      table,
      column: columnName ?? "unknown",
    }, `${logPrefix} applied: column added`);
    return "applied";
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (isDuplicateColumnError(message)) {
      logger.info({
        provider,
        table,
        column: columnName ?? "unknown",
      }, `${logPrefix} skipped: column already exists`);
      return "skipped";
    }
    throw error;
  }
}

function parseColumnName(columnDefinition: string): string | null {
  return columnDefinition.match(/^\s*"([^"]+)"/)?.[1] ?? null;
}

function detectRuntimeProvider(databaseUrl: string | undefined): RuntimeDatabaseProvider {
  const value = String(databaseUrl ?? "").trim().toLowerCase();
  if (value.startsWith("file:")) return "sqlite";
  if (value.startsWith("postgres://") || value.startsWith("postgresql://")) return "postgres";
  return "unknown";
}

async function columnExists(
  prisma: PrismaClient,
  provider: RuntimeDatabaseProvider,
  table: string,
  column: string,
): Promise<boolean> {
  if (provider === "sqlite") {
    const columns = await prisma.$queryRawUnsafe<Array<{ name?: string }>>(`PRAGMA table_info("${table}")`);
    return columns.some((item) => item.name === column);
  }

  if (provider === "postgres") {
    const rows = await prisma.$queryRaw<Array<{ present: number }>>`
      SELECT 1 AS present
      FROM information_schema.columns
      WHERE table_schema = ANY (current_schemas(false))
        AND table_name = ${table}
        AND column_name = ${column}
      LIMIT 1
    `;
    return rows.length > 0;
  }

  return false;
}

function isDuplicateColumnError(value: string): boolean {
  const normalized = value.toLowerCase();
  return normalized.includes("duplicate column")
    || normalized.includes("already exists")
    || (normalized.includes("column") && normalized.includes("exists"));
}
