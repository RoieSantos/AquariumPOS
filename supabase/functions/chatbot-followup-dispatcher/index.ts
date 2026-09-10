// AI Messenger chatbot: proactive follow-ups. Triggered every 15 minutes by pg_cron (see
// cron_dispatch_chatbot_followups / sql/supabase_chatbot_followups.sql), NOT by anything Facebook
// sends us - the opposite direction from facebook-messenger-webhook, which only ever reacts to an
// inbound message. Two jobs each run:
//   1. Detect - scan for conversations/orders that just became "due" a follow-up per the settings
//      in ChatbotFollowUpSettings (portal-editable from AI Bot Setup), and enqueue a row in
//      ChatbotFollowUps for each. Bot-committed follow-ups (schedule_follow_up tool, called from
//      facebook-messenger-webhook mid-conversation) skip this step - they're already queued.
//   2. Dispatch - send every ChatbotFollowUps row that's now due, composing the message with a
//      small standalone Claude call (persona + reason + recent conversation, no tools needed).
//      Skips (never sends) anything past Facebook's 24h free-form-message window for that PSID -
//      sending outside that window needs an approved message tag, which this bot doesn't have.
//
// Secrets: same as facebook-messenger-webhook (FACEBOOK_PAGE_ACCESS_TOKEN, ANTHROPIC_API_KEY,
// FACEBOOK_GRAPH_API_VERSION, CLAUDE_MODEL) - SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY auto-injected.
// Deploy: supabase functions deploy chatbot-followup-dispatcher --project-ref hymcmesqgpliyyeghpgq

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const DEFAULT_MODEL = 'claude-sonnet-5';
const DEFAULT_GRAPH_VERSION = 'v21.0';
const MAX_DISPATCH_PER_RUN = 25;
const MESSENGER_FREEFORM_WINDOW_MS = 24 * 60 * 60 * 1000;
const HISTORY_CONTEXT_LIMIT = 6;

