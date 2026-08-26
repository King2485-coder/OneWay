import { randomUUID } from "node:crypto";
import { logger } from "../../lib/logger";
import { twilioWebhookBaseUrl } from "../twilio/TwilioSecurity";
import type { PSTNOutboundCallInput, PSTNOutboundCallResult, PSTNProvider } from "./PSTNProvider";

interface TwilioCallCreateResult {
  sid: string;
}

interface TwilioCallInstance {
  update(args: { status: "completed" }): Promise<unknown>;
}

interface TwilioCallsApi {
  create(args: CreateCallArgs): Promise<TwilioCallCreateResult>;
}

interface TwilioClient {
  calls: TwilioCallsApi & ((sid: string) => TwilioCallInstance);
}

interface CreateCallArgs {
  to: string;
  from: string;
  callSessionId?: string;
  sourceFunction?: string;
  url?: string;
  method?: "GET" | "POST";
  twiml?: string;
  statusCallback?: string;
  statusCallbackMethod?: "GET" | "POST";
  statusCallbackEvent?: string[];
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return "Unknown provider error";
}

function phoneHint(value: string): string {
  const digits = value.replace(/\D/g, "");
  return digits ? `...${digits.slice(-4)}` : "[invalid]";
}

export class TwilioPSTNProvider implements PSTNProvider {
  name = "twilio" as const;

  private readonly accountSid = process.env.TWILIO_ACCOUNT_SID?.trim() ?? "";
  private readonly authToken = process.env.TWILIO_AUTH_TOKEN?.trim() ?? "";
  private readonly fromNumber = process.env.TWILIO_FROM_NUMBER?.trim() || process.env.PSTN_FROM_NUMBER?.trim() || "";
  private readonly webhookBaseUrl = twilioWebhookBaseUrl()
    ? trimTrailingSlash(twilioWebhookBaseUrl())
    : "";
  private readonly client: TwilioClient | null;

