# Storefront Manual Smoke Test

Use this checklist when validating the OneWay storefront / marketplace stack by hand before a release or after backend changes.

## Goal

Confirm that a developer can create, populate, publish, discover, and load a storefront through the same backend endpoints the iOS app depends on.

This smoke covers:

- Backend health
- Storefront creation
- Product creation
- Storefront publish
- Public marketplace loading
- Product loading
- Featured marketplace loading
- Search
- iOS app verification points

## Production Mac smoke ritual

Remote Codex/container environments may be unable to reach the public HTTPS hosts because of proxy restrictions. Run the production smoke from the Mac that can already reach `oneway.is` and `api.oneway.is`:

```bash
cd "/Users/king/Library/Mobile Documents/com~apple~CloudDocs/Documents/OneWay/OneWay"

export API_BASE="https://api.oneway.is"
export PUBLIC_BASE="https://oneway.is"
export DEV_USER_ID="00000000-0000-0000-0000-000000000001"

open Docs/STOREFRONT_MANUAL_SMOKE.md
```

Run the curl blocks in this document from that shell. If testing from the home LAN with production hostnames, first ensure local DNS resolves both hostnames to the Mac/server:

```text
oneway.is      A  192.168.0.204
api.oneway.is  A  192.168.0.204
```

Verify before starting the smoke:

```bash
dig +short oneway.is
dig +short api.oneway.is
```

Both should return `192.168.0.204`. If physical iPhones are part of the smoke, configure this mapping in the router/Pi-hole/AdGuard/dnsmasq used by the iPhones; Mac `/etc/hosts` alone does not change iPhone DNS. For physical iPhone builds, keep app traffic on `https://oneway.is` so REST and WebSocket calls use the certificate-valid hostname; `api.oneway.is` can be checked separately while proxy/DNS is being repaired. After the curl smoke, inspect backend logs from the server directory:

```bash
cd server
/Applications/Docker.app/Contents/Resources/bin/docker logs server-api-1 --tail=300 | grep -i "storefront\|store\|marketplace\|error\|my-shop-3"
```

Expected production smoke result:

- Smoke shop created
- Product added
- Publish succeeded
- Public URL loads
- Marketplace search finds the smoke storefront or product
- No stale `my-shop-3` handle checks after reset
- No backend errors

After the Mac smoke passes, run the physical iPhone walkthrough in this document against the same production backend.

## Local development prerequisites

1. Start the backend from the server directory:

   ```bash
   cd OneWay/server
   npm run dev
   ```

2. Use a reachable API base URL and public base URL:

   ```bash
   export API_BASE="http://127.0.0.1:3000"
   export PUBLIC_BASE="http://127.0.0.1:3000"
   ```

   For physical iPhone testing, replace this with the Mac LAN URL from:

   ```bash
   ipconfig getifaddr en0
   ```

3. Set a stable dev user ID. The backend accepts this as `x-dev-user-id` in development.

   ```bash
   export DEV_USER_ID="00000000-0000-0000-0000-000000000001"
   ```

## 1. Backend health

```bash
curl -i "$API_BASE/health"
```

Expected:

- HTTP 200
- JSON with `ok: true` or `status`

## 2. Create a private storefront

```bash
STORE_JSON=$(curl -sS -X POST "$API_BASE/stores" \
  -H "Content-Type: application/json" \
  -H "x-dev-user-id: $DEV_USER_ID" \
  -d '{
    "name": "Smoke Test Store",
    "description": "Manual smoke storefront",
    "category": "Testing",
    "tagline": "Created by smoke test",
    "published": false
  }')

echo "$STORE_JSON"
export STORE_ID=$(printf '%s' "$STORE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
```

Expected:

- HTTP 201 response body if run without `-sS`
- Response includes `id`, `name`, `slug`, `published`
- `published` is `false`

## 3. Add a product

