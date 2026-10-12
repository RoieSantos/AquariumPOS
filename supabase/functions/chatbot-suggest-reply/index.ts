// "Advise reply" on the GMA Conversations page (docs/gma-conversations.html): drafts the best next
// reply for STAFF to review, edit and send themselves - it never sends anything to the customer and
// never writes to ChatbotMessages. The draft is dropped into the reply box (docs/js/
// gmaConversations.js, adviseReply); staff press Enter to send it through chatbot-staff-reply as usual.
//
// Same Alice brain as the live bot (buildSystemPrompt/runChatbotTurn from _shared/chatbot-engine.ts)
// so the tone/rules/prices match, but run with simulate: true AND only READ_ONLY_TOOL_NAMES - it can
// look up real prices/stock/quotes to put in the draft, but can't create orders, escalate, schedule
// follow-ups or send photos. If staff typed something in the reply box first, it's passed as
// `instruction` (e.g. "politely say no to the discount") and the draft follows it.
//
// Body: { admin_username, admin_password, psid, instruction? } -> { suggestion }
// Auth: is_conversations_authorized (same staff who can open GMA Conversations).
// Deploy: supabase functions deploy chatbot-suggest-reply --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { READ_ONLY_TOOL_NAMES, buildCurrentTimeLine, buildFacebookPageLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

const DEFAULT_MODEL = 'claude-sonnet-5';
const HISTORY_LIMIT = 30;
const STORE_TIMEZONE = 'Asia/Manila';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

const ADVISE_MODE_RULES = [
  'STAFF DRAFT MODE - you are NOT talking to the customer right now. A store staff member is handling this Messenger conversation by hand and asked you to draft the best possible next reply for them to review, edit and send themselves.',
  '- Write ONLY the message text the staff member would send to the customer - no preamble ("Here\'s a draft:"), no notes to staff, no quotation marks around it, no options/alternatives.',
  '- Read the whole conversation, including what staff ("assistant" turns) already said, and reply to what the customer most recently needs. Don\'t repeat information already given unless it helps.',
  '- Same tone, language (English/Tagalog/Taglish - match the customer) and store rules as always. Look up real prices/stock/quotes with your tools when the reply needs them - never guess.',
  '- Write it as the store, not as an AI: don\'t introduce yourself or mention being a bot.',
  '- You can\'t place orders, escalate, schedule follow-ups or send photos from here - if the reply needs one of those, just write the message and staff will handle the action.'
].join('\n');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!supabaseUrl || !serviceRoleKey || !anthropicApiKey) {
    return jsonResponse({ error: 'chatbot-suggest-reply is missing one or more required secrets.' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let psid: string;
  let instruction: string;
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    psid = String(body.psid ?? '');
    instruction = String(body.instruction ?? '').trim().slice(0, 1000);
    if (!adminUsername || !adminPassword || !psid) throw new Error('missing field');
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, psid, instruction? }.' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { data: authorized, error: authError } = await supabase.rpc('is_conversations_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || authorized !== true) return jsonResponse({ error: 'Not authorized.' }, 403);

  const [{ data: conv }, { data: historyRows }] = await Promise.all([
    supabase.from('ChatbotConversations').select('PageId, CustomerName').eq('Psid', psid).maybeSingle(),
    supabase.from('ChatbotMessages').select('Role, Content').eq('Psid', psid).order('CreatedAtUtc', { ascending: false }).limit(HISTORY_LIMIT)
  ]);
  if (!conv) return jsonResponse({ error: 'Conversation not found.' }, 404);

  // Same Claude-facing mapping as facebook-messenger-webhook: staff + bot rows are both 'assistant'.
  const messages: Anthropic.MessageParam[] = (historyRows ?? [])
    .reverse()
    .filter((row: { Content: string | null }) => (row.Content ?? '').trim())
    .map((row: { Role: string; Content: string }) => ({ role: row.Role === 'user' ? 'user' : 'assistant', content: row.Content }));
  // The cut-off history window can start mid-conversation on a staff/bot turn - start on the customer's.
  while (messages.length > 0 && messages[0].role !== 'user') messages.shift();
  if (messages.length === 0) return jsonResponse({ error: 'This conversation has no messages yet.' }, 400);

  // The request to draft goes in as the final 'user' turn (the API needs the conversation to end on
  // one) - merged into the customer's last message when they spoke last, so turns still alternate.
  const request = `[STAFF REQUEST - not from the customer] Draft the next reply to send to the customer.${instruction ? ` Staff's guidance for this reply: ${instruction}` : ''}`;
  const last = messages[messages.length - 1];
  if (last.role === 'user' && typeof last.content === 'string') {
    last.content = `${last.content}\n\n${request}`;
  } else {
    messages.push({ role: 'user', content: request });
  }

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettings }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  const customerName = (conv.CustomerName as string | null)?.trim();
  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: ADVISE_MODE_RULES },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    { type: 'text' as const, text: customerName ? `The customer's name is ${customerName}.` : 'The customer\'s name is not known.' },
    ...(conv.PageId ? [{ type: 'text' as const, text: buildFacebookPageLine(conv.PageId as string) }] : [])
  ];

  const model = (aiSettings?.AiModel as string | undefined)?.trim() || Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;

  try {
    const suggestion = await runChatbotTurn({
      supabase,
      anthropic: new Anthropic({ apiKey: anthropicApiKey }),
      model,
      psid,
      pageId: (conv.PageId as string | null) ?? undefined,
      messages,
      followUpSettings,
      aiSettings,
      systemBlocks,
      simulate: true,
      allowedToolNames: READ_ONLY_TOOL_NAMES
    });
    return jsonResponse({ suggestion: suggestion.trim() });
  } catch (err) {
    console.error('chatbot-suggest-reply failed:', err instanceof Error ? err.message : err);
    return jsonResponse({ error: 'Could not get a suggestion right now - try again.' }, 502);
  }
});
