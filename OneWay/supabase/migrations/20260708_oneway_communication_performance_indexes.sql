-- OneWay communication performance indexes.
-- These support global community discovery, membership checks, delta message sync,
-- and realtime fanout membership validation without changing RLS behavior.

create index if not exists community_messages_community_id_created_at_desc_idx
  on public.community_messages (community_id, created_at desc);

create index if not exists community_messages_client_message_id_idx
  on public.community_messages (client_message_id);

create index if not exists community_members_community_id_user_id_idx
  on public.community_members (community_id, user_id);

create index if not exists communities_visibility_deleted_updated_idx
  on public.communities (visibility, deleted_at, updated_at desc);

create index if not exists communities_normalized_name_visibility_idx
  on public.communities (normalized_name, visibility)
  where deleted_at is null;
