const REDACTED = "[REDACTED]";
const REDACTED_SECRET = "[REDACTED_SECRET]";
const REDACTED_MESSAGE = "[REDACTED_MESSAGE]";
const REDACTED_PAYMENT = "[REDACTED_PAYMENT_LINK]";
const REDACTED_CONTACT = "[REDACTED_CONTACT]";
const REDACTED_BANK = "[REDACTED_BANK_ID]";

const EMAIL_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi;
const PHONE_PATTERN = /(?:\+?1[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)\d{3}[\s.-]?\d{4}\b/g;
const BEARER_PATTERN = /\bBearer\s+[A-Za-z0-9._~+/-]+=*/gi;
const BASIC_PATTERN = /\bBasic\s+[A-Za-z0-9+/=]+/gi;
const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g;
const SECRET_ASSIGNMENT_PATTERN = /\b([A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|AUTH)[A-Z0-9_]*)\s*=\s*([^\s,;&]+)/gi;
const PAYMENT_URL_PATTERN = /https?:\/\/[^\s"'<>]*(?:checkout|buy|pay|payment|stripe|square|paypal|venmo|cash\.app|token|client_secret)[^\s"'<>]*/gi;
const ACCOUNT_ID_PATTERN = /\b(?:acct|ba|bank|ledger|account)[-_]?[A-Za-z0-9]{8,}\b/gi;
const LABELED_SENSITIVE_ID_PATTERN = /\b(user|userid|user_id|account|accountid|account_id|bank|ledger|unit|unittxid|unit_tx_id|transaction|transactionid|transaction_id|dispute|disputeid|dispute_id|wallet|walletpaymentid|wallet_payment_id)\s*[=:]\s*([A-Za-z0-9._:-]{6,})/gi;
const LABELED_AMOUNT_PATTERN = /\b(amount|balance|available_balance|availablebalance|debit|credit|fee|fees|net)\s*[=:]?\s*\$?-?\d[\d,]*(?:\.\d+)?/gi;

export type SensitiveFieldClass =
  | "secret"
  | "contact"
  | "message"
  | "payment"
  | "bank"
  | "safe";

const SECRET_FIELD = /(^|[_-])(authorization|cookie|setcookie|password|passcode|secret|token|jwt|apikey|api_key|accesskey|access_key|privatekey|private_key|credential|auth|sendgrid|stripe|twilio|telnyx|sinch|livekit|sentry|webhooksecret|client_secret)($|[_-])/i;
const CONTACT_FIELD = /(^|[_-])(email|phone|phonenumber|number|callerid|caller_id|callernumber|caller_number|fromnumber|from_number|tonumber|to_number|onewaynumber|oneway_number|toemail|to_email|fromemail|from_email|replyto|reply_to|customeremail|customer_email|customerphone|customer_phone|buyeremail|buyer_email|buyerphone|buyer_phone|contactemail|contact_email|contactphone|contact_phone)($|[_-])/i;
const MESSAGE_FIELD = /(^|[_-])(message|body|bodytext|bodyhtml|htmlbody|text|plaintext|content|subject|prompt|aibody|lastbody|lastaibody|customername|buyername|name)($|[_-])/i;
const PAYMENT_FIELD = /(^|[_-])(paymentlink|paymentlinkurl|checkouturl|paymenturl|redirecturl|card|pan|cvv|cvc|paymentmethod|providerresponse|providerbody)($|[_-])/i;
const BANK_FIELD = /(^|[_-])(bank|ledger|accountid|account_id|bankaccount|routing|aba|iban|unit|modern_treasury|moderntreasury|balance|availablebalance|available_balance)($|[_-])/i;

export function classifySensitiveField(fieldName: string): SensitiveFieldClass {
  const normalized = fieldName.replace(/[^a-zA-Z0-9_-]/g, "");
  if (SECRET_FIELD.test(normalized)) return "secret";
  if (PAYMENT_FIELD.test(normalized)) return "payment";
  if (CONTACT_FIELD.test(normalized)) return "contact";
  if (MESSAGE_FIELD.test(normalized)) return "message";
  if (BANK_FIELD.test(normalized)) return "bank";
  return "safe";
}

export function redactSensitiveString(value: string): string {
  return value
    .replace(BEARER_PATTERN, "Bearer [REDACTED_SECRET]")
    .replace(BASIC_PATTERN, "Basic [REDACTED_SECRET]")
    .replace(JWT_PATTERN, REDACTED_SECRET)
    .replace(SECRET_ASSIGNMENT_PATTERN, (_match, key) => `${key}=${REDACTED_SECRET}`)
    .replace(PAYMENT_URL_PATTERN, REDACTED_PAYMENT)
    .replace(LABELED_SENSITIVE_ID_PATTERN, (_match, label) => `${label}=${REDACTED_BANK}`)
    .replace(LABELED_AMOUNT_PATTERN, (_match, label) => `${label}=${REDACTED}`)
    .replace(EMAIL_PATTERN, REDACTED_CONTACT)
    .replace(PHONE_PATTERN, REDACTED_CONTACT)
    .replace(ACCOUNT_ID_PATTERN, REDACTED_BANK);
}

export function redactPaymentLink(value: string): string {
  try {
    const url = new URL(value);
    if (["http:", "https:"].includes(url.protocol)) {
      return `${url.origin}${url.pathname ? sanitizePath(url.pathname) : ""}${url.search ? "?…" : ""}`;
    }
  } catch {
    // Fall through to generic string redaction.
  }
  return redactSensitiveString(value);
}

export function redactSensitiveObject<T>(value: T, depth = 0, seen = new WeakSet<object>()): T {
  if (depth > 8) return REDACTED as T;
  if (value == null) return value;

  if (typeof value === "string") return redactSensitiveString(value) as T;
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return value;
  if (value instanceof Date) return value.toISOString() as T;
  if (value instanceof Error) return redactError(value) as T;
  if (Buffer.isBuffer(value)) return `[BUFFER:${value.length}]` as T;

  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => redactSensitiveObject(item, depth + 1, seen)) as T;
  }

  if (typeof value === "object") {
    if (seen.has(value as object)) return "[Circular]" as T;
    seen.add(value as object);

    const output: Record<string, unknown> = {};
    for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
      const fieldClass = classifySensitiveField(key);
      switch (fieldClass) {
        case "secret":
          output[key] = REDACTED_SECRET;
          break;
        case "contact":
          output[key] = typeof raw === "string" ? redactSensitiveString(raw) : REDACTED_CONTACT;
          break;
        case "message":
          output[key] = REDACTED_MESSAGE;
          break;
        case "payment":
          output[key] = typeof raw === "string" ? redactPaymentLink(raw) : REDACTED_PAYMENT;
          break;
        case "bank":
          output[key] = typeof raw === "string" ? shortenSensitiveId(raw, REDACTED_BANK) : REDACTED_BANK;
          break;
        default:
          output[key] = redactSensitiveObject(raw, depth + 1, seen);
      }
    }
    return output as T;
  }

  return REDACTED as T;
}

