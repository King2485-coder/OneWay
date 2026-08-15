import "./styles.css";

const routeFiles = {
  "/": "/captured/home.html",
  "/features": "/captured/routes/features.html",
  "/pricing": "/captured/routes/pricing.html",
  "/phone": "/captured/routes/phone.html",
  "/email": "/captured/routes/email.html",
  "/privacy": "/captured/routes/privacy.html",
  "/business": "/captured/routes/business.html",
  "/shop": "/captured/routes/shop.html",
  "/sites": "/captured/routes/sites.html",
  "/account/billing": "/captured/routes/account__billing.html",
  "/account/sign-in": "/captured/routes/account__sign-in.html",
  "/terms": "/captured/routes/terms.html",
  "/acceptable-use": "/captured/routes/acceptable-use.html",
  "/contact": "/captured/routes/contact.html",
  "/support": "/captured/routes/contact.html",
  "/status": "/captured/routes/status.html",
};

const SMS_DISCLOSURE =
  "By providing your phone number, you agree to receive OneWay SMS messages for verification, account alerts, service notifications, support, and user-initiated communications. Message frequency varies. Message and data rates may apply. Reply STOP to opt out or HELP for help.";

const SMS_OPT_IN_CHECKBOX_LABEL =
  "I agree to receive transactional and account-related text messages from OneWay, including verification codes, security alerts, missed-call notifications, invitations, and requested reminders. Message frequency varies. Message and data rates may apply. Reply STOP to opt out or HELP for help. SMS consent is optional and is not required to create an account, use OneWay, or purchase OneWay products or services.";

const orderProducts = new Set([
  "oneway_free",
  "oneway_private",
  "oneway_complete",
  "oneway_business",
  "oneway_business_pro",
  "oneway_phone_number",
  "oneway_phone_300",
  "oneway_phone_1000",
  "oneway_additional_shop",
  "oneway_shop_slot_1",
  "oneway_shop_slot_10",
  "oneway_shop_slot_25",
  "oneway_shop_slot_50",
  "oneway_shop_slot_100",
]);

function capturePath() {
  if (window.location.pathname === "/order/review") {
    const product = new URLSearchParams(window.location.search).get("product");
    const safeProduct = orderProducts.has(product) ? product : "oneway_free";
    return `/captured/routes/order__review__${safeProduct}.html`;
  }

  return routeFiles[window.location.pathname] ?? routeFiles["/"];
}

function syncMetadata(sourceDocument) {
  document.title = sourceDocument.title;

  document.head
    .querySelectorAll("[data-captured-metadata]")
    .forEach((node) => node.remove());

  sourceDocument.head
    .querySelectorAll('meta[name="description"], meta[property^="og:"], meta[name^="twitter:"], link[rel="canonical"]')
    .forEach((node) => {
      const clone = node.cloneNode(true);
      clone.setAttribute("data-captured-metadata", "");
      document.head.appendChild(clone);
    });
}

function setSmsConsentMetadata() {
  document.title = "SMS Consent | OneWay";
  document.head
    .querySelectorAll("[data-captured-metadata]")
    .forEach((node) => node.remove());

  const metadata = [
    ["meta", { name: "description", content: "How OneWay users opt in to SMS, what messages they may receive, and how to use STOP or HELP." }],
    ["meta", { property: "og:title", content: "SMS Consent | OneWay" }],
    ["meta", { property: "og:description", content: "OneWay SMS opt-in, message types, frequency, rates, STOP, HELP, and privacy details." }],
    ["meta", { property: "og:url", content: "https://oneway.is/sms-consent" }],
    ["link", { rel: "canonical", href: "https://oneway.is/sms-consent" }],
  ];

  metadata.forEach(([tag, attributes]) => {
    const node = document.createElement(tag);
    node.setAttribute("data-captured-metadata", "");
    Object.entries(attributes).forEach(([name, value]) => node.setAttribute(name, value));
    document.head.appendChild(node);
  });
}

