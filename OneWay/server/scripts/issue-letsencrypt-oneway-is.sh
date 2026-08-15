#!/usr/bin/env bash
set -euo pipefail

# Issues/renews Let's Encrypt certs for oneway.is and copies them into
# server/secrets/certs/ so the nginx edge container can load them.
#
# Requirements:
# - DNS A records for oneway.is, www.oneway.is, api.oneway.is point to this host's public IPv4.
# - Port 80 reachable from the public Internet.
#
# Usage:
#   ./scripts/issue-letsencrypt-oneway-is.sh you@example.com
#

EMAIL="${1:-}"
if [ -z "${EMAIL}" ]; then
  echo "usage: $0 <letsencrypt-email>"
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/secrets/certs"
LE_DIR="${ROOT_DIR}/secrets/letsencrypt"
LE_LIB="${ROOT_DIR}/secrets/letsencrypt-lib"

export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"

mkdir -p "${CERT_DIR}" "${LE_DIR}" "${LE_LIB}"

echo "[oneway] stopping edge nginx to free port 80 for certbot"
docker compose --profile edge stop nginx || true

echo "[oneway] running certbot (standalone http-01)"
docker run --rm \
  -p 80:80 \
  -v "${LE_DIR}:/etc/letsencrypt" \
  -v "${LE_LIB}:/var/lib/letsencrypt" \
  certbot/certbot:latest certonly --standalone \
  --non-interactive --agree-tos \
  --email "${EMAIL}" \
  -d oneway.is -d www.oneway.is -d api.oneway.is

echo "[oneway] copying certs to ${CERT_DIR}"
cp -f "${LE_DIR}/live/oneway.is/fullchain.pem" "${CERT_DIR}/oneway.is.pem"
cp -f "${LE_DIR}/live/oneway.is/privkey.pem" "${CERT_DIR}/oneway.is.key"

# api.oneway.is is included in the same cert above, but nginx expects separate files.
cp -f "${CERT_DIR}/oneway.is.pem" "${CERT_DIR}/api.oneway.is.pem"
cp -f "${CERT_DIR}/oneway.is.key" "${CERT_DIR}/api.oneway.is.key"

echo "[oneway] starting edge nginx"
docker compose --profile edge up -d nginx

echo "[oneway] done. Verify:"
echo "  curl -I https://oneway.is/"
echo "  curl -I https://oneway.is/sms-consent"

