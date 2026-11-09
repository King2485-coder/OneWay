import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = process.cwd();
const swiftRoot = path.join(root, "OneWay");
const output = path.join(root, "Docs", "OneWayPhysicalIconImplementation.md");

const files = execFileSync(
  "rg",
  ["-l", "OneWayResolvedIcon|OneWayResolvedLabel|OneWayResolvedButton|OneWayPhysicalIcon", swiftRoot, "--glob", "*.swift"],
  { encoding: "utf8" }
)
  .trim()
  .split("\n")
  .filter(Boolean)
  .map((file) => path.relative(root, file))
  .sort();

const assets = fs
  .readdirSync(path.join(swiftRoot, "Assets.xcassets"), { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && entry.name.startsWith("OneWayPhysical") && entry.name.endsWith(".imageset"))
  .map((entry) => entry.name.replace(/\.imageset$/, ""))
  .sort();

const directImages = Number(execFileSync(
  "sh",
  ["-c", "rg -F -o 'OneWayResolvedIcon(systemName:' OneWay --glob '*.swift' | wc -l"],
  { cwd: root, encoding: "utf8" }
).trim());
const resolvedLabels = Number(execFileSync(
  "sh",
  ["-c", "rg -F -o 'OneWayResolvedLabel(' OneWay --glob '*.swift' | wc -l"],
  { cwd: root, encoding: "utf8" }
).trim());
const resolvedButtons = Number(execFileSync(
  "sh",
  ["-c", "rg -F -o 'OneWayResolvedButton(' OneWay --glob '*.swift' | wc -l"],
  { cwd: root, encoding: "utf8" }
).trim());

const markdown = `# OneWay Physical Icon Implementation

Generated from the current source tree after the app-wide migration.

## Coverage

- ${directImages} direct symbol-image requests routed through the semantic provider
- ${resolvedLabels} symbol labels routed through a real SwiftUI Label compatibility bridge
- ${resolvedButtons} system-image buttons routed through the semantic provider
- ${assets.length} individually addressable physical PNG image sets
- Official third-party Portal logo assets preserved

## Modified Swift files (${files.length})

${files.map((file) => `- \`${file}\``).join("\n")}

## New asset-catalog entries (${assets.length})

${assets.map((asset) => `- \`${asset}\``).join("\n")}

## Supporting files

- \`Docs/OneWayIconAudit.md\`
- \`Docs/OneWayPhysicalIconPrompts.md\`
- \`scripts/generate-icon-audit.mjs\`
- \`scripts/install-physical-icons.mjs\`
- \`scripts/generate-physical-icon-report.mjs\`
`;

fs.writeFileSync(output, markdown);
console.log(`Wrote ${path.relative(root, output)}`);
