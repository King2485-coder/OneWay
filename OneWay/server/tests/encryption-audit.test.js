"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { lineFor, runStaticAudit } = require("../scripts/encryption-audit");
const { scanForSentinel } = require("../scripts/plaintext-sentinel");

test("audit reports source locations without printing secret or message values", () => {
  const findings = runStaticAudit();
  for (const finding of findings) {
    assert.equal("pattern" in finding, false);
    assert.equal("value" in finding, false);
    assert.match(finding.id, /^[A-Z0-9-]+$/);
  }
});

test("current remediation satisfies every static encryption boundary", () => {
  assert.deepEqual(runStaticAudit(), []);
});

test("line numbers are deterministic", () => {
  assert.equal(lineFor("one\ntwo\nthree", 4), 2);
});

test("plaintext sentinel detects persistence without exposing the sentinel", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "oneway-plaintext-sentinel-"));
  const sentinel = "ONEWAY-PLAINTEXT-TEST-8f31d9d4";
  try {
    fs.writeFileSync(path.join(root, "message.sqlite"), `opaque:${sentinel}`, "utf8");
    const findings = scanForSentinel(root, sentinel);
    assert.deepEqual(findings, [{ file: "message.sqlite", offset: 7, category: "database" }]);
    assert.equal(JSON.stringify(findings).includes(sentinel), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test.todo("authenticated encryption rejects modified ciphertext");
test.todo("decryption with the wrong device key fails closed");
test.todo("replay protection rejects a previously accepted message envelope");
test.todo("device revocation prevents new session establishment");
test.todo("group membership change rotates the group epoch or sender key");
test.todo("encrypted attachment upload and download never persist plaintext");
test.todo("encrypted backup restore works without server-held recovery keys");
