import express from "express";
import { z } from "zod";
import type { PrismaClient } from "@prisma/client";
import { ghostMode, setGhostMode } from "../services/AccountVisibility";
import type { AuthenticatedRequest } from "../middleware/auth";
export function accountVisibilityRouter(db: PrismaClient) {
  const router = express.Router();
  router.use((_req, res, next) => { res.set("Cache-Control", "private, no-store"); next(); });
  router.get("/", async (req, res, next) => { try { res.json({ghostMode: await ghostMode(db, (req as AuthenticatedRequest).userId)}); } catch(e) { next(e); } });
  router.patch("/", async (req, res, next) => {
    const input = z.object({ghostMode: z.boolean()}).strict().safeParse(req.body);
    if (!input.success) return res.status(400).json({error: "invalid_visibility"});
    try { await setGhostMode(db, (req as AuthenticatedRequest).userId, input.data.ghostMode); res.json(input.data); } catch(e) { next(e); }
  });
  return router;
}
