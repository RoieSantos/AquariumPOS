// Facebook Page posting for the portal. Actions:
//
//   { action: 'caption', image_base64, media_type, notes?, context? }
//       Claude looks at the photo (plus any staff notes - price, promo, stock) and writes a
//       Facebook caption, following the standing FacebookPostSettings.CaptionDirections set in
//       AI Bot Setup. Nothing is sent to Facebook. (Quick Post / Facebook Post Test.)
//
//   { action: 'post', image_base64, media_type, caption, scheduled_at_unix? }
//       Uploads the photo to the GMA Page via POST /{page-id}/photos. With scheduled_at_unix it is
//       a SCHEDULED post (published=false + scheduled_publish_time) - it shows in Meta Business
//       Suite > Planner, where it can be reviewed or deleted before it goes out. Without it the
//       post is published immediately. (Quick Post / Facebook Post Test.)
//
//   Delivery route "Mark Done" (delivery.html) - two steps, so a delivery is recorded as Done even
//   when Facebook is down or the posting token breaks (supabase_delivery_stop_done_post.sql):
//   { action: 'mark_done', stop_id, image_base64, media_type }
//       Saves the watermarked photo to the online-order-status-photos bucket and marks the stop
//       Done / its order Delivered. No Facebook call. Already-done stops are left as they are.
//   { action: 'post_stop', stop_id }
//       Posts a Done stop to Facebook ONCE: claims the stop first (service_claim_delivery_stop_post),
//       so a double tap, a second phone or a retry can never post the same stop twice. Uses the
//       STORED photo and writes the Delivery Done caption itself, so it can be retried any time
//       from the stop card ("Post to Facebook") even after the app was closed.
//
// Facebook is only ever called by 'post' and 'post_stop', once per request, with no automatic
// retry - and nothing calls this function on a timer; every call is a staff tap.
//
// Uses its own secrets, NOT the Messenger bot's FACEBOOK_PAGE_ACCESS_TOKEN, so a posting token
// problem can never break Alice:
//   FACEBOOK_GMA_POST_TOKEN - never-expiring Page token with pages_manage_posts + pages_read_engagement
//   FACEBOOK_GMA_PAGE_ID    - the RSPetStop GMA Page id
//
// Staff-gated: the caller passes admin_username/admin_password, re-verified via
// is_staff_authorized() on every call, and must be a Super User or on the Delivery Team
// (the Delivery Team uses Mark Done).
//
// Deploy: supabase functions deploy facebook-page-post --project-ref hymcmesqgpliyyeghpgq

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const DEFAULT_MODEL = 'claude-sonnet-5';
// Small, cheap model for pulling just the city out of a delivery address (deliveryCity).
const CITY_MODEL = 'claude-haiku-4-5-20251001';
const DEFAULT_GRAPH_VERSION = 'v21.0';
const ALLOWED_MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const PHOTO_BUCKET = 'online-order-status-photos';
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
// `openings`, when set, is enforced after generation - the caption must start with one of them.
type PostAngle = { label: string; instruction: string; openings?: string[] };
type Staff = Record<string, unknown> | null;

const DELIVERY_ANGLE: PostAngle = { label: 'Delivery', openings: ['Delivery Done! ✅', 'Setup Done! ✅'], instruction: 'Taken by our delivery team at the customer\'s place: open with "Delivery Done! ✅" (or "Setup Done! ✅" if the photo shows the tank installed/set up in a home or office), then thank the customer and invite others to order. If the staff notes give a "Delivered to" city, mention it naturally (e.g. "delivered to our customer in Marikina") - the city only. Never give customer names, streets, barangays, subdivisions or house numbers, and never name a place that is not in the notes. Mention that we deliver and set up.' };

