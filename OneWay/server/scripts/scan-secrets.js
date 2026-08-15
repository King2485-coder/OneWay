#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = process.env.SECRET_SCAN_ROOT
  ? path.resolve(process.env.SECRET_SCAN_ROOT)
  : defaultScanRoot();
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const ignoredDirs = new Set([
  ".git",
  ".expo",
  ".next",
  ".turbo",
  ".build",
  ".swiftpm",
  "DerivedData",
  "build",
  "dist",
  "node_modules",
  "web-build",
  "xcuserdata",
]);
// Local certificate material is intentionally stored outside version control.
// The scanner verifies source files, while .gitignore prevents this vault from
// ever becoming part of a commit.
const ignoredRelativeDirs = new Set([path.join("server", "secrets")]);
const ignoredFiles = new Set([
  "package-lock.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "Package.resolved",
]);
const ignoredExtensions = new Set([
  ".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico", ".pdf", ".zip", ".gz", ".tgz", ".dylib", ".so", ".a", ".framework", ".xcframework",
]);

const detectors = [
  { name: "private_key", regex: /-----BEGIN (?:RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----/g },
  { name: "jwt", regex: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g },
  { name: "stripe_secret", regex: /\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b/g },
  { name: "sendgrid_key", regex: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g },
  { name: "openai_key", regex: /\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b/g },
  { name: "twilio_sid", regex: /\b(?:AC|SK)[a-fA-F0-9]{32}\b/g },
  { name: "livekit_api_secret_assignment", regex: /\bLIVEKIT_(?:API_)?SECRET\s*[:=]\s*["']?([^\s"',;#]{16,})/g, group: 1 },
  { name: "twilio_auth_token_assignment", regex: /\bTWILIO_AUTH_TOKEN\s*[:=]\s*["']?([a-fA-F0-9]{32})/g, group: 1 },
  { name: "encryption_key_assignment", regex: /\b(?:FIELD_ENCRYPTION_MASTER_KEY_BASE64|FIELD_HASH_KEY_BASE64)\s*[:=]\s*["']?([A-Za-z0-9+/]{43}=)/g, group: 1 },
  { name: "generic_secret_assignment", regex: /\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API_KEY|AUTH_KEY|PRIVATE_KEY)[A-Z0-9_]*)\s*[:=]\s*["']?([^\s"',;#]{20,})/g, group: 2 },
];

const findings = [];
for (const file of walk(repoRoot)) {
  const relative = path.relative(repoRoot, file);
  if (shouldIgnoreFile(relative, file)) continue;
  const stat = fs.statSync(file);
  if (stat.size > MAX_FILE_BYTES) continue;
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    continue;
  }
  scanText(relative, text);
}

if (findings.length > 0) {
  console.error(JSON.stringify({ ok: false, findings }, null, 2));
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({ ok: true, scannedRoot: repoRoot, findings: 0 }));
}

function scanText(relative, text) {
  const lines = text.split(/\r?\n/);
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (isAllowedExample(relative, line)) continue;
    for (const detector of detectors) {
      detector.regex.lastIndex = 0;
      let match;
      while ((match = detector.regex.exec(line)) !== null) {
        const value = detector.group ? match[detector.group] : match[0];
        if (isAllowedValue(relative, line, value)) continue;
        findings.push({
          file: relative,
          line: lineIndex + 1,
          type: detector.name,
          preview: redactPreview(value),
        });
      }
    }
  }
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const relative = path.relative(repoRoot, full);
    if (entry.isDirectory()) {
      if (
        ignoredDirs.has(entry.name)
        || ignoredRelativeDirs.has(relative)
        || relative.includes(`${path.sep}DerivedData${path.sep}`)
      ) continue;
      yield* walk(full);
    } else if (entry.isFile()) {
      yield full;
    }
  }
}

function shouldIgnoreFile(relative, fullPath) {
  const basename = path.basename(relative);
  if (ignoredFiles.has(basename)) return true;
  if (basename === ".env" || basename.endsWith(".env") || basename.includes(".env.")) return true;
  if (basename === ".ev" || basename === ",env") return true;
  if (relative.endsWith(".env.example") || relative.endsWith(".example")) return true;
  if (ignoredExtensions.has(path.extname(fullPath).toLowerCase())) return true;
  return false;
}

function isAllowedExample(relative, line) {
  const lower = line.toLowerCase();
  return relative.toLowerCase().includes("docs/")
    || lower.includes("change_me")
    || lower.includes("placeholder")
    || lower.includes("example")
    || lower.includes("fake")
    || lower.includes("redacted")
    || lower.includes("local-dev")
    || lower.includes("base64-32-byte-key")
    || lower.includes("your_")
    || lower.includes("<") && lower.includes(">");
}

function isAllowedValue(relative, line, value) {
  const lower = line.toLowerCase();
  if (isAllowedExample(relative, line)) return true;
  if (lower.includes("process.env") || lower.includes("environment.getenvironmentvariable")) return true;
  if (lower.includes("randombytes") || lower.includes("random_uuid") || lower.includes("uuid")) return true;
  if (lower.includes("pattern = /") || lower.includes("regex: /")) return true;
  if (value.includes("${")) return true;
  if (value.startsWith("/")) return true;
  if (/^[xX]+$/.test(value)) return true;
  if (/^0+$/.test(value)) return true;
  if (value.includes("...")) return true;
  return false;
}

function redactPreview(value) {
  const clean = String(value);
  if (clean.length <= 10) return "[REDACTED]";
  return `${clean.slice(0, 4)}…${clean.slice(-4)}`;
}

function defaultScanRoot() {
  const cwd = process.cwd();
  if (fs.existsSync(path.join(cwd, "package.json")) && path.basename(cwd) !== "server") {
    return cwd;
  }
  return path.resolve(__dirname, "..", "..");
}
