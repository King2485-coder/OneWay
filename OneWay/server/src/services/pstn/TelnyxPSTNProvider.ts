import { PSTNProvider } from "./PSTNProvider";

export class TelnyxPSTNProvider implements PSTNProvider {
  async startOutboundCall(input: {
    fromUserId: string;
    fromOneWayNumber?: string;
    toPhoneNumber: string;
    callSessionId: string;
  }): Promise<{ providerCallId: string; status: "initiated" | "failed" }> {
    console.warn("[pstn:telnyx] provider not configured, falling back to stub-like response", input);
    return { providerCallId: `telnyx_stub_${input.callSessionId}`, status: "failed" };
  }
}
