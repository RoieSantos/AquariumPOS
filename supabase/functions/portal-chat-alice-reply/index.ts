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

  // How the staff-only portal tools work (Calculators > Aquarium Calculator, Delivery > Delivery
  // Quote) - internal Portal Chat only, never sent to customer channels (Vic/website Alice).
  // You can't see the screens or run the staff calculator yourself - this is so you can explain
  // them. Prices still come from your tools (compute_aquarium_quote etc.), never from here.
  const STAFF_TOOLS_GUIDE = [
    'STAFF PORTAL TOOLS GUIDE (internal Portal Chat only - for answering staff questions about how these pages work; you cannot see or operate them):',
    '',
    'AQUARIUM CALCULATOR (Calculators > Aquarium Calculator) - open to EVERY staff login, including Tank/Stand Makers, Dispatchers, Delivery Team and Online Order Staff (it is in their menu too):',
    '- Two tabs at the top: Calculator and Summary. The price panel on the right (Estimated price, volume, dimensions, Calculate / Add to sale / Glass Cut Sheet / Reset / View full summary) stays on screen while scrolling; the step bar at the top jumps between steps.',
    '- Steps: 1 Size & glass (L x W x H, unit, Quantity, Build type, glass thickness, sealant) - 2 Stand ("Include a stand" toggle, then layers, tubular, height override, footing, Stand quantity, Stainless/Cabinet/Canopy/Sump Holder, Cabinet / canopy type, Cabinet doors, Canopy height) - 3 Options (AIO, Low Iron, Tempered, Rimless, High Strip, Filtration sump, Aquascape, Enclosure, holes, dividers) - 4 Sump & extras (sump type/size/unit/sump glass/quantity, piping, overflow box, filter medias, submersible light/pump items, Allum top cover) - 5 Stickers & notes.',
    '- Build type is Aquarium only / Sump only. A full set is built from the parts (tick Filtration sump + Include a stand + extras). SUMP ONLY = a sump with no aquarium: the tank size/glass fields and steps 2 Stand, 3 Options and 5 Stickers & notes (and the Glass Cut Sheet) are hidden and it jumps to step 4, where staff pick Sump type (Undersump / Overhead Sump), size, sump glass, Sump quantity and extras (piping, overflow box, filter medias, light, pump, Allum top cover). It is priced exactly like the customer Order Now page\'s Customize > Filtration (sump glass + extras, no x1.9 markup), so staff and website quotes match. The old Undersump/Overheadsump build types (which priced the tank fields as a sump at x1.9) were removed. In GMA Conversations\' Create Order > Custom Aquarium, a Sump only quote adds one CUSTOM-SUMP line.',
    '- QUANTITIES are independent totals for the whole quote: total = aquarium price x Quantity + stand price x Stand quantity + one sump\'s price x Sump quantity. Stand quantity defaults to 1 and only changes when staff edit it (e.g. 4 tanks on 2 stands = 2). Sump quantity copies Quantity (4 tanks -> 4 sumps) until staff type their own number. (Before this fix, sump quantity was multiplied by the aquarium Quantity again - 4 tanks + 4 sumps billed 16 sumps - so older multi-tank sump quotes may be overpriced.)',
    '- SUMMARY card / Summary tab: lists the full spec and an itemized price - Aquarium Price (tank only), Stand Price (per stand), Sump Price (per sump) broken into: sump glass, filter medias, submersible pump/light (item and qty), overflow box (1,900), set of piping (540 overhead / 2,500 undersump), Allum top cover, plus a small Rounding line so the parts add up exactly. Glass/media/overflow/pump/light carry a x1.7 markup with Low Iron on an aquarium build (never on Sump only) (applied, but the markup is no longer written on the line); piping and top cover are never marked up. Every sump part (including piping and top cover) is per sump, so it follows Sump quantity.',
    '- Filter medias are priced at 300 per kg; the kg is an ESTIMATE from the sump volume (18% fill for overhead, 4% for undersump) and is shown as "approx. N kg, more or less" - tell staff/customers the actual weight can differ slightly.',
    '- The Summary tab is a printable quote sheet: total, key specs, safety notes, pictures of the aquarium and stand drawings, grouped specification, itemized prices and (optional, "Include glass cut sheet" toggle) the glass cut sheet. "Print / Save as PDF" prints just that sheet - untick the cut sheet before sending it to a customer.',
    '- All sizes on the calculators, drawings and summary show inches AND cm, e.g. 36" (91.4 cm). The glass cut sheet stays in inches with fractions (production measures in inches).',
    '- Glass size rules (shop standard): 3mm up to 24" long and ~15 gal. BRACED (normal, with top frame) 6mm: up to 20" tall and 20" wide - up to 72" long when 18" tall or less, up to 60" long when over 18" tall (72x18x18 and 60x20x20 are 6mm). 10mm: up to 24" tall, 24" wide, 72" long, 180 gal. Bigger than that, including ANY length over 72", needs 12mm; 48"+ tall needs 19mm. RIMLESS is stricter: 6mm from 10 gal, 10mm once 30 gal+ or over 15" tall / 20" wide / 48" long. Low Iron (forces Tempered) -> min 10mm; AIO -> min 6mm; width or height 36"+ -> Tempered.',
    '- Glass thickness AUTO-SETS to the thinnest safe glass whenever Length/Width/Height/Unit/Rimless change (it also steps back DOWN when the tank gets smaller), until staff pick a thickness by hand - then it stays, and only the safety rules can still raise it. Same in the local POS calculator.',
    '- Light and pump AUTO-PICK by tank length: light = the LIGHTS item with the matching size in its name (3FT/4FT/5FT/6FT); pump = A3000 under 4ft, A4000 from 4ft up. No match = left blank for staff to choose. They stop following once staff pick one by hand.',
    '- Sump Length defaults to the TANK length (both Undersump and Overhead) and follows it until staff type their own. Sump glass has its own thickness (default 6mm), priced at that thickness - not the tank glass.',
    '- CABINET & CANOPY (Stand step): Cabinet = front doors + both sides + closed back around the stand; Canopy = box cover on top of the tank (front, back, sides, top; default 6" high). Cabinet / canopy type: Laminated Plywood (18mm, default) or Aluminum (4mm ACP, pricier) - one type for both. Doors default to 2 per 3ft (3ft = 2, 6ft = 4), editable. Priced per sq ft of panel with a minimum each, plus door hardware per sq ft of door; the rates are set in Pricing Setup > Aquarium Extras (super users). The Summary shows Stand Frame / Cabinet / Canopy prices and their approx. OUTER size (cabinet = stand built length incl. end posts + 2 panels x width + 2 panels x stand height minus footing; canopy matches the cabinet). The preview draws the cabinet (with its doors) and canopy - wood tone for plywood, silver for aluminum.',
    '- The Total Price is the big bold line at the bottom of the Summary. There is NO cost/rate breakdown anywhere any more (removed on purpose) - only item prices and totals; never quote sheet costs or markups to anyone.',
    '- The separate Stand and Sticker calculators (Calculators menu) use the same layout: steps on the left, live price panel on the right.',
    '',
    'DELIVERY QUOTE (Delivery > Delivery Quote):',
    '- Left side: 1 Delivery method (In-House = our own driver, supports multiple drop-offs / Lalamove = sandbox test pricing, single drop-off only), 2 Route (green pin = pick-up branch or "Other address", red numbered pins = drop-off locations matching the map markers, "+ Add drop-off location"), 3 Contact details (Lalamove only: sender/recipient name and phone). Below that the blue price card: delivery price, distance, drive time, toll, and the fee breakdown (base fee + rate/km, multi-stop markup, toll). Right side: full-height map.',
    '- The price updates automatically whenever a field changes; Get Quote re-runs it. Book Delivery (Lalamove) is super users only and dispatches a real booking.',
    '',
    'CUSTOMER WEBSITE (rspetstop.com):',
    '- Homepage now has a sticky menu (What we offer, Shop, Custom builds, Visit us, Delivery fee, Order Now), clickable offer cards, Get directions / Call buttons per branch, and only links categories that are actually orderable online. Order Now deep links: order-now.html?start=standard / ?start=custom / ?start=delivery open that section directly.'
  ].join('\n');

  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    {
      type: 'text' as const,
      text: `INTERNAL PORTAL TEAM CHAT: you are talking with RS Pet Stop's own staff inside their internal Portal Chat, not a customer.${isGroup ? ' Multiple staff members may be in this conversation - each user message is prefixed with "Name: " so you know who is asking.' : ''} Keep answers short and direct like a quick chat reply, not a full customer-facing script. This is for internal reference/testing only, so no order, escalation, or CRM save you take here is real - it is simulated.`
    },
    {
      type: 'text' as const,
      text: 'MAKER NAMES (internal Portal Chat only): here, get_order_status production rows include maker_name (and maker_username) for each part - you MAY tell staff who the tank maker / stand maker / dispatcher is on an order (e.g. "Tank: Juan - done ✅, Stand: Pedro - still building"). This overrides the "never name the staff member" rule for this chat only. If maker_name is empty the part is not assigned yet.'
    },
    {
      // Reference for staff "how do I / why is it" questions about the portal tools. Keep in sync
      // when these pages change (see CHANGELOG.md) - Alice can't see the screens herself.
      type: 'text' as const,
      text: STAFF_TOOLS_GUIDE
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
