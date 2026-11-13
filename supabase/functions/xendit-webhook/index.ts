// Xendit webhook (Payment Sessions and POS Payments events) - marks the XenditPayments row Paid / Expired and
// applies a paid session to its order (_xendit_record_invoice_status, sql/supabase_xendit_payments.sql).
//
// Trust: the x-callback-token header must equal the test or live callback token, AND the session is re-read
// from Xendit's own API, with that same mode's key, before anything is recorded - the posted body is never taken
// at its word. Idempotent: Xendit retries a webhook until it gets a 2xx, and a repeated PAID never pays twice.
//
// Secrets: see _shared/xendit-keys.ts. Both modes work whichever way the Xendit Payments page's switch is set, so
// a payment already started is still recorded after switching.
//
// Xendit Dashboard > Settings > Webhooks > Payment Session (completed and expired), Payments and Payouts (v2), in
// both TEST and LIVE mode:  https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/xendit-webhook
//
// After a payment is applied, the customer gets a "payment received" message on the order's Messenger
// chat (sendReceiptMessage below; uses the FACEBOOK_PAGE_ACCESS_TOKEN / FACEBOOK_PAGE_TOKENS secrets the
// Messenger bot already has). Test payments are only logged in the thread, never sent.
//
// Deploy: npx supabase functions deploy xendit-webhook --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { getPageAccessToken } from '../_shared/page-tokens.ts';
import { callbackTokenFor, payoutKeyFor, secretKeyFor } from '../_shared/xendit-keys.ts';
import { getPayout, recordArgs } from '../_shared/xendit-payouts.ts';
import { readPaymentRequestOrNotFound, toRecordedInvoice } from '../_shared/xendit-qrph.ts';
import { readSession, toRecordedSession } from '../_shared/xendit-session.ts';

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
      const result = await sendOnMessenger(token, graphVersion, claim.psid, claim.message);
      status = result.ok ? 'Sent' : `Failed: ${result.body?.error?.message || 'Facebook refused the message'}`;
      mid = result.ok ? (result.body?.message_id ?? null) : null;
    }
    await supabase.rpc('_xendit_set_receipt_message_status', { p_payment_id: paymentId, p_status: status, p_facebook_mid: mid });
  }
  await broadcastGmaEvent(claim.psid);
}

