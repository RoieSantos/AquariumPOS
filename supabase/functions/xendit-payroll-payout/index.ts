// Payroll payouts through Xendit (Payroll Run > Pay via Xendit; Payroll Setup > Salary Payout).
//   action 'channels' - the GCash / Maya / bank list Xendit can pay out to (payroll officers + super users)
//   action 'balance'  - available Xendit balance, to compare with the run's Xendit total (super users)
//   action 'send'     - pay a finalized run's Xendit lines (super users only)
//   action 'refresh'  - re-read payouts still waiting on Xendit (payroll officers + super users)
//
// Safety: one XenditPayouts row per line per mode, made by _payroll_payouts_prepare under a lock; its PayoutID is
// the Idempotency-key, so a double click, two tabs or a retry after a timeout can't pay anyone twice. A call that
// never answers leaves the row at 'Creating' and the next send re-uses the same key. sql/supabase_xendit_payroll_payouts.sql
//
// Key: "Money-out: Write" - see payoutKeyFor in _shared/xendit-keys.ts. Mode: XenditSettings."LiveMode".
// Deploy: npx supabase functions deploy xendit-payroll-payout --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { payoutKeyFor, readKeyFor } from '../_shared/xendit-keys.ts';
import { createPayout, findPayoutByReference, getPayout, listPayoutChannels, recordArgs, xenditMessage } from '../_shared/xendit-payouts.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHANNEL_CACHE_MS = 30 * 60 * 1000;
const channelCache = new Map<boolean, { at: number; channels: unknown[] }>();

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
  const action = String(body?.action ?? '');

  const [{ data: isAdmin, error: adminError }, { data: isPayroll, error: payrollError }] = await Promise.all([
    supabase.rpc('is_admin_authorized', { p_username: username, p_password: password }),
    supabase.rpc('is_payroll_authorized', { p_username: username, p_password: password })
  ]);
  if (adminError || payrollError) {
    console.error('xendit-payroll-payout: login check failed', adminError?.message, payrollError?.message);
    return jsonResponse({ error: 'Could not check your login.' }, 500);
  }
  if (!username || (!isAdmin && !isPayroll)) return jsonResponse({ error: 'Not authorized - log in again.' }, 401);
  if ((action === 'send' || action === 'balance') && !isAdmin) {
    return jsonResponse({ error: 'Only a super user can do this.' }, 403);
  }

  const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode', {});
  if (modeError || !modeRows?.[0]) return jsonResponse({ error: 'Could not read the Xendit mode.' }, 500);
  const isTest: boolean = modeRows[0].is_test;

  // ---------------------------------------------------------------- channels
  if (action === 'channels') {
    const cached = channelCache.get(isTest);
    if (cached && Date.now() - cached.at < CHANNEL_CACHE_MS) return jsonResponse({ isTest, channels: cached.channels });
    const key = payoutKeyFor(isTest) ?? readKeyFor(isTest);
    if (!key) return jsonResponse({ error: 'No Xendit key.' }, 500);
    const result = await listPayoutChannels(key);
    if (!result.ok || !Array.isArray(result.body)) return jsonResponse({ error: xenditMessage(result) }, 502);
    const channels = result.body
      .filter((c: any) => (!c.currency || c.currency === 'PHP') && ['BANK', 'EWALLET'].includes(String(c.channel_category)))
      .map((c: any) => ({
        code: c.channel_code,
        name: c.channel_name,
        category: c.channel_category,
        min: c.amount_limits?.minimum ?? null,
        max: c.amount_limits?.maximum ?? null
      }))
      .sort((a: any, b: any) => (a.category === b.category ? String(a.name).localeCompare(String(b.name)) : a.category === 'EWALLET' ? -1 : 1));
    channelCache.set(isTest, { at: Date.now(), channels });
    return jsonResponse({ isTest, channels });
  }

  // ---------------------------------------------------------------- balance
  if (action === 'balance') {
    const key = readKeyFor(isTest);
    if (!key) return jsonResponse({ error: 'No Xendit key.' }, 500);
    const response = await fetch('https://api.xendit.co/balance?account_type=CASH&currency=PHP', {
      headers: { 'Authorization': 'Basic ' + btoa(key + ':') }
    });
    const result = await response.json().catch(() => null);
    if (!response.ok || typeof result?.balance !== 'number') {
      return jsonResponse({ isTest, balance: null, error: 'Could not read the Xendit balance (the key needs "Balance: Read").' });
    }
    return jsonResponse({ isTest, balance: result.balance });
  }

  const runId = String(body?.runId ?? '');
  if (!UUID_RE.test(runId)) return jsonResponse({ error: 'Pick a payroll run.' }, 400);

  // ---------------------------------------------------------------- send
  if (action === 'send') {
    const key = payoutKeyFor(isTest);
    if (!key) return jsonResponse({ error: `No valid ${isTest ? 'test' : 'live'} Xendit payout key.` }, 500);
    const lineIds: string[] | null = Array.isArray(body?.lineIds) ? body.lineIds.map(String).filter((id: string) => UUID_RE.test(id)) : null;

    const { data: rows, error: prepError } = await supabase.rpc('_payroll_payouts_prepare', {
      p_run_id: runId, p_is_test: isTest, p_sent_by: username, p_line_ids: lineIds && lineIds.length ? lineIds : null
    });
    if (prepError) return jsonResponse({ error: prepError.message }, 400);
    const toSend: any[] = rows ?? [];
    if (!toSend.length) return jsonResponse({ isTest, sent: 0, failed: [], note: 'Nothing to send - every Xendit line is already sent or paid.' });

    // Enough in Xendit? Only blocks when the balance can be read and is clearly short; otherwise Xendit itself
    // refuses a payout it can't cover (INSUFFICIENT_BALANCE) and that line can be sent again later.
    const total = toSend.reduce((s, r) => s + Number(r.amount), 0);
    const readKey = readKeyFor(isTest);
    if (readKey) {
      const balanceResponse = await fetch('https://api.xendit.co/balance?account_type=CASH&currency=PHP', {
        headers: { 'Authorization': 'Basic ' + btoa(readKey + ':') }
      });
      const balanceBody = await balanceResponse.json().catch(() => null);
      if (balanceResponse.ok && typeof balanceBody?.balance === 'number' && balanceBody.balance < total) {
        // Nothing went to Xendit for the rows made just now - free them so the next try starts clean. A re-send
        // (is_new false) is left at 'Creating': its first try may have reached Xendit.
        await Promise.all(toSend.filter((r) => r.is_new).map((r) => supabase.rpc('_payroll_payout_record', {
          p_payout_id: r.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: 'Not sent - not enough in the Xendit balance', p_estimated_arrival: null, p_body: null
        })));
        return jsonResponse({
          error: `Not enough in Xendit: need ₱${total.toLocaleString('en-PH', { minimumFractionDigits: 2 })}, available `
            + `₱${balanceBody.balance.toLocaleString('en-PH', { minimumFractionDigits: 2 })}. Wait for sales to settle or top up Xendit, then send again.`
        }, 400);
      }
    }

    let sent = 0;
    const failed: { name: string; error: string }[] = [];
    for (const r of toSend) {
      let result;
      try {
        result = await createPayout(key, r.payout_id, {
          reference_id: r.reference_id,
          channel_code: r.channel_code,
          account_number: r.account_number,
          account_holder_name: r.account_name,
          amount: Number(r.amount),
          description: r.description
        });
      } catch (err) {
        // No answer: leave it at 'Creating' - Refresh / the next send checks with the same key.
        console.error('xendit-payroll-payout: create, no answer', r.payout_id, err);
        failed.push({ name: r.display_name, error: 'Xendit didn\'t answer - press Refresh status before sending again.' });
        continue;
      }
      if (result.ok && result.body?.id) {
        await supabase.rpc('_payroll_payout_record', { p_payout_id: r.payout_id, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
        if (String(result.body.status).toUpperCase() === 'FAILED') failed.push({ name: r.display_name, error: result.body.failure_code || 'Failed' });
        else sent++;
      } else if (result.status >= 500 || result.status === 429 || result.status === 409) {
        // Busy / unsure / same key in flight - leave at 'Creating' for a retry with the same key.
        console.error('xendit-payroll-payout: create', result.status, JSON.stringify(result.body));
        failed.push({ name: r.display_name, error: `${xenditMessage(result)} - press Refresh status before sending again.` });
      } else {
        // Refused (bad account, no permission...): nothing was created, so it can be fixed and sent again.
        await supabase.rpc('_payroll_payout_record', {
          p_payout_id: r.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: xenditMessage(result), p_estimated_arrival: null, p_body: result.body
        });
        failed.push({ name: r.display_name, error: xenditMessage(result) });
      }
    }
    return jsonResponse({ isTest, sent, failed });
  }

  // ---------------------------------------------------------------- refresh
  if (action === 'refresh') {
    const { data: open, error } = await supabase.rpc('_payroll_payouts_open', { p_run_id: runId });
    if (error) return jsonResponse({ error: error.message }, 500);
    let updated = 0;
    for (const p of open ?? []) {
      const key = payoutKeyFor(p.is_test);
      if (!key) continue;
      const result = p.xendit_payout_id ? await getPayout(key, p.xendit_payout_id) : await findPayoutByReference(key, p.reference_id);
      if (result.ok && result.body?.id) {
        await supabase.rpc('_payroll_payout_record', { p_payout_id: p.payout_id, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
        updated++;
      } else if (!p.xendit_payout_id && result.ok && !result.body && Number(p.age_seconds) > 600) {
        // Xendit has no payout with our reference 10+ minutes on: the create never landed - free the line to send
        // again. (Younger rows may still be in flight from another tab, so they're left alone.)
        await supabase.rpc('_payroll_payout_record', {
          p_payout_id: p.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: 'Not created at Xendit - send again', p_estimated_arrival: null, p_body: null
        });
        updated++;
      }
    }
    return jsonResponse({ isTest, checked: (open ?? []).length, updated });
  }

  return jsonResponse({ error: 'Unknown action.' }, 400);
});
