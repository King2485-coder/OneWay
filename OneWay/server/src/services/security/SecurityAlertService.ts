import { logger } from "../../lib/logger";
import { redactSensitiveObject } from "../../lib/privacy/redaction";
import { emailProvider } from "../email/createEmailProvider";
import type { SecuritySeverity } from "./SecurityCheckRunService";

export type SecurityAlertInput = {
  severity: SecuritySeverity;
  title: string;
  summary: string;
  details?: Record<string, unknown>;
};

export async function sendSecurityAlert(input: SecurityAlertInput): Promise<{ delivered: boolean; provider: string; mode: "email" | "stub" | "none" }> {
  const details = redactSensitiveObject(input.details ?? {}) as Record<string, unknown>;
  const recipients = parseRecipients(process.env.SECURITY_ALERT_EMAILS || process.env.SECURITY_ALERT_EMAIL || "");
  if (recipients.length === 0) {
    logger.warn({ severity: input.severity, title: input.title, summary: input.summary, details }, "[security:alert] no recipients configured");
    return { delivered: false, provider: emailProvider.name, mode: "none" };
  }

  if (emailProvider.name === "stub") {
    logger.warn({ severity: input.severity, title: input.title, summary: input.summary, details, recipientCount: recipients.length }, "[security:alert] email provider stubbed");
    return { delivered: false, provider: emailProvider.name, mode: "stub" };
  }

  let delivered = true;
  for (const toEmail of recipients) {
    const result = await emailProvider.sendOutboundMessage({
      fromUserId: "system",
      toEmail,
      subject: `[OneWay Security] ${input.severity.toUpperCase()}: ${input.title}`,
      body: renderText(input, details),
      htmlBody: renderHtml(input, details),
      messageSessionId: `security-${Date.now()}`,
    });
    if (result.status === "failed") delivered = false;
  }
  return { delivered, provider: emailProvider.name, mode: "email" };
}

function parseRecipients(value: string): string[] {
  return value.split(",").map((item) => item.trim()).filter((item) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(item)).slice(0, 10);
}

function renderText(input: SecurityAlertInput, details: Record<string, unknown>): string {
  return [
    `Severity: ${input.severity}`,
    `Title: ${input.title}`,
    `Summary: ${input.summary}`,
    `Details: ${JSON.stringify(details)}`,
  ].join("\n");
}

function renderHtml(input: SecurityAlertInput, details: Record<string, unknown>): string {
  return `<strong>Severity:</strong> ${escapeHtml(input.severity)}<br><strong>Title:</strong> ${escapeHtml(input.title)}<br><strong>Summary:</strong> ${escapeHtml(input.summary)}<br><pre>${escapeHtml(JSON.stringify(details, null, 2))}</pre>`;
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
