import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { logger } from "../lib/logger";
import { redactSensitiveObject, redactSensitiveString, shortId } from "../lib/privacy/redaction";
import { prisma } from "../lib/db";
import type { PSTNProvider } from "../services/pstn/PSTNProvider";
import type { LiveKitTokenService } from "../services/LiveKitTokenService";
import {
  LiveKitSIPBridgeService,
  liveKitSIPParticipantIdentity,
  type LiveKitSIPParticipantSnapshot,
  type MediaBridgeStatus,
} from "../services/pstn/LiveKitSIPBridgeService";
import { twilioSignedCallbackUrl, twilioWebhookMiddleware, validateTwilioProductionEnvironment } from "../services/twilio/TwilioSecurity";

const startCallSchema = z.object({
  toPhoneNumber: z.string().min(1).max(64),
  fromOneWayNumber: z.string().min(1).max(64).optional(),
  idempotencyKey: z.string().min(8).max(128).optional(),
  callerCallKitUUID: z.string().uuid().optional(),
});

const ONE_MINUTE_MS = 60_000;
const ONE_HOUR_MS = 60 * ONE_MINUTE_MS;
const MAX_PER_MINUTE = 5;
const MAX_PER_HOUR = 30;

const pstnAttempts = new Map<string, number[]>();
const pstnStartIdempotency = new Map<string, { expiresAt: number; payload: unknown }>();
const sipParticipantWatcherKeys = new Set<string>();
const twilioDialSIPWatcherKeys = new Set<string>();
const LOCAL_WEBHOOK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);
const PRODUCTION_WEBHOOK_HOSTS = new Set(["api.oneway.is", "api.oneway.app"]);
const LIVEKIT_REQUIRED_ENV = ["LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET"] as const;
const ENABLE_DIRECT_PROVIDER_FALLBACK = (process.env.PSTN_ENABLE_DIRECT_PROVIDER_FALLBACK ?? "").trim().toLowerCase() === "true";
const DISCLOSURE_WAITING_STATUS = "waiting_for_callee_acceptance";
const MAX_TWILIO_BODY_PREVIEW = 1200;

type PSTNMode = "live" | "stub" | "misconfigured";
type PSTNDisclosureStatus = "disabled" | "waiting_for_callee_acceptance" | "accepted" | "declined" | "failed";
type InboundCallerTrust = "trusted" | "unknown";
type InboundRecipientAvailability = "available" | "busy" | "offline";

interface TwilioFailureSnapshot {
  callSid?: string;
  errorCode?: string;
  errorMessage?: string;
  failingUrl?: string;
  requestMethod?: string;
  responseStatus?: number;
  responseContentType?: string;
  responseBodyPreview?: string;
  webhookLatencyMs?: number;
  sipStatus?: string;
  timestamp: string;
}

let lastTwilioFailure: TwilioFailureSnapshot | null = null;

interface PSTNDisclosureConfig {
  enabled: boolean;
  requireAccept: boolean;
  brand: string;
}

interface InboundOwnedNumberProfile {
  userId: string;
  displayName?: string;
  matchedNumber: string;
  source: "onewayNumber" | "businessNumber";
}

interface InboundCallerProfile {
  userId?: string;
  displayName?: string;
  phoneNumber?: string;
  trust: InboundCallerTrust;
  trustReasons: string[];
}

interface InboundVoiceContext {
  recipient: InboundOwnedNumberProfile;
  caller: InboundCallerProfile;
  fromNumber?: string;
  toNumber: string;
  providerCallId?: string;
  introduction?: string;
  availability: InboundRecipientAvailability;
}

interface InboundAppCallStartArgs {
  callerId: string;
  calleeId: string;
  callerDisplayName: string;
  callerName: string;
  callerNumber?: string;
  introduction?: string;
  trusted: boolean;
}

interface InboundAppCallStartResult {
  callId: string;
  roomName: string;
}

export interface PSTNPreflightResult {
  ok: boolean;
  provider: string;
  mode: PSTNMode;
  liveKitConfigured: boolean;
  sipTrunkConfigured: boolean;
  providerConfigured: boolean;
  webhookBaseUrlConfigured: boolean;
  mediaBridgeEnabled: boolean;
  missing: string[];
  warnings: string[];
}

function consumeRateLimit(userId: string): boolean {
  const now = Date.now();
  const history = pstnAttempts.get(userId) ?? [];
  const withinHour = history.filter((ts) => now - ts < ONE_HOUR_MS);
  const withinMinute = withinHour.filter((ts) => now - ts < ONE_MINUTE_MS);

  if (withinMinute.length >= MAX_PER_MINUTE || withinHour.length >= MAX_PER_HOUR) {
    pstnAttempts.set(userId, withinHour);
    return false;
  }

  withinHour.push(now);
  pstnAttempts.set(userId, withinHour);
  return true;
}

function envValue(name: string): string {
  return (process.env[name] ?? "").trim();
}

function envFlag(name: string, defaultValue: boolean): boolean {
  const raw = envValue(name).toLowerCase();
  if (!raw) return defaultValue;
  return ["1", "true", "yes", "on"].includes(raw);
}

function sanitizeDisclosureBrand(value: string): string {
  const cleaned = value
    .replace(/[^a-zA-Z0-9 .'-]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 32);
  return cleaned || "OneWay";
}

function pstnDisclosureConfig(): PSTNDisclosureConfig {
  return {
    enabled: envFlag("PSTN_CALLER_DISCLOSURE_ENABLED", true),
    requireAccept: envFlag("PSTN_CALLER_DISCLOSURE_REQUIRE_ACCEPT", true),
    brand: sanitizeDisclosureBrand(envValue("PSTN_CALLER_DISCLOSURE_BRAND") || "OneWay"),
  };
}

function isPlaceholderValue(value: string): boolean {
  const normalized = value.trim().toLowerCase();
  return normalized === "change_me"
    || normalized === "changeme"
    || normalized === "replace_me"
    || normalized === "replace-with-real-value";
}

function isEnvSet(name: string): boolean {
  const value = envValue(name);
  return value.length > 0 && !isPlaceholderValue(value);
}

function normalizePhoneNumber(value: string): string {
  const trimmed = value.trim();
  let output = "";
  for (const [index, char] of Array.from(trimmed).entries()) {
    if (char >= "0" && char <= "9") {
      output += char;
      continue;
    }
    if (char === "+" && index === 0) {
      output += char;
    }
  }
  const digits = output.replace(/\D/g, "");
  if (!digits) return output;

  if (output.startsWith("+")) {
    return `+${digits}`;
  }

  // Default US normalization for 10-digit local numbers in current deployment.
  if (digits.length === 10) {
    return `+1${digits}`;
  }

  if (digits.length === 11 && digits.startsWith("1")) {
    return `+${digits}`;
  }

  return output;
}

function normalizeOptionalPhoneNumber(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const normalized = normalizePhoneNumber(value);
  return isObviouslyInvalidPhone(normalized) ? undefined : normalized;
}

function sameNormalizedPhoneNumber(lhs: string | undefined | null, rhs: string | undefined | null): boolean {
  const left = normalizeOptionalPhoneNumber(lhs ?? undefined);
  const right = normalizeOptionalPhoneNumber(rhs ?? undefined);
  return Boolean(left && right && left === right);
}

function asTwilioCallSid(value: string | undefined | null): string | undefined {
  const trimmed = value?.trim() ?? "";
  return trimmed.startsWith("CA") ? trimmed : undefined;
}

async function callerOwnedCallableNumbers(userId: string): Promise<string[]> {
  const [userNumbers, businessPresence] = await Promise.all([
    prisma.userNumber.findMany({
      where: { userId },
      select: { number: true },
    }),
    prisma.businessPresence.findFirst({
      where: { userId },
      select: { publicPhoneNumber: true },
    }),
  ]);

  const numbers = [
    ...userNumbers.map((item) => item.number),
    businessPresence?.publicPhoneNumber,
  ];
  return Array.from(new Set(
    numbers
      .map((number) => normalizeOptionalPhoneNumber(number))
      .filter((number): number is string => Boolean(number)),
  ));
}

async function callerRedialBlockReason(args: {
  userId: string;
  targetNumber: string;
  selectedCallerNumber?: string;
}): Promise<string | undefined> {
  const ownedNumbers = await callerOwnedCallableNumbers(args.userId);
  if (ownedNumbers.some((number) => sameNormalizedPhoneNumber(args.targetNumber, number))) {
    return "target_matches_caller_owned_number";
  }
  if (sameNormalizedPhoneNumber(args.targetNumber, args.selectedCallerNumber)) {
    return "target_matches_selected_caller_number";
  }
  return undefined;
}

function logCallLegTimeline(
  eventType: string,
  payload: Record<string, unknown>,
  message = `[pstn] ${eventType}`,
): void {
  logger.info({
    eventType,
    ...payload,
  }, message);
}

function requiredProviderEnv(provider: string): string[] {
  switch (provider) {
    case "twilio":
      return ["TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER"];
    case "telnyx":
      return ["TELNYX_API_KEY", "TELNYX_CONNECTION_ID", "TELNYX_FROM_NUMBER"];
    case "sinch":
      return ["SINCH_PROJECT_ID", "SINCH_KEY_ID", "SINCH_KEY_SECRET", "SINCH_FROM_NUMBER"];
    case "stub":
    default:
      return [];
  }
}

function parseWebhookHost(value: string): { isValid: boolean; host?: string } {
  try {
    const parsed = new URL(value);
    return { isValid: true, host: parsed.hostname.toLowerCase() };
  } catch {
    return { isValid: false };
  }
}

function publicWebhookBaseUrl(): string {
  return (envValue("PUBLIC_WEBHOOK_BASE_URL") || envValue("PSTN_WEBHOOK_BASE_URL")).replace(/\/+$/, "");
}

function isPrivateWebhookHost(host: string | undefined): boolean {
  const normalized = (host ?? "").toLowerCase();
  if (!normalized) return true;
  if (LOCAL_WEBHOOK_HOSTS.has(normalized) || normalized.endsWith(".local")) return true;
  if (/^192\.168\./.test(normalized)) return true;
  if (/^10\./.test(normalized)) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(normalized)) return true;
  if (/^169\.254\./.test(normalized)) return true;
  return false;
}

function isPublicHttpsWebhookUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" && !isPrivateWebhookHost(parsed.hostname);
  } catch {
    return false;
  }
}

function isDevelopmentServerUsingProductionWebhook(host: string | undefined): boolean {
  return process.env.NODE_ENV !== "production"
    && PRODUCTION_WEBHOOK_HOSTS.has((host ?? "").toLowerCase());
}

export function evaluatePSTNPreflight(provider: string): PSTNPreflightResult {
  const missing = new Set<string>();
  const warnings: string[] = [];
  const providerName = provider || "stub";
  const disclosure = pstnDisclosureConfig();
  const webhookBaseUrl = publicWebhookBaseUrl();
  const sipBridgeUriTemplate = envValue("PSTN_SIP_BRIDGE_URI_TEMPLATE");
  const providerEnv = requiredProviderEnv(providerName);
  const providerConfigured = providerEnv.every(isEnvSet);
  const usesTwilioConnectorDisclosure = disclosure.enabled && providerName === "twilio";

  const liveKitConfigured = LIVEKIT_REQUIRED_ENV.every(isEnvSet);

  const sipTrunkConfigured = [
    "LIVEKIT_SIP_TRUNK_ID",
    "TELNYX_SIP_TRUNK_ID",
    "TWILIO_SIP_TRUNK_SID",
  ].some(isEnvSet);

  if (!sipTrunkConfigured && !usesTwilioConnectorDisclosure) {
    warnings.push("LiveKit SIP trunk is not configured. PSTN phone may ring, but app audio will not bridge.");
  }

  let webhookBaseUrlConfigured = webhookBaseUrl.length > 0;
  if (webhookBaseUrl.length > 0) {
    const parsed = parseWebhookHost(webhookBaseUrl);
    if (!parsed.isValid) {
      webhookBaseUrlConfigured = false;
      warnings.push("PUBLIC_WEBHOOK_BASE_URL/PSTN_WEBHOOK_BASE_URL is invalid; provider callbacks will fail.");
    } else if (isDevelopmentServerUsingProductionWebhook(parsed.host)) {
      warnings.push("Development PSTN server is using the production webhook host; provider callbacks will not reach this server's call session store. Use a public HTTPS tunnel for PUBLIC_WEBHOOK_BASE_URL/PSTN_WEBHOOK_BASE_URL.");
      if (providerName !== "stub") {
        webhookBaseUrlConfigured = false;
        missing.add("PUBLIC_WEBHOOK_BASE_URL");
      }
    } else if (!isPublicHttpsWebhookUrl(webhookBaseUrl)) {
      warnings.push("Twilio webhook base URL must be public HTTPS; LAN, localhost, .local, ws://, and internal Docker hosts are not allowed.");
      if (providerName !== "stub") {
        webhookBaseUrlConfigured = false;
      }
    }
  }

  if (providerName !== "stub") {
    for (const envName of LIVEKIT_REQUIRED_ENV) {
      if (!isEnvSet(envName)) missing.add(envName);
    }
    if (!sipTrunkConfigured && !usesTwilioConnectorDisclosure) {
      missing.add("LIVEKIT_SIP_TRUNK_ID");
    }
    for (const envName of providerEnv) {
      if (!isEnvSet(envName)) missing.add(envName);
    }
    if (!webhookBaseUrl) {
      missing.add("PUBLIC_WEBHOOK_BASE_URL");
      webhookBaseUrlConfigured = false;
    }
  }

  const mediaBridgeEnabled = liveKitConfigured && (sipTrunkConfigured || usesTwilioConnectorDisclosure);

  if (disclosure.enabled && providerName !== "stub") {
    warnings.push("PSTN callee disclosure is enabled; outside recipients must accept before audio is bridged.");
    if (providerName === "twilio" && !sipBridgeUriTemplate) {
      warnings.push("PSTN_SIP_BRIDGE_URI_TEMPLATE is not set; Twilio disclosure acceptance will use LiveKit's existing-call connector.");
    }
    if (providerName === "telnyx" || providerName === "sinch") {
      warnings.push(`${providerName} disclosure-first bridge is fail-closed until provider-specific DTMF bridge handling is implemented.`);
    }
  }

  if (providerName === "stub") {
    warnings.push("Stub mode does not place real PSTN calls.");
    return {
      ok: true,
      provider: providerName,
      mode: "stub",
      liveKitConfigured,
      sipTrunkConfigured,
      providerConfigured: true,
      webhookBaseUrlConfigured,
      mediaBridgeEnabled,
      missing: [],
      warnings,
    };
  }

  const ok = providerConfigured && liveKitConfigured && sipTrunkConfigured && webhookBaseUrlConfigured && mediaBridgeEnabled && missing.size === 0;
  return {
    ok,
    provider: providerName,
    mode: ok ? "live" : "misconfigured",
    liveKitConfigured,
    sipTrunkConfigured,
    providerConfigured,
    webhookBaseUrlConfigured,
    mediaBridgeEnabled,
    missing: Array.from(missing),
    warnings,
  };
}

