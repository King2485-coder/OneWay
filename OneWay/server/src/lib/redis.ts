/**
 * Optional Redis client + pub/sub channel. Enabled by setting `REDIS_URL`.
 * Falls back to `null` so the rest of the app boots happily without Redis
 * for single-instance deployments.
 *
 * Uses `ioredis` if installed; the API used here is small enough that
 * swapping for `node-redis` requires only a minor rewrite.
 */

import { logger } from "./logger";

export interface RedisClientLike {
  set(key: string, value: string, ...args: (string | number)[]): Promise<unknown>;
  get(key: string): Promise<string | null>;
  del(...keys: string[]): Promise<unknown>;
  sadd(key: string, ...members: string[]): Promise<unknown>;
  srem(key: string, ...members: string[]): Promise<unknown>;
  smembers(key: string): Promise<string[]>;
  expire(key: string, seconds: number): Promise<unknown>;
  publish(channel: string, message: string): Promise<unknown>;
  subscribe(channel: string): Promise<unknown>;
  on(event: "message", listener: (channel: string, message: string) => void): void;
  duplicate(): RedisClientLike;
  quit(): Promise<unknown>;
}

interface IORedisCtor {
  new (url: string): RedisClientLike;
}

let cached: RedisClientLike | null | undefined;
let subscriber: RedisClientLike | null | undefined;

function loadCtor(): IORedisCtor | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require("ioredis");
    return (mod.default ?? mod) as IORedisCtor;
  } catch {
    return null;
  }
}

export function redis(): RedisClientLike | null {
  if (cached !== undefined) return cached;
  const url = process.env.REDIS_URL;
  if (!url) {
    cached = null;
    return null;
  }
  const Ctor = loadCtor();
  if (!Ctor) {
    cached = null;
    logger.warn({}, "[redis] ioredis not installed — Redis features disabled");
    return null;
  }
  try {
    cached = new Ctor(url);
    logger.info({}, "[redis] connected");
    return cached;
  } catch (err) {
    logger.error({ err }, "[redis] connect failed");
    cached = null;
    return null;
  }
}

export function redisSubscriber(): RedisClientLike | null {
  if (subscriber !== undefined) return subscriber;
  const main = redis();
  if (!main) {
    subscriber = null;
    return null;
  }
  // ioredis: a connection in subscribe mode can't issue normal commands,
  // so duplicate the connection for pub/sub.
  subscriber = main.duplicate();
  return subscriber;
}

export async function shutdownRedis(): Promise<void> {
  await cached?.quit();
  await subscriber?.quit();
  cached = null;
  subscriber = null;
}
