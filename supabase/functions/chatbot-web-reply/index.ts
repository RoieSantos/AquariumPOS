// AI website chat widget ("Alice" - see docs/js/chatWidget.js) - a public, anonymous-callable
// twin of facebook-messenger-webhook for visitors chatting directly on rspetstop.com instead of
// Facebook Messenger. Reuses the EXACT same TOOLS/system prompt/tool-execution engine (see
// supabase/functions/_shared/chatbot-engine.ts) and, per direct decision, the SAME
// ChatbotConversations/ChatbotMessages tables the Facebook bot uses - a website visitor is keyed
// by a client-generated UUID stored in their browser (localStorage), namespaced as
// `web:<uuid>` so it can never collide with a real Facebook PSID. This is NOT simulate mode -
// escalate_to_staff (Telegram alert), save_customer_info, and create_order (real Pancake order)
// all run for real, exactly like a real Messenger conversation - only the difference is there's no
// Facebook Send API to push the reply through (the browser just reads it from this function's own
// response instead), so no pageAccessToken is ever passed to the shared engine here.
//
// Reusing the real tables (rather than a separate ChatbotWebMessages) means a website
// conversation shows up in the existing GMA Conversations staff inbox automatically, with zero
// extra work - it's just another conversation, tagged PageId 'website'. Two tools that assume a
// real Facebook conversation degrade gracefully rather than erroring for a web visitor:
// send_item_image silently no-ops (no pageAccessToken -> "Photo sending is not configured right
// now", so the model just describes the item in text instead) and schedule_follow_up still
// enqueues a real ChatbotFollowUps row - chatbot-followup-dispatcher's later attempt to push it
// through Facebook's Send API for a "web:" psid will fail (logged, not thrown), but it still
// stores the follow-up text in ChatbotMessages beforehand, so a visitor who reopens the same
// browser/session later sees it in their restored history anyway.
//
// BotName is intentionally NOT read from the shared ChatbotAiSettings.BotName the Facebook bot
// uses - per direct request ("name the BOT alice"), this channel always introduces itself as
// "Alice" without touching that shared setting (which would also rename the Facebook bot).
//
// Deploy: supabase functions deploy chatbot-web-reply --project-ref hymcmesqgpliyyeghpgq

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { buildCurrentTimeLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

const DEFAULT_MODEL = 'claude-sonnet-5';
const HISTORY_LIMIT = 20;
const HISTORY_FETCH_LIMIT = 60; // for action:'history' - restoring the widget's own display, not Claude's context
const STORE_TIMEZONE = 'Asia/Manila';
const WEB_PSID_PREFIX = 'web:';
const WEB_PAGE_ID = 'website';
const WEB_BOT_NAME = 'Alice';
const MAX_MESSAGE_LENGTH = 4000;
const RATE_LIMIT_WINDOW_MINUTES = 5;
const RATE_LIMIT_MAX_MESSAGES = 15; // same window/threshold as facebook-messenger-webhook

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

function buildCustomerNameLine(customerName: string | null | undefined): string {
  return customerName
    ? `CUSTOMER'S NAME: ${customerName}`
    : "CUSTOMER'S NAME: unknown - ask for a name if it becomes relevant (e.g. placing an order).";
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;

  if (!supabaseUrl || !serviceRoleKey || !anthropicApiKey) {
    return jsonResponse({ error: 'chatbot-web-reply is missing one or more required secrets.' }, 500);
  }

  let visitorId: string;
  let message: string;
  let action: string;
  try {
    const body = await req.json();
    visitorId = String(body.visitor_id ?? '');
    message = String(body.message ?? '').slice(0, MAX_MESSAGE_LENGTH);
    action = String(body.action ?? 'message');
    if (!UUID_RE.test(visitorId)) throw new Error('invalid visitor_id');
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { visitor_id: <uuid>, message } (or { visitor_id, action: "history" }).' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const psid = `${WEB_PSID_PREFIX}${visitorId}`;

  if (action === 'history') {
    const { data: rows } = await supabase
      .from('ChatbotMessages')
      .select('Role, Content, CreatedAtUtc')
      .eq('Psid', psid)
      .order('CreatedAtUtc', { ascending: true })
      .limit(HISTORY_FETCH_LIMIT);
    return jsonResponse({ ok: true, messages: rows ?? [] });
  }

  if (!message.trim()) {
    return jsonResponse({ error: 'message is required.' }, 400);
  }

  // Insert-if-missing only, exactly like facebook-messenger-webhook's own upsert - never
  // overwrites an existing row (e.g. a returning visitor whose conversation staff already touched).
  await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: WEB_PAGE_ID }, { onConflict: 'Psid', ignoreDuplicates: true });

  const { error: insertErr } = await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'user', Content: message.trim() });
  if (insertErr) {
    return jsonResponse({ error: `Could not record the message: ${insertErr.message}` }, 500);
  }

  await supabase
    .from('ChatbotConversations')
    .update({ LastCustomerMessageAtUtc: new Date().toISOString(), AbandonedNudgeSentAtUtc: null })
    .eq('Psid', psid);

  if (await isRateLimited(supabase, psid)) {
    const reply = "You're sending messages a bit fast - give me a moment to catch up!";
    await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: reply });
    return jsonResponse({ ok: true, reply });
  }

  const { data: convState } = await supabase.from('ChatbotConversations').select('IsPaused, CustomerName').eq('Psid', psid).maybeSingle();
  if (convState?.IsPaused) {
    // A staff member has taken over this conversation from the GMA Conversations portal - stay
    // quiet just like the Facebook bot does, so they can reply manually without the bot talking
    // over them. The visitor's message is still recorded above either way.
    return jsonResponse({ ok: true, reply: null, paused: true });
  }

  const { data: historyRows } = await supabase
    .from('ChatbotMessages')
    .select('Role, Content')
    .eq('Psid', psid)
    .order('CreatedAtUtc', { ascending: false })
    .limit(HISTORY_LIMIT);

  const messages: Anthropic.MessageParam[] = (historyRows ?? [])
    .reverse()
    .map((row: { Role: string; Content: string }) => ({ role: row.Role === 'user' ? 'user' : 'assistant', content: row.Content }));

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettingsRaw }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  // Real store settings/pricing/persona directions - only BotName is overridden (see header
  // comment), so "Alice" answers with the store's actual configured tone/rules.
  const aiSettings = aiSettingsRaw ? { ...aiSettingsRaw, BotName: WEB_BOT_NAME } : { BotName: WEB_BOT_NAME };

  // The BotName override above only covers the prompt's generic opening line - a store-configured
  // CustomDirections/CommunicationStyle (AI Bot Setup) can also give the bot a persona name (e.g.
  // "Vic") for the Facebook channel, which is more specific/later in the prompt and wins over that
  // opening line. This final, unambiguous override block is what actually makes the website
  // widget introduce itself as Alice regardless of what channel-specific persona name is set
  // elsewhere.
  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    { type: 'text' as const, text: buildCustomerNameLine(convState?.CustomerName as string | null | undefined) },
    { type: 'text' as const, text: `WEBSITE CHAT WIDGET OVERRIDE: on this specific channel (the website chat widget, not Facebook Messenger), your name is "${WEB_BOT_NAME}" - if asked your name, or when introducing yourself, always say ${WEB_BOT_NAME}. Ignore any other persona name given elsewhere in these instructions; that name applies only to other channels.` }
  ];

  const effectiveModel = (aiSettingsRaw?.AiModel as string | undefined)?.trim() || model;
  const anthropic = new Anthropic({ apiKey: anthropicApiKey });

  let finalText: string;
  try {
    finalText = await runChatbotTurn({
      supabase,
      anthropic,
      model: effectiveModel,
      psid,
      pageId: WEB_PAGE_ID,
      messages,
      followUpSettings,
      aiSettings,
      systemBlocks,
      simulate: false
      // No pageAccessToken/graphVersion - there is no Facebook conversation to send through here.
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : 'The bot failed to respond.' }, 500);
  }

  await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: finalText });
  await supabase
    .from('ChatbotConversations')
    .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
    .eq('Psid', psid);

  return jsonResponse({ ok: true, reply: finalText });
});