function safeValue(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function applyTemplate(template: string, vars: Record<string, string>): string {
  return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, key: string) => vars[key] ?? "");
}

function isObviouslyInvalidPhone(value: string): boolean {
  const digits = value.replace(/\D/g, "");
  if (digits.length < 7 || digits.length > 15) return true;
  if (/^(\d)\1{6,}$/.test(digits)) return true;
  if (/^0+$/.test(digits)) return true;
  return false;
}

function sanitizeDisclosureDisplayName(value: string | null | undefined): string | undefined {
  const cleaned = String(value ?? "")
    .replace(/[^a-zA-Z0-9 .'-]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 48);
  if (!cleaned) return undefined;
  if (cleaned.includes("@")) return undefined;
  if (/^\+?[0-9 .()-]{7,}$/.test(cleaned)) return undefined;
  return cleaned;
}

async function loadCallerDisclosureDisplayName(userId: string): Promise<string | undefined> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: {
      displayName: true,
      identity: {
        select: {
          walkieName: true,
          displayName: true,
          username: true,
        },
      },
    },
  });

  return sanitizeDisclosureDisplayName(user?.identity?.walkieName)
    ?? sanitizeDisclosureDisplayName(user?.identity?.displayName)
    ?? sanitizeDisclosureDisplayName(user?.displayName)
    ?? sanitizeDisclosureDisplayName(user?.identity?.username);
}

function buildDisclosurePrompt(disclosure: PSTNDisclosureConfig, displayName: string | undefined): string {
  if (displayName) {
    return `You have a ${disclosure.brand} call from ${displayName}. Press 1 to accept, or hang up to decline.`;
  }
  return `You have a ${disclosure.brand} call. Press 1 to accept, or hang up to decline.`;
}

function disclosureStatusFromCallStatus(status: string, failureReason?: string | null): PSTNDisclosureStatus {
  const normalized = status.trim().toLowerCase();
  if (normalized === DISCLOSURE_WAITING_STATUS) return "waiting_for_callee_acceptance";
  if (normalized === "answered" || normalized === "connected" || normalized === "ringing" || normalized === "initiated") {
    return "accepted";
  }
  if (normalized === "failed") {
    const reason = (failureReason ?? "").toLowerCase();
    return reason.includes("declin") || reason.includes("not_accept") || reason.includes("not accepted")
      ? "declined"
      : "failed";
  }
  return "disabled";
}

function calleeDisclosurePayload(args: {
  enabled: boolean;
  requireAccept: boolean;
  status: string;
  failureReason?: string | null;
}) {
  const disclosureStatus = args.enabled
    ? disclosureStatusFromCallStatus(args.status, args.failureReason)
    : "disabled";
  return {
    enabled: args.enabled,
    requireAccept: args.requireAccept,
    accepted: args.enabled
      ? disclosureStatus === "accepted"
      : false,
    status: disclosureStatus,
  };
}

