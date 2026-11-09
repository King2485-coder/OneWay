#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${ROOT_DIR}/server"

echo "[oneway] wire-up-dev (local)"
echo "[oneway] server dir: ${SERVER_DIR}"

export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[oneway] ERROR: docker not found. Install Docker Desktop and try again."
  exit 1
fi

if [ ! -f "${SERVER_DIR}/.env" ]; then
  echo "[oneway] ERROR: ${SERVER_DIR}/.env not found."
  echo "[oneway] Copy ${SERVER_DIR}/.env.example to ${SERVER_DIR}/.env and fill required values."
  exit 1
fi

mkdir -p "${SERVER_DIR}/secrets/certs"

# Local dev certs (self-signed) so the edge proxy can listen on 443.
# These are for local smoke only. Production should use real certs.
if [ ! -f "${SERVER_DIR}/secrets/certs/oneway.is.pem" ] || [ ! -f "${SERVER_DIR}/secrets/certs/oneway.is.key" ]; then
  echo "[oneway] generating self-signed cert for oneway.is (local dev)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes \
    -keyout "${SERVER_DIR}/secrets/certs/oneway.is.key" \
    -out "${SERVER_DIR}/secrets/certs/oneway.is.pem" \
    -subj "/CN=oneway.is" \
    -addext "subjectAltName=DNS:oneway.is,DNS:www.oneway.is"
fi

if [ ! -f "${SERVER_DIR}/secrets/certs/api.oneway.is.pem" ] || [ ! -f "${SERVER_DIR}/secrets/certs/api.oneway.is.key" ]; then
  echo "[oneway] generating self-signed cert for api.oneway.is (local dev)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes \
    -keyout "${SERVER_DIR}/secrets/certs/api.oneway.is.key" \
    -out "${SERVER_DIR}/secrets/certs/api.oneway.is.pem" \
    -subj "/CN=api.oneway.is" \
    -addext "subjectAltName=DNS:api.oneway.is"
fi

cd "${SERVER_DIR}"
docker compose --profile edge --profile frontend up -d --build

BACKEND_HEALTH_URL="${ONEWAY_DEV_HEALTH_URL:-http://127.0.0.1/health}"
BACKEND_ROOT_URL="${ONEWAY_DEV_ROOT_URL:-http://127.0.0.1/}"

echo "[oneway] health checks"
for i in {1..40}; do
  if curl -fsS -o /dev/null "${BACKEND_HEALTH_URL}"; then
    break
  fi
  sleep 0.5
done
curl -fsS -I "${BACKEND_HEALTH_URL}" | head -n 5
curl -fsS -I "${BACKEND_ROOT_URL}" | head -n 5

echo "[oneway] edge proxy (local HTTPS uses self-signed; use curl -k)"
for i in {1..40}; do
  if curl -sS -k -o /dev/null https://127.0.0.1/sms-consent; then
    break
  fi
  sleep 0.5
done
curl -sS -Ik https://127.0.0.1/sms-consent | head -n 12

echo "[oneway] done"
