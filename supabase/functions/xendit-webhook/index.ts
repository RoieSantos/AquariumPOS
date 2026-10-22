// Xendit invoice webhook ("Invoices paid" callback) - marks the XenditPayments row Paid / Expired and
// applies a paid invoice to its order (_xendit_record_invoice_status, sql/supabase_xendit_payments.sql).
//
// Trust: the x-callback-token header must equal XENDIT_CALLBACK_TOKEN, AND the invoice is re-read from
// Xendit's own API before anything is recorded - the posted body is never taken at its word.
// Idempotent: Xendit retries a webhook until it gets a 2xx, and a repeated PAID never pays twice.
//
// Secrets (`npx supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   XENDIT_SECRET_KEY      - same key as xendit-create-invoice (test or live).
//   XENDIT_CALLBACK_TOKEN  - Xendit Dashboard > Settings > Webhooks > "View webhook verification token".
//                             Test and live mode have DIFFERENT tokens - swap it with the key at go-live.
//
// Xendit Dashboard > Settings > Webhooks > Invoices > "Invoices paid", in TEST mode now (and again in LIVE
// mode at go-live):  https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/xendit-webhook
//
// After a payment is applied, the customer gets a "payment received" message on the order's Messenger
// chat (sendReceiptMessage below; uses the FACEBOOK_PAGE_ACCESS_TOKEN / FACEBOOK_PAGE_TOKENS secrets the
// Messenger bot already has). Test payments are only logged in the thread, never sent.
//
// Deploy: npx supabase functions deploy xendit-webhook --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { getPageAccessToken } from '../_shared/page-tokens.ts';

const XENDIT_API = 'https://api.xendit.co';
const DEFAULT_GRAPH_VERSION = 'v21.0';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

// Claims the payment's receipt message (once per payment - sql/supabase_xendit_payment_receipt_message.sql)
// and sends it on the order's Messenger chat. Test payments are only saved in the thread, never sent.
async function sendReceiptMessage(supabase: ReturnType<typeof createClient>, paymentId: string): Promise<void> {
  const { data: rows, error } = await supabase.rpc('_xendit_claim_receipt_message', { p_payment_id: paymentId });
  if (error) throw new Error(error.message);
  const claim = rows?.[0];
  if (!claim) return;
  if (!claim.is_test) {
    const token = getPageAccessToken(claim.page_id ?? null);
    const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
    let status = 'Failed: no Facebook Page token';
    let mid: string | null = null;
    if (token) {
      const send = (extra: Record<string, unknown>) => fetch(`https://graph.facebook.com/${graphVersion}/me/messages?access_token=${token}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ recipient: { id: claim.psid }, message: { text: claim.message }, ...extra })
      }).then(async (res) => ({ ok: res.ok, body: await res.json().catch(() => null) }));
      // Normal reply first; outside Facebook's 24h window a payment receipt is a post-purchase update.
      let result = await send({ messaging_type: 'RESPONSE' });
      if (!result.ok) result = await send({ messaging_type: 'MESSAGE_TAG', tag: 'POST_PURCHASE_UPDATE' });
      status = result.ok ? 'Sent' : `Failed: ${result.body?.error?.message || 'Facebook refused the message'}`;
      mid = result.ok ? (result.body?.message_id ?? null) : null;
    }
    await supabase.rpc('_xendit_set_receipt_message_status', { p_payment_id: paymentId, p_status: status, p_facebook_mid: mid });
  }
  await broadcastGmaEvent(claim.psid);
}

// Live-updates any open Conversations tab (same 'gma-inbox' broadcast as chatbot-staff-reply).
async function broadcastGmaEvent(psid: string): Promise<void> {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return;
  await fetch(`${url}/realtime/v1/api/broadcast`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: key, Authorization: `Bearer ${key}` },
    body: JSON.stringify({ messages: [{ topic: 'gma-inbox', event: 'new_message', payload: { psid }, private: false }] })
  }).catch(() => {});
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const secretKey = Deno.env.get('XENDIT_SECRET_KEY');
  const callbackToken = Deno.env.get('XENDIT_CALLBACK_TOKEN');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!secretKey || !callbackToken || !supabaseUrl || !serviceRoleKey) {
    console.error('xendit-webhook: secrets not configured');
    return jsonResponse({ error: 'Not configured.' }, 500);
  }

  if (!timingSafeEqual(req.headers.get('x-callback-token') ?? '', callbackToken)) {
    return jsonResponse({ error: 'Invalid callback token.' }, 401);
  }

  const payload = await req.json().catch(() => null);
  const invoiceId = String(payload?.id ?? '').trim();
  if (!invoiceId) return jsonResponse({ ok: false, error: 'No invoice id in the callback.' });

  // Re-read the invoice from Xendit.
  let invoice: any = null;
  try {
    const response = await fetch(`${XENDIT_API}/v2/invoices/${encodeURIComponent(invoiceId)}`, {
      headers: { 'Authorization': 'Basic ' + btoa(secretKey + ':') }
    });
    if (response.status === 404) {
      // The dashboard's "Test" button posts a made-up invoice id - acknowledge it so the test shows success.
      return jsonResponse({ ok: true, note: `Invoice ${invoiceId} is not on this Xendit account (dashboard test callback?) - ignored.` });
    }
    invoice = await response.json().catch(() => null);
    if (!response.ok || !invoice?.id) {
      console.error('xendit-webhook: invoice lookup failed', response.status, JSON.stringify(invoice));
      return jsonResponse({ error: `Invoice lookup failed (${response.status}).` }, 502); // Xendit retries
    }
  } catch (err) {
    console.error('xendit-webhook: could not reach Xendit', err);
    return jsonResponse({ error: 'Could not reach Xendit.' }, 502);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data, error } = await supabase.rpc('_xendit_record_invoice_status', {
    // Xendit's own copy wins; the callback only fills fields the GET leaves out (e.g. payment_id).
    p_invoice: { ...payload, ...invoice },
    p_webhook: payload
  });
  if (error) {
    console.error('xendit-webhook: record failed', error.message);
    return jsonResponse({ error: error.message }, 500); // Xendit retries
  }

  // "Payment received" message in the customer's Messenger chat. Never fails the webhook - the payment
  // is already safely recorded.
  if (data?.status === 'Paid' && data?.apply_status === 'Applied') {
    try {
      await sendReceiptMessage(supabase, data.payment_id);
    } catch (err) {
      console.error('xendit-webhook: receipt message failed', err);
    }
  }
  // An invoice we didn't create (another integration on the same account) - nothing to retry.
  return jsonResponse(data ?? { ok: true });
});
