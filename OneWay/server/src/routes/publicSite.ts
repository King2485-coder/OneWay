import express from "express";
import { prisma } from "../lib/db";

type Page = {
  path: string;
  title: string;
  description: string;
  body: string;
};

// Public, compliance-oriented pages for Twilio A2P 10DLC review.
// These must be reachable without auth and avoid exposing any internal/admin details.
export function publicSiteRouter(): express.Router {
  const router = express.Router();

  router.get("/favicon.ico", (_req, res) => {
    // Avoid noisy 404s during compliance review. A real favicon can be added later.
    res.status(204).end();
  });

  router.get("/robots.txt", (_req, res) => {
    res.type("text/plain").send("User-agent: *\nAllow: /\n");
  });

  router.get("/", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/"]));
  });
  router.get("/about", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/about"]));
  });
  router.get("/contact", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/contact"]));
  });
  router.get("/start", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/start"]));
  });
  router.get("/support", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/support"]));
  });
  router.get("/delete-account", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/delete-account"]));
  });
  router.get("/privacy", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/privacy"]));
  });
  router.get("/terms", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/terms"]));
  });
  router.get("/sms", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/sms"]));
  });
  router.get("/sms-consent", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/sms-consent"]));
  });
  router.get("/acceptable-use", (_req, res) => {
    res.type("html").send(renderPage(PUBLIC_SITE_PAGES["/acceptable-use"]));
  });

  router.get("/:slug", async (req, res, next) => {
    const host = String(req.hostname ?? req.headers.host ?? "").split(":")[0].toLowerCase();
    if (host !== "sites.oneway.app") return next();

    const slug = normalizePublishedSiteSlug(String(req.params.slug ?? ""));
    if (!slug) return res.status(400).type("html").send(renderUnavailableSite("Invalid OneWay Site address."));

    const site = await prisma.site.findFirst({
      where: {
        OR: [
          { slug },
          { domain: `${slug}.oneway.app` },
          { domain: `${slug}.oneway.site` },
        ],
      },
    });
    if (!site || site.status !== "PUBLISHED" || !site.activePublicationId || !["PUBLIC", "UNLISTED"].includes(site.visibility ?? "PUBLIC")) {
      return res.status(404).type("html").send(renderUnavailableSite("This OneWay Site is not published yet."));
    }

    const publication = await prisma.sitePublication.findFirst({
      where: { id: site.activePublicationId, siteId: site.id, status: "ACTIVE" },
    });
    if (!publication) {
      return res.status(409).type("html").send(renderUnavailableSite("This OneWay Site publication is temporarily unavailable."));
    }

    const manifest = parsePublishedSiteManifest(publication.contentManifest);
    const html = String(manifest.html ?? site.publishedHtml ?? "").trim();
    if (!html) {
      return res.status(409).type("html").send(renderUnavailableSite("This OneWay Site returned an empty publication."));
    }

    console.info("KING_LOGISTICS_PUBLIC_URL_200", {
      siteId: site.id,
      publicationId: publication.id,
      slug,
      host,
    });
    res.type("html").send(html);
  });

  return router;
}

