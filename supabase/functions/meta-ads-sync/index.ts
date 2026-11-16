// Meta Ads billing sync - pulls wallet loads + daily billing charges from the ad account's activity
// log and logs them via service_log_meta_ads_events (sql/supabase_meta_ads_billing_sync.sql). Each
// wallet load becomes one META-ADS Expense Journal entry; charges are stored for reconciliation only.
//
// POST {}                          -> last 3 days (what the daily cron sends)
// POST { since: "YYYY-MM-DD" }     -> backfill from that Manila date to today
//   -> { fundings_logged, charges_logged, duplicates, available_balance, events_seen }
//
// Idempotent (every event is keyed), so re-runs and overlapping ranges never double-log - which is
// why it can sit behind just the anon key like chatbot-followup-dispatcher.
//
// Secrets: META_ADS_ACCESS_TOKEN_<accountId> (per-account token, e.g. META_ADS_ACCESS_TOKEN_135164877 -
// needed when the ad accounts sit in DIFFERENT Business Managers, one System User token each, ads_read)
// falling back to META_ADS_ACCESS_TOKEN (one token for every account in the same business),
// META_AD_ACCOUNTS (optional, "accountId:Store,accountId:Store" - one entry per store's ad account,
// the expense is booked to that store/warehouse (Amaya or GMA; no store given = Amaya); default
// "1642403133986144:GMA" = RSpetstop Gma),
// FACEBOOK_GRAPH_API_VERSION (optional, default v21.0). Ads are billed per AD ACCOUNT, not per Page -
// if both Pages' ads run from one ad account, one entry covers both.
//
// Deploy: supabase functions deploy meta-ads-sync --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';
const DEFAULT_AD_ACCOUNTS = '1642403133986144:GMA';
const MONEY_EVENTS = new Set(['funding_event_successful', 'ad_account_billing_charge']);
const MAX_PAGES = 50;

// The Meta Ads page's "Refresh from Meta" button calls this from the browser, so it needs CORS
// (same headers as facebook-token-health). The cron calls it server-side and ignores them.
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

function manilaDate(offsetDays = 0): string {
  const d = new Date(Date.now() + 8 * 3600_000 + offsetDays * 86400_000);
  return d.toISOString().slice(0, 10);
}

// deno-lint-ignore no-explicit-any
async function graphGet(url: string): Promise<any> {
  const res = await fetch(url);
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.error) {
    throw new Error(`Graph API: ${body?.error?.message ?? res.statusText}`);
  }
  return body;
}

// Currency -> PHP rate per day (ECB via Frankfurter, same source as claude-receipt-log). One time-series
// call covers the whole range; each event uses the latest business-day rate on or before its date
// (weekends/holidays fall back to the previous business day). If Frankfurter is down, every event
// gets open.er-api.com's latest rate instead.
async function phpRateLookup(currency: string, since: string, until: string): Promise<(date: string) => { rate: number; source: string } | null> {
  const start = new Date(Date.parse(since) - 7 * 86400_000).toISOString().slice(0, 10);
  try {
    const res = await fetch(`https://api.frankfurter.app/${start}..${until}?from=${currency}&to=PHP`);
    if (res.ok) {
      const body = await res.json();
      const days = Object.entries(body?.rates ?? {})
        // deno-lint-ignore no-explicit-any
        .map(([d, r]: [string, any]) => [d, Number(r?.PHP)] as [string, number])
        .filter(([, r]) => r > 0)
        .sort(([a], [b]) => (a < b ? -1 : 1));
      if (days.length) {
        return (date: string) => {
          let hit: [string, number] | null = null;
          for (const day of days) { if (day[0] <= date) hit = day; else break; }
          return hit ? { rate: hit[1], source: `frankfurter.app ECB ${hit[0]}` } : null;
        };
      }
    }
  } catch (err) {
    console.warn('frankfurter rate lookup failed:', err);
  }
  try {
    const res = await fetch(`https://open.er-api.com/v6/latest/${currency}`);
    const body = await res.json();
    const rate = Number(body?.rates?.PHP);
    if (rate > 0) return () => ({ rate, source: 'open.er-api.com latest' });
  } catch (err) {
    console.warn('open.er-api rate lookup failed:', err);
  }
  return () => null; // events are skipped (skipped_no_rate) and retried next run
}

const manilaDateOf = (iso: string): string => new Date(Date.parse(iso) + 8 * 3600_000).toISOString().slice(0, 10);

