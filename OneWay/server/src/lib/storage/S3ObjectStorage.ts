/**
 * S3 / Cloudflare R2 backed `ObjectStorage`.
 *
 * R2 is S3-compatible — point `S3_ENDPOINT` at `https://<account>.r2.cloudflarestorage.com`
 * and set `region: "auto"`. Same code, different env.
 *
 * Required env:
 *   S3_BUCKET           bucket name
 *   S3_REGION           e.g. "us-east-1" or "auto" (R2)
 *   S3_ACCESS_KEY_ID
 *   S3_SECRET_ACCESS_KEY
 *   S3_ENDPOINT         optional — set for R2 / non-AWS
 *   S3_FORCE_PATH_STYLE optional — "true" for some R2 / minio configs
 *   S3_PUBLIC_URL_BASE  optional — if the bucket is fronted by a CDN, use
 *                       this for download URLs instead of presigning
 */

import type { Readable } from "stream";
import type { ObjectStorage } from "./ObjectStorage";
import { StorageError } from "./ObjectStorage";
import { logger } from "../logger";

interface S3ClientOptions {
  region: string;
  endpoint?: string;
  forcePathStyle?: boolean;
  credentials: { accessKeyId: string; secretAccessKey: string };
}

interface S3Client {
  send(cmd: object): Promise<unknown>;
}

interface S3Module {
  S3Client: new (opts: S3ClientOptions) => S3Client;
  PutObjectCommand: new (opts: object) => object;
  GetObjectCommand: new (opts: object) => object;
  DeleteObjectCommand: new (opts: object) => object;
}

interface PresignerModule {
  getSignedUrl(client: S3Client, command: object, opts?: { expiresIn: number }): Promise<string>;
}

let s3Cache: S3Module | null | undefined;
let presignerCache: PresignerModule | null | undefined;

function loadS3(): { s3: S3Module; presigner: PresignerModule } | null {
  if (s3Cache !== undefined && presignerCache !== undefined) {
    if (s3Cache && presignerCache) return { s3: s3Cache, presigner: presignerCache };
    return null;
  }
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    s3Cache = require("@aws-sdk/client-s3") as S3Module;
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    presignerCache = require("@aws-sdk/s3-request-presigner") as PresignerModule;
    return { s3: s3Cache, presigner: presignerCache };
  } catch {
    s3Cache = null;
    presignerCache = null;
    logger.warn({}, "[storage] @aws-sdk/client-s3 not installed — S3 backend unavailable");
    return null;
  }
}

export class S3ObjectStorage implements ObjectStorage {
  private client: S3Client;
  private bucket: string;
  private publicUrlBase: string | null;

  constructor(opts: {
    bucket: string;
    region: string;
    accessKeyId: string;
    secretAccessKey: string;
    endpoint?: string;
    forcePathStyle?: boolean;
    publicUrlBase?: string;
  }) {
    const sdk = loadS3();
    if (!sdk) throw new StorageError("sdk_missing", "@aws-sdk/client-s3 not installed");
    this.client = new sdk.s3.S3Client({
      region: opts.region,
      endpoint: opts.endpoint,
      forcePathStyle: opts.forcePathStyle,
      credentials: { accessKeyId: opts.accessKeyId, secretAccessKey: opts.secretAccessKey },
    });
    this.bucket = opts.bucket;
    this.publicUrlBase = opts.publicUrlBase ?? null;
  }

  static fromEnv(): S3ObjectStorage | null {
    const bucket = process.env.S3_BUCKET;
    const region = process.env.S3_REGION;
    const accessKeyId = process.env.S3_ACCESS_KEY_ID;
    const secretAccessKey = process.env.S3_SECRET_ACCESS_KEY;
    if (!bucket || !region || !accessKeyId || !secretAccessKey) return null;
    if (!loadS3()) return null;
    try {
      return new S3ObjectStorage({
        bucket,
        region,
        accessKeyId,
        secretAccessKey,
        endpoint: process.env.S3_ENDPOINT,
        forcePathStyle: process.env.S3_FORCE_PATH_STYLE === "true",
        publicUrlBase: process.env.S3_PUBLIC_URL_BASE,
      });
    } catch (err) {
      logger.error({ err }, "[storage] S3 init failed");
      return null;
    }
  }

  async put(key: string, body: Buffer | Readable, contentType: string): Promise<{ key: string; bytes: number }> {
    const sdk = loadS3()!;
    const cmd = new sdk.s3.PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      Body: body,
      ContentType: contentType,
    });
    await this.client.send(cmd);
    const bytes = Buffer.isBuffer(body) ? body.byteLength : 0;
    return { key, bytes };
  }

  async presignedUploadUrl(key: string, contentType: string, expiresSeconds: number): Promise<string> {
    const sdk = loadS3()!;
    const cmd = new sdk.s3.PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ContentType: contentType,
    });
    return sdk.presigner.getSignedUrl(this.client, cmd, { expiresIn: expiresSeconds });
  }

  async presignedDownloadUrl(key: string, expiresSeconds: number): Promise<string> {
    if (this.publicUrlBase) {
      return `${this.publicUrlBase.replace(/\/$/, "")}/${encodeURIComponent(key)}`;
    }
    const sdk = loadS3()!;
    const cmd = new sdk.s3.GetObjectCommand({ Bucket: this.bucket, Key: key });
    return sdk.presigner.getSignedUrl(this.client, cmd, { expiresIn: expiresSeconds });
  }

  async read(key: string): Promise<{ stream: Readable; bytes: number; contentType: string } | null> {
    const sdk = loadS3()!;
    const cmd = new sdk.s3.GetObjectCommand({ Bucket: this.bucket, Key: key });
    try {
      const out = (await this.client.send(cmd)) as {
        Body?: Readable;
        ContentLength?: number;
        ContentType?: string;
      };
      if (!out.Body) return null;
      return {
        stream: out.Body,
        bytes: out.ContentLength ?? 0,
        contentType: out.ContentType ?? "application/octet-stream",
      };
    } catch (err) {
      logger.warn({ err, key }, "[storage] S3 read miss");
      return null;
    }
  }

  async delete(key: string): Promise<void> {
    const sdk = loadS3()!;
    const cmd = new sdk.s3.DeleteObjectCommand({ Bucket: this.bucket, Key: key });
    await this.client.send(cmd);
  }
}
