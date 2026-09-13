// Sends a staff-authored reply to a customer on the GMA Conversations page (docs/gma-conversations.
// html) - the "own inbox instead of Pancake" feature: still Facebook Messenger underneath (same
// page/webhook as supabase/functions/facebook-messenger-webhook), just our own interface for staff
// to reply directly rather than a third-party CRM.
//
// Split into its own function (rather than folded into facebook-messenger-webhook) because that
// function's POST handler verifies Facebook's X-Hub-Signature-256 on every request - a
// browser-originated staff reply has no such signature and was never meant to carry one. This
// function is a plain CORS-enabled endpoint instead, called directly from the browser like
// delivery-toll-price/delivery-lalamove-* already are (see docs/js/deliveryQuote.js).
//
// Two steps: (1) admin_send_chatbot_message (supabase_chatbot_staff_reply.sql) validates the admin
// session and logs the message - that RPC is the only thing that touches ChatbotMessages/
// ChatbotConversations, so this function never queries those tables directly; (2) on success, the
// actual Messenger delivery via the same Graph API call facebook-messenger-webhook's
// sendMessengerReply makes, reusing FACEBOOK_PAGE_ACCESS_TOKEN/FACEBOOK_GRAPH_API_VERSION - already
// set as secrets for that function; Supabase secrets are project-wide, so nothing new to configure.
//
// Deploy: supabase functions deploy chatbot-staff-reply --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';

const DEFAULT_GRAPH_VERSION = 'v21.0';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

// Live-updates docs/gma-conversations.html for any OTHER open staff tab (the sender's own tab
// already refreshes locally on a successful send) - same channel/pattern as facebook-messenger-
// webhook's broadcastGmaEvent, duplicated here rather than shared since these are two independent
// Edge Functions. See that file's comment for why Broadcast (not postgres_changes).
async function broadcastGmaEvent(supabase: ReturnType<typeof createClient>, psid: string): Promise<void> {
  try {
    const channel = supabase.channel('gma-inbox');
    await new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      const timer = setTimeout(finish, 3000);
      channel.subscribe((status: string) => {
        if (status === 'SUBSCRIBED' && !settled) {
          clearTimeout(timer);
          channel.send({ type: 'broadcast', event: 'new_message', payload: { psid } }).finally(finish);
        }
      });
    });
    await channel.unsubscribe();
  } catch (err) {
    console.error('Failed to broadcast GMA inbox event:', err instanceof Error ? err.message : err);
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const pageAccessToken = Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN');
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;

  if (!supabaseUrl || !serviceRoleKey || !pageAccessToken) {
    return jsonResponse({ error: 'chatbot-staff-reply is missing one or more required secrets.' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let psid: string;
  let message: string;
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    psid = String(body.psid ?? '');
    message = String(body.message ?? '');
    if (!adminUsername || !adminPassword || !psid || !message.trim()) {
      throw new Error('missing field');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, psid, message }.' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { error: dbError } = await supabase.rpc('admin_send_chatbot_message', {
    p_admin_username: adminUsername,
    p_admin_password: adminPassword,
    p_psid: psid,
    p_message: message
  });

  if (dbError) {
    // Covers both "not authorized" and "no conversation found" - the RPC's own exception message
    // is safe to relay as-is, same as every other admin_* RPC's error handling in the portal JS.
    return jsonResponse({ error: dbError.message }, 400);
  }

  await broadcastGmaEvent(supabase, psid);

  try {
    const res = await fetch(`https://graph.facebook.com/${graphVersion}/me/messages?access_token=${pageAccessToken}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ recipient: { id: psid }, message: { text: message }, messaging_type: 'RESPONSE' })
    });

    if (!res.ok) {
      const detail = await res.text();
      // The message is already logged in ChatbotMessages at this point (staff really did say it) -
      // this failure means Facebook itself rejected delivery (e.g. outside the 24h window), which
      // the customer needs to be reached about some other way (native Messenger/Business Suite).
      return jsonResponse({ ok: false, loggedOnly: true, error: `Message saved but Facebook delivery failed: ${detail}` }, 502);
    }
  } catch (err) {
    return jsonResponse({ ok: false, loggedOnly: true, error: err instanceof Error ? err.message : 'Could not reach Facebook.' }, 502);
  }

  return jsonResponse({ ok: true });
});
