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
// Deploy: npx supabase functions deploy xendit-webhook --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';

const XENDIT_API = 'https://api.xendit.co';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
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
  // An invoice we didn't create (another integration on the same account) - nothing to retry.
  return jsonResponse(data ?? { ok: true });
});
