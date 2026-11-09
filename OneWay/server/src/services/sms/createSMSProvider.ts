import { StubSMSProvider } from "./StubSMSProvider";
import { TwilioSMSProvider } from "./TwilioSMSProvider";
import { TelnyxSMSProvider } from "./TelnyxSMSProvider";
import { SinchSMSProvider } from "./SinchSMSProvider";
import type { SMSProvider, SMSProviderName } from "./SMSProvider";

const SUPPORTED = new Set<SMSProviderName>(["stub", "twilio", "telnyx", "sinch"]);

function normalizeProvider(value: string | undefined): SMSProviderName {
  const normalized = (value ?? "stub").trim().toLowerCase() as SMSProviderName;
  return SUPPORTED.has(normalized) ? normalized : "stub";
}

export function createSMSProvider(): SMSProvider {
  const selected = normalizeProvider(process.env.SMS_PROVIDER || process.env.PSTN_PROVIDER);

  switch (selected) {
    case "twilio":
      return new TwilioSMSProvider();
    case "telnyx":
      return new TelnyxSMSProvider();
    case "sinch":
      return new SinchSMSProvider();
    case "stub":
    default:
      return new StubSMSProvider();
  }
}

export const smsProvider = createSMSProvider();
