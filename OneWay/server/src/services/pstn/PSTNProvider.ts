export interface PSTNProvider {
  startOutboundCall(input: {
    fromUserId: string;
    fromOneWayNumber?: string;
    toPhoneNumber: string;
    callSessionId: string;
  }): Promise<{
    providerCallId: string;
    status: "initiated" | "failed";
  }>;
}
