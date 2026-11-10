// Xendit Ledger page (docs/xendit-ledger.html, super users only): every move on the Xendit account - money in
// (customer payments), Xendit fees / VAT, money out (withdrawals to the bank, refunds) - straight from Xendit's
// Transactions API, plus the current balance (Balance API). Each payment is matched back to our XenditPayments
// row so the page can show which order it was for. Read-only; the secret key never leaves this function.
//
// Key: needs "Balance: Read" + "Transactions: Read" - see readKeyFor in _shared/xendit-keys.ts.
// Deploy: npx supabase functions deploy xendit-ledger --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt
// (checks the super user itself with is_admin_authorized).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readKeyFor } from '../_shared/xendit-keys.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const PAGE_SIZE = 50;   // Xendit's max per call
const MAX_PAGES = 40;   // 2,000 transactions per request - more than that and the page says to narrow the dates

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

function xenditError(status: number, body: any): string {
  if (status === 403 || body?.error_code === 'REQUEST_FORBIDDEN_ERROR') {
    return 'The Xendit key can\'t read the balance / transactions. In the Xendit Dashboard > Settings > API Keys, make a key with '
      + '"Balance: Read" and "Transactions: Read" and save it as the XENDIT_LIVE_READ_KEY (or XENDIT_TEST_READ_KEY) secret.';
  }
  return `Xendit ${status}: ${body?.message || body?.error_code || 'no answer'}`;
}

