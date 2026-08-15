# OneWay Twilio PSTN Voice and Messaging

OneWay uses LiveKit for OneWay-to-OneWay calls. Twilio is used only for PSTN call legs and external SMS/MMS. Do not replace the LiveKit token, room, signaling, or internal-call routes with Twilio Voice SDK calls.

## Required configuration

Store all values in the production environment manager. Never put them in source control.

- `PSTN_PROVIDER=twilio` and `SMS_PROVIDER=twilio`
- `TWILIO_ACCOUNT_SID` and `TWILIO_AUTH_TOKEN`
- `TWILIO_API_KEY_SID` and `TWILIO_API_KEY_SECRET` for five-minute Voice SDK tokens
- `TWILIO_TWIML_APP_SID`
- `TWILIO_MESSAGING_SERVICE_SID`
- `TWILIO_FROM_NUMBER`
- `TWILIO_WEBHOOK_BASE_URL=https://api.oneway.is`
- `TWILIO_VALIDATE_WEBHOOKS=true`
- existing LiveKit variables and SIP/connector settings documented in `Docs/CALLS_SETUP.md`

Use a restricted Twilio API key for token signing. Keep the Auth Token server-only. Never return either secret to a client; `/api/twilio/voice/token` returns only a short-lived signed token for the authenticated OneWay user.

## Twilio Console callbacks

- Incoming Messaging Service webhook: `POST https://api.oneway.is/api/twilio/inbound-sms`
- Messaging delivery callback: `POST https://api.oneway.is/api/messages/external/twilio/status`
- Voice and status callbacks are assigned by the server when it creates PSTN calls.

Every Twilio callback must include a valid `X-Twilio-Signature`. The server reconstructs the public callback URL from `TWILIO_WEBHOOK_BASE_URL` and validates the form parameters with `TWILIO_AUTH_TOKEN`. Production startup fails if Twilio is selected and required settings are incomplete or insecure.

## Consent and carrier handling

The first external send must attest `smsConsentConfirmed: true`, supply `smsConsentSource`, and may supply `smsConsentAt`. OneWay stores the evidence per sending user and recipient. Later messages require that consent record. `STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, and `QUIT` revoke delivery. `START`, `UNSTOP`, and `YES` restore an existing consent relationship. `HELP` and `INFO` return support information. Delivery callbacks persist `queued`, `sent`, `delivered`, `failed`, and `undelivered` state.

Do not enable US long-code delivery until A2P 10DLC approval is complete and the approved sender is attached to the Messaging Service.

## Readiness and validation

- `GET /api/twilio/health` is unauthenticated and returns booleans only.
- `GET /api/twilio/preflight` requires OneWay authentication and lists missing variable names, never values.
- `GET /api/pstn/health` reports PSTN/LiveKit bridge readiness.
- `GET /api/pstn/preflight` requires OneWay authentication and includes Twilio validation when selected.
- `GET /api/pstn/calls/status/:callSessionId` remains the authenticated call-status endpoint.

Before deployment run `npm run build`, `npm run test:twilio`, and the existing server self-tests. Use Twilio test credentials or mocked requests for CI; never use production credentials in tests.