```bash
PRODUCT_JSON=$(curl -sS -X POST "$API_BASE/products" \
  -H "Content-Type: application/json" \
  -H "x-dev-user-id: $DEV_USER_ID" \
  -d "{
    \"storeId\": \"$STORE_ID\",
    \"name\": \"Smoke Product\",
    \"description\": \"A product created during storefront smoke testing.\",
    \"price\": 12.99,
    \"featured\": true,
    \"published\": true
  }")

echo "$PRODUCT_JSON"
export PRODUCT_ID=$(printf '%s' "$PRODUCT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
```

Expected:

- HTTP 201 response body if run without `-sS`
- Response includes `id`, `name`, `price`, and `storeId`
- Product is published and featured

## 4. Publish the storefront

```bash
curl -sS -X PATCH "$API_BASE/api/storefronts/$STORE_ID" \
  -H "Content-Type: application/json" \
  -H "x-dev-user-id: $DEV_USER_ID" \
  -d '{"description":"Manual smoke storefront is now publish-ready."}'

curl -sS -X POST "$API_BASE/api/storefronts/$STORE_ID/publish" \
  -H "x-dev-user-id: $DEV_USER_ID"
```

Expected:

- Response includes `published: true`
- Products and theme data are still present

## 5. Verify public site root

For production smoke, verify the public web host responds before checking storefront data:

```bash
curl -I "$PUBLIC_BASE"
```

Expected:

- HTTP 2xx or 3xx
- No proxy, DNS, TLS, or connection failure

## 6. Verify public storefront list

```bash
curl -sS "$API_BASE/stores" | python3 -m json.tool
```

Expected:

- The smoke storefront appears in the list
- Only published stores appear

## 7. Verify direct storefront lookup

Use either the store ID or slug:

```bash
curl -sS "$API_BASE/stores/$STORE_ID" | python3 -m json.tool
```

Expected:

- The smoke storefront loads
- Products are included
- Theme is included

## 8. Verify products endpoint

```bash
curl -sS "$API_BASE/products?storeId=$STORE_ID" | python3 -m json.tool
curl -sS "$API_BASE/products/$PRODUCT_ID" | python3 -m json.tool
```

Expected:

- Store product list contains Smoke Product
- Direct product lookup returns Smoke Product

## 9. Verify featured marketplace endpoint

```bash
curl -sS "$API_BASE/featured" | python3 -m json.tool
```

Expected:

- Featured products include Smoke Product
- Featured stores include Smoke Test Store if recently updated and published

## 10. Verify marketplace search

```bash
curl -sS "$API_BASE/search?q=smoke&scope=shop" | python3 -m json.tool
```

Expected:

- Results include the smoke storefront and/or smoke product
- Product results include both `storefront` and `product` payloads

## 11. iOS app smoke checklist

With the app pointed at the same backend:

1. Open marketplace / storefront tab.
2. Confirm the public marketplace loads without "Unable to reach OneWay".
3. Search for `smoke`.
4. Confirm `Smoke Test Store` appears.
5. Open the store.
6. Confirm `Smoke Product` appears.
7. Open the product detail or product action.
8. Start the product/order flow far enough to confirm the app can load the order UI or intended purchase action.
9. Confirm no crash, no blank screen, and no auth-only dead end for public browsing.

## Pass / fail criteria

Pass when:

- Backend health passes.
- Smoke shop is created.
- Visible product is added.
- Storefront publish succeeds.
- Public shop URL or public host loads.
- Marketplace search finds the smoke storefront or product.
- iOS shows the shop, product, and order/purchase flow.
- Backend logs show no stale `my-shop-3` handle checks after reset.
- Backend logs show no storefront, store, marketplace, or smoke-test errors.
- All curl commands return 2xx responses.
- The created store becomes visible only after publish.
- The created product is returned by product, featured, and search endpoints.
- The iOS app can load the marketplace, search, store, and product views against the same backend.

Fail when:

- Any endpoint returns 5xx.
- Public endpoints expose unpublished stores or products.
- The iOS app points at a loopback URL on a physical device.
- Storefront or product payloads miss fields required by the app UI.
