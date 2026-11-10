// Xendit Payouts API v2 (money out to GCash / Maya / bank accounts) - used by xendit-payroll-payout and
// xendit-webhook. https://developers.xendit.co/api-reference/#payouts

const API = 'https://api.xendit.co';

function auth(key: string) {
  return { 'Authorization': 'Basic ' + btoa(key + ':') };
}

export type XenditResult = { ok: boolean; status: number; body: any };

export async function createPayout(key: string, idempotencyKey: string, payout: {
  reference_id: string;
  channel_code: string;
  account_number: string;
  account_holder_name: string;
  amount: number;
  description: string;
}): Promise<XenditResult> {
  const response = await fetch(`${API}/v2/payouts`, {
    method: 'POST',
    headers: { ...auth(key), 'Content-Type': 'application/json', 'Idempotency-key': idempotencyKey },
    body: JSON.stringify({
      reference_id: payout.reference_id,
      channel_code: payout.channel_code,
      channel_properties: { account_number: payout.account_number, account_holder_name: payout.account_holder_name },
      amount: payout.amount,
      currency: 'PHP',
      description: payout.description
    })
  });
  return { ok: response.ok, status: response.status, body: await response.json().catch(() => null) };
}

export async function getPayout(key: string, payoutId: string): Promise<XenditResult> {
  const response = await fetch(`${API}/v2/payouts/${encodeURIComponent(payoutId)}`, { headers: auth(key) });
  return { ok: response.ok, status: response.status, body: await response.json().catch(() => null) };
}

// For a create call that never answered: did Xendit make it? (reference_id is ours.)
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

// What _payroll_payout_record takes from a payout object.
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
