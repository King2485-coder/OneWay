-- Phase 1A authorization hardening. Designed to be idempotent and deployed
-- only after the multi-user verification script passes in a staging project.

drop policy if exists "Users can update their own domains" on public.ow_domains;
create policy "Users can update their own domains"
on public.ow_domains for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

-- Availability is public, domain rows are not. Exposing the whole row leaked
-- owner/payment fields to anon and unrelated authenticated users.
drop policy if exists "Anyone can check domain availability" on public.ow_domains;

create or replace function public.is_domain_available(candidate_slug text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select not exists (
    select 1
    from public.ow_domains d
    where d.slug = lower(trim(candidate_slug))
  );
$$;

revoke all on function public.is_domain_available(text) from public;
grant execute on function public.is_domain_available(text) to anon, authenticated, service_role;

drop policy if exists "Users can manage their own sites" on public.ow_sites;
create policy "Users can manage their own sites"
on public.ow_sites for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Authenticated users can upload site files" on storage.objects;
create policy "Authenticated users can upload site files"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'oneway-sites'
  and exists (
    select 1 from public.ow_domains d
    where d.user_id = (select auth.uid())
      and (storage.foldername(name))[1] = 'sites'
      and (storage.foldername(name))[2] = d.slug
  )
);

drop policy if exists "Authenticated users can update their site files" on storage.objects;
create policy "Authenticated users can update their site files"
on storage.objects for update
to authenticated
using (
  bucket_id = 'oneway-sites'
  and exists (
    select 1 from public.ow_domains d
    where d.user_id = (select auth.uid())
      and (storage.foldername(name))[1] = 'sites'
      and (storage.foldername(name))[2] = d.slug
  )
)
with check (
  bucket_id = 'oneway-sites'
  and exists (
    select 1 from public.ow_domains d
    where d.user_id = (select auth.uid())
      and (storage.foldername(name))[1] = 'sites'
      and (storage.foldername(name))[2] = d.slug
  )
);

update storage.buckets
set public = false
where id = 'oneway-sites';

drop policy if exists "Site files are publicly readable" on storage.objects;
create policy "Owners and published sites can read site files"
on storage.objects for select
to anon, authenticated
using (
  bucket_id = 'oneway-sites'
  and (
    exists (
      select 1 from public.ow_domains d
      where d.user_id = (select auth.uid())
        and (storage.foldername(name))[1] = 'sites'
        and (storage.foldername(name))[2] = d.slug
    )
    or exists (
      select 1 from public.ow_sites s
      where s.domain_slug = (storage.foldername(name))[2]
        and s.published = true
        and (storage.foldername(name))[1] = 'sites'
    )
  )
);

drop policy if exists "Users can delete their site files" on storage.objects;
create policy "Users can delete their site files"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'oneway-sites'
  and exists (
    select 1 from public.ow_domains d
    where d.user_id = (select auth.uid())
      and (storage.foldername(name))[1] = 'sites'
      and (storage.foldername(name))[2] = d.slug
  )
);

drop policy if exists "Service role manages payments" on public.ow_payments;
create policy "Service role manages payments"
on public.ow_payments for all
to service_role
using (true)
with check (true);

alter function public.expire_domains() set search_path = pg_catalog, public;
revoke all on function public.expire_domains() from public, anon, authenticated;
grant execute on function public.expire_domains() to service_role;

create or replace function public.is_community_member(target_community_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
as $$
  select
    target_user_id = (select auth.uid())
    and exists (
      select 1
      from public.community_members cm
      where cm.community_id = target_community_id
        and cm.user_id = target_user_id
    );
$$;

revoke all on function public.is_community_member(uuid, uuid) from public, anon;
grant execute on function public.is_community_member(uuid, uuid) to authenticated, service_role;

alter function public.link_site_to_domain() set search_path = pg_catalog, public;
revoke all on function public.link_site_to_domain() from public, anon, authenticated;

alter function public.handle_updated_at() set search_path = pg_catalog, public;
revoke all on function public.handle_updated_at() from public, anon, authenticated;
