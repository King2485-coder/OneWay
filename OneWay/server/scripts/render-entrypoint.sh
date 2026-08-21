#!/bin/sh
set -eu

mkdir -p /app/data /var/lib/oneway/uploads
chown -R oneway:oneway /app/data /var/lib/oneway/uploads

exec su-exec oneway sh -c '
  if echo "$DATABASE_URL" | grep -Eq "^file:"; then
    if [ -s /app/data/dev.db ]; then
      echo "[oneway] Existing SQLite database detected; applying additive domain migrations."
      npx prisma db execute --schema prisma/schema.prisma --file prisma/migrations/20260730_shop_messaging_domain/migration.sql
      npx prisma db execute --schema prisma/schema.prisma --file prisma/migrations/20260820_storefront_creation_idempotency/migration.sql
    else
      echo "[oneway] Initializing the Render persistent database."
      npx prisma db push --skip-generate
    fi
  else
    npx prisma migrate deploy
  fi
  exec node dist/index.js
'