async function getBalance(key: string, accountType: 'CASH' | 'HOLDING'): Promise<number | null> {
  const response = await fetch(`https://api.xendit.co/balance?account_type=${accountType}&currency=PHP`, {
    headers: { 'Authorization': 'Basic ' + btoa(key + ':') }
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) throw new Error(xenditError(response.status, body));
  return typeof body?.balance === 'number' ? body.balance : null;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const body = await req.json().catch(() => null);

  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: String(body?.username ?? ''),
    p_password: String(body?.password ?? '')
  });
  if (authError) {
    console.error('xendit-ledger: admin check failed', authError.message);
    return jsonResponse({ error: 'Could not check your login.' }, 500);
  }
  if (!authorized) return jsonResponse({ error: 'Not authorized - log in again.' }, 401);

  // Live / test: what the page asked for, else the current mode.
  let isTest: boolean;
  if (body?.mode === 'live' || body?.mode === 'test') {
    isTest = body.mode === 'test';
  } else {
    const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode', {});
    if (modeError || !modeRows?.[0]) return jsonResponse({ error: 'Could not read the Xendit mode.' }, 500);
    isTest = modeRows[0].is_test;
  }
  const key = readKeyFor(isTest);
  if (!key) return jsonResponse({ error: `No valid ${isTest ? 'test' : 'live'} Xendit key.` }, 500);

  const from = new Date(String(body?.from ?? ''));
  const to = new Date(String(body?.to ?? ''));
  if (isNaN(from.getTime()) || isNaN(to.getTime()) || from >= to) return jsonResponse({ error: 'Pick a valid date range.' }, 400);

  // Balance first - cheap, and the clearest test of the key's permissions.
  let balance: { cash: number | null; holding: number | null };
  try {
    const [cash, holding] = await Promise.all([getBalance(key, 'CASH'), getBalance(key, 'HOLDING')]);
    balance = { cash, holding };
  } catch (err) {
    return jsonResponse({ error: (err as Error).message }, 502);
  }

  // Transactions in the range, newest first, paged with after_id.
  const transactions: any[] = [];
  let afterId: string | null = null;
  let truncated = false;
  for (let page = 0; page < MAX_PAGES; page++) {
    const params = new URLSearchParams({ limit: String(PAGE_SIZE), currency: 'PHP' });
    params.set('created[gte]', from.toISOString());
    params.set('created[lte]', to.toISOString());
    if (afterId) params.set('after_id', afterId);
    const response = await fetch(`https://api.xendit.co/transactions?${params}`, {
      headers: { 'Authorization': 'Basic ' + btoa(key + ':') }
    });
    const result = await response.json().catch(() => null);
    if (!response.ok) {
      console.error('xendit-ledger: transactions', response.status, JSON.stringify(result));
      return jsonResponse({ error: xenditError(response.status, result) }, 502);
    }
    const rows: any[] = Array.isArray(result?.data) ? result.data : [];
    transactions.push(...rows);
    if (!result?.has_more || rows.length === 0) break;
    afterId = rows[rows.length - 1].id;
    if (page === MAX_PAGES - 1) truncated = true;
  }

  // Which of our payments each one is: reference_id = our ExternalID; product_id = the payment request /
  // session (InvoiceID) or Xendit's payment id (XenditPaymentRef).
  const safeId = (v: unknown) => typeof v === 'string' && /^[\w\-.:]{1,200}$/.test(v);
  const refs = [...new Set(transactions.map((t) => t.reference_id).filter(safeId))];
  const products = [...new Set(transactions.map((t) => t.product_id).filter(safeId))];
  const ours: any[] = [];
  const columns = 'PaymentID,ExternalID,InvoiceID,XenditPaymentRef,OrderRef,OnlineOrderID,Purpose,Source,DeliveryDriver,PosCashier,PosReceiptNo,ReceiptNo';
  for (let i = 0; i < Math.max(refs.length, products.length); i += 150) {
    const r = refs.slice(i, i + 150);
    const p = products.slice(i, i + 150);
    const filters: string[] = [];
    if (r.length) filters.push(`ExternalID.in.(${r.map((v) => `"${v}"`).join(',')})`);
    if (p.length) {
      filters.push(`InvoiceID.in.(${p.map((v) => `"${v}"`).join(',')})`);
      filters.push(`XenditPaymentRef.in.(${p.map((v) => `"${v}"`).join(',')})`);
    }
    const { data, error } = await supabase.from('XenditPayments').select(columns).or(filters.join(','));
    if (error) console.error('xendit-ledger: match', error.message);
    else ours.push(...(data ?? []));
  }
  const byRef = new Map<string, any>();
  for (const o of ours) {
    if (o.ExternalID) byRef.set('r:' + o.ExternalID, o);
    if (o.InvoiceID) byRef.set('p:' + o.InvoiceID, o);
    if (o.XenditPaymentRef) byRef.set('p:' + o.XenditPaymentRef, o);
  }

  const num = (v: unknown) => (typeof v === 'number' ? v : Number(v) || 0);
  const rows = transactions.map((t) => {
    const fee = t.fee ?? {};
    const match = byRef.get('r:' + t.reference_id) ?? byRef.get('p:' + t.product_id) ?? null;
    return {
      id: t.id,
      type: t.type,
      status: t.status,
      cashflow: t.cashflow,
      channel_category: t.channel_category,
      channel_code: t.channel_code,
      reference_id: t.reference_id,
      account: t.account_identifier,
      amount: num(t.amount),
      net_amount: t.net_amount == null ? null : num(t.net_amount),
      xendit_fee: num(fee.xendit_fee),
      vat: num(fee.value_added_tax),
      withholding_tax: num(fee.xendit_withholding_tax) + num(fee.third_party_withholding_tax),
      fee_status: fee.status ?? null,
      settlement_status: t.settlement_status ?? null,
      estimated_settlement: t.estimated_settlement_time ?? null,
      created: t.created,
      updated: t.updated,
      ours: match && {
        payment_id: match.PaymentID,
        order_ref: match.OrderRef,
        online_order_id: match.OnlineOrderID,
        purpose: match.Purpose,
        source: match.Source,
        driver: match.DeliveryDriver,
        cashier: match.PosCashier,
        pos_receipt_no: match.PosReceiptNo,
        receipt_no: match.ReceiptNo
      }
    };
  });

  return jsonResponse({ isTest, balance, transactions: rows, truncated });
});
