// NEW ARRIVALS auto-post (sql/supabase_new_arrivals.sql). Fully automatic - no staff tap:
//
//   { action: 'dispatch' }  (default)
//       Claims the waiting announcements (service_claim_new_arrival_posts - one row per received
//       fish/plant Transfer Order, queued by the Posted_Transfer_Line trigger) and posts each to the
//       receiving store's Page: GMA -> GMA Page, Amaya -> RS Pet Stop Page (same Page secrets as
//       facebook-page-post). Photo = the branded "📣 NEW ARRIVALS" banner saved on the New Arrivals
//       page (NewArrivalSettings."BannerUrl", falls back to the company logo); caption = the item
//       names from a fixed template (no AI, no prices - per request). Called by the portal right after
//       Receive (fire-and-forget) and by pg_cron every 5 minutes as the backup. Calling it with
//       nothing waiting does nothing, so it is safe for anyone to call - it only ever posts what a
//       real Receive queued, and each row once (the claim is atomic).
//
//   { action: 'preview', warehouse, items: [{ name, category }] }
//       Returns the caption that would be posted - nothing is sent to Facebook (New Arrivals page).
//
// Secrets: FACEBOOK_GMA_POST_TOKEN / FACEBOOK_GMA_PAGE_ID, FACEBOOK_RSPETSTOP_POST_TOKEN /
// FACEBOOK_RSPETSTOP_PAGE_ID (already set for facebook-page-post), FACEBOOK_GRAPH_API_VERSION optional.
//
// Deploy: supabase functions deploy new-arrivals-post --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';
const MAX_LISTED_ITEMS = 25;

type PostPage = 'gma' | 'amaya';
const PAGE_SECRETS: Record<PostPage, { token: string; id: string }> = {
  gma: { token: 'FACEBOOK_GMA_POST_TOKEN', id: 'FACEBOOK_GMA_PAGE_ID' },
  amaya: { token: 'FACEBOOK_RSPETSTOP_POST_TOKEN', id: 'FACEBOOK_RSPETSTOP_PAGE_ID' }
};

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

type ArrivalItem = { name?: string; category?: string; qty?: number };
type StoreInfo = { address: string | null; contact: string | null };

function itemEmoji(category: string | undefined): string {
  const c = String(category ?? '').toUpperCase();
  if (c.includes('PLANT')) return '🌿';
  if (c.includes('FISH') || c.includes('CICHLID') || c.includes('TETRA')) return '🐟';
  return '✨';
}

function buildCaption(branch: string, items: ArrivalItem[], store: StoreInfo): string {
  const seen = new Set<string>();
  const lines: string[] = [];
  for (const it of items) {
    const name = String(it.name ?? '').trim();
    if (!name || seen.has(name.toLowerCase())) continue;
    seen.add(name.toLowerCase());
    lines.push(`${itemEmoji(it.category)} ${name}`);
  }
  const shown = lines.slice(0, MAX_LISTED_ITEMS);
  if (lines.length > shown.length) shown.push(`...and ${lines.length - shown.length} more!`);

  const hasPlants = items.some((it) => String(it.category ?? '').toUpperCase().includes('PLANT'));
  const hasFish = items.some((it) => !String(it.category ?? '').toUpperCase().includes('PLANT'));
  const what = hasFish && hasPlants ? 'fish and plants' : hasPlants ? 'plants' : 'fish';

  const parts = [
    `📣 NEW ARRIVALS at RS Pet Stop ${branch}! 🐠`,
    '',
    `Fresh ${what} just arrived at our ${branch} branch:`,
    ...shown,
    '',
    'Limited stocks only - visit us or send us a message to reserve yours! 💬'
  ];
  const contact = [store.address ? `📍 ${store.address}` : null, store.contact ? `📞 ${store.contact}` : null].filter(Boolean) as string[];
  if (contact.length > 0) parts.push('', ...contact);
  parts.push('', `#RSPetStop #NewArrivals #RSPetStop${branch.replace(/\s+/g, '')} #AquariumPH #FishKeeping`);
  return parts.join('\n');
}

function branchLabel(page: PostPage, warehouse: string | null): string {
  if (page === 'amaya') return 'Amaya';
  if (page === 'gma') return 'GMA';
  return warehouse || 'Store';
}

async function storeInfo(supabase: SupabaseClient, branch: string): Promise<StoreInfo> {
  const { data } = await supabase.from('Warehouses').select('"Name", "Address", "ContactNo"')
    .ilike('Name', `%${branch}%`).order('Name').limit(1).maybeSingle();
  return { address: (data?.Address as string) || null, contact: (data?.ContactNo as string) || null };
}

