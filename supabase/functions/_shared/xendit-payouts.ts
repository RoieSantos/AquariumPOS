// Xendit Payouts (money out to GCash / Maya / bank accounts) - used by xendit-payroll-payout, xendit-owner-payout
// and xendit-webhook. v2: https://developers.xendit.co/api-reference/#payouts
// v3: https://docs.xendit.co/apidocs/create-payout-v3. Xendit support (ticket 2805116): no extra per-payout fee on
// v2, but legacy APIs may carry a USD 250 / month maintenance fee; only v3 has processor_reference (not guaranteed
// to match the recipient's app).
//
// Which API: PortalSettings 'XENDIT_PAYOUT_API' = 'v2' (default) or 'v3'. With 'v3', only channels with a
// confirmed v3 routing pair go through v3 (v3Routing below); everything else stays on v2.
// Each payout row keeps the API it was first sent with (XenditPayouts.ApiVersion) and a re-send always uses that
// one - the Idempotency-key only protects against paying twice within the same API.
// sql/supabase_xendit_payouts_v3.sql
//
// v3 objects are turned into the v2 shape our code / SQL / pages already use (normalizeV3): payout_id -> id, and
// the extra v3 statuses map onto ACCEPTED / REQUESTED (still going) or FAILED (rejected / expired, nothing paid).
// The raw v3 object (with processor_reference) is still saved in XenditPayouts.LastResponse.

const API = 'https://api.xendit.co';
const V3_API_VERSION = '2025-09-01';

export type PayoutApi = 'v2' | 'v3';

function auth(key: string) {
  return { 'Authorization': 'Basic ' + btoa(key + ':') };
}

export type XenditResult = { ok: boolean; status: number; body: any };

// Where a payout can go, and its v3 routing pair. v3 uses routing_type_1 / routing_value_1 instead of v2's
// channel_code, and v2 codes must NOT be reused as v3 values. The pairs below are the ones Xendit support
// confirmed (ticket 2805116, 2026-11-19). `code` is what Payroll Setup saves (StaffUsers.PayoutChannelCode) and the
// owner accounts secret uses: the v2 channel code where there is one; v3Only = no v2 code, v3 only.
// Add a row only once Xendit confirms its pair (and a test payout succeeds); keep
// sql/supabase_xendit_payout_channels_v3_check.sql's list in step.
// Also replaces GET /payouts_channels (legacy - no v3 equivalent) for the Payroll Setup list once on v3.
export const PH_PAYOUT_DESTINATIONS: { code: string; name: string; category: 'EWALLET' | 'BANK'; type: string; value: string; v3Only?: boolean }[] = [
  { code: 'PH_GCASH', name: 'GCash', category: 'EWALLET', type: 'WALLET', value: 'PH_GCASH' },
  { code: 'PH_PAYMAYA', name: 'Maya (PayMaya Wallet)', category: 'EWALLET', type: 'WALLET', value: 'PH_PAYMAYA' },
  { code: 'PH_BPI', name: 'BPI', category: 'BANK', type: 'SWIFT', value: 'BPGOPHM1' },
  { code: 'PH_BDO', name: 'BDO Unibank', category: 'BANK', type: 'SWIFT', value: 'BNORPHMM' },
  { code: 'PH_BDO_NETWORK_BANK', name: 'BDO Network Bank', category: 'BANK', type: 'SWIFT', value: 'ONNRPHM1', v3Only: true },
  { code: 'PH_MAYA_BANK', name: 'Maya Bank', category: 'BANK', type: 'SWIFT', value: 'PAPHPHM1', v3Only: true },
  { code: 'PH_GOTYME', name: 'GoTyme Bank', category: 'BANK', type: 'SWIFT', value: 'GOTYPHM2' } // confirmed 2026-11-20
];

function destination(channelCode: string) {
  const code = String(channelCode ?? '').trim().toUpperCase();
  return PH_PAYOUT_DESTINATIONS.find((d) => d.code === code) ?? null;
}

