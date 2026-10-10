// PROTOTYPE - backs docs/facebook-post-test.html, built per direct request to try automated
// Facebook Page posting before building the real scheduled-post queue. Two actions:
//
//   { action: 'caption', image_base64, media_type, notes? }
//       Claude looks at the photo (plus any staff notes - price, promo, stock) and writes a
//       Facebook caption, following the standing FacebookPostSettings.CaptionDirections set in
//       AI Bot Setup. Nothing is sent to Facebook.
//
//   { action: 'post', image_base64, media_type, caption, scheduled_at_unix? }
//       Uploads the photo to the GMA Page via POST /{page-id}/photos. With scheduled_at_unix it is
//       a SCHEDULED post (published=false + scheduled_publish_time) - it shows in Meta Business
//       Suite > Planner, where it can be reviewed or deleted before it goes out, which is the safe
//       way to test. Without it the post is published immediately.
//
// Uses its own secrets, NOT the Messenger bot's FACEBOOK_PAGE_ACCESS_TOKEN, so a posting token
// problem can never break Alice:
//   FACEBOOK_GMA_POST_TOKEN - never-expiring Page token with pages_manage_posts + pages_read_engagement
//   FACEBOOK_GMA_PAGE_ID    - the RSPetStop GMA Page id
//
// Admin-gated: the caller passes admin_username/admin_password, re-verified via
// is_admin_authorized() on every call - same trust model as chatbot-sandbox-reply.
//
// Deploy: supabase functions deploy facebook-page-post --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const DEFAULT_MODEL = 'claude-sonnet-5';
const DEFAULT_GRAPH_VERSION = 'v21.0';
const ALLOWED_MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
// Facebook only accepts a scheduled_publish_time between 10 minutes and 30 days from now.
const MIN_SCHEDULE_SECONDS = 10 * 60;
const MAX_SCHEDULE_SECONDS = 30 * 24 * 60 * 60;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

const CAPTION_SYSTEM_PROMPT = `You write Facebook Page posts for RS Pet Stop GMA, an aquarium and pet supply store in the Philippines (custom aquariums, stands, fish, and aquarium/pet supplies).

Write ONE ready-to-post caption for the photo you are given:
- Friendly, upbeat, natural - English with light, casual Taglish is fine. Sound like a local shop, not an ad agency.
- Open with a short hook line, then 1-3 short lines about what is in the photo.
- Use the staff notes for facts (prices, promos, stock, sizes). NEVER invent a price, discount, size or stock count that is not in the notes.
- End with a call to action to message the Page to order or ask.
- A few relevant emojis (not one per line) and 3-6 hashtags on the last line, including #RSPetStop.
- Keep it under about 600 characters.

Reply with the caption text only - no preamble, no quotes, no options.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'facebook-page-post is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.' }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON.' }, 400);
  }

  const adminUsername = String(body.admin_username ?? '');
  const adminPassword = String(body.admin_password ?? '');
  const action = String(body.action ?? '');
  const imageBase64 = String(body.image_base64 ?? '');
  const mediaType = String(body.media_type ?? 'image/jpeg');

  if (!adminUsername || !adminPassword) return jsonResponse({ error: 'Missing admin_username / admin_password.' }, 400);
  if (!imageBase64) return jsonResponse({ error: 'Missing image_base64.' }, 400);
  if (!ALLOWED_MEDIA_TYPES.includes(mediaType)) return jsonResponse({ error: `Unsupported image type ${mediaType}.` }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);

  if (action === 'caption') {
    const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!anthropicApiKey) return jsonResponse({ error: 'Missing the ANTHROPIC_API_KEY secret.' }, 500);
    const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;
    const notes = String(body.notes ?? '').trim();

    // Standing caption directions from AI Bot Setup > Facebook Posts (supabase_facebook_post_settings.sql).
    // Optional - the table may not exist yet, in which case the built-in rules alone apply.
    const { data: postSettings } = await supabase.from('FacebookPostSettings').select('"CaptionDirections"').eq('Id', 1).maybeSingle();
    const directions = (postSettings?.CaptionDirections as string | undefined)?.trim();
    const systemPrompt = directions
      ? `${CAPTION_SYSTEM_PROMPT}\n\nStore owner's standing directions (always follow these; they override the style rules above):\n${directions}`
      : CAPTION_SYSTEM_PROMPT;

    try {
      const anthropic = new Anthropic({ apiKey: anthropicApiKey });
      const response = await anthropic.messages.create({
        model,
        max_tokens: 1024,
        system: systemPrompt,
        messages: [{
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mediaType as 'image/jpeg', data: imageBase64 } },
            { type: 'text', text: notes ? `Staff notes: ${notes}` : 'No staff notes - describe only what is visible, with no prices.' }
          ]
        }]
      });
      const caption = response.content
        .filter((block) => block.type === 'text')
        .map((block) => (block as { text: string }).text)
        .join('\n')
        .trim();
      return jsonResponse({ ok: true, caption });
    } catch (err) {
      return jsonResponse({ error: `Caption failed: ${err instanceof Error ? err.message : String(err)}` }, 500);
    }
  }

  if (action === 'post') {
    const pageToken = Deno.env.get('FACEBOOK_GMA_POST_TOKEN');
    const pageId = Deno.env.get('FACEBOOK_GMA_PAGE_ID');
    const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
    if (!pageToken || !pageId) {
      return jsonResponse({ error: 'Missing the FACEBOOK_GMA_POST_TOKEN and/or FACEBOOK_GMA_PAGE_ID secret (Supabase > Edge Functions > Secrets).' }, 500);
    }

    const caption = String(body.caption ?? '').trim();
    if (!caption) return jsonResponse({ error: 'Caption is empty.' }, 400);

    const scheduledAt = body.scheduled_at_unix == null || body.scheduled_at_unix === '' ? null : Number(body.scheduled_at_unix);
    if (scheduledAt != null) {
      const secondsAhead = scheduledAt - Math.floor(Date.now() / 1000);
      if (!Number.isFinite(scheduledAt) || secondsAhead < MIN_SCHEDULE_SECONDS || secondsAhead > MAX_SCHEDULE_SECONDS) {
        return jsonResponse({ error: 'Schedule time must be between 10 minutes and 30 days from now.' }, 400);
      }
    }

    let bytes: Uint8Array;
    try {
      bytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
    } catch {
      return jsonResponse({ error: 'image_base64 is not valid base64.' }, 400);
    }

    const form = new FormData();
    form.append('source', new Blob([bytes], { type: mediaType }), 'photo');
    form.append('caption', caption);
    form.append('access_token', pageToken);
    if (scheduledAt != null) {
      form.append('published', 'false');
      form.append('scheduled_publish_time', String(scheduledAt));
    }

    try {
      const res = await fetch(`https://graph.facebook.com/${graphVersion}/${pageId}/photos`, { method: 'POST', body: form });
      const result = await res.json().catch(() => ({}));
      if (!res.ok || result.error) {
        return jsonResponse({ error: `Facebook: ${result?.error?.message || `HTTP ${res.status}`}` }, 502);
      }
      return jsonResponse({
        ok: true,
        scheduled: scheduledAt != null,
        photo_id: result.id ?? null,
        post_id: result.post_id ?? null,
        post_url: result.post_id ? `https://www.facebook.com/${result.post_id}` : null
      });
    } catch (err) {
      return jsonResponse({ error: `Could not reach Facebook: ${err instanceof Error ? err.message : String(err)}` }, 502);
    }
  }

  return jsonResponse({ error: "action must be 'caption' or 'post'." }, 400);
});
