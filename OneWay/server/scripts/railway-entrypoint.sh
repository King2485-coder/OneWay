#!/bin/sh
set -eu

# Railway volumes are mounted after the image is built and initially belong to
# root. Repair ownership before dropping privileges so SQLite and local uploads
# remain writable across deploys and restarts.
mkdir -p /app/data /var/lib/oneway/uploads
chown -R oneway:oneway /app/data /var/lib/oneway/uploads

exec su-exec oneway sh -c '
  if echo "$DATABASE_URL" | grep -Eq "^file:"; then
    if [ -s /app/data/dev.db ]; then
      # Production contains runtime-managed tables that are intentionally not
      # represented in Prisma. A blanket `db push` would try to drop them, so
      # existing SQLite databases are upgraded by the additive startup patches
      # in initializeServer instead.
      echo "[oneway] Existing SQLite database detected; skipping Prisma db push."
    else
      # A brand-new persistent volume still needs the declarative base schema.
      npx prisma db push --skip-generate
    fi
  else
    npx prisma migrate deploy
  fi
  exec node dist/index.js
'
