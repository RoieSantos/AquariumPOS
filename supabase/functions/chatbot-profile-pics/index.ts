// Customer profile pictures for docs/gma-conversations.html - per "display the customer profile
// pictures without saving any image to our database". Nothing is stored: this asks Facebook's User
// Profile API for each customer's current profile_pic URL (with the conversation's own Page token,
// see _shared/page-tokens.ts) and hands the URLs back; the browser loads the image straight from
// Facebook's CDN and only keeps the URL in memory for the open tab. Those URLs expire after a few
// days, which is fine since they're re-fetched every time the page is opened.
//
// Needs Meta's "Business Asset User Profile Access" feature on the Messenger use case - Standard
// Access works only for people with a role on the app; real customers need Advanced Access (App
// Review). Without it Facebook answers code 100 / subcode 33, returned per customer in `errors` so
// the inbox can just keep its initials avatar.
//
// Body: { admin_username, admin_password, psids: string[] } (max 100) - re-verified via
// is_conversations_authorized, same as every Conversations RPC.
// Or { pos_key, psids } from the desktop POS checkout's customer lookup (so the cashier can see it's the
// right customer before tagging the walk-in) - checked with _pos_key_ok (Vault POS_API_KEY), same as the
// pos_* RPCs (sql/supabase_pos_walkin_orders_direct.sql grants it to service_role).
// Returns: { ok: true, pictures: { [psid]: url | null }, errors: { [psid]: string } }
//
// Deploy: supabase functions deploy chatbot-profile-pics --project-ref hymcmesqgpliyyeghpgq
import { createClient } from 'npm:@supabase/supabase-js@2';
import { getPageAccessToken, hasAnyPageAccessToken } from '../_shared/page-tokens.ts';

const DEFAULT_GRAPH_VERSION = 'v21.0';
const MAX_PSIDS = 100;
const CONCURRENCY = 8;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

async function fetchProfilePic(psid: string, pageAccessToken: string, graphVersion: string): Promise<{ url: string | null; error: string | null }> {
  try {
    const res = await fetch(`https://graph.facebook.com/${graphVersion}/${encodeURIComponent(psid)}?fields=profile_pic&access_token=${pageAccessToken}`);
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      const e = body?.error;
      return { url: null, error: e ? `${e.message} (code ${e.code}${e.error_subcode ? `/${e.error_subcode}` : ''})` : `HTTP ${res.status}` };
    }
    return { url: typeof body?.profile_pic === 'string' && body.profile_pic ? body.profile_pic : null, error: null };
  } catch (err) {
    return { url: null, error: err instanceof Error ? err.message : 'Request failed' };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  if (!supabaseUrl || !serviceRoleKey || !hasAnyPageAccessToken()) {
    return jsonResponse({ error: 'chatbot-profile-pics is missing one or more required secrets.' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let posKey: string;
  let psids: string[];
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    posKey = String(body.pos_key ?? '');
    psids = Array.isArray(body.psids) ? [...new Set(body.psids.map((p: unknown) => String(p)).filter(Boolean))] as string[] : [];
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, psids } or { pos_key, psids }.' }, 400);
  }
  if (!posKey && (!adminUsername || !adminPassword)) return jsonResponse({ error: 'Not authorized.' }, 401);
  psids = psids.slice(0, MAX_PSIDS);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = posKey
    ? await supabase.rpc('_pos_key_ok', { p_key: posKey })
    : await supabase.rpc('is_conversations_authorized', { p_username: adminUsername, p_password: adminPassword });
  if (authError || authorized !== true) return jsonResponse({ error: 'Not authorized.' }, 401);

  const pictures: Record<string, string | null> = {};
  const errors: Record<string, string> = {};
  if (psids.length === 0) return jsonResponse({ ok: true, pictures, errors });

  const { data: convs } = await supabase.from('ChatbotConversations').select('Psid, PageId').in('Psid', psids);
  const pageByPsid = new Map(((convs ?? []) as Array<{ Psid: string; PageId: string | null }>).map((c) => [c.Psid, c.PageId]));

  // Website-widget visitors and unknown psids have no Facebook profile - skipped (null).
  const work = psids.filter((psid) => {
    const pageId = pageByPsid.get(psid);
    if (!pageByPsid.has(psid) || pageId === 'website') {
      pictures[psid] = null;
      return false;
    }
    return true;
  });

  for (let i = 0; i < work.length; i += CONCURRENCY) {
    await Promise.all(work.slice(i, i + CONCURRENCY).map(async (psid) => {
      const token = getPageAccessToken(pageByPsid.get(psid) ?? null);
      if (!token) {
        pictures[psid] = null;
        errors[psid] = 'No Facebook token for this Page.';
        return;
      }
      const { url, error } = await fetchProfilePic(psid, token, graphVersion);
      pictures[psid] = url;
      if (error) errors[psid] = error;
    }));
  }

  if (Object.keys(errors).length > 0) console.error('Profile pic lookup errors (first):', Object.values(errors)[0]);
  return jsonResponse({ ok: true, pictures, errors });
});
