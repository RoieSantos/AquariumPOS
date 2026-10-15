// Customer mood for GMA Conversations - per "an indicator for each customer if they sound angry /
// sad / doubtful / excited". Staff-only: shown as an emoji in the inbox list + thread header
// (gmaConversations.js), never sent to the customer, and Alice's replies don't use it.
//
// The same call also auto-fills the Customers record - per "if the customer send an information on
// the conversations can we auto fill in to the customers?" (sql/supabase_chatbot_customer_info_autofill.sql).
// The bot's save_customer_info tool only saves while the bot is replying; this runs after every
// customer message, paused or not, so details given to staff are kept too. See applyCustomerInfo.
//
// Runs in the background after each customer message, on a cheap model - set on AI Bot Setup >
// Customer mood (else the MOOD_MODEL secret, default Claude Haiku 5.5; Alice's replies stay on
// CLAUDE_MODEL). Waits the set delay (default 30s) first so a burst of
// messages ("hi" / "magkano po" / "yung 3ft") costs ONE check: if another customer message arrives
// in the meantime, this check stands down and the newer one's check does the work. Switching
// Customer mood off stops the mood part only - the customer-info part still runs.
// Best-effort: any failure just leaves the previous mood / record as it was.
//
// Data: ChatbotConversations.CustomerMood / CustomerMoodReason / CustomerMoodAtUtc
// (sql/supabase_gma_conversation_mood.sql), CustomerName / CustomerPhone / CustomerAddress +
// CustomerInfoCheckedAtUtc; settings: ChatbotAiSettings.Mood* (sql/supabase_chatbot_mood_settings.sql).

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const DEFAULT_MOOD_MODEL = 'claude-haiku-5-5';
const MOOD_DEBOUNCE_MS = 30_000;
const MOOD_HISTORY_LIMIT = 12;

export const MOODS = ['angry', 'impatient', 'sad', 'unsure', 'neutral', 'happy', 'excited', 'ready_to_buy'] as const;
type Mood = typeof MOODS[number];

// Attachment-only rows ("[Photo]", "[Video]", ...) say nothing about mood on their own.
const PLACEHOLDER_ONLY = /^\[(Photo|Video|Voice message|Audio|File|Location|Attachment|Sticker)[^\]]*\](\s+https?:\/\/\S+)?$/i;

const CHAT_INTRO = 'You read a short Messenger chat between a customer and a Philippine pet/aquarium store (RS Pet Stop / GMA). Messages may be English, Filipino or Taglish.';

const MOOD_TASK = `MOOD: judge how the CUSTOMER feels right now, based mostly on their latest messages, using the earlier chat as context (e.g. a dry "ok." right after a complaint is still annoyed, not neutral).

Pick exactly one mood:
- angry: upset, complaining, blaming, threatening a bad review/refund
- impatient: waiting too long, chasing a reply/delivery ("ang tagal", "hello??", "update po?")
- sad: disappointed, hurt, a pet died or got sick
- unsure: hesitant, doubtful, comparing, worried about price/quality/trust, "pag-iisipan ko muna"
- neutral: plain questions or info, no clear feeling
- happy: satisfied, thankful, friendly
- excited: very eager, lots of enthusiasm/emojis about a pet or product
- ready_to_buy: clearly about to order or pay (asks how to pay, confirms items/address, "sige kukunin ko")`;

const INFO_TASK = `CUSTOMER INFO: from the Customer lines marked [NEW] only, copy any of these the customer gave as their own / for their order or delivery:
- name: their full name, only when they state it ("Juan Dela Cruz po", "name: ...") - not a greeting, nickname or someone else's name
- phones: every mobile number the customer gave as their own / for their order or delivery, exactly as typed, as a list. Put the MAIN one LAST: the one they say is for this order, or the corrected one if they corrected a typo (leave the wrong one out), otherwise the last one they gave. Skip any number that is the store's, staff's or a driver's (e.g. "I sent it to 0917... on GCash", "I called your number") - those are not theirs
- address: their delivery or home address, as complete as they wrote it (join lines with ", ")
Use null for anything not clearly given in a [NEW] line. Never guess or complete a value, and never take details the store sent.`;

