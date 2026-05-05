import { supabase } from '@/lib/supabase';
import type { Domain } from '@/types/database';

const RESERVED = new Set([
  'home',
  'directory',
  'admin',
  'api',
  'www',
  'oneway',
  'support',
  'help',
  'docs',
  'mail',
]);

const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/;

export function validateSlug(raw: string): { ok: true; slug: string } | { ok: false; reason: string } {
  const slug = raw.trim().toLowerCase();
  if (!slug) return { ok: false, reason: 'Pick a name first.' };
  if (slug.length < 2) return { ok: false, reason: 'At least 2 characters.' };
  if (slug.length > 32) return { ok: false, reason: 'Max 32 characters.' };
  if (!SLUG_RE.test(slug)) return { ok: false, reason: 'Letters, numbers, and dashes only.' };
  if (RESERVED.has(slug)) return { ok: false, reason: 'That name is reserved.' };
  return { ok: true, slug };
}

export async function isSlugAvailable(slug: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('ow_domains')
    .select('id')
    .eq('slug', slug)
    .maybeSingle();
  if (error) throw error;
  return !data;
}

export async function listMyDomains(): Promise<Domain[]> {
  const { data, error } = await supabase
    .from('ow_domains')
    .select('*')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as Domain[];
}

export async function registerDomain(input: {
  slug: string;
  payment_method: 'apple_iap' | 'stripe' | 'crypto';
  payment_reference?: string;
}): Promise<Domain> {
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) throw new Error('Not signed in.');

  const expires = new Date();
  expires.setFullYear(expires.getFullYear() + 1);

  const { data, error } = await supabase
    .from('ow_domains')
    .insert({
      user_id: user.user.id,
      slug: input.slug,
      status: 'active',
      expires_at: expires.toISOString(),
      payment_method: input.payment_method,
      payment_reference: input.payment_reference ?? null,
    })
    .select('*')
    .single();
  if (error) throw error;
  return data as Domain;
}
