// TypeScript view of the OneWay schema (supabase/migrations/001_browser_schema.sql).
// Keep in sync if you edit the SQL.

export type DomainStatus = 'active' | 'expired' | 'suspended' | 'pending';
export type SiteMode = 'nocode' | 'code' | 'ai';
export type PaymentMethod = 'apple_iap' | 'stripe' | 'crypto';
export type PaymentStatus = 'pending' | 'completed' | 'failed' | 'refunded';

export interface Profile {
  id: string;
  username: string | null;
  created_at: string;
  updated_at: string;
}

export interface Domain {
  id: string;
  user_id: string;
  slug: string;                  // mira → mira.oneway.app
  status: DomainStatus;
  expires_at: string;            // ISO timestamp
  renewal_price_usd: number;
  site_id: string | null;
  payment_method: PaymentMethod | null;
  payment_reference: string | null;
  created_at: string;
  updated_at: string;
}

export interface Site {
  id: string;
  user_id: string;
  domain_slug: string;
  title: string;
  description: string;
  mode: SiteMode;
  html_content: string;
  blocks: SiteBlock[];
  published: boolean;
  created_at: string;
  updated_at: string;
}

export interface Payment {
  id: string;
  user_id: string;
  domain_slug: string | null;
  amount_usd: number;
  method: PaymentMethod;
  provider_ref: string | null;
  status: PaymentStatus;
  created_at: string;
}

// ─── Site builder block model (for `blocks` jsonb) ──────────────────
export type SiteBlock =
  | { type: 'heading'; level: 1 | 2 | 3; text: string }
  | { type: 'paragraph'; text: string }
  | { type: 'image'; url: string; alt?: string }
  | { type: 'link'; href: string; label: string }
  | { type: 'divider' }
  | { type: 'html'; raw: string };
