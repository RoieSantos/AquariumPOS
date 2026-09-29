// Signs QZ Tray print requests for the portal's barcode label printing (docs/js/labelPrinter.js,
// sql/supabase_barcode_printer_settings.sql) - per "so everytime we print a barcode it will print on the
// barcode printer".
//
// QZ Tray only prints silently (no "Allow this site?" prompt every time) for requests signed by a
// certificate it trusts. The public certificate lives in PortalSettings (QZ_CERTIFICATE); the private key
// never goes to the browser - it's this function's QZ_PRIVATE_KEY secret, and staff credentials are
// checked before anything is signed, so it can't be used as an open signing service.
//
// POST { admin_username, admin_password, request }  ->  { signature }   (base64, SHA512withRSA)
//
// Setup:
//   supabase secrets set QZ_PRIVATE_KEY="$(cat private-key.pem)" --project-ref hymcmesqgpliyyeghpgq
//   supabase functions deploy qz-sign --project-ref hymcmesqgpliyyeghpgq
// QZ_PRIVATE_KEY must be PKCS#8 PEM ("-----BEGIN PRIVATE KEY-----"), which is what QZ Tray's Site
// Manager generates. An older "BEGIN RSA PRIVATE KEY" (PKCS#1) key can be converted with:
//   openssl pkcs8 -topk8 -nocrypt -in private-key.pem -out private-key-pkcs8.pem

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

let cachedKey: CryptoKey | null = null;

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  if (pem.includes('BEGIN RSA PRIVATE KEY')) {
    throw new Error('QZ_PRIVATE_KEY is PKCS#1 - convert it to PKCS#8 (openssl pkcs8 -topk8 -nocrypt).');
  }
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  cachedKey = await crypto.subtle.importKey(
    'pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-512' }, false, ['sign']
  );
  return cachedKey;
}

function toBase64(bytes: ArrayBuffer): string {
  let binary = '';
  const view = new Uint8Array(bytes);
  for (let i = 0; i < view.length; i++) binary += String.fromCharCode(view[i]);
  return btoa(binary);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const privateKeyPem = Deno.env.get('QZ_PRIVATE_KEY');
  if (!supabaseUrl || !serviceRoleKey || !privateKeyPem) {
    return jsonResponse({ error: 'qz-sign is missing QZ_PRIVATE_KEY (or Supabase secrets).' }, 500);
  }

  let adminUsername: string;
  let adminPassword: string;
  let toSign: string;
  try {
    const body = await req.json();
    adminUsername = String(body.admin_username ?? '');
    adminPassword = String(body.admin_password ?? '');
    toSign = String(body.request ?? '');
    if (!adminUsername || !adminPassword || !toSign) throw new Error('missing field');
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { admin_username, admin_password, request }.' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_staff_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);

  try {
    const key = await importPrivateKey(privateKeyPem);
    const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(toSign));
    return jsonResponse({ signature: toBase64(signature) });
  } catch (err) {
    return jsonResponse({ error: `Could not sign: ${(err as Error).message}` }, 500);
  }
});