export function v3Routing(channelCode: string): { type: string; value: string } | null {
  const d = destination(channelCode);
  return d ? { type: d.type, value: d.value } : null;
}

export function isV3Setting(setting: string | null): boolean {
  return String(setting ?? '').trim().toLowerCase() === 'v3';
}

// The API a NEW payout should use. A v3-only destination always goes to v3 (v2 has no code for it).
export function chooseApi(setting: string | null, channelCode: string): PayoutApi {
  const d = destination(channelCode);
  if (d?.v3Only) return 'v3';
  return isV3Setting(setting) && d ? 'v3' : 'v2';
}

export async function readPayoutApiSetting(supabase: any): Promise<string> {
  const { data, error } = await supabase.from('PortalSettings').select('SettingValue').eq('SettingKey', 'XENDIT_PAYOUT_API').maybeSingle();
  if (error) console.warn('xendit-payouts: no XENDIT_PAYOUT_API setting', error.message);
  return String(data?.SettingValue ?? 'v2');
}

// The API for one payout row: a new row is stamped with chooseApi; a re-send keeps what the row was stamped with.
// null = couldn't tell (don't send - the wrong API could pay twice).
export async function payoutApiFor(supabase: any, payoutId: string, isNew: boolean, channelCode: string, setting: string): Promise<PayoutApi | null> {
  const wanted = isNew ? chooseApi(setting, channelCode) : null;
  const { data, error } = await supabase.rpc('_payout_api_version', { p_payout_id: payoutId, p_api: wanted });
  if (error) {
    // Most likely supabase_xendit_payouts_v3.sql isn't run yet: every row is v2 then. A new row that couldn't be
    // stamped also reads back as v2 later (the column's default), so v2 is safe for it.
    console.warn('xendit-payouts: _payout_api_version', payoutId, error.message);
    return isNew ? 'v2' : (error.message.includes('_payout_api_version') ? 'v2' : null);
  }
  return data === 'v3' ? 'v3' : 'v2';
}

// The API a stored payout row was sent with, for Refresh (null = couldn't tell).
export async function storedPayoutApi(supabase: any, payoutId: string): Promise<PayoutApi | null> {
  const { data, error } = await supabase.rpc('_payout_api_version', { p_payout_id: payoutId, p_api: null });
  if (error) return error.message.includes('_payout_api_version') ? 'v2' : null;
  return data === 'v3' ? 'v3' : 'v2';
}

// v3 requires recipient.address.street_line_1 and city in live (the docs say optional - first live owner withdrawal
// 2026-11-19 got API_VALIDATION_ERROR without them). We don't keep structured addresses for employees / owner
// accounts, so every v3 payout carries RS Pet Stop's registered (BIR 2303) address - the same one on the Xendit
// account and the website footer.
const PAYOUT_ADDRESS = {
  country: 'PH',
  street_line_1: 'Blk 17 Lot 16 Masson St., Pineview Filinvest, Sahud Ulan',
  city: 'Tanza',
  province_state: 'Cavite',
  postal_code: '4108'
};

function splitName(full: string): { given: string; surname: string } {
  const words = String(full ?? '').trim().split(/\s+/).filter(Boolean);
  if (words.length <= 1) return { given: (words[0] ?? '-').slice(0, 50), surname: (words[0] ?? '-').slice(0, 50) };
  return { given: words.slice(0, -1).join(' ').slice(0, 50), surname: words[words.length - 1].slice(0, 50) };
}

const V3_STATUS: Record<string, string> = {
  ACCEPTED: 'ACCEPTED', PENDING_COMPLIANCE_ASSESSMENT: 'ACCEPTED', PENDING_COMPLIANCE: 'ACCEPTED', ROUTING: 'ACCEPTED',
  READY: 'REQUESTED', LOCKED: 'REQUESTED', REQUESTED: 'REQUESTED',
  SUCCEEDED: 'SUCCEEDED', FAILED: 'FAILED', CANCELLED: 'CANCELLED', REVERSED: 'REVERSED',
  REJECTED: 'FAILED', EXPIRED: 'FAILED'
};