export interface MoodCheckParams {
  supabase: SupabaseClient;
  anthropic: Anthropic;
  psid: string;
  receivedAtIso: string; // LastCustomerMessageAtUtc this message set - used to detect a newer message
  broadcast: (psid: string) => Promise<void>;
}

interface CustomerInfo {
  name: string | null;
  phones: string[]; // main one last
  address: string | null;
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

function hasText(m: { Content: string | null }): boolean {
  const text = (m.Content || '').trim();
  return text !== '' && !PLACEHOLDER_ONLY.test(text);
}

export async function runMoodCheck({ supabase, anthropic, psid, receivedAtIso, broadcast }: MoodCheckParams): Promise<void> {
  const settings = await loadMoodSettings(supabase);

  await new Promise((resolve) => setTimeout(resolve, settings.delayMs));

  // select('*') so a missing CustomerInfoCheckedAtUtc (SQL not run yet) doesn't break the mood check.
  const { data: convData } = await supabase.from('ChatbotConversations').select('*').eq('Psid', psid).maybeSingle();
  const conv = convData as Record<string, unknown> | null;
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

  // Each part is only worth a call if the customer actually wrote something since that part last
  // ran - a sticker, photo or voice note alone keeps the previous mood / record.
  const moodCheckedAt = conv.CustomerMoodAtUtc ? Date.parse(conv.CustomerMoodAtUtc as string) : 0;
  const infoSupported = 'CustomerInfoCheckedAtUtc' in conv;
  // First run on an existing chat: only this burst counts as new, not months of old messages.
  const infoCheckedAt = conv.CustomerInfoCheckedAtUtc
    ? Date.parse(conv.CustomerInfoCheckedAtUtc as string)
    : Date.parse(receivedAtIso) - settings.delayMs - 5 * 60_000;
  const isNewFor = (m: { Role: string; CreatedAtUtc: string; Content: string | null }, since: number) =>
    m.Role === 'user' && Date.parse(m.CreatedAtUtc) > since && hasText(m);

  const wantMood = settings.enabled && history.some((m) => isNewFor(m, moodCheckedAt));
  const wantInfo = infoSupported && history.some((m) => isNewFor(m, infoCheckedAt));
  if (!wantMood && !wantInfo) return;

  const transcript = history
    .filter((m) => (m.Content || '').trim() !== '')
    .map((m) => {
      const who = m.Role === 'user' ? 'Customer' : m.Role === 'staff' ? 'Store staff' : 'Store bot';
      const tag = wantInfo && isNewFor(m, infoCheckedAt) ? ' [NEW]' : '';
      return `${who}${tag}: ${(m.Content || '').trim().slice(0, 600)}`;
    })
    .join('\n');

  const result = await classifyChat(anthropic, settings.model, transcript, wantMood, wantInfo);
  if (!result) return;

  let changed = false;
  if (wantMood && result.mood) {
    await supabase
      .from('ChatbotConversations')
      .update({ CustomerMood: result.mood, CustomerMoodReason: result.reason, CustomerMoodAtUtc: new Date().toISOString() })
      .eq('Psid', psid);
    changed = true;
  }
  if (wantInfo && result.info) {
    // A number the store / staff / bot sent in this chat BEFORE the customer typed it is the shop's
    // (e.g. a GCash number the customer repeats back). One the customer typed first and staff then
    // repeated to confirm ("0917... po, tama?") is still the customer's.
    const blocked = await loadShopNumbers(supabase);
    const seen = new Set<string>();
    history.forEach((m) => extractPhMobiles(m.Content).forEach((n) => {
      if (seen.has(n)) return;
      seen.add(n);
      if (m.Role !== 'user') blocked.add(n);
    }));
    changed = (await applyCustomerInfo(supabase, psid, conv, result.info, blocked)) || changed;
  }
  if (changed) await broadcast(psid);
}

// PH mobile in any common form (0917 123 4567, +63 917..., 63917..., 917...) -> 09xxxxxxxxx, else null.
function normalizePhMobile(raw: string | null): string | null {
  const digits = String(raw || '').replace(/\D/g, '');
  if (/^09\d{9}$/.test(digits)) return digits;
  if (/^639\d{9}$/.test(digits)) return `0${digits.slice(2)}`;
  if (/^9\d{9}$/.test(digits)) return `0${digits}`;
  return null;
}

// Every PH mobile in a piece of text, normalized (0917 123 4567 / +63 917-123-4567 / 639171234567).
function extractPhMobiles(text: string | null | undefined): string[] {
  const matches = String(text || '').match(/(?<!\d)(?:\+?63|0)?[\s-]*9\d{2}[\s-]*\d{3}[\s-]*\d{4}(?!\d)/g) || [];
  return matches.map(normalizePhMobile).filter((n): n is string => !!n);
}

// The shop's own numbers - never saved as a customer's: Company Information / branch Contact No.,
// any number in AI Bot Setup > Store Info (GCash / bank / pickup contacts) and staff phone numbers
// (drivers share theirs with customers). select('*') so a missing column / table is just skipped.
async function loadShopNumbers(supabase: SupabaseClient): Promise<Set<string>> {
  const blocked = new Set<string>();
  const add = (rows: unknown) => ((rows ?? []) as Array<Record<string, unknown>>)
    .forEach((row) => Object.values(row).forEach((v) => { if (typeof v === 'string') extractPhMobiles(v).forEach((n) => blocked.add(n)); }));
  const [company, warehouses, storeInfo, staff] = await Promise.all([
    supabase.from('CompanyInfo').select('ContactNo'),
    supabase.from('Warehouses').select('ContactNo'),
    supabase.from('ChatbotStoreInfo').select('*'),
    supabase.from('StaffUsers').select('PhoneNumber')
  ]);
  [company, warehouses, storeInfo, staff].forEach((r) => add(r.data));
  return blocked;
}

// Saves what the customer just gave onto their CRM record. Contact No. / Address: the newest one
// they give becomes the default (CustomerPhone / CustomerAddress); the old one stays in their
// Contacts & Addresses list (ChatbotCustomerContacts - the trigger in
// sql/supabase_gma_customer_contacts.sql copies every default into it). Other numbers they gave in the
// same messages are added to that list too, not as default. Name: only fills a blank or
// Facebook-profile name - one they typed before or staff set on the Customer Card ('Staff') is kept.
async function applyCustomerInfo(
  supabase: SupabaseClient,
  psid: string,
  conv: Record<string, unknown>,
  info: CustomerInfo,
  blockedNumbers: Set<string>
): Promise<boolean> {
  const update: Record<string, unknown> = { CustomerInfoCheckedAtUtc: new Date().toISOString() };
  let changed = false;

  const candidates = [...new Set(info.phones.flatMap(extractPhMobiles).filter((n) => !blockedNumbers.has(n)))];
  if (info.phones.length > 0 && candidates.length === 0) console.log(`Customer info: skipped number(s) for ${psid} (shop/staff number or not a PH mobile).`);
  // extractPhMobiles keeps order, so the main one (the model puts it last) is still last.
  const mainPhone = candidates.length > 0 ? info.phones.flatMap(extractPhMobiles).filter((n) => !blockedNumbers.has(n)).pop()! : null;
  const currentPhone = normalizePhMobile(conv.CustomerPhone as string | null) ?? String(conv.CustomerPhone || '').trim();
  for (const extra of candidates.filter((n) => n !== mainPhone && n !== currentPhone)) {
    // Not fatal if the contacts SQL isn't run yet - the main number below is still saved.
    const { error } = await supabase.rpc('gma_upsert_customer_contact', {
      p_psid: psid, p_kind: 'Phone', p_value: extra, p_source: 'Chat', p_make_default: false
    });
    if (error) console.warn('Customer info: extra number not added to the contact list:', error.message);
    else changed = true;
  }
  if (mainPhone && mainPhone !== currentPhone) {
    update.CustomerPhone = mainPhone;
    changed = true;
  }

  const address = String(info.address || '').replace(/\s+/g, ' ').trim().slice(0, 500);
  if (address.length >= 10 && address.toLowerCase() !== String(conv.CustomerAddress || '').trim().toLowerCase()) {
    update.CustomerAddress = address;
    changed = true;
  }

  const name = String(info.name || '').replace(/\s+/g, ' ').trim().slice(0, 255);
  const nameSource = String(conv.CustomerNameSource || '');
  const nameReplaceable = !String(conv.CustomerName || '').trim() || nameSource === '' || nameSource === 'FacebookProfile';
  if (name.length >= 3 && /\s/.test(name) && nameReplaceable && name !== String(conv.CustomerName || '').trim()) {
    update.CustomerName = name;
    update.CustomerNameSource = 'CustomerProvided';
    changed = true;
  }

  const { error } = await supabase.from('ChatbotConversations').update(update).eq('Psid', psid);
  if (error) {
    console.error('Customer info auto-fill failed:', error.message);
    return false;
  }
  if (changed) console.log(`Customer info auto-filled for ${psid}:`, Object.keys(update).filter((k) => k !== 'CustomerInfoCheckedAtUtc').join(', '));
  return changed;
}

function cleanField(value: unknown): string | null {
  const text = typeof value === 'string' ? value.trim() : '';
  return text && text.toLowerCase() !== 'null' ? text : null;
}

async function classifyChat(
  anthropic: Anthropic,
  model: string,
  transcript: string,
  wantMood: boolean,
  wantInfo: boolean
): Promise<{ mood: Mood | null; reason: string; info: CustomerInfo | null } | null> {
  const tasks = [wantMood ? MOOD_TASK : '', wantInfo ? INFO_TASK : ''].filter(Boolean).join('\n\n');
  const shape = [
    wantMood ? '"mood": "<one of the moods>", "reason": "<max 12 words, plain English, why - for store staff>"' : '',
    wantInfo ? '"name": string|null, "phones": string[], "address": string|null' : ''
  ].filter(Boolean).join(', ');
  try {
    const res = await anthropic.messages.create({
      model,
      max_tokens: 1024,
      output_config: { effort: 'low' },
      system: `${CHAT_INTRO}\n\n${tasks}\n\nReply with ONLY a JSON object, no markdown, no other text: {${shape}}`,
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
    const parsed = JSON.parse(raw.slice(start, end + 1)) as Record<string, unknown>;

    let mood: Mood | null = null;
    if (wantMood) {
      const candidate = String(parsed.mood || '').trim().toLowerCase() as Mood;
      if (MOODS.includes(candidate)) mood = candidate;
      else console.error('Mood check returned an unknown mood:', parsed.mood);
    }
    const info = wantInfo
      ? {
        name: cleanField(parsed.name),
        // phones[] - also accepts a lone "phone" string in case the model answers the old shape.
        phones: (Array.isArray(parsed.phones) ? parsed.phones : [parsed.phones ?? parsed.phone])
          .map(cleanField)
          .filter((p): p is string => !!p),
        address: cleanField(parsed.address)
      }
      : null;
    return { mood, reason: String(parsed.reason || '').trim().slice(0, 200), info };
  } catch (err) {
    console.error('Mood check failed:', err instanceof Error ? err.message : err);
    return null;
  }
}
