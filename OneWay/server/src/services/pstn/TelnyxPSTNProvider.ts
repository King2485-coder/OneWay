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

export class TelnyxPSTNProvider implements PSTNProvider {
  name = "telnyx" as const;

  private readonly apiKey = process.env.TELNYX_API_KEY?.trim() ?? "";
  private readonly connectionId = process.env.TELNYX_CONNECTION_ID?.trim() ?? "";
  private readonly fromNumber = process.env.TELNYX_FROM_NUMBER?.trim() || process.env.PSTN_FROM_NUMBER?.trim() || "";
  private readonly webhookBaseUrl = process.env.PSTN_WEBHOOK_BASE_URL?.trim()
    ? trimTrailingSlash(process.env.PSTN_WEBHOOK_BASE_URL.trim())
    : "";

  async startOutboundCall(input: PSTNOutboundCallInput): Promise<PSTNOutboundCallResult> {
    if (!this.apiKey) {
      return this.failed("Missing TELNYX_API_KEY.");
    }
    if (!this.connectionId) {
      return this.failed("Missing TELNYX_CONNECTION_ID.");
    }
    if (!this.fromNumber) {
      return this.failed("Missing TELNYX_FROM_NUMBER or PSTN_FROM_NUMBER.");
    }
    if (input.calleeDisclosure?.enabled) {
      // TODO(telnyx): implement disclosure-first call control:
      // 1. answer the PSTN leg with speak/text-to-speech,
      // 2. gather DTMF,
      // 3. bridge only digit 1 to the LiveKit/SIP room,
      // 4. mark timeout/hangup/other digits as declined.
      return this.failed("Telnyx disclosure-first PSTN bridge is not implemented yet.");
    }

    const callSessionId = encodeURIComponent(input.callSessionId);
    const webhookUrl = this.webhookBaseUrl
      ? `${this.webhookBaseUrl}/api/pstn/telnyx/webhook?callSessionId=${callSessionId}`
      : undefined;

    const payload: Record<string, unknown> = {
      connection_id: this.connectionId,
      to: input.toPhoneNumber,
      from: this.fromNumber,
      client_state: Buffer.from(JSON.stringify({ callSessionId: input.callSessionId })).toString("base64"),
    };

    if (webhookUrl) {
      payload.webhook_url = webhookUrl;
      payload.webhook_url_method = "POST";
    }

    try {
      const response = await fetch("https://api.telnyx.com/v2/calls", {
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
        return this.failed(`Telnyx outbound call failed: ${detail}`);
      }

      const providerCallId = String(body?.data?.call_control_id ?? body?.data?.call_leg_id ?? `telnyx_${randomUUID()}`);
      return {
        providerCallId,
        provider: this.name,
        status: "initiated",
        mediaBridgeReady: false,
      };
    } catch (err) {
      return this.failed(`Telnyx outbound call failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string): PSTNOutboundCallResult {
    logger.warn({ message }, "[pstn:telnyx] outbound call failed");
    return {
      providerCallId: `telnyx_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      mediaBridgeReady: false,
      message,
    };
  }
}