function normalizePublishedSiteSlug(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\/sites\.oneway\.app\//, "")
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function parsePublishedSiteManifest(raw: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function renderUnavailableSite(message: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Site Unavailable</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f7f4ff;color:#171321;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}.card{max-width:520px;margin:24px;padding:32px;border-radius:28px;background:white;border:1px solid #e4d9fa;box-shadow:0 24px 60px rgba(70,41,130,.14)}h1{margin:0 0 10px;font-size:34px}p{color:#6f687d;font-size:17px}</style></head><body><main class="card"><h1>Site Unavailable</h1><p>${escapeHtml(message)}</p></main></body></html>`;
}

const BRAND = "OneWay";
const SUPPORT_EMAIL = "support@oneway.is";
const LEGAL_EMAIL = "legal@oneway.is";
const ABUSE_EMAIL = "abuse@oneway.is";
const CARRIER_EMAIL = "carrier@oneway.is";
const PUBLIC_SITE_ORIGIN = "https://oneway.is";
const SOCIAL_PREVIEW_URL = `${PUBLIC_SITE_ORIGIN}/assets/oneway-social-preview.png`;

// Required Twilio disclosure text.
const SMS_CTA_DISCLOSURE =
  "By providing your phone number, you agree to receive OneWay SMS messages for verification, account alerts, service notifications, support, and user-initiated communications. Message frequency varies. Message and data rates may apply. Reply STOP to opt out or HELP for help.";

const SMS_OPT_IN_CHECKBOX_LABEL =
  "I agree to receive transactional and account-related text messages from OneWay, including verification codes, security alerts, missed-call notifications, invitations, and requested reminders. Message frequency varies. Message and data rates may apply. Reply STOP to opt out or HELP for help. SMS consent is optional and is not required to create an account, use OneWay, or purchase OneWay products or services.";

export const PUBLIC_SITE_PAGES: Record<string, Page> = {
  "/": {
    path: "/",
    title: `${BRAND} | One private platform for communication, commerce, and work`,
    description:
      "OneWay brings private messaging, calls, video, Chirp, Communities, Quantum browsing, Sites, Shops, Ads, Wallet, and business tools into one platform. Plans start at $13/month.",
    body: `
      <section class="product-hero" id="plans">
        <div class="hero-copy">
          <p class="eyebrow">The private everything app</p>
          <h1>One place to talk, build, sell, and belong.</h1>
          <p class="lede">Private messages, Communities, HD calls, video, Chirp, Quantum browsing, Sites, Shops, Ads, Wallet, and creator tools—connected by one identity you control.</p>
          <p class="price-line">Plans start at $13/month with two OneWay numbers included.</p>
          <div class="actions">
            <a class="button primary" href="/start">Start for $13/month</a>
            <a class="button secondary" href="#pricing">Compare plans</a>
          </div>
          <div class="hero-proof" aria-label="OneWay highlights">
            <span>Private by default</span><span>2 numbers included</span><span>One connected platform</span>
          </div>
        </div>
      </section>

      <section class="product-band" id="features">
        <div class="section-heading">
          <p class="eyebrow">Everything in OneWay</p>
          <h2>More than a phone service. A private operating layer for your digital life.</h2>
          <p class="section-copy">Every area uses the same OneWay identity, privacy controls, contacts, and communication layer.</p>
        </div>
        <div class="feature-grid">
          <article>
            <span>LIVE</span>
            <h3>Messages &amp; Communities</h3>
            <p>Private one-to-one chats plus shared spaces, replies, mentions, reactions, receipts, voice notes, documents, and rich conversations.</p>
          </article>
          <article>
            <span>LIVE</span>
            <h3>Calls, video &amp; Chirp</h3>
            <p>HD OneWay voice and video, CallKit integration, voicemail, recents, contacts, and instant push-to-talk channels.</p>
          </article>
          <article>
            <span>LIVE</span>
            <h3>Private identity</h3>
            <p>Two included OneWay numbers, caller controls, profile privacy, safety tools, device protection, and separate public and private identities.</p>
          </article>
          <article>
            <span>LIVE</span>
            <h3>Quantum &amp; Portal apps</h3>
            <p>Private browsing, tabs, history controls, downloads, and a customizable launchpad for the web services you use most.</p>
          </article>
          <article>
            <span>BETA</span>
            <h3>OneWay Sites</h3>
            <p>Build with AI or templates, edit every section, connect a OneWay domain, publish, manage forms, and track performance.</p>
          </article>
          <article>
            <span>BETA</span>
            <h3>Shops &amp; Seller Studio</h3>
            <p>Discover products, launch a storefront, manage listings and orders, message customers, accept payments, and grow with seller analytics.</p>
          </article>
          <article>
            <span>BETA</span>
            <h3>OneWay Ads</h3>
            <p>Create campaigns, choose placements and audiences, control spend, pass moderation, and measure verified delivery and conversion events.</p>
          </article>
          <article>
            <span>PREVIEW</span>
            <h3>Wallet, AI &amp; Workspace</h3>
            <p>A connected layer for payments, rewards, private files, AI-assisted work, team chat, projects, tasks, calendar, and creator workflows.</p>
          </article>
        </div>
      </section>

      <section class="pricing-band" id="pricing">
        <div class="section-heading">
          <p class="eyebrow">Plans</p>
          <h2>Start private. Add power when you need it.</h2>
          <p class="section-copy">All prices are USD. App Store availability and taxes may vary.</p>
        </div>
        <div class="pricing-grid">
          <article>
            <p class="plan-name">OneWay Basic</p>
            <div class="plan-price"><strong>$13</strong><span>/month</span></div>
            <p>Private communication and your essential OneWay identity.</p>
            <ul class="home-check-list">
              <li>2 OneWay numbers included</li>
              <li>Private messages and Communities</li>
              <li>OneWay voice, video, and Chirp</li>
              <li>Voicemail, recents, and contacts</li>
              <li>Quantum browser and Portal apps</li>
            </ul>
            <a class="button secondary" href="/start">Choose Basic</a>
          </article>
          <article class="featured-plan">
            <p class="plan-badge">Most popular</p>
            <p class="plan-name">OneWay Plus</p>
            <div class="plan-price"><strong>$19</strong><span>/month</span></div>
            <p>More control for people who live and communicate in OneWay.</p>
            <ul class="home-check-list">
              <li>Everything in Basic</li>
              <li>Enhanced voicemail and forwarding</li>
              <li>Expanded caller and contact controls</li>
              <li>Priority Chirp presence</li>
              <li>Stronger identity separation</li>
            </ul>
            <a class="button primary" href="/start">Choose Plus</a>
          </article>
          <article>
            <p class="plan-name">OneWay Pro</p>
            <div class="plan-price"><strong>$29</strong><span>/month</span></div>
            <p>For creators and sellers building a public presence.</p>
            <ul class="home-check-list">
              <li>Everything in Plus</li>
              <li>Creator and Seller Studio tools</li>
              <li>Shop storefront and customer contact</li>
              <li>Domain and email identity support</li>
              <li>Advanced privacy separation</li>
            </ul>
            <a class="button secondary" href="/start">Choose Pro</a>
          </article>
          <article>
            <p class="plan-name">OneWay Business</p>
            <div class="plan-price"><strong>$49+</strong><span>/month</span></div>
            <p>Team-ready communication, commerce, and identity.</p>
            <ul class="home-check-list">
              <li>Multiple seats and team numbers</li>
              <li>Shared communication workflows</li>
              <li>Business Shop and Sites</li>
              <li>Domains and email identities</li>
              <li>Priority setup and branded caller ID support</li>
            </ul>
            <a class="button secondary" href="/contact">Contact sales</a>
          </article>
        </div>
      </section>

      <section class="addons-band" id="add-ons">
        <div class="section-heading">
          <p class="eyebrow">Add-ons &amp; seller pricing</p>
          <h2>Clear prices for the extras you choose.</h2>
        </div>
        <div class="addon-grid">
          <article><p class="mini-label">Numbers</p><h3>$7.99/month</h3><p>Add more OneWay numbers after your first two included numbers.</p></article>
          <article><p class="mini-label">OneWay domain</p><h3>$3.99/year</h3><p>Claim a renewable <strong>.oneway.app</strong> name for Sites, Shops, or your public identity.</p></article>
          <article><p class="mini-label">Start selling</p><h3>Included</h3><p>Your first Shop and 10 active product listings are included.</p></article>
          <article><p class="mini-label">Seller Pro</p><h3>$14.99/month</h3><p>Unlimited listings, up to 10 Shops, advanced analytics, and priority seller benefits as available.</p></article>
          <article><p class="mini-label">Product capacity</p><h3>From $0.99</h3><p>Monthly or permanent listing packs, including unlimited permanent capacity for $99.</p></article>
          <article><p class="mini-label">Shop capacity</p><h3>From $1</h3><p>Add permanent Shop slots individually or in 3, 5, and 10-Shop bundles.</p></article>
          <article><p class="mini-label">Marketplace fee</p><h3>$0.30/order</h3><p>A fixed OneWay platform fee applies to each paid marketplace order; payment processing is separate.</p></article>
          <article><p class="mini-label">Ads</p><h3>You control spend</h3><p>Campaign tools use budgets, verified delivery, and pricing snapshots. You choose the campaign amount.</p></article>
        </div>
      </section>

      <section class="closing-band">
        <p class="eyebrow">Built around you</p>
        <h2>Your conversations, your identity, your business—moving OneWay.</h2>
        <p>Start with private communication today. Explore beta and preview features as they become available to your account.</p>
        <div class="actions">
          <a class="button primary" href="/start">Start for $13/month</a>
          <a class="button secondary" href="/privacy">See our privacy approach</a>
        </div>
      </section>
    `,
  },

  "/start": {
    path: "/start",
    title: `${BRAND} | Start phone service`,
    description: "Start OneWay private phone service for $13/month.",
    body: `
      <section class="hero">
        <p class="eyebrow">OneWay phone service</p>
        <h1>Start private phone service.</h1>
        <p class="lede">Set up OneWay Basic for $13/month with two OneWay numbers included, then complete the purchase handoff.</p>
      </section>

      <section class="checkout-flow" data-checkout-flow>
        <div class="checkout-steps" aria-label="Checkout steps">
          <span class="is-active" data-step-label="1">Plan</span>
          <span data-step-label="2">Account</span>
          <span data-step-label="3">Number</span>
          <span data-step-label="4">Purchase</span>
        </div>

        <form class="checkout-form" data-checkout-form>
          <fieldset data-step="1">
            <legend>Review your plan</legend>
            <div class="plan-summary">
              <div>
                <strong>OneWay private phone service</strong>
                <p>$13/month with two OneWay numbers included. Private OneWay-to-OneWay communication is included.</p>
              </div>
              <span>$13/mo</span>
            </div>
            <ul class="check-list">
              <li>Two OneWay numbers included</li>
              <li>Private OneWay calls, video, Chirp, and messaging</li>
              <li>Communities, Quantum browsing, and access to creator tools</li>
            </ul>
          </fieldset>

          <fieldset data-step="2" hidden>
            <legend>Create your service profile</legend>
            <label>
              Full name
              <input name="name" autocomplete="name" required />
            </label>
            <label>
              Email
              <input name="email" type="email" autocomplete="email" required />
            </label>
            <label>
              Mobile number
              <input name="phone" type="tel" autocomplete="tel" required />
            </label>
          </fieldset>

          <fieldset data-step="3" hidden>
            <legend>Choose your first number setup</legend>
            <label>
              Service number
              <select name="numberSetup" required>
                <option value="">Select an option</option>
                <option value="new-number">Get a new OneWay number</option>
                <option value="port-number">Bring my current number</option>
                <option value="decide-later">Decide after purchase</option>
              </select>
            </label>
            <label>
              Setup notes
              <textarea name="notes" placeholder="Preferred area code, current carrier, or anything we should know."></textarea>
            </label>
          </fieldset>

          <fieldset data-step="4" hidden>
            <legend>Complete purchase</legend>
            <div class="plan-summary">
              <div>
                <strong>Total due today</strong>
                <p>OneWay private phone service subscription.</p>
              </div>
              <span>$13</span>
            </div>
            <label class="consent-row">
              <input name="consent" type="checkbox" required />
              <span>I agree to the <a href="/terms">Terms</a>, <a href="/privacy">Privacy Policy</a>, and service-related SMS notices for setup and account alerts.</span>
            </label>
            <p class="callout">After you confirm, OneWay will open the purchase handoff with your setup details so the service purchase can be completed.</p>
          </fieldset>

          <p class="form-status" data-form-status aria-live="polite"></p>
          <div class="checkout-actions">
            <button class="button secondary" type="button" data-prev hidden>Back</button>
            <button class="button primary" type="button" data-next>Continue</button>
            <button class="button primary" type="submit" data-submit hidden>Complete purchase</button>
          </div>
        </form>
      </section>

      <script>
        (() => {
          const form = document.querySelector("[data-checkout-form]");
          if (!form) return;

          const steps = Array.from(form.querySelectorAll("[data-step]"));
          const labels = Array.from(document.querySelectorAll("[data-step-label]"));
          const prev = form.querySelector("[data-prev]");
          const next = form.querySelector("[data-next]");
          const submit = form.querySelector("[data-submit]");
          const status = form.querySelector("[data-form-status]");
          let index = 0;

          const update = () => {
            steps.forEach((step, stepIndex) => {
              step.hidden = stepIndex !== index;
            });
            labels.forEach((label, labelIndex) => {
              label.classList.toggle("is-active", labelIndex === index);
              label.classList.toggle("is-complete", labelIndex < index);
            });
            prev.hidden = index === 0;
            next.hidden = index === steps.length - 1;
            submit.hidden = index !== steps.length - 1;
            status.textContent = "";
          };

          const currentStepIsValid = () => {
            const controls = Array.from(steps[index].querySelectorAll("input, select, textarea"));
            for (const control of controls) {
              if (!control.checkValidity()) {
                control.reportValidity();
                return false;
              }
            }
            return true;
          };

          next.addEventListener("click", () => {
            if (!currentStepIsValid()) return;
            index = Math.min(index + 1, steps.length - 1);
            update();
          });

          prev.addEventListener("click", () => {
            index = Math.max(index - 1, 0);
            update();
          });

          form.addEventListener("submit", (event) => {
            event.preventDefault();
            if (!currentStepIsValid()) return;

            const data = new FormData(form);
            const subject = "Start OneWay private phone service";
            const body = [
              "I am ready to complete the $13/month OneWay service purchase.",
              "",
              "Name: " + (data.get("name") || ""),
              "Email: " + (data.get("email") || ""),
              "Mobile number: " + (data.get("phone") || ""),
              "Number setup: " + (data.get("numberSetup") || ""),
              "Setup notes: " + (data.get("notes") || "")
            ].join("\\n");

            status.textContent = "Opening the purchase handoff...";
            window.location.href = "mailto:${SUPPORT_EMAIL}?subject=" + encodeURIComponent(subject) + "&body=" + encodeURIComponent(body);
          });

          update();
        })();
      </script>
    `,
  },

  "/about": {
    path: "/about",
    title: `${BRAND} | About`,
    description: "Learn about OneWay and how it helps small businesses communicate and manage storefront inquiries.",
    body: `
      <section class="hero">
        <h1>About OneWay</h1>
        <p class="lede">OneWay is a business communication and storefront platform for small teams, independent sellers, and service providers.</p>
      </section>

      <section class="grid two">
        <article>
          <h2>What OneWay does</h2>
          <ul>
            <li>Create a simple online presence for your business.</li>
            <li>Communicate with customers from one place.</li>
            <li>Receive storefront inquiry notifications and service-related alerts.</li>
            <li>Send verification codes and account notifications when needed.</li>
          </ul>
        </article>
        <article>
          <h2>Who it is for</h2>
          <p>OneWay is built for businesses that need practical customer communication without exposing internal tools, private account data, or admin systems on the public web.</p>
        </article>
      </section>

      <section class="band">
        <h2>Messaging standards</h2>
        <p>OneWay supports service-related messaging only. Users must have permission to contact recipients, honor opt-out requests, and avoid spam, harassment, deceptive activity, or unlawful content.</p>
      </section>
    `,
  },

  "/support": {
    path: "/support",
    title: `${BRAND} | Support`,
    description: "OneWay support, HELP instructions, account assistance, and messaging support.",
    body: `
      <section class="hero">
        <h1>Support</h1>
        <p class="lede">Get help with your OneWay account, business profile, messaging consent, or service notifications.</p>
      </section>

      <section class="grid two">
        <article>
          <h2>Contact support</h2>
          <p>Email: <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
          <p>For legal or privacy questions, email <a href="mailto:${LEGAL_EMAIL}">${LEGAL_EMAIL}</a>.</p>
          <p>For abuse reports, email <a href="mailto:${ABUSE_EMAIL}">${ABUSE_EMAIL}</a>.</p>
        </article>
        <article>
          <h2>SMS help</h2>
          <p>Reply <strong>HELP</strong> to a OneWay text message for assistance. Reply <strong>STOP</strong> to opt out of future text messages from that messaging program.</p>
        </article>
      </section>

      <section class="band">
        <h2>Before you contact us</h2>
        <p>Include the email address or phone number associated with your account, a short description of the issue, and any relevant message timestamp. Do not send passwords, private keys, or payment card details by email.</p>
      </section>
    `,
  },

  "/delete-account": {
    path: "/delete-account",
    title: `${BRAND} | Delete Account`,
    description: "Request deletion of a OneWay account and associated data.",
    body: `
      <section class="hero">
        <h1>Delete your account</h1>
        <p class="lede">You can request deletion of your OneWay account and associated data at any time.</p>
      </section>

      <section>
        <h2>How to request deletion</h2>
        <ul>
          <li>In OneWay, open <strong>Settings → Privacy &amp; Identity → Burn My OneWay Account</strong>.</li>
          <li>Review the account summary, export data if desired, choose a recovery window, verify your password, and type the required confirmation phrase.</li>
          <li>If you cannot access the app, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> from the address associated with your account for assisted verification.</li>
        </ul>
      </section>

      <section class="band">
        <h2>What deletion covers</h2>
        <p>Eligible profile, messaging, email, site, shop, community, contact, device, and app-managed personal data is removed from active OneWay systems. Subscriptions are cancelled and public resources are hidden when a burn is confirmed. Financial, tax, telecom, fraud, dispute, safety, and transaction records may be retained where required and are restricted or de-identified where possible.</p>
        <p>Active data is removed by the deletion orchestrator. Historical backups are marked for non-restoration and expire on OneWay’s backup schedule (currently up to 35 days by default). Copies saved, forwarded, exported, or captured by another person and caches controlled by external systems cannot be guaranteed deleted by OneWay.</p>
      </section>
    `,
  },

  "/contact": {
    path: "/contact",
    title: `${BRAND} | Contact`,
    description: "Contact OneWay support.",
    body: `
      <section class="hero">
        <h1>Contact</h1>
        <p class="lede">Need help with your OneWay account or messaging? Contact our support team.</p>
      </section>

      <section class="grid two">
        <article>
          <h2>Support</h2>
          <p>Email: <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
          <p>Use this address for account access, messaging, billing, storefront, and product support.</p>
        </article>
        <article>
          <h2>Business and compliance</h2>
          <p>For business, privacy, or compliance questions, email <a href="mailto:${LEGAL_EMAIL}">${LEGAL_EMAIL}</a>.</p>
          <p>For abuse reports, spam complaints, or caller ID/carrier questions, email <a href="mailto:${ABUSE_EMAIL}">${ABUSE_EMAIL}</a> or <a href="mailto:${CARRIER_EMAIL}">${CARRIER_EMAIL}</a>.</p>
          <p>For SMS help, reply <strong>HELP</strong>. To opt out of SMS, reply <strong>STOP</strong>.</p>
        </article>
      </section>
    `,
  },

  "/privacy": {
    path: "/privacy",
    title: `${BRAND} | Privacy Policy`,
    description: "OneWay privacy policy and SMS consent handling.",
    body: `
      <section class="hero">
        <h1>Privacy Policy</h1>
        <p class="lede">This policy explains what OneWay collects, how we use it, and your choices.</p>
      </section>

      <section>
        <h2>Information we collect</h2>
        <ul>
          <li>Account information (such as username, OneWay ID, and contact email).</li>
          <li>Phone numbers you add to your account and phone numbers you choose to message or call.</li>
          <li>Messaging metadata and content needed to deliver and support service-related communications.</li>
          <li>Storefront information you publish and related inquiry/notification data.</li>
          <li>Device/app diagnostics needed to keep the service reliable.</li>
        </ul>
      </section>

      <section>
        <h2>Phone numbers and messaging data</h2>
        <p>OneWay may use phone numbers and messaging data to provide verification, account/service notifications, storefront inquiry notifications, customer communication alerts, support messages, and user-initiated communications.</p>
        <p><strong>Mobile information, including phone numbers and SMS consent records, will not be shared with third parties or affiliates for marketing or promotional purposes.</strong></p>
      </section>

      <section>
        <h2>How we use information</h2>
        <ul>
          <li>Provide and maintain OneWay account, storefront, messaging, and support features.</li>
          <li>Send account verification, service, security, and customer communication notifications.</li>
          <li>Prevent abuse, investigate security issues, and comply with legal obligations.</li>
          <li>Improve reliability, diagnostics, and customer support.</li>
        </ul>
      </section>

      <section>
        <h2>Sharing</h2>
        <p>We may use service providers to host the service, deliver messages, process support requests, provide analytics, detect abuse, process payments, support telecom compliance, or meet carrier and messaging-program requirements. These providers may process information only as needed to provide services to OneWay.</p>
        <p>Our communications providers may include Twilio or similar telecommunications vendors used to deliver SMS, voice, and related service messages.</p>
        <p>We do not sell personal information. Mobile information, including phone numbers and SMS consent records, will not be shared with third parties or affiliates for marketing or promotional purposes.</p>
      </section>

      <section>
        <h2>SMS consent and opt-out</h2>
        <p>${escapeHtml(SMS_CTA_DISCLOSURE)}</p>
        <ul>
          <li>Opt out: Reply <strong>STOP</strong> to any message.</li>
          <li>Help: Reply <strong>HELP</strong> or email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</li>
        </ul>
        <p>OneWay uses minimal privacy-first defaults. We collect and retain only what is needed to provide the service, honor opt-out requests, prevent abuse, and satisfy payment, telecom, legal, and carrier obligations.</p>
      </section>

      <section>
        <h2>Deletion requests</h2>
        <p>You can use the in-app Burn Button flow or contact <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>. The in-app flow shows affected data, offers an optional export, requires password and typed confirmation, and offers immediate, 24-hour, 7-day, or 30-day scheduling. During a recovery window the account is disabled and hidden. See <a href="/delete-account">Delete Account</a>.</p>
      </section>

      <section>
        <h2>Disappearing messages</h2>
        <p>Eligible OneWay chats may be configured so new messages disappear after all recipients visibly open them in the foreground and the selected timer ends. Push delivery, background sync, previews, indexing, and badge updates do not start the timer. At expiry, OneWay removes active message content and managed attachments and retains only minimal synchronization tombstones.</p>
        <p>Disappearing messages do not prevent recipients from taking screenshots, photographing a screen, copying or forwarding content before expiry, saving files outside OneWay, or retaining content through systems OneWay does not control. Settings that block copying, forwarding, or saving apply only inside OneWay.</p>
      </section>

      <section>
        <h2>Security</h2>
        <p>We use reasonable technical and organizational measures to protect data. Some OneWay features may use encryption for privacy and integrity, but no system can be guaranteed 100% secure.</p>
      </section>

      <section>
        <h2>Contact</h2>
        <p>Email: <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
        <p>Privacy and legal: <a href="mailto:${LEGAL_EMAIL}">${LEGAL_EMAIL}</a></p>
      </section>
    `,
  },

  "/terms": {
    path: "/terms",
    title: `${BRAND} | Terms of Service`,
    description: "OneWay terms of service, acceptable use, and SMS terms.",
    body: `
      <section class="hero">
        <h1>Terms of Service</h1>
        <p class="lede">By using OneWay, you agree to these terms.</p>
      </section>

      <section>
        <h2>Acceptable use</h2>
        <ul>
          <li>No spam, harassment, or abusive messaging.</li>
          <li>No fraudulent, deceptive, or illegal activity.</li>
          <li>You are responsible for obtaining consent from your contacts before messaging them.</li>
          <li>You may not use OneWay to send prohibited content, phishing attempts, malware, or content that violates carrier rules.</li>
          <li>You may not evade carrier registration, filtering, opt-out, or caller ID requirements.</li>
        </ul>
        <p>OneWay may suspend or terminate accounts, stores, numbers, caller IDs, or messaging access for misuse, suspected abuse, carrier rule violations, missing consent, or unlawful activity.</p>
      </section>

      <section>
        <h2>Storefront and customer communication</h2>
        <ul>
          <li>Storefront inquiry and order-related communications must be service-related and relevant to the customer interaction.</li>
          <li>You must honor opt-out requests promptly.</li>
        </ul>
      </section>

      <section>
        <h2>SMS terms</h2>
        <ul>
          <li>Message frequency varies.</li>
          <li>Message and data rates may apply.</li>
          <li>To opt out, reply <strong>STOP</strong>.</li>
          <li>For help, reply <strong>HELP</strong> or email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</li>
        </ul>
        <p>${escapeHtml(SMS_CTA_DISCLOSURE)}</p>
        <p>Users must have consent before sending texts or inviting OneWay to send service-related messages to another person. Unsolicited marketing, spam, harassment, phishing, impersonation, or other abusive messaging is prohibited.</p>
      </section>

      <section>
        <h2>Account deletion</h2>
        <p>You may request account deletion by contacting <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> or visiting <a href="/delete-account">Delete Account</a>. Some records may be retained where required for security, fraud prevention, legal compliance, disputes, or transaction history.</p>
      </section>

      <section>
        <h2>Contact</h2>
        <p>Email: <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
      </section>
    `,
  },

  "/sms": {
    path: "/sms",
    title: `${BRAND} | SMS Policy`,
    description: "SMS consent, opt-in, opt-out, STOP, HELP, and support instructions for OneWay text messages.",
    body: `
      <section class="hero">
        <h1>SMS Policy</h1>
        <p class="lede">This page explains what text messages OneWay may send, how users opt in, and how any recipient can opt out.</p>
      </section>

      <section>
        <h2>What messages you may receive</h2>
        <ul>
          <li>Verification codes</li>
          <li>Login authentication messages</li>
          <li>Account notifications</li>
          <li>Call and voicemail notifications</li>
          <li>Service alerts</li>
          <li>Customer support conversations</li>
          <li>Transactional updates</li>
          <li>User-initiated communications</li>
          <li>Support messages</li>
        </ul>
        <p>OneWay does not send unsolicited marketing texts. Message frequency varies. Message and data rates may apply.</p>
      </section>

      <section>
        <h2>How you opt in</h2>
        <p>OneWay users voluntarily provide their phone number during account setup or profile/contact setup. Users also opt in when enabling messaging features, requesting support, or choosing to receive service-related communication alerts.</p>
        <p class="callout">${escapeHtml(SMS_CTA_DISCLOSURE)}</p>
      </section>

      <section>
        <h2>Consent requirements</h2>
        <p>OneWay users must have permission before sending SMS messages to another person or business. OneWay does not permit unsolicited marketing, purchased contact lists, spam, phishing, deceptive messages, harassment, or illegal content.</p>
      </section>

      <section>
        <h2>How you opt out</h2>
        <ul>
          <li>Reply <strong>STOP</strong> to opt out.</li>
          <li>If you need help, reply <strong>HELP</strong> or contact <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</li>
        </ul>
        <p>Opt-out requests are honored for the applicable OneWay messaging program.</p>
      </section>

      <section>
        <h2>Support and policies</h2>
        <p>Email: <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
        <p>Abuse reports: <a href="mailto:${ABUSE_EMAIL}">${ABUSE_EMAIL}</a></p>
        <p>Carrier or caller ID questions: <a href="mailto:${CARRIER_EMAIL}">${CARRIER_EMAIL}</a></p>
        <p>Review the <a href="/privacy">Privacy Policy</a>, <a href="/terms">Terms of Service</a>, and <a href="/acceptable-use">Acceptable Use Policy</a>.</p>
      </section>
    `,
  },

  "/sms-consent": {
    path: "/sms-consent",
    title: `${BRAND} | SMS Consent`,
    description: "SMS consent, opt-in, opt-out, and HELP instructions for OneWay text messages.",
    body: `
      <section class="hero">
        <h1>SMS Consent</h1>
        <p class="lede">This public page shows where OneWay presents its SMS disclosure, what users agree to receive, and how anyone can opt out.</p>
      </section>

      <section>
        <h2>How users opt in</h2>
        <p>In the OneWay app, a user opens <strong>New message</strong>, chooses <strong>Reach Outside OneWay</strong>, and voluntarily enters a phone number. The complete disclosure appears directly below the phone-number field before the user can continue.</p>
        <p>OneWay also displays the disclosure when a user adds or confirms a phone number for eligible phone, account, or support features. Providing a number is voluntary, and consent to receive SMS is not a condition of purchasing OneWay products or services.</p>
        <p class="callout">${escapeHtml(SMS_CTA_DISCLOSURE)}</p>
        <div class="consent-row">
          <input id="sms-consent-checkbox" name="sms-consent" type="checkbox" />
          <label for="sms-consent-checkbox">${escapeHtml(SMS_OPT_IN_CHECKBOX_LABEL)}</label>
        </div>
        <p><small>This public example demonstrates the consent choice. It does not submit or record consent.</small></p>
      </section>

      <section>
        <h2>What messages users may receive</h2>
        <ul>
          <li>Verification and login codes</li>
          <li>Account and service alerts</li>
          <li>Call and voicemail notifications</li>
          <li>Customer-support replies</li>
          <li>Transactional and user-initiated messages</li>
        </ul>
        <p>OneWay does not send unsolicited marketing texts. Message frequency varies. Message and data rates may apply.</p>
      </section>

      <section>
        <h2>Opt out or get help</h2>
        <p>Reply <strong>STOP</strong> at any time to unsubscribe. Reply <strong>HELP</strong> for assistance, visit <a href="/support">Support</a>, or email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>
      </section>

      <section>
        <h2>SMS privacy</h2>
        <p><strong>OneWay does not sell, rent, or share mobile phone numbers or SMS consent with third parties or affiliates for their marketing or promotional purposes.</strong></p>
        <p>Review the <a href="/sms">full SMS Policy</a>, <a href="/privacy">Privacy Policy</a>, <a href="/terms">Terms of Service</a>, and <a href="/acceptable-use">Acceptable Use Policy</a>.</p>
      </section>
    `,
  },

  "/acceptable-use": {
    path: "/acceptable-use",
    title: `${BRAND} | Acceptable Use Policy`,
    description: "OneWay acceptable use policy for messaging, calling, stores, identity, and public business tools.",
    body: `
      <section class="hero">
        <h1>Acceptable Use Policy</h1>
        <p class="lede">OneWay is built for legitimate communication, business presence, and customer service. Misuse is not allowed.</p>
      </section>

      <section>
        <h2>Prohibited activity</h2>
        <ul>
          <li>Spam, unsolicited marketing, purchased lists, or bulk messaging without consent.</li>
          <li>Phishing, fraud, scams, malware, deceptive links, or attempts to steal information.</li>
          <li>Harassment, threats, hate, abuse, exploitation, or unwanted repeated contact.</li>
          <li>Illegal goods, illegal services, illegal content, or activity that violates applicable law.</li>
          <li>Impersonation, misleading identity, spoofed caller ID, or deceptive business presentation.</li>
          <li>Carrier evasion, opt-out evasion, snowshoeing, number cycling, or attempts to bypass message filtering.</li>
          <li>High-risk messaging abuse, including deceptive finance, health, political, emergency, or regulated-content messaging.</li>
        </ul>
      </section>

      <section>
        <h2>Consent and messaging rules</h2>
        <p>Users must obtain consent before sending SMS or asking OneWay to send messages to another person. Users must honor STOP and other opt-out requests and may not message recipients who have opted out.</p>
      </section>

      <section>
        <h2>Enforcement</h2>
        <p>OneWay may investigate, restrict, suspend, or remove accounts, stores, numbers, caller IDs, content, or messaging access when we detect misuse, suspected abuse, carrier rule violations, or unlawful activity.</p>
      </section>

      <section>
        <h2>Report abuse</h2>
        <p>Email abuse reports to <a href="mailto:${ABUSE_EMAIL}">${ABUSE_EMAIL}</a>. For support, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>
      </section>
    `,
  },
};

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;");
}

export function renderPage(page: Page): string {
  const isHome = page.path === "/";
  const nav = `
    <header class="top">
      <div class="container top-inner">
        <a class="brand" href="/"><span class="brand-mark">1</span><span>OneWay</span></a>
        <nav class="nav">
          ${isHome ? `
          <a href="#features">Features</a>
          <a href="#pricing">Plans</a>
          <a href="#add-ons">Add-ons</a>
          <a href="/privacy"${page.path === "/privacy" ? " aria-current=\"page\"" : ""}>Privacy</a>
          ` : `
          <a href="/about"${page.path === "/about" ? " aria-current=\"page\"" : ""}>About</a>
          <a href="/sms"${page.path === "/sms" || page.path === "/sms-consent" ? " aria-current=\"page\"" : ""}>SMS</a>
          <a href="/privacy"${page.path === "/privacy" ? " aria-current=\"page\"" : ""}>Privacy</a>
          <a href="/terms"${page.path === "/terms" ? " aria-current=\"page\"" : ""}>Terms</a>
          <a href="/acceptable-use"${page.path === "/acceptable-use" ? " aria-current=\"page\"" : ""}>Acceptable Use</a>
          <a href="/support"${page.path === "/support" ? " aria-current=\"page\"" : ""}>Support</a>
          <a href="/contact"${page.path === "/contact" ? " aria-current=\"page\"" : ""}>Contact</a>
          <a href="/start"${page.path === "/start" ? " aria-current=\"page\"" : ""}>Start</a>
          `}
        </nav>
        ${isHome ? `<a class="nav-cta" href="/start">Start for $13</a>` : ""}
      </div>
    </header>
  `;

  const footer = `
    <footer class="footer">
      <div class="container footer-inner">
        <div class="footer-links">
          <a href="/about">About</a>
          <a href="/privacy">Privacy</a>
          <a href="/terms">Terms</a>
          <a href="/sms">SMS</a>
          <a href="/acceptable-use">Acceptable Use</a>
          <a href="/support">Support</a>
          <a href="/start">Start Service</a>
          <a href="/delete-account">Delete Account</a>
          <a href="/contact">Contact</a>
        </div>
        <div class="footer-meta">
          <span>${new Date().getFullYear()} OneWay</span>
          <span class="dot">·</span>
          <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
        </div>
      </div>
    </footer>
  `;

  const main = isHome
    ? `<main>${page.body}</main>`
    : `<main>
      <div class="container">
        <div class="panel">
          ${page.body}
        </div>
      </div>
    </main>`;

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHtml(page.title)}</title>
    <meta name="description" content="${escapeHtml(page.description)}" />
    <meta name="robots" content="index,follow" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="OneWay" />
    <meta property="og:title" content="${escapeHtml(page.title)}" />
    <meta property="og:description" content="${escapeHtml(page.description)}" />
    <meta property="og:url" content="${PUBLIC_SITE_ORIGIN}${page.path}" />
    <meta property="og:image" content="${SOCIAL_PREVIEW_URL}" />
    <meta property="og:image:width" content="1734" />
    <meta property="og:image:height" content="907" />
    <meta property="og:image:alt" content="OneWay — Talk. Build. Sell. Belong. Plans start at $13/month." />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${escapeHtml(page.title)}" />
    <meta name="twitter:description" content="${escapeHtml(page.description)}" />
    <meta name="twitter:image" content="${SOCIAL_PREVIEW_URL}" />
    <style>
      :root {
        color-scheme: light;
        --fg: #0b0f16;
        --muted: #52606d;
        --panel: #ffffff;
        --soft: #f6f8fb;
        --line: rgba(15, 23, 42, 0.12);
        --link: #0b5fff;
        --accent: #0b5fff;
        --shadow: 0 8px 24px rgba(2, 6, 23, 0.08);
        --oneway-purple: #8b3dff;
        --oneway-purple-soft: #c9a7ff;
        --home-bg: #05030a;
      }
      html, body {
        margin: 0;
        padding: 0;
        font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji", "Segoe UI Emoji";
        color: #0b0f16;
        background:
          linear-gradient(180deg, #ffffff 0, #f6f8fb 340px, #eef3f8 100%);
      }
      a { color: var(--link); text-decoration: none; }
      a:hover { text-decoration: underline; }
      body.home {
        color: #fbf8ff;
        background: #05030a;
      }
      body.home a { color: #fbf8ff; }
      .container {
        max-width: 1180px;
        margin: 0 auto;
        padding: 0 18px;
      }
      .top {
        background: #07111f;
        color: #fff;
        border-bottom: 1px solid rgba(255,255,255,0.12);
      }
      .top-inner {
        display: flex;
        gap: 16px;
        align-items: center;
        justify-content: space-between;
        padding: 14px 0;
      }
      body.home .top {
        position: sticky;
        top: 0;
        z-index: 10;
        background: rgba(9, 7, 18, 0.84);
        border-bottom: 1px solid rgba(139, 61, 255, 0.26);
        backdrop-filter: blur(18px);
      }
      body.home .top-inner {
        min-height: 46px;
      }
      .brand {
        color: #fff;
        font-weight: 700;
        letter-spacing: 0;
        font-size: 18px;
        white-space: nowrap;
        display: inline-flex;
        align-items: center;
        gap: 10px;
      }
      .brand:hover { text-decoration: none; }
      .brand-mark {
        width: 28px;
        height: 28px;
        border-radius: 999px;
        display: none;
        align-items: center;
        justify-content: center;
        background: var(--oneway-purple);
        color: #fff;
        font-size: 12px;
        font-weight: 800;
      }
      body.home .brand-mark { display: inline-flex; }
      .nav {
        display: flex;
        flex-wrap: wrap;
        gap: 14px;
        align-items: center;
        justify-content: flex-end;
      }
      .nav a {
        color: rgba(255,255,255,0.92);
        font-size: 14px;
      }
      .nav a[aria-current="page"] {
        color: #fff;
        font-weight: 600;
        text-decoration: underline;
      }
      body.home .nav {
        gap: 26px;
      }
      body.home .nav a {
        color: rgba(255,255,255,0.86);
        font-size: 13px;
        font-weight: 700;
      }
      .nav-cta {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-height: 34px;
        padding: 0 18px;
        border-radius: 999px;
        background: var(--oneway-purple);
        color: #fff !important;
        box-shadow: 0 0 22px rgba(139, 61, 255, 0.34);
        font-size: 13px;
        font-weight: 800;
        white-space: nowrap;
      }
      .nav-cta:hover { text-decoration: none; }
      main {
        padding: 30px 0 12px 0;
      }
      body.home main {
        padding: 0;
        overflow: hidden;
      }
      .panel {
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 8px;
        box-shadow: var(--shadow);
        padding: 28px;
      }
      .eyebrow {
        margin: 0 0 8px 0;
        color: #0b5fff;
        font-size: 13px;
        font-weight: 700;
        letter-spacing: 0;
        text-transform: uppercase;
      }
      .hero h1 {
        margin: 0 0 10px 0;
        font-size: 34px;
        line-height: 1.12;
        letter-spacing: 0;
        max-width: 740px;
      }
      .lede {
        margin: 0;
        color: var(--muted);
        font-size: 16px;
        line-height: 1.55;
        max-width: 760px;
      }
      .actions {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        margin-top: 18px;
      }
      .button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-height: 42px;
        padding: 0 16px;
        border-radius: 8px;
        font-size: 14px;
        font-weight: 700;
        border: 1px solid transparent;
      }
      .button:hover { text-decoration: none; }
      .button.primary {
        background: #0b5fff;
        color: #fff;
      }
      .button.secondary {
        background: #fff;
        color: #0b0f16;
        border-color: var(--line);
      }
      body.home .button {
        min-height: 42px;
        border-radius: 999px;
        padding: 0 22px;
        font-size: 13px;
      }
      body.home .button.primary {
        background: var(--oneway-purple);
        color: #fff;
        box-shadow: 0 0 28px rgba(139, 61, 255, 0.38);
      }
      body.home .button.secondary {
        background: rgba(255,255,255,0.08);
        color: #fff;
        border-color: rgba(255,255,255,0.36);
      }
      .product-hero {
        min-height: clamp(620px, 82vh, 860px);
        display: grid;
        align-items: center;
        position: relative;
        isolation: isolate;
        background:
          linear-gradient(90deg, rgba(5,3,10,0.98) 0%, rgba(5,3,10,0.9) 28%, rgba(5,3,10,0.42) 58%, rgba(5,3,10,0.24) 100%),
          linear-gradient(180deg, rgba(5,3,10,0.10), rgba(5,3,10,0.86)),
          url("/assets/oneway-private-mobile-hero.png") center right / cover no-repeat;
      }
      .product-hero::after {
        content: "";
        position: absolute;
        inset: auto 0 0 0;
        height: 30%;
        background: linear-gradient(180deg, rgba(5,3,10,0), #05030a);
        z-index: -1;
      }
      .hero-copy {
        width: min(760px, calc(100% - 40px));
        margin-left: max(20px, calc((100vw - 1180px) / 2 + 18px));
        padding: 88px 0 84px;
      }
      body.home .eyebrow {
        color: var(--oneway-purple-soft);
      }
      .product-hero h1 {
        margin: 14px 0 18px;
        max-width: 720px;
        color: #fff;
        font-size: clamp(42px, 6vw, 82px);
        line-height: 0.98;
        letter-spacing: 0;
      }
      body.home .lede {
        color: rgba(255,255,255,0.84);
        max-width: 650px;
        font-size: clamp(16px, 1.7vw, 20px);
        line-height: 1.55;
        font-weight: 650;
      }
      .price-line {
        margin-top: 24px;
        max-width: 650px;
        color: #fff;
        font-size: 17px;
        line-height: 1.5;
        font-weight: 800;
      }
      .product-band {
        margin: 0;
        padding: 84px max(20px, calc((100vw - 1180px) / 2 + 18px));
        background: #05030a;
      }
      .section-heading {
        max-width: 780px;
        margin-bottom: 28px;
      }
      .product-band h2,
      .plan-strip h2 {
        margin: 8px 0 0;
        color: #fff;
        font-size: clamp(28px, 4vw, 48px);
        line-height: 1.05;
      }
      .feature-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 14px;
      }
      .feature-grid article,
      .plan-strip article {
        border: 1px solid rgba(139, 61, 255, 0.28);
        border-radius: 8px;
        background: linear-gradient(180deg, rgba(255,255,255,0.075), rgba(255,255,255,0.035));
        padding: 22px;
      }
      .feature-grid span {
        display: inline-flex;
        margin-bottom: 26px;
        padding: 5px 9px;
        border: 1px solid rgba(201, 167, 255, 0.26);
        border-radius: 999px;
        background: rgba(139, 61, 255, 0.1);
        color: var(--oneway-purple-soft);
        font-size: 10px;
        letter-spacing: 0.12em;
        font-weight: 900;
      }
      .feature-grid h3 {
        margin: 0;
        color: #fff;
        font-size: 22px;
        line-height: 1.12;
      }
      body.home p {
        color: rgba(255,255,255,0.76);
      }
      .feature-grid p,
      .plan-strip p {
        color: rgba(255,255,255,0.72);
      }
      .section-copy {
        max-width: 720px;
        font-size: 16px;
      }
      .hero-proof {
        display: flex;
        flex-wrap: wrap;
        gap: 9px;
        margin-top: 28px;
      }
      .hero-proof span {
        padding: 7px 11px;
        border: 1px solid rgba(255,255,255,0.17);
        border-radius: 999px;
        background: rgba(5,3,10,0.48);
        color: rgba(255,255,255,0.76);
        font-size: 11px;
        font-weight: 800;
        letter-spacing: 0.03em;
      }
      .pricing-band,
      .addons-band {
        margin: 0;
        padding: 86px max(20px, calc((100vw - 1180px) / 2 + 18px));
        background: linear-gradient(180deg, #090612, #05030a);
      }
      .addons-band {
        padding-top: 24px;
      }
      .pricing-band h2,
      .addons-band h2,
      .closing-band h2 {
        margin: 8px 0 0;
        color: #fff;
        font-size: clamp(30px, 4vw, 50px);
        line-height: 1.04;
      }
      .pricing-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 14px;
        align-items: stretch;
      }
      .pricing-grid article {
        position: relative;
        display: flex;
        flex-direction: column;
        padding: 24px;
        border: 1px solid rgba(139, 61, 255, 0.25);
        border-radius: 18px;
        background: rgba(255,255,255,0.045);
      }
      .pricing-grid article.featured-plan {
        border-color: rgba(201, 167, 255, 0.72);
        background: linear-gradient(180deg, rgba(139,61,255,0.19), rgba(255,255,255,0.05));
        box-shadow: 0 22px 60px rgba(72, 25, 142, 0.24);
      }
      .plan-badge {
        position: absolute;
        top: 14px;
        right: 14px;
        margin: 0;
        padding: 5px 8px;
        border-radius: 999px;
        background: var(--oneway-purple);
        color: white !important;
        font-size: 10px;
        font-weight: 900;
        text-transform: uppercase;
        letter-spacing: 0.08em;
      }
      .plan-name {
        margin: 0 !important;
        color: #fff !important;
        font-size: 15px;
        font-weight: 900;
      }
      .plan-price {
        display: flex;
        align-items: baseline;
        gap: 6px;
        margin: 16px 0 8px;
      }
      .plan-price strong {
        color: #fff;
        font-size: 40px;
        letter-spacing: -0.04em;
      }
      .plan-price span {
        color: rgba(255,255,255,0.56);
        font-size: 12px;
        font-weight: 800;
      }
      .pricing-grid .button {
        margin-top: auto;
      }
      .home-check-list {
        flex: 1;
        list-style: none;
        margin: 16px 0 24px;
        padding: 0;
      }
      .home-check-list li {
        position: relative;
        margin-top: 9px;
        padding-left: 19px;
        color: rgba(255,255,255,0.75);
        font-size: 13px;
      }
      .home-check-list li::before {
        content: "✓";
        position: absolute;
        left: 0;
        color: var(--oneway-purple-soft);
        font-weight: 900;
      }
      .addon-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 12px;
      }
      .addon-grid article {
        padding: 20px;
        border: 1px solid rgba(255,255,255,0.1);
        border-radius: 14px;
        background: rgba(255,255,255,0.035);
      }
      .addon-grid h3 {
        margin: 8px 0 0;
        color: #fff;
        font-size: 22px;
      }
      .mini-label {
        margin: 0 !important;
        color: var(--oneway-purple-soft) !important;
        font-size: 10px;
        font-weight: 900;
        letter-spacing: 0.1em;
        text-transform: uppercase;
      }
      .closing-band {
        margin: 0;
        padding: 100px max(20px, calc((100vw - 900px) / 2 + 18px));
        text-align: center;
        background:
          radial-gradient(circle at 50% 0, rgba(139,61,255,0.27), transparent 45%),
          #05030a;
      }
      .closing-band p {
        max-width: 650px;
        margin-left: auto;
        margin-right: auto;
      }
      .closing-band .actions {
        justify-content: center;
      }
      .plan-strip {
        margin: 0;
        padding: 0 max(20px, calc((100vw - 1180px) / 2 + 18px)) 90px;
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 14px;
        background: #05030a;
      }
      .plan-strip .button {
        margin-top: 18px;
      }
      section { margin-top: 22px; }
      article {
        min-width: 0;
      }
      h2 {
        margin: 0 0 10px 0;
        font-size: 18px;
      }
      p, li {
        color: #0b0f16;
        line-height: 1.6;
        font-size: 15px;
      }
      p { margin: 10px 0 0 0; }
      ul { margin: 10px 0 0 18px; }
      .grid {
        display: grid;
        gap: 16px;
      }
      .grid.two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .grid.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
      .grid article {
        border: 1px solid var(--line);
        border-radius: 8px;
        padding: 16px;
        background: #fff;
      }
      .band {
        border: 1px solid rgba(11, 95, 255, 0.16);
        background: linear-gradient(180deg, rgba(11, 95, 255, 0.06), rgba(11, 95, 255, 0.025));
        border-radius: 8px;
        padding: 18px;
      }
      .callout {
        margin-top: 12px;
        padding: 12px 14px;
        border-radius: 8px;
        background: rgba(11, 95, 255, 0.07);
        border: 1px solid rgba(11, 95, 255, 0.18);
        color: #0b0f16;
      }
      .checkout-flow {
        margin-top: 22px;
      }
      .checkout-steps {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 8px;
        margin-bottom: 18px;
      }
      .checkout-steps span {
        min-height: 38px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border: 1px solid var(--line);
        border-radius: 8px;
        background: #fff;
        color: var(--muted);
        font-size: 13px;
        font-weight: 800;
      }
      .checkout-steps span.is-active {
        background: #07111f;
        border-color: #07111f;
        color: #fff;
      }
      .checkout-steps span.is-complete {
        background: rgba(11, 95, 255, 0.08);
        border-color: rgba(11, 95, 255, 0.24);
        color: #0b5fff;
      }
      .checkout-form {
        display: grid;
        gap: 16px;
      }
      .checkout-form fieldset {
        margin: 0;
        padding: 18px;
        border: 1px solid var(--line);
        border-radius: 8px;
        background: #fff;
      }
      .checkout-form legend {
        padding: 0 8px;
        font-weight: 900;
      }
      .checkout-form label {
        display: grid;
        gap: 7px;
        margin-top: 14px;
        color: #0b0f16;
        font-size: 14px;
        font-weight: 800;
      }
      .checkout-form input,
      .checkout-form select,
      .checkout-form textarea {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid rgba(15, 23, 42, 0.18);
        border-radius: 8px;
        padding: 12px;
        color: #0b0f16;
        background: #fff;
        font: inherit;
      }
      .checkout-form textarea {
        min-height: 108px;
        resize: vertical;
      }
      .plan-summary {
        display: flex;
        gap: 16px;
        align-items: flex-start;
        justify-content: space-between;
        padding: 16px;
        border-radius: 8px;
        background: #f6f8fb;
        border: 1px solid var(--line);
      }
      .plan-summary strong {
        display: block;
        font-size: 17px;
      }
      .plan-summary span {
        color: #0b5fff;
        font-weight: 950;
        white-space: nowrap;
      }
      .check-list {
        list-style: none;
        padding: 0;
        margin: 14px 0 0 0;
      }
      .check-list li {
        margin-top: 8px;
        padding-left: 22px;
        position: relative;
      }
      .check-list li::before {
        content: "✓";
        position: absolute;
        left: 0;
        color: #0b5fff;
        font-weight: 900;
      }
      .consent-row {
        grid-template-columns: auto 1fr;
        align-items: start;
        font-weight: 650;
      }
      .consent-row input {
        width: 18px;
        height: 18px;
        margin-top: 2px;
      }
      .form-status {
        min-height: 22px;
        margin: 0;
        color: var(--muted);
        font-weight: 700;
      }
      .checkout-actions {
        display: flex;
        gap: 10px;
        justify-content: flex-end;
      }
      .checkout-actions button {
        cursor: pointer;
      }
      .footer {
        margin-top: 30px;
        border-top: 1px solid var(--line);
        background: #fff;
      }
      body.home .footer {
        margin-top: 0;
        background: #030208;
        border-top: 1px solid rgba(139, 61, 255, 0.22);
      }
      .footer-inner {
        padding: 18px 0;
        display: flex;
        gap: 14px;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
      }
      .footer-links {
        display: flex;
        gap: 12px;
        flex-wrap: wrap;
      }
      .footer-links a {
        color: #0b0f16;
        font-size: 14px;
      }
      body.home .footer-links a,
      body.home .footer-meta,
      body.home .footer-meta a {
        color: rgba(255,255,255,0.66);
      }
      .footer-meta {
        display: flex;
        gap: 8px;
        align-items: center;
        color: var(--muted);
        font-size: 13px;
      }
      .footer-meta a { color: var(--muted); }
      .dot { opacity: 0.7; }
      @media (min-width: 641px) and (max-width: 1020px) {
        .feature-grid,
        .pricing-grid,
        .addon-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
        body.home .nav {
          gap: 16px;
        }
      }
      @media (max-width: 640px) {
        .top-inner {
          align-items: flex-start;
          flex-direction: column;
        }
        body.home .top-inner {
          align-items: center;
          flex-direction: row;
          flex-wrap: wrap;
          gap: 10px 14px;
        }
        body.home .nav {
          order: 3;
          width: 100%;
          gap: 14px;
          justify-content: flex-start;
          overflow-x: auto;
          padding-bottom: 2px;
        }
        body.home .nav-cta {
          min-height: 32px;
          padding: 0 14px;
          font-size: 12px;
        }
        .hero h1 { font-size: 28px; }
        .panel { padding: 20px; }
        .nav {
          gap: 10px 12px;
          justify-content: flex-start;
        }
        .grid.two,
        .grid.three {
          grid-template-columns: 1fr;
        }
        .checkout-steps {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
        .plan-summary {
          flex-direction: column;
        }
        .checkout-actions {
          flex-direction: column-reverse;
        }
        .product-hero {
          min-height: 720px;
          align-items: end;
          background:
            linear-gradient(180deg, rgba(5,3,10,0.24) 0%, rgba(5,3,10,0.56) 44%, rgba(5,3,10,0.98) 82%),
            url("/assets/oneway-private-mobile-hero.png") 64% top / auto 58% no-repeat,
            #05030a;
        }
        .hero-copy {
          width: auto;
          margin: 0;
          padding: 330px 20px 54px;
        }
        .product-hero h1 {
          font-size: clamp(38px, 12vw, 54px);
          line-height: 1;
        }
        body.home .lede,
        .price-line {
          font-size: 15px;
        }
        .product-band {
          padding: 54px 20px;
        }
        .feature-grid,
        .plan-strip,
        .pricing-grid,
        .addon-grid {
          grid-template-columns: 1fr;
        }
        .pricing-band,
        .addons-band {
          padding: 58px 20px;
        }
        .addons-band {
          padding-top: 8px;
        }
        .closing-band {
          padding: 70px 20px;
        }
        .plan-strip {
          padding: 0 20px 62px;
        }
        .footer-inner {
          align-items: flex-start;
          flex-direction: column;
        }
      }
    </style>
  </head>
  <body class="${isHome ? "home" : "subpage"}">
    ${nav}
    ${main}
    ${footer}
  </body>
</html>`;
}
