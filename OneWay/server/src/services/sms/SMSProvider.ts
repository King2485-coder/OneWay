export type SMSProviderName = "stub" | "twilio" | "telnyx" | "sinch";

export type SMSOutboundMessageStatus = "queued" | "sending" | "sent" | "delivered" | "failed" | "undelivered";

export interface SMSOutboundMessageInput {
  fromUserId: string;
  fromOneWayNumber?: string;
  toPhoneNumber: string;
  body: string;
  mediaUrls?: string[];
  messageSessionId?: string;
}

export interface SMSOutboundMessageResult {
  providerMessageId: string;
  provider: SMSProviderName;
  status: SMSOutboundMessageStatus;
  message?: string;
}

export interface SMSProvider {
  name: SMSProviderName;
  sendOutboundMessage(input: SMSOutboundMessageInput): Promise<SMSOutboundMessageResult>;
}