function renderSmsConsentPage() {
  setSmsConsentMetadata();
  document.body.className = "sms-consent-body";
  document.body.innerHTML = `
    <div class="sms-page-shell">
      <header class="sms-header">
        <div class="sms-header-inner">
          <a class="sms-brand" href="/" aria-label="OneWay home"><span aria-hidden="true">1</span>OneWay</a>
          <nav class="sms-nav" aria-label="Primary navigation">
            <a href="/phone">Phone</a>
            <a href="/privacy">Privacy</a>
            <a href="/terms">Terms</a>
            <a href="/contact">Contact</a>
          </nav>
          <a class="sms-header-cta" href="mailto:support@oneway.is">Get help</a>
        </div>
      </header>

      <main>
        <section class="sms-hero">
          <div class="sms-eyebrow">Public compliance page</div>
          <h1>SMS consent at OneWay</h1>
          <p class="sms-lede">This page shows exactly where OneWay presents its text-message disclosure, what users agree to receive, and how anyone can opt out.</p>
          <div class="sms-status"><span aria-hidden="true"></span>No login required to review this page</div>
        </section>

        <section class="sms-content-grid" aria-labelledby="opt-in-heading">
          <div class="sms-copy-column">
            <p class="sms-section-label">How users opt in</p>
            <h2 id="opt-in-heading">Consent is shown before a user submits a phone number.</h2>
            <p>In the OneWay app, a user opens <strong>New message</strong>, chooses <strong>Reach Outside OneWay</strong>, and voluntarily enters a phone number. The complete disclosure appears directly below the phone-number field before the user can continue.</p>
            <p>OneWay also displays this disclosure when a user adds or confirms a phone number for eligible phone, account, or support features. Providing a number is voluntary, and consent to receive SMS is not a condition of purchasing OneWay products or services.</p>
            <div class="sms-disclosure" aria-label="OneWay SMS disclosure">
              <p class="sms-disclosure-label">Disclosure shown to users</p>
              <p>${SMS_DISCLOSURE}</p>
            </div>
            <div class="sms-consent-choice">
              <input id="sms-consent-checkbox" name="sms-consent" type="checkbox" />
              <label for="sms-consent-checkbox">${SMS_OPT_IN_CHECKBOX_LABEL}</label>
            </div>
            <p class="sms-choice-note">This public example demonstrates the consent choice. It does not submit or record consent.</p>
          </div>

          <aside class="sms-phone-demo" aria-label="Example of the OneWay in-app SMS opt-in screen">
            <div class="sms-phone-top"><span>9:41</span><span aria-hidden="true">● ●●</span></div>
            <div class="sms-app-bar"><span aria-hidden="true">‹</span><strong>External message</strong><button type="button" disabled>Start</button></div>
            <div class="sms-demo-card">
              <p class="sms-demo-label">Reach Outside OneWay</p>
              <label for="sms-demo-number">Phone number or email</label>
              <input id="sms-demo-number" type="tel" value="(555) 123-4567" disabled />
              <p class="sms-demo-note">OneWay will route phone numbers through the SMS bridge.</p>
              <p class="sms-demo-disclosure">${SMS_DISCLOSURE}</p>
            </div>
            <p class="sms-demo-caption">Illustration of the disclosure placement in the OneWay app</p>
          </aside>
        </section>

        <section class="sms-details" aria-label="SMS program details">
          <article>
            <div class="sms-number">01</div>
            <h2>Messages you may receive</h2>
            <ul>
              <li>Verification and login codes</li>
              <li>Account and service alerts</li>
              <li>Call and voicemail notifications</li>
              <li>Customer-support replies</li>
              <li>Transactional and user-initiated messages</li>
            </ul>
            <p>OneWay does not send unsolicited marketing texts.</p>
          </article>
          <article>
            <div class="sms-number">02</div>
            <h2>Frequency and charges</h2>
            <p>Message frequency varies based on account activity, support requests, and communications initiated by the user.</p>
            <p>Message and data rates may apply according to the recipient's mobile plan.</p>
          </article>
          <article>
            <div class="sms-number">03</div>
            <h2>Opt out or get help</h2>
            <p>Reply <strong>STOP</strong> at any time to unsubscribe. OneWay sends a confirmation and stops messages for the applicable program.</p>
            <p>Reply <strong>HELP</strong> for assistance, visit <a href="/contact">Contact</a>, or email <a href="mailto:support@oneway.is">support@oneway.is</a>.</p>
          </article>
        </section>

        <section class="sms-privacy-band">
          <div>
            <p class="sms-section-label">Privacy promise</p>
            <h2>SMS consent stays private.</h2>
          </div>
          <div>
            <p>OneWay does not sell, rent, or share mobile phone numbers or SMS consent with third parties or affiliates for their marketing or promotional purposes.</p>
            <div class="sms-policy-links">
              <a href="/privacy">Privacy Policy <span aria-hidden="true">↗</span></a>
              <a href="/terms">Terms of Service <span aria-hidden="true">↗</span></a>
              <a href="/acceptable-use">Acceptable Use <span aria-hidden="true">↗</span></a>
            </div>
          </div>
        </section>
      </main>

      <footer class="sms-footer">
        <a class="sms-brand sms-footer-brand" href="/"><span aria-hidden="true">1</span>OneWay</a>
        <p>Questions about SMS consent? <a href="mailto:support@oneway.is">support@oneway.is</a></p>
        <p>© 2026 OneWay</p>
      </footer>
    </div>
  `;
}

