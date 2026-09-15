// Sends a staff-authored reply to a customer on the GMA Conversations page (docs/gma-conversations.
// html) - the "own inbox instead of Pancake" feature: still Facebook Messenger underneath (same
// page/webhook as supabase/functions/facebook-messenger-webhook), just our own interface for staff
// to reply directly rather than a third-party CRM.
//
// Split into its own function (rather than folded into facebook-messenger-webhook) because that
// function's POST handler verifies Facebook's X-Hub-Signature-256 on every request - a
// browser-originated staff reply has no such signature and was never meant to carry one. This
// function is a plain CORS-enabled endpoint instead, called directly from the browser like
// delivery-toll-price/delivery-lalamove-* already are (see docs/js/deliveryQuote.js).
//
// For each item to send (one per photo, then the text, if any - see `images` below):
// admin_send_chatbot_message (supabase_chatbot_staff_attachment_upload.sql, latest definition)
// validates the admin session, logs it, and returns its new Id; then the actual Messenger delivery
// via sendWithFallback (tries the normal 'RESPONSE' type first, falling back to a tagged
// 'HUMAN_AGENT' message if the conversation is outside the 24h window), reusing
// FACEBOOK_PAGE_ACCESS_TOKEN/FACEBOOK_GRAPH_API_VERSION - already set as secrets for
// facebook-messenger-webhook; Supabase secrets are project-wide, so nothing new to configure. This
// function then writes the resulting DeliveryStatus ('Sent'/'Failed') directly onto that message row
// by Id - the one place it touches ChatbotMessages outside the RPC, since delivery is only known
// AFTER the RPC has already returned.
//
// Image/video support (a Quick Reply/Product List pick, or now an ad-hoc staff-attached photo OR
// video, can include one or more sent automatically): the caller passes an optional `images` array
// of {url, path, type} (each url already directly fetchable by Facebook; path is only set for an
// ad-hoc attachment - see docs/js/gmaConversations.js's onAttachmentFileChange - and gets recorded
// as ChatbotMessages.AttachmentPath so the existing 60-day cleanup cron can delete that Storage
// object later; a Quick Reply/Product List image has no path, since those live in permanent/
// external storage the cron has no business touching; type is 'image' (default) or 'video', and
// decides the actual Facebook Send API attachment type used below). `image_urls`/`image_url` (plain
// URL, no path/type - always treated as an image) are still accepted for any caller that only ever
// dealt in URLs. The Send API can't combine more than one item (an attachment or text) into a
// single call, so each photo/video becomes its own Messenger message (and its own ChatbotMessages
// row/bubble in the GMA thread), followed by the text as one final message if present - this is
// also literally how Facebook delivers it to the customer regardless, as separate messages one
// after another.
//
// Like support (per direct request replacing the old text "Send" button - Enter now sends typed
// text/images, and a filled thumbs-up button in that same toolbar slot sends a like on its own): the
// caller passes `like: true` (ignoring message/images entirely when set) and this sends Messenger's
// own native thumbs-up sticker via LIKE_STICKER_ID below, logging it as a plain thumbs-up-emoji text
// message (so it renders as a normal bubble in the GMA thread, same as if staff had typed the emoji)
// even though what the customer actually receives is the real animated Messenger sticker.
//
// Deploy: supabase functions deploy chatbot-staff-reply --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';

// Messenger's own well-known "big thumbs up" sticker id - sent via the Send API as an image-type
// attachment carrying sticker_id instead of a url (a documented Messenger Platform quirk: stickers
// are sent through the same "image" attachment type as a real photo, just with sticker_id in place
// of url). This is the exact sticker the native composer's like button sends.
const LIKE_STICKER_ID = 369239263222822;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

// Live-updates docs/gma-conversations.html for any OTHER open staff tab (the sender's own tab
// already refreshes locally on a successful send) - same channel/pattern as facebook-messenger-
// webhook's broadcastGmaEvent, duplicated here rather than shared since these are two independent
// Edge Functions. See that file's comment for why Broadcast (not postgres_changes).
async function broadcastGmaEvent(supabase: ReturnType<typeof createClient>, psid: string): Promise<void> {
  try {
    const channel = supabase.channel('gma-inbox');
    await new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      const timer = setTimeout(finish, 3000);
      channel.subscribe((status: string) => {
        if (status === 'SUBSCRIBED' && !settled) {
          clearTimeout(timer);
          channel.send({ type: 'broadcast', event: 'new_message', payload: { psid } }).finally(finish);
        }
      });
    });
    await channel.unsubscribe();
  } catch (err) {
    console.error('Failed to broadcast GMA inbox event:', err instanceof Error ? err.message : err);
  }
}

