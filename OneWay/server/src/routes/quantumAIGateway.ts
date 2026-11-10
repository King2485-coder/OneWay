import express, { type RequestHandler } from "express";
import { timingSafeEqual } from "node:crypto";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";

export function gatewaySecretMatches(actual: string | undefined, expected: string): boolean {
  const supplied = Buffer.from((actual ?? "").replace(/^Bearer\s+/i, ""));
  const secret = Buffer.from(expected);
  return secret.length >= 32 && supplied.length === secret.length && timingSafeEqual(supplied, secret);
}

/** The Mac registers a short-lived tunnel; account checks stay on the live API. */
export function quantumAIGatewayRouter(options: { secret: string; authenticate?: RequestHandler; clock?: () => number; forward?: typeof fetch }) {
  const router = express.Router();
  const now = options.clock ?? Date.now;
  const forward = options.forward ?? fetch;
  let origin: { url: string; seen: number } | undefined;
  router.post("/gateway-register", (req, res) => {
    res.set("Cache-Control", "no-store");
    if (!gatewaySecretMatches(req.header("authorization"), options.secret)) { res.status(401).json({ error: "unauthenticated" }); return; }
    const url = req.body?.origin;
    if (typeof url !== "string" || !/^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(url)) { res.status(400).json({ error: "invalid_gateway" }); return; }
    origin = { url, seen: now() };
    res.status(204).end();
  });
  router.use(options.authenticate ?? authMiddleware);
  router.use(async (req, res) => {
    res.set("Cache-Control", "no-store");
    const userId = (req as AuthenticatedRequest).userId;
    if (!/^[A-Za-z0-9_:.\-]{1,64}$/.test(userId ?? "")) { res.status(401).json({ error: "unauthenticated" }); return; }
    if (!["GET", "POST"].includes(req.method) || !/^\/(config|chat|files|tools|exports|artifacts(?:\/[0-9a-f-]{36}\/content)?|jobs\/[0-9a-f-]{36})$/.test(req.path)) { res.status(404).end(); return; }
    if (!origin || now() - origin.seen > 120_000) { res.status(503).json({ error: "ai_unavailable" }); return; }
    try {
      const result = await forward(origin.url + "/api/quantum-ai" + req.path, {
        method: req.method, redirect: "error", signal: AbortSignal.timeout(185_000),
        headers: { Authorization: `Bearer ${options.secret}`, "x-oneway-gateway-user": userId, "Content-Type": "application/json" },
        ...(req.method === "POST" ? { body: JSON.stringify(req.body) } : {}),
      });
      for (const key of ["content-type", "content-disposition", "content-security-policy", "x-content-type-options"]) {
        const value = result.headers.get(key); if (value) res.set(key, value);
      }
      res.status(result.status).send(Buffer.from(await result.arrayBuffer()));
    } catch { res.status(503).json({ error: "ai_unavailable" }); }
  });
  return router;
}