// `context: 'delivery_done'` (Mark Done on a delivery stop, delivery.html) always uses the
// Delivery angle, whoever is logged in.
function posterAngle(staff: Staff, context: string): PostAngle {
  const roles = (staff?.StaffRoles as string[] | null) ?? [];
  if (context === 'delivery_done' || staff?.DeliveryTeam) return DELIVERY_ANGLE;
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

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

// Every caption is grounded in the real business (General Setup's CompanyInfo + AI Bot Setup's
// Store Info, the same facts Alice uses) AND the photo. Standing caption directions come from
// AI Bot Setup > Facebook Posts (supabase_facebook_post_settings.sql) - optional, the table may not
// exist yet. Throws on failure.
async function writeCaption(
  supabase: SupabaseClient, staff: Staff, context: string, notes: string, imageBase64: string, mediaType: string
): Promise<{ caption: string; angle: string; branch: string | null }> {
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!anthropicApiKey) throw new Error('Missing the ANTHROPIC_API_KEY secret.');
  const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;

  const [{ data: company }, { data: storeInfo }, { data: postSettings }] = await Promise.all([
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('FacebookPostSettings').select('"CaptionDirections"').eq('Id', 1).maybeSingle()
  ]);
  const branchName = (staff?.WarehouseName as string | undefined)?.trim() || null;
  const { data: branch } = branchName
    ? await supabase.from('Warehouses').select('"Name", "Address", "ContactNo"').eq('Name', branchName).maybeSingle()
    : { data: null };
  const angle = posterAngle(staff, context);
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
  if (branchName) {
    const branchFacts = [`- Branch: RS Pet Stop ${branch?.Name || branchName}`];
    if (branch?.Address) branchFacts.push(`- Branch address: ${branch.Address}`);
    if (branch?.ContactNo) branchFacts.push(`- Branch contact: ${branch.ContactNo}`);
    systemPrompt += `\nThe photo was taken at this branch - mention the branch name, and prefer its contact number over the main one:\n${branchFacts.join('\n')}`;
  }
  if (directions) {
    systemPrompt += `\n\nStore owner's standing directions (always follow these; they override the style rules above):\n${directions}`;
  }
  // Last, so neither the example caption nor the standing directions can override it.
  systemPrompt += `\n\nREQUIRED angle for this post, based on who took the photo (this overrides the example caption and any opening line above):\n${angle.instruction}`;

  const anthropic = new Anthropic({ apiKey: anthropicApiKey });
  const response = await anthropic.messages.create({
    model,
    max_tokens: 1024,
    system: systemPrompt,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType as 'image/jpeg', data: imageBase64 } },
        {
          type: 'text',
          text: [
            `Photo taken by: ${angle.label} staff.${angle.openings ? ` The caption MUST start with ${angle.openings.map((o) => `"${o}"`).join(' or ')}.` : ''}`,
            notes ? `Staff notes: ${notes}` : 'No staff notes - describe only what is visible, with no prices.'
          ].join('\n')
        }
      ]
    }]
  });
  let caption = response.content
    .filter((block) => block.type === 'text')
    .map((block) => (block as { text: string }).text)
    .join('\n')
    .trim();
  // Safety net: if the model skipped the required opening (e.g. "Delivery Done! ✅"), add it.
  // Leading emoji/punctuation is ignored, so "✅ Delivery Done!" also counts.
  const captionStart = caption.replace(/^[^\p{L}]+/u, '').toLowerCase();
  if (angle.openings && !angle.openings.some((o) => captionStart.startsWith(o.toLowerCase().replace(/[!✅ ]+$/u, '')))) {
    caption = `${angle.openings[0]}\n${caption}`;
  }
  return { caption, angle: angle.label, branch: branchName };
}