async function sendOnMessenger(token: string, graphVersion: string, psid: string, text: string) {
  const send = (extra: Record<string, unknown>) => fetch(`https://graph.facebook.com/${graphVersion}/me/messages?access_token=${token}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ recipient: { id: psid }, message: { text }, ...extra })
  }).then(async (res) => ({ ok: res.ok, body: await res.json().catch(() => null) }));
  // Normal reply first; outside Facebook's 24h window a payment update is a post-purchase update.
  let result = await send({ messaging_type: 'RESPONSE' });
  if (!result.ok) result = await send({ messaging_type: 'MESSAGE_TAG', tag: 'POST_PURCHASE_UPDATE' });
  return result;
}

// A real payment that reaches the 50% down payment confirms an order waiting for confirmation, and the customer
// gets the usual "order confirmed" message. sql/supabase_xendit_auto_confirm.sql
async function autoConfirmOrder(supabase: ReturnType<typeof createClient>, paymentId: string): Promise<void> {
  const { data: rows, error } = await supabase.rpc('_xendit_try_auto_confirm', { p_payment_id: paymentId });
  if (error) throw new Error(error.message);
  const claim = rows?.[0];
  if (!claim?.message_id) return;
  const token = getPageAccessToken(claim.page_id ?? null);
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  const result = token ? await sendOnMessenger(token, graphVersion, claim.psid, claim.message) : null;
  await supabase.rpc('_xendit_set_confirm_message_status', {
    p_message_id: claim.message_id,
    p_sent: !!result?.ok,
    p_facebook_mid: result?.ok ? (result.body?.message_id ?? null) : null
  });
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

  const sentToken = req.headers.get('x-callback-token') ?? '';
  const liveToken = callbackTokenFor(false);
  const testToken = callbackTokenFor(true);
  const isLive = !!liveToken && timingSafeEqual(sentToken, liveToken);
  if (!isLive && !(testToken && timingSafeEqual(sentToken, testToken))) {
    return jsonResponse({ error: 'Invalid callback token.' }, 401);
  }

  const secretKey = secretKeyFor(!isLive);
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!secretKey || !supabaseUrl || !serviceRoleKey) {
    console.error('xendit-webhook: secrets not configured');
    return jsonResponse({ error: 'Not configured.' }, 500);
  }

  const payload = await req.json().catch(() => null);

  // Pay page sessions (xendit-create-invoice): re-read the session from Xendit, record it, send the receipt.
  if (typeof payload?.event === 'string' && payload.event.startsWith('payment_session.')) {
    const sessionId = String(payload?.data?.payment_session_id ?? payload?.data?.id ?? '').trim();
    if (!sessionId) {
      console.error('xendit-webhook: no session id in the callback', JSON.stringify(payload));
      return jsonResponse({ error: 'No session id in the callback.' }, 400); // Xendit retries, and it shows as failed there
    }
    let session: Awaited<ReturnType<typeof readSession>>;
    try {
      session = await readSession(secretKey, sessionId);
    } catch (err) {
      console.error('xendit-webhook: could not reach Xendit', err);
      return jsonResponse({ error: 'Could not reach Xendit.' }, 502);
    }
    if (session.status === 404) {
      // The dashboard's "Test" button posts a made-up session id - acknowledge it so the test shows success.
      return jsonResponse({ ok: true, note: `Session ${sessionId} is not on this Xendit account (dashboard test callback?) - ignored.` });
    }
    if (!session.ok) {
      console.error('xendit-webhook: session lookup failed', session.status, JSON.stringify(session.body));
      return jsonResponse({ error: `Session lookup failed (${session.status}).` }, 502); // Xendit retries
    }
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const { data, error } = await supabase.rpc('_xendit_record_invoice_status', {
      p_invoice: await toRecordedSession(secretKey, session.body),
      p_webhook: payload
    });
    if (error) {
      console.error('xendit-webhook: record failed', error.message);
      return jsonResponse({ error: error.message }, 500); // Xendit retries
    }
    if (data?.status === 'Paid' && data?.apply_status === 'Applied') {
      try {
        await sendReceiptMessage(supabase, data.payment_id);
      } catch (err) {
        console.error('xendit-webhook: receipt message failed', err);
      }
      try {
        await autoConfirmOrder(supabase, data.payment_id);
      } catch (err) {
        console.error('xendit-webhook: auto-confirm failed', err);
      }
    }
    return jsonResponse(data ?? { ok: true });
  }

  // Payroll payouts (xendit-payroll-payout): payout.succeeded / payout.failed / payout.reversed... Re-read from
  // Xendit with that mode's payout key, then recorded on XenditPayouts (sql/supabase_xendit_payroll_payouts.sql).
  // Xendit Dashboard > Settings > Webhooks > Payouts (v2), same URL.
  if (typeof payload?.event === 'string' && payload.event.startsWith('payout.')) {
    const payoutId = String(payload?.data?.id ?? '').trim();
    const referenceId = String(payload?.data?.reference_id ?? '').trim();
    if (!referenceId.startsWith('RSPS-PAY-')) return jsonResponse({ ok: true, note: 'Not a payroll payout - ignored.' });
    const payoutKey = payoutKeyFor(!isLive);
    if (!payoutId || !payoutKey) return jsonResponse({ error: 'No payout id or payout key.' }, 400);
    const read = await getPayout(payoutKey, payoutId);
    if (read.status === 404) return jsonResponse({ ok: true, note: `Payout ${payoutId} is not on this account (dashboard test?) - ignored.` });
    if (!read.ok || !read.body?.id) return jsonResponse({ error: `Payout lookup failed (${read.status}).` }, 502); // Xendit retries
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const { data, error } = await supabase.rpc('_payroll_payout_record', {
      p_payout_id: null, p_reference_id: String(read.body.reference_id ?? referenceId), p_error: null, ...recordArgs(read.body)
    });
    if (error) {
      console.error('xendit-webhook: payout record failed', error.message);
      return jsonResponse({ error: error.message }, 500); // Xendit retries
    }
    return jsonResponse({ ok: true, status: data });
  }

  // POS / delivery QR Ph payments (xendit-pos-payment, xendit-delivery-payment) come from the Payments API, which posts { event, data }. Covers a
  // payment the POS stopped watching, e.g. it closed after the customer scanned. No Messenger message: the
  // POS prints the receipt. Xendit Dashboard > Settings > Webhooks > Payments, same URL as Invoices.
  if (typeof payload?.event === 'string') {
    const paymentRequestId = String(payload?.data?.payment_request_id ?? '').trim();
    if (!paymentRequestId) return jsonResponse({ ok: true, note: `Event ${payload.event} ignored.` });
    const { notFound, request } = await readPaymentRequestOrNotFound(secretKey, paymentRequestId);
    // The dashboard's "Test and save" posts a made-up payment request - acknowledge it so the test passes.
    if (notFound) return jsonResponse({ ok: true, note: `Payment request ${paymentRequestId} is not on this Xendit account (dashboard test callback?) - ignored.` });
    if (!request) return jsonResponse({ error: 'Could not read the payment request from Xendit.' }, 502); // Xendit retries
    // A pay page session's attempts land here too. Skip a failed one: it must not close a session the customer
    // can still retry, and its payment_session.* event covers the outcome. A SUCCEEDED one is recorded (below).
    // Delivery QRs (xendit-delivery-payment, 'RSPS-DLV-') are recorded the same way; recording one Paid saves
    // the driver's collection (sql/supabase_xendit_delivery_collect.sql).
    const referenceId = String(request.reference_id ?? '');
    const isPosOrDelivery = referenceId.startsWith('RSPS-POS-') || referenceId.startsWith('RSPS-DLV-');
    // Pay page attempt that SUCCEEDED: record it here too (AO-00237). The customer had a QR on screen, opened the
    // pay link again (which cancels the old session - xendit-create-invoice), then paid the old QR anyway. Xendit
    // took the money but sends no payment_session.completed for a cancelled session, so this event is the only
    // notice. Recording is once-only, so it's harmless when payment_session.completed also arrives.
    if (!isPosOrDelivery && referenceId.startsWith('RSPS-') && String(request.status ?? '').toUpperCase() === 'SUCCEEDED') {
      const recorded = toRecordedInvoice(request);
      const channel = request.channel_code === 'CARDS' ? 'CREDIT_CARD' : (request.channel_code ?? 'QRPH');
      recorded.payment_method = channel;
      recorded.payment_channel = channel;
      const supabase = createClient(supabaseUrl, serviceRoleKey);
      const { data, error } = await supabase.rpc('_xendit_record_invoice_status', { p_invoice: recorded, p_webhook: payload });
      if (error) {
        console.error('xendit-webhook: pay page payment record failed', error.message);
        return jsonResponse({ error: error.message }, 500); // Xendit retries
      }
      if (data?.status === 'Paid' && data?.apply_status === 'Applied') {
        try {
          await sendReceiptMessage(supabase, data.payment_id);
        } catch (err) {
          console.error('xendit-webhook: receipt message failed', err);
        }
        try {
          await autoConfirmOrder(supabase, data.payment_id);
        } catch (err) {
          console.error('xendit-webhook: auto-confirm failed', err);
        }
      }
      return jsonResponse(data ?? { ok: true });
    }
    if (!isPosOrDelivery) {
      return jsonResponse({ ok: true, note: `Event ${payload.event} is not a POS or delivery payment - ignored.` });
    }
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const { data, error } = await supabase.rpc('_xendit_record_invoice_status', { p_invoice: toRecordedInvoice(request), p_webhook: payload });
    if (error) {
      console.error('xendit-webhook: record failed', error.message);
      return jsonResponse({ error: error.message }, 500); // Xendit retries
    }
    return jsonResponse(data ?? { ok: true });
  }

  return jsonResponse({ ok: true, note: 'Not a Payment Sessions or Payments event - ignored.' });
});
