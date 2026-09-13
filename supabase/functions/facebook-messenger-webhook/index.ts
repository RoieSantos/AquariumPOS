// AI Messenger chatbot webhook for the NEW, plain Facebook Page (no Pancake/CRM layer - a
// separate integration from docs/order-now.html's Pancake-backed Automated Orders flow). Receives
// Facebook's Messenger webhook events directly, answers with Claude (tool-use against the store's
// real product/order data), and replies via the Messenger Send API.
//
// The actual persona/tools/pricing-math/tool-execution logic lives in
// supabase/functions/_shared/chatbot-engine.ts, shared with supabase/functions/chatbot-sandbox-
// reply (a portal-only testing sandbox, docs/ai-bot-sandbox.html, for testing the bot without a
// real Facebook conversation - e.g. while Meta messaging is restricted/under app review). This
// file's own job is everything Facebook-specific: webhook verification, signature checking,
// loading/saving the REAL ChatbotMessages/ChatbotConversations history, and actually sending
// replies via the Messenger Send API.
//
// Secrets (set via `supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   FACEBOOK_PAGE_ACCESS_TOKEN   - Messenger > Settings > Access Tokens, for the NEW page
//   FACEBOOK_APP_SECRET          - App Settings > Basic - used ONLY to verify X-Hub-Signature-256,
//                                   never sent anywhere
//   FACEBOOK_VERIFY_TOKEN        - any random string you choose, used only for the GET handshake
//   ANTHROPIC_API_KEY            - Claude API key
//   CLAUDE_MODEL                 - optional, defaults to claude-sonnet-5 below - override to swap
//                                   models (e.g. claude-haiku-4-5) without a redeploy
//   FACEBOOK_GRAPH_API_VERSION   - optional, defaults to v21.0 below
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected by Supabase for every Edge Function.
// Deploy: supabase functions deploy facebook-messenger-webhook --project-ref hymcmesqgpliyyeghpgq
//
// Data model: see sql/supabase_chatbot_conversations_tables.sql (ChatbotConversations/
// ChatbotMessages), sql/supabase_chatbot_store_info_table.sql (ChatbotStoreInfo), and
// sql/supabase_chatbot_search_items_rpc.sql (public_search_items). Order-status lookups reuse
// the existing public_get_automated_order_status RPC (sql/supabase_automated_order_async_pancake_sync.sql)
// as-is - this page's PSIDs have no relationship to that RPC's OrderNo values, so the bot always
// asks the customer for their order number rather than trying to look one up by PSID/phone.
//
// Proactive follow-ups: see sql/supabase_chatbot_followup_settings.sql (on/off + delay knobs,
// portal-editable from AI Bot Setup) and sql/supabase_chatbot_followups.sql (the ChatbotFollowUps
// queue + detection columns). This file only ever REACTS to an inbound Messenger message; actually
// sending a follow-up is supabase/functions/chatbot-followup-dispatcher's job, run on a pg_cron
// timer. This file's role in the feature is: (1) track LastCustomerMessageAtUtc/LastBotMessageAtUtc/
// AbandonedNudgeSentAtUtc/EscalatedAtUtc so the dispatcher can detect an abandoned or escalated
// conversation, and (2) the schedule_follow_up tool, letting the bot itself queue a follow-up the
// moment it promises a customer a callback.
//
// Always acks Facebook with 200 once the request's signature checks out, even if something later
// fails internally (logged via console.error) - a non-200 makes Facebook redeliver the same event,
// and a retry storm on a genuinely broken message is worse than silently dropping it. Dedup on
// Facebook's message id (ChatbotMessages.FacebookMessageId's unique index) covers the redelivery
// case for messages that DID succeed the first time.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { DEFAULT_GRAPH_VERSION, buildCurrentTimeLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

