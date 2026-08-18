# OneWay – Architecture Overview

## Targets & Entry
- **App:** `CipherChatApp` (`OneWay/OneWay/App`) uses SwiftUI and `AppEnvironment` for dependency injection.
- **Tabs:** Chats · Communities · Calls · Business · Settings. Custom tab bar persists order via `@AppStorage`.

## Core Layers
- **Domain/Models:** Strongly typed models for chat, calls, communities, storefronts, AI builder, and service health.
- **Domain/Services:** Protocol-first boundaries (`AuthService`, `MessagingService`, `CryptoService`, `CallService`, `CommunityService`, `BusinessService`, `AIStorefrontService`, `SystemHealthManager`, etc.).
- **Infrastructure/Services:** Stubs exist for most messaging/calls/community services, while the Business/storefront stack is now wired to a real backend (`NetworkBusinessService`, `NetworkAIStorefrontService`).
- **Infrastructure/Persistence:** `LocalPersistence` with cache policy; `StubStorageService` for ciphertext caching.
- **Presentation:** SwiftUI feature folders per tab; shared UI components in `Presentation/Views/Components` and theme in `Presentation/Theme`.

## Feature Wiring (high level)
- **Encrypted Messaging:** `ChatsListView` → `ChatThreadViewModel` → `MessagingService` (stub uses `CryptoService` + `StorageService` to encrypt & persist ciphertext). Delivery states modeled via `MessageDeliveryStatus`.
- **Communities/Groups:** `CommunitiesView` backed by `CommunityService`; detail screen lists groups/members.
- **Calls (voice/video):** `CallService` abstraction; `ChatThreadViewModel` starts calls; `PhoneView` keeps existing UI for recents/contacts.
- **Business Storefronts (live):** `BusinessHomeView` + `BusinessViewModel` use `NetworkBusinessService` + `NetworkAIStorefrontService` against the Node/Prisma backend in `OneWay/server`. Seller Studio "Send to AI" calls `POST /api/ai/storefronts/generate`, which **creates a real storefront row** and returns it to the app.
- **Diagnostics:** Settings → Diagnostics shows `SystemHealthManager` statuses (per service).

## Running (iOS + Backend)

### 1) Start the backend (required for Storefronts + AI)
```sh
cd OneWay/server
cp .env.example .env
npm install
npx prisma migrate dev
npm run dev
```

You should see:
- Local URL: `http://127.0.0.1:3000/health`
- LAN URL: `http://<your-mac-ip>:3000/health`

To enable real OpenAI responses, set `OPENAI_API_KEY` in `OneWay/server/.env`. If it is missing, the backend falls back to a local generator (but still creates real storefront records).

### 2) Configure the iOS app API base URL
The app uses `OneWay/OneWay/App/APIConfig.swift` as the single source of truth.

- **Simulator:** set `API_BASE_URL` in the Xcode scheme (or edit the fallback).
- **Real iPhone:** set `API_DEVICE_BASE_URL` in the Xcode scheme to your Mac LAN URL, e.g. `http://192.168.1.126:3000`.

### 3) Run the iOS app
Open `OneWay/OneWay.xcodeproj` in Xcode and run the **OneWay** target on simulator or a physical device.

## Extension Points / TODOs
- Replace stubs with production services (Signal-style crypto, transport, WebRTC signaling).
- Wire push notifications and background message fetch.
- Persist encrypted payloads with secure enclave/keychain-derived keys.
- Implement real community/group membership + role enforcement.
- Connect CallService to WebRTC stack and signaling backend.
- Add streaming/iterative AI edits (section-level improvements) to the backend and propagate into `Storefront` model.
- Add tests for service health checks and state flows.
