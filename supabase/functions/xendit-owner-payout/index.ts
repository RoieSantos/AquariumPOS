// Owner withdrawals through Xendit (Xendit Ledger Entries > Withdraw to Owner). Super users only.
//   action 'info'    - the owner accounts (masked), the available balance and the recent withdrawals
//   action 'send'    - send { requestId, accountKey, amount, note } to one owner account
//   action 'refresh' - re-read owner withdrawals still waiting on Xendit
//
// Where the money can go: ONLY the accounts in the XENDIT_OWNER_ACCOUNTS secret - never an account typed in the
// portal, so a stolen super user login can't send the balance to someone else. Set it with:
//   npx supabase secrets set --project-ref hymcmesqgpliyyeghpgq XENDIT_OWNER_ACCOUNTS='[
//     {"key":"gcash","label":"Roie GCash","channel_code":"PH_GCASH","account_number":"09171234567","account_name":"Roie Santos"},
//     {"key":"bpi","label":"Roie BPI","channel_code":"PH_BPI","account_number":"1234567890","account_name":"Roie Santos"}]'
// channel_code is Xendit's payout channel (Payroll Setup's Salary Payout list shows them, e.g. PH_GCASH, PH_BPI).
// Optional XENDIT_OWNER_MAX_PER_SEND (pesos) caps one withdrawal.
//
// Safety: the page makes one requestId per withdrawal; it is the XenditPayouts PayoutID and Xendit's
// Idempotency-key, so a double click or a retry can't pay twice. Status comes back through xendit-webhook
// (reference RSPS-PAY-OWN-...) or 'refresh'. sql/supabase_xendit_owner_payouts.sql
//
// Key: "Money-out: Write" - payoutKeyFor in _shared/xendit-keys.ts. Mode: XenditSettings."LiveMode".
// Deploy: npx supabase functions deploy xendit-owner-payout --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import { payoutKeyFor, readKeyFor } from '../_shared/xendit-keys.ts';
import { createPayout, findPayoutByReference, getPayout, recordArgs, xenditMessage } from '../_shared/xendit-payouts.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type OwnerAccount = { key: string; label: string; channel_code: string; channel_name?: string; account_number: string; account_name: string };

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

function ownerAccounts(): { accounts: OwnerAccount[]; error?: string } {
  const raw = Deno.env.get('XENDIT_OWNER_ACCOUNTS');
  if (!raw) return { accounts: [], error: 'No owner accounts yet - set the XENDIT_OWNER_ACCOUNTS secret (see xendit-owner-payout).' };
  try {
    const list = JSON.parse(raw);
    if (!Array.isArray(list)) throw new Error('not a list');
    const accounts = list
      .map((a: any) => ({
        key: String(a?.key ?? '').trim(),
        label: String(a?.label ?? '').trim(),
        channel_code: String(a?.channel_code ?? '').trim(),
        channel_name: String(a?.channel_name ?? '').trim() || undefined,
        account_number: String(a?.account_number ?? '').replace(/\s+/g, ''),
        account_name: String(a?.account_name ?? '').trim()
      }))
      .filter((a) => a.key && a.channel_code && a.account_number && a.account_name);
    if (!accounts.length) return { accounts: [], error: 'XENDIT_OWNER_ACCOUNTS has no complete account (key, channel_code, account_number, account_name).' };
    return { accounts };
  } catch {
    return { accounts: [], error: 'XENDIT_OWNER_ACCOUNTS is not valid JSON.' };
  }
}