interface FollowUpRow {
  Id: number;
  Psid: string;
  FollowUpType: 'Abandoned' | 'Escalation' | 'PendingOrder' | 'Committed';
  Reason: string | null;
  RelatedOrderNo: string | null;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

// ---------------------------------------------------------------------------
// Detection - each function is a no-op when its toggle is off. Every candidate found here gets
// exactly one ChatbotFollowUps row and its "already handled" marker column set immediately, so a
// slow run or an overlapping run can't double-enqueue the same idle stretch/escalation/order.
// ---------------------------------------------------------------------------

async function detectAbandoned(supabase: SupabaseClient, settings: Record<string, unknown>): Promise<void> {
  if (!settings.AbandonedEnabled) return;
  const delayMinutes = Number(settings.AbandonedDelayMinutes) || 180;
  const cutoff = new Date(Date.now() - delayMinutes * 60 * 1000).toISOString();

  const { data: rows } = await supabase
    .from('ChatbotConversations')
    .select('Psid, LastBotMessageAtUtc, LastCustomerMessageAtUtc')
    .eq('Status', 'Active')
    .not('LastBotMessageAtUtc', 'is', null)
    .lte('LastBotMessageAtUtc', cutoff)
    .is('AbandonedNudgeSentAtUtc', null);

  for (const row of (rows ?? []) as Array<{ Psid: string; LastBotMessageAtUtc: string; LastCustomerMessageAtUtc: string | null }>) {
    // Bot must have spoken LAST (customer went quiet after it) - if the customer's last message is
    // more recent than the bot's, the bot just hasn't replied yet, which isn't an abandoned chat.
    if (row.LastCustomerMessageAtUtc && row.LastCustomerMessageAtUtc >= row.LastBotMessageAtUtc) continue;

    await supabase.from('ChatbotFollowUps').insert({
      Psid: row.Psid,
      FollowUpType: 'Abandoned',
      DueAtUtc: new Date().toISOString(),
      Reason: 'The customer has not replied since your last message in this conversation - send a brief, friendly check-in to see if they still need help with whatever you were discussing.'
    });
    await supabase.from('ChatbotConversations').update({ AbandonedNudgeSentAtUtc: new Date().toISOString() }).eq('Psid', row.Psid);
  }
}

async function detectEscalations(supabase: SupabaseClient, settings: Record<string, unknown>): Promise<void> {
  if (!settings.EscalationEnabled) return;
  const delayMinutes = Number(settings.EscalationDelayMinutes) || 1440;
  const cutoff = new Date(Date.now() - delayMinutes * 60 * 1000).toISOString();

  const { data: rows } = await supabase
    .from('ChatbotConversations')
    .select('Psid')
    .eq('Status', 'Escalated')
    .not('EscalatedAtUtc', 'is', null)
    .lte('EscalatedAtUtc', cutoff)
    .is('EscalationCheckinSentAtUtc', null);

  for (const row of (rows ?? []) as Array<{ Psid: string }>) {
    await supabase.from('ChatbotFollowUps').insert({
      Psid: row.Psid,
      FollowUpType: 'Escalation',
      DueAtUtc: new Date().toISOString(),
      Reason: 'This conversation was escalated to store staff a while ago and the customer may not have heard back yet. Check in warmly - ask if a team member already reached them, and if not, reassure them someone will.'
    });
    await supabase.from('ChatbotConversations').update({ EscalationCheckinSentAtUtc: new Date().toISOString() }).eq('Psid', row.Psid);
  }
}

async function detectPendingOrders(supabase: SupabaseClient, settings: Record<string, unknown>): Promise<void> {
  if (!settings.PendingOrderEnabled) return;
  const delayMinutes = Number(settings.PendingOrderDelayMinutes) || 720;
  const cutoff = new Date(Date.now() - delayMinutes * 60 * 1000).toISOString();

  const { data: rows } = await supabase
    .from('AutomatedOrders')
    .select('OrderNo, Psid, EstimatedTotal')
    .eq('Status', 'New')
    .not('Psid', 'is', null)
    .lte('CreatedAtUtc', cutoff)
    .is('PaymentReminderSentAtUtc', null);

  for (const row of (rows ?? []) as Array<{ OrderNo: string; Psid: string; EstimatedTotal: number }>) {
    await supabase.from('ChatbotFollowUps').insert({
      Psid: row.Psid,
      FollowUpType: 'PendingOrder',
      DueAtUtc: new Date().toISOString(),
      RelatedOrderNo: row.OrderNo,
      Reason: `Order ${row.OrderNo} (estimated total ~PHP ${row.EstimatedTotal}) is still awaiting confirmation/payment - nobody has moved it off "New" yet. Remind the customer it's still open, ask if they'd like to complete payment or need help, and give them the order number so they can reference it.`
    });
    await supabase.from('AutomatedOrders').update({ PaymentReminderSentAtUtc: new Date().toISOString() }).eq('OrderNo', row.OrderNo);
  }
}

// ---------------------------------------------------------------------------
// Message composition - a small standalone Claude call, deliberately without tools/thinking: a
// follow-up is a short proactive nudge, not a multi-step conversational turn.
// ---------------------------------------------------------------------------

async function composeFollowUpMessage(
  anthropic: Anthropic,
  model: string,
  aiSettings: Record<string, unknown> | null,
  followUpSettings: Record<string, unknown> | null,
  reason: string,
  recentMessages: Array<{ Role: string; Content: string }>
): Promise<string> {
  const botName = (aiSettings?.BotName as string) || 'RS Pet Stop Messenger Assistant';
  const lines: string[] = [
    `You are ${botName}, a friendly staff member of an aquarium and pet supply store. You are PROACTIVELY re-opening a Facebook Messenger conversation with a customer - they have not just messaged you, you are the one starting this.`,
    '',
    `WHY YOU ARE FOLLOWING UP: ${reason}`,
    '',
    'Write ONE short, warm, low-pressure Messenger message - plain text only, no markdown, no bullet points. Sound like a helpful staff member checking in, never like an automated reminder or a sales blast. Do not repeat information already covered in the recent conversation below if shown - move things forward naturally instead.'
  ];
  if (aiSettings?.CommunicationStyle) {
    lines.push('', 'COMMUNICATION STYLE:', String(aiSettings.CommunicationStyle));
  }
  if (followUpSettings?.FollowUpDirections) {
    lines.push('', 'ADDITIONAL FOLLOW-UP DIRECTIONS FROM THE STORE OWNER:', String(followUpSettings.FollowUpDirections));
  }
  if (recentMessages.length > 0) {
    lines.push('', 'RECENT CONVERSATION (oldest first):');
    for (const m of [...recentMessages].reverse()) {
      lines.push(`${m.Role === 'user' ? 'Customer' : botName}: ${m.Content}`);
    }
  }
  lines.push('', 'Reply with ONLY the message text to send the customer - nothing else, no preamble.');

  const response = await anthropic.messages.create({
    model,
    max_tokens: 300,
    system: lines.join('\n'),
    messages: [{ role: 'user', content: 'Write the follow-up message now.' }]
  });

  const textBlocks = response.content.filter((b) => b.type === 'text') as Array<{ text: string }>;
  return textBlocks.map((b) => b.text).join('\n\n').trim() || "Hi! Just checking in - let us know if there's anything else we can help with.";
}

async function sendMessengerReply(psid: string, text: string, pageAccessToken: string, graphVersion: string): Promise<void> {
  const url = `https://graph.facebook.com/${graphVersion}/me/messages?access_token=${pageAccessToken}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ recipient: { id: psid }, message: { text }, messaging_type: 'RESPONSE' })
  });
  if (!res.ok) {
    console.error(`Messenger Send API failed (${res.status}): ${await res.text()}`);
  }
}

async function dispatchDueFollowUps(
  supabase: SupabaseClient,
  anthropic: Anthropic,
  model: string,
  aiSettings: Record<string, unknown> | null,
  followUpSettings: Record<string, unknown> | null,
  pageAccessToken: string,
  graphVersion: string
): Promise<{ sent: number; skipped: number }> {
  const { data: dueRows } = await supabase
    .from('ChatbotFollowUps')
    .select('Id, Psid, FollowUpType, Reason, RelatedOrderNo')
    .eq('Status', 'Pending')
    .lte('DueAtUtc', new Date().toISOString())
    .order('DueAtUtc', { ascending: true })
    .limit(MAX_DISPATCH_PER_RUN);

  let sent = 0;
  let skipped = 0;

  for (const followUp of (dueRows ?? []) as FollowUpRow[]) {
    const { data: convo } = await supabase
      .from('ChatbotConversations')
      .select('LastCustomerMessageAtUtc')
      .eq('Psid', followUp.Psid)
      .maybeSingle();

    // Facebook only allows free-form messages within 24h of the customer's last message to the
    // page - outside that window a message tag (which this bot isn't approved for) is required.
    // Sending anyway would just fail against Meta, so skip cleanly instead.
    const lastCustomerMessageAtUtc = convo?.LastCustomerMessageAtUtc ? new Date(convo.LastCustomerMessageAtUtc as string).getTime() : 0;
    if (!lastCustomerMessageAtUtc || Date.now() - lastCustomerMessageAtUtc > MESSENGER_FREEFORM_WINDOW_MS) {
      await supabase
        .from('ChatbotFollowUps')
        .update({ Status: 'Skipped', SkipReason: 'Outside Messenger 24h free-form messaging window.' })
        .eq('Id', followUp.Id);
      skipped++;
      continue;
    }

    const { data: historyRows } = await supabase
      .from('ChatbotMessages')
      .select('Role, Content')
      .eq('Psid', followUp.Psid)
      .order('CreatedAtUtc', { ascending: false })
      .limit(HISTORY_CONTEXT_LIMIT);

    try {
      const text = await composeFollowUpMessage(
        anthropic,
        model,
        aiSettings,
        followUpSettings,
        followUp.Reason || 'Check in with the customer.',
        (historyRows ?? []) as Array<{ Role: string; Content: string }>
      );

      await sendMessengerReply(followUp.Psid, text, pageAccessToken, graphVersion);
      await supabase.from('ChatbotMessages').insert({ Psid: followUp.Psid, Role: 'assistant', Content: text });
      await supabase
        .from('ChatbotConversations')
        .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
        .eq('Psid', followUp.Psid);
      await supabase.from('ChatbotFollowUps').update({ Status: 'Sent', SentAtUtc: new Date().toISOString() }).eq('Id', followUp.Id);
      sent++;
    } catch (err) {
      console.error(`Failed to dispatch follow-up ${followUp.Id} (${followUp.FollowUpType}, psid ${followUp.Psid}):`, err instanceof Error ? err.message : err);
    }
  }

  return { sent, skipped };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST (invoked by pg_cron).' }, 405);
  }

  const pageAccessToken = Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;

  if (!pageAccessToken || !anthropicApiKey || !supabaseUrl || !serviceRoleKey) {
    console.error('chatbot-followup-dispatcher is missing one or more required secrets.');
    return jsonResponse({ error: 'Missing required secrets.' }, 500);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const anthropic = new Anthropic({ apiKey: anthropicApiKey });

  try {
    const { data: followUpSettings } = await supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle();
    if (!followUpSettings) {
      return jsonResponse({ ok: true, note: 'ChatbotFollowUpSettings not configured yet.' });
    }

    await Promise.all([
      detectAbandoned(supabase, followUpSettings),
      detectEscalations(supabase, followUpSettings),
      detectPendingOrders(supabase, followUpSettings)
    ]);

    const { data: aiSettings } = await supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle();
    const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;

    const { sent, skipped } = await dispatchDueFollowUps(supabase, anthropic, effectiveModel, aiSettings, followUpSettings, pageAccessToken, graphVersion);

    return jsonResponse({ ok: true, sent, skipped });
  } catch (err) {
    console.error('Unhandled error in chatbot-followup-dispatcher:', err instanceof Error ? err.message : err);
    return jsonResponse({ ok: false, error: err instanceof Error ? err.message : 'Unknown error' }, 500);
  }
});
