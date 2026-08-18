import { PSTNProvider } from "./PSTNProvider";

export class TwilioPSTNProvider implements PSTNProvider {
  async startOutboundCall(input: {
    fromUserId: string;
    fromOneWayNumber?: string;
    toPhoneNumber: string;
    callSessionId: string;
  }): Promise<{ providerCallId: string; status: "initiated" | "failed" }> {
    console.warn("[pstn:twilio] provider not configured, falling back to stub-like response", input);
    return { providerCallId: `twilio_stub_${input.callSessionId}`, status: "failed" };
  }
}
