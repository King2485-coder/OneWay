import fs from "fs";
import path from "path";
import crypto from "crypto";
import type { Readable } from "stream";
import type { ObjectStorage } from "./ObjectStorage";

/**
 * Filesystem-backed `ObjectStorage` for dev / single-host deployments.
 * "Presigned" URLs are HMAC-signed paths on the local API — anyone who
 * holds them for the TTL can fetch the object even without auth, mimicking
 * S3 presigning semantics.
 *
 * The HMAC key (`STORAGE_HMAC_SECRET`) MUST be the same across instances
 * if you ever scale beyond one. For single-host MVP, defaults to a process
 * key — fine for one box.
 */
export class LocalObjectStorage implements ObjectStorage {
  private readonly root: string;
  private readonly publicMountPath: string;
  private readonly secret: string;

  constructor(opts?: { root?: string; publicMountPath?: string; secret?: string }) {
    this.root = opts?.root ?? path.resolve(process.cwd(), "uploads");
    // The Express route in voicemail.ts mounts a verifier at this path.
    this.publicMountPath = opts?.publicMountPath ?? "/api/voicemail/storage";
    this.secret = opts?.secret ?? process.env.STORAGE_HMAC_SECRET ?? crypto.randomBytes(32).toString("hex");
    fs.mkdirSync(this.root, { recursive: true });
  }

  async put(key: string, body: Buffer | Readable, _contentType: string): Promise<{ key: string; bytes: number }> {
    const filePath = this.resolve(key);
    await fs.promises.mkdir(path.dirname(filePath), { recursive: true });
    if (Buffer.isBuffer(body)) {
      await fs.promises.writeFile(filePath, body);
      return { key, bytes: body.byteLength };
    }
    await new Promise<void>((resolve, reject) => {
      const out = fs.createWriteStream(filePath);
      body.pipe(out);
      body.on("error", reject);
      out.on("error", reject);
      out.on("finish", () => resolve());
    });
    const stat = await fs.promises.stat(filePath);
    return { key, bytes: stat.size };
  }

  async presignedUploadUrl(key: string, _contentType: string, _expiresSeconds: number): Promise<string> {
    // Direct-to-storage upload isn't implemented for local — clients just
    // POST through `/api/voicemail/upload`. Return a marker the caller
    // can detect and switch to the legacy upload path.
    return `local:${key}`;
  }

  async presignedDownloadUrl(key: string, expiresSeconds: number): Promise<string> {
    const expiresAt = Math.floor(Date.now() / 1000) + Math.max(60, expiresSeconds);
    const sig = this.sign(key, expiresAt);
    const params = new URLSearchParams({ exp: String(expiresAt), sig });
    return `${this.publicMountPath}/${encodeURIComponent(key)}?${params.toString()}`;
  }

  async read(key: string): Promise<{ stream: Readable; bytes: number; contentType: string } | null> {
    const filePath = this.resolve(key);
    if (!fs.existsSync(filePath)) return null;
    const stat = await fs.promises.stat(filePath);
    return {
      stream: fs.createReadStream(filePath),
      bytes: stat.size,
      contentType: "application/octet-stream",
    };
  }

  async delete(key: string): Promise<void> {
    const filePath = this.resolve(key);
    try {
      await fs.promises.unlink(filePath);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    }
  }

  /** Verify a signed download URL. Used by the route mounted at
   *  `/api/voicemail/storage/:key`. */
  verifySignature(key: string, expiresAt: number, sig: string): boolean {
    if (!Number.isFinite(expiresAt) || Math.floor(Date.now() / 1000) > expiresAt) return false;
    const expected = this.sign(key, expiresAt);
    if (expected.length !== sig.length) return false;
    return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(sig));
  }

  // ---- internal --------------------------------------------------------

  private resolve(key: string): string {
    // Refuse anything that would escape the root.
    if (key.includes("..") || key.startsWith("/") || key.includes("\0")) {
      throw new Error("invalid_key");
    }
    return path.join(this.root, key);
  }

  private sign(key: string, expiresAt: number): string {
    return crypto
      .createHmac("sha256", this.secret)
      .update(`${key}:${expiresAt}`)
      .digest("hex");
  }
}
