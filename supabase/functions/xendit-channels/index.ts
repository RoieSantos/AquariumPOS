// Lists the payment channels on the Xendit account (GET /payment_channels) for the current mode
// (XenditSettings."LiveMode"), so the Xendit Payments page can show which are activated, and customer
// pages can name only the ways to pay that actually work. Read-only; the secret key never leaves this
// function. Kept for 10 minutes per mode so a busy page doesn't call Xendit every time.
//
// Deploy: npx supabase functions deploy xendit-channels --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt
// (public: the list of a shop's payment methods is not secret).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { secretKeyFor } from '../_shared/xendit-keys.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

const CACHE_MS = 10 * 60 * 1000;
const cache = new Map<boolean, { at: number; channels: unknown[]; xenditCount: number }>();

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: modeRows, error: modeError } = await supabase.rpc('_xendit_current_mode', {});
  if (modeError || !modeRows?.[0]) {
    console.error('xendit-channels: mode check failed', modeError?.message);
    return jsonResponse({ error: 'Could not read the Xendit mode.' }, 500);
  }
  // ?mode=live|test reads that mode's list instead of the current one.
  const asked = new URL(req.url).searchParams.get('mode');
  const isTest: boolean = asked === 'live' ? false : asked === 'test' ? true : modeRows[0].is_test;

  const cached = cache.get(isTest);
  if (cached && Date.now() - cached.at < CACHE_MS) return jsonResponse({ isTest, channels: cached.channels, xenditCount: cached.xenditCount, cached: true });

  const secretKey = secretKeyFor(isTest);
  if (!secretKey) return jsonResponse({ error: `No valid ${isTest ? 'test' : 'live'} secret key.` }, 500);

  const response = await fetch('https://api.xendit.co/payment_channels', {
    headers: { 'Authorization': 'Basic ' + btoa(secretKey + ':') }
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || !Array.isArray(body)) {
    console.error('xendit-channels:', response.status, JSON.stringify(body));
    return jsonResponse({ error: `Xendit ${response.status}: ${body?.message || body?.error_code || 'no channel list'}` }, 502);
  }

  const channels = body
    .filter((c: any) => !c.currency || c.currency === 'PHP')
    .map((c: any) => ({ code: c.channel_code, name: c.name, category: c.channel_category, enabled: c.is_enabled === true }));
  cache.set(isTest, { at: Date.now(), channels, xenditCount: body.length });
  return jsonResponse({ isTest, channels, xenditCount: body.length, cached: false });
});
