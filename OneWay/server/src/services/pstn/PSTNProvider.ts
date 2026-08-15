export type PSTNProviderName = "stub" | "twilio" | "telnyx" | "sinch";

export interface PSTNOutboundCallInput {
  fromUserId: string;
  fromOneWayNumber?: string;
  toPhoneNumber: string;
  callSessionId: string;
  roomName?: string;
  callerDisplayName?: string;
  disclosurePrompt?: string;
  calleeDisclosure?: {
    enabled: boolean;
    requireAccept: boolean;
    brand: string;
    callbackUrl?: string;
  };
  bridgeTarget?: {
    roomName?: string;
    sipUri?: string;
    liveKitRoomName?: string;
  };
}

export interface PSTNOutboundCallResult {
  providerCallId: string;
  status: "initiated" | "waiting_for_callee_acceptance" | "accepted" | "failed";
  provider: string;
  message?: string;
  mediaBridgeReady?: boolean;
  calleeDisclosure?: {
    enabled: boolean;
    requireAccept: boolean;
    accepted: boolean;
    status: "disabled" | "waiting_for_callee_acceptance" | "accepted" | "declined" | "failed";
  };
}

export interface PSTNProvider {
  name: PSTNProviderName;
  startOutboundCall(input: PSTNOutboundCallInput): Promise<PSTNOutboundCallResult>;
}
