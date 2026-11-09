import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import path from "node:path";

const accountRoute = fs.readFileSync(path.resolve("src/routes/account.ts"), "utf8");
const authMiddleware = fs.readFileSync(path.resolve("src/middleware/auth.ts"), "utf8");

test("permanent deletion uses only the authenticated subject", () => {
  const deleteRoute = accountRoute.slice(accountRoute.indexOf('router.delete("/"'));
  assert.match(deleteRoute, /AuthenticatedRequest\)\.userId/);
  assert.doesNotMatch(deleteRoute, /req\.(body|params|query).*userId/);
  assert.match(authMiddleware, /account_not_active/);
});

test("one-tap endpoint is active, transactional, and removes credentials last", () => {
  const deleteRoute = accountRoute.slice(accountRoute.indexOf('router.delete("/"'));
  assert.doesNotMatch(deleteRoute, /burn_flow_required/);
  assert.match(deleteRoute, /prisma\.\$transaction/);
  assert.match(deleteRoute, /await tx\.user\.delete/);
  assert.ok(
    deleteRoute.indexOf("await tx.user.delete") > deleteRoute.indexOf("await tx.community.deleteMany"),
    "authentication account must be removed after dependent records"
  );
});

test("legally retained commerce records are de-identified", () => {
  const deleteRoute = accountRoute.slice(accountRoute.indexOf('router.delete("/"'));
  assert.match(deleteRoute, /oneway-retained-financial-records/);
  assert.match(deleteRoute, /customerName:\s*""/);
  assert.match(deleteRoute, /customerEmail:\s*""/);
  assert.match(deleteRoute, /customerPhone:\s*""/);
  assert.match(deleteRoute, /actorId:\s*null/);
});

test("deletion revokes tokens and removes searchable identity by deleting User", () => {
  assert.match(authMiddleware, /deleted_or_missing_account/);
  assert.match(accountRoute, /await tx\.user\.delete/);
  assert.match(accountRoute, /await tx\.community\.deleteMany/);
  assert.match(accountRoute, /await tx\.shopConversation\.deleteMany/);
});
