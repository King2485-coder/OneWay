export type SMSDeliveryState = "queued" | "sending" | "sent" | "delivered" | "failed" | "undelivered";

export function normalizeSMSDeliveryStatus(status: string): SMSDeliveryState {
  const normalized = status.trim().toLowerCase();
  if (["queued", "accepted", "scheduled"].includes(normalized)) return "queued";
  if (normalized === "sending") return "sending";
  if (normalized === "sent") return "sent";
  if (normalized === "delivered") return "delivered";
  if (normalized === "undelivered") return "undelivered";
  if (normalized === "failed") return "failed";
  return "queued";
}

export function smsDeliveryFailureMessage(provider: string, failureReason?: string): string | null {
  if (provider === "twilio" && failureReason === "30034") {
    return "Twilio blocked this SMS because the sender is not registered for US A2P 10DLC.";
  }
  return failureReason?.trim() || null;
}
