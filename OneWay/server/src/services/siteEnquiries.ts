import { z } from "zod";
import { encryptIfEnabled } from "./privacy/EncryptionService";

export const siteEnquirySchema = z.object({
  customerName: z.string().trim().min(1).max(120),
  customerEmail: z.string().trim().email().max(254),
  customerPhone: z.string().trim().max(40).optional().default(""),
  message: z.string().trim().min(1).max(4000),
  website: z.string().max(0).optional().default(""),
});

export function encryptedSiteEnquiry(domain: string, input: z.infer<typeof siteEnquirySchema>) {
  const protect = (field: string, value: string) => encryptIfEnabled(value, `store:${domain}:inquiry:${field}`);
  return {
    customerName: protect("customerName", input.customerName),
    customerEmail: protect("customerEmail", input.customerEmail),
    customerPhone: protect("customerPhone", input.customerPhone),
    message: protect("message", input.message),
    productName: "Website enquiry",
    status: "new",
  };
}

function escaped(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export function renderSiteEnquiryForm(domain: string, apiBase: string): string {
  const endpoint = `${apiBase.replace(/\/+$/, "")}/api/sites/${encodeURIComponent(domain)}/inquiries`;
  return `<section class="card" id="contact-form"><h2>Send an enquiry</h2>
<form method="post" action="${escaped(endpoint)}">
<label>Your name<input name="customerName" autocomplete="name" required maxlength="120"></label>
<label>Email<input name="customerEmail" type="email" autocomplete="email" required maxlength="254"></label>
<label>Phone (optional)<input name="customerPhone" type="tel" autocomplete="tel" maxlength="40"></label>
<label>Message<textarea name="message" required maxlength="4000" rows="5"></textarea></label>
<div hidden aria-hidden="true"><label>Leave blank<input name="website" tabindex="-1" autocomplete="off"></label></div>
<p>Your contact details and message will be shared with this website’s owner so they can respond.</p>
<button type="submit">Send enquiry</button></form></section>`;
}
