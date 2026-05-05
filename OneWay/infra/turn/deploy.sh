#!/usr/bin/env bash
# OneWay TURN — one-shot Ubuntu 22.04/24.04 bootstrapper.
#
# What it does, in order:
#   1. Installs Docker, ufw, certbot.
#   2. Opens only the ports coturn needs.
#   3. Provisions a Let's Encrypt cert for $TURN_HOSTNAME.
#   4. Templates turnserver.conf with values from .env.
#   5. Starts the coturn container.
#   6. Wires a renewal hook so certbot reloads coturn on cert refresh.
#
# Re-running is safe — every step is idempotent.

set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env missing. Copy .env.example to .env and fill in values." >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env

require() {
  local name=$1
  if [[ -z "${!name:-}" || "${!name}" == REPLACE_* ]]; then
    echo "ERROR: env var $name is unset or still a placeholder." >&2
    exit 1
  fi
}
require TURN_PUBLIC_IP
require TURN_HOSTNAME
require TURN_SHARED_SECRET
require TURN_MIN_PORT
require TURN_MAX_PORT
require LE_EMAIL

# ---- 1. apt -------------------------------------------------------------
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg ufw certbot

# ---- 2. Docker ----------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' plugin missing. The official get.docker.com script ships it." >&2
  exit 1
fi

# ---- 3. Firewall --------------------------------------------------------
# Default deny inbound, allow outbound, then poke holes for SSH + TURN.
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'ssh'
sudo ufw allow 80/tcp comment 'certbot http-01'
sudo ufw allow 3478/udp comment 'STUN/TURN udp'
sudo ufw allow 3478/tcp comment 'STUN/TURN tcp'
sudo ufw allow 5349/tcp comment 'TURNs tls'
sudo ufw allow "${TURN_MIN_PORT}":"${TURN_MAX_PORT}"/udp comment 'turn relay'
sudo ufw --force enable

# ---- 4. Certbot ---------------------------------------------------------
# Use standalone mode on port 80 — coturn doesn't bind 80 itself.
sudo mkdir -p ./certs ./logs
if [[ ! -f /etc/letsencrypt/live/"$TURN_HOSTNAME"/fullchain.pem ]]; then
  sudo certbot certonly --standalone --non-interactive --agree-tos \
    -m "$LE_EMAIL" -d "$TURN_HOSTNAME"
fi

# Copy the cert into ./certs so the container (read-only-mounted) can read
# it without root inside the container. Ownership = nobody (proc-user in
# turnserver.conf).
sudo cp -L /etc/letsencrypt/live/"$TURN_HOSTNAME"/fullchain.pem ./certs/
sudo cp -L /etc/letsencrypt/live/"$TURN_HOSTNAME"/privkey.pem  ./certs/
sudo chown -R 65534:65534 ./certs ./logs
sudo chmod 600 ./certs/privkey.pem

# ---- 5. Render turnserver.conf -----------------------------------------
# Substitute the two real placeholders. We do this with sed -i so the file
# on disk is the one coturn actually reads. Keep a backup the first time.
if [[ ! -f turnserver.conf.bak ]]; then
  cp turnserver.conf turnserver.conf.bak
fi

sed -i \
  -e "s|^external-ip=.*|external-ip=${TURN_PUBLIC_IP}|" \
  -e "s|^static-auth-secret=.*|static-auth-secret=${TURN_SHARED_SECRET}|" \
  -e "s|^realm=.*|realm=${TURN_HOSTNAME}|" \
  -e "s|^min-port=.*|min-port=${TURN_MIN_PORT}|" \
  -e "s|^max-port=.*|max-port=${TURN_MAX_PORT}|" \
  turnserver.conf

# ---- 6. Start container ------------------------------------------------
sudo docker compose pull
sudo docker compose up -d

# ---- 7. Renewal hook ---------------------------------------------------
# certbot runs this when it refreshes the cert. We re-copy the files into
# ./certs and HUP coturn so it rereads them without dropping calls.
HOOK=/etc/letsencrypt/renewal-hooks/deploy/oneway-coturn.sh
sudo tee "$HOOK" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
SRC=/etc/letsencrypt/live/${TURN_HOSTNAME}
DST=$(pwd)/certs
cp -L "\$SRC/fullchain.pem" "\$DST/"
cp -L "\$SRC/privkey.pem"  "\$DST/"
chown 65534:65534 "\$DST/fullchain.pem" "\$DST/privkey.pem"
chmod 600 "\$DST/privkey.pem"
docker kill --signal=HUP oneway-coturn || true
EOF
sudo chmod +x "$HOOK"

echo
echo "------------------------------------------------------------"
echo "coturn up. Verify with:"
echo "  docker compose logs -f coturn"
echo "  ss -lun | grep 3478"
echo "  turnutils_uclient -v -t -u test -w test ${TURN_HOSTNAME}   # will 401, that's fine"
echo "------------------------------------------------------------"
