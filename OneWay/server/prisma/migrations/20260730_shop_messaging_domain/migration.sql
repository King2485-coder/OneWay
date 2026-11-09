CREATE TABLE IF NOT EXISTS "shop_conversations" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "shop_id" TEXT NOT NULL,
  "buyer_id" TEXT NOT NULL,
  "seller_id" TEXT NOT NULL,
  "product_id" TEXT,
  "order_id" TEXT,
  "custom_request_id" TEXT,
  "conversation_type" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'open',
  "muted_by_json" TEXT NOT NULL DEFAULT '[]',
  "archived_by_json" TEXT NOT NULL DEFAULT '[]',
  "deleted_by_json" TEXT NOT NULL DEFAULT '[]',
  "created_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at" DATETIME NOT NULL,
  "last_message_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "closed_at" DATETIME
);

CREATE TABLE IF NOT EXISTS "shop_messages" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "shop_conversation_id" TEXT NOT NULL,
  "sender_id" TEXT NOT NULL,
  "sender_role" TEXT NOT NULL,
  "recipient_id" TEXT NOT NULL,
  "body_encrypted" TEXT NOT NULL,
  "message_type" TEXT NOT NULL DEFAULT 'userMessage',
  "attachment_metadata" TEXT,
  "client_message_id" TEXT NOT NULL,
  "created_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "edited_at" DATETIME,
  "deleted_at" DATETIME,
  CONSTRAINT "shop_messages_shop_conversation_id_fkey"
    FOREIGN KEY ("shop_conversation_id")
    REFERENCES "shop_conversations" ("id")
    ON DELETE CASCADE
    ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "shop_conversation_reads" (
  "conversation_id" TEXT NOT NULL,
  "user_id" TEXT NOT NULL,
  "last_read_message_id" TEXT,
  "last_read_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("conversation_id", "user_id"),
  CONSTRAINT "shop_conversation_reads_conversation_id_fkey"
    FOREIGN KEY ("conversation_id")
    REFERENCES "shop_conversations" ("id")
    ON DELETE CASCADE
    ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS "shop_blocked_users" (
  "user_id" TEXT NOT NULL,
  "blocked_user_id" TEXT NOT NULL,
  "scope" TEXT NOT NULL DEFAULT 'shop',
  "blocked_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("user_id", "blocked_user_id")
);

CREATE TABLE IF NOT EXISTS "shop_message_settings" (
  "user_id" TEXT NOT NULL PRIMARY KEY,
  "seller_permission" TEXT NOT NULL DEFAULT 'Anyone',
  "buyer_permission" TEXT NOT NULL DEFAULT 'Sellers I contacted',
  "allow_product_questions" BOOLEAN NOT NULL DEFAULT true,
  "allow_custom_requests" BOOLEAN NOT NULL DEFAULT true,
  "allow_order_only_messages" BOOLEAN NOT NULL DEFAULT true,
  "allow_promotional_messages" BOOLEAN NOT NULL DEFAULT false,
  "allow_messages_from_new_accounts" BOOLEAN NOT NULL DEFAULT true,
  "seller_allow_attachments" BOOLEAN NOT NULL DEFAULT true,
  "seller_allow_links" BOOLEAN NOT NULL DEFAULT false,
  "auto_close_inactive" BOOLEAN NOT NULL DEFAULT false,
  "require_order_number_for_support" BOOLEAN NOT NULL DEFAULT false,
  "buyer_allow_attachments" BOOLEAN NOT NULL DEFAULT true,
  "buyer_allow_links" BOOLEAN NOT NULL DEFAULT false,
  "show_read_receipts" BOOLEAN NOT NULL DEFAULT false,
  "show_typing_indicator" BOOLEAN NOT NULL DEFAULT true,
  "show_activity_status" BOOLEAN NOT NULL DEFAULT false,
  "updated_at" DATETIME NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS "shop_messages_shop_conversation_id_client_message_id_key"
  ON "shop_messages" ("shop_conversation_id", "client_message_id");

CREATE INDEX IF NOT EXISTS "shop_conversations_buyer_id_updated_at_idx"
  ON "shop_conversations" ("buyer_id", "updated_at");
CREATE INDEX IF NOT EXISTS "shop_conversations_seller_id_updated_at_idx"
  ON "shop_conversations" ("seller_id", "updated_at");
CREATE INDEX IF NOT EXISTS "shop_conversations_shop_id_updated_at_idx"
  ON "shop_conversations" ("shop_id", "updated_at");
CREATE INDEX IF NOT EXISTS "shop_conversations_product_id_idx"
  ON "shop_conversations" ("product_id");
CREATE INDEX IF NOT EXISTS "shop_conversations_order_id_idx"
  ON "shop_conversations" ("order_id");
CREATE INDEX IF NOT EXISTS "shop_conversations_conversation_type_status_idx"
  ON "shop_conversations" ("conversation_type", "status");
CREATE INDEX IF NOT EXISTS "shop_messages_shop_conversation_id_created_at_idx"
  ON "shop_messages" ("shop_conversation_id", "created_at");
CREATE INDEX IF NOT EXISTS "shop_messages_sender_id_created_at_idx"
  ON "shop_messages" ("sender_id", "created_at");
CREATE INDEX IF NOT EXISTS "shop_conversation_reads_user_id_last_read_at_idx"
  ON "shop_conversation_reads" ("user_id", "last_read_at");
CREATE INDEX IF NOT EXISTS "shop_blocked_users_blocked_user_id_idx"
  ON "shop_blocked_users" ("blocked_user_id");