// v3 payout object -> the v2 fields we read (id, status, failure_code, estimated_arrival_time), raw fields kept.
export function normalizeV3(raw: any) {
  if (!raw || typeof raw !== 'object' || !raw.payout_id) return raw;
  const s = String(raw.status ?? '').toUpperCase();
  if (!V3_STATUS[s]) console.warn('xendit-payouts: unknown v3 status', s, raw.payout_id);
  return {
    ...raw,
    id: raw.payout_id,
    status: V3_STATUS[s] ?? 'REQUESTED', // unknown = still going, never "failed" (that would free it to pay again)
    xendit_status: raw.status,
    failure_code: raw.failure_code ?? (s === 'REJECTED' || s === 'EXPIRED' ? s : null),
    api_version: 'v3'
  };
}

export async function createPayout(key: string, idempotencyKey: string, payout: {
  api?: PayoutApi;
  reference_id: string;
  channel_code: string;
  account_number: string;
  account_holder_name: string;
  amount: number;
  description: string;
  // v3 only: who the recipient is to us and what the money is for. Defaults: EMPLOYEE / SALARY.
  relationship?: string;
  purpose_code?: string;
  // Xendit emails a transaction proof (beneficiary, bank, account number, bank reference, description) when set -
  // test mode too. email_to is required for it to be sent. It can't be resent later (Xendit support, ticket 2805101).
  receipt_email_to?: string[];
  receipt_email_cc?: string[];
}): Promise<XenditResult> {
  const emailTo = (payout.receipt_email_to ?? []).filter(Boolean);
  const emailCc = (payout.receipt_email_cc ?? []).filter(Boolean);
  const receipt = emailTo.length ? { receipt_notification: { email_to: emailTo, ...(emailCc.length ? { email_cc: emailCc } : {}) } } : {};

  if (payout.api === 'v3') {
    const routing = v3Routing(payout.channel_code);
    if (!routing) return { ok: false, status: 400, body: { error_code: 'V3_ROUTING_UNKNOWN', message: `No v3 routing for ${payout.channel_code}` } };
    const name = splitName(payout.account_holder_name);
    const response = await fetch(`${API}/v3/payouts`, {
      method: 'POST',
      headers: { ...auth(key), 'Content-Type': 'application/json', 'idempotency-key': idempotencyKey, 'api-version': V3_API_VERSION },
      body: JSON.stringify({
        reference_id: payout.reference_id,
        recipient: {
          type: 'INDIVIDUAL',
          given_name: name.given,
          surname: name.surname,
          relationship: payout.relationship ?? 'EMPLOYEE',
          address: PAYOUT_ADDRESS,
          account_details: {
            currency: 'PHP',
            account_country: 'PH',
            account_holder_name: payout.account_holder_name,
            account_number: payout.account_number,
            routing_type_1: routing.type,
            routing_value_1: routing.value
          }
        },
        // destination_amount: the employee gets exactly this. v3 amounts are in centavos.
        payout_details: { source_currency: 'PHP', destination_currency: 'PHP', destination_amount: Math.round(payout.amount * 100) },
        source_of_fund: 'BUSINESS_REVENUE',
        purpose_code: payout.purpose_code ?? 'SALARY',
        description: String(payout.description ?? '').slice(0, 100),
        ...receipt
      })
    });
    const body = await response.json().catch(() => null);
    return { ok: response.ok, status: response.status, body: response.ok ? normalizeV3(body) : body };
  }

  const response = await fetch(`${API}/v2/payouts`, {
    method: 'POST',
    headers: { ...auth(key), 'Content-Type': 'application/json', 'Idempotency-key': idempotencyKey },
    body: JSON.stringify({
      reference_id: payout.reference_id,
      channel_code: payout.channel_code,
      channel_properties: { account_number: payout.account_number, account_holder_name: payout.account_holder_name },
      amount: payout.amount,
      currency: 'PHP',
      description: payout.description,
      ...receipt
    })
  });
  return { ok: response.ok, status: response.status, body: await response.json().catch(() => null) };
}

