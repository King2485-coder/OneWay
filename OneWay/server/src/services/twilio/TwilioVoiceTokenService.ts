import twilio from "twilio";

export interface TwilioVoiceTokenResult {
  token: string;
  identity: string;
  expiresIn: number;
}

export function issueTwilioVoiceToken(identity: string): TwilioVoiceTokenResult {
  const accountSid = (process.env.TWILIO_ACCOUNT_SID ?? "").trim();
  const apiKeySid = (process.env.TWILIO_API_KEY_SID ?? "").trim();
  const apiKeySecret = (process.env.TWILIO_API_KEY_SECRET ?? "").trim();
  const twimlAppSid = (process.env.TWILIO_TWIML_APP_SID ?? "").trim();
  if (!accountSid || !apiKeySid || !apiKeySecret || !twimlAppSid) {
    throw new Error("twilio_voice_token_not_configured");
  }

  const safeIdentity = identity.replace(/[^A-Za-z0-9_.:@-]/g, "_").slice(0, 121);
  if (!safeIdentity) throw new Error("invalid_twilio_identity");
  const expiresIn = 300;
  const token = new twilio.jwt.AccessToken(accountSid, apiKeySid, apiKeySecret, {
    identity: safeIdentity,
    ttl: expiresIn,
  });
  token.addGrant(new twilio.jwt.AccessToken.VoiceGrant({
    outgoingApplicationSid: twimlAppSid,
    incomingAllow: true,
  }));
  return { token: token.toJwt(), identity: safeIdentity, expiresIn };
}
