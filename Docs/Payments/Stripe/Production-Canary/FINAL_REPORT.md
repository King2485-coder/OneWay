# OneWay production payment canary

STRIPE PRODUCTION CANARY PARTIAL — FIXES REQUIRED

No live checkout, PaymentIntent, charge or refund was created. The inspected shop is a test fixture, confirmed by its owner. Stripe explicitly prohibits live-mode testing with real payment details; see [Stripe testing guidance](https://docs.stripe.com/testing).

| Item | Area | Result |
|---|---|---|
| A | Final verdict | STRIPE PRODUCTION CANARY PARTIAL — FIXES REQUIRED |
| B | Stripe account | ymK: browser context and running server GET /v1/account match; connector VYd was not used. |
| C | Livemode | Live browser and production runtime confirmed; server key live-format check true. |
| D | Order ID | NOT CREATED — no real merchant/item ready. |
| E | Amount | NOT QUOTED — no placeholder total or invented $1 test item. |
| F | Currency | NOT SELECTED for an actual canary. |
| G | PaymentIntent | NOT CREATED |
| H | Checkout Session | NOT CREATED |
| I | Charge | NOT CREATED; no charge attempted. |
| J | Payment state | No production payment initiated. |
| K | Real webhook delivery | NOT VERIFIED; baseline internal event count 0. Local signed fixtures are not Stripe-origin deliveries. |
| L | Event types | Actual canary events: none. Local fixtures cover payment_intent.succeeded, payment_intent.payment_failed, payment_intent.processing and checkout.session.completed. |
| M | Signature | Raw body mounts before JSON parsing. Valid/invalid signatures pass local tests. Live signing-secret match was verified earlier on 2026-11-16; current run confirms configuration present, not a new Stripe-origin signature. |
| N | Duplicate webhook | Local tests: one durable event, no repeated processing after success; failed events reclaim safely; in-flight replay receives retryable 503; abandoned five-minute lease recovers. |
| O | Order transitions | Local checks use actual models: pending_payment/awaiting_payment → paid/confirmed. Delayed unpaid/failure events do not overwrite paid/refunded state. |
| P | Wallet | Local seller-ledger deduplication passes. Actual customer/seller Wallet transaction and UI linkage NOT RUN. |
| Q | Receipt | Code stores order/session/intent references; no actual receipt exists yet. |
| R | Merchant order center | NOT RUN with a paid order. No fixture shop activated. |
| S | Conversation Pulse | Commerce update bus exists; actual paid-order Pulse event NOT RUN. |
| T | Notification privacy | No real payment notification sent. Privacy fixtures exclude private order text from discovery; actual payment push NOT RUN. |
| U | Cancelled checkout | Pending/unpaid callbacks do not create false paid state in local tests. Actual hosted cancel/recovery flow NOT RUN. |
| V | Failure path | Local handler failure returns 500, retry of same signed event succeeds after repair, completed event deduplicates. No failed real charge created. |
| W | Client restart/recovery | Local new-service-instance retry after lost response: one provider session/object and one order; state stays pending until verified payment. |
| X | Duplicate payments | Server-generated stable order/quote keys; client nonce cannot create extra legacy sessions. Canary is bound to one owner/order/merchant/amount/currency/entry point, max one hour; no approval configured. |
| Y | Stripe reconciliation | Live account/webhook/zero connected merchants verified. No canary financial objects to reconcile; historical transactions are not attributed to this run. |
| Z | Database reconciliation | Read-only production baseline: 0 Order, 0 ShopPayment, 0 SellerPaymentAccount, 0 StripeWebhookEvent. Local fixtures verify single-order/event/ledger behavior. |
| AA | Secrets/logs | 0 matching secret patterns in 955 staged source/dist/native-source/main-binary files; no credential values printed. This is a bounded scan, not a complete historical log audit. Webhook error logging now avoids raw error/payload output. |
| AB | Refund readiness | NOT PASSED: request targets exact PaymentIntent and has amount/idempotency support, but full/partial/failed/pending/transfer-reversal and Wallet handling need further validation. |
| AC | Refund performed | NO; no refund approval requested or implied. |
| AD | Public gate | Runtime ONEWAY_LIVE_CHECKOUT_ENABLED=false; canary approval absent. New guard additionally closes marketplace Intent/Checkout and Memory Commerce checkout/link recovery. |
| AE | Remaining blockers | Genuine product/merchant, completed seller onboarding, exact reviewed order/total and explicit owner approval; real end-to-end and refund evidence remain missing. |
| AF | Exact next step | Keep the fake shop in non-charging test workflows. Finish provider-sandbox checkout and refund verification; only then prepare a genuine purchase and present its exact order/total for approval. No canary may be called READY before that. |
