import express, { type RequestHandler } from "express";
import type { Prisma, PrismaClient } from "@prisma/client";
import { z } from "zod";
import rateLimit from "express-rate-limit";

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
}).strict();
const postSchema = z.object({ body: z.string().trim().min(1).max(2000), audience: z.enum(["public", "followers"]).default("followers"), clientId: z.string().uuid().optional() }).strict();
const reportSchema = z.object({ reason: z.enum(["spam", "harassment", "harmful_content", "other"]) }).strict();
const active = { accountStatus: "active", publicProfileHiddenAt: null };
const identifier = z.string().min(1).max(64);
const pageSchema = z.object({ limit: z.coerce.number().int().min(1).max(50).default(20), before: z.string().datetime().optional(), beforeId: z.string().max(64).optional(), q: z.string().trim().max(100).default("") })
  .refine(v => Boolean(v.before) === Boolean(v.beforeId), "A cursor needs both before and beforeId");

/** Shared social API. Public posts are server-readable; this does not reuse DM storage. */
export function socialRouter(deps: { prisma: PrismaClient; authenticate: RequestHandler; enabled?: () => boolean }) {
  const { prisma } = deps;
  const router = express.Router();
  const enabled = deps.enabled ?? (() => process.env.ONEWAY_SOCIAL_ENABLED === "true");
  router.get("/status", (_req, res) => { res.json({ enabled: enabled(), version: 1 }); });
  router.use((req, res, next) => { if (!enabled()) { res.status(503).json({ error: "social_not_enabled" }); return; } next(); });
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
    return { user: active, userId: { notIn: await excluded(viewer) }, OR: [{ discoverable: true }, { userId: viewer }] };
  }
  async function visiblePosts(viewer: string): Promise<Prisma.SocialPostWhereInput> {
    return { author: await visibleProfiles(viewer), OR: [{ authorId: viewer }, { audience: "public" },
      { audience: "followers", author: { followers: { some: { followerId: viewer } } } }] };
  }
  async function profileDTO(profile: { userId: string; handle: string; displayName: string; bio: string; website: string; discoverable: boolean }, viewer: string) {
    const [followers, following, posts, followed] = await Promise.all([
      prisma.socialFollow.count({ where: { followingId: profile.userId, follower: { user: active } } }),
      prisma.socialFollow.count({ where: { followerId: profile.userId, following: { user: active } } }),
      prisma.socialPost.count({ where: { AND: [await visiblePosts(viewer), { authorId: profile.userId }] } }),
      prisma.socialFollow.findUnique({ where: { followerId_followingId: { followerId: viewer, followingId: profile.userId } } }),
    ]);
    return { ...profile, followers, following, postCount: posts, isFollowing: Boolean(followed), isMe: profile.userId === viewer };
  }
  const authorSelect = { userId: true, handle: true, displayName: true } as const;
  router.get("/me", wrap(async (req, res) => {
    const profile = await prisma.socialProfile.findUnique({ where: { userId: uid(req) } });
    res.json({ profile: profile ? await profileDTO(profile, uid(req)) : null });
  }));
  router.put("/me", writes, wrap(async (req, res) => {
    const data = profileSchema.parse(req.body);
    if (["admin", "support", "oneway", "security", "official"].includes(data.handle)) return res.status(409).json({ error: "handle_unavailable" });
    const profile = await prisma.socialProfile.upsert({ where: { userId: uid(req) }, create: { ...data, userId: uid(req) }, update: data });
    res.json({ profile: await profileDTO(profile, uid(req)) });
  }));
  router.get("/people", wrap(async (req, res) => {
    const page = pageSchema.parse(req.query);
    const profiles = await prisma.socialProfile.findMany({ where: { AND: [await visibleProfiles(uid(req)), { discoverable: true },
      { OR: [{ handle: { contains: page.q.toLowerCase() } }, { displayName: { contains: page.q } }] }] }, orderBy: { handle: "asc" }, take: page.limit });
    res.json({ profiles: await Promise.all(profiles.map(p => profileDTO(p, uid(req)))) });
  }));
  router.get("/profiles/:handle", wrap(async (req, res) => {
    const handle = identifier.parse(req.params.handle).toLowerCase();
    const profile = await prisma.socialProfile.findFirst({ where: { AND: [await visibleProfiles(uid(req)), { handle }] } });
    if (!profile) return res.status(404).json({ error: "profile_not_found" });
    const posts = await prisma.socialPost.findMany({ where: { AND: [await visiblePosts(uid(req)), { authorId: profile.userId }] }, include: { author: { select: authorSelect } }, orderBy: [{ createdAt: "desc" }, { id: "desc" }], take: 20 });
    res.json({ profile: await profileDTO(profile, uid(req)), posts });
  }));
  router.get("/feed", wrap(async (req, res) => {
    const page = pageSchema.parse(req.query);
    const mode = z.enum(["following", "discover"]).default("following").parse(req.query.mode);
    const scope: Prisma.SocialPostWhereInput = mode === "discover" ? { audience: "public", author: { discoverable: true } }
      : { OR: [{ authorId: uid(req) }, { author: { followers: { some: { followerId: uid(req) } } } }] };
    const cursor: Prisma.SocialPostWhereInput = page.before ? { OR: [{ createdAt: { lt: new Date(page.before) } }, { createdAt: new Date(page.before), id: { lt: page.beforeId } }] } : {};
    const posts = await prisma.socialPost.findMany({ where: { AND: [await visiblePosts(uid(req)), scope, cursor] }, include: { author: { select: authorSelect } }, orderBy: [{ createdAt: "desc" }, { id: "desc" }], take: page.limit + 1 });
    const hasMore = posts.length > page.limit; const items = posts.slice(0, page.limit); const last = items.at(-1);
    res.json({ posts: items, next: hasMore && last ? { before: last.createdAt.toISOString(), beforeId: last.id } : null });
  }));
  router.post("/posts", writes, wrap(async (req, res) => {
    const data = postSchema.parse(req.body);
    const profile = await prisma.socialProfile.findUnique({ where: { userId: uid(req) } });
    if (!profile) return res.status(409).json({ error: "profile_required" });
    if (data.audience === "public" && !profile.discoverable) return res.status(409).json({ error: "public_profile_required" });
    if (data.clientId) {
      const previous = await prisma.socialPost.findUnique({ where: { id: data.clientId }, include: { author: { select: authorSelect } } });
      if (previous) {
        if (previous.authorId !== uid(req) || previous.body !== data.body || previous.audience !== data.audience) return res.status(409).json({ error: "post_request_conflict" });
        return res.json({ post: previous });
      }
    }
    const post = await prisma.socialPost.create({ data: { id: data.clientId, body: data.body, audience: data.audience, authorId: uid(req) }, include: { author: { select: authorSelect } } });
    res.status(201).json({ post });
  }));
  router.delete("/posts/:id", writes, wrap(async (req, res) => {
    const result = await prisma.socialPost.deleteMany({ where: { id: identifier.parse(req.params.id), authorId: uid(req) } });
    res.status(result.count ? 204 : 404).end();
  }));
  async function target(viewer: string, targetId: string) {
    return prisma.socialProfile.findFirst({ where: { AND: [await visibleProfiles(viewer), { userId: targetId, discoverable: true }] } });
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
