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

interface FacebookAttachment {
  type?: string;
  payload?: { url?: string };
}

interface FacebookWebhookBody {
  entry?: Array<{
    messaging?: Array<{
      sender?: { id: string };
      recipient?: { id: string };
      message?: { mid: string; text?: string; is_echo?: boolean; attachments?: FacebookAttachment[] };
      read?: { watermark: number };
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

// Returns whether Facebook actually accepted the message, so callers can record DeliveryStatus
// ('Sent'/'Failed') on the ChatbotMessages row - see processMessage below.
async function sendMessengerReply(psid: string, text: string, pageAccessToken: string, graphVersion: string): Promise<boolean> {
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
    return false;
  }
  return true;
}

// Marks every one of our own messages up to the customer's read watermark as seen - fired from a
// Messenger 'read' webhook event (requires the message_reads field to be checked under Messenger >
// Settings > Webhooks in the App Dashboard). Facebook's watermark is "the customer has read
// everything up to this timestamp", so it can mark several messages seen at once, not just the
// latest.
async function handleReadReceipt(supabase: SupabaseClient, psid: string | undefined, watermarkMs: number | undefined): Promise<void> {
  if (!psid || !watermarkMs) return;
  try {
    const watermarkIso = new Date(watermarkMs).toISOString();
    const { error } = await supabase
      .from('ChatbotMessages')
      .update({ SeenAtUtc: watermarkIso })
      .eq('Psid', psid)
      .in('Role', ['assistant', 'staff'])
      .is('SeenAtUtc', null)
      .lte('CreatedAtUtc', watermarkIso);
    if (!error) {
      await broadcastGmaEvent(supabase, psid);
    }
  } catch (err) {
    console.error('Failed to record read receipt:', err instanceof Error ? err.message : err);
  }
}

// User Profile API lookup - Facebook's webhook payload never includes the sender's name, only
// their Psid, so this is the only way to get it. Best-effort: swallows any failure (missing
// permission, deactivated profile, transient error) and just leaves CustomerName null rather than
// blocking the reply - the next inbound message tries again since the caller only calls this when
// CustomerName is still unset.
async function fetchFacebookProfileName(psid: string, pageAccessToken: string, graphVersion: string): Promise<string | null> {
  try {
    const url = `https://graph.facebook.com/${graphVersion}/${psid}?fields=first_name,last_name&access_token=${pageAccessToken}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const body = await res.json();
    const name = [body.first_name, body.last_name].filter(Boolean).join(' ').trim();
    return name || null;
  } catch (err) {
    console.error('Failed to fetch Facebook profile name:', err instanceof Error ? err.message : err);
    return null;
  }
}

// Downloads an inbound image attachment (e.g. a GCash payment screenshot) and re-hosts it in our
// own private 'chatbot-attachments' Storage bucket (see sql/supabase_chatbot_message_attachments.
// sql), rather than just keeping Facebook's own CDN url - that url isn't guaranteed to stay valid
// indefinitely, and the GMA Conversations inbox needs something durable to display. Only ever
// called for type:'image' attachments (video/audio/file/location are left alone entirely - still
// "out of v1 scope", same cut as before this existed). Best-effort: any failure here just means
// the attachment is dropped (falls back to text-only handling, or the whole event is dropped if
// there was no text either) - never blocks the rest of message processing.
async function storeChatbotAttachment(supabase: SupabaseClient, psid: string, sourceUrl: string): Promise<{ path: string; signedUrl: string; base64: string; contentType: string } | null> {
  try {
    const res = await fetch(sourceUrl);
    if (!res.ok) return null;

    const contentType = res.headers.get('content-type') || 'image/jpeg';
    const ext = contentType.includes('png') ? 'png' : contentType.includes('webp') ? 'webp' : contentType.includes('gif') ? 'gif' : 'jpg';
    const bytes = new Uint8Array(await res.arrayBuffer());
    const path = `${psid}/${Date.now()}.${ext}`;

    const { error: uploadError } = await supabase.storage
      .from('chatbot-attachments')
      .upload(path, bytes, { contentType, upsert: false });
    if (uploadError) {
      console.error('Failed to upload chatbot attachment:', uploadError.message);
      return null;
    }

    // 60-day expiry to match ChatbotMessages' own retention window (cron_cleanup_old_chatbot_
    // messages deletes both the row and the Storage object well before this URL would expire).
    const { data: signedData, error: signError } = await supabase.storage
      .from('chatbot-attachments')
      .createSignedUrl(path, 60 * 60 * 24 * 60);
    if (signError || !signedData?.signedUrl) {
      console.error('Failed to sign chatbot attachment URL:', signError?.message);
      return null;
    }

    // base64-encode the bytes we already have in memory, so extractPaymentDetails (below) can hand
    // this straight to Claude's vision input without re-downloading the image from Facebook's CDN a
    // second time. Chunked to stay under String.fromCharCode's argument-count limit on large images.
    let binary = '';
    const chunkSize = 8192;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    const base64 = btoa(binary);

    return { path, signedUrl: signedData.signedUrl, base64, contentType };
  } catch (err) {
    console.error('Failed to store chatbot attachment:', err instanceof Error ? err.message : err);
    return null;
  }
}

interface DetectedPayment {
  amount: number | null;
  method: string | null;
  reference: string | null;
  senderName: string | null;
  paymentDateText: string | null;
}

// Vision pass over a stored image attachment: is this a payment screenshot (GCash/Maya/bank
// transfer receipt) the customer sent, and if so what does it say? Purely a SUGGESTION surfaced to
// staff in the GMA Conversations inbox (a "Use in Add Payment" button that pre-fills the existing
// Add Payment form, admin_add_automated_order_payment) - never posted as a real payment
// automatically, since a misread amount or reference would corrupt an actual money record. Best-
// effort: any failure (bad JSON, API error, low confidence) just means no suggestion is shown - the
// photo itself is still saved and visible either way.
async function extractPaymentDetails(anthropic: Anthropic, model: string, base64: string, contentType: string): Promise<DetectedPayment | null> {
  try {
    const mediaType = (contentType.includes('png') ? 'image/png' : contentType.includes('webp') ? 'image/webp' : contentType.includes('gif') ? 'image/gif' : 'image/jpeg') as
      | 'image/jpeg'
      | 'image/png'
      | 'image/gif'
      | 'image/webp';

    const res = await anthropic.messages.create({
      model,
      max_tokens: 400,
      system:
        'You look at a single photo a customer sent to a pet store\'s Messenger chat and decide if it is a payment screenshot (e.g. GCash, Maya/PayMaya, bank transfer, or similar receipt/confirmation screen). Respond with ONLY a JSON object, no markdown code fences, no other text, in exactly this shape: {"is_payment_screenshot": boolean, "amount": number or null, "reference": string or null, "method": string or null, "sender_name": string or null, "payment_date_text": string or null}. "method" must be one of "GCash", "Maya", "Bank Transfer", "Other", or null. "payment_date_text" is the payment\'s date/time EXACTLY as displayed on the screenshot (e.g. "Nov 15, 2025 3:42 PM") - copy it verbatim, do not reformat/convert/guess a timezone; null if no date/time is visible. If the image is not a payment screenshot, or you are not reasonably confident, set is_payment_screenshot to false and leave the other fields null.',
      messages: [
        {
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mediaType, data: base64 } },
            { type: 'text', text: 'Is this a payment screenshot? Extract the details as instructed.' }
          ]
        }
      ]
    });

    const block = res.content.find((b) => b.type === 'text');
    if (!block || block.type !== 'text') {
      console.error('Payment vision pass returned no text block; stop_reason:', res.stop_reason);
      return null;
    }

    // Extract the {...} substring rather than assuming the whole response is pure JSON - despite
    // the "ONLY a JSON object" instruction, the model occasionally prefaces it with a stray word or
    // sentence (e.g. when the image contains partially-redacted personal/financial info), which
    // would otherwise fail JSON.parse and silently drop a real detection.
    const rawText = block.text.trim();
    const jsonStart = rawText.indexOf('{');
    const jsonEnd = rawText.lastIndexOf('}');
    if (jsonStart === -1 || jsonEnd === -1 || jsonEnd < jsonStart) {
      console.error('Payment vision pass returned no JSON object. Raw response:', rawText);
      return null;
    }

    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(rawText.slice(jsonStart, jsonEnd + 1));
    } catch (parseErr) {
      console.error('Payment vision pass returned unparseable JSON:', parseErr instanceof Error ? parseErr.message : parseErr, 'Raw response:', rawText);
      return null;
    }
    if (!parsed?.is_payment_screenshot) return null;

    const amount = typeof parsed.amount === 'number' && Number.isFinite(parsed.amount) ? parsed.amount : null;
    return {
      amount,
      method: typeof parsed.method === 'string' ? parsed.method : null,
      reference: typeof parsed.reference === 'string' ? parsed.reference : null,
      senderName: typeof parsed.sender_name === 'string' ? parsed.sender_name : null,
      paymentDateText: typeof parsed.payment_date_text === 'string' ? parsed.payment_date_text : null
    };
  } catch (err) {
    console.error('Failed to extract payment details from attachment:', err instanceof Error ? err.message : err);
    return null;
  }
}

interface OrderSummaryLine {
  itemName: string;
  quantity: number;
}

interface OrderSummary {
  orderNo: string;
  // Pancake's own short order id (AutomatedOrders.PancakeOrderId, e.g. "91364") - null until the
  // order has synced to Pancake. Just the id, never the order_link - see receiptUrl below.
  pancakeOrderId: string | null;
  status: string;
  totalProducts: number;
  estimatedTotal: number;
  balance: number;
  lines: OrderSummaryLine[];
  // Portal-rendered receipt page, NOT Pancake's own order_link - per direct decision, the bot
  // never shares the Pancake link with customers. Built client-side from orderNo (no DB column
  // needed) since docs/online-order-receipt.html's public_get_order_receipt RPC (see
  // sql/supabase_automated_order_portal_receipt.sql) reads straight from AutomatedOrders by
  // OrderNo - works the instant an order is created, with no dependency on it having synced back
  // from Pancake into OnlineOrders yet.
  receiptUrl: string;
}

// Looks up the customer's most recent Automated Order created from THIS GMA conversation (matches
// admin_list_automated_orders_by_gma_conversation's own GmaPsid+GmaPageId/CreatedAtUtc-desc
// convention - sql/supabase_gma_conversation_order_details.sql), so a payment-screenshot ack can
// include a real order summary instead of a generic "thanks". Returns null if the conversation has
// no order yet (e.g. customer paid before staff turned the chat into an order) - the caller falls
// back to the plain ack in that case. Reads tables directly via the service-role client, same as
// the rest of this file - no admin_* RPC needed since there's no staff username/password here.
async function findLatestOrderSummary(supabase: SupabaseClient, psid: string, pageId: string): Promise<OrderSummary | null> {
  const { data: order } = await supabase
    .from('AutomatedOrders')
    .select('OrderNo, EstimatedTotal, Status, PancakeOrderId')
    .eq('GmaPsid', psid)
    .eq('GmaPageId', pageId)
    .order('CreatedAtUtc', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!order) return null;

  const [{ data: lines }, { data: payments }] = await Promise.all([
    supabase.from('AutomatedOrderLines').select('ItemName, Quantity').eq('OrderNo', order.OrderNo),
    supabase.from('AutomatedOrderPayments').select('Amount').eq('OrderNo', order.OrderNo)
  ]);

  const totalProducts = (lines ?? []).reduce((sum: number, l: { Quantity: number }) => sum + (l.Quantity ?? 0), 0);
  const amountPaid = (payments ?? []).reduce((sum: number, p: { Amount: number }) => sum + Number(p.Amount ?? 0), 0);
  const estimatedTotal = Number(order.EstimatedTotal ?? 0);
  const orderLines = (lines ?? []).map((l: { ItemName: string; Quantity: number }) => ({ itemName: l.ItemName, quantity: l.Quantity ?? 0 }));

  return {
    orderNo: order.OrderNo,
    pancakeOrderId: order.PancakeOrderId ?? null,
    status: order.Status ?? 'New',
    totalProducts,
    estimatedTotal,
    balance: estimatedTotal - amountPaid,
    lines: orderLines,
    receiptUrl: `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(order.OrderNo)}`
  };
}

// Renders the itemized "🛒 Products:" block shared by both the payment-screenshot receipt and the
// confirmation-request message below, so the two stay in sync automatically.
function formatOrderLines(lines: OrderSummaryLine[]): string {
  return lines.map((l) => `  - ${l.itemName} x${l.quantity}`).join('\n');
}

// Loose intent check for "yes, everything's correct" replies to the receipt-confirmation prompt
// below - deliberately narrow (whole-message match, not a substring search) so an unrelated message
// that happens to contain "ok" somewhere doesn't get misread as a confirmation. Covers common
// English/Tagalog affirmatives customers actually type; anything else (a correction, a question,
// "no wait...") falls through to the normal AI turn instead of being treated as a confirmation.
function isAffirmativeReply(text: string): boolean {
  const normalized = text.trim().toLowerCase().replace(/[.!?]+$/, '');
  return /^(yes+|yep|yup|yeah|correct|that'?s correct|all correct|tama|tama po|sige|sige po|oo|oo po|opo|confirm|confirmed|ok|okay|okay po|ok po|right|all good|good to go)$/.test(normalized);
}

// Classifies a reply to "is this payment for your existing order, or a new one?" (asked - see
// below - whenever a payment screenshot arrives and this conversation already has a prior order,
// rather than silently guessing which one it's for, per direct instruction). Deliberately narrow
// keyword matching; anything it can't confidently read returns null, which falls through to the
// normal AI turn instead of the bot guessing wrong.
function classifyOrderClarificationReply(text: string): 'existing' | 'new' | null {
  const normalized = text.trim().toLowerCase();
  if (/\b(new|bago|different|iba|separate|another|panibago)\b/.test(normalized)) return 'new';
  if (/\b(existing|same|current|that order|this order|my order|dati|yun na|meron na|old order)\b/.test(normalized) || /\bao-\d+\b/i.test(normalized)) return 'existing';
  return null;
}

// Shared by every ack path below (the plain no-caption ack, and both branches of the payment-
// clarification reply) - saves/broadcasts/sends one assistant message the same way every time:
// optionally flags an order as awaiting the "reply YES" receipt confirmation, inserts the
// ChatbotMessages row, bumps ChatbotConversations' timestamps, broadcasts for the live inbox, then
// actually sends it via Messenger and records delivery status.
async function sendAckMessage(
  supabase: SupabaseClient,
  psid: string,
  pageAccessToken: string,
  graphVersion: string,
  ack: string,
  confirmationRequestedOrderNo: string | null
): Promise<void> {
  if (confirmationRequestedOrderNo) {
    await supabase
      .from('AutomatedOrders')
      .update({ ReceiptConfirmationRequestedAtUtc: new Date().toISOString() })
      .eq('OrderNo', confirmationRequestedOrderNo);
  }
  const { data: ackRow } = await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: ack }).select('Id').single();
  await supabase
    .from('ChatbotConversations')
    .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
    .eq('Psid', psid);
  await broadcastGmaEvent(supabase, psid);
  await new Promise((resolve) => setTimeout(resolve, REPLY_DELAY_MS));
  const delivered = await sendMessengerReply(psid, ack, pageAccessToken, graphVersion);
  if (ackRow?.Id) {
    await supabase.from('ChatbotMessages').update({ DeliveryStatus: delivered ? 'Sent' : 'Failed' }).eq('Id', ackRow.Id);
    await broadcastGmaEvent(supabase, psid);
  }
}

// Builds the itemized-receipt-and-ask (New, unconfirmed order) or plain summary (any other status)
// ack text for a known order + payment - shared by the no-caption path (a freshly auto-created
// order) and the payment-clarification "existing" branch (the customer said this payment is for
// their existing order after all), so both stay in sync automatically.
function buildOrderPaymentAck(orderSummary: OrderSummary, paymentLine: string): { ack: string; confirmationRequestedOrderNo: string | null } {
  // Portal-rendered receipt (docs/online-order-receipt.html), NOT Pancake's own order_link - per
  // direct decision, the bot never shares Pancake's link with customers. Always present (built
  // from orderNo, no sync dependency - see the OrderSummary.receiptUrl comment above).
  const receiptLinkLine = `\n📄 Order Confirmation: ${orderSummary.receiptUrl}\n`;
  // Only the id (e.g. "#91364"), never Pancake's order_link. Null until the order has synced -
  // omitted rather than shown blank in that case.
  const onlineOrderIdLine = orderSummary.pancakeOrderId ? `🧾 Online Order ID: #${orderSummary.pancakeOrderId}\n` : '';
  if (orderSummary.status === 'New') {
    return {
      confirmationRequestedOrderNo: orderSummary.orderNo,
      ack: 'Thanks for the payment! Here\'s your order confirmation receipt - please check everything below:\n\n' +
        `📋 Order No: ${orderSummary.orderNo}\n` +
        onlineOrderIdLine +
        `🛒 Products:\n${formatOrderLines(orderSummary.lines)}\n` +
        `💰 Total amount: ₱${orderSummary.estimatedTotal.toFixed(2)}\n` +
        `💳 Payment: ${paymentLine}\n` +
        `📌 Balance remaining: ₱${orderSummary.balance.toFixed(2)}\n` +
        receiptLinkLine + '\n' +
        'Is everything above correct? Reply YES to confirm so our team can finalize your order. \u{1F60A}'
    };
  }
  return {
    confirmationRequestedOrderNo: null,
    ack: 'Thanks for the payment screenshot! Here\'s your order summary:\n\n' +
      `📋 Order No: ${orderSummary.orderNo}\n` +
      onlineOrderIdLine +
      `🛒 Products:\n${formatOrderLines(orderSummary.lines)}\n` +
      `💰 Total amount: ₱${orderSummary.estimatedTotal.toFixed(2)}\n` +
      `💳 Payment: ${paymentLine}\n` +
      `📌 Balance remaining: ₱${orderSummary.balance.toFixed(2)}\n` +
      receiptLinkLine + '\n' +
      'Our team will verify this shortly! \u{1F60A}'
  };
}

// Its own uncached system block, same reasoning as buildCurrentTimeLine (differs per conversation,
// so keeping it out of the cached persona block preserves the cache hit rate for everything else).
// Lets create_order's "offer to use their Facebook name" behavior (chatbot-engine.ts's PLACING
// ORDERS rules) actually work - ChatbotConversations.CustomerName (fetchFacebookProfileName, set
// earlier in processMessage) was never otherwise surfaced to Claude at all.
function buildCustomerNameLine(customerName: string | null | undefined): string {
  return customerName
    ? `CUSTOMER'S FACEBOOK NAME: ${customerName}`
    : "CUSTOMER'S FACEBOOK NAME: unknown - ask for a name instead.";
}

// Its own uncached system block, used only by attemptAutoCreateOrderFromPayment below. A dedicated
// block (rather than appending to the last message's content, which was this function's original
// approach) works correctly regardless of what the customer's actual last message was - a photo
// with no caption (the normal case), or a plain text "new"/"existing" reply to the payment-
// clarification question (facebook-messenger-webhook/index.ts's PendingPaymentClarification* flow),
// where the payment being described isn't the literal last message at all.
function buildDetectedPaymentLine(detectedPayment: DetectedPayment): string {
  return `DETECTED PAYMENT: The customer has sent proof of payment - ₱${detectedPayment.amount?.toFixed(2)} via ${detectedPayment.method || 'an unspecified method'}` +
    `${detectedPayment.reference ? `, Ref: ${detectedPayment.reference}` : ''}${detectedPayment.paymentDateText ? `, dated ${detectedPayment.paymentDateText}` : ''}. ` +
    'If you already know the customer\'s full name, phone number, address, and exact items/quantities (real item_code values only, from this conversation) call create_order now. Otherwise ask the customer for whatever is still missing.';
}

// Called from the no-caption/payment-screenshot ack path (below) ONLY when this conversation has no
// order yet - lets the bot place one itself (the create_order tool, chatbot-engine.ts) rather than
// always falling back to a plain "our team will confirm" ack, per direct request. Runs one bounded,
// full AI turn (same persona/tools/rules as a normal reply, via runChatbotTurn) rather than a
// separate bespoke extraction pass, so Claude's own judgment (does it actually know the items,
// customer details, and has payment really been sent?) decides whether to call create_order - never
// forced or assumed here. The caller re-checks findLatestOrderSummary afterward rather than trusting
// a return value from the tool call itself, since that's the same ground truth every other part of
// this file already uses.
async function attemptAutoCreateOrderFromPayment(
  supabase: SupabaseClient,
  anthropic: Anthropic,
  model: string,
  pageAccessToken: string,
  graphVersion: string,
  psid: string,
  pageId: string,
  detectedPayment: DetectedPayment,
  customerName: string | null | undefined
): Promise<{ created: boolean; finalText: string }> {
  // Captured BEFORE the AI turn so success can be judged by "did the order number actually change"
  // rather than merely "does an order exist now" - this function can be called when an order
  // ALREADY exists (the payment-clarification "new" branch above), where the latter check would
  // always be true regardless of whether create_order actually ran.
  const orderBefore = await findLatestOrderSummary(supabase, psid, pageId);

  const { data: historyRows } = await supabase
    .from('ChatbotMessages')
    .select('Role, Content')
    .eq('Psid', psid)
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

  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    { type: 'text' as const, text: buildCustomerNameLine(customerName) },
    { type: 'text' as const, text: buildDetectedPaymentLine(detectedPayment) }
  ];
  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;

  const finalText = await runChatbotTurn({
    supabase,
    anthropic,
    model: effectiveModel,
    psid,
    pageId,
    messages,
    followUpSettings,
    aiSettings,
    systemBlocks,
    simulate: false,
    pageAccessToken,
    graphVersion
  });

  const orderAfter = await findLatestOrderSummary(supabase, psid, pageId);
  return { created: orderAfter !== null && orderAfter.orderNo !== orderBefore?.orderNo, finalText };
}

// Live-updates docs/gma-conversations.html (the GMA Conversations inbox) without polling - fired
// after every ChatbotMessages insert (inbound customer message, bot reply, or a staff reply via
// chatbot-staff-reply) so any open browser tab refreshes instantly. Broadcast, not postgres_changes
// - ChatbotConversations/ChatbotMessages have zero anon RLS policies (this app uses its own staff
// username/password auth, not Supabase Auth, so everything else goes through is_admin_authorized-
// gated RPCs instead of direct table reads), and a postgres_changes subscription is gated by that
// same RLS - it would just never fire. Broadcast sidesteps that: it's channel-based, not
// table-read-based, so the service-role client here can freely push into the same channel name the
// browser subscribes to. Mirrors docs/js/chat.js's chatInboxBroadcast - the only other place in
// this codebase already doing Realtime Broadcast - which found the same thing: send() only works
// once the channel is actually SUBSCRIBED, so this subscribes, sends, and tears down every call
// rather than holding a channel open across invocations (this function runs fresh per request).
// Best-effort: never lets a broadcast failure affect the real work (message already saved either
// way) - a missed live-update just means staff sees it on their next manual Refresh instead.
async function broadcastGmaEvent(supabase: SupabaseClient, psid: string): Promise<void> {
  try {
    const channel = supabase.channel('gma-inbox');
    await new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      const timer = setTimeout(finish, 3000);
      channel.subscribe((status: string) => {
        if (status === 'SUBSCRIBED' && !settled) {
          clearTimeout(timer);
          channel.send({ type: 'broadcast', event: 'new_message', payload: { psid } }).finally(finish);
        }
      });
    });
    await channel.unsubscribe();
  } catch (err) {
    console.error('Failed to broadcast GMA inbox event:', err instanceof Error ? err.message : err);
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
  text: string | undefined,
  mid: string,
  attachments: FacebookAttachment[] | undefined
): Promise<void> {
  // Insert-if-missing only - LastMessageAtUtc/Status are updated below, never overwritten here.
  await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: pageId }, { onConflict: 'Psid', ignoreDuplicates: true });

  // Only the FIRST image attachment is stored - Facebook's FacebookMessageId unique index only
  // allows one ChatbotMessages row per mid, so multiple attachments on one event can't each get
  // their own row without violating that constraint. In practice a customer sending several
  // photos almost always does so as separate messages/events (each with its own mid) anyway, so
  // this only ever discards anything in the rare multi-attachment-in-one-event case.
  const imageAttachment = attachments?.find((a) => a.type === 'image' && a.payload?.url);
  let attachmentPath: string | null = null;
  let attachmentUrl: string | null = null;
  let attachmentType: string | null = null;
  let detectedPayment: DetectedPayment | null = null;

  if (imageAttachment?.payload?.url) {
    const stored = await storeChatbotAttachment(supabase, psid, imageAttachment.payload.url);
    if (stored) {
      attachmentPath = stored.path;
      attachmentUrl = stored.signedUrl;
      attachmentType = 'image';
      detectedPayment = await extractPaymentDetails(anthropic, model, stored.base64, stored.contentType);
    }
  }

  const trimmedText = text?.trim() || '';
  // A stored photo with no caption still needs SOME Content (ChatbotMessages.Content is NOT
  // NULL) - a placeholder that reads sensibly in the GMA inbox thread even without the actual
  // image rendering (e.g. if AttachmentUrl ever fails to load).
  const messageContent = trimmedText || (attachmentUrl ? '[Photo]' : '');
  if (!messageContent) return; // no text and no attachment we could store - nothing to record

  const { error: insertErr } = await supabase
    .from('ChatbotMessages')
    .insert({
      Psid: psid,
      Role: 'user',
      Content: messageContent,
      FacebookMessageId: mid,
      AttachmentPath: attachmentPath,
      AttachmentUrl: attachmentUrl,
      AttachmentType: attachmentType,
      DetectedPaymentAmount: detectedPayment?.amount ?? null,
      DetectedPaymentMethod: detectedPayment?.method ?? null,
      DetectedPaymentReference: detectedPayment?.reference ?? null,
      DetectedPaymentSenderName: detectedPayment?.senderName ?? null,
      DetectedPaymentAtText: detectedPayment?.paymentDateText ?? null
    });
  if (insertErr) {
    if (insertErr.code === '23505') return; // Facebook redelivered a message we already processed.
    console.error('Failed to record inbound chatbot message:', insertErr.message);
  }

  await broadcastGmaEvent(supabase, psid);

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
  const { data: convState } = await supabase.from('ChatbotConversations').select('IsPaused, CustomerName').eq('Psid', psid).maybeSingle();

  // Backfills CustomerName for both brand-new conversations and older ones that predate this
  // column - runs regardless of pause state so a paused conversation still gets a name attached.
  if (!convState?.CustomerName) {
    const fetchedName = await fetchFacebookProfileName(psid, pageAccessToken, graphVersion);
    if (fetchedName) {
      await supabase.from('ChatbotConversations').update({ CustomerName: fetchedName }).eq('Psid', psid);
    }
  }

  if (convState?.IsPaused) return;

  // Reply to a pending "is this payment for your existing order, or a new one?" question (asked
  // below whenever a payment screenshot arrives and this conversation already has a prior order -
  // per direct instruction, rather than silently assuming it belongs to that order). Checked before
  // the receipt-confirmation reply below since it's asked at an earlier point in the exchange.
  if (trimmedText) {
    const { data: convClarification } = await supabase
      .from('ChatbotConversations')
      .select('PendingPaymentClarificationOrderNo, PendingPaymentClarificationAmount, PendingPaymentClarificationMethod, PendingPaymentClarificationReference, PendingPaymentClarificationRequestedAtUtc')
      .eq('Psid', psid)
      .maybeSingle();

    if (convClarification?.PendingPaymentClarificationOrderNo && convClarification.PendingPaymentClarificationRequestedAtUtc) {
      // Same staleness guard as the receipt-confirmation reply below - only the very first customer
      // message since this was asked counts as answering it.
      const { count: repliesSinceAsk } = await supabase
        .from('ChatbotMessages')
        .select('Id', { count: 'exact', head: true })
        .eq('Psid', psid)
        .eq('Role', 'user')
        .gt('CreatedAtUtc', convClarification.PendingPaymentClarificationRequestedAtUtc);

      if (repliesSinceAsk === 1) {
        const classification = classifyOrderClarificationReply(trimmedText);
        if (classification) {
          await supabase
            .from('ChatbotConversations')
            .update({
              PendingPaymentClarificationOrderNo: null,
              PendingPaymentClarificationAmount: null,
              PendingPaymentClarificationMethod: null,
              PendingPaymentClarificationReference: null,
              PendingPaymentClarificationRequestedAtUtc: null
            })
            .eq('Psid', psid);

          const paymentLine = `₱${Number(convClarification.PendingPaymentClarificationAmount).toFixed(2)} via ${convClarification.PendingPaymentClarificationMethod || 'payment'}` +
            `${convClarification.PendingPaymentClarificationReference ? ` (Ref: ${convClarification.PendingPaymentClarificationReference})` : ''} - To be confirmed by staff`;

          if (classification === 'existing') {
            const orderSummary = await findLatestOrderSummary(supabase, psid, pageId);
            const { ack, confirmationRequestedOrderNo } = orderSummary
              ? buildOrderPaymentAck(orderSummary, paymentLine)
              : { ack: 'Got it - thanks! Our team will apply this payment and follow up shortly. \u{1F60A}', confirmationRequestedOrderNo: null };
            await sendAckMessage(supabase, psid, pageAccessToken, graphVersion, ack, confirmationRequestedOrderNo);
          } else {
            // 'new' - same auto-create attempt the no-caption path uses, fed the ORIGINAL detected
            // payment (this reply is just "new", not the screenshot itself).
            const detectedPayment: DetectedPayment = {
              amount: convClarification.PendingPaymentClarificationAmount,
              method: convClarification.PendingPaymentClarificationMethod,
              reference: convClarification.PendingPaymentClarificationReference,
              senderName: null,
              paymentDateText: null
            };
            const autoCreateResult = await attemptAutoCreateOrderFromPayment(
              supabase, anthropic, model, pageAccessToken, graphVersion, psid, pageId, detectedPayment, convState?.CustomerName
            );
            const newOrderSummary = autoCreateResult.created ? await findLatestOrderSummary(supabase, psid, pageId) : null;
            const { ack, confirmationRequestedOrderNo } = newOrderSummary
              ? buildOrderPaymentAck(newOrderSummary, paymentLine)
              : { ack: autoCreateResult.finalText || `Thanks! I see ${paymentLine} - our team will confirm and log it shortly. \u{1F60A}`, confirmationRequestedOrderNo: null };
            await sendAckMessage(supabase, psid, pageAccessToken, graphVersion, ack, confirmationRequestedOrderNo);
          }
          return;
        }
      }
    }
  }

  // Reply to a pending "is your order receipt correct?" prompt (see ReceiptConfirmationRequestedAtUtc
  // above, set when the itemized receipt was sent) - checked before the normal AI turn so a simple
  // "yes" doesn't need a full Claude round trip and can't get misrouted into unrelated small talk.
  // Only ever intercepts an exact affirmative reply (isAffirmativeReply) on the customer's MOST
  // RECENT order while it's still 'New' and genuinely awaiting exactly this confirmation; anything
  // else (a correction, a question, "no") falls through to the normal AI-driven conversation below.
  if (trimmedText) {
    const { data: pendingOrder } = await supabase
      .from('AutomatedOrders')
      .select('OrderNo, Status, ReceiptConfirmationRequestedAtUtc, ReceiptConfirmedAtUtc')
      .eq('GmaPsid', psid)
      .eq('GmaPageId', pageId)
      .order('CreatedAtUtc', { ascending: false })
      .limit(1)
      .maybeSingle();

    // Guards against a STALE match: without this, an old unconfirmed order's receipt prompt (e.g.
    // the customer never replied, then came back days/messages later and happened to say "opo"/"ok"
    // to something completely unrelated) would wrongly get treated as confirming it. Only counts as
    // "awaiting" when this inbound message is the very FIRST customer reply since
    // ReceiptConfirmationRequestedAtUtc was set - i.e. nothing else was said in between.
    let isFirstReplySincePrompt = false;
    if (pendingOrder?.ReceiptConfirmationRequestedAtUtc) {
      const { count: repliesSincePrompt } = await supabase
        .from('ChatbotMessages')
        .select('Id', { count: 'exact', head: true })
        .eq('Psid', psid)
        .eq('Role', 'user')
        .gt('CreatedAtUtc', pendingOrder.ReceiptConfirmationRequestedAtUtc);
      isFirstReplySincePrompt = repliesSincePrompt === 1; // just this current message
    }

    if (
      pendingOrder &&
      pendingOrder.Status === 'New' &&
      pendingOrder.ReceiptConfirmationRequestedAtUtc &&
      !pendingOrder.ReceiptConfirmedAtUtc &&
      isFirstReplySincePrompt &&
      isAffirmativeReply(trimmedText)
    ) {
      // This IS the "pass to staff for order id confirmation" step: staff already see every 'New'
      // order in GMA Conversations, but ReceiptConfirmedAtUtc now flags this one as customer-
      // confirmed and ready, surfaced as a badge on its order card (renderConversationOrderCards in
      // js/gmaConversations.js) right next to the existing Confirm-in-Pancake button.
      await supabase
        .from('AutomatedOrders')
        .update({ ReceiptConfirmedAtUtc: new Date().toISOString() })
        .eq('OrderNo', pendingOrder.OrderNo);

      const confirmAck = `Perfect, thanks for confirming Order No: ${pendingOrder.OrderNo}! \u{2705} We've passed it to our team to finalize - you'll hear from us shortly.`;
      await sendAckMessage(supabase, psid, pageAccessToken, graphVersion, confirmAck, null);
      return;
    }
  }

  // A photo with no caption has nothing for Claude to meaningfully respond to (no product/order
  // question to answer) - acknowledge it and hand off to staff (who can see it inline in the GMA
  // Conversations inbox, e.g. to verify a GCash payment screenshot) rather than running a full AI
  // turn over a placeholder "[Photo]" prompt.
  if (!trimmedText && attachmentUrl) {
    let ack: string;
    let confirmationRequestedOrderNo: string | null = null;
    if (detectedPayment?.amount != null) {
      const existingOrderSummary = await findLatestOrderSummary(supabase, psid, pageId);

      if (existingOrderSummary) {
        // A prior order already exists for this conversation - per direct instruction, ASK the
        // customer whether this payment is for that order or a new one, rather than silently
        // assuming either way (assuming "existing" would wrongly attach an unrelated new purchase's
        // payment to an old order; assuming "new" would wrongly spin up a duplicate for what's
        // really just a balance payment). PendingPaymentClarification* on ChatbotConversations
        // remembers the detected payment until the customer answers (handled above, before the
        // receipt-confirmation reply check).
        ack = `Just to confirm - I see you already have Order No: ${existingOrderSummary.orderNo}. Is this payment for that order, or is it for a NEW order you're asking about? \u{1F60A}`;
        await supabase
          .from('ChatbotConversations')
          .update({
            PendingPaymentClarificationOrderNo: existingOrderSummary.orderNo,
            PendingPaymentClarificationAmount: detectedPayment.amount,
            PendingPaymentClarificationMethod: detectedPayment.method,
            PendingPaymentClarificationReference: detectedPayment.reference,
            PendingPaymentClarificationRequestedAtUtc: new Date().toISOString()
          })
          .eq('Psid', psid);
      } else {
        // No order exists for this conversation yet - let the bot try to place one itself (the
        // create_order tool, chatbot-engine.ts) using whatever items/customer details are already
        // established in the conversation, now that a downpayment/payment has actually arrived.
        // Runs a full AI turn (not a canned reply) specifically so Claude can judge whether it has
        // everything required; falls through to the plain ack below if it doesn't.
        const paymentLine = `₱${detectedPayment.amount.toFixed(2)} via ${detectedPayment.method || 'payment'}${detectedPayment.reference ? ` (Ref: ${detectedPayment.reference})` : ''} - To be confirmed by staff`;
        const autoCreateResult = await attemptAutoCreateOrderFromPayment(
          supabase, anthropic, model, pageAccessToken, graphVersion, psid, pageId, detectedPayment, convState?.CustomerName
        );
        const newOrderSummary = autoCreateResult.created ? await findLatestOrderSummary(supabase, psid, pageId) : null;

        if (newOrderSummary) {
          ({ ack, confirmationRequestedOrderNo } = buildOrderPaymentAck(newOrderSummary, paymentLine));
        } else if (autoCreateResult.finalText) {
          // The bot tried to place an order itself and couldn't (missing info, or it judged the
          // conversation wasn't ready) - Claude's own reply already explains what's still needed, so
          // use that instead of the generic ack.
          ack = autoCreateResult.finalText;
        } else {
          ack = `Thanks for the payment screenshot! I see ${paymentLine} - our team will confirm and log it shortly. \u{1F60A}`;
        }
      }
    } else {
      ack = "Thanks for sending that! Someone from our team will take a look and follow up if needed. \u{1F60A}";
    }
    await sendAckMessage(supabase, psid, pageAccessToken, graphVersion, ack, confirmationRequestedOrderNo);
    return;
  }

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
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) },
    { type: 'text' as const, text: buildCustomerNameLine(convState?.CustomerName) }
  ];

  // AiSettings.AiModel (portal-editable, see ai-bot-setup.html) overrides the env/default model
  // when set, so the store owner can switch models without a code deploy.
  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;

  const finalText = await runChatbotTurn({
    supabase,
    anthropic,
    model: effectiveModel,
    psid,
    pageId,
    messages,
    followUpSettings,
    aiSettings,
    systemBlocks,
    simulate: false,
    pageAccessToken,
    graphVersion
  });

  const { data: replyRow } = await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: finalText }).select('Id').single();
  await supabase
    .from('ChatbotConversations')
    .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
    .eq('Psid', psid);
  await broadcastGmaEvent(supabase, psid);

  await new Promise((resolve) => setTimeout(resolve, REPLY_DELAY_MS));
  const replyDelivered = await sendMessengerReply(psid, finalText, pageAccessToken, graphVersion);
  if (replyRow?.Id) {
    await supabase.from('ChatbotMessages').update({ DeliveryStatus: replyDelivered ? 'Sent' : 'Failed' }).eq('Id', replyRow.Id);
    await broadcastGmaEvent(supabase, psid);
  }
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
        if (evt.read) {
          // Read receipt (requires the message_reads field checked under Messenger > Settings >
          // Webhooks) - not a message, handled separately and doesn't go through processMessage.
          try {
            await handleReadReceipt(supabase, evt.sender?.id, evt.read.watermark);
          } catch (err) {
            console.error('Error processing read receipt:', err instanceof Error ? err.message : err);
          }
          continue;
        }
        if (evt.message?.is_echo) continue; // the page's own message, echoed back - skip to avoid a reply loop
        const text = evt.message?.text;
        const attachments = evt.message?.attachments;
        const psid = evt.sender?.id;
        const pageId = evt.recipient?.id;
        const mid = evt.message?.mid;
        // A message needs text AND/OR an image attachment to be worth processing - postbacks and
        // non-image attachments (video/audio/file/location) are still out of scope.
        if ((!text && !(attachments && attachments.length > 0)) || !psid || !pageId || !mid) continue;

        try {
          await processMessage(supabase, anthropic, model, pageAccessToken, graphVersion, pageId, psid, text, mid, attachments);
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