const DEFAULT_MODEL = 'claude-sonnet-5';
const HISTORY_LIMIT = 20;
const RATE_LIMIT_WINDOW_MINUTES = 5;
const RATE_LIMIT_MAX_MESSAGES = 15;
// Small pause before sending the reply so the bot doesn't feel instant/robotic, and so replies
// aren't fired at Meta back-to-back-to-back during a burst of customer messages.
const REPLY_DELAY_MS = 2000;
// Both store branches (Amaya/GMA) are in the Philippines - hardcoded rather than a settings-page
// field since there's no multi-timezone need today; change this constant if that ever changes.
const STORE_TIMEZONE = 'Asia/Manila';

interface FacebookAttachment {
  type?: string;
  payload?: { url?: string };
}

interface FacebookWebhookBody {
  entry?: Array<{
    messaging?: Array<{
      sender?: { id: string };
      recipient?: { id: string };
      message?: { mid: string; text?: string; is_echo?: boolean; attachments?: FacebookAttachment[] };
    }>;
  }>;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey('raw', encoder.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(message));
  return Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// Facebook's signature is a fixed-length "sha256=<64 hex chars>" string in both the header and our
// computed value, so a length check before the constant-time loop leaks nothing an attacker doesn't
// already know from the wire format.
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

function handleGet(req: Request): Response {
  const url = new URL(req.url);
  const mode = url.searchParams.get('hub.mode');
  const token = url.searchParams.get('hub.verify_token');
  const challenge = url.searchParams.get('hub.challenge');
  const verifyToken = Deno.env.get('FACEBOOK_VERIFY_TOKEN');

  if (mode === 'subscribe' && verifyToken && token === verifyToken) {
    // Meta expects the raw challenge value back as plain text, not JSON.
    return new Response(challenge ?? '', { status: 200 });
  }
  return new Response('Forbidden', { status: 403 });
}

async function sendMessengerReply(psid: string, text: string, pageAccessToken: string, graphVersion: string): Promise<void> {
  const url = `https://graph.facebook.com/${graphVersion}/me/messages?access_token=${pageAccessToken}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    // messaging_type RESPONSE is correct here - this always replies within the standard 24h window
    // to a customer-initiated message, so no message tag is needed.
    body: JSON.stringify({ recipient: { id: psid }, message: { text }, messaging_type: 'RESPONSE' })
  });
  if (!res.ok) {
    console.error(`Messenger Send API failed (${res.status}): ${await res.text()}`);
  }
}

// User Profile API lookup - Facebook's webhook payload never includes the sender's name, only
// their Psid, so this is the only way to get it. Best-effort: swallows any failure (missing
// permission, deactivated profile, transient error) and just leaves CustomerName null rather than
// blocking the reply - the next inbound message tries again since the caller only calls this when
// CustomerName is still unset.
async function fetchFacebookProfileName(psid: string, pageAccessToken: string, graphVersion: string): Promise<string | null> {
  try {
    const url = `https://graph.facebook.com/${graphVersion}/${psid}?fields=first_name,last_name&access_token=${pageAccessToken}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const body = await res.json();
    const name = [body.first_name, body.last_name].filter(Boolean).join(' ').trim();
    return name || null;
  } catch (err) {
    console.error('Failed to fetch Facebook profile name:', err instanceof Error ? err.message : err);
    return null;
  }
}

