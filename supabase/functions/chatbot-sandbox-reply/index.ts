// Runs one turn of the AI bot's actual conversational/tool-use logic against a portal-only test
// conversation - backs docs/ai-bot-sandbox.html, built per direct request to let staff test the
// bot without a real Facebook conversation (e.g. while Meta's messaging was temporarily
// restricting the real Page). Reuses the exact same TOOLS/system prompt/tool-execution code as
// facebook-messenger-webhook via supabase/functions/_shared/chatbot-engine.ts - the ONLY
// difference is `simulate: true`, which makes every side-effecting tool (escalate_to_staff,
// send_item_image, schedule_follow_up, schedule_delivery_date) skip its real action and describe
// what it WOULD have done instead (see that file's header comment) - per direct decision, so
// testers can safely use real order numbers without creating bogus DeliveryStops rows, spamming
// staff Telegram, or triggering a real Messenger send.
//
// Plain CORS-enabled endpoint, same reasoning as chatbot-staff-reply (no Facebook signature to
// verify here - this is a browser-originated staff test message, not a Facebook webhook event).
// Test history lives in its own ChatbotSandboxMessages table (supabase_chatbot_sandbox_tables.sql),
// one ongoing conversation per staff username - fully separate from the real ChatbotConversations/
// ChatbotMessages tables so a test message can never show up in the real customer inbox
// (docs/gma-conversations.html).
//
// Deploy: supabase functions deploy chatbot-sandbox-reply --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { buildCurrentTimeLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

const DEFAULT_MODEL = 'claude-sonnet-5';
const HISTORY_LIMIT = 20;
const STORE_TIMEZONE = 'Asia/Manila';
// A fake, obviously-non-Facebook psid - executeTool's read-only tools don't care what this value
// is (none of them look up anything by psid), and every side-effecting tool is always simulated
// here, so this is never actually used to reach a real Facebook user or a real ChatbotConversations
// row.
const SANDBOX_PSID_PREFIX = 'sandbox:';

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
    return jsonResponse({ error: 'chatbot-sandbox-reply is missing one or more required secrets.' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let message: string;
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    message = String(body.message ?? '');
    if (!adminUsername || !adminPassword || !message.trim()) {
      throw new Error('missing field');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, message }.' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) {
    return jsonResponse({ error: 'Not authorized.' }, 401);
  }

  const { error: insertErr } = await supabase
    .from('ChatbotSandboxMessages')
    .insert({ Username: adminUsername, Role: 'user', Content: message });
  if (insertErr) {
    return jsonResponse({ error: `Could not record the test message: ${insertErr.message}` }, 500);
  }

  const { data: historyRows } = await supabase
    .from('ChatbotSandboxMessages')
    .select('Role, Content')
    .eq('Username', adminUsername)
    .order('CreatedAtUtc', { ascending: false })
    .limit(HISTORY_LIMIT);

  const messages: Anthropic.MessageParam[] = (historyRows ?? [])
    .reverse()
    .map((row: { Role: string; Content: string }) => ({ role: row.Role === 'user' ? 'user' : 'assistant', content: row.Content }));

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettings }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  // Real store settings/pricing/persona - only the tool SIDE EFFECTS are faked (see
  // chatbot-engine.ts), so testing reflects what the live bot would actually say today.
  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) }
  ];

  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;
  const anthropic = new Anthropic({ apiKey: anthropicApiKey });

  let finalText: string;
  try {
    finalText = await runChatbotTurn({
      supabase,
      anthropic,
      model: effectiveModel,
      psid: `${SANDBOX_PSID_PREFIX}${adminUsername}`,
      messages,
      followUpSettings,
      systemBlocks,
      simulate: true
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : 'The bot failed to respond.' }, 500);
  }

  const { error: replyInsertErr } = await supabase
    .from('ChatbotSandboxMessages')
    .insert({ Username: adminUsername, Role: 'assistant', Content: finalText });
  if (replyInsertErr) {
    console.error('Failed to record sandbox bot reply:', replyInsertErr.message);
  }

  return jsonResponse({ ok: true, reply: finalText });
});
