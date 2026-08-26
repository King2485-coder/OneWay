import assert from "node:assert/strict";
import test from "node:test";
import twilio from "twilio";

import { normalizeSMSDeliveryStatus } from "../src/services/sms/MessageDeliveryService";
import { normalizeSMSPhoneNumber } from "../src/services/sms/SMSOptOutStore";
import { twilioSignedCallbackUrl, twilioWebhookBaseUrl, validateTwilioProductionEnvironment, validateTwilioRequest } from "../src/services/twilio/TwilioSecurity";

test("validates authentic Twilio webhook signatures and rejects tampering", () => {
  const authToken = "unit-test-auth-token";
  const url = "https://api.oneway.is/api/twilio/inbound-sms";
  const params = { From: "+16025550101", To: "+16025550102", Body: "HELP" };
  const signature = twilio.getExpectedTwilioSignature(authToken, url, params);

  assert.equal(validateTwilioRequest({ authToken, signature, url, params }), true);
  assert.equal(validateTwilioRequest({ authToken, signature, url, params: { ...params, Body: "STOP" } }), false);
});

test("uses one canonical Twilio webhook base URL for signing and callback generation", () => {
  const names = ["TWILIO_WEBHOOK_BASE_URL", "PUBLIC_WEBHOOK_BASE_URL", "PSTN_WEBHOOK_BASE_URL"];
  const previous = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  try {
    process.env.TWILIO_WEBHOOK_BASE_URL = "https://api.oneway.is";
    process.env.PUBLIC_WEBHOOK_BASE_URL = "https://different.example.com";
    process.env.PSTN_WEBHOOK_BASE_URL = "https://another.example.com";
    assert.equal(twilioWebhookBaseUrl(), "https://api.oneway.is");
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});

test("adds a server-authenticated signature to outbound Twilio callback URLs", () => {
  const previous = process.env.TWILIO_AUTH_TOKEN;
  process.env.TWILIO_AUTH_TOKEN = "unit-test-auth-token";
  try {
    const callback = new URL(twilioSignedCallbackUrl(
      "/api/pstn/twilio/voice",
      { callSessionId: "session-123", stage: "disclosure" },
      "https://api.oneway.is",
    ));
    assert.equal(callback.searchParams.get("callSessionId"), "session-123");
    assert.equal(callback.searchParams.get("stage"), "disclosure");
    assert.ok((callback.searchParams.get("owSig") ?? "").length >= 40);
  } finally {
    if (previous === undefined) delete process.env.TWILIO_AUTH_TOKEN;
    else process.env.TWILIO_AUTH_TOKEN = previous;
  }
});

test("normalizes Twilio delivery states", () => {
  assert.equal(normalizeSMSDeliveryStatus("accepted"), "queued");
  assert.equal(normalizeSMSDeliveryStatus("delivered"), "delivered");
  assert.equal(normalizeSMSDeliveryStatus("undelivered"), "undelivered");
});

test("normalizes recipient phone numbers for consent and opt-out enforcement", () => {
  assert.equal(normalizeSMSPhoneNumber("+1 (602) 555-0101"), "+16025550101");
  assert.equal(normalizeSMSPhoneNumber(""), "");
});

test("production validation reports missing configuration without revealing values", () => {
  const names = [
    "TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_API_KEY_SID",
    "TWILIO_API_KEY_SECRET", "TWILIO_TWIML_APP_SID", "TWILIO_MESSAGING_SERVICE_SID",
    "TWILIO_WEBHOOK_BASE_URL", "PUBLIC_WEBHOOK_BASE_URL",
  ];
  const previous = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  for (const name of names) delete process.env[name];
  try {
    const result = validateTwilioProductionEnvironment();
    assert.equal(result.ok, false);
    assert.ok(result.missing.includes("TWILIO_AUTH_TOKEN"));
    assert.ok(result.missing.includes("TWILIO_MESSAGING_SERVICE_SID"));
    assert.equal(JSON.stringify(result).includes("unit-test-auth-token"), false);
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});
