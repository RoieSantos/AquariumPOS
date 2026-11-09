// Xendit QR Ph at the POS counter (walk-in sales) - called only by the desktop POS (XenditPayForm.cs), which
// sends the POS key on every call. sql/supabase_xendit_pos_walkin.sql explains the flow.
//   create   - makes a QR Ph payment request for the amount; the POS shows its QR string
//   status   - re-reads it from Xendit and records it, so the sale never waits on the webhook
//   cancel   - cancels it; if it was paid a moment ago the answer says Paid
//   link     - saves the sale's receipt no. on the payment (ties it to the WI- order)
//   simulate - test mode only: pays it, since a real app can't pay a test QR
//
// QR Ph has no expiry at Xendit, so "status" cancels a request once it's past QR_MINUTES.
// Same secrets as xendit-create-invoice (_shared/xendit-keys.ts): the Xendit Payments page's test / live switch
// picks the mode for a new payment, and an existing one keeps its own. The xendit-webhook function also records
// these payments; recording twice is safe.
//
// Deploy: npx supabase functions deploy xendit-pos-payment --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { secretKeyFor } from '../_shared/xendit-keys.ts';
import { cancelPaymentRequest, createQrphRequest, readPaymentRequest, simulatePayment, toRecordedInvoice } from '../_shared/xendit-qrph.ts';

const QR_MINUTES = 15;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Xendit is not set up yet.' }, 500);
  }

  const body = await req.json().catch(() => null);
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { data: keyOk, error: keyError } = await supabase.rpc('_pos_key_ok', { p_key: String(body?.posKey ?? '') });
  if (keyError) {
    console.error('xendit-pos-payment: POS key check failed', keyError.message);
    return jsonResponse({ error: 'Could not check the POS key.' }, 500);
  }
  if (!keyOk) return jsonResponse({ error: 'Not authorized.' }, 401);

  const action = String(body?.action ?? '');

  if (action === 'create') {
    const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode');
    if (modeError || !modeRows?.[0]) return jsonResponse({ error: 'Could not check the Xendit mode.' }, 500);
    const isTest: boolean = modeRows[0].is_test;
    const secretKey = secretKeyFor(isTest);
    if (!secretKey) return jsonResponse({ error: 'Xendit is not set up yet.' }, 500);

    const { data: rows, error: prepareError } = await supabase.rpc('_xendit_pos_prepare', {
      p_amount: Number(body?.amount),
      p_warehouse_id: body?.warehouseId ?? null,
      p_cashier: body?.cashier ?? null,
      p_terminal: body?.terminal ?? null,
      p_is_test: isTest
    });
    if (prepareError) return jsonResponse({ error: prepareError.message }, 400);
    const prepared = rows?.[0];

    const amount = Number(prepared.amount);
    const description = `RS Pet Stop${prepared.branch ? ' ' + prepared.branch : ''} - walk-in ${prepared.order_ref}`;
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
      console.error('xendit-pos-payment:', createError, JSON.stringify(created?.body));
      return jsonResponse({ error: createError }, 502);
    }
    // expiresInSeconds drives the POS "Pay before" countdown (it falls back to 15 min without it).
    return jsonResponse({ paymentId: prepared.payment_id, qrString: created!.qrString, amount, isTest, reference: prepared.order_ref, expiresInSeconds: QR_MINUTES * 60 });
  }

  // The rest all work on an existing POS payment.
  const paymentId = String(body?.paymentId ?? '');
  const { data: rows, error: readError } = await supabase.rpc('_xendit_pos_get_payment', { p_payment_id: paymentId });
  if (readError) return jsonResponse({ error: readError.message }, 400);
  const payment = rows?.[0];
  if (!payment) return jsonResponse({ error: 'Payment not found.' }, 404);

  if (action === 'link') {
    const { error } = await supabase.rpc('_xendit_pos_link', { p_payment_id: paymentId, p_receipt_no: body?.receiptNo ?? null });
    if (error) return jsonResponse({ error: error.message }, 400);
    return jsonResponse({ ok: true });
  }

  if (!payment.invoice_id) return jsonResponse({ status: payment.status });

  const secretKey = secretKeyFor(payment.is_test);
  if (!secretKey) return jsonResponse({ error: 'Xendit is not set up yet.' }, 500);

  if (action === 'simulate') {
    if (!payment.is_test) return jsonResponse({ error: 'Simulate is for test mode only.' }, 400);
    const result = await simulatePayment(secretKey, payment.invoice_id, Number(payment.amount));
    if (!result.ok) return jsonResponse({ error: `Xendit ${result.status}: ${result.body?.message || result.body?.error_code || 'simulate failed'}` }, 502);
    return jsonResponse({ status: payment.status });
  }

  if (action !== 'status' && action !== 'cancel') return jsonResponse({ error: 'Unknown action.' }, 400);

  // Only Xendit's own answer is ever recorded. A cancel Xendit refuses (e.g. just paid) falls back to a read.
  let request = action === 'cancel' ? await cancelPaymentRequest(secretKey, payment.invoice_id) : null;
  if (!request) request = await readPaymentRequest(secretKey, payment.invoice_id);
  if (!request) return jsonResponse({ error: 'Could not reach Xendit.' }, 502);

  const unpaid = ['REQUIRES_ACTION', 'ACCEPTING_PAYMENTS'].includes(String(request.status).toUpperCase());
  if (action === 'status' && unpaid && payment.expires_at && new Date(payment.expires_at).getTime() < Date.now()) {
    request = (await cancelPaymentRequest(secretKey, payment.invoice_id)) ?? (await readPaymentRequest(secretKey, payment.invoice_id)) ?? request;
  }

  const { data: recorded, error: recordError } = await supabase.rpc('_xendit_record_invoice_status', {
    p_invoice: toRecordedInvoice(request),
    p_webhook: { source: `pos-${action}` }
  });
  if (recordError) {
    console.error('xendit-pos-payment: record failed', recordError.message);
    return jsonResponse({ error: recordError.message }, 500);
  }
  const { data: after } = await supabase.rpc('_xendit_pos_get_payment', { p_payment_id: paymentId });
  const current = after?.[0];
  return jsonResponse({
    status: current?.status ?? recorded?.status,
    paidAmount: current?.paid_amount ?? null,
    channel: current?.payment_channel ?? current?.payment_method ?? null
  });
});
