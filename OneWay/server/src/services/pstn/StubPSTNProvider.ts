import { PSTNProvider } from "./PSTNProvider";

export class StubPSTNProvider implements PSTNProvider {
  async startOutboundCall(input: {
    fromUserId: string;
    fromOneWayNumber?: string;
    toPhoneNumber: string;
    callSessionId: string;
  }): Promise<{ providerCallId: string; status: "initiated" | "failed" }> {
    const providerCallId = `stub_${input.callSessionId}`;
    console.log("[pstn:stub] outbound call requested", { ...input, providerCallId });
    return { providerCallId, status: "initiated" };
  }
}
