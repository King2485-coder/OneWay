import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import test from "node:test";
import { siteEnquirySchema, encryptedSiteEnquiry, renderSiteEnquiryForm } from "../src/services/siteEnquiries";
import { decryptIfEncrypted, isEncryptedPayload } from "../src/services/privacy/EncryptionService";

const valid = { customerName: "Studio visitor", customerEmail: "visitor@example.com", message: "Please tell me more." };
test("website enquiry validates visitor fields, limits and honeypot", () => {
  assert.equal(siteEnquirySchema.safeParse(valid).success, true);
  for (const bad of [ { ...valid, customerName: " " }, { ...valid, customerEmail: "bad" }, { ...valid, message: "x".repeat(4001) }, { ...valid, website: "spam.example" } ]) {
    assert.equal(siteEnquirySchema.safeParse(bad).success, false);
  }
  const parsed = siteEnquirySchema.parse({ ...valid, userId: "attacker", status: "paid" });
  assert.equal("userId" in parsed, false);
  assert.equal("status" in parsed, false);
});
test("website enquiry uses the existing encrypted inbox field contexts", () => {
  process.env.FIELD_ENCRYPTION_ENABLED = "true";
  process.env.FIELD_ENCRYPTION_KEY_ID = "site-enquiry-test";
  process.env.FIELD_ENCRYPTION_KEYS_JSON = JSON.stringify({ "site-enquiry-test": randomBytes(32).toString("base64") });
  const saved = encryptedSiteEnquiry("studio.oneway.app", siteEnquirySchema.parse(valid));
  assert.equal(isEncryptedPayload(saved.message), true);
  assert.equal(decryptIfEncrypted(saved.message, "store:studio.oneway.app:inquiry:message"), valid.message);
  assert.equal(decryptIfEncrypted(saved.customerEmail, "store:studio.oneway.app:inquiry:customerEmail"), valid.customerEmail);
  assert.throws(() => decryptIfEncrypted(saved.message, "store:other.oneway.app:inquiry:message"));
  assert.equal(saved.status, "new");
});
test("published form posts to the website endpoint and escapes its action", () => {
  const html = renderSiteEnquiryForm("studio.oneway.app", "https://api.oneway.is/");
  assert.match(html, /method="post"/);
  assert.match(html, /\/api\/sites\/studio.oneway.app\/inquiries/);
  assert.match(html, /name="customerEmail" type="email"/);
  assert.match(html, /maxlength="4000"/);
  assert.match(html, /website’s owner/);
  assert.doesNotMatch(html, /userId|token|Authorization|javascript:/);
  assert.doesNotMatch(renderSiteEnquiryForm("studio.oneway.app", 'https://api.example/\" onmouseover=\"bad'), /action="[^\"]*" onmouseover=/);
});
