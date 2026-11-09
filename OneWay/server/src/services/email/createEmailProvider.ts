import { StubEmailProvider } from "./StubEmailProvider";
import { SendGridEmailProvider } from "./SendGridEmailProvider";
import { MailgunEmailProvider } from "./MailgunEmailProvider";
import type { EmailProvider, EmailProviderName } from "./EmailProvider";

const SUPPORTED = new Set<EmailProviderName>(["stub", "sendgrid", "mailgun"]);

function normalizeProvider(value: string): EmailProviderName {
  const normalized = value.trim().toLowerCase() as EmailProviderName;
  return SUPPORTED.has(normalized) ? normalized : "stub";
}

/**
 * Prefer an explicitly selected provider, but recover safely when production
 * has credentials configured and EMAIL_PROVIDER was omitted. This prevents a
 * valid mail configuration from silently falling back to the non-sending stub.
 */
export function resolveConfiguredEmailProvider(
  env: NodeJS.ProcessEnv = process.env,
): EmailProviderName {
  if (env.EMAIL_PROVIDER?.trim()) return normalizeProvider(env.EMAIL_PROVIDER);

  const mailgunConfigured = Boolean(
    env.MAILGUN_API_KEY?.trim()
      && (env.ONEWAY_EMAIL_DOMAIN?.trim() || env.MAILGUN_DOMAIN?.trim()),
  );
  if (mailgunConfigured) return "mailgun";

  const sendGridConfigured = Boolean(
    env.SENDGRID_API_KEY?.trim()
      && (env.EMAIL_FROM_ADDRESS?.trim() || env.EMAIL_FROM?.trim() || env.SENDGRID_FROM_EMAIL?.trim()),
  );
  if (sendGridConfigured) return "sendgrid";

  return "stub";
}

export function getEmailDeliveryReadiness(env: NodeJS.ProcessEnv = process.env): {
  ready: boolean;
  provider: EmailProviderName;
  missing: string[];
} {
  const provider = resolveConfiguredEmailProvider(env);
  const missing: string[] = [];

  if (provider === "stub") missing.push("live_email_provider");
  if (provider === "mailgun") {
    if (!env.MAILGUN_API_KEY?.trim()) missing.push("MAILGUN_API_KEY");
    if (!env.ONEWAY_EMAIL_DOMAIN?.trim() && !env.MAILGUN_DOMAIN?.trim()) {
      missing.push("ONEWAY_EMAIL_DOMAIN or MAILGUN_DOMAIN");
    }
  }
  if (provider === "sendgrid") {
    if (!env.SENDGRID_API_KEY?.trim()) missing.push("SENDGRID_API_KEY");
    if (!env.EMAIL_FROM_ADDRESS?.trim() && !env.EMAIL_FROM?.trim() && !env.SENDGRID_FROM_EMAIL?.trim()) {
      missing.push("EMAIL_FROM_ADDRESS or SENDGRID_FROM_EMAIL");
    }
  }

  return { ready: missing.length === 0, provider, missing };
}

export function createEmailProvider(): EmailProvider {
  const selected = resolveConfiguredEmailProvider();

  switch (selected) {
    case "mailgun":
      return new MailgunEmailProvider();
    case "sendgrid":
      return new SendGridEmailProvider();
    case "stub":
    default:
      return new StubEmailProvider();
  }
}

export const emailProvider = createEmailProvider();
