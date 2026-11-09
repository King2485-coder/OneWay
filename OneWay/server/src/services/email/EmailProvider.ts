export type EmailProviderName = "stub" | "sendgrid" | "mailgun";

export type EmailOutboundMessageStatus = "queued" | "sent" | "failed" | "stubbed";

export interface EmailOutboundMessageInput {
  fromUserId: string;
  fromEmail?: string;
  toEmail: string;
  toEmails?: string[];
  ccEmails?: string[];
  bccEmails?: string[];
  replyTo?: string;
  subject?: string;
  body: string;
  htmlBody?: string;
  messageSessionId?: string;
  inReplyTo?: string;
  references?: string[];
  attachments?: Array<{
    filename: string;
    contentType: string;
    data: Buffer;
  }>;
}

export interface EmailOutboundMessageResult {
  providerMessageId: string;
  provider: EmailProviderName;
  status: EmailOutboundMessageStatus;
  message?: string;
}

export interface EmailProvider {
  name: EmailProviderName;
  sendOutboundMessage(input: EmailOutboundMessageInput): Promise<EmailOutboundMessageResult>;
}
