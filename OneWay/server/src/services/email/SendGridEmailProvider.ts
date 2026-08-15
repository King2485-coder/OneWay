import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { EmailOutboundMessageInput, EmailOutboundMessageResult, EmailProvider } from "./EmailProvider";

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return "Unknown provider error";
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function plainTextToHtml(value: string): string {
  return escapeHtml(value).replace(/\r?\n/g, "<br>");
}

export class SendGridEmailProvider implements EmailProvider {
  name = "sendgrid" as const;

  private readonly apiKey = process.env.SENDGRID_API_KEY?.trim() ?? "";
  private readonly fromEmail = process.env.EMAIL_FROM_ADDRESS?.trim()
    || process.env.EMAIL_FROM?.trim()
    || process.env.SENDGRID_FROM_EMAIL?.trim()
    || "";
  private readonly fromName = process.env.EMAIL_FROM_NAME?.trim() || "OneWay";
  private readonly defaultReplyTo = process.env.EMAIL_REPLY_TO?.trim()
    || process.env.SENDGRID_REPLY_TO_EMAIL?.trim()
    || "";

  async sendOutboundMessage(input: EmailOutboundMessageInput): Promise<EmailOutboundMessageResult> {
    if (!this.apiKey) {
      return this.failed("Missing SENDGRID_API_KEY.");
    }
    if (!this.fromEmail) {
      return this.failed("Missing EMAIL_FROM_ADDRESS, EMAIL_FROM, or SENDGRID_FROM_EMAIL.");
    }

    try {
      const htmlBody = input.htmlBody?.trim() || plainTextToHtml(input.body);
      const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          personalizations: [
            {
              to: (input.toEmails?.length ? input.toEmails : [input.toEmail]).map((email) => ({ email })),
              subject: input.subject || "OneWay message",
            },
          ],
          from: {
            email: this.fromEmail,
            name: this.fromName,
          },
          reply_to: {
            email: input.replyTo?.trim() || this.defaultReplyTo || this.fromEmail,
            name: this.fromName,
          },
          content: [
            {
              type: "text/plain",
              value: input.body,
            },
            {
              type: "text/html",
              value: htmlBody,
            },
          ],
          custom_args: {
            messageSessionId: input.messageSessionId ?? "",
            fromUserId: input.fromUserId,
          },
        }),
      });

      if (!response.ok) {
        const body = (await response.json().catch(() => ({}))) as Record<string, any>;
        const detail = typeof body?.errors?.[0]?.message === "string"
          ? body.errors[0].message
          : `HTTP ${response.status}`;
        return this.failed(`SendGrid email send failed: ${detail}`);
      }

      return {
        providerMessageId: response.headers.get("x-message-id") ?? `sendgrid_email_${randomUUID()}`,
        provider: this.name,
        status: "queued",
      };
    } catch (err) {
      return this.failed(`SendGrid email send failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string): EmailOutboundMessageResult {
    logger.warn({ message }, "[email:sendgrid] outbound message failed");
    return {
      providerMessageId: `sendgrid_email_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      message,
    };
  }
}