// v3 payout IDs start with 'po-' (v2: 'disb-...'), so the ID alone says which API to ask.
export async function getPayout(key: string, payoutId: string): Promise<XenditResult> {
  if (String(payoutId).startsWith('po-')) {
    const response = await fetch(`${API}/v3/payouts/${encodeURIComponent(payoutId)}`, {
      headers: { ...auth(key), 'api-version': V3_API_VERSION }
    });
    const body = await response.json().catch(() => null);
    return { ok: response.ok, status: response.status, body: response.ok ? normalizeV3(body) : body };
  }
  const response = await fetch(`${API}/v2/payouts/${encodeURIComponent(payoutId)}`, { headers: auth(key) });
  return { ok: response.ok, status: response.status, body: await response.json().catch(() => null) };
}

// Cancel a payout that Xendit hasn't handed to the bank yet (ACCEPTED; v3 also PENDING_COMPLIANCE_ASSESSMENT /
// ROUTING). Xendit refuses (403 INELIGIBLE_TRANSACTION_STATUS / CANCELLATION_NOT_ALLOWED) once it's past that point.
// v3: https://docs.xendit.co/apidocs/cancel-payout. Used by xendit-payout-cancel.
export async function cancelPayout(key: string, payoutId: string): Promise<XenditResult> {
  if (String(payoutId).startsWith('po-')) {
    const response = await fetch(`${API}/v3/payouts/${encodeURIComponent(payoutId)}/cancel`, {
      method: 'POST',
      headers: { ...auth(key), 'api-version': V3_API_VERSION }
    });
    const body = await response.json().catch(() => null);
    return { ok: response.ok, status: response.status, body: response.ok ? normalizeV3(body) : body };
  }
  const response = await fetch(`${API}/v2/payouts/${encodeURIComponent(payoutId)}/cancel`, { method: 'POST', headers: auth(key) });
  return { ok: response.ok, status: response.status, body: await response.json().catch(() => null) };
}

// For a v2 create call that never answered: did Xendit make it? (reference_id is ours.) v3 has no lookup by
// reference - a v3 row with no Xendit ID is settled by sending it again with the same Idempotency-key.
export async function findPayoutByReference(key: string, referenceId: string): Promise<XenditResult> {
  const response = await fetch(`${API}/v2/payouts?reference_id=${encodeURIComponent(referenceId)}`, { headers: auth(key) });
  const body = await response.json().catch(() => null);
  const list = Array.isArray(body) ? body : Array.isArray(body?.data) ? body.data : [];
  return { ok: response.ok, status: response.status, body: list[0] ?? null };
}

export async function listPayoutChannels(key: string): Promise<XenditResult> {
  const response = await fetch(`${API}/payouts_channels?currency=PHP`, { headers: auth(key) });
  return { ok: response.ok, status: response.status, body: await response.json().catch(() => null) };
}

// What _payroll_payout_record takes from a payout object (v2, or v3 after normalizeV3).
export function recordArgs(payout: any) {
  return {
    p_status: payout?.status ?? null,
    p_xendit_id: payout?.id ?? null,
    p_failure_code: payout?.failure_code ?? null,
    p_estimated_arrival: payout?.estimated_arrival_time ?? null,
    p_body: payout ?? null
  };
}

export function xenditMessage(result: XenditResult): string {
  if (result.status === 401 || result.status === 403 || result.body?.error_code === 'REQUEST_FORBIDDEN_ERROR') {
    return 'The Xendit key can\'t send payouts. Make a key with "Money-out: Write" in the Xendit Dashboard > Settings > API Keys '
      + 'and save it as the XENDIT_LIVE_PAYOUT_KEY secret.';
  }
  return `${result.body?.error_code || 'Xendit ' + result.status}: ${result.body?.message || 'no answer'}`;
}
