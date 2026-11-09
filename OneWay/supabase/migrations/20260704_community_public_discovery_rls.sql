-- Inspect existing community policies before applying this migration:
--
-- select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
-- from pg_policies
-- where schemaname = 'public'
--   and tablename in ('communities', 'community_members', 'community_messages')
-- order by tablename, policyname;

create extension if not exists pgcrypto;

create table if not exists public.communities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  normalized_name text not null,
  description text not null default '',
  creator_user_id uuid not null,
  creator_handle text not null default '@oneway',
  visibility text not null default 'public' check (visibility in ('public', 'private', 'hidden')),
  blocked_user_ids uuid[] not null default '{}',
  banned_user_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

alter table public.communities
  add column if not exists normalized_name text,
  add column if not exists description text not null default '',
  add column if not exists creator_user_id uuid,
  add column if not exists creator_handle text not null default '@oneway',
  add column if not exists visibility text not null default 'public',
  add column if not exists blocked_user_ids uuid[] not null default '{}',
  add column if not exists banned_user_ids uuid[] not null default '{}',
  add column if not exists deleted_at timestamptz;

update public.communities
set normalized_name = lower(regexp_replace(trim(name), '\s+', ' ', 'g'))
where normalized_name is null or trim(normalized_name) = '';

create unique index if not exists communities_public_normalized_name_unique
  on public.communities (normalized_name)
  where visibility = 'public' and deleted_at is null;

create index if not exists communities_visibility_deleted_idx
  on public.communities (visibility, deleted_at);

create table if not exists public.community_members (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  user_id uuid not null,
  display_name text not null default 'OneWay User',
  handle text not null default '@oneway',
  role text not null default 'member',
  created_at timestamptz not null default now(),
  unique (community_id, user_id)
);

create index if not exists community_members_user_idx
  on public.community_members (user_id);

create table if not exists public.community_messages (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  client_message_id text,
  sender_id uuid not null,
  sender_handle text not null,
  sender_display_name text not null,
  body text not null check (char_length(trim(body)) > 0),
  status text not null default 'sent',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists community_messages_community_created_idx
  on public.community_messages (community_id, created_at);

alter table public.communities enable row level security;
alter table public.community_members enable row level security;
alter table public.community_messages enable row level security;

create or replace function public.is_community_member(target_community_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.community_members cm
    where cm.community_id = target_community_id
      and cm.user_id = target_user_id
  );
$$;

drop policy if exists "communities_select_discoverable" on public.communities;
drop policy if exists "communities_insert_creator" on public.communities;
drop policy if exists "communities_update_creator" on public.communities;
drop policy if exists "communities_soft_delete_creator" on public.communities;
drop policy if exists "community_members_select_visible" on public.community_members;
drop policy if exists "community_members_insert_self_join" on public.community_members;
drop policy if exists "community_members_delete_self_or_creator" on public.community_members;
drop policy if exists "community_messages_select_members_only" on public.community_messages;
drop policy if exists "community_messages_insert_members_only" on public.community_messages;

create policy "communities_select_discoverable"
on public.communities
for select
to authenticated
using (
  deleted_at is null
  and (
    visibility = 'public'
    or creator_user_id = auth.uid()
    or public.is_community_member(communities.id, auth.uid())
  )
);

create policy "communities_insert_creator"
on public.communities
for insert
to authenticated
with check (
  creator_user_id = auth.uid()
  and deleted_at is null
);

create policy "communities_update_creator"
on public.communities
for update
to authenticated
using (creator_user_id = auth.uid())
with check (creator_user_id = auth.uid());

create policy "communities_soft_delete_creator"
on public.communities
for delete
to authenticated
using (creator_user_id = auth.uid());

create policy "community_members_select_visible"
on public.community_members
for select
to authenticated
using (
  exists (
    select 1
    from public.communities c
    where c.id = community_members.community_id
      and c.deleted_at is null
      and (
        c.visibility = 'public'
        or c.creator_user_id = auth.uid()
        or public.is_community_member(community_members.community_id, auth.uid())
      )
  )
);

create policy "community_members_insert_self_join"
on public.community_members
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.communities c
    where c.id = community_members.community_id
      and c.deleted_at is null
      and c.visibility = 'public'
      and not (auth.uid() = any(c.blocked_user_ids))
      and not (auth.uid() = any(c.banned_user_ids))
  )
);

create policy "community_members_delete_self_or_creator"
on public.community_members
for delete
to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1
    from public.communities c
    where c.id = community_members.community_id
      and c.creator_user_id = auth.uid()
  )
);

create policy "community_messages_select_members_only"
on public.community_messages
for select
to authenticated
using (
  public.is_community_member(community_messages.community_id, auth.uid())
);

create policy "community_messages_insert_members_only"
on public.community_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
  and public.is_community_member(community_messages.community_id, auth.uid())
);
