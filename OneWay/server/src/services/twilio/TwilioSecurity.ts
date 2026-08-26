import type { NextFunction, Request, Response } from "express";
import twilio from "twilio";

import { logger } from "../../lib/logger";

function env(name: string): string {
  return (process.env[name] ?? "").trim();
}

export function twilioWebhookBaseUrl(): string {
  return env("TWILIO_WEBHOOK_BASE_URL")
    || env("PUBLIC_WEBHOOK_BASE_URL")
    || env("PSTN_WEBHOOK_BASE_URL")
    || env("SMS_WEBHOOK_BASE_URL");
}

function firstHeader(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

export function twilioWebhookUrl(req: Request): string {
  const configured = twilioWebhookBaseUrl();
  if (configured) return `${configured.replace(/\/+$/, "")}${req.originalUrl}`;

  const forwardedProto = firstHeader(req.headers["x-forwarded-proto"] as string | string[] | undefined)
    .split(",")[0]?.trim();
  const forwardedHost = firstHeader(req.headers["x-forwarded-host"] as string | string[] | undefined)
    .split(",")[0]?.trim();
  const protocol = forwardedProto || req.protocol;
  const host = forwardedHost || req.get("host") || "";
  return `${protocol}://${host}${req.originalUrl}`;
}

export function validateTwilioRequest(input: {
  authToken: string;
  signature: string;
  url: string;
  params: Record<string, string>;
}): boolean {
  if (!input.authToken || !input.signature || !input.url) return false;
  return twilio.validateRequest(input.authToken, input.signature, input.url, input.params);
}

export function twilioWebhookMiddleware(req: Request, res: Response, next: NextFunction): void {
  const authToken = env("TWILIO_AUTH_TOKEN");
  const signature = firstHeader(req.headers["x-twilio-signature"] as string | string[] | undefined);
  const required = process.env.NODE_ENV === "production"
    || env("TWILIO_VALIDATE_WEBHOOKS").toLowerCase() !== "false";

  if (!authToken) {
    if (!required) {
      next();
      return;
    }
    res.status(503).json({ error: "twilio_webhook_validation_not_configured" });
    return;
  }

  const params = Object.fromEntries(
    Object.entries(req.method === "GET" ? req.query : req.body ?? {})
      .filter((entry): entry is [string, string | number | boolean] =>
        ["string", "number", "boolean"].includes(typeof entry[1]))
      .map(([key, value]) => [key, String(value)]),
  );
  const url = twilioWebhookUrl(req);
  if (!validateTwilioRequest({ authToken, signature, url, params })) {
    logger.warn({ path: req.path, method: req.method }, "[twilio] rejected invalid webhook signature");
    res.status(403).json({ error: "invalid_twilio_signature" });
    return;
  }
  next();
}

export interface TwilioProductionValidation {
  ok: boolean;
  missing: string[];
  warnings: string[];
}

export function validateTwilioProductionEnvironment(): TwilioProductionValidation {
  const missing: string[] = [];
  const warnings: string[] = [];
  const required = [
    "TWILIO_ACCOUNT_SID",
    "TWILIO_AUTH_TOKEN",
    "TWILIO_API_KEY_SID",
    "TWILIO_API_KEY_SECRET",
    "TWILIO_TWIML_APP_SID",
    "TWILIO_MESSAGING_SERVICE_SID",
  ];
  for (const name of required) if (!env(name)) missing.push(name);

  const baseUrl = env("TWILIO_WEBHOOK_BASE_URL") || env("PUBLIC_WEBHOOK_BASE_URL");
  if (!baseUrl) missing.push("TWILIO_WEBHOOK_BASE_URL or PUBLIC_WEBHOOK_BASE_URL");
  else {
    try {
      const parsed = new URL(baseUrl);
      if (parsed.protocol !== "https:") warnings.push("Twilio webhooks must use HTTPS in production.");
      if (["localhost", "127.0.0.1", "::1"].includes(parsed.hostname)) {
        warnings.push("Twilio webhooks must use a publicly reachable host in production.");
      }
    } catch {
      warnings.push("Twilio webhook base URL is invalid.");
    }
  }
  if (env("TWILIO_VALIDATE_WEBHOOKS").toLowerCase() === "false") {
    warnings.push("TWILIO_VALIDATE_WEBHOOKS cannot be false in production.");
  }
  return { ok: missing.length === 0 && warnings.length === 0, missing, warnings };
}
