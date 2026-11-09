import express from "express";
import { z } from "zod";

import { prisma } from "../lib/db";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import { recordAuditEvent } from "../services/audit/AuditEventService";

const targetSchema = z.object({
  handle: z.string().trim().min(2).max(128),
});

const reportSchema = targetSchema.extend({
  reason: z.string().trim().min(3).max(1_000),
});

const privacyPresetSchema = z.object({
  preset: z.enum(["Open", "Contacts Only", "Locked Down"]),
});

const storyAudienceSchema = z.object({
  scope: z.enum(["Friends", "Everyone"]),
});

export function safetyRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/blocked", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const blocked = await prisma.oneWayContact.findMany({
      where: { userId, status: "blocked" },
      select: { contactUserId: true },
      orderBy: { blockedAt: "desc" },
    });
    const targetIds = blocked.map((contact) => contact.contactUserId);
    const identities = targetIds.length === 0 ? [] : await prisma.oneWayIdentity.findMany({
      where: { userId: { in: targetIds } },
      select: { userId: true, onewayId: true },
    });
    const handlesByUserId = new Map(identities.map((identity) => [identity.userId, identity.onewayId]));
    res.json({ handles: targetIds.map((id) => handlesByUserId.get(id) ?? "OneWay user") });
  });

  router.post("/block", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = targetSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const target = await resolveUser(parsed.data.handle);
    if (!target || target.id === userId) {
      res.status(404).json({ error: "oneway_user_not_found" });
      return;
    }

    const blockedAt = new Date();
    await prisma.$transaction([
      prisma.oneWayContact.upsert({
        where: { userId_contactUserId: { userId, contactUserId: target.id } },
        update: { status: "blocked", direction: "blocked", blockedAt, removedAt: null },
        create: { userId, contactUserId: target.id, status: "blocked", direction: "blocked", blockedAt },
      }),
      prisma.oneWayContact.upsert({
        where: { userId_contactUserId: { userId: target.id, contactUserId: userId } },
        update: { status: "blocked", direction: "blocked", blockedAt, removedAt: null },
        create: { userId: target.id, contactUserId: userId, status: "blocked", direction: "blocked", blockedAt },
      }),
    ]);
    res.json({ ok: true, handle: target.handle });
  });

  router.post("/report", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = reportSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const target = await resolveUser(parsed.data.handle);
    const event = await recordAuditEvent(prisma, {
      actorId: userId,
      actorType: "user",
      action: "safety.report.created",
      resourceType: "user_report",
      resourceId: target?.id ?? null,
      metadata: {
        reportedHandle: target?.handle ?? parsed.data.handle,
        reason: parsed.data.reason,
        targetResolved: Boolean(target),
        reviewStatus: "pending",
      },
    });
    res.status(201).json({ ok: true, reportId: event.id });
  });

  router.post("/privacy-preset", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = privacyPresetSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    const settings = presetSettings(parsed.data.preset);
    await prisma.walkiePrivacySettings.upsert({
      where: { userId },
      update: settings,
      create: { userId, ...settings },
    });
    res.json({ ok: true, preset: parsed.data.preset });
  });

  router.post("/session-kill-switch", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await prisma.$transaction([
      prisma.pushToken.deleteMany({ where: { userId } }),
      prisma.chirpTrustPermission.deleteMany({ where: { ownerUserId: userId } }),
      prisma.directChirpRequest.updateMany({
        where: { OR: [{ senderUserId: userId }, { recipientUserId: userId }], status: "pending" },
        data: { status: "cancelled", cancelledAt: new Date() },
      }),
      prisma.walkiePrivacySettings.upsert({
        where: { userId },
        update: presetSettings("Locked Down"),
        create: { userId, ...presetSettings("Locked Down") },
      }),
    ]);
    res.json({ ok: true });
  });

  router.get("/story-audience", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const latest = await prisma.oneWayNetworkEvent.findFirst({
      where: { userId, type: "privacy.story_audience" },
      orderBy: { createdAt: "desc" },
      select: { metadata: true },
    });
    const scope = parseStoryScope(latest?.metadata);
    res.json({ scope });
  });

  router.post("/story-audience", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    const parsed = storyAudienceSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }
    await prisma.oneWayNetworkEvent.create({
      data: { userId, type: "privacy.story_audience", metadata: JSON.stringify({ scope: parsed.data.scope }) },
    });
    res.json({ ok: true, scope: parsed.data.scope });
  });

  return router;
}

async function resolveUser(raw: string): Promise<{ id: string; handle: string } | null> {
  const value = raw.trim();
  const normalizedHandle = value.toLowerCase().replace(/^@?/, "@");
  const normalizedChirp = value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  const user = await prisma.user.findFirst({
    where: {
      OR: [
        { id: value },
        { email: { equals: value.toLowerCase() } },
        { chirpIdNormalized: normalizedChirp },
        { identity: { is: { onewayId: normalizedHandle } } },
        { identity: { is: { username: value.replace(/^@/, "") } } },
      ],
    },
    select: { id: true, identity: { select: { onewayId: true } }, chirpId: true },
  });
  if (!user) return null;
  return { id: user.id, handle: user.identity?.onewayId ?? user.chirpId ?? "OneWay user" };
}

function presetSettings(preset: "Open" | "Contacts Only" | "Locked Down") {
  if (preset === "Open") {
    return { allowFriends: true, allowFriendsOfFriends: true, allowAnyone: true, allowDirectChirp: true, directChirpAudience: "anyone", silenceUnknownChirps: false, blockUnknownDuringDnd: false };
  }
  if (preset === "Locked Down") {
    return { allowFriends: true, allowFriendsOfFriends: false, allowAnyone: false, allowDirectChirp: false, directChirpAudience: "nobody", silenceUnknownChirps: true, blockUnknownDuringDnd: true };
  }
  return { allowFriends: true, allowFriendsOfFriends: false, allowAnyone: false, allowDirectChirp: true, directChirpAudience: "friends", silenceUnknownChirps: true, blockUnknownDuringDnd: true };
}

function parseStoryScope(metadata: string | null | undefined): "Friends" | "Everyone" {
  try {
    const scope = JSON.parse(metadata ?? "{}")?.scope;
    return scope === "Everyone" ? "Everyone" : "Friends";
  } catch {
    return "Friends";
  }
}
