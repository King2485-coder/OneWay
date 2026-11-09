import fs from "node:fs/promises";
import path from "node:path";

export type PrivacyMaintenanceRun = {
  command: string;
  dryRun: boolean;
  limit: number | null;
  scanned: number;
  updated: number;
  startedAt: string;
  finishedAt: string;
  ok: boolean;
};

const STATE_FILE = path.join(process.cwd(), ".privacy-maintenance-state.json");

export async function readPrivacyMaintenanceState(): Promise<{ lastRun: PrivacyMaintenanceRun | null }> {
  try {
    const raw = await fs.readFile(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw) as { lastRun?: PrivacyMaintenanceRun };
    return { lastRun: parsed.lastRun ?? null };
  } catch {
    return { lastRun: null };
  }
}

export async function writePrivacyMaintenanceRun(run: PrivacyMaintenanceRun): Promise<void> {
  await fs.writeFile(STATE_FILE, `${JSON.stringify({ lastRun: run }, null, 2)}\n`, "utf8");
}
