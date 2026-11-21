// Purchase Order supplier payments through Xendit (Purchase Orders > Xendit Payments). Same flow as cash advances:
// staff request a payment (staff_request_po_xendit_payment), a super user approves it here.
//   action 'balance' - available Xendit balance, shown before Approve & Send (super users)
//   action 'send'    - Approve & Send one request { requestId } to the vendor's payout account (super users)
//   action 'refresh' - re-read this PO's payouts still waiting on Xendit { poNo } (any staff)
//
// Where the money goes: the vendor's Xendit payout account (Vendors > Manage, super users only, every change
// alerted on Telegram), copied onto the payout row when it is sent.
// Safety: one XenditPayouts row per request per mode, made by _vendor_payout_prepare under a lock; its PayoutID
// is the Idempotency-key, so a double click, two tabs or a retry after a timeout can't pay twice. A call that
// never answers leaves the row at 'Creating' and the next send re-uses the same key. Status comes back through
// xendit-webhook (reference RSPS-PAY-PO-...) or 'refresh'. sql/supabase_purchase_order_xendit_payments.sql
//
// API: v2, or v3 when PortalSettings XENDIT_PAYOUT_API = 'v3' (_shared/xendit-payouts.ts). A re-send always goes
// to the API the row was first sent with.
// Key: "Money-out: Write" - payoutKeyFor in _shared/xendit-keys.ts. Mode: XenditSettings."LiveMode".
// Deploy: npx supabase functions deploy xendit-vendor-payout --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { payoutKeyFor, readKeyFor } from '../_shared/xendit-keys.ts';
import {
  createPayout, findPayoutByReference, getPayout, payoutApiFor, readPayoutApiSetting, recordArgs, storedPayoutApi, xenditMessage
} from '../_shared/xendit-payouts.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

async function readBalance(isTest: boolean): Promise<number | null> {
  const key = readKeyFor(isTest);
  if (!key) return null;
  const response = await fetch('https://api.xendit.co/balance?account_type=CASH&currency=PHP', {
    headers: { 'Authorization': 'Basic ' + btoa(key + ':') }
  });
  const body = await response.json().catch(() => null);
  return response.ok && typeof body?.balance === 'number' ? body.balance : null;
}

