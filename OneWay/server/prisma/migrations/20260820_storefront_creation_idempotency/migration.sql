CREATE TABLE IF NOT EXISTS "storefront_creation_attempts" (
  "owner_id" TEXT NOT NULL,
  "idempotency_key" TEXT NOT NULL,
  "storefront_id" TEXT NOT NULL,
  "created_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("owner_id", "idempotency_key")
);

CREATE INDEX IF NOT EXISTS "storefront_creation_attempts_storefront_id_idx"
  ON "storefront_creation_attempts" ("storefront_id");
