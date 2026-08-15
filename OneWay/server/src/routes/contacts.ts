import express from "express";
import { z } from "zod";
import type { OneWayContact, PrismaClient } from "@prisma/client";
import { prisma } from "../lib/db";
import { addColumnIfMissing } from "../lib/runtimeSchemaPatch";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import {
  chirpLookupCandidates,
  ensureUserChirpId,
  ensureUserRecord,
  loadPublicIdentity,
  normalizeOneWayId,
} from "../services/identity";

const addContactSchema = z.object({
  handle: z.string().trim().min(2).max(64),
});

const updateContactSchema = z.object({
  displayName: z.string().trim().max(64).nullable().optional(),
  nickname: z.string().trim().max(64).nullable().optional(),
});

type ContactStatus = "pending" | "connected" | "blocked" | "removed";

interface OneWayContactDTO {
  contactId: string;
  id: string;
  displayName: string;
  handle: string;
  chirpId: string | null;
  status: ContactStatus;
  isIncoming: boolean;
  nickname: string | null;
}

export async function ensureOneWayContactLifecycleColumns(client: PrismaClient): Promise<void> {
  await addColumnIfMissing(client, {
    table: "OneWayContact",
    columnDefinition: `"acceptedAt" TIMESTAMP`,
    logPrefix: "oneway contact schema patch",
  });
  await addColumnIfMissing(client, {
    table: "OneWayContact",
    columnDefinition: `"removedAt" TIMESTAMP`,
    logPrefix: "oneway contact schema patch",
  });
  await addColumnIfMissing(client, {
    table: "OneWayContact",
    columnDefinition: `"blockedAt" TIMESTAMP`,
    logPrefix: "oneway contact schema patch",
  });
}

