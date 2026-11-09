import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { SMSOutboundMessageInput, SMSOutboundMessageResult, SMSProvider } from "./SMSProvider";

export class StubSMSProvider implements SMSProvider {
  name = "stub" as const;

  async sendOutboundMessage(input: SMSOutboundMessageInput): Promise<SMSOutboundMessageResult> {
    logger.info({
      fromUserId: input.fromUserId,
      fromOneWayNumber: input.fromOneWayNumber,
      toPhoneNumber: input.toPhoneNumber,
      messageSessionId: input.messageSessionId,
      hasMedia: Boolean(input.mediaUrls?.length),
    }, "[sms:stub] outbound message requested");

    return {
      providerMessageId: `stub_sms_${randomUUID()}`,
      provider: this.name,
      status: "queued",
      message: "SMS bridge is running in stub mode. Configure Twilio, Telnyx, or Sinch to send real outside-line messages.",
    };
  }
}