export function shortId(value: string | null | undefined, visible = 6): string | null {
  if (!value) return null;
  const trimmed = String(value).trim();
  if (trimmed.length <= visible * 2 + 1) return trimmed;
  return `${trimmed.slice(0, visible)}…${trimmed.slice(-visible)}`;
}

function redactError(error: Error): Record<string, unknown> {
  const maybeAny = error as Error & { code?: unknown; statusCode?: unknown; status?: unknown };
  return {
    name: error.name,
    message: redactSensitiveString(error.message),
    code: typeof maybeAny.code === "string" || typeof maybeAny.code === "number" ? maybeAny.code : undefined,
    statusCode: typeof maybeAny.statusCode === "number" ? maybeAny.statusCode : typeof maybeAny.status === "number" ? maybeAny.status : undefined,
  };
}

function shortenSensitiveId(value: string, fallback: string): string {
  const redacted = redactSensitiveString(value);
  if (redacted !== value) return redacted;
  return shortId(value, 4) ?? fallback;
}

function sanitizePath(pathname: string): string {
  return pathname
    .split("/")
    .map((part) => {
      if (!part) return part;
      if (/^[A-Za-z0-9_-]{16,}$/.test(part)) return "…";
      return part;
    })
    .join("/");
}

export const PrivacyRedaction = {
  classifySensitiveField,
  redactSensitiveObject,
  redactSensitiveString,
  redactPaymentLink,
  shortId,
};
