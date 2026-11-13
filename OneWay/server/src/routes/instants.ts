import express, { type RequestHandler } from "express";
import type { PrismaClient } from "@prisma/client";
import rateLimit from "express-rate-limit";
import { z } from "zod";
import { createHash } from "node:crypto";
import { approvedContacts, mayCommunicate } from "../services/AccountVisibility";
import { encryptString, decryptString, isFieldEncryptionEnabled } from "../services/privacy/EncryptionService";
import { validCloudMedia } from "./cloudMedia";
import type { EmailAlertPushService } from "../services/EmailAlertPushService";

const maxPhoto = 512 * 1024;
const ttl = 24 * 60 * 60 * 1000;
const identifier = z.string().uuid().transform(v => v.toLowerCase());
const send = z.object({ id: identifier, recipients: z.array(z.string().min(1).max(64)).min(1).max(15), caption: z.string().trim().max(280).default(""), photo: z.string().min(1).max(700000) }).strict();
type Row = { id: string; senderId: string; ciphertext: string | null; fingerprint: string; createdAtMs: bigint | number; expiresAtMs: bigint | number };
class InstantError extends Error { constructor(readonly status: number, readonly code: string) { super(code); } }

export function instantsRouter(deps: { db: PrismaClient; authenticate: RequestHandler; alerts?: EmailAlertPushService; clock?: () => number }) {
  const { db } = deps; const now = deps.clock ?? Date.now; const router = express.Router();
  const uid = (req: express.Request) => (req as express.Request & {userId: string}).userId;
  const wrap = (fn: (req: express.Request, res: express.Response) => Promise<unknown>): RequestHandler => (req, res, next) => {
    fn(req, res).catch(error => {
      if (error instanceof z.ZodError) { res.status(400).json({ error: "invalid_instant" }); return; }
      if (error instanceof InstantError) { res.status(error.status).json({ error: error.code }); return; }
      if (error?.code === "P2002") { res.status(409).json({ error: "instant_conflict" }); return; }
      // Do not log images, captions, request bodies or encryption errors.
      res.status(503).json({ error: "instants_unavailable" });
    });
  };
  async function purge() {
    await db.$executeRawUnsafe(`DELETE FROM "InstantPhoto" WHERE "expiresAtMs" <= ? OR "senderId" NOT IN (SELECT "id" FROM "User" WHERE "accountStatus" = 'active')`, now());
  }
  const cleanup = setInterval(() => { void purge().catch(() => undefined); }, 60000); cleanup.unref();
  async function allowed(sender: string, recipient: string) {
    if (sender === recipient || !(await approvedContacts(db, sender)).includes(recipient) || !await mayCommunicate(db, sender, recipient)) return false;
    const active = await db.user.count({ where: { id: { in: [sender, recipient] }, accountStatus: "active" } });
    const blocked = await db.socialBlock.count({ where: { OR: [{blockerId: sender, blockedId: recipient}, {blockerId: recipient, blockedId: sender}] } });
    return active === 2 && blocked === 0;
  }
  router.get("/status", (_req, res) => res.json({ enabled: isFieldEncryptionEnabled(), version: 1, cameraOnly: true, expiresAfterHours: 24, viewOnce: true }));
  router.use(deps.authenticate);
  router.use((_req, res, next) => { res.set({"Cache-Control": "private, no-store, max-age=0", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff"}); next(); });
  router.use((req, res, next) => {
    (async () => {
      if (!isFieldEncryptionEnabled()) throw new InstantError(503, "instants_unavailable");
      if (!await db.user.findFirst({where: {id: uid(req), accountStatus: "active"}, select: {id: true}})) throw new InstantError(401, "account_not_active");
      await purge(); next();
    })().catch(error => res.status(error instanceof InstantError ? error.status : 503).json({error: error instanceof InstantError ? error.code : "instants_unavailable"}));
  });
  const writes = rateLimit({windowMs: 60000, limit: 12, standardHeaders: true, legacyHeaders: false, keyGenerator: req => uid(req)});
  const opens = rateLimit({windowMs: 60000, limit: 40, standardHeaders: true, legacyHeaders: false, keyGenerator: req => uid(req)});
  async function dto(row: Row, viewer: string, openedAtMs?: bigint | number | null) {
    const profile = await db.socialProfile.findUnique({where: {userId: row.senderId}, select: {displayName: true}});
    const user = profile ? null : await db.user.findUnique({where: {id: row.senderId}, select: {displayName: true}});
    const receipts = row.senderId === viewer ? await db.$queryRawUnsafe<{userId: string; openedAtMs: bigint | null}[]>(`SELECT "userId","openedAtMs" FROM "InstantRecipient" WHERE "instantId"=?`, row.id) : [];
    return {id: row.id, senderId: row.senderId, senderName: profile?.displayName || user?.displayName || "OneWay contact", createdAt: new Date(Number(row.createdAtMs)).toISOString(), expiresAt: new Date(Number(row.expiresAtMs)).toISOString(), isMine: row.senderId === viewer, opened: openedAtMs != null, recipientCount: receipts.length, openedCount: receipts.filter(r => r.openedAtMs != null).length};
  }
  router.get("/", wrap(async(req, res) => {
    const viewer = uid(req);
    const incoming = await db.$queryRawUnsafe<(Row & {openedAtMs: bigint | null})[]>(`SELECT p."id",p."senderId",p."createdAtMs",p."expiresAtMs",r."openedAtMs" FROM "InstantPhoto" p JOIN "InstantRecipient" r ON r."instantId"=p."id" WHERE r."userId"=? AND p."expiresAtMs">? ORDER BY p."createdAtMs" DESC LIMIT 100`, viewer, now());
    const sent = await db.$queryRawUnsafe<Row[]>(`SELECT "id","senderId","createdAtMs","expiresAtMs" FROM "InstantPhoto" WHERE "senderId"=? AND "expiresAtMs">? ORDER BY "createdAtMs" DESC LIMIT 50`, viewer, now());
    const visible = [];
    for (const row of incoming) if (await allowed(row.senderId, viewer)) visible.push(await dto(row, viewer, row.openedAtMs));
    res.json({incoming: visible, sent: await Promise.all(sent.map(row => dto(row, viewer)))});
  }));
  router.post("/", writes, wrap(async(req, res) => {
    const value = send.parse(req.body); const sender = uid(req); const recipients = [...new Set(value.recipients.map(v => /^[a-f0-9-]{36}$/i.test(v) ? v.toLowerCase() : v))].sort();
    const bytes = Buffer.from(value.photo, "base64");
    if (bytes.length > maxPhoto || bytes.length < 16 || bytes.toString("base64") !== value.photo || !validCloudMedia(bytes, "image/jpeg")) throw new InstantError(400, "invalid_instant_photo");
    for (const recipient of recipients) if (!await allowed(sender, recipient)) throw new InstantError(403, "approved_contact_required");
    const fingerprint = createHash("sha256").update(JSON.stringify([sender, recipients, value.caption, value.photo])).digest("hex");
    const existing = (await db.$queryRawUnsafe<Row[]>(`SELECT * FROM "InstantPhoto" WHERE "id"=?`, value.id))[0];
    if (existing) {
      if (existing.senderId !== sender || existing.fingerprint !== fingerprint) throw new InstantError(409, "instant_conflict");
      return res.json(await dto(existing, sender));
    }
    const count = await db.$queryRawUnsafe<{n: bigint}[]>(`SELECT COUNT(*) AS n FROM "InstantPhoto" WHERE "senderId"=? AND "expiresAtMs">?`, sender, now());
    if (Number(count[0].n) >= 50) throw new InstantError(429, "instant_limit");
    const total = await db.$queryRawUnsafe<{n: bigint | null}[]>(`SELECT SUM(LENGTH("ciphertext")) AS n FROM "InstantPhoto"`);
    if (Number(total[0]?.n ?? 0) > 512 * 1024 * 1024) throw new InstantError(503, "instants_storage_busy");
    const time = now(); const ciphertext = encryptString(JSON.stringify({caption: value.caption, photo: value.photo}), {purpose: "instant-photo", id: value.id, sender});
    await db.$transaction(async tx => {
      await tx.$executeRawUnsafe(`INSERT INTO "InstantPhoto" ("id","senderId","ciphertext","fingerprint","createdAtMs","expiresAtMs") VALUES (?,?,?,?,?,?)`, value.id, sender, ciphertext, fingerprint, time, time + ttl);
      for (const recipient of recipients) await tx.$executeRawUnsafe(`INSERT INTO "InstantRecipient" ("instantId","userId") VALUES (?,?)`, value.id, recipient);
    });
    for (const recipient of recipients) void deps.alerts?.sendInstant({userId: recipient, instantId: value.id}).catch(() => undefined);
    res.status(201).json(await dto({id:value.id,senderId:sender,ciphertext,fingerprint,createdAtMs:time,expiresAtMs:time+ttl}, sender));
  }));
  router.post("/:id/open", opens, wrap(async(req, res) => {
    const id = identifier.parse(req.params.id), viewer = uid(req);
    const row = (await db.$queryRawUnsafe<Row[]>(`SELECT p.* FROM "InstantPhoto" p JOIN "InstantRecipient" r ON r."instantId"=p."id" WHERE p."id"=? AND r."userId"=?`, id, viewer))[0];
    if (!row || !await allowed(row.senderId, viewer)) throw new InstantError(404, "instant_not_found");
    if (!row.ciphertext || Number(row.expiresAtMs) <= now()) throw new InstantError(410, "instant_unavailable");
    const payload = JSON.parse(decryptString(row.ciphertext, {purpose: "instant-photo", id, sender: row.senderId})) as {photo: string; caption: string};
    await db.$transaction(async tx => {
      const changed = await tx.$executeRawUnsafe(`UPDATE "InstantRecipient" SET "openedAtMs"=? WHERE "instantId"=? AND "userId"=? AND "openedAtMs" IS NULL AND EXISTS (SELECT 1 FROM "InstantPhoto" WHERE "id"=? AND "ciphertext" IS NOT NULL AND "expiresAtMs">?)`, now(), id, viewer, id, now());
      if (changed !== 1) throw new InstantError(410, "instant_unavailable");
      await tx.$executeRawUnsafe(`UPDATE "InstantPhoto" SET "ciphertext"=NULL WHERE "id"=? AND NOT EXISTS (SELECT 1 FROM "InstantRecipient" WHERE "instantId"=? AND "openedAtMs" IS NULL)`, id, id);
    });
    res.json({photo: payload.photo, caption: payload.caption});
  }));
  router.delete("/:id", writes, wrap(async(req, res) => {
    const id = identifier.parse(req.params.id);
    const changed = await db.$executeRawUnsafe(`DELETE FROM "InstantPhoto" WHERE "id"=? AND "senderId"=?`, id, uid(req));
    if (!changed) throw new InstantError(404, "instant_not_found");
    res.status(204).end();
  }));
  return router;
}