function maxPerSend(): number | null {
  const v = Number(Deno.env.get('XENDIT_OWNER_MAX_PER_SEND'));
  return Number.isFinite(v) && v > 0 ? v : null;
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const body = await req.json().catch(() => null);
  const username = String(body?.username ?? '').trim();
  const password = String(body?.password ?? '');
  const action = String(body?.action ?? '');

  const { data: isAdmin, error: adminError } = await supabase.rpc('is_admin_authorized', { p_username: username, p_password: password });
  if (adminError) {
    console.error('xendit-owner-payout: login check failed', adminError.message);
    return jsonResponse({ error: 'Could not check your login.' }, 500);
  }
  if (!username || !isAdmin) return jsonResponse({ error: 'Only a super user can do this - log in again.' }, 401);

  const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode', {});
  if (modeError || !modeRows?.[0]) return jsonResponse({ error: 'Could not read the Xendit mode.' }, 500);
  const isTest: boolean = modeRows[0].is_test;
  const { accounts, error: accountsError } = ownerAccounts();

  // ---------------------------------------------------------------- info
  if (action === 'info') {
    const [balance, recent] = await Promise.all([
      readBalance(isTest),
      supabase.rpc('_owner_payouts_recent', { p_limit: 20 })
    ]);
    return jsonResponse({
      isTest,
      balance,
      maxPerSend: maxPerSend(),
      accountsError: accountsError ?? null,
      accounts: accounts.map((a) => ({
        key: a.key,
        label: a.label || a.key,
        channel: a.channel_name || a.channel_code,
        accountLast4: a.account_number.slice(-4),
        accountName: a.account_name
      })),
      recent: recent.error ? [] : recent.data ?? [],
      recentError: recent.error ? (recent.error.message.includes('_owner_payouts_recent') ? 'Run sql/supabase_xendit_owner_payouts.sql first.' : recent.error.message) : null
    });
  }

  // ---------------------------------------------------------------- send
  if (action === 'send') {
    const requestId = String(body?.requestId ?? '');
    if (!UUID_RE.test(requestId)) return jsonResponse({ error: 'Missing request id - reload the page and try again.' }, 400);
    if (accountsError) return jsonResponse({ error: accountsError }, 400);
    const account = accounts.find((a) => a.key === String(body?.accountKey ?? ''));
    if (!account) return jsonResponse({ error: 'Pick one of the owner accounts.' }, 400);
    const amount = Math.round(Number(body?.amount) * 100) / 100;
    if (!Number.isFinite(amount) || amount <= 0) return jsonResponse({ error: 'Enter an amount above zero.' }, 400);
    const cap = maxPerSend();
    if (cap && amount > cap) return jsonResponse({ error: `One withdrawal can be at most ${peso(cap)} (XENDIT_OWNER_MAX_PER_SEND).` }, 400);
    const note = String(body?.note ?? '').trim().slice(0, 200);

    const key = payoutKeyFor(isTest);
    if (!key) return jsonResponse({ error: `No valid ${isTest ? 'test' : 'live'} Xendit payout key.` }, 500);

    const prep = await supabase.rpc('_owner_payout_prepare', {
      p_request_id: requestId, p_is_test: isTest, p_sent_by: username, p_amount: amount, p_account_key: account.key,
      p_channel_code: account.channel_code, p_channel_name: account.channel_name || account.label || account.channel_code,
      p_account_number: account.account_number, p_account_name: account.account_name, p_label: account.label || account.key, p_note: note
    });
    if (prep.error) return jsonResponse({ error: prep.error.message }, 400);
    const row = prep.data?.[0];
    if (!row) return jsonResponse({ error: 'Could not prepare the withdrawal.' }, 500);
    if (!row.send) {
      // Same request again after it already went through (or was refused): report it, never pay twice.
      return jsonResponse({ isTest, done: true, status: row.status, note: `This withdrawal was already handled (${row.status}).` });
    }

    // Enough in Xendit? Only for a new row - a re-send of a 'Creating' row may already have been taken.
    if (row.is_new) {
      const balance = await readBalance(isTest);
      if (balance !== null && balance < Number(row.amount)) {
        await supabase.rpc('_payroll_payout_record', {
          p_payout_id: row.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: 'Not sent - not enough in the Xendit balance', p_estimated_arrival: null, p_body: null
        });
        return jsonResponse({ error: `Not enough in Xendit: need ${peso(Number(row.amount))}, available ${peso(balance)}.`, done: true }, 400);
      }
    }

    const description = left(`Owner withdrawal RS Pet Stop${note ? ' - ' + note : ''}`, 100);
    let result;
    try {
      result = await createPayout(key, row.payout_id, {
        reference_id: row.reference_id,
        channel_code: row.channel_code,
        account_number: row.account_number,
        account_holder_name: row.account_name,
        amount: Number(row.amount),
        description
      });
    } catch (err) {
      // No answer: stays 'Creating'. The page keeps the same requestId, so sending again re-uses the same key.
      console.error('xendit-owner-payout: create, no answer', row.payout_id, err);
      return jsonResponse({ error: 'Xendit didn\'t answer. Press Refresh Status before trying again - it won\'t pay twice.', retrySame: true }, 502);
    }
    if (result.ok && result.body?.id) {
      await supabase.rpc('_payroll_payout_record', { p_payout_id: row.payout_id, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
      const status = String(result.body.status || '').toUpperCase();
      if (status === 'FAILED') return jsonResponse({ error: `Xendit refused it: ${result.body.failure_code || 'FAILED'}`, done: true }, 400);
      return jsonResponse({ isTest, done: true, status, amount: Number(row.amount) });
    }
    if (result.status >= 500 || result.status === 429 || result.status === 409) {
      console.error('xendit-owner-payout: create', result.status, JSON.stringify(result.body));
      return jsonResponse({ error: `${xenditMessage(result)} - press Refresh Status before trying again.`, retrySame: true }, 502);
    }
    // Refused (bad account, below the minimum, no permission...): nothing was created.
    await supabase.rpc('_payroll_payout_record', {
      p_payout_id: row.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
      p_error: xenditMessage(result), p_estimated_arrival: null, p_body: result.body
    });
    return jsonResponse({ error: xenditMessage(result), done: true }, 400);
  }

  // ---------------------------------------------------------------- refresh
  if (action === 'refresh') {
    const open = await supabase.rpc('_owner_payouts_open', {});
    if (open.error) return jsonResponse({ error: open.error.message }, 500);
    const rows: any[] = open.data ?? [];
    let updated = 0;
    for (const p of rows) {
      const key = payoutKeyFor(p.is_test);
      if (!key) continue;
      const result = p.xendit_payout_id ? await getPayout(key, p.xendit_payout_id) : await findPayoutByReference(key, p.reference_id);
      if (result.ok && result.body?.id) {
        await supabase.rpc('_payroll_payout_record', { p_payout_id: p.payout_id, p_reference_id: null, p_error: null, ...recordArgs(result.body) });
        updated++;
      } else if (!p.xendit_payout_id && result.ok && !result.body && Number(p.age_seconds) > 600) {
        // Never reached Xendit (10+ minutes, nothing with our reference): mark it so a new withdrawal can be made.
        await supabase.rpc('_payroll_payout_record', {
          p_payout_id: p.payout_id, p_reference_id: null, p_status: null, p_xendit_id: null, p_failure_code: null,
          p_error: 'Not created at Xendit - make a new withdrawal', p_estimated_arrival: null, p_body: null
        });
        updated++;
      }
    }
    return jsonResponse({ isTest, checked: rows.length, updated });
  }

  return jsonResponse({ error: 'Unknown action.' }, 400);
});

function left(s: string, n: number) {
  return s.length > n ? s.slice(0, n) : s;
}