function sanitizeSpokenText(value: string | null | undefined, maxLength = 80): string | undefined {
  const cleaned = String(value ?? "")
    .replace(/[^a-zA-Z0-9 .,'!?-]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
  return cleaned || undefined;
}

function phoneLogHint(value: string | undefined): string | undefined {
  const digits = (value ?? "").replace(/\D/g, "");
  if (!digits) return undefined;
  return `...${digits.slice(-4)}`;
}

function xmlResponse(inner: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${inner}</Response>`;
}

function validateTwiML(twiml: string): { ok: true } | { ok: false; reason: string } {
  const trimmed = twiml.trim();
  if (!trimmed.startsWith('<?xml version="1.0" encoding="UTF-8"?>')) {
    return { ok: false, reason: "missing_xml_declaration" };
  }
  if (!trimmed.includes("<Response>") || !trimmed.endsWith("</Response>")) {
    return { ok: false, reason: "missing_response_root" };
  }
  if ((trimmed.match(/<Response>/g) ?? []).length !== 1 || (trimmed.match(/<\/Response>/g) ?? []).length !== 1) {
    return { ok: false, reason: "invalid_response_root_count" };
  }
  const hasDialSip = /<Dial\b[\s\S]*<Sip>[\s\S]*<\/Sip>[\s\S]*<\/Dial>/.test(trimmed);
  const hasStream = /<Connect\b[\s\S]*<Stream\b[\s\S]*<\/Connect>/.test(trimmed);
  if (hasDialSip && hasStream) {
    return { ok: false, reason: "mixed_sip_and_stream_twiml" };
  }
  if (/<Sip>\s*<\/Sip>/.test(trimmed)) {
    return { ok: false, reason: "empty_sip_uri" };
  }
  return { ok: true };
}

function fullRequestUrl(req: express.Request): string {
  const proto = String(req.headers["x-forwarded-proto"] ?? req.protocol ?? "https").split(",")[0].trim() || "https";
  const host = String(req.headers["x-forwarded-host"] ?? req.headers.host ?? "").split(",")[0].trim();
  return `${proto}://${host}${req.originalUrl || req.url}`;
}

function twilioBodyPreview(value: string): string {
  return redactSensitiveString(value).slice(0, MAX_TWILIO_BODY_PREVIEW);
}

function setLastTwilioFailure(snapshot: Omit<TwilioFailureSnapshot, "timestamp">): void {
  lastTwilioFailure = {
    ...snapshot,
    responseBodyPreview: snapshot.responseBodyPreview
      ? twilioBodyPreview(snapshot.responseBodyPreview)
      : undefined,
    timestamp: new Date().toISOString(),
  };
}

function twilioDebugRouteEnabled(): boolean {
  return process.env.NODE_ENV !== "production"
    || envFlag("PSTN_DEBUG_ROUTES_ENABLED", false);
}

function twilioBasicAuthHeader(): string | undefined {
  const accountSid = envValue("TWILIO_ACCOUNT_SID");
  const authToken = envValue("TWILIO_AUTH_TOKEN");
  if (!accountSid || !authToken) return undefined;
  return `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString("base64")}`;
}

function twilioAlertValue(alert: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = alert[key];
    if (typeof value === "string" && value.trim()) return value.trim();
    if (typeof value === "number") return String(value);
  }
  return undefined;
}

function twilioAlertFromRecord(alert: Record<string, unknown>): TwilioFailureSnapshot {
  const responseBody = twilioAlertValue(alert, ["response_body", "responseBody"]);
  return {
    callSid: twilioAlertValue(alert, ["call_sid", "callSid", "resource_sid", "resourceSid"]),
    errorCode: twilioAlertValue(alert, ["error_code", "errorCode"]),
    errorMessage: twilioAlertValue(alert, ["alert_text", "alertText", "message"]),
    failingUrl: twilioAlertValue(alert, ["request_url", "requestUrl", "url"]),
    requestMethod: twilioAlertValue(alert, ["request_method", "requestMethod"]),
    responseStatus: Number(twilioAlertValue(alert, ["response_status_code", "responseStatusCode", "response_status", "responseStatus"])) || undefined,
    responseContentType: twilioAlertValue(alert, ["response_content_type", "responseContentType"]),
    responseBodyPreview: responseBody ? twilioBodyPreview(responseBody) : undefined,
    sipStatus: twilioAlertValue(alert, ["sip_response_code", "sipResponseCode", "sip_status", "sipStatus"]),
    timestamp: twilioAlertValue(alert, ["date_created", "dateCreated", "timestamp"]) ?? new Date().toISOString(),
  };
}

async function fetchTwilioAlertsEndpoint(
  endpoint: string,
  authorization: string,
): Promise<{ status: number; alerts: Record<string, unknown>[] }> {
  const response = await fetch(endpoint, {
    headers: { Authorization: authorization },
  });
  if (!response.ok) {
    return { status: response.status, alerts: [] };
  }
  const body = await response.json().catch(() => ({})) as Record<string, unknown>;
  const rawAlerts = Array.isArray(body.alerts)
    ? body.alerts
    : Array.isArray(body.results)
      ? body.results
      : [];
  const alerts = rawAlerts.filter((item): item is Record<string, unknown> => Boolean(item && typeof item === "object"));
  return { status: response.status, alerts };
}

async function fetchLatestTwilioFailureFromDebugger(): Promise<TwilioFailureSnapshot | null> {
  const accountSid = envValue("TWILIO_ACCOUNT_SID");
  const authorization = twilioBasicAuthHeader();
  if (!accountSid || !authorization) return null;

  const endpoints = [
    `https://monitor.twilio.com/v1/Alerts?PageSize=20`,
    `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/Alerts.json?PageSize=20`,
  ];
  let lastStatus = 0;
  let alerts: Record<string, unknown>[] = [];
  for (const endpoint of endpoints) {
    const result = await fetchTwilioAlertsEndpoint(endpoint, authorization);
    lastStatus = result.status;
    if (result.alerts.length > 0) {
      alerts = result.alerts;
      break;
    }
    if (result.status >= 200 && result.status < 300) break;
  }

  if (!alerts.length && lastStatus >= 400) {
    return {
      errorCode: `twilio_alerts_http_${lastStatus}`,
      errorMessage: "Could not retrieve Twilio Debugger alerts.",
      timestamp: new Date().toISOString(),
    };
  }

  const alert = alerts.find((item): item is Record<string, unknown> => {
    const requestUrl = twilioAlertValue(item, ["request_url", "requestUrl", "url"]);
    const alertText = twilioAlertValue(item, ["alert_text", "alertText", "message"]);
    return Boolean(
      requestUrl?.includes("/api/pstn/")
        || alertText?.toLowerCase().includes("twiml")
        || alertText?.toLowerCase().includes("application error")
        || twilioAlertValue(item, ["error_code", "errorCode"]),
    );
  }) as Record<string, unknown> | undefined;
  if (!alert) return null;
  return twilioAlertFromRecord(alert);
}

function sayXml(value: string): string {
  return `<Say voice="alice">${safeValue(value)}</Say>`;
}

function hangupXml(): string {
  return "<Hangup/>";
}

function buildConnectLeadIn(trust: InboundCallerTrust): string {
  return trust === "trusted"
    ? "Connecting you now."
    : "Thanks. One moment while I try to connect you.";
}

function buildUnavailablePrompt(displayName: string | undefined): string {
  if (displayName) {
    return `${displayName} is unavailable right now. Would you like to leave a voice message or send a text message?`;
  }
  return "They are unavailable right now. Would you like to leave a voice message or send a text message?";
}

function buildRecipientAnnouncement(context: Pick<InboundVoiceContext, "caller" | "introduction">): string {
  if (context.caller.trust === "trusted" && context.caller.displayName) {
    return `Incoming OneWay call from ${context.caller.displayName}.`;
  }
  if (context.introduction) {
    return `Incoming OneWay call from the caller who said: '${context.introduction}'.`;
  }
  if (context.caller.displayName) {
    return `Incoming OneWay call from ${context.caller.displayName}.`;
  }
  return "Incoming OneWay call.";
}

function syntheticInboundCallerId(fromNumber: string | undefined, providerCallId: string | undefined): string {
  const source = fromNumber ?? providerCallId ?? randomUUID();
  return `pstn:${source}`.slice(0, 128);
}

async function resolveOwnedNumberProfile(value: string | undefined): Promise<InboundOwnedNumberProfile | undefined> {
  if (!value) return undefined;
  const normalized = normalizePhoneNumber(value);
  if (isObviouslyInvalidPhone(normalized)) return undefined;
  const candidates = Array.from(new Set([normalized, value.trim()].filter(Boolean)));

  const userNumber = await prisma.userNumber.findFirst({
    where: { number: { in: candidates } },
    select: { userId: true, number: true },
  });

  if (userNumber) {
    return {
      userId: userNumber.userId,
      displayName: await loadCallerDisclosureDisplayName(userNumber.userId),
      matchedNumber: userNumber.number,
      source: "onewayNumber",
    };
  }

  const businessPresence = await prisma.businessPresence.findFirst({
    where: { publicPhoneNumber: { in: candidates } },
    select: { userId: true, publicPhoneNumber: true, businessName: true },
  });

  if (!businessPresence) return undefined;
  return {
    userId: businessPresence.userId,
    displayName: sanitizeDisclosureDisplayName(businessPresence.businessName)
      ?? await loadCallerDisclosureDisplayName(businessPresence.userId),
    matchedNumber: businessPresence.publicPhoneNumber,
    source: "businessNumber",
  };
}

async function resolveInboundCallerProfile(
  recipientUserId: string,
  fromNumber: string | undefined,
): Promise<InboundCallerProfile> {
  const caller = await resolveOwnedNumberProfile(fromNumber);
  if (!caller) {
    return {
      phoneNumber: fromNumber,
      trust: "unknown",
      trustReasons: [],
    };
  }

  const trustReasons = ["oneway_user"];
  if (caller.userId === recipientUserId) {
    trustReasons.push("same_user");
  } else {
    const connectedContact = await prisma.oneWayContact.findFirst({
      where: {
        status: "connected",
        OR: [
          { userId: recipientUserId, contactUserId: caller.userId },
          { userId: caller.userId, contactUserId: recipientUserId },
        ],
      },
      select: { id: true },
    });
    if (connectedContact) {
      trustReasons.push("connected_contact");
    }
  }

  return {
    userId: caller.userId,
    displayName: caller.displayName,
    phoneNumber: fromNumber,
    trust: trustReasons.length > 0 ? "trusted" : "unknown",
    trustReasons,
  };
}

function twilioVoiceActionUrl(stage: string, params: Record<string, string | undefined>): string {
  const baseUrl = publicWebhookBaseUrl();
  const search = new URLSearchParams({ stage });
  for (const [key, value] of Object.entries(params)) {
    if (value) search.set(key, value);
  }
  return `${baseUrl}/api/pstn/twilio/voice?${search.toString()}`;
}

function twilioDisclosureAcceptUrl(callSessionId: string | undefined): string {
  return twilioSignedCallbackUrl("/api/pstn/twilio/disclosure/accept", { callSessionId }, publicWebhookBaseUrl());
}

function twilioDisclosureTimeoutUrl(callSessionId: string | undefined): string {
  return twilioSignedCallbackUrl("/api/pstn/twilio/disclosure/timeout", { callSessionId }, publicWebhookBaseUrl());
}

function sipUriForRoom(args: {
  template: string;
  roomName: string;
  callSessionId: string;
  toPhoneNumber: string;
}): string {
  if (!args.template) return "";
  return applyTemplate(args.template, {
    roomName: args.roomName,
    callSessionId: args.callSessionId,
    toPhoneNumber: args.toPhoneNumber,
  }).trim();
}

function sipUriWithOneWayHeaders(args: {
  sipUri: string;
  callSessionId: string;
  providerCallId?: string;
  role: "pstn_recipient" | "oneway_user";
}): string {
  const headers = new URLSearchParams({
    "X-OneWay-CallSessionId": args.callSessionId,
    "X-OneWay-Role": args.role,
  });
  if (args.providerCallId) {
    headers.set("X-OneWay-ProviderCallId", args.providerCallId);
  }
  return `${args.sipUri}${args.sipUri.includes("?") ? "&" : "?"}${headers.toString()}`;
}

function dialExistingTwilioLegToSIPXml(args: {
  sipUri: string;
  callSessionId: string;
  providerCallId?: string;
}): string {
  const sipUriWithHeaders = sipUriWithOneWayHeaders({
    sipUri: args.sipUri,
    callSessionId: args.callSessionId,
    providerCallId: args.providerCallId,
    role: "pstn_recipient",
  });
  return `<Dial answerOnBridge="true"><Sip>${safeValue(sipUriWithHeaders)}</Sip></Dial>`;
}

function connectExistingTwilioLegToLiveKitXml(connectUrl: string): string {
  return `<Connect><Stream url="${safeValue(connectUrl)}" /></Connect>`;
}

async function findOutboundTwilioCallSession(args: {
  callSessionId?: string;
  providerCallId?: string;
}): Promise<{
  id: string;
  callerUserId: string | null;
  roomName: string;
  toNumber: string | null;
  externalPhoneNumber: string | null;
  fromNumber: string | null;
  providerCallId: string | null;
  sipParticipantId: string | null;
  mediaBridgeStatus: string | null;
  status: string;
} | null> {
  const select = {
    id: true,
    callerUserId: true,
    roomName: true,
    toNumber: true,
    externalPhoneNumber: true,
    fromNumber: true,
    providerCallId: true,
    sipParticipantId: true,
    mediaBridgeStatus: true,
    status: true,
  } as const;

  if (args.callSessionId) {
    const byId = await prisma.callSession.findFirst({
      where: {
        id: args.callSessionId,
        provider: "twilio",
        networkType: "pstnBridge",
      },
      select,
    });
    if (byId) return byId;
  }

  if (args.providerCallId) {
    return await prisma.callSession.findFirst({
      where: {
        provider: "twilio",
        providerCallId: args.providerCallId,
        networkType: "pstnBridge",
      },
      select,
    });
  }

  return null;
}

async function findInboundCallSession(providerCallId: string | undefined): Promise<{
  id: string;
  roomName: string;
} | undefined> {
  if (!providerCallId) return undefined;
  const existing = await prisma.callSession.findFirst({
    where: {
      provider: "twilio",
      providerCallId,
      networkType: "pstnInbound",
    },
    select: { id: true, roomName: true },
  });
  return existing ?? undefined;
}

async function createInboundCallSession(args: {
  roomName: string;
  context: InboundVoiceContext;
  callerId: string;
}): Promise<{ id: string; roomName: string }> {
  const existing = await findInboundCallSession(args.context.providerCallId);
  if (existing) return existing;

  const id = randomUUID();
  await prisma.callSession.create({
    data: {
      id,
      roomName: args.roomName,
      callerUserId: args.callerId,
      calleeUserId: args.context.recipient.userId,
      fromIdentity: args.context.caller.displayName,
      fromNumber: args.context.fromNumber,
      toIdentity: args.context.recipient.displayName,
      toNumber: args.context.toNumber,
      externalPhoneNumber: args.context.fromNumber,
      networkType: "pstnInbound",
      provider: "twilio",
      providerCallId: args.context.providerCallId,
      status: "ringing",
      mediaBridgeStatus: "connecting",
    },
  });

  return { id, roomName: args.roomName };
}

function isDisclosureNotAcceptedFailure(status: string, failureReason?: string | null): boolean {
  if (status.trim().toLowerCase() !== "failed") return false;
  const reason = (failureReason ?? "").toLowerCase();
  return reason.includes("callee_disclosure")
    || reason.includes("not_accept")
    || reason.includes("not accepted")
    || reason.includes("declin");
}

function mapProviderStatusToCallStatus(status: string): string {
  const normalized = status.trim().toLowerCase();
  switch (normalized) {
    case "waiting_for_callee_acceptance":
      return DISCLOSURE_WAITING_STATUS;
    case "accepted":
      return "answered";
    case "connected":
      return "connected";
    case "queued":
    case "initiated":
      return "initiated";
    case "ringing":
      return "ringing";
    case "in-progress":
    case "answered":
    case "bridged":
      return "answered";
    case "completed":
    case "ended":
    case "hangup":
      return "ended";
    case "failed":
    case "busy":
    case "no-answer":
    case "canceled":
    case "cancelled":
      return "failed";
    default:
      return "initiated";
  }
}

function mapProviderStatusToMediaBridgeStatus(status: string): MediaBridgeStatus | undefined {
  const mapped = mapProviderStatusToCallStatus(status);
  switch (mapped) {
    case "ringing":
    case "initiated":
      return "connecting";
    case "answered":
    case "connected":
      return "connected";
    case "failed":
      return "failed";
    default:
      return undefined;
  }
}

function shouldAttemptProviderFallback(providerName: string): boolean {
  // Keep LiveKit SIP as the primary path. Allow direct provider fallback only
  // for stub mode, or when explicitly enabled for controlled rollouts.
  return providerName === "stub" || ENABLE_DIRECT_PROVIDER_FALLBACK;
}

async function updateCallSessionById(callSessionId: string | undefined, data: {
  status?: string;
  providerCallId?: string;
  twilioCallSid?: string;
  sipParticipantId?: string;
  mediaBridgeStatus?: string | null;
  failureReason?: string | null;
  pstnLiveKitIdentity?: string | null;
  callerCallKitUUID?: string | null;
}): Promise<void> {
  if (!callSessionId) return;
  try {
    await prisma.callSession.update({
      where: { id: callSessionId },
      data,
    });
  } catch (error) {
    logger.warn({ err: error, callSessionId, data }, "[pstn] call session update by id failed");
  }
}

async function createAcceptedDisclosureSIPParticipant(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  callerUserId: string | null;
  roomName: string;
  toPhoneNumber: string;
  fromPhoneNumber?: string | null;
  providerCallId?: string;
  startedAt: number;
  source: "disclosure_accept" | "voice_webhook";
}): Promise<{
  ok: true;
  sipParticipantId: string;
  participantIdentity: string;
  providerCallId?: string;
} | {
  ok: false;
  reason: string;
}> {
  const existingBridge = await prisma.callSession.findUnique({
    where: { id: args.callSessionId },
    select: {
      providerCallId: true,
      sipParticipantId: true,
      mediaBridgeStatus: true,
    },
  }).catch(() => null);

  if (existingBridge?.sipParticipantId && existingBridge.mediaBridgeStatus !== "failed") {
    const participantIdentity = liveKitSIPParticipantIdentity(args.callSessionId);
    logCallLegTimeline("sip.participant.create.reused", {
      callSessionId: shortId(args.callSessionId),
      actorRole: "pstn_recipient",
      providerCallId: shortId(args.providerCallId ?? existingBridge.providerCallId ?? undefined),
      sipParticipantId: shortId(existingBridge.sipParticipantId),
      participantIdentity: shortId(participantIdentity),
      sourceFunction: args.source,
      reason: "existing_sip_participant",
    });
    return {
      ok: true,
      sipParticipantId: existingBridge.sipParticipantId,
      participantIdentity,
      providerCallId: args.providerCallId ?? existingBridge.providerCallId ?? undefined,
    };
  }

  if (!args.callerUserId) {
    const reason = "disclosure_accept_missing_caller_user";
    await updateCallSessionById(args.callSessionId, {
      providerCallId: args.providerCallId ?? existingBridge?.providerCallId ?? undefined,
      status: "failed",
      mediaBridgeStatus: "failed",
      failureReason: reason,
    });
    logger.error({
      callSessionId: shortId(args.callSessionId),
      providerCallId: shortId(args.providerCallId),
      source: args.source,
      reason,
    }, "[pstn] createSipParticipant skipped");
    return { ok: false, reason };
  }

  const bridgeInput = {
    callSessionId: args.callSessionId,
    roomName: args.roomName,
    userId: args.callerUserId,
    toPhoneNumber: args.toPhoneNumber,
    fromPhoneNumber: args.fromPhoneNumber ?? undefined,
    provider: "twilio" as const,
  };
  const diagnostics = args.bridgeService.diagnosticsForCreate(bridgeInput);

  logger.info({
    callSessionId: shortId(args.callSessionId),
    providerCallId: shortId(args.providerCallId ?? existingBridge?.providerCallId ?? undefined),
    roomName: shortId(args.roomName),
    source: args.source,
    diagnostics,
  }, "[pstn] disclosure accepted; calling createSipParticipant");

  const bridgeResult = await args.bridgeService.setupBridge(bridgeInput);

  if (bridgeResult.mediaBridgeStatus === "failed" || !bridgeResult.sipParticipantId) {
    const reason = bridgeResult.message ?? "createSipParticipant returned no SIP participant ID.";
    await updateCallSessionById(args.callSessionId, {
      providerCallId: args.providerCallId ?? existingBridge?.providerCallId ?? undefined,
      status: "failed",
      sipParticipantId: bridgeResult.sipParticipantId,
      mediaBridgeStatus: "failed",
      failureReason: reason,
    });
    logger.error({
      callSessionId: shortId(args.callSessionId),
      providerCallId: shortId(args.providerCallId ?? existingBridge?.providerCallId ?? undefined),
      roomName: shortId(args.roomName),
      source: args.source,
      diagnostics,
      bridgeResult: {
        mediaBridgeStatus: bridgeResult.mediaBridgeStatus,
        sipParticipantId: shortId(bridgeResult.sipParticipantId),
        participantIdentity: shortId(bridgeResult.participantIdentity),
        providerCallId: shortId(bridgeResult.providerCallId),
        message: redactSensitiveString(bridgeResult.message ?? ""),
      },
      reason,
    }, "[pstn] createSipParticipant failed or returned no participant");
    return { ok: false, reason };
  }

  const participantIdentity = bridgeResult.participantIdentity
    ?? liveKitSIPParticipantIdentity(args.callSessionId);

  await updateCallSessionById(args.callSessionId, {
    providerCallId: args.providerCallId ?? existingBridge?.providerCallId ?? undefined,
    status: "answered",
    sipParticipantId: bridgeResult.sipParticipantId,
    mediaBridgeStatus: "connecting",
    failureReason: null,
  });

  logger.info({
    callSessionId: shortId(args.callSessionId),
    providerCallId: shortId(args.providerCallId ?? existingBridge?.providerCallId ?? undefined),
    sipParticipantId: shortId(bridgeResult.sipParticipantId),
    participantIdentity: shortId(participantIdentity),
    roomName: shortId(args.roomName),
    source: args.source,
    latencyMs: Date.now() - args.startedAt,
  }, "[pstn] createSipParticipant succeeded; SIP watcher armed");

  startLiveKitSIPParticipantWatcher({
    bridgeService: args.bridgeService,
    callSessionId: args.callSessionId,
    roomName: args.roomName,
    participantIdentity,
    sipParticipantId: bridgeResult.sipParticipantId,
  });

  return {
    ok: true,
    sipParticipantId: bridgeResult.sipParticipantId,
    participantIdentity,
    providerCallId: args.providerCallId ?? existingBridge?.providerCallId ?? undefined,
  };
}

