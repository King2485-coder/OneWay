# OneWay

This repo currently contains:

- **iOS SwiftUI app:** `OneWay/OneWay/`
- **Node/Prisma backend API:** `OneWay/server/`

The iOS app uses a custom backend for live storefront + AI generation (see the root `README.md` for setup and run steps).

Note: You may also see legacy/experimental web scaffolding (React/Expo/Supabase) in this repo; it is not part of the current shipping iOS build path.

## Local network iPhone testing (no localhost)

For physical iPhones, do **not** point `OneWayAPIBaseURL` to `localhost` or `127.0.0.1`.

1. On the Mac hosting the backend, find LAN IP:

   ```bash
   ipconfig getifaddr en0
   ```

2. Run backend on that Mac:

   ```bash
   cd OneWay/server
   npm install
   npm run dev
   ```

3. `Info.plist` reads the API host from Xcode build settings:
   - `OneWayAPIBaseURL` = `$(ONEWAY_API_BASE_URL)`
   - `OneWayLANAPIBaseURL` = `$(ONEWAY_LAN_API_BASE_URL)`
   - Debug `ONEWAY_API_BASE_URL` / `ONEWAY_LAN_API_BASE_URL` = `http://192.168.0.204:3000`
   - Release `ONEWAY_API_BASE_URL` / `ONEWAY_LAN_API_BASE_URL` = `https://oneway.is`

   Rebuild/reinstall the Debug app on the physical iPhone after changing these values; an already-installed app keeps the old embedded Info.plist values.

4. The plist value is authoritative. If `OneWayAPIBaseURL` points to production, Debug devices will use production. Keep Debug pointed at `http://192.168.0.204:3000` while testing the Mac/LAN backend.

5. Verify the Debug LAN endpoint before reinstalling the iPhone app:

   ```bash
   curl -v http://192.168.0.204:3000/health
   ```

   Expected response includes `"ok":true` from `oneway-server`. If iOS reports a certificate hostname error for the raw IP, switch Debug back to the hostname path (`https://oneway.is`) and make local DNS resolve `oneway.is` to `192.168.0.204`.

## Home network hostname override

When testing production hostnames on the home LAN, use split-horizon DNS so both public OneWay hostnames resolve to the Mac/server on the local network:

```text
oneway.is      A  192.168.0.204
api.oneway.is  A  192.168.0.204
```

Configure those records in the router, Pi-hole, AdGuard Home, dnsmasq, or whichever DNS server the iPhones use on Wi-Fi. A Mac `/etc/hosts` entry is useful for Mac-only curl checks, but it does **not** affect physical iPhones unless the iPhones are configured to use that Mac as DNS.

If raw-IP HTTPS causes certificate validation errors, use this split-horizon DNS path instead and point the Debug build settings back to `https://oneway.is`.

After changing DNS, reconnect Wi-Fi or flush DNS on test devices, then verify from the Mac:

```bash
dig +short oneway.is
dig +short api.oneway.is
curl -vk https://oneway.is/health
curl -vk https://api.oneway.is/health
```

Expected DNS result for both names is `192.168.0.204`. The hostname health check must succeed on `oneway.is`; `api.oneway.is` can be checked separately while proxy/DNS is being repaired. If DNS is correct but HTTPS fails, fix the local reverse proxy/TLS certificate for `oneway.is` and `api.oneway.is` before debugging the iOS app.