async function bannerUrl(supabase: SupabaseClient): Promise<string | null> {
  const { data: settings } = await supabase.from('NewArrivalSettings').select('"BannerUrl"').eq('Id', 1).maybeSingle();
  if (settings?.BannerUrl) return String(settings.BannerUrl);
  const { data: company } = await supabase.from('CompanyInfo').select('"LogoUrl"').eq('Id', 1).maybeSingle();
  return (company?.LogoUrl as string) || null;
}

class PostError extends Error {
  constructor(message: string, public retryable: boolean) {
    super(message);
  }
}

// One POST /{page-id}/photos with a public image URL. No retry here - a definite Facebook rejection
// is marked retryable (the claim retries it later); a network failure is not (it may have posted).
async function postToFacebook(page: PostPage, imageUrl: string, caption: string) {
  const secrets = PAGE_SECRETS[page];
  const pageToken = Deno.env.get(secrets.token);
  const pageId = Deno.env.get(secrets.id);
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  if (!pageToken || !pageId) throw new PostError(`Missing the ${secrets.token} and/or ${secrets.id} secret.`, true);

  const form = new FormData();
  form.append('url', imageUrl);
  form.append('caption', caption);
  form.append('access_token', pageToken);

  let res: Response;
  try {
    res = await fetch(`https://graph.facebook.com/${graphVersion}/${pageId}/photos`, { method: 'POST', body: form });
  } catch (err) {
    throw new PostError(`Could not reach Facebook: ${errorText(err)}`, false);
  }
  const result = await res.json().catch(() => null);
  if (!result) throw new PostError(`Facebook: unreadable response (HTTP ${res.status}) - check the Page before retrying.`, false);
  if (!res.ok || result.error) throw new PostError(`Facebook: ${result?.error?.message || `HTTP ${res.status}`}`, true);
  return {
    postId: (result.post_id ?? result.id ?? null) as string | null,
    postUrl: result.post_id ? `https://www.facebook.com/${result.post_id}` : null
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.' }, 500);
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }
  const action = String(body.action ?? 'dispatch');

  if (action === 'preview') {
    const warehouse = String(body.warehouse ?? 'GMA');
    const page: PostPage = /amaya/i.test(warehouse) ? 'amaya' : 'gma';
    const branch = branchLabel(page, warehouse);
    const items = Array.isArray(body.items) ? (body.items as ArrivalItem[]).slice(0, 100) : [];
    return jsonResponse({ ok: true, caption: buildCaption(branch, items, await storeInfo(supabase, branch)) });
  }

  if (action !== 'dispatch') return jsonResponse({ error: "action must be 'dispatch' or 'preview'." }, 400);

  const { data: claimed, error: claimError } = await supabase.rpc('service_claim_new_arrival_posts', { p_limit: 5 });
  if (claimError) return jsonResponse({ error: `Claim failed: ${claimError.message}` }, 500);
  const rows = (claimed ?? []) as Array<Record<string, unknown>>;
  if (rows.length === 0) return jsonResponse({ ok: true, posted: 0 });

  const image = await bannerUrl(supabase);
  const results: Array<Record<string, unknown>> = [];

  for (const row of rows) {
    const id = Number(row.Id);
    const page = String(row.Page) as PostPage;
    let caption: string | null = null;
    try {
      if (!PAGE_SECRETS[page]) throw new PostError(`Unknown Page '${row.Page}'.`, false);
      if (!image) throw new PostError('No New Arrivals banner and no company logo - open New Arrivals and save the banner.', true);
      const branch = branchLabel(page, row.Warehouse as string | null);
      caption = buildCaption(branch, (row.Items as ArrivalItem[]) ?? [], await storeInfo(supabase, branch));
      const posted = await postToFacebook(page, image, caption);
      await supabase.rpc('service_finish_new_arrival_post', {
        p_id: id, p_ok: true, p_caption: caption, p_post_id: posted.postId, p_post_url: posted.postUrl, p_error: null, p_retryable: false
      });
      results.push({ id, document_no: row.DocumentNo, ok: true, post_url: posted.postUrl });
    } catch (err) {
      const retryable = err instanceof PostError ? err.retryable : false;
      await supabase.rpc('service_finish_new_arrival_post', {
        p_id: id, p_ok: false, p_caption: caption, p_post_id: null, p_post_url: null, p_error: errorText(err), p_retryable: retryable
      });
      results.push({ id, document_no: row.DocumentNo, ok: false, error: errorText(err) });
    }
  }

  return jsonResponse({ ok: true, posted: results.filter((r) => r.ok).length, results });
});
