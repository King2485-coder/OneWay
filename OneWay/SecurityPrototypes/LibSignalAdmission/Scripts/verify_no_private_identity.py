#!/usr/bin/env python3
"""Assert that test transport/server fixtures contain no private identity bytes."""

from __future__ import annotations

import pathlib
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: verify_no_private_identity.py PRIVATE_KEY_FILE SEARCH_ROOT...", file=sys.stderr)
        return 64
    private_bytes = pathlib.Path(sys.argv[1]).read_bytes()
    if not private_bytes:
        print("empty private-key sentinel", file=sys.stderr)
        return 1
    for root_arg in sys.argv[2:]:
        root = pathlib.Path(root_arg)
        paths = [root] if root.is_file() else (p for p in root.rglob("*") if p.is_file())
        for path in paths:
            try:
                if private_bytes in path.read_bytes():
                    print(f"SERVER_PRIVATE_IDENTITY_KEY_BYTES_FOUND=true:{path}", file=sys.stderr)
                    return 1
            except OSError:
                continue
    print("SERVER_PRIVATE_IDENTITY_KEY_BYTES_FOUND=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
