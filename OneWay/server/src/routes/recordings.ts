import express from "express";
import { z } from "zod";
import { EgressClient, EncodedFileOutput, S3Upload } from "livekit-server-sdk";

import { prisma } from "../lib/db";
import { logger } from "../lib/logger";
import { authMiddleware } from "../middleware/auth";

const startSchema = z.object({
  roomName: z.string().min(1).max(200),
});

const stopSchema = z.object({
  egressId: z.string().min(1).max(200),
});

function buildEgressClient(): EgressClient | null {
  const host = process.env.LIVEKIT_HOST;
  const apiKey = process.env.LIVEKIT_API_KEY;
  const apiSecret = process.env.LIVEKIT_API_SECRET;

  if (!host || !apiKey || !apiSecret) {
    return null;
  }

  return new EgressClient(host, apiKey, apiSecret);
}

function buildRecordingOutput(roomName: string): { output: EncodedFileOutput; fileUrl: string } | null {
  const accessKey = process.env.AWS_ACCESS_KEY_ID ?? process.env.S3_ACCESS_KEY_ID;
  const secret = process.env.AWS_SECRET_ACCESS_KEY ?? process.env.S3_SECRET_ACCESS_KEY;
  const region = process.env.AWS_REGION ?? process.env.S3_REGION;
  const bucket = process.env.S3_RECORDINGS_BUCKET ?? process.env.S3_BUCKET;
  const endpoint = process.env.S3_ENDPOINT ?? "";
  const forcePathStyle = process.env.S3_FORCE_PATH_STYLE === "true";

  if (!accessKey || !secret || !region || !bucket) {
    return null;
  }

  const safeRoomName = roomName.replace(/[^a-zA-Z0-9-_]/g, "-").slice(0, 120);
  const filepath = `recordings/${safeRoomName}-${Date.now()}.mp4`;
  const fileUrl = process.env.S3_RECORDINGS_PUBLIC_BASE_URL
    ? `${process.env.S3_RECORDINGS_PUBLIC_BASE_URL.replace(/\/$/, "")}/${filepath}`
    : `https://${bucket}.s3.${region}.amazonaws.com/${filepath}`;

  return {
    output: new EncodedFileOutput({
      filepath,
      output: {
        case: "s3",
        value: new S3Upload({
          accessKey,
          secret,
          region,
          endpoint,
          bucket,
          forcePathStyle,
        }),
      },
    }),
    fileUrl,
  };
}

export function recordingsRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.post("/start", async (req, res) => {
    const parsed = startSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const client = buildEgressClient();
    const recordingOutput = buildRecordingOutput(parsed.data.roomName);

    if (!client || !recordingOutput) {
      res.status(503).json({ error: "recording_not_configured" });
      return;
    }

    try {
      const egress = await client.startRoomCompositeEgress(
        parsed.data.roomName,
        recordingOutput.output
      );

      await prisma.recording.create({
        data: {
          roomName: parsed.data.roomName,
          fileUrl: recordingOutput.fileUrl,
          egressId: egress.egressId,
          status: "recording",
        },
    });

    res.json({ ok: true, egressId: egress.egressId });
  } catch (error) {
    logger.error({ err: error }, "[recordings] start failed");
    res.status(500).json({ error: "recording_start_failed" });
  }
  });

  router.post("/stop", async (req, res) => {
    const parsed = stopSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const client = buildEgressClient();
    if (!client) {
      res.status(503).json({ error: "recording_not_configured" });
      return;
    }

    try {
      await client.stopEgress(parsed.data.egressId);
      await prisma.recording.updateMany({
        where: { egressId: parsed.data.egressId },
        data: { status: "completed" },
      });
      res.json({ ok: true });
    } catch (error) {
      logger.error({ err: error }, "[recordings] stop failed");
      res.status(500).json({ error: "recording_stop_failed" });
    }
  });

  router.get("/", async (_req, res) => {
    const recordings = await prisma.recording.findMany({
      orderBy: { createdAt: "desc" },
    });

    res.json(recordings);
  });

  return router;
}
