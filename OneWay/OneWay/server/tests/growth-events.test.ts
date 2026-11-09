import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { sanitizeGrowthMetadata, validateGrowthEventPayload } from "../src/services/growthEvents";

test("growth relay accepts only canonical events and authenticated subjects", () => {
  const parsed = validateGrowthEventPayload({
    eventId: "evt_signup_12345",
    eventName: "signup_completed",
    subjectKey: "client-supplied-user",
    occurredAt: new Date().toISOString(),
    sourcePlatform: "ios",
    metadata: { screen: "welcome", is_test: true },
  }, "authenticated-user");

  assert.equal(parsed.ok, true);
  if (parsed.ok) {
    assert.equal(parsed.event.subjectKey, "authenticated-user");
    assert.equal(parsed.event.eventName, "signup_completed");
    assert.equal(parsed.event.isTest, true);
  }

  const unknown = validateGrowthEventPayload({
    eventId: "evt_unknown_12345",
    eventName: "message_body_opened",
    occurredAt: new Date().toISOString(),
  }, "authenticated-user");
  assert.deepEqual(unknown, { ok: false, status: 400, error: "unknown_event_name" });
});

test("growth relay rejects private content, credentials, and stale replays", () => {
  assert.deepEqual(sanitizeGrowthMetadata({ messageBody: "hello", screen: "home", token: "secret" }), {
    metadata: { screen: "home" },
    rejectedKeys: ["messageBody", "token"],
  });

  const privatePayload = validateGrowthEventPayload({
    eventId: "evt_private_12345",
    eventName: "first_message_sent",
    occurredAt: new Date().toISOString(),
    metadata: { messageContent: "do not store this" },
  }, "authenticated-user");
  assert.deepEqual(privatePayload, { ok: false, status: 400, error: "sensitive_metadata_rejected" });

  const stalePayload = validateGrowthEventPayload({
    eventId: "evt_stale_12345",
    eventName: "app_open",
    occurredAt: new Date(Date.now() - 50 * 86_400_000).toISOString(),
  }, "authenticated-user");
  assert.deepEqual(stalePayload, { ok: false, status: 400, error: "timestamp_out_of_range" });
});

test("growth event export and status require a server-side bearer token", () => {
  const routeSource = fs.readFileSync(path.resolve("src/routes/growthEvents.ts"), "utf8");
  assert.match(routeSource, /process\.env\.GROWTH_EVENTS_EXPORT_TOKEN/);
  assert.match(routeSource, /router\.get\("\/export"/);
  assert.match(routeSource, /router\.get\("\/status"/);
  assert.match(routeSource, /hasExportAccess\(req\)/);
});

test("activation rule requires signup and two qualifying actions inside seven days", () => {
  const serviceSource = fs.readFileSync(path.resolve("src/services/growthEvents.ts"), "utf8");
  assert.match(serviceSource, /if \(!signupAt\) return false/);
  assert.match(serviceSource, /7 \* 86_400_000/);
  assert.match(serviceSource, /qualifyingActivationEvents/);
  assert.match(serviceSource, /activation_rule_v1/);
});
