// Lets staff talk to Alice (the AI bot) directly inside the existing Messenger-style Portal Chat
// widget (docs/js/chat.js, schema in supabase_portal_chat_tables.sql /
// supabase_portal_chat_groups_and_alice.sql) - per direct request "i want alice and the GC to live
// only in the portal" (no external Telegram app - see supabase_telegram_alice_messages.sql /
// telegram-alice-webhook, which stays deployed but unused/dormant now that this is the chosen
// path). Alice is a normal StaffUsers row (Username 'alice') that can be DM'd or added to a group
// like any other contact; this function is what actually generates her replies once the widget
// decides a message should trigger one (DM with her -> always; group she's a member of -> only
// when "@Alice" is mentioned - the widget checks this client-side before calling, and this function
// re-checks it server-side too so a stray call can't make her reply somewhere she isn't actually a
// member, or reply to ordinary group chatter she wasn't mentioned in).
//
// Runs the shared engine (supabase/functions/_shared/chatbot-engine.ts) in `simulate: true` mode -
// same safety net as the AI Bot Sandbox (docs/ai-bot-sandbox.html) - so nothing said to her here
// creates a real order, saves a real CRM record, or sends a real customer-facing escalation.
//
// Deploy: supabase functions deploy portal-chat-alice-reply --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { buildCurrentTimeLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

const DEFAULT_MODEL = 'claude-sonnet-5';
const HISTORY_LIMIT = 20;
const STORE_TIMEZONE = 'Asia/Manila';
const ALICE_USERNAME = 'alice';
const ALICE_MENTION_RE = /@alice\b/i;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
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
    return jsonResponse({ error: 'portal-chat-alice-reply is missing one or more required secrets.' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let conversationId: string;
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    conversationId = String(body.conversation_id ?? '');
    if (!adminUsername || !adminPassword || !conversationId) {
      throw new Error('missing field');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, conversation_id }.' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { data: authorized, error: authError } = await supabase.rpc('is_staff_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) {
    return jsonResponse({ error: 'Not authorized.' }, 401);
  }

  const { data: conversation, error: convError } = await supabase
    .from('ChatConversations')
    .select('ConversationID, IsGroup')
    .eq('ConversationID', conversationId)
    .maybeSingle();
  if (convError || !conversation) {
    return jsonResponse({ error: 'Conversation not found.' }, 404);
  }

  const { data: memberRows, error: memberError } = await supabase
    .from('ChatConversationMembers')
    .select('Username')
    .eq('ConversationID', conversationId);
  if (memberError) {
    return jsonResponse({ error: memberError.message }, 500);
  }
  const memberUsernames = (memberRows ?? []).map((m: { Username: string }) => m.Username);
  if (!memberUsernames.includes(adminUsername)) {
    return jsonResponse({ error: 'Not a member of this conversation.' }, 403);
  }
  if (!memberUsernames.includes(ALICE_USERNAME)) {
    return jsonResponse({ ok: true, reply: null }); // Alice isn't in this conversation - quietly no-op
  }

  // Per direct request: only super users can DM Alice 1:1 - any staff can still @mention her
  // inside a group. get_or_create_dm_conversation (supabase_portal_chat_tables.sql) has no
  // password/identity check at all (same "anon full access" trust tier as the rest of that
  // schema), so it can't be the enforcement point - this IS, since it already re-verifies
  // adminUsername/adminPassword above before ever getting here.
  if (!conversation.IsGroup) {
    const { data: isSuperUser } = await supabase.rpc('is_admin_authorized', {
      p_username: adminUsername,
      p_password: adminPassword
    });
    if (!isSuperUser) {
      return jsonResponse({ ok: true, reply: null });
    }
  }

  const { data: historyRows, error: historyError } = await supabase
    .from('ChatMessages')
    .select('SenderUsername, Body, CreatedAtUtc')
    .eq('ConversationID', conversationId)
    .order('CreatedAtUtc', { ascending: false })
    .limit(HISTORY_LIMIT);
  if (historyError) {
    return jsonResponse({ error: historyError.message }, 500);
  }

  const orderedHistory = (historyRows ?? []).slice().reverse() as Array<{ SenderUsername: string; Body: string; CreatedAtUtc: string }>;
  const latestMessage = orderedHistory[orderedHistory.length - 1];

  // Server-side re-check, independent of what the widget decided client-side: a group only ever
  // gets a reply when the LATEST message actually mentions Alice - never for ordinary back-and-forth
  // between staff, even if she's a member. A 1:1 DM with her always replies.
  if (conversation.IsGroup) {
    if (!latestMessage || latestMessage.SenderUsername === ALICE_USERNAME || !ALICE_MENTION_RE.test(latestMessage.Body)) {
      return jsonResponse({ ok: true, reply: null });
    }
  }

  const staffUsernames = Array.from(new Set(orderedHistory.map((m) => m.SenderUsername).filter((u) => u !== ALICE_USERNAME)));
  const { data: staffRows } = staffUsernames.length
    ? await supabase.from('StaffUsers').select('Username, DisplayName').in('Username', staffUsernames)
    : { data: [] as Array<{ Username: string; DisplayName: string | null }> };
  const displayNameByUsername = new Map((staffRows ?? []).map((s: { Username: string; DisplayName: string | null }) => [s.Username, s.DisplayName || s.Username]));

  const isGroup = Boolean(conversation.IsGroup);
  const messages: Anthropic.MessageParam[] = orderedHistory.map((row) => {
    const isAlice = row.SenderUsername === ALICE_USERNAME;
    const senderLabel = displayNameByUsername.get(row.SenderUsername) || row.SenderUsername;
    return {
      role: isAlice ? 'assistant' : 'user',
      // In a group with multiple humans, prefix who said it so Alice can tell speakers apart - a
      // 1:1 DM only ever has one other speaker, so the prefix would just be noise there.
      content: !isAlice && isGroup ? `${senderLabel}: ${row.Body}` : row.Body
    };
  });

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettings }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    {
      type: 'text' as const,
      text: `INTERNAL PORTAL TEAM CHAT: you are talking with RS Pet Stop's own staff inside their internal Portal Chat, not a customer.${isGroup ? ' Multiple staff members may be in this conversation - each user message is prefixed with "Name: " so you know who is asking.' : ''} Keep answers short and direct like a quick chat reply, not a full customer-facing script. This is for internal reference/testing only, so no order, escalation, or CRM save you take here is real - it is simulated.`
    }
  ];

  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;
  const anthropic = new Anthropic({ apiKey: anthropicApiKey });

  let finalText: string;
  try {
    finalText = await runChatbotTurn({
      supabase,
      anthropic,
      model: effectiveModel,
      psid: `portal-chat:${conversationId}`,
      messages,
      followUpSettings,
      aiSettings,
      systemBlocks,
      simulate: true
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : 'The bot failed to respond.' }, 500);
  }

  const { error: insertErr } = await supabase
    .from('ChatMessages')
    .insert({ ConversationID: conversationId, SenderUsername: ALICE_USERNAME, Body: finalText });
  if (insertErr) {
    return jsonResponse({ error: `Alice replied but the message could not be saved: ${insertErr.message}` }, 500);
  }

  return jsonResponse({ ok: true, reply: finalText });
});
