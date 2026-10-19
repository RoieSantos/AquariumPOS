// Read-only health check of every Facebook Page token the system uses - backs the "Facebook tokens"
// suite on docs/system-tests.html, per "how about the auto post in facebook?". A broken/expired token
// is the most common way Facebook posting (and Alice's Messenger replies) silently stops working.
//
// POST { admin_username, admin_password }  (super users only - is_admin_authorized)
//   -> { tokens: [{ label, purpose, configured, valid, page_id, page_name, page_matches, scopes,
//                   missing_scopes, expires_at, error }] }
//
// Only GET calls to the Graph API (debug_token + the Page's id/name) - it never posts, sends or
// changes anything, and never returns the tokens themselves.
//
// Tokens checked (same secrets the real functions use):
//   facebook-page-post:        FACEBOOK_GMA_POST_TOKEN + FACEBOOK_GMA_PAGE_ID,
//                              FACEBOOK_RSPETSTOP_POST_TOKEN + FACEBOOK_RSPETSTOP_PAGE_ID
//   Messenger bot (Alice):     FACEBOOK_PAGE_ACCESS_TOKEN (GMA) + each Page in FACEBOOK_PAGE_TOKENS
//                              (_shared/page-tokens.ts)
//
// Deploy: supabase functions deploy facebook-token-health --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';
const POSTING_SCOPES = ['pages_manage_posts', 'pages_read_engagement'];
const MESSENGER_SCOPES = ['pages_messaging'];

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

type TokenToCheck = { label: string; purpose: 'posting' | 'messenger'; token?: string; pageId?: string; requiredScopes: string[] };

async function graphGet(path: string, params: Record<string, string>, graphVersion: string): Promise<{ ok: boolean; body: Record<string, any> }> {
  const url = `https://graph.facebook.com/${graphVersion}/${path}?${new URLSearchParams(params).toString()}`;
  try {
    const res = await fetch(url);
    const body = await res.json().catch(() => ({}));
    return { ok: res.ok && !body.error, body };
  } catch (err) {
    return { ok: false, body: { error: { message: err instanceof Error ? err.message : String(err) } } };
  }
}

async function checkToken(t: TokenToCheck, appToken: string | null, graphVersion: string, expectedAppId: string | null) {
  const result: Record<string, unknown> = {
    label: t.label, purpose: t.purpose, configured: Boolean(t.token), valid: false,
    page_id: t.pageId ?? null, page_name: null, page_matches: null, scopes: [], missing_scopes: [], expires_at: null,
    data_access_expires_at: null, app_id: null, app_name: null, app_matches: null, error: null
  };
  if (!t.token) {
    result.error = 'Secret not set.';
    return result;
  }

  // debug_token: validity, scopes, expiry. The app token works for tokens from our own Meta app; a
  // token debugging itself covers a Page token from another app.
  let debug = appToken ? await graphGet('debug_token', { input_token: t.token, access_token: appToken }, graphVersion) : null;
  if (!debug || !debug.ok || !debug.body.data) debug = await graphGet('debug_token', { input_token: t.token, access_token: t.token }, graphVersion);
  const data = debug.ok ? debug.body.data : null;
  if (data) {
    const scopes: string[] = Array.isArray(data.scopes) ? data.scopes : [];
    result.scopes = scopes;
    result.missing_scopes = t.requiredScopes.filter((s) => !scopes.includes(s));
    // 0 / missing = never expires. data_access_expires_at is Meta's separate ~90-day data-access window.
    result.expires_at = data.expires_at ? new Date(data.expires_at * 1000).toISOString() : 'never';
    result.data_access_expires_at = data.data_access_expires_at ? new Date(data.data_access_expires_at * 1000).toISOString() : null;
    if (data.is_valid === false) result.error = data.error?.message || 'Facebook says this token is no longer valid.';
    // Which Meta app issued the token - App Dashboard usage counters (e.g. Human Agent's API calls)
    // only count calls made with that app's tokens.
    result.app_id = data.app_id ? String(data.app_id) : null;
    result.app_name = data.application ?? null;
    result.app_matches = expectedAppId && result.app_id ? result.app_id === expectedAppId : null;
  }

  // The Page itself - also proves the token can actually be used, even if debug_token was refused.
  const me = await graphGet('me', { fields: 'id,name', access_token: t.token }, graphVersion);
  if (me.ok) {
    result.page_name = me.body.name ?? null;
    if (!t.pageId) result.page_id = me.body.id ?? null;
    result.page_matches = t.pageId ? String(me.body.id) === String(t.pageId) : null;
    result.valid = data ? data.is_valid !== false : true;
  } else if (!result.error) {
    result.error = me.body.error?.message || 'Facebook refused this token.';
  }
  if (!data && me.ok) result.error = null; // usable; permissions just couldn't be listed
  if (!data) result.missing_scopes = null; // unknown, not "none missing"
  return result;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'facebook-token-health is missing its Supabase secrets.' }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password }.' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: String(body.admin_username ?? ''),
    p_password: String(body.admin_password ?? '')
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);

  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  const appId = Deno.env.get('FACEBOOK_APP_ID')?.trim();
  const appSecret = Deno.env.get('FACEBOOK_APP_SECRET')?.trim();
  const appToken = appId && appSecret ? `${appId}|${appSecret}` : null;

  const tokens: TokenToCheck[] = [
    { label: 'Posting - GMA Page', purpose: 'posting', token: Deno.env.get('FACEBOOK_GMA_POST_TOKEN'), pageId: Deno.env.get('FACEBOOK_GMA_PAGE_ID'), requiredScopes: POSTING_SCOPES },
    { label: 'Posting - RS Pet Stop (Amaya) Page', purpose: 'posting', token: Deno.env.get('FACEBOOK_RSPETSTOP_POST_TOKEN'), pageId: Deno.env.get('FACEBOOK_RSPETSTOP_PAGE_ID'), requiredScopes: POSTING_SCOPES },
    { label: 'Messenger (Alice) - default Page', purpose: 'messenger', token: Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN'), requiredScopes: MESSENGER_SCOPES }
  ];
  const rawMap = Deno.env.get('FACEBOOK_PAGE_TOKENS')?.trim();
  if (rawMap) {
    try {
      for (const [pageId, token] of Object.entries(JSON.parse(rawMap) as Record<string, unknown>)) {
        if (typeof token === 'string' && token.trim()) {
          tokens.push({ label: `Messenger (Alice) - Page ${pageId}`, purpose: 'messenger', token: token.trim(), pageId, requiredScopes: MESSENGER_SCOPES });
        }
      }
    } catch {
      tokens.push({ label: 'Messenger (Alice) - FACEBOOK_PAGE_TOKENS', purpose: 'messenger', token: undefined, requiredScopes: MESSENGER_SCOPES });
    }
  }

  const results = await Promise.all(tokens.map((t) => checkToken(t, appToken, graphVersion, appId || null)));
  return jsonResponse({ tokens: results, expected_app_id: appId || null });
});
