// Xendit QR Ph for the delivery team - the driver shows the QR on their phone at the door (Delivery page,
// js/delivery.js). Called with the driver's portal login (username + password / staff session token) on every
// call. sql/supabase_xendit_delivery_collect.sql explains the flow.
//   create   - cancels any unpaid QR still open on these stops, then makes a QR Ph payment request for the amount
//   status   - re-reads it from Xendit and records it, so the driver never waits on the webhook. Recording it
//              Paid saves the stop's collection(s) (trigger TR_XenditPayments_DeliveryPaid)
//   cancel   - cancels it; if it was paid a moment ago the answer says Paid
//   simulate - test mode only: pays it, since a real app can't pay a test QR
//
// Same QR Ph helpers as xendit-pos-payment (_shared/xendit-qrph.ts) and the same secrets (_shared/xendit-keys.ts).
// The xendit-webhook function also records these payments ('RSPS-DLV-' reference); recording twice is safe.
//
// Deploy: npx supabase functions deploy xendit-delivery-payment --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { secretKeyFor } from '../_shared/xendit-keys.ts';
import { cancelPaymentRequest, createQrphRequest, readPaymentRequest, simulatePayment, toRecordedInvoice } from '../_shared/xendit-qrph.ts';

const QR_MINUTES = 15;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'Xendit is not set up yet.' }, 500);

  const body = await req.json().catch(() => null);
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const username = String(body?.username ?? '').trim();
  const { data: staffOk, error: staffError } = await supabase.rpc('is_staff_authorized', {
    p_username: username,
    p_password: String(body?.password ?? '')
  });
  if (staffError) {
    console.error('xendit-delivery-payment: staff check failed', staffError.message);
    return jsonResponse({ error: 'Could not check your login.' }, 500);
  }
  if (!username || !staffOk) return jsonResponse({ error: 'Not authorized - log in again.' }, 401);

  const action = String(body?.action ?? '');

  if (action === 'create') {
    const stopIds: string[] = Array.isArray(body?.stopIds) ? body.stopIds.map(String).filter((id: string) => UUID_RE.test(id)) : [];
    if (!stopIds.length) return jsonResponse({ error: 'Pick a stop.' }, 400);

    const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode');
    if (modeError || !modeRows?.[0]) return jsonResponse({ error: 'Could not check the Xendit mode.' }, 500);
    const isTest: boolean = modeRows[0].is_test;
    const secretKey = secretKeyFor(isTest);
    if (!secretKey) return jsonResponse({ error: 'Xendit is not set up yet.' }, 500);

    // One open QR per stop: cancel older unpaid ones first. One that turns out paid is recorded (which saves
    // its collection) and the driver is told, instead of showing a second QR for the same balance.
    const { data: openRows } = await supabase.rpc('_xendit_delivery_open_payments', { p_stop_ids: stopIds });
    for (const open of openRows ?? []) {
      const key = secretKeyFor(open.is_test);
      if (!key) continue;
      const request = (await cancelPaymentRequest(key, open.invoice_id)) ?? (await readPaymentRequest(key, open.invoice_id));
      if (!request) continue;
      await supabase.rpc('_xendit_record_invoice_status', { p_invoice: toRecordedInvoice(request), p_webhook: { source: 'delivery-replace' } });
      if (String(request.status).toUpperCase() === 'SUCCEEDED') {
        return jsonResponse({ error: 'An earlier QR for this stop was just PAID. It is saved on the stop - check the stop before collecting again.', alreadyPaid: true }, 409);
      }
    }

    const { data: rows, error: prepareError } = await supabase.rpc('_xendit_delivery_prepare', {
      p_username: username,
      p_stop_ids: stopIds,
      p_amount: Number(body?.amount),
      p_is_test: isTest
    });
    if (prepareError) return jsonResponse({ error: prepareError.message }, 400);
    const prepared = rows?.[0];

    const amount = Number(prepared.amount);
    const description = `RS Pet Stop delivery - ${prepared.order_ref}`.slice(0, 250);
    let created: Awaited<ReturnType<typeof createQrphRequest>> | null = null;
    let createError: string | null = null;
    try {
      created = await createQrphRequest(secretKey, prepared.external_id, amount, description);
      if (!created.ok) createError = `Xendit ${created.status}: ${created.body?.message || created.body?.error_code || 'QR was not created'}`;
    } catch (err) {
      createError = `Could not reach Xendit: ${(err as Error).message}`;
    }

    await supabase.rpc('_xendit_set_invoice', {
      p_payment_id: prepared.payment_id,
      p_invoice_id: created?.body?.payment_request_id ?? null,
      p_invoice_url: null,
      p_expires_at: createError ? null : new Date(Date.now() + QR_MINUTES * 60 * 1000).toISOString(),
      p_error: createError
    });
    if (createError) {
      console.error('xendit-delivery-payment:', createError, JSON.stringify(created?.body));
      return jsonResponse({ error: createError }, 502);
    }
    return jsonResponse({
      paymentId: prepared.payment_id,
      qrString: created!.qrString,
      amount,
      isTest,
      reference: prepared.order_ref,
      expiresInSeconds: QR_MINUTES * 60
    });
  }

  // The rest all work on an existing delivery payment.
  const paymentId = String(body?.paymentId ?? '');
  if (!UUID_RE.test(paymentId)) return jsonResponse({ error: 'Payment not found.' }, 404);
  const readPayment = async () => {
    const { data, error } = await supabase.rpc('_xendit_delivery_get_payment', { p_payment_id: paymentId });
    if (error) throw new Error(error.message);
    return data?.[0] ?? null;
  };
  const answer = (p: any) => jsonResponse({
    status: p?.status,
    paidAmount: p?.paid_amount ?? null,
    channel: p?.payment_channel ?? p?.payment_method ?? null,
    receiptNo: p?.receipt_no ?? null,
    collectionsSaved: p?.collections_saved ?? 0,
    collectionsFailed: p?.collections_failed ?? 0
  });

  let payment: any;
  try {
    payment = await readPayment();
  } catch (err) {
    return jsonResponse({ error: (err as Error).message }, 400);
  }
  if (!payment) return jsonResponse({ error: 'Payment not found.' }, 404);
  if (!payment.invoice_id) return answer(payment);

  const secretKey = secretKeyFor(payment.is_test);
  if (!secretKey) return jsonResponse({ error: 'Xendit is not set up yet.' }, 500);

  if (action === 'simulate') {
    if (!payment.is_test) return jsonResponse({ error: 'Simulate is for test mode only.' }, 400);
    const result = await simulatePayment(secretKey, payment.invoice_id, Number(payment.amount));
    if (!result.ok) return jsonResponse({ error: `Xendit ${result.status}: ${result.body?.message || result.body?.error_code || 'simulate failed'}` }, 502);
    return answer(payment);
  }

  if (action !== 'status' && action !== 'cancel') return jsonResponse({ error: 'Unknown action.' }, 400);

  // Already paid and its collection saved: nothing to ask Xendit.
  if (payment.status === 'Paid' && payment.collections_saved > 0) return answer(payment);

  // Only Xendit's own answer is ever recorded. A cancel Xendit refuses (e.g. just paid) falls back to a read.
  let request = action === 'cancel' ? await cancelPaymentRequest(secretKey, payment.invoice_id) : null;
  if (!request) request = await readPaymentRequest(secretKey, payment.invoice_id);
  if (!request) return jsonResponse({ error: 'Could not reach Xendit.' }, 502);

  const unpaid = ['REQUIRES_ACTION', 'ACCEPTING_PAYMENTS'].includes(String(request.status).toUpperCase());
  if (action === 'status' && unpaid && payment.expires_at && new Date(payment.expires_at).getTime() < Date.now()) {
    request = (await cancelPaymentRequest(secretKey, payment.invoice_id)) ?? (await readPaymentRequest(secretKey, payment.invoice_id)) ?? request;
  }

  const { error: recordError } = await supabase.rpc('_xendit_record_invoice_status', {
    p_invoice: toRecordedInvoice(request),
    p_webhook: { source: `delivery-${action}` }
  });
  if (recordError) {
    console.error('xendit-delivery-payment: record failed', recordError.message);
    return jsonResponse({ error: recordError.message }, 500);
  }

  try {
    let current = await readPayment();
    // Paid but no collection yet (the trigger's save failed earlier) - try again now.
    if (current?.status === 'Paid' && !current.collections_saved) {
      await supabase.rpc('_xendit_delivery_complete', { p_payment_id: paymentId });
      current = await readPayment();
    }
    return answer(current);
  } catch (err) {
    return jsonResponse({ error: (err as Error).message }, 500);
  }
});
