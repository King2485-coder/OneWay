import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { PSTNOutboundCallInput, PSTNOutboundCallResult, PSTNProvider } from "./PSTNProvider";

export class StubPSTNProvider implements PSTNProvider {
  name = "stub" as const;

  async startOutboundCall(input: PSTNOutboundCallInput): Promise<PSTNOutboundCallResult> {
    const providerCallId = `stub_${randomUUID()}`;
    logger.info({
      callSessionId: input.callSessionId.slice(0, 8),
      providerCallId: providerCallId.slice(0, 13),
      disclosureEnabled: input.calleeDisclosure?.enabled === true,
      requireAccept: input.calleeDisclosure?.requireAccept === true,
      disclosureStatus: input.calleeDisclosure?.requireAccept ? "waiting_for_callee_acceptance" : "disabled",
    }, "[pstn:stub] outbound call requested");

    const disclosureEnabled = input.calleeDisclosure?.enabled === true;
    const requireAccept = input.calleeDisclosure?.requireAccept === true;

    return {
      providerCallId,
      provider: this.name,
      status: disclosureEnabled && requireAccept ? "waiting_for_callee_acceptance" : "initiated",
      mediaBridgeReady: false,
      message: disclosureEnabled && requireAccept
        ? "Stub provider simulated disclosure prompt. Waiting for simulated recipient acceptance."
        : "Stub provider in use. Configure Twilio, Telnyx, or Sinch for real PSTN calls.",
      calleeDisclosure: {
        enabled: disclosureEnabled,
        requireAccept,
        accepted: disclosureEnabled && !requireAccept,
        status: disclosureEnabled && requireAccept
          ? "waiting_for_callee_acceptance"
          : disclosureEnabled
            ? "accepted"
            : "disabled",
      },
    };
  }
}
