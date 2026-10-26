// Video Ad Builder "Load reviews from Facebook" (video-ad-builder.html) - reads the recommendations
// (reviews) on our Facebook Pages so staff can pick real ones for a ⭐ Reviews scene.
//
//   POST { admin_username, admin_password }
//   ->   { reviews: [{ page, text, recommends, created, name }], recommends_total,
//          pages: [{ name, ok, error?, recommends }] }
//   recommends_total = every positive recommendation across the Pages, with or without text -
//   the real number behind a "120+ recommendations" line in the ad.
//
// Read-only: one GET of each Page's /ratings with the Page tokens the other functions already use
// (Messenger bot + Facebook posting secrets). Reading reviews needs the token's
// pages_read_user_content permission; a Page whose token lacks it is reported in "pages" with the
// error, and staff can still type reviews in by hand. Facebook usually hides the reviewer's name
// from apps, so name is often null.
//
// Super users only (is_admin_authorized), like the page.
//
// Deploy: supabase functions deploy video-ad-reviews --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

const MAX_PAGES_PER_FB_PAGE = 20; // 100 ratings each

async function graphGet(graphVersion: string, path: string, params: Record<string, string>, fullUrl?: string) {
  const url = fullUrl || `https://graph.facebook.com/${graphVersion}/${path}?${new URLSearchParams(params).toString()}`;
  try {
    const res = await fetch(url);
    const body = await res.json().catch(() => ({}));
    return { ok: res.ok && !body.error, body };
  } catch (err) {
    return { ok: false, body: { error: { message: String(err) } } };
  }
}

// Every distinct Page token we have (the same Page can appear under several secrets).
function pageTokens(): string[] {
  const tokens = [
    Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN'),
    Deno.env.get('FACEBOOK_GMA_POST_TOKEN'),
    Deno.env.get('FACEBOOK_RSPETSTOP_POST_TOKEN')
  ];
  const raw = Deno.env.get('FACEBOOK_PAGE_TOKENS')?.trim();
  if (raw) {
    try {
      for (const token of Object.values(JSON.parse(raw) as Record<string, unknown>)) if (typeof token === 'string') tokens.push(token);
    } catch { /* bad JSON - the Messenger functions log it */ }
  }
  return [...new Set(tokens.map((t) => t?.trim()).filter((t): t is string => !!t))];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'video-ad-reviews is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.' }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON.' }, 400);
  }
  const adminUsername = String(body.admin_username ?? '');
  const adminPassword = String(body.admin_password ?? '');
  if (!adminUsername || !adminPassword) return jsonResponse({ error: 'Missing admin_username / admin_password.' }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);

  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  const tokens = pageTokens();
  if (!tokens.length) return jsonResponse({ error: 'No Facebook Page token is set up.' }, 500);

  const seenPages = new Set<string>();
  const pages: { name: string; ok: boolean; error?: string; recommends?: number }[] = [];
  let recommendsTotal = 0;
  const reviews: { page: string; text: string; recommends: boolean; created: string; name: string | null }[] = [];

  for (const token of tokens) {
    const me = await graphGet(graphVersion, 'me', { fields: 'id,name', access_token: token });
    if (!me.ok || !me.body.id || seenPages.has(me.body.id)) continue;
    seenPages.add(me.body.id);
    const pageName = String(me.body.name || me.body.id);

    // Ask for the reviewer's name too; if Facebook refuses that field, try again without it.
    const fields = 'created_time,recommendation_type,review_text,rating';
    let r = await graphGet(graphVersion, 'me/ratings', { fields: fields + ',reviewer{name}', limit: '100', access_token: token });
    if (!r.ok) r = await graphGet(graphVersion, 'me/ratings', { fields, limit: '100', access_token: token });
    if (!r.ok) {
      pages.push({ name: pageName, ok: false, error: r.body?.error?.message || 'Could not read reviews.' });
      continue;
    }
    let recommends = 0;
    for (let n = 0; ; n++) {
      for (const x of (r.body.data ?? []) as Record<string, any>[]) {
        const positive = x.recommendation_type ? x.recommendation_type === 'positive' : Number(x.rating) >= 4;
        if (positive) recommends++;
        const text = String(x.review_text ?? '').trim();
        if (!text) continue;
        reviews.push({
          page: pageName,
          text,
          recommends: positive,
          created: String(x.created_time ?? ''),
          name: x.reviewer?.name ? String(x.reviewer.name) : null
        });
      }
      const next = r.body.paging?.next;
      if (!next || n + 1 >= MAX_PAGES_PER_FB_PAGE) break;
      r = await graphGet(graphVersion, '', {}, next);
      if (!r.ok) break;
    }
    recommendsTotal += recommends;
    pages.push({ name: pageName, ok: true, recommends });
  }

  reviews.sort((a, b) => b.created.localeCompare(a.created));
  return jsonResponse({ reviews, recommends_total: recommendsTotal, pages });
});
