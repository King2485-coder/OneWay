/**
 * Structured logging. Uses pino if installed; falls back to a console-based
 * shim that emits the same shape so call sites never branch on availability.
 *
 * Two surfaces:
 *  - `logger`: app-wide singleton. Shape: `logger.info({ ...fields }, message)`
 *  - `httpLogger`: Express middleware that adds a per-request child logger,
 *     records method/path/status/latency, and never logs request bodies.
 */

interface LogFn {
  (obj: object, msg?: string): void;
  (msg: string): void;
}
export interface Logger {
  fatal: LogFn;
  error: LogFn;
  warn: LogFn;
  info: LogFn;
  debug: LogFn;
  child(bindings: Record<string, unknown>): Logger;
}

interface PinoModule {
  (opts?: object): Logger;
}

let pinoCache: PinoModule | null | undefined;
function loadPino(): PinoModule | null {
  if (pinoCache !== undefined) return pinoCache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    pinoCache = require("pino") as PinoModule;
  } catch {
    pinoCache = null;
  }
  return pinoCache;
}

function makeFallbackLogger(bindings: Record<string, unknown> = {}): Logger {
  const emit = (level: string, a: object | string, b?: string) => {
    const time = new Date().toISOString();
    if (typeof a === "string") {
      console.log(JSON.stringify({ level, time, msg: a, ...bindings }));
    } else {
      console.log(JSON.stringify({ level, time, msg: b, ...bindings, ...a }));
    }
  };
  return {
    fatal: (a: object | string, b?: string) => emit("fatal", a, b),
    error: (a: object | string, b?: string) => emit("error", a, b),
    warn:  (a: object | string, b?: string) => emit("warn", a, b),
    info:  (a: object | string, b?: string) => emit("info", a, b),
    debug: (a: object | string, b?: string) => {
      if (process.env.LOG_LEVEL === "debug") emit("debug", a, b);
    },
    child: (extra) => makeFallbackLogger({ ...bindings, ...extra }),
  } as Logger;
}

function buildLogger(): Logger {
  const pino = loadPino();
  if (!pino) return makeFallbackLogger({ app: "oneway-server" });
  return pino({
    level: process.env.LOG_LEVEL ?? (process.env.NODE_ENV === "production" ? "info" : "debug"),
    base: { app: "oneway-server" },
    redact: {
      paths: [
        "req.headers.authorization",
        "req.headers.cookie",
        "*.password",
        "*.passwordHash",
        "*.token",
        "*.voipToken",
      ],
      remove: true,
    },
  });
}

export const logger: Logger = buildLogger();

// ---- Express middleware ---------------------------------------------------

import type { Request, Response, NextFunction } from "express";
import crypto from "crypto";

export function httpLogger(req: Request, res: Response, next: NextFunction): void {
  const start = process.hrtime.bigint();
  const reqId = crypto.randomUUID();
  const child = logger.child({ reqId });
  (req as Request & { log: Logger }).log = child;
  res.setHeader("X-Request-Id", reqId);

  res.on("finish", () => {
    const ns = Number(process.hrtime.bigint() - start);
    const ms = Math.round(ns / 1_000_000);
    const level = res.statusCode >= 500 ? "error" : res.statusCode >= 400 ? "warn" : "info";
    child[level]({
      method: req.method,
      path: req.path,
      status: res.statusCode,
      latencyMs: ms,
    }, "http");
  });
  next();
}
