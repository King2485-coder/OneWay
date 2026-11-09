import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const sourceRoot = path.join(root, "OneWay");
const outputPath = path.join(root, "Docs", "OneWayIconAudit.md");

const roleRules = [
  [/atom|globe|safari|network|circle\.hexagongrid/i, ["quantum", "physical portal or dimensional browser orb"]],
  [/person\.3|person\.2|person\.crop|figure/i, ["community", "dimensional people figures or identity card"]],
  [/phone|handset/i, ["calls", "rounded physical handset"]],
  [/video|camera/i, ["videoCall", "dimensional camera"]],
  [/storefront|building\.2|shop/i, ["shops", "miniature physical storefront"]],
  [/shippingbox|cube|archivebox/i, ["product", "physical package or product box"]],
  [/bag|cart/i, ["shopSlot", "physical shopping bag"]],
  [/message|bubble|paperplane/i, ["messages", "layered message cards"]],
  [/mic|waveform|radiowaves/i, ["chirp", "push-to-talk radio or microphone"]],
  [/wallet|creditcard|banknote|dollarsign/i, ["wallet", "wallet or payment terminal"]],
  [/cloud/i, ["cloud", "secure dimensional cloud container"]],
  [/desktop|rectangle\.3|macwindow/i, ["workspace", "physical dashboard or work tray"]],
  [/doc|folder|tray/i, ["files", "folder, document case, or file container"]],
  [/calendar/i, ["calendar", "physical calendar card"]],
  [/envelope|mail/i, ["email", "physical envelope or mail tray"]],
  [/gear|slider|dial/i, ["settings", "machined control dial"]],
  [/shield|lock|key/i, ["privacy", "secure shield, lock, or vault"]],
  [/bell/i, ["notifications", "dimensional bell"]],
  [/magnifyingglass/i, ["search", "physical magnifying glass"]],
  [/xmark\.octagon|xmark\.circle/i, ["error", "red dimensional alert badge"]],
  [/exclamation|warning/i, ["warning", "amber dimensional caution badge"]],
  [/(^|[."' ])tag([."' ]|$)/i, ["sellerID", "physical merchandise tag"]],
  [/receipt/i, ["receipt", "paper receipt"]],
  [/checkmark\.seal|checkmark\.circle/i, ["success", "green verification seal"]],
  [/trash/i, ["delete", "physical waste bin with destructive treatment"]],
  [/pencil|square\.and\.pencil/i, ["edit", "physical pencil or edit card"]],
  [/square\.and\.arrow\.up|share/i, ["share", "physical share tray"]],
  [/chevron\.left|arrow\.left/i, ["back", "system-standard back control"]],
  [/chevron\.right|arrow\.right/i, ["forward", "system-standard forward control"]],
  [/plus/i, ["create", "dimensional purple plus object"]],
];

const thirdPartyAssets = new Set([
  "PortalAmazon", "PortalApple", "PortalGoogle", "PortalReddit",
  "PortalWikipedia", "PortalX", "PortalYouTube",
]);

function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) return walk(absolute);
    return entry.name.endsWith(".swift") ? [absolute] : [];
  });
}

function semanticRecommendation(icon) {
  for (const [pattern, result] of roleRules) {
    if (pattern.test(icon)) return result;
  }
  return ["utility", "centralized SF Symbol fallback pending a dedicated physical asset"];
}

function escapeCell(value) {
  return String(value).replaceAll("|", "\\|").replaceAll("\n", " ");
}

const rows = [];
for (const file of walk(sourceRoot)) {
  const relative = path.relative(root, file);
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  lines.forEach((line, index) => {
    const patterns = [
      { source: "SF Symbol", regex: /Image\s*\(\s*systemName:\s*([^,)]+)/g },
      { source: "SF Symbol label", regex: /systemImage:\s*([^,)]+)/g },
      { source: "Asset catalog", regex: /Image\s*\(\s*"([^"]+)"\s*\)/g },
    ];
    for (const { source, regex } of patterns) {
      for (const match of line.matchAll(regex)) {
        const raw = match[1].trim();
        const icon = raw.replace(/^"|"$/g, "");
        const isLiteral = raw.startsWith("\"");
        const [role, recommendation] = semanticRecommendation(icon);
        const nearby = lines.slice(Math.max(0, index - 4), Math.min(lines.length, index + 5)).join(" ");
        const interactive = /Button|Menu|NavigationLink|onTapGesture/.test(nearby) || source.includes("label");
        const accessibility = /accessibilityLabel/.test(nearby)
          ? "Nearby explicit label"
          : interactive
            ? "Requires verification"
            : "Decorative or inherited from text";
        rows.push({
          icon: isLiteral ? icon : `dynamic: ${raw}`,
          source,
          location: `${relative}:${index + 1}`,
          purpose: role,
          interactive: interactive ? "Yes / likely" : "No / unclear",
          replacement: thirdPartyAssets.has(icon) ? "Preserve official third-party logo" : recommendation,
          states: interactive ? "default, pressed, disabled; selected where applicable" : "default; semantic status where applicable",
          accessibility,
        });
      }
    }
  });
}

const assetSets = fs.readdirSync(path.join(sourceRoot, "Assets.xcassets"), { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && entry.name.length > ".imageset".length && entry.name.endsWith(".imageset"))
  .map((entry) => entry.name.replace(/\.imageset$/, ""))
  .sort();

const report = [
  "# OneWay Icon Audit",
  "",
  `Generated before physical-item migration. Direct visible icon occurrences: **${rows.length}**.`,
  "",
  "## Scope and policy",
  "",
  "- SwiftUI `Image(systemName:)`, `systemImage:` labels/buttons, and direct asset-catalog images were inventoried.",
  "- Dynamic icon expressions are retained as dynamic audit entries and route through the centralized fallback mapping after migration.",
  "- Official third-party Quick Access logos remain unchanged.",
  "- System-standard directional and safety-critical controls may retain simplified centralized fallbacks where physical rendering would reduce clarity.",
  "- No assets are deleted by this audit.",
  "",
  "## Existing asset catalog entries",
  "",
  ...assetSets.map((name) => `- \`${name}\`${thirdPartyAssets.has(name) ? " — preserve official brand" : ""}`),
  "",
  "## Complete occurrence audit",
  "",
  "| Current icon | Current source | Screen/component | Purpose/role | Interactive | Recommended object | Required states | Accessibility |",
  "|---|---|---|---|---|---|---|---|",
  ...rows.map((row) => `| ${[
    row.icon, row.source, row.location, row.purpose, row.interactive,
    row.replacement, row.states, row.accessibility,
  ].map(escapeCell).join(" | ")} |`),
  "",
];

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, report.join("\n"));
console.log(`Wrote ${rows.length} icon occurrences to ${path.relative(root, outputPath)}`);
