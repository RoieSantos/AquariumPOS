// Lets the internal sales team chat with Alice (the AI bot) directly inside the existing Telegram
// group used for order-confirmed notifications (see supabase_telegram_notifications.sql) - per
// direct request: "is it possible to create a group message with our sales team with Alice using
// our inhouse telegram?" Reuses the SAME bot token + chat id (no second bot), adding INBOUND
// handling on top of the existing OUTBOUND-only notification sender.
//
// Design decisions (confirmed with the user before building):
//  - Same bot/persona as Facebook Messenger and the website widget ("Alice"), not a separate bot.
//  - In a GROUP chat, only responds when explicitly @mentioned or when a message is a reply to one
//    of Alice's own messages - never to ordinary back-and-forth between staff. (Telegram's default
//    bot "Privacy Mode" already restricts *which* group messages even reach this webhook to
//    mentions/replies/commands - this function re-checks that explicitly too, so behavior doesn't
//    silently change if Privacy Mode is ever turned off in BotFather.)
//  - In a PRIVATE chat with the bot (1:1 DM), always responds - no "everyone sees it" noise concern.
//  - Runs the shared engine in `simulate: true` mode (same safety net as the AI Bot Sandbox,
//    docs/ai-bot-sandbox.html) - nothing said to Alice here can create a real order, save a real
//    CRM record, or send a real customer-facing escalation; every side-effecting tool just
//    describes what it WOULD have done. This is an internal Q&A/testing surface, not a new
//    customer-facing order channel.
//  - History lives in its own TelegramAliceMessages table (supabase_telegram_alice_messages.sql),
//    NOT the customer-facing ChatbotConversations/ChatbotMessages tables.
//
// SETUP (one-time, after deploying this function):
//   1. Make sure supabase_telegram_notifications.sql has already been run and
//      TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are both configured (General Setup page).
//   2. Run supabase_telegram_alice_messages.sql.
//   3. Set a webhook secret so random internet traffic can't POST fake Telegram updates here:
//        npx supabase secrets set TELEGRAM_WEBHOOK_SECRET=<any-random-string> --project-ref hymcmesqgpliyyeghpgq
//   4. Point Telegram at this function (replace <TOKEN> and <SECRET> with your real values):
//        curl "https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/telegram-alice-webhook&secret_token=<SECRET>"
//   5. In the group, @mention the bot (e.g. "@YourBotUsername what's the price of a 24x12x12 tank?")
//      or reply to one of its messages - it'll answer right in the group. DM it directly for a
//      private 1:1 test chat.
//
// Deploy: supabase functions deploy telegram-alice-webhook --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { buildCurrentTimeLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

const DEFAULT_MODEL = 'claude-sonnet-5';
const HISTORY_LIMIT = 20;
const STORE_TIMEZONE = 'Asia/Manila';

interface TelegramEntity {
  type: string;
  offset: number;
  length: number;
}

interface BotIdentity {
  id: number;
  username: string;
}

// Edge function instances can be reused across invocations while warm - caching the bot's own
// id/username here just avoids an extra getMe call on every message once an instance is warm.
let cachedBot: BotIdentity | null = null;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