export function contactsRouter(): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  router.get("/", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const contacts = await prisma.oneWayContact.findMany({
      where: {
        userId,
        NOT: { status: "removed" },
      },
      orderBy: [{ status: "asc" }, { updatedAt: "desc" }],
    });

    res.json({ contacts: await mapContacts(contacts) });
  });

  router.post("/", async (req, res) => {
    const userId = (req as AuthenticatedRequest).userId;
    await ensureUserRecord(userId);

    const parsed = addContactSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const target = await resolveContactTarget(parsed.data.handle, userId);

    if (!target) {
      res.status(404).json({
        error: "oneway_contact_not_found",
        message: "No OneWay user was found for that handle or Chirp ID.",
      });
      return;
    }

    if (target.userId === userId) {
      res.status(400).json({
        error: "self_contact_forbidden",
        message: "You cannot add yourself as a OneWay contact.",
      });
      return;
    }

    const existing = await prisma.oneWayContact.findUnique({
      where: {
        userId_contactUserId: {
          userId,
          contactUserId: target.userId,
        },
      },
    });

    if (existing?.status === "blocked") {
      res.status(403).json({
        error: "contact_blocked",
        message: "This contact is blocked.",
      });
      return;
    }

    if (existing?.status === "connected") {
      res.json({ contact: await mapContact(existing) });
      return;
    }

    if (existing?.status === "pending" && existing.direction === "incoming") {
      const accepted = await connectPair(userId, target.userId);
      res.json({ contact: await mapContact(accepted) });
      return;
    }

    const [requesterContact] = await prisma.$transaction([
      prisma.oneWayContact.upsert({
        where: {
          userId_contactUserId: {
            userId,
            contactUserId: target.userId,
          },
        },
        update: {
          status: "pending",
          direction: "outgoing",
          removedAt: null,
          blockedAt: null,
          acceptedAt: null,
        },
        create: {
          userId,
          contactUserId: target.userId,
          status: "pending",
          direction: "outgoing",
        },
      }),
      prisma.oneWayContact.upsert({
        where: {
          userId_contactUserId: {
            userId: target.userId,
            contactUserId: userId,
          },
        },
        update: {
          status: "pending",
          direction: "incoming",
          removedAt: null,
          blockedAt: null,
          acceptedAt: null,
        },
        create: {
          userId: target.userId,
          contactUserId: userId,
          status: "pending",
          direction: "incoming",
        },
      }),
    ]);

    res.status(existing ? 200 : 201).json({ contact: await mapContact(requesterContact) });
  });

  router.post("/:contactId/accept", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const contact = await prisma.oneWayContact.findFirst({
      where: {
        id: req.params.contactId,
        userId,
      },
    });

    if (!contact) {
      res.status(404).json({ error: "contact_not_found" });
      return;
    }

    if (contact.status !== "pending" || contact.direction !== "incoming") {
      res.status(409).json({
        error: "contact_not_acceptable",
        message: "Only incoming pending contact requests can be accepted.",
      });
      return;
    }

    const accepted = await connectPair(userId, contact.contactUserId);
    res.json({ contact: await mapContact(accepted) });
  });

  router.patch("/:contactId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const parsed = updateContactSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "invalid_body", issues: parsed.error.issues });
      return;
    }

    const requestedName = parsed.data.displayName ?? parsed.data.nickname;
    const nickname = sanitizeNickname(requestedName);
    const contact = await prisma.oneWayContact.updateMany({
      where: {
        id: req.params.contactId,
        userId,
      },
      data: { nickname },
    });

    if (contact.count === 0) {
      res.status(404).json({ error: "contact_not_found" });
      return;
    }

    const updated = await prisma.oneWayContact.findUniqueOrThrow({
      where: { id: req.params.contactId },
    });
    res.json({ contact: await mapContact(updated) });
  });

  router.delete("/:contactId", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const contact = await prisma.oneWayContact.findFirst({
      where: {
        id: req.params.contactId,
        userId,
      },
    });

    if (!contact) {
      res.status(404).json({ error: "contact_not_found" });
      return;
    }

    await prisma.oneWayContact.updateMany({
      where: {
        OR: [
          { userId, contactUserId: contact.contactUserId },
          { userId: contact.contactUserId, contactUserId: userId },
        ],
      },
      data: {
        status: "removed",
        direction: "removed",
        removedAt: new Date(),
      },
    });

    res.json({ ok: true });
  });

  router.post("/:contactId/block", async (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const contact = await prisma.oneWayContact.findFirst({
      where: {
        id: req.params.contactId,
        userId,
      },
    });

    if (!contact) {
      res.status(404).json({ error: "contact_not_found" });
      return;
    }

    const blockedAt = new Date();
    const [blocked] = await prisma.$transaction([
      prisma.oneWayContact.upsert({
        where: {
          userId_contactUserId: {
            userId,
            contactUserId: contact.contactUserId,
          },
        },
        update: {
          status: "blocked",
          direction: "blocked",
          blockedAt,
          removedAt: null,
        },
        create: {
          userId,
          contactUserId: contact.contactUserId,
          status: "blocked",
          direction: "blocked",
          blockedAt,
        },
      }),
      prisma.oneWayContact.upsert({
        where: {
          userId_contactUserId: {
            userId: contact.contactUserId,
            contactUserId: userId,
          },
        },
        update: {
          status: "blocked",
          direction: "blocked",
          blockedAt,
          removedAt: null,
        },
        create: {
          userId: contact.contactUserId,
          contactUserId: userId,
          status: "blocked",
          direction: "blocked",
          blockedAt,
        },
      }),
    ]);

    res.json({ contact: await mapContact(blocked) });
  });

  return router;
}

async function connectPair(userId: string, contactUserId: string): Promise<OneWayContact> {
  const acceptedAt = new Date();
  const [accepted] = await prisma.$transaction([
    prisma.oneWayContact.upsert({
      where: {
        userId_contactUserId: {
          userId,
          contactUserId,
        },
      },
      update: {
        status: "connected",
        direction: "connected",
        acceptedAt,
        removedAt: null,
        blockedAt: null,
      },
      create: {
        userId,
        contactUserId,
        status: "connected",
        direction: "connected",
        acceptedAt,
      },
    }),
    prisma.oneWayContact.upsert({
      where: {
        userId_contactUserId: {
          userId: contactUserId,
          contactUserId: userId,
        },
      },
      update: {
        status: "connected",
        direction: "connected",
        acceptedAt,
        removedAt: null,
        blockedAt: null,
      },
      create: {
        userId: contactUserId,
        contactUserId: userId,
        status: "connected",
        direction: "connected",
        acceptedAt,
      },
    }),
  ]);

  return accepted;
}

