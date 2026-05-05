-- ═══════════════════════════════════════════════════════════════════
-- OneWay Browser + Sites Schema
-- Append to supabase_schema.sql and re-run, or run separately
-- ═══════════════════════════════════════════════════════════════════

-- ─── DOMAINS ───────────────────────────────────────────────────────
create table if not exists public.ow_domains (
  id                  uuid primary key default uuid_generate_v4(),
  user_id             uuid not null references public.profiles(id) on delete cascade,
  slug                text not null unique,           -- e.g. "mira" → mira.oneway.app
  status              text not null default 'active'
                      check (status in ('active','expired','suspended','pending')),
  expires_at          timestamptz not null,
  renewal_price_usd   numeric(6,2) not null default 3.99,
  site_id             uuid,                           -- FK set after site creation
  payment_method      text,
  payment_reference   text,                           -- Stripe/Coinbase charge ID
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create unique index if not exists idx_ow_domains_slug on public.ow_domains(slug);
create index if not exists idx_ow_domains_user on public.ow_domains(user_id);
create index if not exists idx_ow_domains_expires on public.ow_domains(expires_at)
  where status = 'active';

create trigger ow_domains_updated_at
  before update on public.ow_domains
  for each row execute function public.handle_updated_at();

alter table public.ow_domains enable row level security;

create policy "Users can view their own domains"
  on public.ow_domains for select
  using (auth.uid() = user_id);

create policy "Users can insert their own domains"
  on public.ow_domains for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own domains"
  on public.ow_domains for update
  using (auth.uid() = user_id);

-- Public read for directory / availability checks
create policy "Anyone can check domain availability"
  on public.ow_domains for select
  using (true);           -- slug uniqueness enforced at DB level

-- ─── SITES ─────────────────────────────────────────────────────────
create table if not exists public.ow_sites (
  id              uuid primary key default uuid_generate_v4(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  domain_slug     text not null references public.ow_domains(slug) on delete cascade,
  title           text not null default 'My OneWay Site',
  description     text default '',
  mode            text not null default 'nocode'
                  check (mode in ('nocode','code','ai')),
  html_content    text default '',      -- compiled HTML, stored here + in Storage
  blocks          jsonb default '[]'::jsonb,   -- no-code builder state
  published       boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_ow_sites_user on public.ow_sites(user_id);
create index if not exists idx_ow_sites_domain on public.ow_sites(domain_slug);
create index if not exists idx_ow_sites_published on public.ow_sites(published)
  where published = true;

create trigger ow_sites_updated_at
  before update on public.ow_sites
  for each row execute function public.handle_updated_at();

-- Update domain.site_id when a site is created
create or replace function public.link_site_to_domain()
returns trigger language plpgsql as $$
begin
  update public.ow_domains
  set site_id = new.id
  where slug = new.domain_slug;
  return new;
end;
$$;

create trigger ow_sites_link_domain
  after insert on public.ow_sites
  for each row execute function public.link_site_to_domain();

alter table public.ow_sites enable row level security;

create policy "Users can manage their own sites"
  on public.ow_sites for all
  using (auth.uid() = user_id);

create policy "Published sites are publicly readable"
  on public.ow_sites for select
  using (published = true);

-- ─── STORAGE BUCKET FOR SITES ──────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'oneway-sites',
  'oneway-sites',
  true,          -- public bucket so edge function can read without auth
  10485760,      -- 10 MB per file
  array['text/html','text/css','text/javascript','application/javascript',
        'image/jpeg','image/png','image/webp','image/gif','image/svg+xml']
)
on conflict (id) do nothing;

-- Storage policies
create policy "Authenticated users can upload site files"
  on storage.objects for insert
  with check (
    bucket_id = 'oneway-sites'
    and auth.role() = 'authenticated'
    -- Enforce path: sites/{slug}/...  where slug belongs to the user
    and exists (
      select 1 from public.ow_domains d
      where d.user_id = auth.uid()
        and (storage.foldername(name))[1] = 'sites'
        and (storage.foldername(name))[2] = d.slug
    )
  );

create policy "Authenticated users can update their site files"
  on storage.objects for update
  using (
    bucket_id = 'oneway-sites'
    and auth.role() = 'authenticated'
  );

create policy "Site files are publicly readable"
  on storage.objects for select
  using (bucket_id = 'oneway-sites');

-- ─── DOMAIN EXPIRY CLEANUP ─────────────────────────────────────────
-- Run via Supabase Dashboard → Edge Functions → Cron, or pg_cron:
-- select cron.schedule('expire-domains', '0 0 * * *', $$
--   update public.ow_domains set status = 'expired'
--   where expires_at < now() and status = 'active';
-- $$);

create or replace function public.expire_domains()
returns void language sql security definer as $$
  update public.ow_domains
  set status = 'expired', updated_at = now()
  where expires_at < now() and status = 'active';
$$;

-- ─── PAYMENT RECORDS ───────────────────────────────────────────────
create table if not exists public.ow_payments (
  id                uuid primary key default uuid_generate_v4(),
  user_id           uuid not null references public.profiles(id),
  domain_slug       text,
  amount_usd        numeric(10,2) not null,
  method            text not null,         -- apple_iap, stripe, crypto
  provider_ref      text,                  -- Stripe charge ID, Coinbase charge code, etc.
  status            text not null default 'pending'
                    check (status in ('pending','completed','failed','refunded')),
  created_at        timestamptz not null default now()
);

alter table public.ow_payments enable row level security;

create policy "Users can view their own payments"
  on public.ow_payments for select
  using (auth.uid() = user_id);

-- Service role inserts payments (from edge functions after webhook confirmation)
create policy "Service role manages payments"
  on public.ow_payments for all
  using (auth.role() = 'service_role');

-- ─── REALTIME ──────────────────────────────────────────────────────
-- Enable realtime on domains so app updates live when domain status changes
alter publication supabase_realtime add table public.ow_domains;
alter publication supabase_realtime add table public.ow_sites;
