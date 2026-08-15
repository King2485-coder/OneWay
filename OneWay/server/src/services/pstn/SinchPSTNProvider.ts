import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import type { PSTNOutboundCallInput, PSTNOutboundCallResult, PSTNProvider } from "./PSTNProvider";

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return "Unknown provider error";
}

export class SinchPSTNProvider implements PSTNProvider {
  name = "sinch" as const;

  private readonly projectId = process.env.SINCH_PROJECT_ID?.trim() ?? "";
  private readonly keyId = process.env.SINCH_KEY_ID?.trim() ?? "";
  private readonly keySecret = process.env.SINCH_KEY_SECRET?.trim() ?? "";
  private readonly fromNumber = process.env.SINCH_FROM_NUMBER?.trim() || process.env.PSTN_FROM_NUMBER?.trim() || "";
  private readonly webhookBaseUrl = process.env.PSTN_WEBHOOK_BASE_URL?.trim()
    ? trimTrailingSlash(process.env.PSTN_WEBHOOK_BASE_URL.trim())
    : "";

  async startOutboundCall(input: PSTNOutboundCallInput): Promise<PSTNOutboundCallResult> {
    if (!this.projectId) {
      return this.failed("Missing SINCH_PROJECT_ID.");
    }
    if (!this.keyId || !this.keySecret) {
      return this.failed("Missing SINCH_KEY_ID or SINCH_KEY_SECRET.");
    }
    if (!this.fromNumber) {
      return this.failed("Missing SINCH_FROM_NUMBER or PSTN_FROM_NUMBER.");
    }
    if (input.calleeDisclosure?.enabled) {
      // TODO(sinch): implement disclosure-first callout:
      // 1. play the configured disclosure prompt,
      // 2. gather DTMF,
      // 3. connect digit 1 to the LiveKit/SIP room,
      // 4. decline on timeout, hangup, or any other digit.
      return this.failed("Sinch disclosure-first PSTN bridge is not implemented yet.");
    }

    const auth = Buffer.from(`${this.keyId}:${this.keySecret}`).toString("base64");
    const callSessionId = encodeURIComponent(input.callSessionId);
    const callbackUrl = this.webhookBaseUrl
      ? `${this.webhookBaseUrl}/api/pstn/sinch/webhook?callSessionId=${callSessionId}`
      : undefined;

    const payload: Record<string, unknown> = {
      method: "ttsCallout",
      ttsCallout: {
        cli: this.fromNumber,
        destination: {
          type: "number",
          endpoint: input.toPhoneNumber,
        },
        locale: "en-US",
        text: "This OneWay bridge is connecting your call.",
      },
      custom: input.callSessionId,
    };

    if (callbackUrl) {
      payload.callbackUrl = callbackUrl;
    }

    try {
      const response = await fetch("https://calling.api.sinch.com/calling/v1/callouts", {
        method: "POST",
        headers: {
          Authorization: `Basic ${auth}`,
          "Project-ID": this.projectId,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      const body = (await response.json().catch(() => ({}))) as Record<string, any>;
      if (!response.ok) {
        const detail = typeof body?.error?.message === "string"
          ? body.error.message
          : typeof body?.message === "string"
            ? body.message
            : `HTTP ${response.status}`;
        return this.failed(`Sinch outbound call failed: ${detail}`);
      }

      const providerCallId = String(body?.callId ?? body?.id ?? `sinch_${randomUUID()}`);
      return {
        providerCallId,
        provider: this.name,
        status: "initiated",
        mediaBridgeReady: false,
      };
    } catch (err) {
      return this.failed(`Sinch outbound call failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string): PSTNOutboundCallResult {
    logger.warn({ message }, "[pstn:sinch] outbound call failed");
    return {
      providerCallId: `sinch_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      mediaBridgeReady: false,
      message,
    };
  }
}
