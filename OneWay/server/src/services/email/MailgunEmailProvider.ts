import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { EmailOutboundMessageInput, EmailOutboundMessageResult, EmailProvider } from "./EmailProvider";

export class MailgunEmailProvider implements EmailProvider {
  name = "mailgun" as const;

  private readonly apiKey = process.env.MAILGUN_API_KEY?.trim() ?? "";
  private readonly domain = process.env.ONEWAY_EMAIL_DOMAIN?.trim()
    || process.env.MAILGUN_DOMAIN?.trim()
    || "";
  private readonly apiBase = (process.env.MAILGUN_API_BASE_URL?.trim() || "https://api.mailgun.net").replace(/\/$/, "");

  async sendOutboundMessage(input: EmailOutboundMessageInput): Promise<EmailOutboundMessageResult> {
    if (!this.apiKey || !this.domain) {
      return this.failed("Mailgun credentials or sending domain are not configured.");
    }

    const form = new FormData();
    form.append("from", input.fromEmail?.trim() || process.env.EMAIL_FROM_ADDRESS?.trim() || `OneWay <postmaster@${this.domain}>`);
    for (const email of input.toEmails?.length ? input.toEmails : [input.toEmail]) form.append("to", email);
    for (const email of input.ccEmails ?? []) form.append("cc", email);
    for (const email of input.bccEmails ?? []) form.append("bcc", email);
    form.append("subject", input.subject?.trim() || "OneWay message");
    form.append("text", input.body);
    if (input.htmlBody?.trim()) form.append("html", input.htmlBody);
    if (input.replyTo?.trim()) form.append("h:Reply-To", input.replyTo.trim());
    if (input.inReplyTo?.trim()) form.append("h:In-Reply-To", input.inReplyTo.trim());
    if (input.references?.length) form.append("h:References", input.references.join(" "));
    if (input.messageSessionId) form.append("v:oneway-message-id", input.messageSessionId);
    form.append("v:oneway-user-id", input.fromUserId);
    form.append("o:tracking", "no");
    for (const attachment of input.attachments ?? []) {
      form.append("attachment", new Blob([Uint8Array.from(attachment.data)], { type: attachment.contentType }), attachment.filename);
    }

    try {
      const response = await fetch(`${this.apiBase}/v3/${encodeURIComponent(this.domain)}/messages`, {
        method: "POST",
        headers: { Authorization: `Basic ${Buffer.from(`api:${this.apiKey}`).toString("base64")}` },
        body: form,
      });
      const payload = await response.json().catch(() => ({})) as { id?: string; message?: string };
      if (!response.ok || !payload.id) {
        return this.failed(`Mailgun send failed: ${payload.message || `HTTP ${response.status}`}`);
      }
      return { providerMessageId: payload.id, provider: this.name, status: "queued" };
    } catch (error) {
      return this.failed(`Mailgun send failed: ${error instanceof Error ? error.message : "unknown error"}`);
    }
  }

  private failed(message: string): EmailOutboundMessageResult {
    logger.warn({ message }, "[email:mailgun] outbound message failed");
    return {
      providerMessageId: `mailgun_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      message,
    };
  }
}