const centavos = (v: unknown): number | null => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) / 100 : null;
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'POST only.' }, 405);

  const sharedToken = Deno.env.get('META_ADS_ACCESS_TOKEN') || '';
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'Function is not configured.' }, 500);

  const accounts = (Deno.env.get('META_AD_ACCOUNTS') || DEFAULT_AD_ACCOUNTS)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      const [id, ...wh] = s.split(':');
      return { accountId: id.trim().replace(/^act_/, ''), warehouse: wh.join(':').trim() || 'Amaya' };
    });
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
  const base = `https://graph.facebook.com/${graphVersion}`;

  // deno-lint-ignore no-explicit-any
  let body: any = {};
  try { body = await req.json(); } catch { /* empty body = defaults */ }
  let since = typeof body?.since === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.since) ? body.since : manilaDate(-3);
  if (since < '2020-01-01') since = '2020-01-01';
  const until = manilaDate(1);

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // Each account syncs independently - one failing (e.g. token lacks access) doesn't block the other.
  const results = [];
  for (const { accountId, warehouse } of accounts) {
    const token = Deno.env.get(`META_ADS_ACCESS_TOKEN_${accountId}`) || sharedToken;
    if (!token) {
      results.push({ ad_account: `act_${accountId}`, warehouse, error: `No token: set META_ADS_ACCESS_TOKEN_${accountId} or META_ADS_ACCESS_TOKEN.` });
      continue;
    }
    results.push(await syncAccount({ supabase, base, token, accountId, warehouse, since, until }));
  }
  const anyFailed = results.some((r) => 'error' in r);
  return jsonResponse({ since, accounts: results }, anyFailed ? 502 : 200);
});

async function syncAccount(
  // deno-lint-ignore no-explicit-any
  { supabase, base, token, accountId, warehouse, since, until }: { supabase: any; base: string; token: string; accountId: string; warehouse: string; since: string; until: string }
): Promise<Record<string, unknown>> {
  try {
    // 1. Account + balance
    const acct = await graphGet(`${base}/act_${accountId}?${new URLSearchParams({
      fields: 'name,currency,balance,amount_spent,spend_cap,funding_source_details',
      access_token: token
    })}`);
    const display: string = acct?.funding_source_details?.display_string ?? '';
    // "Available Balance (PHP597.32)" / "Available Balance (€4.90 EUR)" - first number inside the parens.
    const balMatch = display.replace(/,/g, '').match(/\([^)\d-]*(-?\d+(?:\.\d+)?)/);
    const availableBalance = balMatch ? Number(balMatch[1]) : null;

    // 2. Activities (paged)
    // deno-lint-ignore no-explicit-any
    const events: any[] = [];
    let url: string | null = `${base}/act_${accountId}/activities?${new URLSearchParams({
      fields: 'event_type,event_time,extra_data,object_name',
      since,
      until,
      limit: '200',
      access_token: token
    })}`;
    let seen = 0;
    for (let page = 0; url && page < MAX_PAGES; page++) {
      const res = await graphGet(url);
      for (const ev of res?.data ?? []) {
        seen++;
        if (MONEY_EVENTS.has(ev.event_type)) events.push(ev);
      }
      url = res?.paging?.next ?? null;
    }

    // Non-PHP account (Amaya = EUR): attach the day's rate to each money event.
    const currency = String(acct?.currency ?? 'PHP').toUpperCase();
    if (currency !== 'PHP' && events.length) {
      const rateFor = await phpRateLookup(currency, since, until);
      for (const ev of events) {
        const r = rateFor(manilaDateOf(ev.event_time));
        if (r) { ev.php_rate = r.rate; ev.rate_source = r.source; }
      }
    }

    const { data, error } = await supabase.rpc('service_log_meta_ads_events', {
      p_ad_account_id: accountId,
      p_ad_account_name: acct?.name ?? null,
      p_events: events,
      p_warehouse: warehouse
    });
    if (error) throw new Error(`service_log_meta_ads_events: ${error.message}`);
    const row = Array.isArray(data) ? data[0] : data;

    const result = {
      ad_account: `act_${accountId}`,
      warehouse,
      events_seen: seen,
      fundings_logged: row?.fundings_logged ?? 0,
      charges_logged: row?.charges_logged ?? 0,
      duplicates: row?.duplicates ?? 0,
      skipped_no_rate: row?.skipped_no_rate ?? 0,
      currency,
      available_balance: availableBalance
    };

    await supabase.rpc('service_set_meta_ads_snapshot', {
      p_ad_account_id: accountId,
      p_ad_account_name: acct?.name ?? null,
      p_currency: acct?.currency ?? null,
      p_available_balance: availableBalance,
      p_unbilled_spend: centavos(acct?.balance),
      p_amount_spent: centavos(acct?.amount_spent),
      p_spend_cap: centavos(acct?.spend_cap),
      p_result: `ok: ${JSON.stringify(result)}`,
      p_store: warehouse
    });

    return result;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`meta-ads-sync act_${accountId} failed:`, message);
    // Record the failure on the snapshot so it's visible without digging through function logs.
    await supabase.from('MetaAdsAccountSnapshot').upsert({
      AdAccountId: accountId,
      LastSyncAtUtc: new Date().toISOString(),
      LastSyncResult: `error: ${message}`.slice(0, 1000)
    }).then(() => {}, () => {});
    return { ad_account: `act_${accountId}`, warehouse, error: message };
  }
}