async function getBotIdentity(token: string): Promise<BotIdentity | null> {
  if (cachedBot) return cachedBot;
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/getMe`);
    const data = await res.json();
    if (data?.ok && data.result?.id && data.result?.username) {
      cachedBot = { id: data.result.id, username: String(data.result.username).toLowerCase() };
      return cachedBot;
    }
  } catch (err) {
    console.error('telegram-alice-webhook getMe failed:', err);
  }
  return null;
}

function findBotMention(text: string, entities: TelegramEntity[] | undefined, botUsername: string): TelegramEntity | null {
  if (!text || !entities) return null;
  for (const entity of entities) {
    if (entity.type !== 'mention') continue;
    const mentionText = text.substring(entity.offset, entity.offset + entity.length).toLowerCase();
    if (mentionText === `@${botUsername}`) return entity;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const webhookSecret = Deno.env.get('TELEGRAM_WEBHOOK_SECRET');
  const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;

  if (!supabaseUrl || !serviceRoleKey || !anthropicApiKey) {
    console.error('telegram-alice-webhook is missing one or more required secrets.');
    return jsonResponse({ ok: true }); // 200 so Telegram doesn't retry-storm a misconfigured deploy
  }

  // Telegram sends this header back exactly as given to setWebhook's secret_token param - without
  // it, anyone who finds this URL could POST fake "updates" that make Alice answer as if a staff
  // member asked something.
  if (webhookSecret) {
    const gotSecret = req.headers.get('x-telegram-bot-api-secret-token');
    if (gotSecret !== webhookSecret) {
      return jsonResponse({ error: 'Invalid secret token.' }, 401);
    }
  }

  let update: Record<string, any>;
  try {
    update = await req.json();
  } catch {
    return jsonResponse({ ok: true });
  }

  const message = update?.message;
  const text: string | undefined = message?.text;
  const chatId: string | undefined = message?.chat?.id != null ? String(message.chat.id) : undefined;
  const chatType: string | undefined = message?.chat?.type;

  if (!message || !text || !chatId) {
    // Not a plain text message (photo, sticker, edited_message, callback_query, etc.) - nothing
    // for Alice to answer here, just ack quietly.
    return jsonResponse({ ok: true });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { data: token } = await supabase.rpc('_telegram_bot_token');
  if (!token) {
    console.error('TELEGRAM_BOT_TOKEN is not configured yet - see supabase_telegram_notifications.sql.');
    return jsonResponse({ ok: true });
  }

  const bot = await getBotIdentity(token);

  let shouldRespond = chatType === 'private';
  let cleanText = text;

  if (!shouldRespond && bot) {
    const mention = findBotMention(text, message.entities as TelegramEntity[] | undefined, bot.username);
    const repliedToBot = message.reply_to_message?.from?.id === bot.id;
    shouldRespond = Boolean(mention) || repliedToBot;
    if (mention) {
      cleanText = (text.substring(0, mention.offset) + text.substring(mention.offset + mention.length)).trim() || text;
    }
  }

  if (!shouldRespond) {
    return jsonResponse({ ok: true });
  }

  const senderName = [message.from?.first_name, message.from?.last_name].filter(Boolean).join(' ')
    || message.from?.username
    || 'Staff';

  const { error: insertErr } = await supabase
    .from('TelegramAliceMessages')
    .insert({ ChatId: chatId, SenderName: senderName, Role: 'user', Content: cleanText });
  if (insertErr) {
    console.error('Failed to record incoming Telegram message:', insertErr.message);
  }

  const { data: historyRows } = await supabase
    .from('TelegramAliceMessages')
    .select('Role, Content, SenderName')
    .eq('ChatId', chatId)
    .order('CreatedAtUtc', { ascending: false })
    .limit(HISTORY_LIMIT);

  const messages: Anthropic.MessageParam[] = (historyRows ?? [])
    .reverse()
    .map((row: { Role: string; Content: string; SenderName: string | null }) => ({
      role: row.Role === 'user' ? 'user' : 'assistant',
      // Multiple staff share this one conversation, so user turns are prefixed with who said it -
      // otherwise Alice would see an undifferentiated stream and couldn't tell speakers apart.
      content: row.Role === 'user' && row.SenderName ? `${row.SenderName}: ${row.Content}` : row.Content
    }));

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettings }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  const systemBlocks = [
    {
      type: 'text' as const,
      text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings),
      cache_control: { type: 'ephemeral' as const }
    },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    {
      type: 'text' as const,
      text: 'INTERNAL STAFF TELEGRAM CHAT: you are talking with RS Pet Stop\'s own sales/staff team inside their internal Telegram chat, not a customer. Multiple staff members may be in this conversation - each user message is prefixed with "Name: " so you know who is asking. Keep answers short and direct like a quick Telegram reply, not a full customer-facing script. This is for internal reference/testing only, so no order, escalation, or CRM save you take here is real - it is simulated.'
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
      psid: `telegram:${chatId}`,
      messages,
      followUpSettings,
      aiSettings,
      systemBlocks,
      simulate: true
    });
  } catch (err) {
    finalText = 'Sorry, I ran into an error answering that - please try again.';
    console.error('telegram-alice-webhook runChatbotTurn error:', err);
  }

  const { error: replyInsertErr } = await supabase
    .from('TelegramAliceMessages')
    .insert({ ChatId: chatId, SenderName: 'Alice', Role: 'assistant', Content: finalText });
  if (replyInsertErr) {
    console.error('Failed to record Alice reply:', replyInsertErr.message);
  }

  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chat_id: chatId,
        text: finalText,
        reply_to_message_id: message.message_id
      })
    });
  } catch (err) {
    console.error('Failed to send Telegram reply:', err);
  }

  return jsonResponse({ ok: true });
});
