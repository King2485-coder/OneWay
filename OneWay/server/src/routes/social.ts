import { ghostMode, ghostUsers, approvedContacts } from "../services/AccountVisibility";
import { contactOptions, selectedContact, contactDisplayKey } from "../services/SocialProfileContact";
import express, { type RequestHandler } from "express";
import type { Prisma, PrismaClient } from "@prisma/client";
import { z } from "zod";
import rateLimit from "express-rate-limit";
import { createHash, randomUUID } from "node:crypto";
import type { ObjectStorage } from "../lib/storage/ObjectStorage";
import { LocalObjectStorage } from "../lib/storage/LocalObjectStorage";
import { S3ObjectStorage } from "../lib/storage/S3ObjectStorage";
import { decryptString, isFieldEncryptionEnabled } from "../services/privacy/EncryptionService";
import { validCloudMedia } from "./cloudMedia";

const pageDesignSchema = z.object({
  background: z.enum(["quantum", "metal", "midnight"]),
  layout: z.enum(["classic", "spotlight"]),
  photoShape: z.enum(["rounded", "circle"]),
}).strict();
const defaultPageDesign = {background: "quantum", layout: "classic", photoShape: "rounded"} as const;
const profileSchema = z.object({
  handle: z.string().trim().toLowerCase().regex(/^[a-z][a-z0-9_]{2,29}$/),
  displayName: z.string().trim().min(1).max(64),
  bio: z.string().trim().max(280).default(""),
  website: z.string().trim().max(500).default("").refine(value => {
    if (!value) return true;
    try { const u = new URL(value); return u.protocol === "https:" && !u.username && !u.password; }
    catch { return false; }
  }),
  discoverable: z.boolean().default(false),
  contactDisplay: z.string().regex(/^(none|onewayId|chirpId|emailAlias|number:[a-fA-F0-9-]{36})$/).optional(),
  accent: z.enum(["violet", "blue", "teal", "rose", "amber"]).optional(),
  pinnedSiteId: z.string().uuid().nullable().optional(),
  pageDesign: pageDesignSchema.optional(),
  avatarFileId: z.string().uuid().nullable().optional(),
  coverFileId: z.string().uuid().nullable().optional(),
}).strict();
const postSchema = z.object({ body: z.string().trim().min(1).max(2000), audience: z.enum(["public", "followers"]).default("followers"), clientId: z.string().uuid().optional() }).strict();
const editPostSchema = z.object({body: z.string().trim().min(1).max(2000), audience: z.enum(["public", "followers"]).optional(), expectedBody: z.string().min(1).max(2000), expectedAudience: z.enum(["public", "followers"])}).strict();
const reportSchema = z.object({ reason: z.enum(["spam", "harassment", "harmful_content", "other"]) }).strict();
const active = { accountStatus: "active", publicProfileHiddenAt: null };
const identifier = z.string().min(1).max(64);
const pageSchema = z.object({ limit: z.coerce.number().int().min(1).max(50).default(20), before: z.string().datetime().optional(), beforeId: z.string().max(64).optional(), q: z.string().trim().max(100).default("") })
  .refine(v => Boolean(v.before) === Boolean(v.beforeId), "A cursor needs both before and beforeId");

