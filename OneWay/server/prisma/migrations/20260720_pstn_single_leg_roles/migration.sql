ALTER TABLE "CallSession" ADD COLUMN "callerRole" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "calleeRole" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "twilioCallSid" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "callerOneWayNumber" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "destinationNumber" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "callerLiveKitIdentity" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "pstnLiveKitIdentity" TEXT;
ALTER TABLE "CallSession" ADD COLUMN "callerCallKitUUID" TEXT;

CREATE INDEX "CallSession_twilioCallSid_idx" ON "CallSession"("twilioCallSid");
