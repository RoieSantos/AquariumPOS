// Video Ad Builder "From our Facebook page" (video-ad-builder.html) - lists the photos and videos posted
// on our Facebook Pages so staff can use the real ones (finished tanks, deliveries) in a 📷 scene.
//
//   POST { admin_username, admin_password }
//   ->   { items: [{ page, kind: 'image'|'video', thumb, src, created, caption, post }],
//          pages: [{ name, ok, error?, count? }] }
//   POST { admin_username, admin_password, import: { kind, src } }
//   ->   { url }   - the file copied into the video-ad-media bucket
//
// Facebook's file links (fbcdn) expire after a while and can't be drawn into the exported MP4 (no CORS),
// so a picked file is copied into our own bucket first. Only fbcdn / facebook URLs are fetched.
//
// Read-only on Facebook: GETs of each Page's /photos?type=uploaded and /videos with the Page tokens the
// other functions already use (needs pages_read_engagement). A Page whose token can't read them is
// reported in "pages" with the error.
//
// Super users only (is_admin_authorized), like the page.
//
// Deploy: supabase functions deploy video-ad-page-media --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';
const MEDIA_BUCKET = 'video-ad-media';
const MAX_BYTES = 50 * 1024 * 1024;
const PHOTO_LIMIT = 100; // newest per Page
const VIDEO_LIMIT = 50;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

async function graphGet(graphVersion: string, path: string, params: Record<string, string>) {
  const url = `https://graph.facebook.com/${graphVersion}/${path}?${new URLSearchParams(params).toString()}`;
  try {
    const res = await fetch(url);
    const body = await res.json().catch(() => ({}));
    return { ok: res.ok && !body.error, body };
  } catch (err) {
    return { ok: false, body: { error: { message: String(err) } } };
  }
}

// Every distinct Page token we have (same list as video-ad-reviews).
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

function isFacebookFileUrl(value: string): boolean {
  try {
    const u = new URL(value);
    return u.protocol === 'https:' && /(^|\.)(fbcdn\.net|facebook\.com)$/.test(u.hostname);
  } catch {
    return false;
  }
}

// post = the Page post a photo was shared in (page_story_id), so the picker can take a whole post's photos.
type Item = { page: string; kind: 'image' | 'video'; thumb: string; src: string; created: string; caption: string; post: string | null };

async function listMedia(graphVersion: string) {
  const items: Item[] = [];
  const pages: { name: string; ok: boolean; error?: string; count?: number }[] = [];
  const seenPages = new Set<string>();

  for (const token of pageTokens()) {
    const me = await graphGet(graphVersion, 'me', { fields: 'id,name', access_token: token });
    if (!me.ok || !me.body.id || seenPages.has(me.body.id)) continue;
    seenPages.add(me.body.id);
    const pageName = String(me.body.name || me.body.id);

    let [photos, videos] = await Promise.all([
      graphGet(graphVersion, 'me/photos', { type: 'uploaded', fields: 'images,created_time,name,page_story_id', limit: String(PHOTO_LIMIT), access_token: token }),
      graphGet(graphVersion, 'me/videos', { fields: 'source,picture,created_time,description,title', limit: String(VIDEO_LIMIT), access_token: token })
    ]);
    // If Facebook refuses page_story_id, list the photos without their post (no "Posts" grouping).
    if (!photos.ok) photos = await graphGet(graphVersion, 'me/photos', { type: 'uploaded', fields: 'images,created_time,name', limit: String(PHOTO_LIMIT), access_token: token });
    if (!photos.ok && !videos.ok) {
      pages.push({ name: pageName, ok: false, error: photos.body?.error?.message || 'Could not read photos.' });
      continue;
    }

    let count = 0;
    for (const p of (photos.ok ? photos.body.data ?? [] : []) as Record<string, any>[]) {
      // images = every size Facebook keeps, largest first.
      const sizes = (Array.isArray(p.images) ? p.images : []) as { source: string; width: number; height: number }[];
      if (!sizes.length) continue;
      const big = sizes[0];
      const small = sizes.find((x) => Math.max(x.width, x.height) <= 480) || sizes[sizes.length - 1];
      items.push({ page: pageName, kind: 'image', thumb: small.source, src: big.source, created: String(p.created_time ?? ''), caption: String(p.name ?? '').slice(0, 200), post: p.page_story_id ? String(p.page_story_id) : null });
      count++;
    }
    for (const v of (videos.ok ? videos.body.data ?? [] : []) as Record<string, any>[]) {
      if (!v.source) continue;
      items.push({ page: pageName, kind: 'video', thumb: String(v.picture ?? ''), src: String(v.source), created: String(v.created_time ?? ''), caption: String(v.title || v.description || '').slice(0, 200), post: null });
      count++;
    }
    pages.push({ name: pageName, ok: true, count });
  }

  items.sort((a, b) => b.created.localeCompare(a.created));
  return { items, pages };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'video-ad-page-media is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.' }, 500);

  let body: Record<string, any>;
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

  if (!body.import) {
    if (!pageTokens().length) return jsonResponse({ error: 'No Facebook Page token is set up.' }, 500);
    return jsonResponse(await listMedia(Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION));
  }

  // Copy one picked file into our bucket.
  const kind = body.import.kind === 'video' ? 'video' : 'image';
  const src = String(body.import.src ?? '');
  if (!isFacebookFileUrl(src)) return jsonResponse({ error: 'That is not a Facebook file link.' }, 400);

  let res: Response;
  try {
    res = await fetch(src);
  } catch (err) {
    return jsonResponse({ error: 'Could not download it from Facebook: ' + String(err) }, 502);
  }
  if (!res.ok) return jsonResponse({ error: `Facebook would not give the file (HTTP ${res.status}) - reload the list and try again.` }, 502);
  if (Number(res.headers.get('content-length') || 0) > MAX_BYTES) return jsonResponse({ error: 'That video is over 50 MB - trim it and upload it from your phone instead.' }, 400);
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.byteLength > MAX_BYTES) return jsonResponse({ error: 'That video is over 50 MB - trim it and upload it from your phone instead.' }, 400);

  const contentType = kind === 'video' ? 'video/mp4' : 'image/jpeg';
  const now = new Date();
  const stamp = now.toISOString().replace(/\D/g, '').slice(0, 17);
  const path = `${now.toISOString().slice(0, 7)}/${stamp}_facebook.${kind === 'video' ? 'mp4' : 'jpg'}`;
  const { error: uploadError } = await supabase.storage.from(MEDIA_BUCKET).upload(path, bytes, { contentType, upsert: false });
  if (uploadError) return jsonResponse({ error: 'Could not save it: ' + uploadError.message }, 500);

  return jsonResponse({ url: supabase.storage.from(MEDIA_BUCKET).getPublicUrl(path).data.publicUrl });
});
