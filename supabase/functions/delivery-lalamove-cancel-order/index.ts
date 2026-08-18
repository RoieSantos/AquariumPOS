// Proxies Lalamove's Cancel Order API (DELETE /v3/orders/{orderId}) - a safety net paired with
// delivery-lalamove-place-order's "Book Delivery" button, since booking is a real (or in sandbox,
// realistic-test) dispatch action that's easy to want to undo immediately after a mistake. Same
// HMAC-signing/CORS constraints and shared secrets (LALAMOVE_API_KEY/LALAMOVE_API_SECRET/
// LALAMOVE_ENV) as the other delivery-lalamove-* functions.
// Deploy: supabase functions deploy delivery-lalamove-cancel-order --project-ref hymcmesqgpliyyeghpgq
//
// Per Lalamove's docs, cancellation only succeeds while the order is still ASSIGNING_DRIVER, or
// within ~5 minutes of a driver being matched - past that it 409s with ERR_CANCELLATION_FORBIDDEN,
// surfaced as-is so the UI can explain why "Cancel" stopped working rather than failing silently.

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

async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(key),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(message));
  return Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  // POST rather than DELETE at this function's own boundary - simpler for a JSON-body fetch()
  // call from the client; it issues the real DELETE to Lalamove internally below.
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405);
  }

  const apiKey = Deno.env.get('LALAMOVE_API_KEY');
  const apiSecret = Deno.env.get('LALAMOVE_API_SECRET');
  if (!apiKey || !apiSecret) {
    return jsonResponse({ error: 'LALAMOVE_API_KEY / LALAMOVE_API_SECRET secrets are not configured on this function.' }, 500);
  }

  const isSandbox = (Deno.env.get('LALAMOVE_ENV') || 'sandbox').toLowerCase() !== 'production';
  const baseUrl = isSandbox ? 'https://rest.sandbox.lalamove.com' : 'https://rest.lalamove.com';

  let orderId: string;
  try {
    const body = await req.json();
    orderId = body.orderId;
    if (!orderId) throw new Error('missing orderId');
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { orderId }.' }, 400);
  }

  const path = `/v3/orders/${orderId}`;

  try {
    const timestamp = Date.now().toString();
    const rawSignature = `${timestamp}\r\nDELETE\r\n${path}\r\n\r\n`;
    const signature = await hmacSha256Hex(apiSecret, rawSignature);

    const lalamoveResponse = await fetch(`${baseUrl}${path}`, {
      method: 'DELETE',
      headers: {
        'Authorization': `hmac ${apiKey}:${timestamp}:${signature}`,
        'Market': 'PH',
        'Request-ID': crypto.randomUUID()
      }
    });

    if (lalamoveResponse.status === 204) {
      return jsonResponse({ cancelled: true, isSandbox });
    }

    const data = await lalamoveResponse.json().catch(() => null);
    const message = data?.errors?.[0]?.message || data?.message || `Lalamove cancellation failed (${lalamoveResponse.status}).`;
    return jsonResponse({ error: message, raw: data }, lalamoveResponse.status);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