/** Shared social API. Public posts are server-readable; this does not reuse DM storage. */
export function socialRouter(deps: { prisma: PrismaClient; authenticate: RequestHandler; enabled?: () => boolean; storage?: ObjectStorage | null }) {
  const { prisma } = deps;
  const router = express.Router();
  const storage = deps.storage === undefined ? (process.env.ONEWAY_PRIVATE_CLOUD_DIR ? new LocalObjectStorage({ root: process.env.ONEWAY_PRIVATE_CLOUD_DIR }) : S3ObjectStorage.fromEnv()) : deps.storage;
  const mediaReady = () => Boolean(storage) && isFieldEncryptionEnabled();
  const mediaKeys = { avatar: "social.profile.avatar", cover: "social.profile.cover" } as const;
  const prefix = (owner: string) => `private-media/${createHash("sha256").update(owner).digest("hex")}/`;
  const version = (file: { id: string; updatedAt: unknown }) => createHash("sha256").update(file.id + String(file.updatedAt)).digest("hex").slice(0, 24);
  async function mediaFile(owner: string, kind: keyof typeof mediaKeys) {
    const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT f.* FROM "CloudFile" f JOIN "PrivacySetting" p ON p."userId" = f."ownerId" AND p."value" = f."id" WHERE p."userId" = ? AND p."key" = ? LIMIT 1`, owner, mediaKeys[kind]);
    const f = rows[0];
    return f && f.encrypted && f.storageKey.startsWith(prefix(owner)) && ["image/jpeg", "image/png"].includes(f.mimeType) && Number(f.byteCount) <= 256 * 1024 ? f : null;
  }
  const enabled = deps.enabled ?? (() => process.env.ONEWAY_SOCIAL_ENABLED === "true");
  router.get("/status", (_req, res) => { res.json({ enabled: enabled(), version: 6, pageDesign: true, ghostMode: true, contactDisplay: true, postEditing: true, postAvatars: true, profileMedia: mediaReady(), profileCustomization: true }); });
  router.use((req, res, next) => { if (!enabled()) { res.status(503).json({ error: "social_not_enabled" }); return; } next(); });
  router.use((_req, res, next) => { res.set("Cache-Control", "private, no-store"); next(); });
  router.use(deps.authenticate);
  const uid = (req: express.Request) => (req as express.Request & { userId: string }).userId;
  const wrap = (action: (req: express.Request, res: express.Response) => Promise<unknown>): RequestHandler => (req, res, next) => {
    action(req, res).catch(error => {
      if (error instanceof z.ZodError) { res.status(400).json({ error: "invalid_request" }); return; }
      if (error?.code === "P2002") { res.status(409).json({ error: "handle_unavailable" }); return; }
      if (error?.code === "P2025") { res.status(404).json({ error: "not_found" }); return; }
      next(error);
    });
  };
  // Also enforce lifecycle rules for development sessions and injected test auth.
  router.use((req, res, next) => {
    prisma.user.findFirst({ where: { id: uid(req), ...active }, select: { id: true } })
      .then(user => { if (user) next(); else res.status(401).json({ error: "account_not_active" }); }).catch(next);
  });
  const writes = rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: true, legacyHeaders: false,
    keyGenerator: req => uid(req), message: { error: "too_many_social_changes" } });

  async function excluded(viewer: string) {
    const blocks = await prisma.socialBlock.findMany({ where: { OR: [{ blockerId: viewer }, { blockedId: viewer }] } });
    return blocks.map(b => b.blockerId === viewer ? b.blockedId : b.blockerId);
  }
  async function visibleProfiles(viewer: string): Promise<Prisma.SocialProfileWhereInput> {
    const [hidden, approved] = await Promise.all([ghostUsers(prisma), approvedContacts(prisma, viewer)]);
    return {user: active, userId: {notIn: await excluded(viewer)}, OR: [
      {userId: viewer}, {userId: {in: approved.filter(id => hidden.includes(id))}},
      {discoverable: true, userId: {notIn: hidden}}
    ]};
  }
  async function visiblePosts(viewer: string): Promise<Prisma.SocialPostWhereInput> {
    return { author: await visibleProfiles(viewer), OR: [{ authorId: viewer }, { audience: "public" },
      { audience: "followers", author: { followers: { some: { followerId: viewer } } } }] };
  }
  const lookKey = "social.profile.look";
  async function profileLook(owner: string) {
    const rows = await prisma.$queryRawUnsafe<{value: string}[]>(`SELECT "value" FROM "PrivacySetting" WHERE "userId" = ? AND "key" = ? LIMIT 1`, owner, lookKey);
    try { return JSON.parse(rows[0]?.value ?? "{}") as {accent?: string; pinnedSiteId?: string | null; pageDesign?: unknown}; } catch { return {}; }
  }
  // Only a current public publication owned by this profile may be featured.
  async function pinnableSite(owner: string, id: string) {
    const site = await prisma.site.findFirst({where: {id, userId: owner, status: "PUBLISHED", visibility: "PUBLIC", publishedAt: {not: null}, activePublicationId: {not: null}}});
    if (!site || !site.slug || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(site.slug)) return null;
    const publication = await prisma.sitePublication.findFirst({where: {id: site.activePublicationId!, siteId: site.id, status: "ACTIVE"}});
    if (!publication) return null;
    return {id: site.id, title: site.title || site.slug, address: `oneway://${site.slug}`};
  }
  router.get("/pin-sites", wrap(async (req, res) => {
    const sites = await prisma.site.findMany({where: {userId: uid(req), status: "PUBLISHED", visibility: "PUBLIC"}, orderBy: {updatedAt: "desc"}, take: 100});
    res.set("Cache-Control", "private, no-store").json({sites: (await Promise.all(sites.map(site => pinnableSite(uid(req), site.id)))).filter(Boolean)});
  }));
  async function profileDTO(profile: { userId: string; handle: string; displayName: string; bio: string; website: string; discoverable: boolean }, viewer: string) {
    const [followers, following, posts, followed] = await Promise.all([
      prisma.socialFollow.count({ where: { followingId: profile.userId, follower: { user: active } } }),
      prisma.socialFollow.count({ where: { followerId: profile.userId, following: { user: active } } }),
      prisma.socialPost.count({ where: { AND: [await visiblePosts(viewer), { authorId: profile.userId }] } }),
      prisma.socialFollow.findUnique({ where: { followerId_followingId: { followerId: viewer, followingId: profile.userId } } }),
    ]);
    // Return only opaque versions. Private cloud IDs/keys never enter the public DTO.
    const [avatar, cover] = await Promise.all([mediaFile(profile.userId, "avatar"), mediaFile(profile.userId, "cover")]).catch(() => [null, null]);
    const look = await profileLook(profile.userId);
    const pageDesign = pageDesignSchema.safeParse(look.pageDesign);
    const pinnedWebsite = look.pinnedSiteId ? await pinnableSite(profile.userId, look.pinnedSiteId) : null;
    return { ...profile, ghostMode: await ghostMode(prisma, profile.userId), publicContact: await selectedContact(prisma, profile.userId), ...(profile.userId === viewer ? {contactDisplay: (await prisma.$queryRawUnsafe<{value:string}[]>(`SELECT "value" FROM "PrivacySetting" WHERE "userId"=? AND "key"=? LIMIT 1`, viewer, contactDisplayKey))[0]?.value ?? "none"} : {}), accent: ["violet", "blue", "teal", "rose", "amber"].includes(look.accent ?? "") ? look.accent : "violet", pinnedWebsite, pageDesign: pageDesign.success ? pageDesign.data : defaultPageDesign, avatarVersion: avatar ? version(avatar) : null, coverVersion: cover ? version(cover) : null,
      followers, following, postCount: posts, isFollowing: Boolean(followed), isMe: profile.userId === viewer };
  }
  async function postDTO<T extends {author: {userId: string; handle: string; displayName: string}}>(post: T) {
    const avatar = await mediaFile(post.author.userId, "avatar").catch(() => null);
    return {...post, author: {...post.author, publicContact: await selectedContact(prisma, post.author.userId), avatarVersion: avatar ? version(avatar) : null}};
  }
  const authorSelect = { userId: true, handle: true, displayName: true } as const;
  router.get("/contact-options", wrap(async (req, res) => { res.json({options: await contactOptions(prisma, uid(req))}); }));
  router.get("/me", wrap(async (req, res) => {
    const profile = await prisma.socialProfile.findUnique({ where: { userId: uid(req) } });
    res.json({ profile: profile ? await profileDTO(profile, uid(req)) : null });
  }));
  router.put("/me", writes, wrap(async (req, res) => {
    const { avatarFileId, coverFileId, accent, pinnedSiteId, contactDisplay, pageDesign, ...data } = profileSchema.parse(req.body);
    if (contactDisplay !== undefined && !(await contactOptions(prisma, uid(req))).some(o => o.key === contactDisplay)) return res.status(400).json({error: "invalid_contact_choice"});
    const updates = [["avatar", avatarFileId], ["cover", coverFileId]] as const;
    if (updates.some(([, id]) => id !== undefined) && !mediaReady()) return res.status(503).json({ error: "profile_media_unavailable" });
    // A client uploads a fresh, reduced JPEG copy; linking cannot claim another owner's object.
    for (const [, id] of updates) if (id) {
      const rows = await prisma.$queryRawUnsafe<any[]>(`SELECT * FROM "CloudFile" WHERE "id" = ? AND "ownerId" = ? LIMIT 1`, id, uid(req));
      const file = rows[0];
      if (!file || !file.encrypted || !file.storageKey.startsWith(prefix(uid(req))) || !["image/jpeg", "image/png"].includes(file.mimeType) || Number(file.byteCount) > 256 * 1024) return res.status(400).json({ error: "invalid_profile_media" });
    }
    if (["admin", "support", "oneway", "security", "official"].includes(data.handle)) return res.status(409).json({ error: "handle_unavailable" });
    if (pinnedSiteId && !await pinnableSite(uid(req), pinnedSiteId)) return res.status(400).json({error: "site_not_public_or_owned"});
    const profile = await prisma.$transaction(async tx => {
      const saved = await tx.socialProfile.upsert({ where: { userId: uid(req) }, create: { ...data, userId: uid(req) }, update: data });
      for (const [kind, id] of updates) {
        if (id === undefined) continue; // Older clients preserve photos.
        if (id === null) await tx.$executeRawUnsafe(`DELETE FROM "PrivacySetting" WHERE "userId" = ? AND "key" = ?`, uid(req), mediaKeys[kind]);
        else await tx.$executeRawUnsafe(`INSERT INTO "PrivacySetting" ("id", "userId", "key", "value", "updatedAt") VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP) ON CONFLICT("userId", "key") DO UPDATE SET "value" = excluded."value", "updatedAt" = CURRENT_TIMESTAMP`, randomUUID(), uid(req), mediaKeys[kind], id);
      }
      if (accent !== undefined || pinnedSiteId !== undefined || pageDesign !== undefined) {
        const rows = await tx.$queryRawUnsafe<{value: string}[]>(`SELECT "value" FROM "PrivacySetting" WHERE "userId" = ? AND "key" = ? LIMIT 1`, uid(req), lookKey);
        let previous: Record<string, unknown> = {}; try { previous = JSON.parse(rows[0]?.value ?? "{}"); } catch {}
        const value = JSON.stringify({...previous, ...(accent !== undefined ? {accent} : {}), ...(pinnedSiteId !== undefined ? {pinnedSiteId} : {}), ...(pageDesign !== undefined ? {pageDesign} : {})});
        await tx.$executeRawUnsafe(`INSERT INTO "PrivacySetting" ("id", "userId", "key", "value", "updatedAt") VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP) ON CONFLICT("userId", "key") DO UPDATE SET "value" = excluded."value", "updatedAt" = CURRENT_TIMESTAMP`, randomUUID(), uid(req), lookKey, value);
      }
      if (contactDisplay !== undefined) await tx.$executeRawUnsafe(`INSERT INTO "PrivacySetting" ("id","userId","key","value","updatedAt") VALUES (?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT("userId","key") DO UPDATE SET "value"=excluded."value","updatedAt"=CURRENT_TIMESTAMP`, randomUUID(), uid(req), contactDisplayKey, contactDisplay);
      return saved;
    });
    res.json({ profile: await profileDTO(profile, uid(req)) });
  }));
  router.get("/people", wrap(async (req, res) => {
    const page = pageSchema.parse(req.query);
    const profiles = await prisma.socialProfile.findMany({ where: { AND: [await visibleProfiles(uid(req)), { discoverable: true, userId: {notIn: await ghostUsers(prisma)} },
      { OR: [{ handle: { contains: page.q.toLowerCase() } }, { displayName: { contains: page.q } }] }] }, orderBy: { handle: "asc" }, take: page.limit });
    res.json({ profiles: await Promise.all(profiles.map(p => profileDTO(p, uid(req)))) });
  }));
  router.get("/profiles/:handle/media/:kind", wrap(async (req, res) => {
    res.set({ "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" });
    const kind = z.enum(["avatar", "cover"]).parse(req.params.kind);
    const handle = identifier.parse(req.params.handle).toLowerCase();
    const profile = await prisma.socialProfile.findFirst({ where: { AND: [await visibleProfiles(uid(req)), { handle }] } });
    if (!profile || !mediaReady()) return res.status(404).end();
    const file = await mediaFile(profile.userId, kind);
    if (!file || typeof req.query.v !== "string" || req.query.v !== version(file)) return res.status(404).end();
    const object = await storage!.read(file.storageKey);
    if (!object) return res.status(404).end();
    const chunks: Buffer[] = []; let count = 0;
    for await (const chunk of object.stream) {
      const bytes = Buffer.from(chunk); count += bytes.length;
      if (count > 1024 * 1024) { object.stream.destroy(); return res.status(413).end(); }
      chunks.push(bytes);
    }
    const bytes = Buffer.from(decryptString(Buffer.concat(chunks).toString(), { purpose: "cloud-media", owner: profile.userId, id: file.id }), "base64");
    if (bytes.length !== Number(file.byteCount) || !validCloudMedia(bytes, file.mimeType)) return res.status(404).end();
    res.set({ "Content-Type": file.mimeType, "Content-Disposition": "inline" }).send(bytes);
  }));
  router.get("/profiles/:handle", wrap(async (req, res) => {
    const handle = identifier.parse(req.params.handle).toLowerCase();
    const profile = await prisma.socialProfile.findFirst({ where: { AND: [await visibleProfiles(uid(req)), { handle }] } });
    if (!profile) return res.status(404).json({ error: "profile_not_found" });
    const posts = await prisma.socialPost.findMany({ where: { AND: [await visiblePosts(uid(req)), { authorId: profile.userId }] }, include: { author: { select: authorSelect } }, orderBy: [{ createdAt: "desc" }, { id: "desc" }], take: 20 });
    res.json({ profile: await profileDTO(profile, uid(req)), posts: await Promise.all(posts.map(postDTO)) });
  }));
  router.get("/feed", wrap(async (req, res) => {
    const page = pageSchema.parse(req.query);
    const mode = z.enum(["following", "discover"]).default("following").parse(req.query.mode);
    const scope: Prisma.SocialPostWhereInput = mode === "discover" ? { audience: "public", author: { discoverable: true, userId: {notIn: await ghostUsers(prisma)} } }
      : { OR: [{ authorId: uid(req) }, { author: { followers: { some: { followerId: uid(req) } } } }] };
    const cursor: Prisma.SocialPostWhereInput = page.before ? { OR: [{ createdAt: { lt: new Date(page.before) } }, { createdAt: new Date(page.before), id: { lt: page.beforeId } }] } : {};
    const posts = await prisma.socialPost.findMany({ where: { AND: [await visiblePosts(uid(req)), scope, cursor] }, include: { author: { select: authorSelect } }, orderBy: [{ createdAt: "desc" }, { id: "desc" }], take: page.limit + 1 });
    const hasMore = posts.length > page.limit; const items = posts.slice(0, page.limit); const last = items.at(-1);
    res.json({ posts: await Promise.all(items.map(postDTO)), next: hasMore && last ? { before: last.createdAt.toISOString(), beforeId: last.id } : null });
  }));
  router.post("/posts", writes, wrap(async (req, res) => {
    const data = postSchema.parse(req.body);
    const profile = await prisma.socialProfile.findUnique({ where: { userId: uid(req) } });
    if (!profile) return res.status(409).json({ error: "profile_required" });
    if (data.audience === "public" && await ghostMode(prisma, uid(req))) return res.status(409).json({error: "ghost_mode_active"});
    if (data.audience === "public" && !profile.discoverable) return res.status(409).json({ error: "public_profile_required" });
    if (data.clientId) {
      const previous = await prisma.socialPost.findUnique({ where: { id: data.clientId }, include: { author: { select: authorSelect } } });
      if (previous) {
        if (previous.authorId !== uid(req) || previous.body !== data.body || previous.audience !== data.audience) return res.status(409).json({ error: "post_request_conflict" });
        return res.json({ post: await postDTO(previous) });
      }
    }
    const post = await prisma.socialPost.create({ data: { id: data.clientId, body: data.body, audience: data.audience, authorId: uid(req) }, include: { author: { select: authorSelect } } });
    res.status(201).json({ post: await postDTO(post) });
  }));
  router.patch("/posts/:id", writes, wrap(async (req, res) => {
    const id = identifier.parse(req.params.id), data = editPostSchema.parse(req.body);
    const current = await prisma.socialPost.findFirst({where: {id, authorId: uid(req)}, include: {author: {select: authorSelect}}});
    if (!current) return res.status(404).json({error: "post_not_found"});
    const audience = data.audience ?? current.audience;
    const profile = await prisma.socialProfile.findUnique({where: {userId: uid(req)}});
    if (audience === "public" && await ghostMode(prisma, uid(req))) return res.status(409).json({error: "ghost_mode_active"});
    if (audience === "public" && !profile?.discoverable) return res.status(409).json({error: "public_profile_required"});
    if (current.body === data.body && current.audience === audience) return res.json({post: await postDTO(current)});
    const saved = await prisma.socialPost.updateMany({where: {id, authorId: uid(req), body: data.expectedBody, audience: data.expectedAudience}, data: {body: data.body, audience}});
    if (!saved.count) return res.status(409).json({error: "post_changed", message: "This post changed. Refresh it before editing again."});
    const post = await prisma.socialPost.findUnique({where: {id}, include: {author: {select: authorSelect}}});
    if (!post) return res.status(404).json({error: "post_not_found"});
    res.json({post: await postDTO(post)});
  }));
  router.delete("/posts/:id", writes, wrap(async (req, res) => {
    const result = await prisma.socialPost.deleteMany({ where: { id: identifier.parse(req.params.id), authorId: uid(req) } });
    res.status(result.count ? 204 : 404).end();
  }));
  async function target(viewer: string, targetId: string) {
    return prisma.socialProfile.findFirst({ where: { AND: [await visibleProfiles(viewer), { userId: targetId }] } });
  }
  router.put("/following/:id", writes, wrap(async (req, res) => {
    const followingId = identifier.parse(req.params.id);
    if (followingId === uid(req)) return res.status(400).json({ error: "cannot_follow_self" });
    if (!await prisma.socialProfile.findUnique({ where: { userId: uid(req) } })) return res.status(409).json({ error: "profile_required" });
    if (!await target(uid(req), followingId)) return res.status(404).json({ error: "profile_not_found" });
    await prisma.socialFollow.upsert({ where: { followerId_followingId: { followerId: uid(req), followingId } }, create: { followerId: uid(req), followingId }, update: {} });
    res.status(204).end();
  }));
  router.delete("/following/:id", writes, wrap(async (req, res) => {
    await prisma.socialFollow.deleteMany({ where: { followerId: uid(req), followingId: identifier.parse(req.params.id) } }); res.status(204).end();
  }));
  router.put("/blocks/:id", writes, wrap(async (req, res) => {
    const blockedId = identifier.parse(req.params.id);
    if (blockedId === uid(req)) return res.status(400).json({ error: "cannot_block_self" });
    if (!await prisma.socialProfile.findUnique({ where: { userId: uid(req) } }) || !await target(uid(req), blockedId)) return res.status(404).json({ error: "profile_not_found" });
    await prisma.$transaction([
      prisma.socialBlock.upsert({ where: { blockerId_blockedId: { blockerId: uid(req), blockedId } }, create: { blockerId: uid(req), blockedId }, update: {} }),
      prisma.socialFollow.deleteMany({ where: { OR: [{ followerId: uid(req), followingId: blockedId }, { followerId: blockedId, followingId: uid(req) }] } }),
    ]); res.status(204).end();
  }));
  router.get("/blocks", wrap(async (req, res) => {
    const blocks = await prisma.socialBlock.findMany({ where: { blockerId: uid(req) }, include: { blocked: { select: authorSelect } }, take: 100 });
    res.json({ profiles: blocks.map(b => b.blocked) });
  }));
  router.delete("/blocks/:id", writes, wrap(async (req, res) => {
    await prisma.socialBlock.deleteMany({ where: { blockerId: uid(req), blockedId: identifier.parse(req.params.id) } }); res.status(204).end();
  }));
  router.post("/posts/:id/reports", writes, wrap(async (req, res) => {
    const { reason } = reportSchema.parse(req.body); const postId = identifier.parse(req.params.id);
    if (!await prisma.socialProfile.findUnique({ where: { userId: uid(req) } })) return res.status(409).json({ error: "profile_required" });
    if (!await prisma.socialPost.findFirst({ where: { AND: [await visiblePosts(uid(req)), { id: postId }] } })) return res.status(404).json({ error: "post_not_found" });
    await prisma.socialReport.upsert({ where: { reporterId_postId: { reporterId: uid(req), postId } }, create: { reporterId: uid(req), postId, reason }, update: { reason } });
    res.status(202).json({ status: "received", message: "Report received for review." });
  }));
  return router;
}
