import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { EmailOutboundMessageInput, EmailOutboundMessageResult, EmailProvider } from "./EmailProvider";

export class StubEmailProvider implements EmailProvider {
  name = "stub" as const;

  async sendOutboundMessage(input: EmailOutboundMessageInput): Promise<EmailOutboundMessageResult> {
    logger.info({
      fromUserId: input.fromUserId,
      toEmail: input.toEmail,
      replyTo: input.replyTo,
      messageSessionId: input.messageSessionId,
    }, "[email:stub] outbound message requested");

    return {
      providerMessageId: `stub_email_${randomUUID()}`,
      provider: this.name,
      status: "stubbed",
      message: "Email bridge is running in stub mode. Configure SendGrid to send real external email messages.",
    };
  }
}