// Downloads an inbound image attachment (e.g. a GCash payment screenshot) and re-hosts it in our
// own private 'chatbot-attachments' Storage bucket (see sql/supabase_chatbot_message_attachments.
// sql), rather than just keeping Facebook's own CDN url - that url isn't guaranteed to stay valid
// indefinitely, and the GMA Conversations inbox needs something durable to display. Only ever
// called for type:'image' attachments (video/audio/file/location are left alone entirely - still
// "out of v1 scope", same cut as before this existed). Best-effort: any failure here just means
// the attachment is dropped (falls back to text-only handling, or the whole event is dropped if
// there was no text either) - never blocks the rest of message processing.
async function storeChatbotAttachment(supabase: SupabaseClient, psid: string, sourceUrl: string): Promise<{ path: string; signedUrl: string; base64: string; contentType: string } | null> {
  try {
    const res = await fetch(sourceUrl);
    if (!res.ok) return null;

    const contentType = res.headers.get('content-type') || 'image/jpeg';
    const ext = contentType.includes('png') ? 'png' : contentType.includes('webp') ? 'webp' : contentType.includes('gif') ? 'gif' : 'jpg';
    const bytes = new Uint8Array(await res.arrayBuffer());
    const path = `${psid}/${Date.now()}.${ext}`;

    const { error: uploadError } = await supabase.storage
      .from('chatbot-attachments')
      .upload(path, bytes, { contentType, upsert: false });
    if (uploadError) {
      console.error('Failed to upload chatbot attachment:', uploadError.message);
      return null;
    }

    // 60-day expiry to match ChatbotMessages' own retention window (cron_cleanup_old_chatbot_
    // messages deletes both the row and the Storage object well before this URL would expire).
    const { data: signedData, error: signError } = await supabase.storage
      .from('chatbot-attachments')
      .createSignedUrl(path, 60 * 60 * 24 * 60);
    if (signError || !signedData?.signedUrl) {
      console.error('Failed to sign chatbot attachment URL:', signError?.message);
      return null;
    }

    // base64-encode the bytes we already have in memory, so extractPaymentDetails (below) can hand
    // this straight to Claude's vision input without re-downloading the image from Facebook's CDN a
    // second time. Chunked to stay under String.fromCharCode's argument-count limit on large images.
    let binary = '';
    const chunkSize = 8192;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    const base64 = btoa(binary);

    return { path, signedUrl: signedData.signedUrl, base64, contentType };
  } catch (err) {
    console.error('Failed to store chatbot attachment:', err instanceof Error ? err.message : err);
    return null;
  }
}

interface DetectedPayment {
  amount: number | null;
  method: string | null;
  reference: string | null;
  senderName: string | null;
}

// Vision pass over a stored image attachment: is this a payment screenshot (GCash/Maya/bank
// transfer receipt) the customer sent, and if so what does it say? Purely a SUGGESTION surfaced to
// staff in the GMA Conversations inbox (a "Use in Add Payment" button that pre-fills the existing
// Add Payment form, admin_add_automated_order_payment) - never posted as a real payment
// automatically, since a misread amount or reference would corrupt an actual money record. Best-
// effort: any failure (bad JSON, API error, low confidence) just means no suggestion is shown - the
// photo itself is still saved and visible either way.
async function extractPaymentDetails(anthropic: Anthropic, model: string, base64: string, contentType: string): Promise<DetectedPayment | null> {
  try {
    const mediaType = (contentType.includes('png') ? 'image/png' : contentType.includes('webp') ? 'image/webp' : contentType.includes('gif') ? 'image/gif' : 'image/jpeg') as
      | 'image/jpeg'
      | 'image/png'
      | 'image/gif'
      | 'image/webp';

    const res = await anthropic.messages.create({
      model,
      max_tokens: 300,
      temperature: 0,
      system:
        'You look at a single photo a customer sent to a pet store\'s Messenger chat and decide if it is a payment screenshot (e.g. GCash, Maya/PayMaya, bank transfer, or similar receipt/confirmation screen). Respond with ONLY a JSON object, no markdown code fences, no other text, in exactly this shape: {"is_payment_screenshot": boolean, "amount": number or null, "reference": string or null, "method": string or null, "sender_name": string or null}. "method" must be one of "GCash", "Maya", "Bank Transfer", "Other", or null. If the image is not a payment screenshot, or you are not reasonably confident, set is_payment_screenshot to false and leave the other fields null.',
      messages: [
        {
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mediaType, data: base64 } },
            { type: 'text', text: 'Is this a payment screenshot? Extract the details as instructed.' }
          ]
        }
      ]
    });

    const block = res.content.find((b) => b.type === 'text');
    if (!block || block.type !== 'text') return null;

    const cleaned = block.text.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();
    const parsed = JSON.parse(cleaned);
    if (!parsed?.is_payment_screenshot) return null;

    const amount = typeof parsed.amount === 'number' && Number.isFinite(parsed.amount) ? parsed.amount : null;
    return {
      amount,
      method: typeof parsed.method === 'string' ? parsed.method : null,
      reference: typeof parsed.reference === 'string' ? parsed.reference : null,
      senderName: typeof parsed.sender_name === 'string' ? parsed.sender_name : null
    };
  } catch (err) {
    console.error('Failed to extract payment details from attachment:', err instanceof Error ? err.message : err);
    return null;
  }
}

