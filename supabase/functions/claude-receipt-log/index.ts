// claude-receipt-log - receives one parsed Anthropic receipt from the Gmail Apps Script
// (tools/gmail-claude-receipts.gs), converts USD -> PHP at the day's rate, and logs it to the
// Expense Journal via service_log_claude_receipt (sql/supabase_claude_spend_tracking.sql).
//
// Auth: shared secret in the x-receipt-secret header (CLAUDE_RECEIPT_SECRET). Deploy with
// --no-verify-jwt - the caller is Google Apps Script, not a portal session.
//
// Secrets: CLAUDE_RECEIPT_SECRET (required), CLAUDE_EXPENSE_WAREHOUSE (optional, default
// "Warehouse" - which warehouse the expense is booked to). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
// are provided by Supabase.
//
// Body: { receipt_number, invoice_number?, date_paid: 'YYYY-MM-DD', kind: 'api_credits'|'subscription',
//         item_description?, subtotal_usd?, tax_usd?, total_usd, gmail_message_id? }
// Reply: { status: 'logged'|'duplicate', receipt_no, amount_php, exchange_rate }

import { createClient } from 'npm:@supabase/supabase-js@2';

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function num(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(/,/g, ''));
  return Number.isFinite(n) ? n : null;
}

// USD -> PHP for the receipt date. Frankfurter (ECB reference rates, date-specific; a weekend or
// holiday returns the last business day's rate), falling back to open.er-api.com's latest rate.
async function usdToPhp(date: string): Promise<{ rate: number; source: string }> {
  try {
    const res = await fetch(`https://api.frankfurter.app/${date}?from=USD&to=PHP`);
    if (res.ok) {
      const body = await res.json();
      const rate = Number(body?.rates?.PHP);
      if (rate > 0) return { rate, source: `frankfurter.app ECB ${body?.date ?? date}` };
    }
  } catch (err) {
    console.warn('frankfurter rate lookup failed:', err);
  }
  const res = await fetch('https://open.er-api.com/v6/latest/USD');
  if (!res.ok) throw new Error(`Exchange rate lookup failed (${res.status}).`);
  const body = await res.json();
  const rate = Number(body?.rates?.PHP);
  if (!(rate > 0)) throw new Error('Exchange rate lookup returned no PHP rate.');
  return { rate, source: 'open.er-api.com latest' };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'POST only.' }, 405);

  const secret = Deno.env.get('CLAUDE_RECEIPT_SECRET');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!secret || !supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'Function is not configured.' }, 500);

  if (!safeEqual(req.headers.get('x-receipt-secret') ?? '', secret)) {
    return jsonResponse({ error: 'Not authorized.' }, 401);
  }

  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON.' }, 400);
  }

  const receiptNumber = String(body?.receipt_number ?? '').trim();
  const datePaid = String(body?.date_paid ?? '').trim();
  const kind = String(body?.kind ?? '').trim();
  const totalUsd = num(body?.total_usd);
  const subtotalUsd = num(body?.subtotal_usd);
  const taxUsd = num(body?.tax_usd);

  if (!/^[0-9A-Za-z-]{4,50}$/.test(receiptNumber)) return jsonResponse({ error: 'Missing or invalid receipt_number.' }, 400);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(datePaid)) return jsonResponse({ error: 'date_paid must be YYYY-MM-DD.' }, 400);
  if (kind !== 'api_credits' && kind !== 'subscription') return jsonResponse({ error: 'kind must be api_credits or subscription.' }, 400);
  if (!totalUsd || totalUsd <= 0) return jsonResponse({ error: 'total_usd must be greater than zero.' }, 400);

  let rate: { rate: number; source: string };
  try {
    rate = await usdToPhp(datePaid);
  } catch (err) {
    return jsonResponse({ error: (err as Error).message }, 502);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data, error } = await supabase.rpc('service_log_claude_receipt', {
    p_receipt_number: receiptNumber,
    p_invoice_number: body?.invoice_number ? String(body.invoice_number) : null,
    p_date_paid: datePaid,
    p_kind: kind,
    p_item_description: body?.item_description ? String(body.item_description) : null,
    p_subtotal_usd: subtotalUsd,
    p_tax_usd: taxUsd,
    p_total_usd: totalUsd,
    p_exchange_rate: rate.rate,
    p_rate_source: rate.source,
    p_warehouse: Deno.env.get('CLAUDE_EXPENSE_WAREHOUSE') || 'Warehouse',
    p_gmail_message_id: body?.gmail_message_id ? String(body.gmail_message_id) : null
  });

  if (error) {
    console.error('service_log_claude_receipt failed:', error.message);
    return jsonResponse({ error: error.message }, 500);
  }

  const row = Array.isArray(data) ? data[0] : data;
  return jsonResponse({
    status: row?.status,
    receipt_no: row?.receipt_no,
    amount_php: row?.amount_php,
    exchange_rate: rate.rate
  });
});
