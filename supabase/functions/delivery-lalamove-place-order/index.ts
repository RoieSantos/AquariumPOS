// Proxies Lalamove's Place Order API (POST /v3/orders) so docs/js/deliveryQuote.js's "Book
// Delivery" button can actually create a delivery order from a previously-fetched quotation, per
// "can we book this to lalamove via api? I want to be able to pass on the contact number /
// address and then the user has the capability to book it". Same HMAC-signing/CORS constraints
// and shared secrets (LALAMOVE_API_KEY/LALAMOVE_API_SECRET/LALAMOVE_ENV) as delivery-lalamove-
// quote - see that function's header comment.
// Deploy: supabase functions deploy delivery-lalamove-place-order --project-ref hymcmesqgpliyyeghpgq
//
// IMPORTANT: this creates a REAL order in whatever environment LALAMOVE_ENV points at. In
// sandbox that's harmless test data; once LALAMOVE_ENV=production with live keys, this dispatches
// an actual driver and charges the real Lalamove wallet. There is no "dry run" flag on Lalamove's
// side - the client-side confirmation prompt (see docs/js/deliveryQuote.js's bookLalamoveDelivery)
// is the only guard before this fires, so don't remove that confirmation when touching this flow.
//
// quotationId must come from a delivery-lalamove-quote response less than 5 minutes old - Lalamove
// rejects stale ones with ERR_INVALID_QUOTATION_ID (422), surfaced as-is below.

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
  const path = '/v3/orders';

  let quotationId: string;
  let sender: { stopId: string; name: string; phone: string };
  let recipient: { stopId: string; name: string; phone: string; remarks?: string };
  try {
    const body = await req.json();
    quotationId = body.quotationId;
    sender = body.sender;
    recipient = body.recipient;
    if (!quotationId || !sender?.stopId || !sender?.name || !sender?.phone || !recipient?.stopId || !recipient?.name || !recipient?.phone) {
      throw new Error('missing required field');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { quotationId, sender: {stopId,name,phone}, recipient: {stopId,name,phone,remarks?} }.' }, 400);
  }

  const requestBody = {
    data: {
      quotationId,
      sender: { stopId: sender.stopId, name: sender.name, phone: sender.phone },
      recipients: [{ stopId: recipient.stopId, name: recipient.name, phone: recipient.phone, remarks: recipient.remarks || '' }],
      isPODEnabled: false
    }
  };
  const bodyText = JSON.stringify(requestBody);

  try {
    const timestamp = Date.now().toString();
    const rawSignature = `${timestamp}\r\nPOST\r\n${path}\r\n\r\n${bodyText}`;
    const signature = await hmacSha256Hex(apiSecret, rawSignature);

    const lalamoveResponse = await fetch(`${baseUrl}${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `hmac ${apiKey}:${timestamp}:${signature}`,
        'Market': 'PH',
        'Request-ID': crypto.randomUUID()
      },
      body: bodyText
    });

    const data = await lalamoveResponse.json();

    if (!lalamoveResponse.ok) {
      const message = data?.errors?.[0]?.message || data?.message || `Lalamove order request failed (${lalamoveResponse.status}).`;
      return jsonResponse({ error: message, raw: data }, lalamoveResponse.status);
    }

    const price = data?.data?.priceBreakdown;
    return jsonResponse({
      orderId: data?.data?.orderId || null,
      status: data?.data?.status || null,
      driverId: data?.data?.driverId || null,
      shareLink: data?.data?.shareLink || null,
      total: price ? Number(price.total) : null,
      currency: price?.currency || null,
      isSandbox
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