function appendLaunchPrivacyDisclosure(sourceDocument) {
  if (window.location.pathname !== "/privacy") return;

  const main = sourceDocument.querySelector("main");
  if (!main || sourceDocument.querySelector("#oneway-launch-privacy")) return;

  const mobileInformationSection = sourceDocument.createElement("section");
  mobileInformationSection.id = "oneway-mobile-information";
  mobileInformationSection.setAttribute("aria-labelledby", "oneway-mobile-information-title");
  mobileInformationSection.style.cssText = "max-width:72rem;margin:5rem auto 1.5rem;padding:2rem;border:1px solid rgba(124,58,237,.35);border-radius:1.5rem;background:#f8f5ff;color:#171321";
  mobileInformationSection.innerHTML = `
    <p style="margin:0 0 .5rem;font-size:.8rem;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:#6d28d9">Mobile information and SMS consent</p>
    <h2 id="oneway-mobile-information-title" style="margin:0 0 1rem;font-size:clamp(1.75rem,4vw,2.5rem);line-height:1.1">Your mobile information is not used for third-party marketing.</h2>
    <p style="margin:0;font-size:1.05rem;font-weight:650;line-height:1.7;color:#3f3749">Mobile information, including phone numbers and SMS consent records, will not be shared with third parties or affiliates for marketing or promotional purposes.</p>
  `;
  main.appendChild(mobileInformationSection);

  const section = sourceDocument.createElement("section");
  section.id = "oneway-launch-privacy";
  section.setAttribute("aria-labelledby", "oneway-launch-privacy-title");
  section.style.cssText = "max-width:72rem;margin:0 auto 5rem;padding:2rem;border:1px solid rgba(124,58,237,.35);border-radius:1.5rem;background:rgba(124,58,237,.08);color:inherit";
  section.innerHTML = `
    <p style="margin:0 0 .5rem;font-size:.8rem;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:#a78bfa">Launch privacy controls</p>
    <h2 id="oneway-launch-privacy-title" style="margin:0 0 1rem;font-size:clamp(1.75rem,4vw,2.5rem);line-height:1.1">Disappearing messages and account deletion</h2>
    <div style="display:grid;gap:1.5rem;grid-template-columns:repeat(auto-fit,minmax(13rem,1fr));line-height:1.65">
      <div>
        <h3 style="margin:0 0 .5rem;font-size:1.2rem">Disappear After Read</h3>
        <p style="margin:0">For eligible OneWay chats, the timer starts only after every recipient visibly opens the message in the foreground. Push delivery, previews, background sync, indexing, and badge updates do not start it. At expiry, OneWay removes active message content and OneWay-managed attachments and keeps only minimal synchronization records.</p>
      </div>
      <div>
        <h3 style="margin:0 0 .5rem;font-size:1.2rem">Limits you should know</h3>
        <p style="margin:0">OneWay cannot prevent screenshots, photos of a screen, or copies saved outside OneWay. In-app controls can restrict copying, forwarding, and saving inside OneWay, but they cannot erase recipient-held copies or data controlled by outside services.</p>
      </div>
      <div>
        <h3 style="margin:0 0 .5rem;font-size:1.2rem">Burn My OneWay Account</h3>
        <p style="margin:0">The in-app flow shows affected data, offers an export, verifies your password and exact confirmation phrase, and supports immediate, 24-hour, 7-day, or 30-day scheduling. During a recovery window your account and public identity are disabled; the recovery token saved on your device can cancel the request.</p>
      </div>
      <div>
        <h3 style="margin:0 0 .5rem;font-size:1.2rem">Retention and backups</h3>
        <p style="margin:0">Eligible active data is deleted after the recovery window. Records required for financial, tax, telecom, fraud, disputes, safety, or legal obligations may be restricted and retained. Backups are blocked from restoration and expire on OneWay's schedule, currently up to 35 days by default.</p>
      </div>
    </div>
  `;
  main.appendChild(section);
}

async function renderCapturedPage() {
  if (window.location.pathname === "/sms-consent" || window.location.pathname === "/sms-consent/") {
    renderSmsConsentPage();
    return;
  }

  const response = await fetch(capturePath());
  if (!response.ok) throw new Error(`Unable to load page (${response.status})`);

  const sourceDocument = new DOMParser().parseFromString(
    await response.text(),
    "text/html",
  );

  sourceDocument.body
    .querySelectorAll('script:not([type="application/ld+json"])')
    .forEach((node) => node.remove());
  sourceDocument
    .querySelector("#codex-browser-sidebar-comments-root")
    ?.remove();

  appendLaunchPrivacyDisclosure(sourceDocument);

  syncMetadata(sourceDocument);
  document.body.className = sourceDocument.body.className;
  document.body.replaceChildren(...sourceDocument.body.childNodes);
}

renderCapturedPage().catch(() => {
  document.body.innerHTML = `
    <main class="site-load-error">
      <p>OneWay</p>
      <h1>This page could not be loaded.</h1>
      <a href="/">Return home</a>
    </main>
  `;
});
