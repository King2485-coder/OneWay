import { StubPSTNProvider } from "./StubPSTNProvider";
import { TwilioPSTNProvider } from "./TwilioPSTNProvider";
import { TelnyxPSTNProvider } from "./TelnyxPSTNProvider";
import { SinchPSTNProvider } from "./SinchPSTNProvider";
import type { PSTNProvider, PSTNProviderName } from "./PSTNProvider";

const SUPPORTED = new Set<PSTNProviderName>(["stub", "twilio", "telnyx", "sinch"]);

function normalizeProvider(value: string | undefined): PSTNProviderName {
  const normalized = (value ?? "stub").trim().toLowerCase() as PSTNProviderName;
  return SUPPORTED.has(normalized) ? normalized : "stub";
}

export function createPSTNProvider(): PSTNProvider {
  const selected = normalizeProvider(process.env.PSTN_PROVIDER);

  switch (selected) {
    case "twilio":
      return new TwilioPSTNProvider();
    case "telnyx":
      return new TelnyxPSTNProvider();
    case "sinch":
      return new SinchPSTNProvider();
    case "stub":
    default:
      return new StubPSTNProvider();
  }
}

export const pstnProvider = createPSTNProvider();