async function callSendApi(
  psid: string,
  messageBody: Record<string, unknown>,
  pageAccessToken: string,
  graphVersion: string,
  payloadExtra: Record<string, unknown>
): Promise<{ ok: boolean; bodyText: string; bodyJson: { error?: { message?: string; code?: number; error_subcode?: number } } | null }> {
  const res = await fetch(`https://graph.facebook.com/${graphVersion}/me/messages?access_token=${pageAccessToken}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ recipient: { id: psid }, message: messageBody, ...payloadExtra })
  });
  const bodyText = await res.text();
  let bodyJson = null;
  try {
    bodyJson = JSON.parse(bodyText);
  } catch {
    // non-JSON body - bodyText alone is still shown to staff below
  }
  return { ok: res.ok, bodyText, bodyJson };
}

// One Send API call for one message body, translating Facebook's raw error JSON into something a
// non-technical staff member can actually act on, instead of a wall of OAuthException JSON in the
// portal.
//
// Tries the normal 'RESPONSE' type first (works whenever the customer messaged within the last 24
// hours, needs no special Meta approval). Per direct report, customers sometimes go quiet for more
// than a day - Facebook then rejects 'RESPONSE' with error code 10, and the only way to still
// deliver the reply is a tagged 'HUMAN_AGENT' message (a Meta Feature requiring Business
// Verification + separate App Review approval - see App Dashboard > Permissions and Features). This
// function attempts that fallback automatically; if the tag itself isn't approved yet (error_subcode
// 2018276), it returns a plain-language explanation rather than that raw rejection.
async function sendWithFallback(
  psid: string,
  messageBody: Record<string, unknown>,
  pageAccessToken: string,
  graphVersion: string
): Promise<{ ok: true } | { ok: false; friendlyError: string }> {
  const first = await callSendApi(psid, messageBody, pageAccessToken, graphVersion, { messaging_type: 'RESPONSE' });
  if (first.ok) return { ok: true };

  const firstCode = first.bodyJson?.error?.code;
  const firstSubcode = first.bodyJson?.error?.error_subcode;
  const isOutsideWindow = firstCode === 10 && (firstSubcode === 2018278 || firstSubcode === 2534022);

  if (!isOutsideWindow) {
    return { ok: false, friendlyError: `Facebook rejected the message: ${first.bodyJson?.error?.message || first.bodyText}` };
  }

  const tagged = await callSendApi(psid, messageBody, pageAccessToken, graphVersion, { messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT' });
  if (tagged.ok) return { ok: true };

  if (tagged.bodyJson?.error?.error_subcode === 2018276) {
    return {
      ok: false,
      friendlyError:
        "This customer hasn't messaged in over 24 hours, so Facebook is blocking this reply. Sending after that window requires Meta's Human Agent feature, which isn't approved yet (it needs Business Verification first - see App Dashboard > Permissions and Features). For now, reply to them directly through Meta Business Suite or the native Facebook Page inbox instead."
    };
  }

  return { ok: false, friendlyError: `Facebook rejected the message: ${tagged.bodyJson?.error?.message || tagged.bodyText}` };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const pageAccessToken = Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN');
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;

  if (!supabaseUrl || !serviceRoleKey || !pageAccessToken) {
    return jsonResponse({ error: 'chatbot-staff-reply is missing one or more required secrets.' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let psid: string;
  let message: string;
  let images: { url: string; path: string | null; kind: 'image' | 'video' }[];
  let isLike: boolean;
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    psid = String(body.psid ?? '');
    message = String(body.message ?? '').trim();
    isLike = body.like === true;
    // images (array of {url, path, type}) is the current shape - path is the Storage object path
    // for a one-off ad-hoc attachment (see supabase_chatbot_staff_attachment_upload.sql), so it can
    // be recorded as ChatbotMessages.AttachmentPath and picked up by the existing 60-day cleanup
    // cron; null/omitted for a Quick Reply or Product List image, which live in permanent/external
    // storage that cron has no business touching. type is 'image' (default) or 'video' - per direct
    // follow-up request to also allow attaching a video, not just a photo - and decides which
    // Facebook Send API attachment type this gets sent as (see LIKE_STICKER_ID's sibling comment
    // below). image_urls (plain string array) and image_url (single string) are still accepted for
    // any caller that only ever dealt in plain image URLs.
    if (Array.isArray(body.images)) {
      images = (body.images as unknown[])
        .filter((it): it is Record<string, unknown> => !!it && typeof it === 'object')
        .map((it) => ({
          url: String(it.url ?? '').trim(),
          path: typeof it.path === 'string' && it.path.trim() ? it.path.trim() : null,
          kind: it.type === 'video' ? 'video' as const : 'image' as const
        }))
        .filter((it) => it.url.length > 0);
    } else {
      const rawUrls: unknown = Array.isArray(body.image_urls)
        ? body.image_urls
        : (typeof body.image_url === 'string' && body.image_url.trim() ? [body.image_url] : []);
      images = (rawUrls as unknown[])
        .filter((u): u is string => typeof u === 'string' && u.trim().length > 0)
        .map((u) => ({ url: u.trim(), path: null, kind: 'image' as const }));
    }
    if (!adminUsername || !adminPassword || !psid || (!message && images.length === 0 && !isLike)) {
      throw new Error('missing field');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, psid, message } (message, images, or like required).' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // One item per photo/video (logged + sent as its own message/bubble), then the text last, if
  // present - see the file header comment for why this can't be combined into a single Send API
  // call/DB row. A like send is always exactly one item on its own (message/images are ignored when
  // isLike).
  const items: { message: string; attachmentUrl: string | null; attachmentPath: string | null; attachmentKind: 'image' | 'video'; isLike: boolean }[] = isLike
    ? [{ message: '👍', attachmentUrl: null, attachmentPath: null, attachmentKind: 'image', isLike: true }]
    : [
        ...images.map((img) => ({ message: '', attachmentUrl: img.url, attachmentPath: img.path, attachmentKind: img.kind, isLike: false })),
        ...(message ? [{ message, attachmentUrl: null, attachmentPath: null, attachmentKind: 'image' as const, isLike: false }] : [])
      ];

  let friendlyError: string | null = null;

  for (const item of items) {
    const { data: messageId, error: dbError } = await supabase.rpc('admin_send_chatbot_message', {
      p_admin_username: adminUsername,
      p_admin_password: adminPassword,
      p_psid: psid,
      p_message: item.message,
      p_attachment_url: item.attachmentUrl,
      p_attachment_type: item.attachmentUrl ? item.attachmentKind : null,
      p_attachment_path: item.attachmentPath
    });

    if (dbError) {
      // Covers both "not authorized" and "no conversation found" - the RPC's own exception message
      // is safe to relay as-is, same as every other admin_* RPC's error handling in the portal JS.
      // Bails out immediately (rather than continuing with remaining items) since this almost always
      // means every item would fail the same way (bad credentials/psid).
      await broadcastGmaEvent(supabase, psid);
      return jsonResponse({ error: dbError.message }, 400);
    }

    try {
      const sendResult = item.isLike
        ? await sendWithFallback(psid, { attachment: { type: 'image', payload: { sticker_id: LIKE_STICKER_ID } } }, pageAccessToken, graphVersion)
        : item.attachmentUrl
          ? await sendWithFallback(psid, { attachment: { type: item.attachmentKind, payload: { url: item.attachmentUrl, is_reusable: true } } }, pageAccessToken, graphVersion)
          : await sendWithFallback(psid, { text: item.message }, pageAccessToken, graphVersion);

      // DeliveryStatus can't be known by admin_send_chatbot_message itself (it runs before this Send
      // API attempt), so it's set here directly - this is the one place chatbot-staff-reply touches
      // ChatbotMessages outside the RPC, and only for this operational field.
      if (messageId) {
        await supabase.from('ChatbotMessages').update({ DeliveryStatus: sendResult.ok ? 'Sent' : 'Failed' }).eq('Id', messageId);
      }

      if (!sendResult.ok && !friendlyError) {
        friendlyError = sendResult.friendlyError;
      }
    } catch (err) {
      if (!friendlyError) {
        friendlyError = err instanceof Error ? err.message : 'Could not reach Facebook.';
      }
    }
  }

  // Broadcast ONCE after every item is fully logged/sent, not per item - per direct report, a
  // multi-item send (several Quick Reply photos, or several picked products) was taking many
  // seconds because broadcastGmaEvent opens its own Realtime channel and waits (up to a 3s timeout)
  // for it to subscribe before sending, and this loop used to call it up to twice per item. The
  // sender's own tab already refreshes locally on a successful response (see sendMessageToCustomer
  // in docs/js/gmaConversations.js) - this broadcast only matters for OTHER open staff tabs, which
  // don't need per-item granularity, just to know something changed once it's all done.
  await broadcastGmaEvent(supabase, psid);

  if (friendlyError) {
    // Everything attempted is already logged in ChatbotMessages at this point (staff really did say
    // it) - this failure only means Facebook itself rejected DELIVERY for at least one item, which
    // the customer needs to be reached about some other way (native Messenger/Business Suite) until
    // it's resolved.
    return jsonResponse({ ok: false, loggedOnly: true, error: friendlyError }, 502);
  }

  return jsonResponse({ ok: true });
});
