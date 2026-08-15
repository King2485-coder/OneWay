import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import { isSMSOptedOut } from "./SMSOptOutStore";
import type { SMSOutboundMessageInput, SMSOutboundMessageResult, SMSProvider } from "./SMSProvider";

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return "Unknown provider error";
}

function normalizeStatus(raw: unknown): SMSOutboundMessageResult["status"] {
  const status = typeof raw === "string" ? raw.toLowerCase() : "";
  if (status === "sent") return "sent";
  if (status === "delivered") return "delivered";
  if (status === "sending" || status === "accepted") return "sending";
  if (status === "failed") return "failed";
  if (status === "undelivered") return "undelivered";
  return "queued";
}

const REGISTRATION_REQUIRED_MESSAGE = "Your Twilio number is SMS-capable, but US carriers require A2P 10DLC approval before app-sent texts can deliver from a +1 long-code number. Complete Twilio A2P registration, attach this number to the approved Messaging Service, then set TWILIO_MESSAGING_SERVICE_SID=MG..., or use a verified toll-free/short-code sender.";

function isRawUSLongCode(value: string): boolean {
  return /^\+1\d{10}$/.test(value.trim());
}

function allowUnregisteredLongCode(): boolean {
  const value = process.env.SMS_ALLOW_UNREGISTERED_LONG_CODE?.trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes";
}

export class TwilioSMSProvider implements SMSProvider {
  name = "twilio" as const;

  private readonly accountSid = process.env.TWILIO_ACCOUNT_SID?.trim() ?? "";
  private readonly authToken = process.env.TWILIO_AUTH_TOKEN?.trim() ?? "";
  private readonly messagingServiceSid = process.env.TWILIO_MESSAGING_SERVICE_SID?.trim() ?? "";
  private readonly fromNumber = process.env.SMS_FROM_NUMBER?.trim()
    || process.env.TWILIO_FROM_NUMBER?.trim()
    || process.env.PSTN_FROM_NUMBER?.trim()
    || "";
  private readonly webhookBaseUrl = (process.env.SMS_WEBHOOK_BASE_URL?.trim()
    || process.env.PSTN_WEBHOOK_BASE_URL?.trim()
    || "")
    ? trimTrailingSlash(process.env.SMS_WEBHOOK_BASE_URL?.trim() || process.env.PSTN_WEBHOOK_BASE_URL!.trim())
    : "";
  private readonly webhookSecret = process.env.SMS_WEBHOOK_SECRET?.trim() ?? "";
  private readonly statusCallbackUrl = process.env.TWILIO_STATUS_CALLBACK_URL?.trim() ?? "";

  async sendOutboundMessage(input: SMSOutboundMessageInput): Promise<SMSOutboundMessageResult> {
    if (!this.accountSid || !this.authToken) {
      return this.failed("Missing TWILIO_ACCOUNT_SID or TWILIO_AUTH_TOKEN.");
    }
    if (!this.messagingServiceSid && !this.fromNumber) {
      return this.failed("Missing TWILIO_MESSAGING_SERVICE_SID, SMS_FROM_NUMBER, TWILIO_FROM_NUMBER, or PSTN_FROM_NUMBER.");
    }
    if (!this.messagingServiceSid && isRawUSLongCode(this.fromNumber) && !allowUnregisteredLongCode()) {
      return this.failed(REGISTRATION_REQUIRED_MESSAGE);
    }
    if (await isSMSOptedOut(input.toPhoneNumber)) {
      return this.failed("Recipient has opted out of OneWay SMS messages.");
    }

    const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(this.accountSid)}/Messages.json`;
    const params = new URLSearchParams();
    params.set("To", input.toPhoneNumber);
    params.set("Body", input.body);
    if (this.messagingServiceSid) {
      params.set("MessagingServiceSid", this.messagingServiceSid);
    } else {
      params.set("From", this.fromNumber);
    }
    for (const mediaUrl of input.mediaUrls ?? []) {
      params.append("MediaUrl", mediaUrl);
    }
    if (this.statusCallbackUrl) {
      params.set("StatusCallback", this.statusCallbackUrl);
    } else if (this.webhookBaseUrl) {
      const secret = this.webhookSecret ? `?secret=${encodeURIComponent(this.webhookSecret)}` : "";
      params.set("StatusCallback", `${this.webhookBaseUrl}/api/messages/external/twilio/status${secret}`);
    }

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Basic ${Buffer.from(`${this.accountSid}:${this.authToken}`).toString("base64")}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: params.toString(),
      });

      const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
      if (!response.ok) {
        const detail = typeof body.message === "string" ? body.message : `HTTP ${response.status}`;
        const code = typeof body.code === "number" || typeof body.code === "string" ? ` code=${String(body.code)}` : "";
        const moreInfo = typeof body.more_info === "string" ? ` more_info=${body.more_info}` : "";
        return this.failed(`Twilio SMS send failed:${code} ${detail}${moreInfo}`);
      }

      return {
        providerMessageId: typeof body.sid === "string" ? body.sid : `twilio_sms_${randomUUID()}`,
        provider: this.name,
        status: normalizeStatus(body.status),
        message: typeof body.error_message === "string" ? body.error_message : undefined,
      };
    } catch (err) {
      return this.failed(`Twilio SMS send failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string, providerMessageId?: string): SMSOutboundMessageResult {
    logger.warn({ message, providerMessageId }, "[sms:twilio] outbound message failed");
    return {
      providerMessageId: providerMessageId ?? `twilio_sms_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      message,
    };
  }

}
