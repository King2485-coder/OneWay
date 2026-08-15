const DEFAULT_TWILIO_A2P_COMPLIANCE_SID = "QE2c6890da8086d771620e9b13fadeba0b";

export type TwilioCampaignStatusResult = {
  campaignStatus: string | null;
  error?: string;
};

export async function resolveTwilioCampaignStatus(messagingServiceSid: string): Promise<TwilioCampaignStatusResult> {
  const configuredStatus = env("TWILIO_A2P_CAMPAIGN_STATUS") || env("SMS_A2P_CAMPAIGN_STATUS");
  if (configuredStatus) {
    return { campaignStatus: configuredStatus.toUpperCase() };
  }

  const accountSid = env("TWILIO_ACCOUNT_SID");
  const authToken = env("TWILIO_AUTH_TOKEN");
  if (!accountSid || !authToken) {
    return { campaignStatus: null, error: "missing_twilio_credentials" };
  }

  const complianceSid = env("TWILIO_A2P_COMPLIANCE_SID") || DEFAULT_TWILIO_A2P_COMPLIANCE_SID;
  const endpoint = `https://messaging.twilio.com/v1/Services/${encodeURIComponent(messagingServiceSid)}/Compliance/Usa2p/${complianceSid}`;
  try {
    const response = await fetch(endpoint, {
      headers: {
        Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString("base64")}`,
      },
    });
    if (response.status === 404) {
      return { campaignStatus: null, error: "campaign_not_found" };
    }
    if (!response.ok) {
      return { campaignStatus: null, error: `twilio_a2p_status_http_${response.status}` };
    }
    const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    const rawStatus = typeof body.campaign_status === "string" ? body.campaign_status : null;
    return { campaignStatus: rawStatus?.trim().toUpperCase() ?? null };
  } catch {
    return { campaignStatus: null, error: "twilio_a2p_status_unavailable" };
  }
}

function env(name: string): string {
  return (process.env[name] ?? "").trim();
}
