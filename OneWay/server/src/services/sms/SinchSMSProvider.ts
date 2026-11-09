import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { SMSOutboundMessageInput, SMSOutboundMessageResult, SMSProvider } from "./SMSProvider";

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return "Unknown provider error";
}

export class SinchSMSProvider implements SMSProvider {
  name = "sinch" as const;

  private readonly servicePlanId = process.env.SINCH_SERVICE_PLAN_ID?.trim() ?? "";
  private readonly apiToken = process.env.SINCH_API_TOKEN?.trim() ?? "";
  private readonly region = process.env.SINCH_SMS_REGION?.trim() || "us";
  private readonly fromNumber = process.env.SINCH_SMS_FROM_NUMBER?.trim()
    || process.env.SMS_FROM_NUMBER?.trim()
    || process.env.SINCH_FROM_NUMBER?.trim()
    || process.env.PSTN_FROM_NUMBER?.trim()
    || "";

  async sendOutboundMessage(input: SMSOutboundMessageInput): Promise<SMSOutboundMessageResult> {
    if (!this.servicePlanId || !this.apiToken) {
      return this.failed("Missing SINCH_SERVICE_PLAN_ID or SINCH_API_TOKEN.");
    }
    if (!this.fromNumber) {
      return this.failed("Missing SINCH_SMS_FROM_NUMBER, SMS_FROM_NUMBER, SINCH_FROM_NUMBER, or PSTN_FROM_NUMBER.");
    }

    try {
      const endpoint = `https://${encodeURIComponent(this.region)}.sms.api.sinch.com/xms/v1/${encodeURIComponent(this.servicePlanId)}/batches`;
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: this.fromNumber,
          to: [input.toPhoneNumber],
          body: input.body,
        }),
      });

      const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
      if (!response.ok) {
        const detail = typeof body.text === "string" ? body.text : typeof body.message === "string" ? body.message : `HTTP ${response.status}`;
        return this.failed(`Sinch SMS send failed: ${detail}`);
      }

      return {
        providerMessageId: typeof body.id === "string" ? body.id : `sinch_sms_${randomUUID()}`,
        provider: this.name,
        status: "queued",
      };
    } catch (err) {
      return this.failed(`Sinch SMS send failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string): SMSOutboundMessageResult {
    logger.warn({ message }, "[sms:sinch] outbound message failed");
    return {
      providerMessageId: `sinch_sms_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      message,
    };
  }
}
