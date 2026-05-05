# OneWay browser — one-time Xcode setup

The OneWay browser tab (and the *.oneway.app site renderer) is wired into the
existing app and compiles with the bundled stub services. Adding the real
Supabase backend takes two short steps in Xcode.

## 1. Add the Supabase Swift package

1. Open `OneWay.xcodeproj` in Xcode.
2. **File → Add Package Dependencies…**
3. Paste:
   ```
   https://github.com/supabase/supabase-swift
   ```
4. Pick the latest stable version, add the **Supabase** product to the
   `OneWay` app target, and finish.

Once the package resolves, every `#if canImport(Supabase)` block in
`Infrastructure/Services/Supabase*.swift` activates automatically. No project
file edits are needed — this Xcode project uses
`PBXFileSystemSynchronizedRootGroup`, so files dropped under
`OneWay/` are picked up on the next build.

## 2. Configure your Supabase project keys

Add two keys to `Info.plist` (Project → Targets → OneWay → Info):

| Key                 | Type   | Example                                      |
| ------------------- | ------ | -------------------------------------------- |
| `SUPABASE_URL`      | String | `https://YOUR_PROJECT.supabase.co`           |
| `SUPABASE_ANON_KEY` | String | (the anon JWT from Supabase → Project API)   |

`SupabaseClientProvider` reads both at launch. If either is missing, the app
silently falls back to `StubDomainService` / `StubSiteService` so the UI still
works in previews and on simulators without the env wired up.

## 3. Backend deploy

The Postgres schema and the two Deno edge functions live alongside this app
in `../supabase/`:

- `supabase/migrations/001_browser_schema.sql` — `ow_domains`, `ow_sites`,
  `ow_payments`, RLS policies.
- `supabase/functions/serve-site/` — serves any `*.oneway.app` slug from
  Storage.
- `supabase/functions/generate-site/` — the AI-backed site builder
  invoked from `EditSiteView` when the user picks AI mode.

Standard deploy:

```bash
supabase db push
supabase functions deploy serve-site
supabase functions deploy generate-site
supabase secrets set AI_PROVIDER_API_KEY=...
```

Set up a Storage bucket named `oneway-sites` (public read).

## 4. What's in the app

```
OneWay/
├── App/
│   └── AppEnvironment.swift        # exposes domainService + siteService
├── Domain/
│   ├── Models/SiteModels.swift     # domains, sites, blocks, slug validator
│   └── Services/
│       ├── DomainService.swift
│       └── SiteService.swift
├── Infrastructure/Services/
│   ├── StubDomainService.swift     # in-memory, used until Supabase is added
│   ├── StubSiteService.swift
│   ├── SupabaseClientProvider.swift
│   ├── SupabaseDomainService.swift # #if canImport(Supabase)
│   └── SupabaseSiteService.swift   # #if canImport(Supabase) + SiteRenderer
└── Presentation/
    ├── ViewModels/
    │   ├── BrowserViewModel.swift
    │   ├── MyDomainsViewModel.swift
    │   ├── RegisterDomainViewModel.swift
    │   └── EditSiteViewModel.swift
    └── Views/
        ├── Browser/
        │   ├── BrowserHostView.swift
        │   ├── BrowserHomeView.swift
        │   ├── DirectoryView.swift
        │   └── SiteWebView.swift   # sandboxed WKWebView, oneway.app only
        └── Domains/
            ├── MyDomainsView.swift
            ├── RegisterDomainView.swift
            ├── DomainDetailView.swift
            └── EditSiteView.swift
```

## 5. Tab integration

`RootTab` gained a `.browser` case (label *Web*, SF symbol `globe`). The new
case is wired into `RootView`'s switch and into `CustomTabBar`'s reorder list.
Existing users will pick up the new tab on next launch via the merge in
`loadTabOrderIfNeeded()` — no migration needed.
