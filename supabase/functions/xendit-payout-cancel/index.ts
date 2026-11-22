// Cancel a Purchase Order supplier payout that is stuck at Xendit (Purchase Orders > Xendit Payments > Stop payout).
// Super users only. Input: { username, password, requestId } (PurchaseOrderXenditRequests.RequestID).
//
// Safety: Xendit decides. We only ask it to cancel the one payout tied to this request; our records change only
// after Xendit answers CANCELLED. If Xendit refuses (already handed to the bank), we re-read the payout, save its
// real status and change nothing else. On success the request is cancelled through staff_cancel_po_xendit_payment
// (same rules as the Cancel button), so the PO can be posted and paid another way. A cancelled payout's amount goes
// back to the Xendit balance.
// Added 2026-11-22 for PO-0101 (payout stuck ACCEPTED, vendor paid another way).
// Deploy: npx supabase functions deploy xendit-payout-cancel --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { payoutKeyFor } from '../_shared/xendit-keys.ts';
import { cancelPayout, getPayout, recordArgs, xenditMessage } from '../_shared/xendit-payouts.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const body = await req.json().catch(() => null);
  const username = String(body?.username ?? '').trim();
  const password = String(body?.password ?? '');
  const requestId = String(body?.requestId ?? '');

  const { data: isAdmin, error: adminError } = await supabase.rpc('is_admin_authorized', { p_username: username, p_password: password });
  if (adminError) return jsonResponse({ error: 'Could not check your login.' }, 500);
  if (!username || !isAdmin) return jsonResponse({ error: 'Only a super user can stop a Xendit payout.' }, 403);
  if (!UUID_RE.test(requestId)) return jsonResponse({ error: 'Pick a payment.' }, 400);

  // The payout still in flight for this request.
  const { data: rows, error: rowError } = await supabase
    .from('XenditPayouts')
    .select('PayoutID, XenditPayoutID, Status, IsTest, Amount, PONo')
    .eq('VendorRequestID', requestId)
    .in('Status', ['ACCEPTED', 'REQUESTED'])
    .order('CreatedAtUtc', { ascending: false });
  if (rowError) return jsonResponse({ error: rowError.message }, 500);
  const row = rows?.[0];
  if (!row) return jsonResponse({ error: 'This payment has nothing in progress at Xendit to stop - press Refresh Status.' }, 400);
  if (!row.XenditPayoutID) return jsonResponse({ error: 'This payout has no Xendit ID yet - press Refresh Status first.' }, 400);

  const key = payoutKeyFor(row.IsTest);
  if (!key) return jsonResponse({ error: `No valid ${row.IsTest ? 'test' : 'live'} Xendit payout key.` }, 500);

  let result;
  try {
    result = await cancelPayout(key, row.XenditPayoutID);
  } catch (err) {
    console.error('xendit-payout-cancel: no answer', row.XenditPayoutID, err);
    return jsonResponse({ error: 'Xendit didn\'t answer - press Refresh Status, then try again.' }, 502);
  }
  console.log('xendit-payout-cancel', row.XenditPayoutID, result.status, JSON.stringify(result.body));

  const cancelled = result.ok && String(result.body?.status ?? '').toUpperCase() === 'CANCELLED';
  if (!cancelled) {
    // Refused or unclear: save Xendit's real status, change nothing else.
    const now = await getPayout(key, row.XenditPayoutID).catch(() => null);
    if (now?.ok && now.body?.id) {
      await supabase.rpc('_payroll_payout_record', { p_payout_id: row.PayoutID, p_reference_id: null, p_error: null, ...recordArgs(now.body) });
    }
    const nowStatus = now?.ok ? String(now.body?.status ?? '') : '';
    return jsonResponse({
      error: `Xendit didn't cancel it (${xenditMessage(result)}).${nowStatus ? ` Xendit now shows it as ${nowStatus}.` : ''}`
        + (nowStatus === 'SUCCEEDED' ? ' The money reached the supplier.' : ' Ask Xendit support to stop it.'),
      xenditStatus: nowStatus || null
    }, 400);
  }

  const rec = await supabase.rpc('_payroll_payout_record', { p_payout_id: row.PayoutID, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
  if (rec.error) console.error('xendit-payout-cancel: record', rec.error.message);

  const { data: cancelData, error: cancelError } = await supabase.rpc('staff_cancel_po_xendit_payment', {
    p_admin_username: username, p_admin_password: password, p_request_id: requestId
  });
  const cancelRes = Array.isArray(cancelData) ? cancelData[0] : cancelData;
  if (cancelError || !cancelRes?.success) {
    return jsonResponse({
      error: `Xendit cancelled the payout (money back in the Xendit balance), but the request couldn't be closed here: ${cancelError?.message || cancelRes?.message}. Press Cancel on it.`
    }, 500);
  }
  return jsonResponse({ done: true, message: `Xendit cancelled the ${row.IsTest ? 'TEST ' : ''}payout - the money goes back to the Xendit balance. The request is cancelled, so the PO can be posted.` });
});
