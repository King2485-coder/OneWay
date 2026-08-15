#!/usr/bin/env bash
set -euo pipefail

echo "[oneway] origin check: nginx + api containers + local 443"
echo

if command -v rg >/dev/null 2>&1; then
  RG=rg
else
  RG=grep
fi

echo "== Listening ports (443/80)"
if command -v ss >/dev/null 2>&1; then
  ss -lntp | $RG ':443|:80' || true
else
  netstat -anp tcp | $RG '\\.443|\\.80' || true
fi
echo

echo "== docker compose status"
docker compose ps || true
echo

echo "== Local health"
curl -sS -I http://127.0.0.1/health | head -n 5 || true
echo

echo "== Local HTTPS (will show cert subject; -k to avoid strict verify during early setup)"
curl -sS -Ik https://127.0.0.1/health | head -n 15 || true
echo

echo "== Local HTTPS public pages"
for p in / /sms-consent /privacy /terms /contact; do
  echo "-- https://127.0.0.1${p}"
  curl -sS -Ik "https://127.0.0.1${p}" | head -n 10 || true
  echo
done

echo "== Public health"
curl -fsS https://api.oneway.is/health || true
echo
curl -fsS https://oneway.is/health || true
echo

echo "== Public WebSocket reachability (wss://api.oneway.is/ws/calls)"
if command -v node >/dev/null 2>&1; then
  node <<'EOF' || true
const https = require("node:https");

const req = https.request("https://api.oneway.is/ws/calls", {
  method: "GET",
  headers: {
    Connection: "Upgrade",
    Upgrade: "websocket",
    "Sec-WebSocket-Version": "13",
    "Sec-WebSocket-Key": Buffer.from("oneway-prod-check").toString("base64"),
  },
});

req.on("upgrade", (res) => {
  console.log(`[oneway] websocket upgrade reached: ${res.statusCode}`);
  req.destroy();
});

req.on("response", (res) => {
  console.log(`[oneway] websocket endpoint responded over HTTPS: ${res.statusCode}`);
  res.resume();
});

req.on("error", (error) => {
  console.log(`[oneway] websocket reachability failed: ${error.message}`);
});

req.end();
EOF
else
  echo "[oneway] node not installed; skipping websocket reachability probe"
fi
echo

echo "[oneway] done"
