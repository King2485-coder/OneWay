#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${ROOT_DIR}/server"

echo "[oneway] wire-up-prod (production-like)"
echo "[oneway] server dir: ${SERVER_DIR}"

export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[oneway] ERROR: docker not found."
  exit 1
fi

if [ ! -f "${SERVER_DIR}/.env" ]; then
  echo "[oneway] ERROR: ${SERVER_DIR}/.env not found."
  exit 1
fi

# Production requires real TLS certs for oneway.is (and optionally api.oneway.is).
CERT_DIR="${SERVER_DIR}/secrets/certs"
REQ=(
  "${CERT_DIR}/oneway.is.pem"
  "${CERT_DIR}/oneway.is.key"
  "${CERT_DIR}/api.oneway.is.pem"
  "${CERT_DIR}/api.oneway.is.key"
)

missing=0
for f in "${REQ[@]}"; do
  if [ ! -f "$f" ]; then
    echo "[oneway] missing cert file: $f"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  cat <<'EOF'
[oneway] ERROR: production TLS certs are missing.

Place certs in server/secrets/certs:
  - oneway.is.pem / oneway.is.key
  - api.oneway.is.pem / api.oneway.is.key

If you're using Let's Encrypt on the host, copy the fullchain + privkey here.
If you're using a managed load balancer/ingress, you may not need this nginx container.
EOF
  exit 1
fi

cd "${SERVER_DIR}"
docker compose --profile edge --profile frontend up -d --build

echo "[oneway] production smoke (run from the host with real DNS + HTTPS):"
echo "  curl -I https://oneway.is/"
echo "  curl -I https://oneway.is/sms-consent"
