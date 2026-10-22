// Creates a Xendit invoice (hosted checkout: GCash, Maya, cards, QR Ph, banks...) for an order's down
// payment or full balance and returns its checkout URL - called by docs/js/pay.js. The amount is worked
// out in the database (_xendit_prepare_invoice, sql/supabase_xendit_payments.sql) from the order itself;
// the browser only says which order and "Down payment" / "Full balance". The secret key never leaves
// this function.
//
// Secrets (set via `npx supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   XENDIT_SECRET_KEY   - Xendit Dashboard > Settings > API Keys. A TEST key (xnd_development_...) makes
//                          every invoice a test invoice (IsTest = true - see the SQL file for what that
//                          means); swap in the LIVE key (xnd_production_...) once the account is approved.
//                          Needs "Money-in: Write" permission.
//   PUBLIC_SITE_URL      - optional, default https://www.rspetstop.com - where Xendit sends the customer
//                          back after paying (pay.html).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy: npx supabase functions deploy xendit-create-invoice --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt
// (no staff login - customers call it from the public pay page with the publishable key).

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const XENDIT_API = 'https://api.xendit.co';
const INVOICE_DURATION_SECONDS = 24 * 60 * 60;

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
    if (!ALLOWED_RETURN_HOSTS.includes(url.hostname)) return fallback;
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const secretKey = Deno.env.get('XENDIT_SECRET_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!secretKey || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Online payment is not set up yet.' }, 500);
  }
  const isTest = !secretKey.startsWith('xnd_production_');

  const body = await req.json().catch(() => null);
  const orderRef = String(body?.orderRef ?? '').trim();
  const purpose = String(body?.purpose ?? '').trim();
  if (!orderRef) return jsonResponse({ error: 'Order ID is required.' }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  // While Xendit is switched off (XenditSettings.Enabled) only a super user's portal login gets an
  // invoice - checked in _xendit_prepare_invoice, not here.
  const { data: prepared, error: prepareError } = await supabase.rpc('_xendit_prepare_invoice', {
    p_order_ref: orderRef,
    p_purpose: purpose,
    p_is_test: isTest,
    p_staff_username: typeof body?.staffUsername === 'string' ? body.staffUsername : null,
    p_staff_password: typeof body?.staffPassword === 'string' ? body.staffPassword : null
  });
  if (prepareError) return jsonResponse({ error: prepareError.message }, 400);
  if (prepared.reuse) {
    return jsonResponse({ invoiceUrl: prepared.invoice_url, amount: prepared.amount, isTest, reused: true });
  }

  const back = returnBase(body?.returnUrl);
  const orderParam = encodeURIComponent(prepared.order_ref);
  const customer: Record<string, string> = { given_names: String(prepared.customer_name || 'RS Pet Stop customer').slice(0, 100) };
  const email = validEmail(prepared.customer_email);
  const mobile = toE164Ph(prepared.customer_phone);
  if (email) customer.email = email;
  if (mobile) customer.mobile_number = mobile;

  const invoiceRequest: Record<string, unknown> = {
    external_id: prepared.external_id,
    amount: Number(prepared.amount),
    currency: 'PHP',
    description: `RS Pet Stop order ${prepared.order_ref} - ${prepared.purpose}`,
    invoice_duration: INVOICE_DURATION_SECONDS,
    customer,
    items: [{ name: `${prepared.purpose} - order ${prepared.order_ref}`, quantity: 1, price: Number(prepared.amount) }],
    success_redirect_url: `${back}?order=${orderParam}&result=success`,
    failure_redirect_url: `${back}?order=${orderParam}&result=failed`
  };
  if (email) invoiceRequest.payer_email = email;

  let invoice: any = null;
  let createError: string | null = null;
  try {
    const response = await fetch(`${XENDIT_API}/v2/invoices`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(secretKey + ':'),
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(invoiceRequest)
    });
    invoice = await response.json().catch(() => null);
    if (!response.ok || !invoice?.invoice_url) {
      createError = `Xendit ${response.status}: ${invoice?.message || invoice?.error_code || 'invoice was not created'}`;
    }
  } catch (err) {
    createError = `Could not reach Xendit: ${(err as Error).message}`;
  }

  await supabase.rpc('_xendit_set_invoice', {
    p_payment_id: prepared.payment_id,
    p_invoice_id: invoice?.id ?? null,
    p_invoice_url: invoice?.invoice_url ?? null,
    p_expires_at: invoice?.expiry_date ?? null,
    p_error: createError
  });

  if (createError) {
    console.error('xendit-create-invoice:', createError, JSON.stringify(invoice));
    return jsonResponse({ error: 'We could not start the online payment. Please try again in a moment.', detail: createError }, 502);
  }
  return jsonResponse({ invoiceUrl: invoice.invoice_url, amount: prepared.amount, isTest, reused: false });
});
