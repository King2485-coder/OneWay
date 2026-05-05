import type { Readable } from "stream";

/**
 * Pluggable object storage. The voicemail service depends on this — swap
 * the implementation (S3, R2, local disk) without touching the routes.
 *
 * `presignedDownloadUrl` returns a URL the iOS client can fetch directly
 * (skipping the API server). For backends that don't support presigning
 * (LocalObjectStorage), the implementation returns a relative URL routed
 * back through the API.
 */
export interface ObjectStorage {
  /** Upload a buffer or stream. Returns the canonical key the object now
   *  lives at (usually echoes the input key). */
  put(key: string, body: Buffer | Readable, contentType: string): Promise<{ key: string; bytes: number }>;

  /** Pre-signed PUT URL for direct-from-client uploads. */
  presignedUploadUrl(key: string, contentType: string, expiresSeconds: number): Promise<string>;

  /** Pre-signed GET URL for direct-from-client playback. */
  presignedDownloadUrl(key: string, expiresSeconds: number): Promise<string>;

  /** Stream an object back through the API (used when presigning is off
   *  or the client wants to attach an Authorization header). */
  read(key: string): Promise<{ stream: Readable; bytes: number; contentType: string } | null>;

  /** Delete an object. Best-effort; missing objects return successfully. */
  delete(key: string): Promise<void>;
}

export class StorageError extends Error {
  constructor(public readonly code: string, message: string) {
    super(message);
    this.name = "StorageError";
  }
}
