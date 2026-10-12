// Customer mood for GMA Conversations - per "an indicator for each customer if they sound angry /
// sad / doubtful / excited". Staff-only: shown as an emoji in the inbox list + thread header
// (gmaConversations.js), never sent to the customer, and Alice's replies don't use it.
//
// Runs in the background after each customer message, on a cheap model - set on AI Bot Setup >
// Customer mood (else the MOOD_MODEL secret, default Claude Haiku 5.5; Alice's replies stay on
// CLAUDE_MODEL). Waits the set delay (default 30s) first so a burst of
// messages ("hi" / "magkano po" / "yung 3ft") costs ONE check: if another customer message arrives
// in the meantime, this check stands down and the newer one's check does the work.
// Best-effort: any failure just leaves the previous mood showing.
//
// Data: ChatbotConversations.CustomerMood / CustomerMoodReason / CustomerMoodAtUtc
// (sql/supabase_gma_conversation_mood.sql); settings: ChatbotAiSettings.Mood* (sql/supabase_chatbot_mood_settings.sql).

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const DEFAULT_MOOD_MODEL = 'claude-haiku-5-5';
const MOOD_DEBOUNCE_MS = 30_000;
const MOOD_HISTORY_LIMIT = 12;

export const MOODS = ['angry', 'impatient', 'sad', 'unsure', 'neutral', 'happy', 'excited', 'ready_to_buy'] as const;
type Mood = typeof MOODS[number];

// Attachment-only rows ("[Photo]", "[Video]", ...) say nothing about mood on their own.
const PLACEHOLDER_ONLY = /^\[(Photo|Video|Voice message|Audio|File|Location|Attachment|Sticker)[^\]]*\](\s+https?:\/\/\S+)?$/i;

const SYSTEM_PROMPT = `You read a short Messenger chat between a customer and a Philippine pet/aquarium store (RS Pet Stop / GMA). Messages may be English, Filipino or Taglish. Judge how the CUSTOMER feels right now, based mostly on their latest messages, using the earlier chat as context (e.g. a dry "ok." right after a complaint is still annoyed, not neutral).

Pick exactly one mood:
- angry: upset, complaining, blaming, threatening a bad review/refund
- impatient: waiting too long, chasing a reply/delivery ("ang tagal", "hello??", "update po?")
- sad: disappointed, hurt, a pet died or got sick
- unsure: hesitant, doubtful, comparing, worried about price/quality/trust, "pag-iisipan ko muna"
- neutral: plain questions or info, no clear feeling
- happy: satisfied, thankful, friendly
- excited: very eager, lots of enthusiasm/emojis about a pet or product
- ready_to_buy: clearly about to order or pay (asks how to pay, confirms items/address, "sige kukunin ko")

Reply with ONLY a JSON object, no markdown, no other text: {"mood": "<one of the moods>", "reason": "<max 12 words, plain English, why - for store staff>"}`;

export interface MoodCheckParams {
  supabase: SupabaseClient;
  anthropic: Anthropic;
  psid: string;
  receivedAtIso: string; // LastCustomerMessageAtUtc this message set - used to detect a newer message
  broadcast: (psid: string) => Promise<void>;
}

// On/off, model and wait time from AI Bot Setup (ChatbotAiSettings.Mood*, supabase_chatbot_mood_settings.sql).
// select('*') so a missing column (SQL not run yet) just falls back to the defaults.
async function loadMoodSettings(supabase: SupabaseClient): Promise<{ enabled: boolean; model: string; delayMs: number }> {
  const { data } = await supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle();
  const row = (data ?? {}) as Record<string, unknown>;
  const delaySeconds = Number(row.MoodDelaySeconds);
  return {
    enabled: row.MoodEnabled !== false,
    model: (typeof row.MoodModel === 'string' && row.MoodModel) || Deno.env.get('MOOD_MODEL') || DEFAULT_MOOD_MODEL,
    delayMs: delaySeconds >= 10 && delaySeconds <= 120 ? delaySeconds * 1000 : MOOD_DEBOUNCE_MS
  };
}

export async function runMoodCheck({ supabase, anthropic, psid, receivedAtIso, broadcast }: MoodCheckParams): Promise<void> {
  const settings = await loadMoodSettings(supabase);
  if (!settings.enabled) return;

  await new Promise((resolve) => setTimeout(resolve, settings.delayMs));

  const { data: conv } = await supabase
    .from('ChatbotConversations')
    .select('LastCustomerMessageAtUtc, CustomerMoodAtUtc')
    .eq('Psid', psid)
    .maybeSingle();
  if (!conv) return;
  // A newer customer message arrived while waiting - its own check covers this one too.
  if (Date.parse(conv.LastCustomerMessageAtUtc as string) !== Date.parse(receivedAtIso)) return;

  const { data: rows } = await supabase
    .from('ChatbotMessages')
    .select('Role, Content, CreatedAtUtc')
    .eq('Psid', psid)
    .order('CreatedAtUtc', { ascending: false })
    .limit(MOOD_HISTORY_LIMIT);
  const history = ((rows ?? []) as Array<{ Role: string; Content: string | null; CreatedAtUtc: string }>).reverse();

  // Only worth a call if the customer actually wrote something since the last check - a sticker,
  // photo or voice note alone keeps the previous mood.
  const lastCheckAt = conv.CustomerMoodAtUtc ? Date.parse(conv.CustomerMoodAtUtc as string) : 0;
  const hasNewText = history.some((m) => {
    const text = (m.Content || '').trim();
    return m.Role === 'user' && Date.parse(m.CreatedAtUtc) > lastCheckAt && text !== '' && !PLACEHOLDER_ONLY.test(text);
  });
  if (!hasNewText) return;

  const transcript = history
    .filter((m) => (m.Content || '').trim() !== '')
    .map((m) => `${m.Role === 'user' ? 'Customer' : m.Role === 'staff' ? 'Store staff' : 'Store bot'}: ${(m.Content || '').trim().slice(0, 600)}`)
    .join('\n');

  const result = await classifyMood(anthropic, settings.model, transcript);
  if (!result) return;

  await supabase
    .from('ChatbotConversations')
    .update({ CustomerMood: result.mood, CustomerMoodReason: result.reason, CustomerMoodAtUtc: new Date().toISOString() })
    .eq('Psid', psid);
  await broadcast(psid);
}

async function classifyMood(anthropic: Anthropic, model: string, transcript: string): Promise<{ mood: Mood; reason: string } | null> {
  try {
    const res = await anthropic.messages.create({
      model,
      max_tokens: 1024,
      output_config: { effort: 'low' },
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: `Chat (oldest first):\n${transcript}` }]
    });

    const block = res.content.find((b) => b.type === 'text');
    if (!block || block.type !== 'text') {
      console.error('Mood check returned no text block; stop_reason:', res.stop_reason);
      return null;
    }
    // Same tolerant {...} extraction as the payment vision pass.
    const raw = block.text.trim();
    const start = raw.indexOf('{');
    const end = raw.lastIndexOf('}');
    if (start === -1 || end < start) {
      console.error('Mood check returned no JSON object. Raw response:', raw);
      return null;
    }
    const parsed = JSON.parse(raw.slice(start, end + 1)) as { mood?: string; reason?: string };
    const mood = (parsed.mood || '').trim().toLowerCase() as Mood;
    if (!MOODS.includes(mood)) {
      console.error('Mood check returned an unknown mood:', parsed.mood);
      return null;
    }
    return { mood, reason: (parsed.reason || '').toString().trim().slice(0, 200) };
  } catch (err) {
    console.error('Mood check failed:', err instanceof Error ? err.message : err);
    return null;
  }
}