  constructor() {
    if (!this.accountSid || !this.authToken) {
      this.client = null;
      return;
    }

    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const twilio = require("twilio") as (sid: string, token: string) => TwilioClient;
      this.client = twilio(this.accountSid, this.authToken);
    } catch {
      this.client = null;
    }
  }

  async startOutboundCall(input: PSTNOutboundCallInput): Promise<PSTNOutboundCallResult> {
    if (!this.accountSid || !this.authToken) {
      return this.failed("Missing TWILIO_ACCOUNT_SID or TWILIO_AUTH_TOKEN.");
    }
    if (!this.fromNumber) {
      return this.failed("Missing TWILIO_FROM_NUMBER or PSTN_FROM_NUMBER.");
    }
    if (input.calleeDisclosure?.enabled) {
      return this.startDisclosureCall(input);
    }

    if (!this.webhookBaseUrl) {
      return this.failed("Missing PSTN_WEBHOOK_BASE_URL for Twilio voice webhook.");
    }

    const callSessionId = encodeURIComponent(input.callSessionId);
    const voiceWebhook = `${this.webhookBaseUrl}/api/pstn/twilio/voice?callSessionId=${callSessionId}`;
    const statusWebhook = `${this.webhookBaseUrl}/api/pstn/twilio/status?callSessionId=${callSessionId}&leg=pstn`;

    try {
      const response = await this.createCall({
        to: input.toPhoneNumber,
        from: this.fromNumber,
        callSessionId: input.callSessionId,
        sourceFunction: "TwilioPSTNProvider.startOutboundCall",
        url: voiceWebhook,
        method: "POST",
        statusCallback: statusWebhook,
        statusCallbackMethod: "POST",
        statusCallbackEvent: ["initiated", "ringing", "answered", "completed"],
      });

      return {
        providerCallId: String(response.sid),
        provider: this.name,
        status: "initiated",
        mediaBridgeReady: false,
        message: "Twilio outbound call initiated with OneWay answer webhook.",
      };
    } catch (err) {
      return this.failed(`Twilio outbound call failed: ${errorMessage(err)}`);
    }
  }

  async endOutboundCall(providerCallId: string): Promise<void> {
    if (!providerCallId.startsWith("CA")) return;
    if (this.client) {
      await this.client.calls(providerCallId).update({ status: "completed" });
      return;
    }
    const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(this.accountSid)}/Calls/${encodeURIComponent(providerCallId)}.json`;
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Basic ${Buffer.from(`${this.accountSid}:${this.authToken}`).toString("base64")}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ Status: "completed" }).toString(),
    });
    if (!response.ok && response.status !== 404) throw new Error(`Twilio hangup failed: HTTP ${response.status}`);
  }

  private async startDisclosureCall(input: PSTNOutboundCallInput): Promise<PSTNOutboundCallResult> {
    if (!this.webhookBaseUrl) {
      return this.failed("Missing PSTN_WEBHOOK_BASE_URL for Twilio disclosure webhooks.");
    }

    const callSessionId = encodeURIComponent(input.callSessionId);
    const voiceWebhook = `${this.webhookBaseUrl}/api/pstn/twilio/voice?callSessionId=${callSessionId}&stage=disclosure`;
    const statusWebhook = `${this.webhookBaseUrl}/api/pstn/twilio/status?callSessionId=${callSessionId}&leg=pstn`;
    const requireAccept = input.calleeDisclosure?.requireAccept === true;

    try {
      const response = await this.createCall({
        to: input.toPhoneNumber,
        from: this.fromNumber,
        callSessionId: input.callSessionId,
        sourceFunction: "TwilioPSTNProvider.startDisclosureCall",
        url: voiceWebhook,
        method: "POST",
        statusCallback: statusWebhook,
        statusCallbackMethod: "POST",
        statusCallbackEvent: ["initiated", "ringing", "answered", "completed"],
      });

      logger.info({
        callSessionId: input.callSessionId.slice(0, 8),
        providerCallId: String(response.sid).slice(0, 12),
        disclosureEnabled: true,
        requireAccept,
        disclosureStatus: requireAccept ? "waiting_for_callee_acceptance" : "accepted",
      }, "[pstn:twilio] disclosure call initiated");

      return {
        providerCallId: String(response.sid),
        provider: this.name,
        status: requireAccept ? "waiting_for_callee_acceptance" : "initiated",
        mediaBridgeReady: false,
        message: requireAccept
          ? "Disclosure prompt started. Waiting for callee acceptance."
          : "Disclosure prompt started.",
        calleeDisclosure: {
          enabled: true,
          requireAccept,
          accepted: !requireAccept,
          status: requireAccept ? "waiting_for_callee_acceptance" : "accepted",
        },
      };
    } catch (err) {
      return this.failed(`Twilio disclosure call failed: ${errorMessage(err)}`);
    }
  }

  private failed(message: string): PSTNOutboundCallResult {
    logger.warn({ message }, "[pstn:twilio] outbound call failed");
    return {
      providerCallId: `twilio_failed_${randomUUID()}`,
      provider: this.name,
      status: "failed",
      message,
      mediaBridgeReady: false,
    };
  }

  private async createCall(args: CreateCallArgs): Promise<TwilioCallCreateResult> {
    const { callSessionId, sourceFunction, ...twilioArgs } = args;
    logger.info({
      eventType: "twilio.recipient.call.create.attempt",
      callSessionId: callSessionId?.slice(0, 8),
      actorRole: "pstn_recipient",
      normalizedTargetNumber: phoneHint(args.to),
      fromNumberHint: phoneHint(args.from),
      sourceFunction: sourceFunction ?? "TwilioPSTNProvider.createCall",
      hasVoiceUrl: Boolean(args.url),
      hasStatusCallback: Boolean(args.statusCallback),
      reason: "external_destination_only",
    }, "[pstn:twilio] create call attempt");
    if (this.client) {
      return this.client.calls.create(twilioArgs);
    }
    return this.createCallViaRest(twilioArgs);
  }

  private async createCallViaRest(args: CreateCallArgs): Promise<TwilioCallCreateResult> {
    const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(this.accountSid)}/Calls.json`;
    const params = new URLSearchParams();
    params.set("To", args.to);
    params.set("From", args.from);
    if (args.url) params.set("Url", args.url);
    if (args.method) params.set("Method", args.method);
    if (args.twiml) params.set("Twiml", args.twiml);
    if (args.statusCallback) params.set("StatusCallback", args.statusCallback);
    if (args.statusCallbackMethod) params.set("StatusCallbackMethod", args.statusCallbackMethod);
    for (const eventName of args.statusCallbackEvent ?? []) {
      params.append("StatusCallbackEvent", eventName);
    }

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
      const twilioMessage = typeof body.message === "string"
        ? body.message
        : `HTTP ${response.status}`;
      throw new Error(twilioMessage);
    }

    const sid = typeof body.sid === "string" ? body.sid : "";
    if (!sid) throw new Error("Twilio response missing call SID.");
    return { sid };
  }

}
