// Which Xendit secrets to use: used by xendit-create-invoice, xendit-pos-payment and xendit-webhook.
// Secrets (`npx supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   XENDIT_TEST_SECRET_KEY, XENDIT_LIVE_SECRET_KEY         - Xendit Dashboard > Settings > API Keys, one per mode.
//                                                            Need "Money-in: Write" permission.
//   XENDIT_TEST_CALLBACK_TOKEN, XENDIT_LIVE_CALLBACK_TOKEN - Settings > Webhooks > "View webhook verification
//                                                            token", one per mode.
// XenditSettings."LiveMode" picks the mode for new payments: sql/supabase_xendit_live_mode.sql.

// A key in the wrong secret counts as missing, so real charges can't be recorded as test ones or the reverse.
export function secretKeyFor(isTest: boolean): string | null {
  const key = Deno.env.get(isTest ? 'XENDIT_TEST_SECRET_KEY' : 'XENDIT_LIVE_SECRET_KEY');
  return key?.startsWith(isTest ? 'xnd_development_' : 'xnd_production_') ? key : null;
}

// Xendit Ledger (xendit-ledger) reads the balance + transactions, which need "Balance: Read" and
// "Transactions: Read" on the key. If the main key doesn't have them, make a separate read-only key in the
// Xendit Dashboard (Settings > API Keys) and save it as XENDIT_LIVE_READ_KEY / XENDIT_TEST_READ_KEY.
// Without one, the main secret key is used.
export function readKeyFor(isTest: boolean): string | null {
  const key = Deno.env.get(isTest ? 'XENDIT_TEST_READ_KEY' : 'XENDIT_LIVE_READ_KEY');
  return key?.startsWith(isTest ? 'xnd_development_' : 'xnd_production_') ? key : secretKeyFor(isTest);
}

// Payroll payouts (xendit-payroll-payout, xendit-webhook) send money OUT, which needs "Money-out: Write" on the
// key. Keep that permission off the payments key: make a separate key and save it as XENDIT_LIVE_PAYOUT_KEY /
// XENDIT_TEST_PAYOUT_KEY. Without one, the main secret key is tried (and Xendit refuses if it can't pay out).
export function payoutKeyFor(isTest: boolean): string | null {
  const key = Deno.env.get(isTest ? 'XENDIT_TEST_PAYOUT_KEY' : 'XENDIT_LIVE_PAYOUT_KEY');
  return key?.startsWith(isTest ? 'xnd_development_' : 'xnd_production_') ? key : secretKeyFor(isTest);
}

export function callbackTokenFor(isTest: boolean): string | null {
  return Deno.env.get(isTest ? 'XENDIT_TEST_CALLBACK_TOKEN' : 'XENDIT_LIVE_CALLBACK_TOKEN') || null;
}