async function acceptDisclosureOnExistingTwilioLeg(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  callerUserId: string | null;
  roomName: string;
  toPhoneNumber: string;
  fromPhoneNumber?: string | null;
  providerCallId?: string;
  sourceFunction: "twilio.disclosure.accept" | "twilio.voice";
}): Promise<{
  ok: true;
  connectUrl: string;
  participantIdentity: string;
} | {
  ok: false;
  reason: string;
}> {
  if (!args.callerUserId) {
    const reason = "disclosure_accept_missing_caller_user";
    await updateCallSessionById(args.callSessionId, {
      providerCallId: args.providerCallId,
      status: "failed",
      mediaBridgeStatus: "failed",
      failureReason: reason,
    });
    return { ok: false, reason };
  }

  const redialBlockReason = await callerRedialBlockReason({
    userId: args.callerUserId,
    targetNumber: args.toPhoneNumber,
    selectedCallerNumber: args.fromPhoneNumber ?? undefined,
  });
  if (redialBlockReason) {
    await updateCallSessionById(args.callSessionId, {
      providerCallId: args.providerCallId,
      status: "failed",
      mediaBridgeStatus: "failed",
      failureReason: "CALLER_REDIAL_BLOCKED",
    });
    logger.warn({
      eventType: "CALLER_REDIAL_BLOCKED",
      callSessionId: shortId(args.callSessionId),
      actorRole: "oneway_user",
      targetUserId: shortId(args.callerUserId),
      normalizedTargetNumber: phoneLogHint(args.toPhoneNumber),
      existingCallKitUUID: null,
      event: "pstn_disclosure_accepted",
      sourceFunction: args.sourceFunction,
      reason: redialBlockReason,
    }, "[pstn] CALLER_REDIAL_BLOCKED");
    return { ok: false, reason: "CALLER_REDIAL_BLOCKED" };
  }

  const connector = await args.bridgeService.connectExistingTwilioLeg({
    callSessionId: args.callSessionId,
    roomName: args.roomName,
    providerCallId: args.providerCallId,
    toPhoneNumber: args.toPhoneNumber,
    fromPhoneNumber: args.fromPhoneNumber ?? undefined,
  });

  if (connector.mediaBridgeStatus === "failed" || !connector.connectUrl) {
    const reason = connector.message ?? "livekit_twilio_connector_failed";
    await updateCallSessionById(args.callSessionId, {
      providerCallId: args.providerCallId,
      twilioCallSid: asTwilioCallSid(args.providerCallId),
      status: "failed",
      mediaBridgeStatus: "failed",
      failureReason: reason,
    });
    return { ok: false, reason };
  }

  logCallLegTimeline("livekit.connector.participant.created", {
    callSessionId: shortId(args.callSessionId),
    actorRole: "pstn_recipient",
    providerCallId: shortId(args.providerCallId),
    roomName: shortId(args.roomName),
    participantIdentity: shortId(connector.participantIdentity),
    sourceFunction: args.sourceFunction,
    reason: "existing_twilio_leg_connector",
  });

  await updateCallSessionById(args.callSessionId, {
    providerCallId: args.providerCallId,
    twilioCallSid: asTwilioCallSid(args.providerCallId),
    status: "answered",
    mediaBridgeStatus: "connecting",
    pstnLiveKitIdentity: connector.participantIdentity,
    failureReason: null,
  });

  logCallLegTimeline("pstn_disclosure_accepted", {
    callSessionId: shortId(args.callSessionId),
    actorRole: "pstn_recipient",
    targetUserId: shortId(args.callerUserId),
    normalizedTargetNumber: phoneLogHint(args.toPhoneNumber),
    providerCallId: shortId(args.providerCallId),
    roomName: shortId(args.roomName),
    participantIdentity: shortId(connector.participantIdentity),
    event: "pstn_disclosure_accepted",
    sourceFunction: args.sourceFunction,
    reason: "recipient_accepted_prompt",
  }, "disclosure.accepted");

  logCallLegTimeline("pstn_bridge_connecting", {
    callSessionId: shortId(args.callSessionId),
    actorRole: "pstn_recipient",
    targetUserId: shortId(args.callerUserId),
    normalizedTargetNumber: phoneLogHint(args.toPhoneNumber),
    providerCallId: shortId(args.providerCallId),
    roomName: shortId(args.roomName),
    participantIdentity: shortId(connector.participantIdentity),
    event: "pstn_bridge_connecting",
    sourceFunction: args.sourceFunction,
    reason: "stream_existing_twilio_leg_to_livekit_connector",
  });

  startLiveKitSIPParticipantWatcher({
    bridgeService: args.bridgeService,
    callSessionId: args.callSessionId,
    roomName: args.roomName,
    participantIdentity: connector.participantIdentity,
    sipParticipantId: connector.participantIdentity,
  });

  return {
    ok: true,
    connectUrl: connector.connectUrl,
    participantIdentity: connector.participantIdentity,
  };
}

async function updateCallSessionByIdForProvider(
  callSessionId: string | undefined,
  provider: "twilio" | "telnyx" | "sinch",
  data: {
    status?: string;
    providerCallId?: string;
    twilioCallSid?: string;
    mediaBridgeStatus?: string | null;
    failureReason?: string | null;
  },
): Promise<void> {
  if (!callSessionId) return;
  try {
    await prisma.callSession.updateMany({
      where: { id: callSessionId, provider },
      data,
    });
  } catch (error) {
    logger.warn({ err: error, callSessionId, provider, data }, "[pstn] call session update by id/provider failed");
  }
}

async function updateCallSessionByProviderCallId(
  providerCallId: string | undefined,
  data: {
    status?: string;
    mediaBridgeStatus?: string | null;
    failureReason?: string | null;
  },
  provider?: "twilio" | "telnyx" | "sinch",
): Promise<void> {
  if (!providerCallId) return;
  try {
    await prisma.callSession.updateMany({
      where: {
        providerCallId,
        ...(provider ? { provider } : {}),
      },
      data,
    });
  } catch (error) {
    logger.warn({ err: error, providerCallId, provider, data }, "[pstn] call session update by providerCallId failed");
  }
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function decodeTelnyxClientState(value: unknown): string | undefined {
  const encoded = text(value);
  if (!encoded) return undefined;
  try {
    const decoded = Buffer.from(encoded, "base64").toString("utf8");
    const parsed = JSON.parse(decoded) as Record<string, unknown>;
    return text(parsed.callSessionId);
  } catch {
    return undefined;
  }
}

function pstnStatusMessage(status: string, failureReason: string | null | undefined): string | undefined {
  const normalized = status.trim().toLowerCase();
  if (normalized === "failed") return failureReason ?? "External network call failed.";
  if (normalized === "connected") return "External network call connected.";
  if (normalized === "answered") return "External network call connected.";
  if (normalized === "ended") return "External network call ended.";
  if (normalized === "ringing") return "External phone is ringing.";
  if (normalized === DISCLOSURE_WAITING_STATUS) return "Waiting for recipient to accept the OneWay call.";
  if (normalized === "initiated") return "Connecting to external network.";
  if (normalized === "starting") return "Starting external network setup.";
  return undefined;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function scheduleStubDisclosureAcceptance(callSessionId: string): void {
  const timer = setTimeout(() => {
    void updateCallSessionById(callSessionId, {
      status: "answered",
      mediaBridgeStatus: "not_configured",
      failureReason: null,
    });
  }, 1_000);
  timer.unref?.();
}

function timeoutSnapshot(args: {
  callSessionId: string;
  roomName: string;
  participantIdentity: string;
  timeoutMs: number;
}): Promise<LiveKitSIPParticipantSnapshot> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      resolve({
        found: false,
        connected: false,
        roomName: args.roomName,
        participantIdentity: args.participantIdentity,
        trackCount: 0,
        tracks: [],
        error: `participant_snapshot_timeout_${args.timeoutMs}ms`,
      });
    }, args.timeoutMs);
    timer.unref?.();
  });
}

async function participantSnapshotWithTimeout(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  roomName: string;
  participantIdentity: string;
  timeoutMs: number;
}): Promise<LiveKitSIPParticipantSnapshot> {
  return Promise.race([
    args.bridgeService.participantSnapshot(args.roomName, args.participantIdentity),
    timeoutSnapshot(args),
  ]);
}

function startLiveKitSIPParticipantWatcher(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  roomName: string;
  participantIdentity: string;
  sipParticipantId: string;
}): void {
  const watcherKey = `${args.callSessionId}:${args.participantIdentity}`;
  if (sipParticipantWatcherKeys.has(watcherKey)) {
    logger.info({
      callSessionId: shortId(args.callSessionId),
      sipParticipantId: shortId(args.sipParticipantId),
      participantIdentity: shortId(args.participantIdentity),
      reason: "duplicate_watcher",
  }, "[pstn] LiveKit bridge participant watcher reused");
    return;
  }
  sipParticipantWatcherKeys.add(watcherKey);

  const startPayload = {
    callSessionId: shortId(args.callSessionId),
    sipParticipantId: shortId(args.sipParticipantId),
    participantIdentity: shortId(args.participantIdentity),
    roomName: shortId(args.roomName),
  };

  console.log("[pstn] starting LiveKit bridge participant watcher", redactSensitiveObject(startPayload));
  logger.info(startPayload, "[pstn] starting LiveKit bridge participant watcher");

  void monitorLiveKitSIPParticipant(args)
    .catch(async (error) => {
      console.error("[pstn] LiveKit bridge participant watcher crashed", redactSensitiveObject({
        ...startPayload,
        error: error instanceof Error ? error.message : String(error),
      }));
      logger.error({
        err: error,
        ...startPayload,
      }, "[pstn] LiveKit bridge participant watcher crashed");
      await updateCallSessionById(args.callSessionId, {
        status: "failed",
        mediaBridgeStatus: "failed",
        failureReason: error instanceof Error ? error.message : "sip_readiness_watcher_crashed",
      });
    })
    .finally(() => {
      sipParticipantWatcherKeys.delete(watcherKey);
    });
}

async function monitorLiveKitSIPParticipant(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  roomName: string;
  participantIdentity: string;
  sipParticipantId?: string;
  timeoutMs?: number;
  intervalMs?: number;
  snapshotTimeoutMs?: number;
}): Promise<void> {
  const timeoutMs = args.timeoutMs ?? 15_000;
  const intervalMs = args.intervalMs ?? 1_000;
  const snapshotTimeoutMs = args.snapshotTimeoutMs ?? 4_000;
  const deadline = Date.now() + timeoutMs;
  let lastSnapshot: LiveKitSIPParticipantSnapshot | undefined;
  let pollCount = 0;

  while (Date.now() <= deadline) {
    pollCount += 1;
    console.log("[pstn] LiveKit bridge participant readiness poll", redactSensitiveObject({
      callSessionId: shortId(args.callSessionId),
      roomName: shortId(args.roomName),
      participantIdentity: shortId(args.participantIdentity),
      pollCount,
    }));

    const snapshot = await participantSnapshotWithTimeout({
      bridgeService: args.bridgeService,
      callSessionId: args.callSessionId,
      roomName: args.roomName,
      participantIdentity: args.participantIdentity,
      timeoutMs: snapshotTimeoutMs,
    });
    lastSnapshot = snapshot;

    logger.info({
      callSessionId: shortId(args.callSessionId),
      roomName: shortId(args.roomName),
      participantIdentity: shortId(args.participantIdentity),
      ...summarizeSIPSnapshot(snapshot),
    }, "[pstn] LiveKit bridge participant readiness poll");

    if (snapshot.connected) {
      await updateCallSessionById(args.callSessionId, {
        status: "connected",
        sipParticipantId: snapshot.sid ?? args.sipParticipantId,
        pstnLiveKitIdentity: snapshot.identity ?? snapshot.participantIdentity,
        mediaBridgeStatus: "connected",
        failureReason: null,
      });
      logger.info({
        callSessionId: shortId(args.callSessionId),
        roomName: shortId(args.roomName),
        participantIdentity: shortId(args.participantIdentity),
        ...summarizeSIPSnapshot(snapshot),
      }, "[pstn] LiveKit bridge participant connected");
      return;
    }

    await sleep(intervalMs);
  }

  logger.warn({
    callSessionId: shortId(args.callSessionId),
    roomName: shortId(args.roomName),
    participantIdentity: shortId(args.participantIdentity),
    timeoutMs,
    lastSnapshot: summarizeSIPSnapshot(lastSnapshot),
  }, "[pstn] LiveKit bridge participant readiness timeout");

  await updateCallSessionById(args.callSessionId, {
    status: "failed",
    mediaBridgeStatus: "failed",
    failureReason: lastSnapshot?.error
      ? `sip_readiness_timeout: ${lastSnapshot.error}`
    : "sip_readiness_timeout",
  });
}

function startTwilioDialSIPParticipantWatcher(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  roomName: string;
  providerCallId?: string;
  sourceFunction: string;
}): void {
  const watcherKey = `${args.callSessionId}:${args.providerCallId ?? "provider_pending"}`;
  if (twilioDialSIPWatcherKeys.has(watcherKey)) {
    logger.info({
      callSessionId: shortId(args.callSessionId),
      providerCallId: shortId(args.providerCallId),
      sourceFunction: args.sourceFunction,
      reason: "duplicate_watcher",
    }, "[pstn] Twilio Dial SIP watcher reused");
    return;
  }
  twilioDialSIPWatcherKeys.add(watcherKey);

  logCallLegTimeline("sip.participant.create.requested", {
    callSessionId: shortId(args.callSessionId),
    actorRole: "pstn_recipient",
    providerCallId: shortId(args.providerCallId),
    roomName: shortId(args.roomName),
    sourceFunction: args.sourceFunction,
    reason: "twilio_existing_leg_dial_sip",
  });

  void monitorTwilioDialSIPParticipant(args)
    .catch(async (error) => {
      logger.error({
        err: error,
        callSessionId: shortId(args.callSessionId),
        providerCallId: shortId(args.providerCallId),
        roomName: shortId(args.roomName),
        sourceFunction: args.sourceFunction,
      }, "[pstn] Twilio Dial SIP watcher crashed");
      await updateCallSessionById(args.callSessionId, {
        status: "failed",
        mediaBridgeStatus: "failed",
        failureReason: error instanceof Error ? error.message : "twilio_dial_sip_watcher_crashed",
      });
    })
    .finally(() => {
      twilioDialSIPWatcherKeys.delete(watcherKey);
    });
}

async function monitorTwilioDialSIPParticipant(args: {
  bridgeService: LiveKitSIPBridgeService;
  callSessionId: string;
  roomName: string;
  providerCallId?: string;
  sourceFunction: string;
  timeoutMs?: number;
  intervalMs?: number;
}): Promise<void> {
  const timeoutMs = args.timeoutMs ?? 25_000;
  const intervalMs = args.intervalMs ?? 1_000;
  const deadline = Date.now() + timeoutMs;
  let lastSnapshot: LiveKitSIPParticipantSnapshot | undefined;
  let didPersistParticipant = false;

  while (Date.now() <= deadline) {
    const snapshot = await args.bridgeService.findSIPParticipantForTwilioLeg({
      roomName: args.roomName,
      callSessionId: args.callSessionId,
      providerCallId: args.providerCallId,
    });
    lastSnapshot = snapshot;

    logger.info({
      callSessionId: shortId(args.callSessionId),
      providerCallId: shortId(args.providerCallId),
      roomName: shortId(args.roomName),
      sourceFunction: args.sourceFunction,
      ...summarizeSIPSnapshot(snapshot),
    }, "[pstn] Twilio Dial SIP participant readiness poll");

    if (snapshot.found && snapshot.sid && !didPersistParticipant) {
      didPersistParticipant = true;
      await updateCallSessionById(args.callSessionId, {
        status: "answered",
        sipParticipantId: snapshot.sid,
        pstnLiveKitIdentity: snapshot.identity ?? snapshot.participantIdentity,
        mediaBridgeStatus: "connecting",
        failureReason: null,
      });
      logCallLegTimeline("sip.participant.joined", {
        callSessionId: shortId(args.callSessionId),
        actorRole: "pstn_recipient",
        providerCallId: shortId(args.providerCallId),
        sipParticipantId: shortId(snapshot.sid),
        participantIdentity: shortId(snapshot.identity ?? snapshot.participantIdentity),
        sourceFunction: args.sourceFunction,
        reason: "twilio_existing_leg_joined_room",
      });
    }

    if (snapshot.connected) {
      await updateCallSessionById(args.callSessionId, {
        status: "connected",
        sipParticipantId: snapshot.sid,
        pstnLiveKitIdentity: snapshot.identity ?? snapshot.participantIdentity,
        mediaBridgeStatus: "connected",
        failureReason: null,
      });
      logCallLegTimeline("bridge.connected", {
        callSessionId: shortId(args.callSessionId),
        actorRole: "pstn_recipient",
        providerCallId: shortId(args.providerCallId),
        sipParticipantId: shortId(snapshot.sid),
        participantIdentity: shortId(snapshot.identity ?? snapshot.participantIdentity),
        sourceFunction: args.sourceFunction,
        reason: "twilio_existing_leg_media_connected",
      });
      return;
    }

    await sleep(intervalMs);
  }

  logger.warn({
    callSessionId: shortId(args.callSessionId),
    providerCallId: shortId(args.providerCallId),
    roomName: shortId(args.roomName),
    timeoutMs,
    sourceFunction: args.sourceFunction,
    lastSnapshot: summarizeSIPSnapshot(lastSnapshot),
  }, "[pstn] Twilio Dial SIP participant readiness timeout");

  await updateCallSessionById(args.callSessionId, {
    status: "failed",
    mediaBridgeStatus: "failed",
    failureReason: lastSnapshot?.error
      ? `twilio_dial_sip_readiness_timeout: ${lastSnapshot.error}`
      : "twilio_dial_sip_readiness_timeout",
  });
}

