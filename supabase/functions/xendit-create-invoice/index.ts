// Creates a Xendit Payment Session (hosted checkout: GCash, Maya, cards, QR Ph, banks...) for an order's down
// payment or full balance and returns its checkout URL - called by docs/js/pay.js. The session ID and URL
// are kept in XenditPayments' "InvoiceID" / "InvoiceUrl", so "invoice" below means that row. The amount is worked
// out in the database (_xendit_prepare_invoice, sql/supabase_xendit_payments.sql) from the order itself;
// the browser only says which order and "Down payment" / "Full balance". The secret key never leaves
// this function.
//
// Secrets (set via `npx supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   XENDIT_TEST_SECRET_KEY / XENDIT_LIVE_SECRET_KEY - see _shared/xendit-keys.ts. The Xendit Payments page's
//                          test / live switch picks one. Test mode only serves a logged-in super user.
//   PUBLIC_SITE_URL     - optional, default https://www.rspetstop.com - where Xendit sends the customer
//                          back after paying (pay.html).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy: npx supabase functions deploy xendit-create-invoice --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt
// (no staff login - customers call it from the public pay page with the publishable key).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { secretKeyFor } from '../_shared/xendit-keys.ts';
import { cancelSession, createSession, readSession, toRecordedSession } from '../_shared/xendit-session.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const SESSION_DURATION_MS = 24 * 60 * 60 * 1000;
// The checkout's methods when the customer didn't choose card, so a card can't skip the card fee.
// https://docs.xendit.co/docs/available-payment-channels
const NON_CARD_CHANNELS = ['GCASH', 'PAYMAYA', 'GRABPAY', 'SHOPEEPAY', 'QRPH', 'BPI_DIRECT_DEBIT', 'UBP_EADA', 'BDO_ONLINE_BANKING'];

// Return pages the customer may be sent back to - anything else falls back to PUBLIC_SITE_URL, so the
// invoice can't be turned into a redirect to someone else's site.
const ALLOWED_RETURN_HOSTS = ['www.rspetstop.com', 'rspetstop.com', 'localhost', '127.0.0.1'];

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
  });
}

function returnBase(requested: unknown): string {
  const fallback = (Deno.env.get('PUBLIC_SITE_URL') || 'https://www.rspetstop.com').replace(/\/+$/, '') + '/pay.html';
  if (typeof requested !== 'string' || !requested) return fallback;
  try {
    const url = new URL(requested);
    // Sessions only take https return URLs, so a local http page falls back too.
    if (url.protocol !== 'https:' || !ALLOWED_RETURN_HOSTS.includes(url.hostname)) return fallback;
    return url.origin + url.pathname;
  } catch {
    return fallback;
  }
}

// Xendit rejects a badly formatted mobile number outright, so only send one that is clearly a PH mobile.
function toE164Ph(phone: unknown): string | null {
  const digits = String(phone ?? '').replace(/\D/g, '');
  if (/^09\d{9}$/.test(digits)) return '+63' + digits.slice(1);
  if (/^639\d{9}$/.test(digits)) return '+' + digits;
  return null;
}

function validEmail(email: unknown): string | null {
  const value = String(email ?? '').trim();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) ? value : null;
}

