# CipherChat Security Notes

## Current Status (January 2025)
- App is structured for end-to-end encryption with production-ready protocol boundaries, but ships with **stubbed crypto/transport** for local builds.
- `MessagingService` now routes through `CryptoService` + `StorageService` stubs to encrypt and persist ciphertext; replace with real Signal-style implementation before release.
- Keys and sensitive material must live in Keychain/Secure Enclave in production; stubs do not persist secrets.

## Intended E2EE Architecture
- Client-side encryption/decryption only; server handles routing metadata plus ciphertext.
- Identity + session/ratchet keys managed by `CryptoService` (`KeyService` handles lifecycle).
- Authenticated encryption for message bodies and attachments; minimal associated metadata.
- Forward secrecy + post-compromise security required; follow audited Signal Double Ratchet or MLS once backend is ready.
- Safety number / fingerprint verification for trust establishment.
- Push notifications must exclude plaintext; only envelope data allowed.

## Metadata Minimization
- Store only operational metadata (ids, timestamps, delivery states).
- Default `LocalPersistence` uses `metadataOnly`; ciphertext caching goes through `StorageService` (intended to encrypt-at-rest).
- Avoid analytics linkage unless explicitly consented; keep per-service dependency lists minimal.

## Deletion + Retention Realities
- “Delete for everyone” removes server-side ciphertext best-effort but cannot guarantee removal from:
  - Recipient devices, screenshots, screen recordings.
  - OS/device/cloud backups outside app control.
  - Third-party keyboards or accessibility services.
- Ephemeral/disappearing timers operate at app level; they do not prevent out-of-app capture.

## Hardening Roadmap
- Replace stubs with audited crypto library; store keys in Secure Enclave + Keychain with device binding.
- Add encrypted-at-rest persistence for cached ciphertext; consider per-conversation keys.
- Implement remote attestation / device integrity checks where feasible.
- Rate-limit and abuse-prevent at transport and notification layers.
- Commission independent security review before production launch.
