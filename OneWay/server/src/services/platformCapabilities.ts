import type { PrismaClient } from "@prisma/client";

import { logger } from "../lib/logger";

type CapabilityStatus = "live" | "beta" | "planned" | "needsProvider";

export type PlatformCapability = {
  id: string;
  group: string;
  title: string;
  summary: string;
  status: CapabilityStatus;
  privacyLevel: string;
  routeHint?: string;
};

export type PlatformCapabilityGroup = {
  title: string;
  icon: string;
  promise: string;
  capabilities: PlatformCapability[];
};

export function buildPlatformReadinessPayload() {
  return {
    updatedAt: new Date().toISOString(),
    headline: "OneWay does WhatsApp, plus private business infrastructure.",
    summary: "Messaging, calls, Walkie, Sites, Shops, AI, storage, and privacy controls are tracked as one connected platform so unfinished capabilities have clear owners instead of hidden gaps.",
    groups: platformCapabilityGroups,
  };
}

export async function ensurePlatformCapabilityTables(prisma: PrismaClient): Promise<void> {
  // These tables are intentionally idempotent runtime patches until the next full Prisma migration.
  // TODO: Replace runtime creation with generated Prisma models once backend API shape is finalized.
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "PlatformCapabilityState" (
      "id" TEXT PRIMARY KEY,
      "groupName" TEXT NOT NULL,
      "title" TEXT NOT NULL,
      "status" TEXT NOT NULL,
      "privacyLevel" TEXT NOT NULL,
      "routeHint" TEXT,
      "notes" TEXT,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "PlatformCapabilityState_group_status_idx" ON "PlatformCapabilityState"("groupName", "status")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "PrivacySetting" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "key" TEXT NOT NULL,
      "value" TEXT NOT NULL,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE UNIQUE INDEX IF NOT EXISTS "PrivacySetting_user_key_unique" ON "PrivacySetting"("userId", "key")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "AILog" (
      "id" TEXT PRIMARY KEY,
      "userId" TEXT NOT NULL,
      "action" TEXT NOT NULL,
      "contentScope" TEXT NOT NULL,
      "requiresDecryptedContent" BOOLEAN NOT NULL DEFAULT false,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "AILog_user_created_idx" ON "AILog"("userId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "CloudFile" (
      "id" TEXT PRIMARY KEY,
      "ownerId" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "mimeType" TEXT,
      "byteCount" INTEGER NOT NULL DEFAULT 0,
      "storageKey" TEXT NOT NULL,
      "encrypted" BOOLEAN NOT NULL DEFAULT true,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "CloudFile_owner_updated_idx" ON "CloudFile"("ownerId", "updatedAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "ScheduledMessage" (
      "id" TEXT PRIMARY KEY,
      "conversationId" TEXT NOT NULL,
      "senderId" TEXT NOT NULL,
      "body" TEXT NOT NULL,
      "scheduledFor" DATETIME NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'scheduled',
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ScheduledMessage_sender_status_idx" ON "ScheduledMessage"("senderId", "status", "scheduledFor")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "ChannelPost" (
      "id" TEXT PRIMARY KEY,
      "channelId" TEXT NOT NULL,
      "authorId" TEXT NOT NULL,
      "body" TEXT NOT NULL,
      "reactionCount" INTEGER NOT NULL DEFAULT 0,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "ChannelPost_channel_created_idx" ON "ChannelPost"("channelId", "createdAt")`);

  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS "WorkspaceItem" (
      "id" TEXT PRIMARY KEY,
      "workspaceId" TEXT NOT NULL,
      "type" TEXT NOT NULL,
      "title" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'open',
      "metadataJson" TEXT,
      "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updatedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await prisma.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS "WorkspaceItem_workspace_type_idx" ON "WorkspaceItem"("workspaceId", "type", "updatedAt")`);

  await seedPlatformCapabilities(prisma);
  logger.info({ groupCount: platformCapabilityGroups.length }, "[platform] capability tables ready");
}

async function seedPlatformCapabilities(prisma: PrismaClient): Promise<void> {
  for (const group of platformCapabilityGroups) {
    for (const item of group.capabilities) {
      await prisma.$executeRawUnsafe(
        `
        INSERT INTO "PlatformCapabilityState" ("id", "groupName", "title", "status", "privacyLevel", "routeHint", "notes", "updatedAt")
        VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT("id") DO UPDATE SET
          "groupName" = excluded."groupName",
          "title" = excluded."title",
          "status" = excluded."status",
          "privacyLevel" = excluded."privacyLevel",
          "routeHint" = excluded."routeHint",
          "updatedAt" = CURRENT_TIMESTAMP
        `,
        item.id,
        group.title,
        item.title,
        item.status,
        item.privacyLevel,
        item.routeHint ?? null,
        item.summary,
      );
    }
  }
}

const platformCapabilityGroups: PlatformCapabilityGroup[] = [
  {
    title: "Messaging",
    icon: "bubble.left.and.bubble.right.fill",
    promise: "Private chats with modern collaboration controls.",
    capabilities: [
      { id: "messages.direct", group: "Messaging", title: "One-on-one chats", summary: "Encrypted direct messaging through the existing messages service.", status: "live", privacyLevel: "E2EE ready", routeHint: "Chats" },
      { id: "messages.groups", group: "Messaging", title: "Group chats", summary: "Shared conversations, replies, mentions, reactions, and receipts.", status: "beta", privacyLevel: "Encrypted metadata-minimized", routeHint: "Communities" },
      { id: "messages.channels", group: "Messaging", title: "Channels and broadcasts", summary: "One-to-many posting, follower controls, and broadcast lists.", status: "planned", privacyLevel: "Sender controlled", routeHint: "Communities" },
      { id: "messages.rich", group: "Messaging", title: "Rich messages", summary: "Editing, delete for everyone, forwarding, stars, pins, drafts, polls, events, link previews, voice notes, documents, and location.", status: "beta", privacyLevel: "Local-first drafts", routeHint: "Chats" },
    ],
  },
  {
    title: "Voice and Video",
    icon: "phone.connection.fill",
    promise: "LiveKit, PSTN, voicemail, and Walkie in one calling layer.",
    capabilities: [
      { id: "calls.oneway", group: "Voice and Video", title: "HD voice and video", summary: "OneWay-to-OneWay calling through LiveKit with CallKit handoff.", status: "live", privacyLevel: "Call metadata protected", routeHint: "Calls" },
      { id: "calls.pstn", group: "Voice and Video", title: "PSTN and SIP", summary: "Phone-network calling with provider preflight and SIP bridge support.", status: "beta", privacyLevel: "Number privacy supported", routeHint: "Calls" },
      { id: "calls.walkie", group: "Voice and Video", title: "Walkie Station", summary: "Push-to-talk mode with channels, activity, and privacy indicators.", status: "live", privacyLevel: "Private channels", routeHint: "Walkie" },
      { id: "calls.ai", group: "Voice and Video", title: "Call intelligence", summary: "Captions, transcription, summaries, and meeting notes behind AI permissions.", status: "planned", privacyLevel: "Explicit AI consent", routeHint: "AI" },
    ],
  },
  {
    title: "Privacy and Identity",
    icon: "lock.shield.fill",
    promise: "Privacy-first defaults with user-owned identity.",
    capabilities: [
      { id: "privacy.defaults", group: "Privacy and Identity", title: "Privacy controls", summary: "Hide phone number, usernames, read receipts, typing indicators, online status, and profile visibility.", status: "live", privacyLevel: "User controlled", routeHint: "Privacy" },
      { id: "privacy.lock", group: "Privacy and Identity", title: "Chat Lock and devices", summary: "Face ID/PIN unlock, linked devices, session management, and hidden chats.", status: "beta", privacyLevel: "Device protected", routeHint: "Settings" },
      { id: "privacy.safety", group: "Privacy and Identity", title: "Safety actions", summary: "Block, report, spam detection, audit logs, and security verification.", status: "live", privacyLevel: "Auditable", routeHint: "Safety" },
    ],
  },
  {
    title: "Business, Sites, and Shops",
    icon: "briefcase.fill",
    promise: "The WhatsApp business surface plus real storefronts and websites.",
    capabilities: [
      { id: "business.inbox", group: "Business, Sites, and Shops", title: "Business inbox", summary: "Quick replies, greeting/away messages, customer notes, labels, roles, and AI support.", status: "planned", privacyLevel: "Team scoped", routeHint: "Business" },
      { id: "sites.builder", group: "Business, Sites, and Shops", title: "OneWay Sites", summary: "AI builder, templates, editor, domains, analytics, forms, and publish checks.", status: "beta", privacyLevel: "Private pages supported", routeHint: "Sites" },
      { id: "shops.marketplace", group: "Business, Sites, and Shops", title: "Shops marketplace", summary: "Buyer-facing marketplace, seller studio, products, orders, carts, favorites, and payments abstraction.", status: "beta", privacyLevel: "Private by default", routeHint: "Business" },
    ],
  },
  {
    title: "Cloud, AI, and Workspace",
    icon: "sparkles",
    promise: "A private productivity layer that WhatsApp does not offer.",
    capabilities: [
      { id: "cloud.vault", group: "Cloud, AI, and Workspace", title: "Encrypted OneWay Cloud", summary: "Files, photos, shared folders, family/business vaults, secure links, and storage usage.", status: "planned", privacyLevel: "Encrypted storage", routeHint: "Storage" },
      { id: "ai.layer", group: "Cloud, AI, and Workspace", title: "OneWay AI", summary: "Summaries, suggested replies, translation, transcription, writing, image help, and cross-OneWay search.", status: "planned", privacyLevel: "Explicit decrypted-content warning", routeHint: "AI" },
      { id: "workspace.team", group: "Cloud, AI, and Workspace", title: "Workspace", summary: "Team chat, tasks, projects, calendar, notes, whiteboard placeholder, roles, and activity feed.", status: "planned", privacyLevel: "Role based", routeHint: "Workspace" },
    ],
  },
];