// Live-updates docs/gma-conversations.html (the GMA Conversations inbox) without polling - fired
// after every ChatbotMessages insert (inbound customer message, bot reply, or a staff reply via
// chatbot-staff-reply) so any open browser tab refreshes instantly. Broadcast, not postgres_changes
// - ChatbotConversations/ChatbotMessages have zero anon RLS policies (this app uses its own staff
// username/password auth, not Supabase Auth, so everything else goes through is_admin_authorized-
// gated RPCs instead of direct table reads), and a postgres_changes subscription is gated by that
// same RLS - it would just never fire. Broadcast sidesteps that: it's channel-based, not
// table-read-based, so the service-role client here can freely push into the same channel name the
// browser subscribes to. Mirrors docs/js/chat.js's chatInboxBroadcast - the only other place in
// this codebase already doing Realtime Broadcast - which found the same thing: send() only works
// once the channel is actually SUBSCRIBED, so this subscribes, sends, and tears down every call
// rather than holding a channel open across invocations (this function runs fresh per request).
// Best-effort: never lets a broadcast failure affect the real work (message already saved either
// way) - a missed live-update just means staff sees it on their next manual Refresh instead.
async function broadcastGmaEvent(supabase: SupabaseClient, psid: string): Promise<void> {
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

async function isRateLimited(supabase: SupabaseClient, psid: string): Promise<boolean> {
  const windowStart = new Date(Date.now() - RATE_LIMIT_WINDOW_MINUTES * 60 * 1000).toISOString();
  const { count } = await supabase
    .from('ChatbotMessages')
    .select('Id', { count: 'exact', head: true })
    .eq('Psid', psid)
    .eq('Role', 'user')
    .gte('CreatedAtUtc', windowStart);
  return (count ?? 0) >= RATE_LIMIT_MAX_MESSAGES;
}

async function processMessage(
  supabase: SupabaseClient,
  anthropic: Anthropic,
  model: string,
  pageAccessToken: string,
  graphVersion: string,
  pageId: string,
  psid: string,
  text: string | undefined,
  mid: string,
  attachments: FacebookAttachment[] | undefined
): Promise<void> {
  // Insert-if-missing only - LastMessageAtUtc/Status are updated below, never overwritten here.
  await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: pageId }, { onConflict: 'Psid', ignoreDuplicates: true });

  // Only the FIRST image attachment is stored - Facebook's FacebookMessageId unique index only
  // allows one ChatbotMessages row per mid, so multiple attachments on one event can't each get
  // their own row without violating that constraint. In practice a customer sending several
  // photos almost always does so as separate messages/events (each with its own mid) anyway, so
  // this only ever discards anything in the rare multi-attachment-in-one-event case.
  const imageAttachment = attachments?.find((a) => a.type === 'image' && a.payload?.url);
  let attachmentPath: string | null = null;
  let attachmentUrl: string | null = null;
  let attachmentType: string | null = null;
  let detectedPayment: DetectedPayment | null = null;

  if (imageAttachment?.payload?.url) {
    const stored = await storeChatbotAttachment(supabase, psid, imageAttachment.payload.url);
    if (stored) {
      attachmentPath = stored.path;
      attachmentUrl = stored.signedUrl;
      attachmentType = 'image';
      detectedPayment = await extractPaymentDetails(anthropic, model, stored.base64, stored.contentType);
    }
  }

  const trimmedText = text?.trim() || '';
  // A stored photo with no caption still needs SOME Content (ChatbotMessages.Content is NOT
  // NULL) - a placeholder that reads sensibly in the GMA inbox thread even without the actual
  // image rendering (e.g. if AttachmentUrl ever fails to load).
  const messageContent = trimmedText || (attachmentUrl ? '[Photo]' : '');
  if (!messageContent) return; // no text and no attachment we could store - nothing to record

  const { error: insertErr } = await supabase
    .from('ChatbotMessages')
    .insert({
      Psid: psid,
      Role: 'user',
      Content: messageContent,
      FacebookMessageId: mid,
      AttachmentPath: attachmentPath,
      AttachmentUrl: attachmentUrl,
      AttachmentType: attachmentType,
      DetectedPaymentAmount: detectedPayment?.amount ?? null,
      DetectedPaymentMethod: detectedPayment?.method ?? null,
      DetectedPaymentReference: detectedPayment?.reference ?? null,
      DetectedPaymentSenderName: detectedPayment?.senderName ?? null
    });
  if (insertErr) {
    if (insertErr.code === '23505') return; // Facebook redelivered a message we already processed.
    console.error('Failed to record inbound chatbot message:', insertErr.message);
  }

  await broadcastGmaEvent(supabase, psid);

  // A fresh inbound message means any prior idle stretch is over - clears AbandonedNudgeSentAtUtc
  // so chatbot-followup-dispatcher can detect the *next* idle stretch, if there is one.
  await supabase
    .from('ChatbotConversations')
    .update({ LastCustomerMessageAtUtc: new Date().toISOString(), AbandonedNudgeSentAtUtc: null })
    .eq('Psid', psid);

  // Staff-controlled pause (docs/gma-conversations.html, set via admin_set_chatbot_conversation_paused
  // - see supabase_chatbot_conversations_admin_inbox.sql) - independent of Status/Escalated, which
  // never silences the bot on its own per direct confirmation. The message above is still recorded
  // and LastCustomerMessageAtUtc still updates, so a paused conversation stays visible/current in
  // the inbox - only the auto-reply itself is skipped, so staff can answer manually on Messenger.
  const { data: convState } = await supabase.from('ChatbotConversations').select('IsPaused, CustomerName').eq('Psid', psid).maybeSingle();

  // Backfills CustomerName for both brand-new conversations and older ones that predate this
  // column - runs regardless of pause state so a paused conversation still gets a name attached.
  if (!convState?.CustomerName) {
    const fetchedName = await fetchFacebookProfileName(psid, pageAccessToken, graphVersion);
    if (fetchedName) {
      await supabase.from('ChatbotConversations').update({ CustomerName: fetchedName }).eq('Psid', psid);
    }
  }

  if (convState?.IsPaused) return;

  // A photo with no caption has nothing for Claude to meaningfully respond to (no product/order
  // question to answer) - acknowledge it and hand off to staff (who can see it inline in the GMA
  // Conversations inbox, e.g. to verify a GCash payment screenshot) rather than running a full AI
  // turn over a placeholder "[Photo]" prompt.
  if (!trimmedText && attachmentUrl) {
    const ack = detectedPayment?.amount != null
      ? `Thanks for the payment screenshot! I see an amount of ₱${detectedPayment.amount.toFixed(2)}${detectedPayment.reference ? ` (Ref: ${detectedPayment.reference})` : ''} - our team will confirm and log it shortly. \u{1F60A}`
      : "Thanks for sending that! Someone from our team will take a look and follow up if needed. \u{1F60A}";
    await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: ack });
    await supabase
      .from('ChatbotConversations')
      .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
      .eq('Psid', psid);
    await broadcastGmaEvent(supabase, psid);
    await new Promise((resolve) => setTimeout(resolve, REPLY_DELAY_MS));
    await sendMessengerReply(psid, ack, pageAccessToken, graphVersion);
    return;
  }

  if (await isRateLimited(supabase, psid)) {
    await sendMessengerReply(psid, "You're sending messages a bit fast - give me a moment to catch up!", pageAccessToken, graphVersion);
    return;
  }

  const { data: historyRows } = await supabase
    .from('ChatbotMessages')
    .select('Role, Content')
    .eq('Psid', psid)
    .order('CreatedAtUtc', { ascending: false })
    .limit(HISTORY_LIMIT);

  // 'staff' rows (a human's manual reply from docs/gma-conversations.html - see
  // supabase_chatbot_staff_reply.sql) map to 'assistant' here - Claude's Messages API only accepts
  // 'user'/'assistant' roles, and a staff reply plays the same conversational turn as a bot reply
  // from the model's perspective. The DB keeps the real 'staff' value (for the inbox UI's own
  // labeling/coloring) - only this Claude-facing mapping collapses the two.
  const messages: Anthropic.MessageParam[] = (historyRows ?? [])
    .reverse()
    .map((row: { Role: string; Content: string }) => ({ role: row.Role === 'user' ? 'user' : 'assistant', content: row.Content }));

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettings }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  // Not type-annotated as Anthropic.TextBlockParam[] - structural typing against
  // MessageCreateParams['system'] is enough, and avoids depending on an unverified type name.
  // Two blocks: the large static persona/rules/store-info text is cached (changes only when
  // settings are edited), while the current date/time is appended uncached after it since it's
  // different on every request - keeping it out of the cached block preserves the cache hit rate
  // for everything else.
  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) }
  ];

  // AiSettings.AiModel (portal-editable, see ai-bot-setup.html) overrides the env/default model
  // when set, so the store owner can switch models without a code deploy.
  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;

  const finalText = await runChatbotTurn({
    supabase,
    anthropic,
    model: effectiveModel,
    psid,
    messages,
    followUpSettings,
    systemBlocks,
    simulate: false,
    pageAccessToken,
    graphVersion
  });

  await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: finalText });
  await supabase
    .from('ChatbotConversations')
    .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
    .eq('Psid', psid);
  await broadcastGmaEvent(supabase, psid);

  await new Promise((resolve) => setTimeout(resolve, REPLY_DELAY_MS));
  await sendMessengerReply(psid, finalText, pageAccessToken, graphVersion);
}