function peso(n: number) {
  return '₱' + n.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function splitEmails(value: unknown): string[] {
  return String(value ?? '').split(/[,;\s]+/).map((e) => e.trim()).filter((e) => e.includes('@'));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const body = await req.json().catch(() => null);
  const username = String(body?.username ?? '').trim();
  const password = String(body?.password ?? '');
  const action = String(body?.action ?? '');

  const [{ data: isAdmin, error: adminError }, { data: isStaff, error: staffError }] = await Promise.all([
    supabase.rpc('is_admin_authorized', { p_username: username, p_password: password }),
    supabase.rpc('is_staff_authorized', { p_username: username, p_password: password })
  ]);
  if (adminError || staffError) {
    console.error('xendit-vendor-payout: login check failed', adminError?.message, staffError?.message);
    return jsonResponse({ error: 'Could not check your login.' }, 500);
  }
  if (!username || (!isAdmin && !isStaff)) return jsonResponse({ error: 'Not authorized - log in again.' }, 401);
  if ((action === 'send' || action === 'balance') && !isAdmin) {
    return jsonResponse({ error: 'Only a super user can approve and send a supplier payment.' }, 403);
  }

  const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode', {});
  if (modeError || !modeRows?.[0]) return jsonResponse({ error: 'Could not read the Xendit mode.' }, 500);
  const isTest: boolean = modeRows[0].is_test;

  // ---------------------------------------------------------------- balance
  if (action === 'balance') {
    const balance = await readBalance(isTest);
    return jsonResponse({ isTest, balance, ...(balance === null ? { error: 'Could not read the Xendit balance (the key needs "Balance: Read").' } : {}) });
  }

  // ---------------------------------------------------------------- send
  if (action === 'send') {
    const requestId = String(body?.requestId ?? '');
    if (!UUID_RE.test(requestId)) return jsonResponse({ error: 'Pick a payment request.' }, 400);

    const key = payoutKeyFor(isTest);
    if (!key) return jsonResponse({ error: `No valid ${isTest ? 'test' : 'live'} Xendit payout key.` }, 500);

    const prep = await supabase.rpc('_vendor_payout_prepare', { p_request_id: requestId, p_is_test: isTest, p_sent_by: username });
    if (prep.error) return jsonResponse({ error: prep.error.message }, 400);
    const row = prep.data?.[0];
    if (!row) return jsonResponse({ isTest, done: true, note: 'This payment was already sent - press Refresh Status to see where it is.' });

    // Enough in Xendit? Only for a new row - a re-send of a 'Creating' row may already have been taken.
    if (row.is_new) {
      const balance = await readBalance(isTest);
      if (balance !== null && balance < Number(row.amount)) {
        await supabase.rpc('_payroll_payout_record', {
          p_payout_id: row.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: 'Not sent - not enough in the Xendit balance', p_estimated_arrival: null, p_body: null
        });
        return jsonResponse({
          error: `Not enough in Xendit: need ${peso(Number(row.amount))}, available ${peso(balance)}. Wait for sales to settle or top up Xendit, then send again.`
        }, 400);
      }
    }

    const api = await payoutApiFor(supabase, row.payout_id, !!row.is_new, row.channel_code, await readPayoutApiSetting(supabase));
    if (!api) return jsonResponse({ error: 'Could not tell how this payment was first sent - try again in a minute.' }, 502);

    let result;
    try {
      result = await createPayout(key, row.payout_id, {
        api,
        relationship: 'OTHER',
        purpose_code: 'OTHER',
        reference_id: row.reference_id,
        channel_code: row.channel_code,
        account_number: row.account_number,
        account_holder_name: row.account_name,
        amount: Number(row.amount),
        description: row.description,
        receipt_email_to: splitEmails(row.email_to),
        receipt_email_cc: splitEmails(row.email_cc)
      });
    } catch (err) {
      // No answer: stays 'Creating'. Sending again re-uses the same Idempotency-key.
      console.error('xendit-vendor-payout: create, no answer', row.payout_id, err);
      return jsonResponse({ error: 'Xendit didn\'t answer. Press Refresh Status before sending again - it won\'t pay twice.' }, 502);
    }
    if (result.ok && result.body?.id) {
      await supabase.rpc('_payroll_payout_record', { p_payout_id: row.payout_id, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
      const status = String(result.body.status || '').toUpperCase();
      if (status === 'FAILED') return jsonResponse({ error: `Xendit refused it: ${result.body.failure_code || 'FAILED'}`, done: true }, 400);
      return jsonResponse({ isTest, done: true, status, amount: Number(row.amount) });
    }
    if (result.status >= 500 || result.status === 429 || result.status === 409) {
      // Busy / unsure / same key in flight - leave at 'Creating' for a retry with the same key.
      console.error('xendit-vendor-payout: create', result.status, JSON.stringify(result.body));
      return jsonResponse({ error: `${xenditMessage(result)} - press Refresh Status before sending again.` }, 502);
    }
    // Refused (bad account, below the minimum, no permission...): nothing was created - fix it and send again.
    await supabase.rpc('_payroll_payout_record', {
      p_payout_id: row.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
      p_error: xenditMessage(result), p_estimated_arrival: null, p_body: result.body
    });
    return jsonResponse({ error: xenditMessage(result), done: true }, 400);
  }

  // ---------------------------------------------------------------- refresh
  if (action === 'refresh') {
    const poNo = String(body?.poNo ?? '').trim();
    if (!poNo) return jsonResponse({ error: 'Pick a Purchase Order.' }, 400);
    const open = await supabase.rpc('_vendor_payouts_open', { p_po_no: poNo });
    if (open.error) return jsonResponse({ error: open.error.message }, 500);
    const rows: any[] = open.data ?? [];
    let updated = 0;
    let waitingSend = 0;
    for (const p of rows) {
      const key = payoutKeyFor(p.is_test);
      if (!key) continue;
      if (!p.xendit_payout_id && (await storedPayoutApi(supabase, p.payout_id)) !== 'v2') {
        // v3 with no Xendit ID can't be looked up by our reference - a super user's Send again re-uses the same
        // Idempotency-key, which returns the payout if it was made.
        waitingSend++;
        continue;
      }
      const result = p.xendit_payout_id ? await getPayout(key, p.xendit_payout_id) : await findPayoutByReference(key, p.reference_id);
      if (result.ok && result.body?.id) {
        await supabase.rpc('_payroll_payout_record', { p_payout_id: p.payout_id, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
        updated++;
      } else if (!p.xendit_payout_id && result.ok && !result.body && Number(p.age_seconds) > 600) {
        // Never reached Xendit (10+ minutes, nothing with our reference): free it to send again.
        await supabase.rpc('_payroll_payout_record', {
          p_payout_id: p.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: 'Not created at Xendit - send again', p_estimated_arrival: null, p_body: null
        });
        updated++;
      }
    }
    return jsonResponse({
      isTest, checked: rows.length, updated,
      ...(waitingSend ? { note: `${waitingSend} payment(s) got no answer from Xendit - a super user should press Send again (it won't pay twice).` } : {})
    });
  }

  return jsonResponse({ error: 'Unknown action.' }, 400);
});