async function resolveContactTarget(rawValue: string, requesterUserId: string): Promise<{ userId: string } | null> {
  const value = rawValue.trim();
  if (!value) return null;

  const chirpCandidates = chirpLookupCandidates(value);
  if (chirpCandidates.length > 0 && chirpCandidates.some((candidate) => /^OW[0-9]{6,9}$/.test(candidate))) {
    const byChirp = await prisma.user.findFirst({
      where: { chirpIdNormalized: { in: chirpCandidates } },
      select: { id: true },
    });
    if (byChirp) return { userId: byChirp.id };
  }

  if (value.startsWith("@")) {
    const identity = await prisma.oneWayIdentity.findUnique({
      where: { onewayId: normalizeOneWayId(value) },
      select: { userId: true },
    });
    if (identity) return { userId: identity.userId };
  }

  if (!value.includes("@") && /^[A-Za-z0-9_.-]{2,64}$/.test(value)) {
    const byBareHandle = await prisma.oneWayIdentity.findUnique({
      where: { onewayId: normalizeOneWayId(`@${value}`) },
      select: { userId: true },
    });
    if (byBareHandle) return { userId: byBareHandle.userId };
  }

  if (value.includes("@")) {
    const emailAlias = value.toLowerCase().endsWith("@oneway.app")
      ? value.toLowerCase()
      : null;
    if (emailAlias) {
      const byAlias = await prisma.oneWayIdentity.findFirst({
        where: {
          emailAlias,
          showEmailAlias: true,
        },
        select: { userId: true },
      });
      if (byAlias) return { userId: byAlias.userId };
    }
  }

  const phone = normalizePhoneTarget(value);
  if (phone) {
    const number = await prisma.userNumber.findFirst({
      where: {
        number: phone,
        user: {
          identity: {
            is: { showNumbers: true },
          },
        },
      },
      select: { userId: true },
    });
    if (number) return { userId: number.userId };
  }

  const displayLookup = value.replace(/\s+/g, " ").trim();
  if (displayLookup.length >= 2 && displayLookup.length <= 64) {
    const identity = await prisma.oneWayIdentity.findFirst({
      where: {
        OR: [
          { usernameHidden: false, username: { equals: displayLookup } },
          { displayName: { equals: displayLookup } },
          { walkieName: { equals: displayLookup } },
        ],
      },
      select: { userId: true },
      orderBy: { updatedAt: "desc" },
    });
    if (identity && identity.userId !== requesterUserId) return { userId: identity.userId };
  }

  return null;
}

async function mapContacts(contacts: OneWayContact[]): Promise<OneWayContactDTO[]> {
  const mapped = await Promise.all(contacts.map(mapContact));
  return mapped.sort((left, right) => {
    if (left.status !== right.status) return left.status === "connected" ? -1 : 1;
    return left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" });
  });
}

async function mapContact(contact: OneWayContact): Promise<OneWayContactDTO> {
  const identity = await loadPublicIdentity(contact.contactUserId);
  const chirpId = await ensureUserChirpId(prisma, contact.contactUserId);
  const nickname = sanitizeNickname(contact.nickname);
  return {
    contactId: contact.id,
    id: contact.contactUserId,
    displayName: nickname ?? identity.displayName,
    handle: identity.onewayId,
    chirpId,
    status: mapContactStatus(contact.status),
    isIncoming: contact.status === "pending" && contact.direction === "incoming",
    nickname,
  };
}

function mapContactStatus(status: string): ContactStatus {
  switch (status) {
  case "connected":
    return "connected";
  case "blocked":
    return "blocked";
  case "removed":
    return "removed";
  default:
    return "pending";
  }
}

function sanitizeNickname(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? "";
  return trimmed.length === 0 ? null : trimmed;
}

function normalizePhoneTarget(value: string): string | null {
  const trimmed = value.trim();
  if (/^\+\d{10,15}$/.test(trimmed)) return trimmed;

  const digits = trimmed.replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}
