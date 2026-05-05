import { supabase } from '@/lib/supabase';
import type { Site, SiteBlock, SiteMode } from '@/types/database';

export async function getSiteForSlug(slug: string): Promise<Site | null> {
  const { data, error } = await supabase
    .from('ow_sites')
    .select('*')
    .eq('domain_slug', slug)
    .maybeSingle();
  if (error) throw error;
  return (data ?? null) as Site | null;
}

export async function upsertSite(input: {
  domain_slug: string;
  title: string;
  description?: string;
  mode: SiteMode;
  html_content?: string;
  blocks?: SiteBlock[];
}): Promise<Site> {
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) throw new Error('Not signed in.');

  const { data, error } = await supabase
    .from('ow_sites')
    .upsert(
      {
        user_id: user.user.id,
        domain_slug: input.domain_slug,
        title: input.title,
        description: input.description ?? '',
        mode: input.mode,
        html_content: input.html_content ?? '',
        blocks: input.blocks ?? [],
      },
      { onConflict: 'domain_slug' }
    )
    .select('*')
    .single();
  if (error) throw error;
  return data as Site;
}

export async function publishSite(site: Site): Promise<void> {
  // 1. Mark row published
  const { error: rowErr } = await supabase
    .from('ow_sites')
    .update({ published: true })
    .eq('id', site.id);
  if (rowErr) throw rowErr;

  // 2. Push HTML to Storage so the edge function can serve it
  const html = site.mode === 'nocode' ? renderBlocks(site.blocks, site) : site.html_content;
  const path = `sites/${site.domain_slug}/index.html`;
  const { error: upErr } = await supabase.storage
    .from('oneway-sites')
    .upload(path, new Blob([html], { type: 'text/html' }), { upsert: true });
  if (upErr) throw upErr;
}

// Minimal block → HTML renderer. Mirrors the look of the edge function templates.
export function renderBlocks(blocks: SiteBlock[], site: Pick<Site, 'title' | 'description'>): string {
  const body = blocks
    .map((b) => {
      switch (b.type) {
        case 'heading':
          return `<h${b.level}>${escape(b.text)}</h${b.level}>`;
        case 'paragraph':
          return `<p>${escape(b.text)}</p>`;
        case 'image':
          return `<img src="${escape(b.url)}" alt="${escape(b.alt ?? '')}" />`;
        case 'link':
          return `<a href="${escape(b.href)}">${escape(b.label)}</a>`;
        case 'divider':
          return '<hr/>';
        case 'html':
          return b.raw; // trusted: author's own site
      }
    })
    .join('\n');

  return `<!DOCTYPE html><html><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escape(site.title)}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,sans-serif;background:#06030f;color:#f0ebff;
  padding:48px 20px;max-width:680px;margin:0 auto;line-height:1.6}
h1,h2,h3{font-weight:900;margin:24px 0 8px}
p{color:#9d8fc4;margin:8px 0}
a{color:#a855f7}
img{max-width:100%;border-radius:12px;margin:12px 0}
hr{border:0;border-top:1px solid rgba(124,58,237,0.18);margin:24px 0}
footer{margin-top:48px;padding-top:24px;border-top:1px solid rgba(124,58,237,0.18);
  color:#6b5d8c;font-size:.8rem;text-align:center}
</style></head><body>
${body}
<footer>Hosted on <a href="https://home.oneway.app">OneWay</a></footer>
</body></html>`;
}

function escape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
