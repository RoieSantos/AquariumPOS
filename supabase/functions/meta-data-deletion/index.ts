// Meta "Data Deletion Request" callback for the RSPetStopMessenger app.
//
// Meta POSTs here (form field `signed_request`) when someone removes the app or asks Facebook to
// delete their data. We verify the signature with the app secret, delete that user's data, and
// answer with { url, confirmation_code } as Meta requires. The url is docs/data-deletion-status.html,
// which calls GET ?code=<code> on this function to show the status.
//
// What gets deleted is defined in public.meta_delete_user_data (sql/supabase_meta_data_deletion_callback.sql):
// chat data is deleted, orders are kept (BIR) with the Facebook ID blanked. Chat images in the
// chatbot-attachments bucket are removed here first, since SQL can't reach Storage directly.
//
// Meta sends an APP-scoped user_id; our tables hold PAGE-scoped PSIDs, which are often different.
// Finding nothing is normal and still reported to Meta as completed (we hold no data under that ID).
//
// Secrets: FACEBOOK_APP_SECRET (already set for facebook-messenger-webhook).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
// Meta calls without a Supabase JWT, so deploy with --no-verify-jwt:
//   supabase functions deploy meta-data-deletion --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt
// Then App Dashboard > Settings > Basic > Data Deletion Request URL:
//   https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/meta-data-deletion

import { createClient } from 'npm:@supabase/supabase-js@2';

const STATUS_PAGE = 'https://rspetstop.com/data-deletion-status.html';
const BUCKET = 'chatbot-attachments';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'content-type, apikey, authorization',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

function base64UrlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4);
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

async function hmacSha256(key: string, message: string): Promise<Uint8Array> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(message)));
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// Returns Meta's user_id if the signed_request is genuine, otherwise null.
async function parseSignedRequest(signedRequest: string, appSecret: string): Promise<string | null> {
  const [sig, payload] = signedRequest.split('.', 2);
  if (!sig || !payload) return null;
  const expected = await hmacSha256(appSecret, payload);
  if (!bytesEqual(base64UrlToBytes(sig), expected)) return null;
  let data: { algorithm?: string; user_id?: string | number };
  try {
    data = JSON.parse(new TextDecoder().decode(base64UrlToBytes(payload)));
  } catch {
    return null;
  }
  if ((data.algorithm || '').toUpperCase() !== 'HMAC-SHA256') return null;
  const userId = String(data.user_id ?? '').trim();
  return /^[0-9]+$/.test(userId) ? userId : null;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // Status lookup for docs/data-deletion-status.html - only reveals status + dates, never the ID.
  if (req.method === 'GET') {
    const code = (new URL(req.url).searchParams.get('code') || '').trim();
    if (!/^[A-Za-z0-9-]{8,64}$/.test(code)) return json({ found: false }, 400);
    const { data } = await supabase
      .from('MetaDataDeletionRequests')
      .select('Status, RequestedAtUtc, CompletedAtUtc')
      .eq('ConfirmationCode', code)
      .maybeSingle();
    if (!data) return json({ found: false }, 404);
    return json({ found: true, status: data.Status, requested_at: data.RequestedAtUtc, completed_at: data.CompletedAtUtc });
  }

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const appSecret = Deno.env.get('FACEBOOK_APP_SECRET');
  if (!appSecret) {
    console.error('FACEBOOK_APP_SECRET is not set');
    return json({ error: 'Not configured' }, 500);
  }

  let signedRequest = '';
  try {
    const form = await req.formData();
    signedRequest = String(form.get('signed_request') || '');
  } catch {
    return json({ error: 'Bad request' }, 400);
  }

  const userId = await parseSignedRequest(signedRequest, appSecret);
  if (!userId) return json({ error: 'Invalid signed_request' }, 403);

  const code = crypto.randomUUID().replace(/-/g, '').slice(0, 16).toUpperCase();
  const userIdHash = await sha256Hex(userId);
  await supabase.from('MetaDataDeletionRequests').insert({ ConfirmationCode: code, UserIdHash: userIdHash });

  try {
    // Chat images first - once the message rows are gone nothing points at them any more.
    const { data: files } = await supabase
      .from('ChatbotMessages')
      .select('AttachmentPath')
      .eq('Psid', userId)
      .not('AttachmentPath', 'is', null);
    const paths = (files ?? []).map((f: { AttachmentPath: string }) => f.AttachmentPath).filter(Boolean);
    let filesRemoved = 0;
    for (let i = 0; i < paths.length; i += 100) {
      const { data: removed, error } = await supabase.storage.from(BUCKET).remove(paths.slice(i, i + 100));
      if (error) throw new Error('Storage remove failed: ' + error.message);
      filesRemoved += removed?.length ?? 0;
    }

    const { data: rows, error } = await supabase.rpc('meta_delete_user_data', { p_user_id: userId });
    if (error) throw new Error(error.message);

    await supabase
      .from('MetaDataDeletionRequests')
      .update({ Status: 'Completed', CompletedAtUtc: new Date().toISOString(), RowsAffected: { ...(rows ?? {}), StorageFiles: filesRemoved } })
      .eq('ConfirmationCode', code);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error('meta-data-deletion failed for code', code, msg);
    await supabase.from('MetaDataDeletionRequests').update({ Status: 'Failed', Error: msg }).eq('ConfirmationCode', code);
  }

  // Meta needs this response even if deletion failed - a Failed row shows up for follow-up.
  return json({ url: `${STATUS_PAGE}?code=${code}`, confirmation_code: code });
});
