import { StubEmailProvider } from "./StubEmailProvider";
import { SendGridEmailProvider } from "./SendGridEmailProvider";
import { MailgunEmailProvider } from "./MailgunEmailProvider";
import type { EmailProvider, EmailProviderName } from "./EmailProvider";

const SUPPORTED = new Set<EmailProviderName>(["stub", "sendgrid", "mailgun"]);

function normalizeProvider(value: string | undefined): EmailProviderName {
  const normalized = (value ?? "stub").trim().toLowerCase() as EmailProviderName;
  return SUPPORTED.has(normalized) ? normalized : "stub";
}

export function createEmailProvider(): EmailProvider {
  const selected = normalizeProvider(process.env.EMAIL_PROVIDER);

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