// Per "can you include the main address (dont include the complete address) ... the city only":
// the stop's address as the driver sees it (stop's manual address, else the order's / draft AO's
// shipping address, else the map address for a walk-in), reduced to just the city / municipality
// by a separate text-only call - so the caption writer only ever sees the city, never the full
// address. null when there's no usable address or the city isn't clear (caption leaves it out).
async function deliveryCity(supabase: SupabaseClient, stop: Record<string, unknown>): Promise<string | null> {
  const clean = (v: unknown) => {
    const s = typeof v === 'string' ? v.trim() : '';
    return s && s.toLowerCase() !== 'walkin' ? s : null;
  };
  let address = clean(stop.ManualAddress);
  if (!address && stop.OrderID) {
    const { data } = await supabase.from('OnlineOrders').select('"ShippingAddress"').eq('OrderID', stop.OrderID).maybeSingle();
    address = clean(data?.ShippingAddress);
  }
  if (!address && stop.AutomatedOrderNo) {
    const { data } = await supabase.from('AutomatedOrders').select('"DeliveryAddress"').eq('OrderNo', stop.AutomatedOrderNo).maybeSingle();
    address = clean(data?.DeliveryAddress);
  }
  address = address || clean(stop.GeocodedAddress);
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!address || !anthropicApiKey) return null;

  try {
    const anthropic = new Anthropic({ apiKey: anthropicApiKey });
    const response = await anthropic.messages.create({
      model: CITY_MODEL,
      max_tokens: 20,
      system: 'You are given a delivery address in the Philippines. Reply with ONLY the city or municipality name, in its usual short form (e.g. "Marikina", "Malabon", "Dasmariñas", "General Trias", "Quezon City"). No barangay, street, subdivision, province or country. If you cannot tell, reply NONE.',
      messages: [{ role: 'user', content: address }]
    });
    const city = response.content
      .filter((block) => block.type === 'text')
      .map((block) => (block as { text: string }).text)
      .join(' ')
      .trim()
      .replace(/^["']|["'.]$/g, '');
    // Only a plain place name gets through - never anything that looks like part of an address.
    if (!city || /^none$/i.test(city) || city.length > 40 || /\d|,|\b(brgy|barangay|street|st\.|blk|lot|purok|subd)\b/i.test(city)) return null;
    return city;
  } catch (err) {
    console.error(`Delivery city lookup failed: ${errorText(err)}`);
    return null;
  }
}

// One POST /{page-id}/photos - the only place this code publishes to Facebook. No retry. Throws on
// failure; returns Facebook's ids and the post link.
async function postPhotoToFacebook(
  bytes: Uint8Array, mediaType: string, caption: string, scheduledAt: number | null
): Promise<{ photoId: string | null; postId: string | null; postUrl: string | null }> {
  const pageToken = Deno.env.get('FACEBOOK_GMA_POST_TOKEN');
  const pageId = Deno.env.get('FACEBOOK_GMA_PAGE_ID');
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  if (!pageToken || !pageId) {
    throw new Error('Missing the FACEBOOK_GMA_POST_TOKEN and/or FACEBOOK_GMA_PAGE_ID secret (Supabase > Edge Functions > Secrets).');
  }

  const form = new FormData();
  form.append('source', new Blob([bytes], { type: mediaType }), 'photo');
  form.append('caption', caption);
  form.append('access_token', pageToken);
  if (scheduledAt != null) {
    form.append('published', 'false');
    form.append('scheduled_publish_time', String(scheduledAt));
  }

  let res: Response;
  try {
    res = await fetch(`https://graph.facebook.com/${graphVersion}/${pageId}/photos`, { method: 'POST', body: form });
  } catch (err) {
    throw new Error(`Could not reach Facebook: ${errorText(err)}`);
  }
  const result = await res.json().catch(() => ({}));
  if (!res.ok || result.error) throw new Error(`Facebook: ${result?.error?.message || `HTTP ${res.status}`}`);
  return {
    photoId: result.id ?? null,
    postId: result.post_id ?? null,
    postUrl: result.post_id ? `https://www.facebook.com/${result.post_id}` : null
  };
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
  const stopId = String(body.stop_id ?? '').trim();

  if (!adminUsername || !adminPassword) return jsonResponse({ error: 'Missing admin_username / admin_password.' }, 400);
  if (!['caption', 'post', 'mark_done', 'post_stop'].includes(action)) {
    return jsonResponse({ error: "action must be 'caption', 'post', 'mark_done' or 'post_stop'." }, 400);
  }
  // post_stop uses the photo already stored by mark_done.
  if (action !== 'post_stop') {
    if (!imageBase64) return jsonResponse({ error: 'Missing image_base64.' }, 400);
    if (!ALLOWED_MEDIA_TYPES.includes(mediaType)) return jsonResponse({ error: `Unsupported image type ${mediaType}.` }, 400);
  }
  if ((action === 'mark_done' || action === 'post_stop') && !stopId) return jsonResponse({ error: 'Missing stop_id.' }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_staff_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);

  // Who is posting - read from StaffUsers by the username that just passed is_staff_authorized,
  // never from anything the browser claims (not verify_login, which bumps login counters).
  const { data: staff } = await supabase.from('StaffUsers')
    .select('"SuperUser", "WarehouseName", "StaffRoles", "ProductionMember", "StoreManager", "SalesUser", "DeliveryTeam"')
    .eq('Username', adminUsername).maybeSingle();
  if (!staff?.SuperUser && !staff?.DeliveryTeam) return jsonResponse({ error: 'Not authorized to post.' }, 403);

  let bytes: Uint8Array | null = null;
  if (imageBase64) {
    try {
      bytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
    } catch {
      return jsonResponse({ error: 'image_base64 is not valid base64.' }, 400);
    }
  }

  if (action === 'caption') {
    try {
      const result = await writeCaption(supabase, staff, String(body.context ?? ''), String(body.notes ?? '').trim(), imageBase64, mediaType);
      return jsonResponse({ ok: true, ...result });
    } catch (err) {
      return jsonResponse({ error: `Caption failed: ${errorText(err)}` }, 500);
    }
  }

  if (action === 'post') {
    const caption = String(body.caption ?? '').trim();
    if (!caption) return jsonResponse({ error: 'Caption is empty.' }, 400);

    const scheduledAt = body.scheduled_at_unix == null || body.scheduled_at_unix === '' ? null : Number(body.scheduled_at_unix);
    if (scheduledAt != null) {
      const secondsAhead = scheduledAt - Math.floor(Date.now() / 1000);
      if (!Number.isFinite(scheduledAt) || secondsAhead < MIN_SCHEDULE_SECONDS || secondsAhead > MAX_SCHEDULE_SECONDS) {
        return jsonResponse({ error: 'Schedule time must be between 10 minutes and 30 days from now.' }, 400);
      }
    }

    try {
      const posted = await postPhotoToFacebook(bytes!, mediaType, caption, scheduledAt);
      return jsonResponse({ ok: true, scheduled: scheduledAt != null, photo_id: posted.photoId, post_id: posted.postId, post_url: posted.postUrl });
    } catch (err) {
      return jsonResponse({ error: errorText(err) }, 502);
    }
  }

  if (action === 'mark_done') {
    // Already done (second phone, double tap): leave it - nothing uploaded, nothing changed.
    const { data: done } = await supabase.from('DeliveryStopCompletions').select('"StopID"').eq('StopID', stopId).maybeSingle();
    if (done) return jsonResponse({ ok: true, already_done: true });

    // select('*'): AutomatedOrderNo (a draft AO stop) only exists once
    // supabase_delivery_assign_automated_order_search.sql has been run.
    const { data: stop } = await supabase.from('DeliveryStops').select('*').eq('StopID', stopId).maybeSingle();
    const refId = (stop?.OrderID ?? stop?.AdvanceTransactionNo ?? stop?.AutomatedOrderNo) as string | undefined;
    if (!refId) return jsonResponse({ error: 'Delivery stop not found - it may have been removed or moved.' }, 404);

    // Same bucket/path layout as the Shipped proof photos (<order or advance no>/<timestamp>_<name>),
    // so it shows in the order's Photos as "Delivered" - and post_stop posts this stored copy.
    const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 17);
    const path = `${refId}/${stamp}_delivered.jpg`;
    const { error: uploadError } = await supabase.storage.from(PHOTO_BUCKET).upload(path, bytes!, { contentType: mediaType, upsert: false });
    if (uploadError) return jsonResponse({ error: `Could not save the photo: ${uploadError.message}` }, 500);
    const photoUrl = supabase.storage.from(PHOTO_BUCKET).getPublicUrl(path).data.publicUrl;

    const { data: newlyDone, error } = await supabase.rpc('service_mark_delivery_stop_done', {
      p_stop_id: stopId,
      p_username: adminUsername,
      p_photo_storage_path: path,
      p_photo_url: photoUrl
    });
    if (error) {
      // Not recorded - remove the photo so a retry starts clean.
      await supabase.storage.from(PHOTO_BUCKET).remove([path]);
      return jsonResponse({ error: `Could not mark the stop done: ${error.message}` }, 500);
    }
    return jsonResponse({ ok: true, already_done: newlyDone === false, photo_url: photoUrl });
  }

  // action === 'post_stop'
  // Claim first: returns the stored photo only if the stop is Done, not posted yet, and nobody else
  // is posting it right now. No row = nothing to do, so nothing is sent to Facebook.
  const { data: claimRows, error: claimError } = await supabase.rpc('service_claim_delivery_stop_post', { p_stop_id: stopId });
  if (claimError) return jsonResponse({ error: `Could not start the post: ${claimError.message}` }, 500);
  const claim = (claimRows as Array<{ photo_storage_path: string | null; facebook_post_url: string | null; status: string }> | null)?.[0];
  if (!claim || claim.status !== 'claimed') {
    return jsonResponse({
      ok: false,
      status: claim?.status ?? 'not_done',
      post_url: claim?.facebook_post_url ?? null,
      error: claim?.status === 'posted' ? 'Already posted to Facebook.'
        : claim?.status === 'in_progress' ? 'This stop is being posted right now.'
          : 'Mark the stop Done first.'
    }, 409);
  }

  const finish = (fields: { postId?: string | null; postUrl?: string | null; caption?: string | null; error?: string | null }) =>
    supabase.rpc('service_finish_delivery_stop_post', {
      p_stop_id: stopId,
      p_post_id: fields.postId ?? null,
      p_post_url: fields.postUrl ?? null,
      p_caption: fields.caption ?? null,
      p_error: fields.error ?? null
    });

  let caption = '';
  try {
    if (!claim.photo_storage_path) throw new Error('No saved photo for this stop.');
    const { data: blob, error: downloadError } = await supabase.storage.from(PHOTO_BUCKET).download(claim.photo_storage_path);
    if (downloadError || !blob) throw new Error(`Could not load the saved photo: ${downloadError?.message ?? 'not found'}`);
    const photoBytes = new Uint8Array(await blob.arrayBuffer());
    // City only (deliveryCity) - the caption writer never sees the full address.
    const { data: stop } = await supabase.from('DeliveryStops').select('*').eq('StopID', stopId).maybeSingle();
    const city = stop ? await deliveryCity(supabase, stop) : null;
    caption = (await writeCaption(supabase, staff, 'delivery_done', city ? `Delivered to: ${city}` : '', bytesToBase64(photoBytes), 'image/jpeg')).caption;
    const posted = await postPhotoToFacebook(photoBytes, 'image/jpeg', caption, null);
    // Record the post right away - this is what stops a second post.
    await finish({ postId: posted.postId ?? posted.photoId, postUrl: posted.postUrl, caption });
    return jsonResponse({ ok: true, status: 'posted', caption, post_url: posted.postUrl });
  } catch (err) {
    // Releases the claim so "Post to Facebook" can be tried again.
    await finish({ caption: caption || null, error: errorText(err) });
    return jsonResponse({ ok: false, status: 'failed', caption: caption || null, error: errorText(err) }, 502);
  }
});
