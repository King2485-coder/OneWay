import assert from "node:assert/strict";
import test from "node:test";
import { normalizeDirectoryText, normalizeFullPhoneCandidates } from "../src/routes/users";

test("OneWay identifiers normalize consistently", () => {
  assert.equal(normalizeDirectoryText("  @OW-397704  "), "@ow-397704");
  assert.equal(normalizeDirectoryText("  Marcus   Reed "), "marcus reed");
});

test("only complete phone numbers become directory phone candidates", () => {
  assert.deepEqual(normalizeFullPhoneCandidates("520-492"), []);
  assert.deepEqual(normalizeFullPhoneCandidates("hello 5204926656"), []);
  assert.deepEqual(
    normalizeFullPhoneCandidates("(520) 492-6656"),
    ["+15204926656", "5204926656", "+5204926656"]
  );
});
