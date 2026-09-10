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

interface FacebookWebhookBody {
  entry?: Array<{
    messaging?: Array<{
      sender?: { id: string };
      recipient?: { id: string };
      message?: { mid: string; text?: string; is_echo?: boolean };
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
  text: string,
  mid: string
): Promise<void> {
  // Insert-if-missing only - LastMessageAtUtc/Status are updated below, never overwritten here.
  await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: pageId }, { onConflict: 'Psid', ignoreDuplicates: true });

  const { error: insertErr } = await supabase
    .from('ChatbotMessages')
    .insert({ Psid: psid, Role: 'user', Content: text, FacebookMessageId: mid });
  if (insertErr) {
    if (insertErr.code === '23505') return; // Facebook redelivered a message we already processed.
    console.error('Failed to record inbound chatbot message:', insertErr.message);
  }

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
  const { data: pauseCheck } = await supabase.from('ChatbotConversations').select('IsPaused').eq('Psid', psid).maybeSingle();
  if (pauseCheck?.IsPaused) return;

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
        const psid = evt.sender?.id;
        const pageId = evt.recipient?.id;
        const mid = evt.message?.mid;
        if (!text || !psid || !pageId || !mid) continue; // read receipts, postbacks, attachments - out of v1 scope

        try {
          await processMessage(supabase, anthropic, model, pageAccessToken, graphVersion, pageId, psid, text, mid);
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
