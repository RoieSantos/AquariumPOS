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

Write ONE ready-to-post caption for the photo you are given. It must be about BOTH what is in the photo AND this business - a post this store would make about something it sells, builds or offers.

Keep it HIGH LEVEL - do not over-describe the photo:
- Name what it is in a few words only (e.g. "Custom aquarium set with stand and sump"). Do NOT describe backgrounds, decorations, colors, tiles, covers, filter media, parts or what is lying around.
- 2-3 short lines in total, then a call to action to message the Page to order or ask.
- If the photo is unclear or unrelated to the store, keep it general rather than guessing what it is.

Style:
- Friendly, upbeat, natural - English with light, casual Taglish is fine. Sound like a local shop, not an ad agency.
- Use the staff notes for facts (prices, promos, stock, sizes). NEVER invent a price, discount, size or stock count that is not in the notes.
- A few relevant emojis (not one per line) and 2-4 hashtags on the last line, including #RSPetStop.
- Keep it under about 300 characters.

Example of the right level of detail:
Bagong gawa! 🐟 Custom aquarium set with stand and built-in sump filter - ready for its new home.
Message us to order yours! 📩
#RSPetStop #CustomAquarium #AquariumPH

Reply with the caption text only - no preamble, no quotes, no options.`;

// Caption angle by who took the photo (StaffUsers flags/roles), checked in this order. Production
// staff photograph freshly built tanks, store staff photograph what's on display at their branch,
// delivery staff photograph orders going out - each reads best framed that way.
function posterAngle(staff: Record<string, unknown> | null): { label: string; instruction: string } {
  const roles = (staff?.StaffRoles as string[] | null) ?? [];
  if (staff?.DeliveryTeam) {
    return { label: 'Delivery', instruction: 'Taken by our delivery team at the customer\'s place: open with "Delivery Done! ✅" (or "Setup Done! ✅" if the photo shows the tank installed/set up in a home or office), then thank the customer and invite others to order. Never give customer names or exact addresses - a city/area is fine only if it is in the staff notes. Mention that we deliver and set up.' };
  }
  if (roles.includes('Dispatcher')) {
    return { label: 'Dispatch', instruction: 'Taken by our dispatcher as an order is sent out: frame it as an order on its way / ready for delivery. Do NOT mention any customer, name, address, city or destination - only the item. Mention that we deliver.' };
  }
  if (staff?.ProductionMember || roles.some((r) => ['TankMaker', 'StandMaker', 'ProductionManager'].includes(r))) {
    return { label: 'Production', instruction: 'Taken by our production team: frame it as freshly built in our own workshop, made to order in any size.' };
  }
  if (staff?.StoreManager || staff?.SalesUser) {
    return { label: 'Store', instruction: 'Taken by our store staff: frame it as available now at the branch below - invite people to visit or message to reserve.' };
  }
  return { label: 'General', instruction: 'General store post: frame it as something we offer.' };
}

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

    // Every caption is grounded in the real business (General Setup's CompanyInfo + AI Bot Setup's
    // Store Info, the same facts Alice uses) AND the photo. Standing caption directions come from
    // AI Bot Setup > Facebook Posts (supabase_facebook_post_settings.sql) - optional, the table
    // may not exist yet.
    // Who is posting - read from StaffUsers by the username that just passed is_admin_authorized,
    // never from anything the browser claims (not verify_login, which bumps login counters).
    const [{ data: company }, { data: storeInfo }, { data: postSettings }, { data: staff }] = await Promise.all([
      supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
      supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
      supabase.from('FacebookPostSettings').select('"CaptionDirections"').eq('Id', 1).maybeSingle(),
      supabase.from('StaffUsers')
        .select('"WarehouseName", "StaffRoles", "ProductionMember", "StoreManager", "SalesUser", "DeliveryTeam"')
        .eq('Username', adminUsername).maybeSingle()
    ]);
    const branchName = (staff?.WarehouseName as string | undefined)?.trim() || null;
    const { data: branch } = branchName
      ? await supabase.from('Warehouses').select('"Name", "Address", "ContactNo"').eq('Name', branchName).maybeSingle()
      : { data: null };
    const angle = posterAngle(staff);
    const businessFacts = [
      ['Business name', company?.CompanyName],
      ['Address', company?.Address],
      ['Contact number', company?.ContactNo],
      ['Facebook', company?.FacebookUrl],
      ['Business hours', storeInfo?.BusinessHours],
      ['Delivery', storeInfo?.DeliveryPolicy],
      ['Payment methods', storeInfo?.PaymentMethods],
      ['Pickup locations', storeInfo?.PickupLocations],
      ['Other store info', storeInfo?.AdditionalNotes]
    ]
      .filter(([, value]) => typeof value === 'string' && value.trim())
      .map(([label, value]) => `- ${label}: ${(value as string).trim()}`)
      .join('\n');
    const directions = (postSettings?.CaptionDirections as string | undefined)?.trim();

    let systemPrompt = CAPTION_SYSTEM_PROMPT;
    if (businessFacts) {
      systemPrompt += `\n\nAbout the business (real facts - use the ones that fit this post, e.g. delivery or how to order; never contradict them or invent others):\n${businessFacts}`;
    }
    systemPrompt += `\n\nAngle for this post: ${angle.instruction}`;
    if (branchName) {
      const branchFacts = [`- Branch: RS Pet Stop ${branch?.Name || branchName}`];
      if (branch?.Address) branchFacts.push(`- Branch address: ${branch.Address}`);
      if (branch?.ContactNo) branchFacts.push(`- Branch contact: ${branch.ContactNo}`);
      systemPrompt += `\nThe photo was taken at this branch - mention the branch name, and prefer its contact number over the main one:\n${branchFacts.join('\n')}`;
    }
    if (directions) {
      systemPrompt += `\n\nStore owner's standing directions (always follow these; they override the style rules above):\n${directions}`;
    }

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
      return jsonResponse({ ok: true, caption, angle: angle.label, branch: branchName });
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
