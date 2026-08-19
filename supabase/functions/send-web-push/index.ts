// Sends a real Web Push notification to every subscribed device in public.PushSubscriptions
// (see supabase_web_push_subscriptions.sql). Called from Postgres via
// public._trigger_web_push() (supabase_web_push_order_confirmed_trigger.sql) whenever an online
// order transitions into Confirmed/Submitted status - lets the notification come from the Portal
// PWA itself instead of a third-party app like Telegram.
//
// This has to be an Edge Function (not plain SQL, unlike the Telegram send) because Web Push
// requires per-subscriber message encryption (RFC 8291, aes128gcm) and a signed VAPID JWT
// (RFC 8292) - real crypto with no reasonable way to do it from plpgsql. The web-push npm package
// handles both.
//
// Secrets (set via `supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   VAPID_PUBLIC_KEY   - paired with the key embedded in docs/js/pushNotifications.js
//   VAPID_PRIVATE_KEY  - NEVER expose this client-side
//   VAPID_SUBJECT       - a mailto: or https: URL identifying who's sending (Web Push spec
//                          requires one - contact info a push service can reach if something's
//                          wrong, e.g. mailto:admin@rspetstop.com)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected by Supabase for every Edge Function -
// no need to set those manually.
// Deploy: supabase functions deploy send-web-push --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405);
  }

  const vapidPublicKey = Deno.env.get('VAPID_PUBLIC_KEY');
  const vapidPrivateKey = Deno.env.get('VAPID_PRIVATE_KEY');
  const vapidSubject = Deno.env.get('VAPID_SUBJECT');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!vapidPublicKey || !vapidPrivateKey || !vapidSubject) {
    return jsonResponse({ error: 'VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT secrets are not configured on this function.' }, 500);
  }
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are missing (these should be auto-injected).' }, 500);
  }

  let title: string;
  let body: string;
  let url: string;
  try {
    const payload = await req.json();
    title = payload.title || 'RS Pet Stop Portal';
    body = payload.body || '';
    url = payload.url || 'dashboard.html';
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { title, body, url? }.' }, 400);
  }

  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: subs, error } = await supabase.from('PushSubscriptions').select('Endpoint, P256dh, Auth');
  if (error) {
    return jsonResponse({ error: error.message }, 500);
  }

  const notificationPayload = JSON.stringify({ title, body, url });
  let sent = 0;
  let failed = 0;
  const staleEndpoints: string[] = [];

  await Promise.all(
    (subs || []).map(async (sub) => {
      try {
        await webpush.sendNotification(
          { endpoint: sub.Endpoint, keys: { p256dh: sub.P256dh, auth: sub.Auth } },
          notificationPayload
        );
        sent++;
      } catch (err) {
        failed++;
        // 404/410 = the push service says this subscription no longer exists (uninstalled,
        // notifications revoked, etc.) - clean it up so future sends don't keep failing on it.
        const statusCode = (err as { statusCode?: number })?.statusCode;
        if (statusCode === 404 || statusCode === 410) {
          staleEndpoints.push(sub.Endpoint);
        }
      }
    })
  );

  if (staleEndpoints.length > 0) {
    await supabase.from('PushSubscriptions').delete().in('Endpoint', staleEndpoints);
  }

  return jsonResponse({ sent, failed, removedStale: staleEndpoints.length, totalSubscriptions: (subs || []).length });
});
