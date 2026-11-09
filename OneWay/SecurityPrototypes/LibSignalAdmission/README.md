# OneWay libsignal admission prototype

This directory is an isolated, test-only admission harness for `signalapp/libsignal`
`v0.105.4` at commit
`b2a5c30f3245c1bcad04b27b1e752a38321c793d`. It is not linked into the
production OneWay application and does not register keys, migrate messages, or
contact production services.

The harness establishes three boundaries:

1. `Scripts/verify_libsignal_artifact.py` rejects any binary whose filename,
   length, or SHA-256 is not in the approved manifest.
2. `Sources/OneWayCrypto` owns the application-facing crypto interfaces and the
   libsignal store adapters. UI code never imports libsignal.
3. `Tests` exercises the pinned Swift API with local test identities and no
   network or user account.

The integration project is generated in a temporary directory by
`Scripts/run_admission.sh`; pinned upstream source and the approved archive stay
outside the repository. The script fails closed on a tag, commit, source-tree,
or artifact-hash mismatch.

No cryptographic construction is implemented here. All identity, prekey,
session, ratchet, encryption, and decryption operations are performed by the
pinned libsignal API.
