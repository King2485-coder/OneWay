# OneWay Backend

This folder holds everything Supabase needs: schema migrations and edge functions.

## One-time setup

1. Create a Supabase project at https://supabase.com
2. From the project settings, grab:
   - `Project URL` → `EXPO_PUBLIC_SUPABASE_URL`
   - `anon` key → `EXPO_PUBLIC_SUPABASE_ANON_KEY`
   - `service_role` key → `SUPABASE_SERVICE_ROLE_KEY` (server-side only — used by edge functions)
3. Create a `profiles` table and a `handle_updated_at()` trigger function — these are referenced by the OneWay schema. A minimal version:

   ```sql
   create extension if not exists "uuid-ossp";

   create table public.profiles (
     id          uuid primary key references auth.users(id) on delete cascade,
     username    text unique,
     created_at  timestamptz not null default now(),
     updated_at  timestamptz not null default now()
   );

   create or replace function public.handle_updated_at()
   returns trigger language plpgsql as $$
   begin new.updated_at = now(); return new; end $$;
   ```

4. Run the OneWay migration:

   ```sh
   supabase db push
   # or paste migrations/001_browser_schema.sql into the SQL editor
   ```

## Edge functions

```sh
supabase functions deploy serve-site
supabase functions deploy generate-site

# Set secrets used by serve-site / generate-site
supabase secrets set \
  SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY \
  ANTHROPIC_API_KEY=YOUR_ANTHROPIC_KEY
```

## DNS / custom domain

1. Add a wildcard DNS record: `*.oneway.app  CNAME  YOUR_PROJECT.functions.supabase.co`
2. In the Supabase dashboard, add `*.oneway.app` as a custom domain pointing at the `serve-site` function.
3. Test:
   ```sh
   curl -H "Host: home.oneway.app" https://YOUR_PROJECT.functions.supabase.co/serve-site
   curl -H "Host: foo.oneway.app"  https://YOUR_PROJECT.functions.supabase.co/serve-site
   ```

## Cron

Schedule the daily expiry job once:

```sql
select cron.schedule('expire-domains', '0 0 * * *', $$
  select public.expire_domains();
$$);
```
