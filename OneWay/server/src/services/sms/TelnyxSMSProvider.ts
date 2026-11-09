import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
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
  if (status === "sent" || status === "delivered") return "sent";
  if (status === "failed" || status === "delivery_failed") return "failed";
  return "queued";
}

export class TelnyxSMSProvider implements SMSProvider {
  name = "telnyx" as const;

  private readonly apiKey = process.env.TELNYX_API_KEY?.trim() ?? "";
  private readonly messagingProfileId = process.env.TELNYX_MESSAGING_PROFILE_ID?.trim() ?? "";
  private readonly fromNumber = process.env.TELNYX_MESSAGING_FROM_NUMBER?.trim()
    || process.env.SMS_FROM_NUMBER?.trim()
    || process.env.TELNYX_FROM_NUMBER?.trim()
    || process.env.PSTN_FROM_NUMBER?.trim()
    || "";
  private readonly webhookBaseUrl = (process.env.SMS_WEBHOOK_BASE_URL?.trim()
    || process.env.PSTN_WEBHOOK_BASE_URL?.trim()
    || "")
    ? trimTrailingSlash(process.env.SMS_WEBHOOK_BASE_URL?.trim() || process.env.PSTN_WEBHOOK_BASE_URL!.trim())
    : "";
  private readonly webhookSecret = process.env.SMS_WEBHOOK_SECRET?.trim() ?? "";

  async sendOutboundMessage(input: SMSOutboundMessageInput): Promise<SMSOutboundMessageResult> {
    if (!this.apiKey) {
      return this.failed("Missing TELNYX_API_KEY.");
    }
    if (!this.fromNumber && !this.messagingProfileId) {
      return this.failed("Missing TELNYX_MESSAGING_FROM_NUMBER, TELNYX_MESSAGING_PROFILE_ID, SMS_FROM_NUMBER, TELNYX_FROM_NUMBER, or PSTN_FROM_NUMBER.");
    }

    const payload: Record<string, unknown> = {
      to: input.toPhoneNumber,
      text: input.body,
    };
    if (this.fromNumber) payload.from = this.fromNumber;
    if (this.messagingProfileId) payload.messaging_profile_id = this.messagingProfileId;
    if (input.mediaUrls?.length) payload.media_urls = input.mediaUrls;
    if (this.webhookBaseUrl) {
      const secret = this.webhookSecret ? `?secret=${encodeURIComponent(this.webhookSecret)}` : "";
      payload.webhook_url = `${this.webhookBaseUrl}/api/messages/external/telnyx/status${secret}`;
      payload.use_profile_webhooks = false;
    }

    try {
      const response = await fetch("https://api.telnyx.com/v2/messages", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      const body = (await response.json().catch(() => ({}))) as Record<string, any>;
      if (!response.ok) {
        const detail = typeof body?.errors?.[0]?.detail === "string" ? body.errors[0].detail : `HTTP ${response.status}`;
        return this.failed(`Telnyx SMS send failed: ${detail}`);
      }

      return {
        providerMessageId: String(body?.data?.id ?? `telnyx_sms_${randomUUID()}`),
        provider: this.name,
        status: normalizeStatus(body?.data?.to?.[0]?.status ?? body?.data?.record_type),
      };
    } catch (err) {
      return this.failed(`Telnyx SMS send failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string): SMSOutboundMessageResult {
    logger.warn({ message }, "[sms:telnyx] outbound message failed");
    return {
      providerMessageId: `telnyx_sms_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      message,
    };
  }
}