async function handlePost(req: Request): Promise<Response> {
  const appSecret = Deno.env.get('FACEBOOK_APP_SECRET');
  const pageAccessToken = Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;

  if (!appSecret || !pageAccessToken || !anthropicApiKey || !supabaseUrl || !serviceRoleKey) {
    console.error('facebook-messenger-webhook is missing one or more required secrets.');
    // Still ack Facebook - a misconfigured server is nothing a retry will fix.
    return jsonResponse({ received: true });
  }

  // Must read the body as text (for signature verification) BEFORE any JSON parsing.
  const rawBody = await req.text();
  const signatureHeader = req.headers.get('x-hub-signature-256') || '';
  const expectedSignature = 'sha256=' + (await hmacSha256Hex(appSecret, rawBody));
  if (!constantTimeEqual(signatureHeader, expectedSignature)) {
    return new Response('Forbidden', { status: 403 });
  }

  let body: FacebookWebhookBody;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return jsonResponse({ received: true });
  }

  try {
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const anthropic = new Anthropic({ apiKey: anthropicApiKey });

    for (const entry of body.entry ?? []) {
      for (const evt of entry.messaging ?? []) {
        if (evt.message?.is_echo) continue; // the page's own message, echoed back - skip to avoid a reply loop
        const text = evt.message?.text;
        const attachments = evt.message?.attachments;
        const psid = evt.sender?.id;
        const pageId = evt.recipient?.id;
        const mid = evt.message?.mid;
        // A message needs text AND/OR an image attachment to be worth processing - read receipts,
        // postbacks, and non-image attachments (video/audio/file/location) are still out of scope.
        if ((!text && !(attachments && attachments.length > 0)) || !psid || !pageId || !mid) continue;

        try {
          await processMessage(supabase, anthropic, model, pageAccessToken, graphVersion, pageId, psid, text, mid, attachments);
        } catch (err) {
          console.error('Error processing Messenger event:', err instanceof Error ? err.message : err);
        }
      }
    }
  } catch (err) {
    console.error('Unhandled error in facebook-messenger-webhook:', err instanceof Error ? err.message : err);
  }

  return jsonResponse({ received: true });
}

Deno.serve(async (req) => {
  if (req.method === 'GET') return handleGet(req);
  if (req.method === 'POST') return await handlePost(req);
  return jsonResponse({ error: 'Use GET (webhook verification) or POST (webhook events).' }, 405);
});