function summarizeSIPSnapshot(snapshot: LiveKitSIPParticipantSnapshot | undefined): Record<string, unknown> {
  if (!snapshot) return {};
  return {
    found: snapshot.found,
    connected: snapshot.connected,
    state: snapshot.state,
    stateName: snapshot.stateName,
    kind: snapshot.kind,
    kindName: snapshot.kindName,
    tracks: snapshot.trackCount,
    hasMetadata: Boolean(snapshot.metadata),
    attributeKeys: snapshot.attributes && typeof snapshot.attributes === "object"
      ? Object.keys(snapshot.attributes).slice(0, 12)
      : [],
    isPublisher: snapshot.isPublisher,
    disconnectReason: redactSensitiveString(String(snapshot.disconnectReason ?? "")),
    error: redactSensitiveString(snapshot.error ?? ""),
  };
}

interface PSTNRouterDeps {
  provider: PSTNProvider;
  livekit: LiveKitTokenService;
  isUserConnected?: (userId: string) => boolean;
  hasPushToken?: (userId: string) => Promise<boolean>;
  isUserBusy?: (userId: string) => boolean;
  startInboundAppCall?: (args: InboundAppCallStartArgs) => Promise<InboundAppCallStartResult | undefined>;
}

export function pstnRouter(deps: PSTNRouterDeps): express.Router {
  const { provider, livekit } = deps;
  const router = express.Router();
  const sipBridgeUriTemplate = process.env.PSTN_SIP_BRIDGE_URI_TEMPLATE?.trim() ?? "";
  const bridgeService = new LiveKitSIPBridgeService(livekit);
  const defaultFromNumber = text(process.env.PSTN_FROM_NUMBER);
  const startupPublicWebhookBaseUrl = publicWebhookBaseUrl();

  logger.info({
    iosDebugApiBaseUrl: envValue("IOS_API_BASE_URL") || envValue("API_BASE_URL") || "not_set",
    publicWebhookBaseUrl: startupPublicWebhookBaseUrl,
    twilioDisclosureUrl: `${startupPublicWebhookBaseUrl}/api/pstn/twilio/voice?stage=disclosure`,
    twilioDisclosureAcceptUrl: `${startupPublicWebhookBaseUrl}/api/pstn/twilio/disclosure/accept`,
    twilioDisclosureTimeoutUrl: `${startupPublicWebhookBaseUrl}/api/pstn/twilio/disclosure/timeout`,
    twilioStatusCallbackUrl: `${startupPublicWebhookBaseUrl}/api/pstn/twilio/status`,
    publicWebhookUrlIsValid: isPublicHttpsWebhookUrl(startupPublicWebhookBaseUrl),
  }, "[pstn] public webhook configuration");

  async function recipientAvailability(userId: string): Promise<InboundRecipientAvailability> {
    if (deps.isUserBusy?.(userId)) return "busy";
    const [hasActiveSocket, hasRegisteredPush] = await Promise.all([
      Promise.resolve(deps.isUserConnected?.(userId) ?? false),
      deps.hasPushToken?.(userId) ?? Promise.resolve(false),
    ]);
    return hasActiveSocket || hasRegisteredPush ? "available" : "offline";
  }

  function sendTwiml(res: express.Response, inner: string): void {
    res.type("text/xml").status(200).send(xmlResponse(inner));
  }

  function sendTwilioTwiML(
    req: express.Request,
    res: express.Response,
    inner: string,
    args: {
      callSessionId?: string;
      providerCallId?: string;
      stage: string;
      startedAt: number;
      reason?: string;
    },
  ): void {
    let twiml = xmlResponse(inner);
    let validation = validateTwiML(twiml);
    if (!validation.ok) {
      logger.error({
        callSessionId: shortId(args.callSessionId),
        providerCallId: shortId(args.providerCallId),
        stage: args.stage,
        reason: validation.reason,
        twimlPreview: twilioBodyPreview(twiml),
      }, "[pstn] invalid twiml generated");
      setLastTwilioFailure({
        callSid: args.providerCallId,
        errorCode: "invalid_twiml_generated",
        errorMessage: validation.reason,
        failingUrl: fullRequestUrl(req),
        requestMethod: req.method,
        responseStatus: 200,
        responseContentType: "text/xml",
        responseBodyPreview: twiml,
        webhookLatencyMs: Date.now() - args.startedAt,
      });
      twiml = xmlResponse(sayXml("We could not connect your call. Please try again.") + hangupXml());
      validation = validateTwiML(twiml);
    }
    logger.info({
      callSessionId: shortId(args.callSessionId),
      providerCallId: shortId(args.providerCallId),
      stage: args.stage,
      latencyMs: Date.now() - args.startedAt,
      twimlBytes: Buffer.byteLength(twiml),
      reason: args.reason,
      twimlValid: validation.ok,
      requestUrl: fullRequestUrl(req),
    }, "[pstn] twilio twiml returned");
    res.type("text/xml").status(200).send(twiml);
  }

  function sendTwilioFailureTwiML(
    req: express.Request,
    res: express.Response,
    args: {
      callSessionId?: string;
      providerCallId?: string;
      stage: string;
      startedAt: number;
      reason: string;
    },
  ): void {
    sendTwilioTwiML(
      req,
      res,
      sayXml("This OneWay call cannot be connected right now. Please try again later.") + hangupXml(),
      args,
    );
  }

  function sendUnavailableTwiML(res: express.Response, context: InboundVoiceContext): void {
    const choiceUrl = twilioVoiceActionUrl("unavailable-choice", {
      from: context.fromNumber,
      to: context.toNumber,
      CallSid: context.providerCallId,
    });
    sendTwiml(
      res,
      `<Gather input="dtmf" numDigits="1" timeout="8" action="${safeValue(choiceUrl)}" method="POST">`
        + sayXml(`${buildUnavailablePrompt(context.recipient.displayName)} Press 1 for a voice message, or 2 to send a text message.`)
        + "</Gather>"
        + sayXml("No problem. Goodbye.")
        + hangupXml(),
    );
  }

  async function connectInboundCaller(
    res: express.Response,
    context: InboundVoiceContext,
  ): Promise<void> {
    const existingSession = await findInboundCallSession(context.providerCallId);
    let roomName = existingSession?.roomName;
    let callSessionId = existingSession?.id;
    const callerId = context.caller.userId
      ?? syntheticInboundCallerId(context.fromNumber, context.providerCallId);
    const recipientAnnouncement = buildRecipientAnnouncement(context);

    if (!sipBridgeUriTemplate) {
      logger.warn({
        provider: "twilio",
        providerCallId: shortId(context.providerCallId),
        recipientUserId: shortId(context.recipient.userId),
        callerUserId: shortId(context.caller.userId),
        trust: context.caller.trust,
      }, "[pstn] inbound SIP bridge target not configured");
      sendTwiml(res, sayXml("We cannot connect this OneWay call right now. Please try again later.") + hangupXml());
      return;
    }

    if (!roomName) {
      const appCall = await deps.startInboundAppCall?.({
        callerId,
        calleeId: context.recipient.userId,
        callerDisplayName: recipientAnnouncement,
        callerName: context.caller.displayName ?? "OneWay Caller",
        callerNumber: context.fromNumber,
        introduction: context.introduction,
        trusted: context.caller.trust === "trusted",
      });

      if (!appCall) {
        logger.warn({
          provider: "twilio",
          providerCallId: shortId(context.providerCallId),
          recipientUserId: shortId(context.recipient.userId),
          callerUserId: shortId(context.caller.userId),
          trust: context.caller.trust,
        }, "[pstn] inbound app call hook unavailable");
        sendTwiml(res, sayXml("We cannot connect this OneWay call right now. Please try again later.") + hangupXml());
        return;
      }

      roomName = appCall.roomName;
      const session = await createInboundCallSession({
        roomName,
        context,
        callerId,
      });
      callSessionId = session.id;
    }

    const sipUri = sipUriForRoom({
      template: sipBridgeUriTemplate,
      roomName,
      callSessionId: callSessionId ?? "",
      toPhoneNumber: context.toNumber,
    });

    if (!sipUri) {
      await updateCallSessionById(callSessionId, {
        status: "failed",
        mediaBridgeStatus: "failed",
        failureReason: "inbound_missing_bridge_target",
      });
      logger.warn({
        callSessionId: shortId(callSessionId),
        provider: "twilio",
        recipientUserId: shortId(context.recipient.userId),
        callerUserId: shortId(context.caller.userId),
        trust: context.caller.trust,
      }, "[pstn] inbound missing SIP bridge target");
      sendTwiml(res, sayXml("We cannot connect this OneWay call right now. Please try again later.") + hangupXml());
      return;
    }

    await updateCallSessionById(callSessionId, {
      status: "ringing",
      providerCallId: context.providerCallId,
      mediaBridgeStatus: "connecting",
      failureReason: null,
    });

    logger.info({
      callSessionId: shortId(callSessionId),
      provider: "twilio",
      providerCallId: shortId(context.providerCallId),
      recipientUserId: shortId(context.recipient.userId),
      callerUserId: shortId(context.caller.userId),
      trust: context.caller.trust,
      trustReasons: context.caller.trustReasons,
      availability: context.availability,
      hasIntroduction: Boolean(context.introduction),
      hasBridgeTarget: true,
    }, "[pstn] inbound connecting to OneWay room");

    sendTwiml(
      res,
      sayXml(buildConnectLeadIn(context.caller.trust))
        + `<Dial answerOnBridge="true"><Sip>${safeValue(sipUri)}</Sip></Dial>`,
    );
  }

  async function handleInboundTwilioVoice(
    req: express.Request,
    res: express.Response,
    args: {
      providerCallId?: string;
      providerStatus?: string;
      digits?: string;
    },
  ): Promise<boolean> {
    const stage = text(req.query.stage) ?? text(req.body?.stage) ?? "start";
    const fromRaw = text(req.body?.From) ?? text(req.query.From) ?? text(req.query.from);
    const toRaw = text(req.body?.To) ?? text(req.query.To) ?? text(req.query.to);
    const toNumber = normalizeOptionalPhoneNumber(toRaw);
    if (!toNumber) return false;

    const recipient = await resolveOwnedNumberProfile(toRaw);
    if (!recipient) return false;

    const fromNumber = normalizeOptionalPhoneNumber(fromRaw);
    const caller = await resolveInboundCallerProfile(recipient.userId, fromNumber);
    const availability = await recipientAvailability(recipient.userId);
    const introduction = sanitizeSpokenText(
      text(req.body?.SpeechResult) ?? text(req.query.introduction),
      96,
    );
    const context: InboundVoiceContext = {
      recipient,
      caller,
      fromNumber,
      toNumber,
      providerCallId: args.providerCallId,
      introduction,
      availability,
    };

    logger.info({
      provider: "twilio",
      providerCallId: shortId(args.providerCallId),
      providerStatus: args.providerStatus,
      stage,
      from: phoneLogHint(fromNumber),
      to: phoneLogHint(toNumber),
      recipientUserId: shortId(recipient.userId),
      callerUserId: shortId(caller.userId),
      trust: caller.trust,
      trustReasons: caller.trustReasons,
      availability,
      hasIntroduction: Boolean(introduction),
    }, "[pstn] inbound voice webhook");

    if (stage === "unavailable-choice") {
      if (args.digits === "1") {
        const doneUrl = twilioVoiceActionUrl("voice-message-done", {
          from: context.fromNumber,
          to: context.toNumber,
          CallSid: context.providerCallId,
        });
        sendTwiml(
          res,
          sayXml("Please leave your message after the tone.")
            + `<Record maxLength="120" playBeep="true" action="${safeValue(doneUrl)}" method="POST"/>`
            + sayXml("Thanks. Goodbye.")
            + hangupXml(),
        );
        return true;
      }
      if (args.digits === "2") {
        sendTwiml(res, sayXml("Please send a text message to this OneWay number. Goodbye.") + hangupXml());
        return true;
      }
      sendTwiml(res, sayXml("No problem. Goodbye.") + hangupXml());
      return true;
    }

    if (stage === "voice-message-done") {
      sendTwiml(res, sayXml("Thanks. Goodbye.") + hangupXml());
      return true;
    }

    if (availability !== "available") {
      sendUnavailableTwiML(res, context);
      return true;
    }

    if (caller.trust === "trusted") {
      await connectInboundCaller(res, context);
      return true;
    }

    if (stage !== "introduction") {
      const actionUrl = twilioVoiceActionUrl("introduction", {
        from: context.fromNumber,
        to: context.toNumber,
        CallSid: context.providerCallId,
      });
      sendTwiml(
        res,
        `<Gather input="speech" timeout="5" speechTimeout="auto" action="${safeValue(actionUrl)}" method="POST">`
          + sayXml("Please tell them who is calling.")
          + "</Gather>"
          + sayXml("Thanks. One moment while I try to connect you.")
          + `<Redirect method="POST">${safeValue(actionUrl)}</Redirect>`,
      );
      return true;
    }

    await connectInboundCaller(res, context);
    return true;
  }

  router.get("/health", (_req, res) => {
    const preflight = evaluatePSTNPreflight(provider.name);
    const twilioValidation = provider.name === "twilio" ? validateTwilioProductionEnvironment() : null;
    res.status(200).json({
      ok: preflight.ok && (twilioValidation?.ok ?? true),
      provider: preflight.provider,
      webhookBaseUrl: envValue("PSTN_WEBHOOK_BASE_URL"),
      mediaBridgeEnabled: preflight.mediaBridgeEnabled,
      twilioWebhookValidationConfigured: twilioValidation
        ? !twilioValidation.missing.includes("TWILIO_AUTH_TOKEN")
        : undefined,
    });
  });

  router.get("/preflight", authMiddleware, async (_req, res) => {
    const preflight = evaluatePSTNPreflight(provider.name);
    const twilioValidation = provider.name === "twilio" ? validateTwilioProductionEnvironment() : null;
    res.status(preflight.ok && (twilioValidation?.ok ?? true) ? 200 : 503).json({
      ...preflight,
      twilio: twilioValidation,
    });
  });

  router.post("/calls/start", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;

    const preflight = evaluatePSTNPreflight(provider.name);
    if (provider.name !== "stub" && !preflight.ok) {
      res.status(503).json({
        error: "pstn_preflight_failed",
        message: "OneWay Bridge is not ready.",
        missing: preflight.missing,
        warnings: preflight.warnings,
      });
      return;
    }

    if (!consumeRateLimit(userId)) {
      res.status(429).json({
        error: "pstn_rate_limited",
        message: "Too many external call attempts. Try again later.",
      });
      return;
    }

    const parsed = startCallSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const idempotencyKey = text(parsed.data.idempotencyKey);
    const callerCallKitUUID = text(parsed.data.callerCallKitUUID)?.toLowerCase();
    const idempotencyCacheKey = idempotencyKey ? `${userId}:${idempotencyKey}` : "";
    if (idempotencyCacheKey) {
      const cached = pstnStartIdempotency.get(idempotencyCacheKey);
      if (cached && cached.expiresAt > Date.now()) {
        logger.info({ userId: shortId(userId), idempotencyKey: shortId(idempotencyKey) }, "[pstn] calls/start idempotent replay");
        res.status(200).json(cached.payload);
        return;
      }
      if (cached) pstnStartIdempotency.delete(idempotencyCacheKey);
    }

    const normalizedTo = normalizePhoneNumber(parsed.data.toPhoneNumber);
    if (isObviouslyInvalidPhone(normalizedTo)) {
      res.status(400).json({
        error: "invalid_phone_number",
        message: "Enter a valid external phone number.",
      });
      return;
    }

    const fromOneWayNumber = text(parsed.data.fromOneWayNumber);
    const fromNumberForDial = normalizeOptionalPhoneNumber(fromOneWayNumber)
      ?? normalizeOptionalPhoneNumber(defaultFromNumber);
    const redialBlockReason = await callerRedialBlockReason({
      userId,
      targetNumber: normalizedTo,
      selectedCallerNumber: fromOneWayNumber,
    });
    if (redialBlockReason) {
      logger.warn({
        eventType: "CALLER_REDIAL_BLOCKED",
        actorRole: "oneway_user",
        targetUserId: shortId(userId),
        normalizedTargetNumber: phoneLogHint(normalizedTo),
        existingCallKitUUID: shortId(callerCallKitUUID),
        event: "pstn_call_started",
        sourceFunction: "pstn.calls.start",
        reason: redialBlockReason,
      }, "[pstn] CALLER_REDIAL_BLOCKED");
      res.status(409).json({
        error: "caller_redial_blocked",
        message: "OneWay will not place an external bridge call to your own OneWay number.",
      });
      return;
    }

    const disclosure = pstnDisclosureConfig();
    const callerDisplayName = await loadCallerDisclosureDisplayName(userId);
    const disclosurePrompt = buildDisclosurePrompt(disclosure, callerDisplayName);

    logger.info({
      userId: shortId(userId),
      provider: provider.name,
      disclosureEnabled: disclosure.enabled,
      requireAccept: disclosure.requireAccept,
      hasCallerDisplayName: Boolean(callerDisplayName),
    }, "[pstn] outbound call attempt");

    console.log("📞 PSTN live readiness", {
      provider: preflight.provider,
      liveKitConfigured: preflight.liveKitConfigured,
      sipTrunkConfigured: preflight.sipTrunkConfigured,
      providerConfigured: preflight.providerConfigured,
      webhookBaseUrlConfigured: preflight.webhookBaseUrlConfigured,
      mediaBridgeEnabled: preflight.mediaBridgeEnabled,
      disclosureEnabled: disclosure.enabled,
      requireAccept: disclosure.requireAccept,
    });

    const callSessionId = randomUUID();
    const callSession = await prisma.callSession.create({
      data: {
        id: callSessionId,
        roomName: `pstn-${callSessionId}`,
        callerUserId: userId,
        calleeUserId: `pstn:${normalizedTo}`,
        callerRole: "oneway_user",
        calleeRole: "pstn_recipient",
        fromNumber: fromNumberForDial ?? fromOneWayNumber,
        toNumber: normalizedTo,
        externalPhoneNumber: normalizedTo,
        callerOneWayNumber: fromOneWayNumber,
        destinationNumber: normalizedTo,
        callerLiveKitIdentity: userId,
        callerCallKitUUID,
        networkType: "pstnBridge",
        provider: provider.name,
        status: "starting",
        mediaBridgeStatus: "connecting",
      },
    });

    logger.info({
      callSessionId: shortId(callSessionId),
      roomName: shortId(callSession.roomName),
      status: "starting",
      disclosureEnabled: disclosure.enabled,
      requireAccept: disclosure.requireAccept,
    }, "[pstn] call session stored");
    logCallLegTimeline("call.session.created", {
      callSessionId: shortId(callSessionId),
      actorRole: "oneway_user",
      targetUserId: shortId(userId),
      normalizedTargetNumber: phoneLogHint(normalizedTo),
      callerRole: "oneway_user",
      calleeRole: "pstn_recipient",
      roomName: shortId(callSession.roomName),
      existingCallKitUUID: shortId(callerCallKitUUID),
      sourceFunction: "pstn.calls.start",
      reason: "outbound_pstn_requested",
    });

    let bridgeResult: {
      roomName: string;
      liveKitUrl?: string;
      token?: string;
      sipParticipantId?: string;
      participantIdentity?: string;
      providerCallId?: string;
      mediaBridgeStatus: MediaBridgeStatus;
      message?: string;
    };

    try {
      if (disclosure.enabled) {
        if (provider.name === "stub") {
          bridgeResult = {
            roomName: callSession.roomName,
            mediaBridgeStatus: "not_configured",
            message: "Stub provider in use. No external network call was placed.",
          };
        } else {
          const preparedRoom = await bridgeService.prepareCallerRoom({
            callSessionId,
            roomName: callSession.roomName,
            userId,
          });
          bridgeResult = {
            roomName: preparedRoom.roomName,
            liveKitUrl: preparedRoom.liveKitUrl,
            token: preparedRoom.token,
            mediaBridgeStatus: preparedRoom.mediaBridgeStatus,
            message: preparedRoom.message,
          };
        }
      } else {
        bridgeResult = await bridgeService.setupBridge({
          callSessionId,
          roomName: callSession.roomName,
          userId,
          toPhoneNumber: normalizedTo,
          fromPhoneNumber: fromNumberForDial,
          provider: provider.name,
        });
      }
    } catch (error) {
      logger.error({
        err: error,
        callSessionId: shortId(callSessionId),
        userId: shortId(userId),
        provider: provider.name,
        disclosureEnabled: disclosure.enabled,
        requireAccept: disclosure.requireAccept,
      }, "[pstn] livekit bridge setup failed");
      bridgeResult = {
        roomName: callSession.roomName,
        mediaBridgeStatus: "failed",
        message: error instanceof Error
          ? `LiveKit bridge setup failed: ${error.message}`
          : "LiveKit bridge setup failed.",
      };
    }

    let result: {
      providerCallId: string;
      status: "initiated" | "waiting_for_callee_acceptance" | "accepted" | "failed";
      provider: string;
      message?: string;
      calleeDisclosure?: {
        enabled: boolean;
        requireAccept: boolean;
        accepted: boolean;
        status: "disabled" | "waiting_for_callee_acceptance" | "accepted" | "declined" | "failed";
      };
    } = {
      providerCallId: bridgeResult.providerCallId ?? `bridge_pending_${randomUUID()}`,
      status: bridgeResult.mediaBridgeStatus === "failed" ? "failed" as const : "initiated" as const,
      provider: provider.name,
      message: bridgeResult.message,
    };

    // Primary path: LiveKit SIP participant owns PSTN dialing.
    const liveKitBridgeUnavailable = !bridgeResult.providerCallId
      || bridgeResult.mediaBridgeStatus === "failed"
      || bridgeResult.mediaBridgeStatus === "not_configured";

    if (disclosure.enabled) {
      if (bridgeResult.mediaBridgeStatus === "failed") {
        result = {
          providerCallId: bridgeResult.providerCallId ?? `bridge_failed_${randomUUID()}`,
          status: "failed",
          provider: provider.name,
          message: bridgeResult.message ?? "LiveKit room setup failed before disclosure.",
          calleeDisclosure: calleeDisclosurePayload({
            enabled: true,
            requireAccept: disclosure.requireAccept,
            status: "failed",
            failureReason: bridgeResult.message,
          }),
        };
        } else {
          logCallLegTimeline("twilio.recipient.call.create.attempt", {
            callSessionId: shortId(callSessionId),
            actorRole: "pstn_recipient",
            targetUserId: `pstn:${phoneLogHint(normalizedTo)}`,
            normalizedTargetNumber: phoneLogHint(normalizedTo),
            roomName: shortId(callSession.roomName),
            sourceFunction: "pstn.calls.start",
            reason: "disclosure_call_to_external_destination",
          });
          const providerResult = await provider.startOutboundCall({
            fromUserId: userId,
            fromOneWayNumber,
          toPhoneNumber: normalizedTo,
          callSessionId,
          roomName: callSession.roomName,
          callerDisplayName,
          disclosurePrompt,
          calleeDisclosure: {
            enabled: true,
            requireAccept: disclosure.requireAccept,
            brand: disclosure.brand,
            callbackUrl: publicWebhookBaseUrl(),
          },
          bridgeTarget: {
            roomName: callSession.roomName,
            liveKitRoomName: callSession.roomName,
            sipUri: sipBridgeUriTemplate
              ? applyTemplate(sipBridgeUriTemplate, {
                  callSessionId,
                  roomName: callSession.roomName,
                  toPhoneNumber: normalizedTo,
                }).trim()
              : undefined,
          },
        });
        result = {
          providerCallId: providerResult.providerCallId,
          status: providerResult.status,
          provider: providerResult.provider,
          message: providerResult.message,
          calleeDisclosure: providerResult.calleeDisclosure,
        };
        logCallLegTimeline("twilio.recipient.call.created", {
          callSessionId: shortId(callSessionId),
          actorRole: "pstn_recipient",
          providerCallId: shortId(providerResult.providerCallId),
          targetUserId: `pstn:${phoneLogHint(normalizedTo)}`,
          normalizedTargetNumber: phoneLogHint(normalizedTo),
          roomName: shortId(callSession.roomName),
          sourceFunction: "pstn.calls.start",
          reason: providerResult.status,
        });

        if (provider.name === "stub" && providerResult.status === DISCLOSURE_WAITING_STATUS) {
          scheduleStubDisclosureAcceptance(callSession.id);
        }
      }
    } else if (liveKitBridgeUnavailable) {
      if (shouldAttemptProviderFallback(provider.name)) {
        logCallLegTimeline("twilio.recipient.call.create.attempt", {
          callSessionId: shortId(callSessionId),
          actorRole: "pstn_recipient",
          targetUserId: `pstn:${phoneLogHint(normalizedTo)}`,
          normalizedTargetNumber: phoneLogHint(normalizedTo),
          roomName: shortId(callSession.roomName),
          sourceFunction: "pstn.calls.start.fallback",
          reason: "direct_provider_fallback_external_destination",
        });
        const fallbackResult = await provider.startOutboundCall({
          fromUserId: userId,
          fromOneWayNumber,
          toPhoneNumber: normalizedTo,
          callSessionId,
          roomName: callSession.roomName,
        });
        result = {
          providerCallId: fallbackResult.providerCallId,
          status: fallbackResult.status,
          provider: fallbackResult.provider,
          message: fallbackResult.message,
        };
        logCallLegTimeline("twilio.recipient.call.created", {
          callSessionId: shortId(callSessionId),
          actorRole: "pstn_recipient",
          providerCallId: shortId(fallbackResult.providerCallId),
          targetUserId: `pstn:${phoneLogHint(normalizedTo)}`,
          normalizedTargetNumber: phoneLogHint(normalizedTo),
          roomName: shortId(callSession.roomName),
          sourceFunction: "pstn.calls.start.fallback",
          reason: fallbackResult.status,
        });
      } else {
        result = {
          providerCallId: bridgeResult.providerCallId ?? `bridge_failed_${randomUUID()}`,
          status: "failed",
          provider: provider.name,
          message: bridgeResult.message
            ?? "LiveKit SIP bridge setup failed. Direct provider fallback is disabled.",
        };
      }
    }

    if (bridgeResult.sipParticipantId) {
      logger.info({
        callSessionId: shortId(callSessionId),
        roomName: shortId(callSession.roomName),
        sipParticipantId: shortId(bridgeResult.sipParticipantId),
        participantIdentity: shortId(bridgeResult.participantIdentity ?? liveKitSIPParticipantIdentity(callSessionId)),
        providerCallId: shortId(bridgeResult.providerCallId),
      }, "[pstn] LiveKit SIP dispatch created");
    }

    const mediaBridgeStatus: MediaBridgeStatus = bridgeResult.mediaBridgeStatus === "not_configured"
      ? "not_configured"
      : bridgeResult.mediaBridgeStatus === "failed"
        ? "failed"
        : "connecting";

    let responseMessage = result.message ?? bridgeResult.message;
    if (result.status === "initiated" && mediaBridgeStatus === "failed") {
      responseMessage = "Phone leg started, but OneWay audio bridge failed.";
    }
    if (result.status === "initiated" && mediaBridgeStatus === "not_configured") {
      responseMessage = "OneWay Bridge test mode. Add provider credentials.";
    }
    if (!responseMessage && result.status === "initiated" && mediaBridgeStatus === "connecting") {
      responseMessage = "Connecting to external network.";
    }

    const providerStatus = mapProviderStatusToCallStatus(result.status);
    const twilioCallSid = result.provider === "twilio" ? asTwilioCallSid(result.providerCallId) : undefined;
    await updateCallSessionById(callSession.id, {
      status: providerStatus,
      providerCallId: result.providerCallId,
      twilioCallSid,
      sipParticipantId: bridgeResult.sipParticipantId,
      mediaBridgeStatus,
      failureReason: result.status === "failed" ? result.message ?? "provider_failed" : null,
    });

    const participantIdentity = bridgeResult.participantIdentity
      ?? (bridgeResult.sipParticipantId ? liveKitSIPParticipantIdentity(callSession.id) : undefined);

    if (participantIdentity && bridgeResult.sipParticipantId && mediaBridgeStatus === "connecting") {
      startLiveKitSIPParticipantWatcher({
        bridgeService,
        callSessionId: callSession.id,
        roomName: callSession.roomName,
        participantIdentity,
        sipParticipantId: bridgeResult.sipParticipantId,
      });
    } else {
      logger.warn({
        callSessionId: shortId(callSession.id),
        roomName: shortId(callSession.roomName),
        mediaBridgeStatus,
        sipParticipantId: shortId(bridgeResult.sipParticipantId),
        participantIdentity: shortId(participantIdentity),
      }, "[pstn] SIP readiness watcher skipped");
    }

    const payload = {
      callSessionId: callSession.id,
      roomName: callSession.roomName,
      networkType: "pstnBridge",
      provider: result.provider,
      status: providerStatus,
      providerCallId: result.providerCallId,
      sipParticipantId: bridgeResult.sipParticipantId,
      participantIdentity,
      liveKitUrl: bridgeResult.liveKitUrl,
      token: bridgeResult.token,
      participantToken: bridgeResult.token,
      mediaBridgeStatus,
      message: responseMessage,
      calleeDisclosure: result.calleeDisclosure ?? calleeDisclosurePayload({
        enabled: disclosure.enabled,
        requireAccept: disclosure.requireAccept,
        status: providerStatus,
        failureReason: result.status === "failed" ? result.message : null,
      }),
    };

    if (result.status === "failed") {
      const failurePayload = {
        error: "pstn_provider_unavailable",
        ...payload,
      };
      if (idempotencyCacheKey) {
        pstnStartIdempotency.set(idempotencyCacheKey, {
          expiresAt: Date.now() + 60_000,
          payload: failurePayload,
        });
      }
      res.status(503).json(failurePayload);
      return;
    }

    logger.info({
      callSessionId: shortId(callSession.id),
      provider: result.provider,
      status: providerStatus,
      mediaBridgeStatus,
      sipParticipantId: shortId(bridgeResult.sipParticipantId),
      disclosureEnabled: disclosure.enabled,
      requireAccept: disclosure.requireAccept,
      disclosureStatus: payload.calleeDisclosure.status,
    }, "[pstn] calls/start 200");

    if (idempotencyCacheKey) {
      pstnStartIdempotency.set(idempotencyCacheKey, {
        expiresAt: Date.now() + 60_000,
        payload,
      });
    }
    res.status(200).json(payload);
  });

  async function sendCallStatus(req: express.Request, res: express.Response, callSessionId: string) {
    const userId = (req as AuthenticatedRequest).userId;
    if (!callSessionId) {
      res.status(400).json({ ok: false, error: "invalid_call_session_id" });
      return;
    }

    const callSession = await prisma.callSession.findFirst({
      where: {
        id: callSessionId,
        callerUserId: userId,
        networkType: "pstnBridge",
      },
      select: {
        id: true,
        status: true,
        provider: true,
        providerCallId: true,
        mediaBridgeStatus: true,
        failureReason: true,
        roomName: true,
        sipParticipantId: true,
        pstnLiveKitIdentity: true,
        startedAt: true,
        answeredAt: true,
        endedAt: true,
      },
    });

    if (!callSession) {
      res.status(404).json({
        ok: false,
        error: "call_session_not_found",
        message: "External call session not found.",
      });
      return;
    }

    res.status(200).json({
      ok: true,
      callSessionId: callSession.id,
      status: callSession.status,
      provider: callSession.provider ?? provider.name,
      providerCallId: callSession.providerCallId,
      sipParticipantId: callSession.sipParticipantId,
      participantIdentity: callSession.sipParticipantId
        ? callSession.pstnLiveKitIdentity ?? liveKitSIPParticipantIdentity(callSession.id)
        : null,
      mediaBridgeStatus: callSession.mediaBridgeStatus,
      failureReason: callSession.failureReason,
      roomName: callSession.roomName,
      startedAt: callSession.startedAt,
      answeredAt: callSession.answeredAt,
      endedAt: callSession.endedAt,
      message: pstnStatusMessage(callSession.status, callSession.failureReason),
      calleeDisclosure: calleeDisclosurePayload({
        enabled: pstnDisclosureConfig().enabled,
        requireAccept: pstnDisclosureConfig().requireAccept,
        status: callSession.status,
        failureReason: callSession.failureReason,
      }),
    });
  }

  router.get("/calls/status", authMiddleware, async (req, res) => {
    await sendCallStatus(req, res, text(req.query.callSessionId) ?? "");
  });

  router.get("/calls/status/:callSessionId", authMiddleware, async (req, res) => {
    await sendCallStatus(req, res, text(req.params.callSessionId) ?? "");
  });

  router.get("/calls/:callSessionId", authMiddleware, async (req, res) => {
    await sendCallStatus(req, res, text(req.params.callSessionId) ?? "");
  });

  router.post("/calls/end", authMiddleware, async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const callSessionId = text(req.body?.callSessionId) ?? text(req.query.callSessionId);
    if (!callSessionId) {
      res.status(400).json({ ok: false, error: "invalid_call_session_id" });
      return;
    }

    const callSession = await prisma.callSession.findFirst({
      where: {
        id: callSessionId,
        callerUserId: userId,
        networkType: "pstnBridge",
      },
      select: { id: true, providerCallId: true, roomName: true },
    });
    if (!callSession) {
      res.status(404).json({ ok: false, callSessionId, error: "call_session_not_found" });
      return;
    }
    const terminationResults = await Promise.allSettled([
      callSession.providerCallId && provider.endOutboundCall
        ? provider.endOutboundCall(callSession.providerCallId)
        : Promise.resolve(),
      bridgeService.endCallRoom(callSession.roomName),
    ]);
    for (const result of terminationResults) {
      if (result.status === "rejected") {
        logger.error({ err: result.reason, callSessionId: shortId(callSessionId) }, "[pstn] call leg termination failed");
      }
    }
    await prisma.callSession.update({
      where: { id: callSession.id },
      data: {
        status: "ended",
        mediaBridgeStatus: "ended",
        endedAt: new Date(),
      },
    });

    res.status(200).json({
      ok: true,
      callSessionId,
    });
  });

  router.get("/debug/last-failure", authMiddleware, async (_req, res) => {
    if (!twilioDebugRouteEnabled()) {
      res.status(404).json({ ok: false, error: "not_found" });
      return;
    }

    let debuggerFailure: TwilioFailureSnapshot | null = null;
    try {
      debuggerFailure = await fetchLatestTwilioFailureFromDebugger();
    } catch (error) {
      logger.warn({ err: error }, "[pstn] twilio debugger lookup failed");
      debuggerFailure = {
        errorCode: "twilio_debugger_lookup_failed",
        errorMessage: error instanceof Error ? error.message : "Twilio debugger lookup failed.",
        timestamp: new Date().toISOString(),
      };
    }

    const failure = debuggerFailure ?? lastTwilioFailure;
    res.status(200).json({
      ok: true,
      source: debuggerFailure ? "twilio_debugger" : lastTwilioFailure ? "server_capture" : "none",
      failure: failure ?? null,
    });
  });

  router.post("/twilio/disclosure/timeout", twilioWebhookMiddleware, async (req, res) => {
    const startedAt = Date.now();
    const callSessionId = text(req.query.callSessionId) ?? text(req.body?.callSessionId);
    const providerCallId = text(req.body?.CallSid) ?? text(req.query.CallSid);

    logger.info({
      callSessionId: shortId(callSessionId),
      providerCallId: shortId(providerCallId),
      contentType: req.headers["content-type"],
      route: "/api/pstn/twilio/disclosure/timeout",
    }, "twilio.disclosure.timeout.received");

    const session = await findOutboundTwilioCallSession({ callSessionId, providerCallId });
    if (session) {
      await updateCallSessionByIdForProvider(session.id, "twilio", {
        providerCallId: providerCallId ?? session.providerCallId ?? undefined,
        status: "failed",
        mediaBridgeStatus: "failed",
        failureReason: "callee_disclosure_timeout",
      });
    }

    sendTwilioTwiML(
      req,
      res,
      sayXml("No acceptance was received. Goodbye.") + hangupXml(),
      {
        callSessionId: session?.id ?? callSessionId,
        providerCallId: providerCallId ?? session?.providerCallId ?? undefined,
        stage: "disclosure_timeout",
        startedAt,
        reason: "callee_disclosure_timeout",
      },
    );
  });

  router.post("/twilio/disclosure/accept", twilioWebhookMiddleware, async (req, res) => {
    const startedAt = Date.now();
    const callSessionId = text(req.query.callSessionId) ?? text(req.body?.callSessionId);
    const providerCallId = text(req.body?.CallSid) ?? text(req.query.CallSid);
    const digits = text(req.body?.Digits) ?? text(req.query.Digits);

    logger.info({
      callSessionId: shortId(callSessionId),
      providerCallId: shortId(providerCallId),
      digits,
      contentType: req.headers["content-type"],
      route: "/api/pstn/twilio/disclosure/accept",
    }, "twilio.disclosure.callback.received");

    const session = await findOutboundTwilioCallSession({ callSessionId, providerCallId });
    if (!session) {
      setLastTwilioFailure({
        callSid: providerCallId,
        errorCode: "disclosure_accept_session_not_found",
        errorMessage: "Could not locate PSTN call session for Twilio disclosure acceptance.",
        failingUrl: fullRequestUrl(req),
        requestMethod: req.method,
        responseStatus: 200,
        responseContentType: "text/xml",
        responseBodyPreview: "session_not_found",
        webhookLatencyMs: Date.now() - startedAt,
      });
      sendTwilioFailureTwiML(req, res, {
        callSessionId,
        providerCallId,
        stage: "disclosure_accept",
        startedAt,
        reason: "session_not_found",
      });
      return;
    }

    if (digits !== "1") {
      await updateCallSessionByIdForProvider(session.id, "twilio", {
        providerCallId: providerCallId ?? session.providerCallId ?? undefined,
        status: "failed",
        mediaBridgeStatus: "failed",
        failureReason: digits ? "callee_disclosure_declined" : "callee_disclosure_missing_digits",
      });
      sendTwilioTwiML(
        req,
        res,
        sayXml("The call was not accepted. Goodbye.") + hangupXml(),
        {
          callSessionId: session.id,
          providerCallId: providerCallId ?? session.providerCallId ?? undefined,
          stage: "disclosure_accept",
          startedAt,
          reason: digits ? "disclosure_declined" : "disclosure_missing_digits",
        },
      );
      return;
    }

    const inboundTo = session.externalPhoneNumber ?? session.toNumber ?? text(req.body?.To) ?? text(req.query.To) ?? "";

    const accepted = await acceptDisclosureOnExistingTwilioLeg({
      bridgeService,
      callSessionId: session.id,
      callerUserId: session.callerUserId,
      roomName: session.roomName,
      toPhoneNumber: inboundTo,
      fromPhoneNumber: session.fromNumber,
      providerCallId: providerCallId ?? session.providerCallId ?? undefined,
      sourceFunction: "twilio.disclosure.accept",
    });

    if (!accepted.ok) {
      sendTwilioFailureTwiML(req, res, {
        callSessionId: session.id,
        providerCallId: providerCallId ?? session.providerCallId ?? undefined,
        stage: "disclosure_accept",
        startedAt,
        reason: accepted.reason,
      });
      return;
    }

    sendTwilioTwiML(
      req,
      res,
      sayXml("Connecting your OneWay call.")
        + connectExistingTwilioLegToLiveKitXml(accepted.connectUrl),
      {
        callSessionId: session.id,
        providerCallId: providerCallId ?? session.providerCallId ?? undefined,
        stage: "disclosure_accept",
        startedAt,
        reason: "disclosure_accepted_bridge",
      },
    );
  });

  router.get("/twilio/voice/diagnostic", authMiddleware, async (req, res) => {
    const callSessionId = text(req.query.callSessionId) ?? "diagnostic";
    const roomName = text(req.query.roomName) ?? `pstn-${callSessionId}`;
    const toPhoneNumber = text(req.query.toPhoneNumber) ?? "";
    const sipUri = sipBridgeUriTemplate
      ? applyTemplate(sipBridgeUriTemplate, {
          roomName,
          callSessionId,
          toPhoneNumber,
        }).trim()
      : "";

    const inner = sipUri
      ? sayXml("Diagnostic TwiML. Connecting test SIP bridge.")
        + `<Dial answerOnBridge="true"><Sip>${safeValue(sipUri)}</Sip></Dial>`
      : sayXml("Diagnostic TwiML. SIP bridge target is not configured.") + hangupXml();

    res.type("text/xml").status(200).send(xmlResponse(inner));
  });

  router.all("/twilio/voice", twilioWebhookMiddleware, async (req, res) => {
    const startedAt = Date.now();
    const callSessionId = text(req.query.callSessionId) ?? text(req.body?.callSessionId);
    const providerCallId = text(req.body?.CallSid) ?? text(req.query.CallSid);
    const providerStatus = text(req.body?.CallStatus) ?? text(req.query.CallStatus);
    const digits = text(req.body?.Digits) ?? text(req.query.Digits);
    const disclosure = pstnDisclosureConfig();
    const stage = text(req.query.stage) ?? text(req.body?.stage) ?? "start";

    try {

    logger.info({
      callSessionId: shortId(callSessionId),
      providerCallId: shortId(providerCallId),
      providerStatus,
      method: req.method,
      stage,
      disclosureEnabled: disclosure.enabled,
      requireAccept: disclosure.requireAccept,
      disclosureStatus: digits ? (digits === "1" ? "accepted" : "declined") : DISCLOSURE_WAITING_STATUS,
    }, "[pstn] twilio voice webhook");

    await updateCallSessionByIdForProvider(callSessionId, "twilio", {
      providerCallId,
      twilioCallSid: asTwilioCallSid(providerCallId),
      status: providerStatus ? mapProviderStatusToCallStatus(providerStatus) : undefined,
      mediaBridgeStatus: providerStatus ? mapProviderStatusToMediaBridgeStatus(providerStatus) : undefined,
      failureReason: null,
    });

    await updateCallSessionByProviderCallId(providerCallId, {
      status: providerStatus ? mapProviderStatusToCallStatus(providerStatus) : undefined,
      mediaBridgeStatus: providerStatus ? mapProviderStatusToMediaBridgeStatus(providerStatus) : undefined,
    }, "twilio");

    const callSession = callSessionId
      ? await prisma.callSession.findUnique({
          where: { id: callSessionId },
          select: {
            id: true,
            callerUserId: true,
            roomName: true,
            toNumber: true,
            externalPhoneNumber: true,
            fromNumber: true,
          },
        }).catch(() => null)
      : null;

    if (!callSession) {
      const handledInbound = await handleInboundTwilioVoice(req, res, {
        providerCallId,
        providerStatus,
        digits,
      });
      if (handledInbound) return;
    }

    if (disclosure.enabled) {
      const callerDisplayName = callSession?.callerUserId
        ? await loadCallerDisclosureDisplayName(callSession.callerUserId)
        : undefined;
      const prompt = buildDisclosurePrompt(disclosure, callerDisplayName);
      const actionUrl = twilioDisclosureAcceptUrl(callSessionId);
      const timeoutUrl = twilioDisclosureTimeoutUrl(callSessionId);

      if (disclosure.requireAccept && !digits) {
        await updateCallSessionByIdForProvider(callSessionId, "twilio", {
          providerCallId,
          status: DISCLOSURE_WAITING_STATUS,
          mediaBridgeStatus: "connecting",
          failureReason: null,
        });
        sendTwilioTwiML(
          req,
          res,
          `<Gather input="dtmf" numDigits="1" timeout="10" action="${safeValue(actionUrl)}" method="POST">` +
          `<Say voice="alice">${safeValue(prompt)}</Say>` +
          `</Gather>` +
          `<Redirect method="POST">${safeValue(timeoutUrl)}</Redirect>`,
          { callSessionId, providerCallId, stage, startedAt, reason: "disclosure_prompt" },
        );
        return;
      }

      if (disclosure.requireAccept && digits !== "1") {
        await updateCallSessionByIdForProvider(callSessionId, "twilio", {
          providerCallId,
          status: "failed",
          mediaBridgeStatus: "failed",
          failureReason: "callee_disclosure_declined",
        });
        sendTwilioTwiML(
          req,
          res,
          sayXml("The call was not accepted. Goodbye.") + hangupXml(),
          { callSessionId, providerCallId, stage, startedAt, reason: "disclosure_declined" },
        );
        return;
      }

      const inboundTo = callSession?.externalPhoneNumber ?? callSession?.toNumber ?? text(req.body?.To) ?? text(req.query.To) ?? "";

      let acceptedConnector: { connectUrl: string } | undefined;
      if (callSession?.id && callSession.roomName) {
        const accepted = await acceptDisclosureOnExistingTwilioLeg({
          bridgeService,
          callSessionId: callSession.id,
          callerUserId: callSession.callerUserId,
          roomName: callSession.roomName,
          toPhoneNumber: inboundTo,
          fromPhoneNumber: callSession.fromNumber,
          providerCallId,
          sourceFunction: "twilio.voice",
        });
        if (!accepted.ok) {
          sendTwilioFailureTwiML(req, res, {
            callSessionId,
            providerCallId,
            stage,
            startedAt,
            reason: accepted.reason,
          });
          return;
        }
        acceptedConnector = accepted;
      } else {
        sendTwilioFailureTwiML(req, res, {
          callSessionId,
          providerCallId,
          stage,
          startedAt,
          reason: "disclosure_accept_session_not_found",
        });
        return;
      }
      logger.info({
        callSessionId: shortId(callSessionId),
        providerCallId: shortId(providerCallId),
        provider: "twilio",
        disclosureEnabled: true,
        requireAccept: disclosure.requireAccept,
        disclosureStatus: "accepted",
        hasBridgeTarget: true,
        backendRoomName: callSession?.roomName,
        sipParticipantRoomName: callSession?.roomName,
      }, "[pstn] twilio disclosure accepted; bridging");

      const leadIn = disclosure.requireAccept ? "Connecting your OneWay call." : prompt;
      sendTwilioTwiML(
        req,
        res,
        `<Say voice="alice">${safeValue(leadIn)}</Say>` +
        connectExistingTwilioLegToLiveKitXml(acceptedConnector.connectUrl) +
        "",
        { callSessionId, providerCallId, stage, startedAt, reason: "disclosure_accepted_bridge" },
      );
      return;
    }

    if (sipBridgeUriTemplate && callSession?.roomName) {
      const inboundTo = text(req.body?.To) ?? text(req.query.To) ?? "";
      const sipUri = applyTemplate(sipBridgeUriTemplate, {
        roomName: callSession.roomName,
        callSessionId: callSessionId ?? "",
        toPhoneNumber: inboundTo,
      }).trim();
      if (sipUri) {
        startTwilioDialSIPParticipantWatcher({
          bridgeService,
          callSessionId: callSession.id,
          roomName: callSession.roomName,
          providerCallId,
          sourceFunction: "twilio.voice.direct_bridge",
        });
        sendTwilioTwiML(
          req,
          res,
          dialExistingTwilioLegToSIPXml({
            sipUri,
            callSessionId: callSession.id,
            providerCallId,
          }),
          { callSessionId, providerCallId, stage, startedAt, reason: "direct_bridge" },
        );
        return;
      }
    }

    await updateCallSessionByIdForProvider(callSessionId, "twilio", {
      providerCallId,
      status: "failed",
      mediaBridgeStatus: "failed",
      failureReason: "twilio_voice_missing_bridge_target",
    });
    sendTwilioFailureTwiML(req, res, {
      callSessionId,
      providerCallId,
      stage,
      startedAt,
      reason: "missing_bridge_target_fallback",
    });
    } catch (error) {
      logger.error({
        err: error,
        callSessionId: shortId(callSessionId),
        providerCallId: shortId(providerCallId),
        providerStatus,
        method: req.method,
        stage,
        latencyMs: Date.now() - startedAt,
      }, "[pstn] twilio voice webhook failed");

      await updateCallSessionByIdForProvider(callSessionId, "twilio", {
        providerCallId,
        status: "failed",
        mediaBridgeStatus: "failed",
        failureReason: error instanceof Error ? `twilio_webhook_failed: ${error.message}` : "twilio_webhook_failed",
      });

      if (!res.headersSent) {
        sendTwilioFailureTwiML(req, res, {
          callSessionId,
          providerCallId,
          stage,
          startedAt,
          reason: "handler_exception",
        });
      }
    }
  });

  router.post("/twilio/status", twilioWebhookMiddleware, async (req, res) => {
    const callSessionId = text(req.query.callSessionId) ?? text(req.body?.callSessionId);
    const providerCallId = text(req.body?.CallSid);
    const providerStatus = text(req.body?.CallStatus);
    const leg = text(req.query.leg) ?? text(req.body?.leg);
    const sipStatus = text(req.body?.SipResponseCode)
      ?? text(req.body?.SipCallStatus)
      ?? text(req.body?.ErrorCode);
    const twilioErrorCode = text(req.body?.ErrorCode);
    const twilioErrorMessage = text(req.body?.ErrorMessage);

    logger.info({
      callSessionId,
      providerCallId,
      providerStatus,
      leg,
      sipStatus,
      hasTwilioError: Boolean(twilioErrorCode || twilioErrorMessage),
    }, "[pstn] twilio status webhook");

    const mappedStatus = providerStatus ? mapProviderStatusToCallStatus(providerStatus) : undefined;
    const existing = callSessionId
      ? await prisma.callSession.findUnique({
          where: { id: callSessionId },
          select: { status: true, roomName: true },
        }).catch(() => null)
      : null;
    const didEndBeforeDisclosureAcceptance =
      existing?.status === DISCLOSURE_WAITING_STATUS &&
      (mappedStatus === "ended" || mappedStatus === "failed");
    const stillWaitingForDisclosureAcceptance =
      existing?.status === DISCLOSURE_WAITING_STATUS &&
      !didEndBeforeDisclosureAcceptance;
    const effectiveStatus = didEndBeforeDisclosureAcceptance
      ? "failed"
      : stillWaitingForDisclosureAcceptance
      ? undefined
      : leg === "sip" && mappedStatus !== "failed"
      ? undefined
      : mappedStatus;
    const effectiveFailureReason = didEndBeforeDisclosureAcceptance
      ? "callee_disclosure_not_accepted"
      : providerStatus && mappedStatus === "failed"
        ? providerStatus
        : null;

    await updateCallSessionByIdForProvider(callSessionId, "twilio", {
      providerCallId,
      twilioCallSid: asTwilioCallSid(providerCallId),
      status: effectiveStatus,
      mediaBridgeStatus: didEndBeforeDisclosureAcceptance
        ? "failed"
        : stillWaitingForDisclosureAcceptance
          ? "connecting"
          : providerStatus ? mapProviderStatusToMediaBridgeStatus(providerStatus) : undefined,
      failureReason: effectiveFailureReason,
    });

    await updateCallSessionByProviderCallId(providerCallId, {
      status: effectiveStatus,
      mediaBridgeStatus: didEndBeforeDisclosureAcceptance
        ? "failed"
        : stillWaitingForDisclosureAcceptance
          ? "connecting"
          : providerStatus ? mapProviderStatusToMediaBridgeStatus(providerStatus) : undefined,
      failureReason: effectiveFailureReason,
    }, "twilio");

    if ((mappedStatus === "ended" || mappedStatus === "failed") && existing?.roomName) {
      try {
        await bridgeService.endCallRoom(existing.roomName);
      } catch (error) {
        logger.error({ err: error, callSessionId: shortId(callSessionId) }, "[pstn] failed to end LiveKit room after Twilio hangup");
      }
    }

    if (mappedStatus === "failed" || twilioErrorCode || sipStatus) {
      setLastTwilioFailure({
        callSid: providerCallId,
        errorCode: twilioErrorCode ?? (mappedStatus === "failed" ? providerStatus : undefined),
        errorMessage: twilioErrorMessage ?? effectiveFailureReason ?? undefined,
        failingUrl: fullRequestUrl(req),
        requestMethod: req.method,
        responseStatus: 200,
        responseContentType: "application/json",
        responseBodyPreview: JSON.stringify({ ok: true }),
        sipStatus,
      });
    }

    res.status(200).json({ ok: true });
  });

  router.post("/telnyx/webhook", async (req, res) => {
    const eventType = text(req.body?.data?.event_type) ?? text(req.body?.event_type);
    const payload = req.body?.data?.payload ?? req.body?.payload ?? {};

    const callSessionId = text(req.query.callSessionId)
      ?? text(payload.call_session_id)
      ?? decodeTelnyxClientState(payload.client_state);

    const providerCallId = text(payload.call_control_id) ?? text(payload.call_leg_id) ?? text(req.body?.call_control_id);
    const mappedStatus = eventType ? mapProviderStatusToCallStatus(eventType.replace("call.", "")) : undefined;

    logger.info({
      eventType,
      callSessionId: shortId(callSessionId),
      providerCallId: shortId(providerCallId),
      hasPayload: Boolean(payload),
    }, "[pstn] telnyx webhook");

    await updateCallSessionByIdForProvider(callSessionId, "telnyx", {
      providerCallId,
      status: mappedStatus,
      mediaBridgeStatus: eventType ? mapProviderStatusToMediaBridgeStatus(eventType.replace("call.", "")) : undefined,
      failureReason: mappedStatus === "failed" ? eventType : null,
    });

    await updateCallSessionByProviderCallId(providerCallId, {
      status: mappedStatus,
      mediaBridgeStatus: eventType ? mapProviderStatusToMediaBridgeStatus(eventType.replace("call.", "")) : undefined,
      failureReason: mappedStatus === "failed" ? eventType : null,
    }, "telnyx");

    res.status(200).json({ ok: true });
  });

  router.post("/sinch/webhook", async (req, res) => {
    const eventType = text(req.body?.event) ?? text(req.body?.eventType) ?? text(req.body?.type);
    const callSessionId = text(req.query.callSessionId)
      ?? text(req.body?.custom)
      ?? text(req.body?.callSessionId)
      ?? text(req.body?.callid);
    const providerCallId = text(req.body?.callid) ?? text(req.body?.callId) ?? text(req.body?.id);
    const mappedStatus = eventType ? mapProviderStatusToCallStatus(eventType.replace("call.", "")) : undefined;

    logger.info({
      eventType,
      callSessionId: shortId(callSessionId),
      providerCallId: shortId(providerCallId),
      hasPayload: Boolean(req.body),
    }, "[pstn] sinch webhook");

    await updateCallSessionByIdForProvider(callSessionId, "sinch", {
      providerCallId,
      status: mappedStatus,
      mediaBridgeStatus: eventType ? mapProviderStatusToMediaBridgeStatus(eventType.replace("call.", "")) : undefined,
      failureReason: mappedStatus === "failed" ? eventType : null,
    });

    await updateCallSessionByProviderCallId(providerCallId, {
      status: mappedStatus,
      mediaBridgeStatus: eventType ? mapProviderStatusToMediaBridgeStatus(eventType.replace("call.", "")) : undefined,
      failureReason: mappedStatus === "failed" ? eventType : null,
    }, "sinch");

    res.status(200).json({ ok: true });
  });

  return router;
}