// Cancels an unpaid session at Xendit. If Xendit refuses (e.g. it was paid a moment ago), the session is
// re-read so the caller sees its real status. Returns { status, invoice, error }.
async function expireInvoice(secretKey: string, invoiceId: string): Promise<{ status: string; invoice?: any; error?: string }> {
  try {
    const cancelled = await cancelSession(secretKey, invoiceId);
    const read = cancelled.ok ? cancelled : await readSession(secretKey, invoiceId);
    if (!read.ok) return { status: 'UNKNOWN', error: `cancel ${cancelled.status} / get ${read.status}: ${read.body?.message || ''}` };
    const invoice = await toRecordedSession(secretKey, read.body);
    return { status: String(invoice.status), invoice };
  } catch (err) {
    return { status: 'UNKNOWN', error: (err as Error).message };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Online payment is not set up yet.' }, 500);
  }

  const body = await req.json().catch(() => null);
  const orderRef = String(body?.orderRef ?? '').trim();
  const purpose = String(body?.purpose ?? '').trim();
  if (!orderRef) return jsonResponse({ error: 'Order ID is required.' }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const staffUsername = typeof body?.staffUsername === 'string' ? body.staffUsername : null;
  const staffPassword = typeof body?.staffPassword === 'string' ? body.staffPassword : null;

  // Test mode is super users only: fake money must never mark a customer's real order as paid.
  const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode', {
    p_staff_username: staffUsername,
    p_staff_password: staffPassword
  });
  if (modeError || !modeRows?.[0]) {
    console.error('xendit-create-invoice: mode check failed', modeError?.message);
    return jsonResponse({ error: 'We could not start the online payment. Please try again in a moment.' }, 500);
  }
  if (!modeRows[0].may_pay) return jsonResponse({ error: 'Online payment is not available yet.' }, 400);
  const isTest: boolean = modeRows[0].is_test;
  const secretKey = secretKeyFor(isTest);
  if (!secretKey) {
    console.error(`xendit-create-invoice: no valid ${isTest ? 'test' : 'live'} secret key`);
    return jsonResponse({ error: 'Online payment is not set up yet.' }, 500);
  }

  // One open invoice per order: expire the order's older unpaid invoices at Xendit first, so a customer
  // can never pay two of them (AO-00118). One that turns out to be paid is recorded and stops here.
  // sql/supabase_xendit_expire_old_invoices.sql
  const { data: openInvoices, error: openError } = await supabase.rpc('_xendit_open_invoices', {
    p_order_ref: orderRef,
    p_staff_username: staffUsername,
    p_staff_password: staffPassword
  });
  if (openError) {
    console.error('xendit-create-invoice: open invoice check failed', openError.message);
    return jsonResponse({ error: 'We could not start the online payment. Please try again in a moment.' }, 500);
  }
  for (const open of openInvoices ?? []) {
    const openKey = secretKeyFor(open.is_test); // an invoice from the other mode needs that mode's key
    const outcome = openKey ? await expireInvoice(openKey, open.invoice_id) : { status: 'UNKNOWN', error: 'no secret key for its mode' } as { status: string; invoice?: any; error?: string };
    if (outcome.status === 'PAID' || outcome.status === 'SETTLED') {
      await supabase.rpc('_xendit_record_invoice_status', { p_invoice: outcome.invoice, p_webhook: { source: 'expire-check' } });
      return jsonResponse({ error: 'A payment for this order was just received. Please refresh the page to see your updated balance.' }, 409);
    }
    if (outcome.status === 'EXPIRED') {
      await supabase.rpc('_xendit_mark_expired', { p_payment_id: open.payment_id });
    } else {
      console.error('xendit-create-invoice: could not expire', open.invoice_id, outcome.error);
      return jsonResponse({ error: 'We could not start the online payment. Please try again in a moment.' }, 502);
    }
  }

  // While Xendit is switched off (XenditSettings.Enabled) only a super user's portal login gets an
  // invoice - checked in _xendit_prepare_invoice, not here.
  const { data: prepared, error: prepareError } = await supabase.rpc('_xendit_prepare_invoice', {
    p_order_ref: orderRef,
    p_purpose: purpose,
    p_is_test: isTest,
    p_staff_username: staffUsername,
    p_staff_password: staffPassword
  });
  if (prepareError) return jsonResponse({ error: prepareError.message }, 400);
  if (prepared.reuse) {
    return jsonResponse({ invoiceUrl: prepared.invoice_url, amount: prepared.amount, isTest, reused: true });
  }

  // Card fee, worked out in the database (sql/supabase_xendit_card_fee.sql). 0% = no fee and all methods together.
  const payByCard = body?.payByCard === true;
  const { data: feeRows, error: feeError } = await supabase.rpc('_xendit_set_card_fee', { p_payment_id: prepared.payment_id, p_pay_by_card: payByCard });
  if (feeError || !feeRows?.[0]) {
    console.error('xendit-create-invoice: card fee failed', feeError?.message);
    await supabase.rpc('_xendit_set_invoice', { p_payment_id: prepared.payment_id, p_invoice_id: null, p_invoice_url: null, p_expires_at: null, p_error: 'Card fee failed' });
    return jsonResponse({ error: 'We could not start the online payment. Please try again in a moment.' }, 500);
  }
  const cardFee = Number(feeRows[0].card_fee);
  const channels = Number(feeRows[0].fee_percent) > 0 ? { allowed_payment_channels: payByCard ? ['CARDS'] : NON_CARD_CHANNELS } : {};

  const back = returnBase(body?.returnUrl);
  const orderParam = encodeURIComponent(prepared.order_ref);
  const individual_detail = { given_names: String(prepared.customer_name || 'RS Pet Stop customer').slice(0, 100) };
  // reference_id must be new each time and letters / numbers only, or Xendit answers DUPLICATE_ERROR.
  const customer: Record<string, unknown> = { type: 'INDIVIDUAL', reference_id: String(prepared.payment_id).replace(/-/g, ''), individual_detail };
  const email = validEmail(prepared.customer_email);
  const mobile = toE164Ph(prepared.customer_phone);
  if (email && email.length <= 50) customer.email = email;
  if (mobile) customer.mobile_number = mobile;

  let invoice: any = null;
  let createError: string | null = null;
  try {
    const created = await createSession(secretKey, {
      reference_id: prepared.external_id,
      amount: Math.round((Number(prepared.amount) + cardFee) * 100) / 100,
      ...channels,
      description: `RS Pet Stop order ${prepared.order_ref} - ${prepared.purpose}${cardFee > 0 ? ` (includes PHP ${cardFee.toFixed(2)} card fee)` : ''}`,
      expires_at: new Date(Date.now() + SESSION_DURATION_MS).toISOString(),
      customer,
      success_return_url: `${back}?order=${orderParam}&result=success`,
      cancel_return_url: `${back}?order=${orderParam}&result=failed`
    });
    invoice = created.body;
    if (!created.ok) {
      createError = `Xendit ${created.status}: ${invoice?.message || invoice?.error_code || 'session was not created'}`;
    }
  } catch (err) {
    createError = `Could not reach Xendit: ${(err as Error).message}`;
  }

  await supabase.rpc('_xendit_set_invoice', {
    p_payment_id: prepared.payment_id,
    p_invoice_id: invoice?.payment_session_id ?? null,
    p_invoice_url: invoice?.payment_link_url ?? null,
    p_expires_at: invoice?.expires_at ?? null,
    p_error: createError
  });

  if (createError) {
    console.error('xendit-create-invoice:', createError, JSON.stringify(invoice));
    return jsonResponse({ error: 'We could not start the online payment. Please try again in a moment.', detail: createError }, 502);
  }
  return jsonResponse({ invoiceUrl: invoice.payment_link_url, amount: prepared.amount, isTest, reused: false });
});
