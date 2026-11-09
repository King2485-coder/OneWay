#!/usr/bin/env python3
"""Fail-closed verifier for the admitted libsignal iOS archive."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify_libsignal_artifact.py MANIFEST ARTIFACT", file=sys.stderr)
        return 64

    manifest_path = pathlib.Path(sys.argv[1]).resolve()
    artifact_path = pathlib.Path(sys.argv[2]).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    if artifact_path.name != manifest["artifact_filename"]:
        print("libsignal admission failed: unexpected artifact filename", file=sys.stderr)
        return 1
    if artifact_path.stat().st_size != manifest["artifact_size_bytes"]:
        print("libsignal admission failed: unexpected artifact size", file=sys.stderr)
        return 1

    digest = hashlib.sha256()
    with artifact_path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != manifest["sha256"]:
        print("libsignal admission failed: SHA-256 mismatch", file=sys.stderr)
        return 1

    print("libsignal artifact admitted: filename, size, and SHA-256 match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
