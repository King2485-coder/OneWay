import express from "express";
import { authMiddleware, type AuthenticatedRequest } from "../middleware/auth";
import type { CallHistoryService } from "../services/CallHistoryService";

interface HistoryRouterDeps {
  history: CallHistoryService;
}

export function historyRouter(deps: HistoryRouterDeps): express.Router {
  const router = express.Router();
  router.use(authMiddleware);

  // GET /api/history/recent --------------------------------------------------
  // Caller's own recent activity. Defaults to last 50.
  router.get("/recent", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const limit = clampLimit(req.query.limit);
    res.json({ entries: deps.history.forUser(userId, { limit }) });
  });

  // GET /api/history/:userId -------------------------------------------------
  // Returns the requesting user's view of their own history. The `:userId`
  // path param is here for parity with the spec; we still verify it matches
  // the authenticated id, otherwise users could enumerate each other.
  router.get("/:userId", (req, res, next) => {
    if (req.params.userId === "recent") return next(); // skip if matched above
    const userId = (req as unknown as AuthenticatedRequest).userId;
    if (req.params.userId !== userId) {
      res.status(403).json({ error: "forbidden" });
      return;
    }
    res.json({ entries: deps.history.forUser(userId) });
  });

  // GET /api/history/call/:callId --------------------------------------------
  // Look up a single entry. Both directions live in the store; we serve the
  // one that belongs to the requesting user.
  router.get("/call/:callId", (req, res) => {
    const userId = (req as unknown as AuthenticatedRequest).userId;
    const entry = deps.history.forCallId(req.params.callId, userId);
    if (!entry) {
      res.status(404).json({ error: "not_found" });
      return;
    }
    res.json({ entry });
  });

  return router;
}

function clampLimit(value: unknown): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 50;
  return Math.min(Math.floor(n), 500);
}
