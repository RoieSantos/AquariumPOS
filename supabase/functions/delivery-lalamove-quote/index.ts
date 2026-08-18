// Proxies Lalamove's Quotation API (POST /v3/quotations) so docs/js/deliveryQuote.js can offer a
// real Lalamove price alongside the in-house base-fee/rate-per-km/toll calculation, per "I want to
// be able to add a dropdown box to be able to select if its lalamove delivery or inhouse
// delivery". Lalamove's REST API is HMAC-signed with a secret key that must never reach the
// browser, so - same reasoning as delivery-toll-price - this has to be a server-side proxy.
//
// Secrets (set via `supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   LALAMOVE_API_KEY     - from Partner Portal > API Keys
//   LALAMOVE_API_SECRET  - from Partner Portal > API Keys (never expose client-side)
//   LALAMOVE_ENV          - "sandbox" (default if unset) or "production" - flips the base URL
//                            without a redeploy once real production keys are approved.
// Deploy: supabase functions deploy delivery-lalamove-quote --project-ref hymcmesqgpliyyeghpgq
//
// serviceType is normally supplied by the client, picked from the real options
// delivery-lalamove-vehicle-types loaded from this account's actual Get City Info config (see
// that function), defaulting to MOTORCYCLE there. DEFAULT_SERVICE_TYPE below only kicks in if the
// client omits it entirely. Note valid values can depend on the specific route, not just the
// account/city in general - confirmed against this account's sandbox (e.g. TRUCK330 was rejected
// for a Cavite-to-Quezon-City route that TRUCK550 accepted) - so a serviceType that works for one
// quote may still get rejected for another; Lalamove's error message (surfaced as-is in the
// response) names the actual valid options when that happens - see docs/js/deliveryQuote.js's
// runLalamoveQuote for how that reaches the UI.

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const DEFAULT_SERVICE_TYPE = 'MOTORCYCLE';

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
  const path = '/v3/quotations';

  let origin: { lat: number; lng: number; address?: string };
  let destination: { lat: number; lng: number; address?: string };
  let serviceType: string;
  try {
    const body = await req.json();
    origin = body.origin;
    destination = body.destination;
    serviceType = body.serviceType || DEFAULT_SERVICE_TYPE;
    if (!origin || !destination || typeof origin.lat !== 'number' || typeof destination.lat !== 'number') {
      throw new Error('missing/invalid origin or destination');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { origin: {lat,lng,address}, destination: {lat,lng,address}, serviceType? }.' }, 400);
  }

  const requestBody = {
    data: {
      serviceType,
      language: 'en_PH',
      stops: [
        { coordinates: { lat: String(origin.lat), lng: String(origin.lng) }, address: origin.address || `${origin.lat}, ${origin.lng}` },
        { coordinates: { lat: String(destination.lat), lng: String(destination.lng) }, address: destination.address || `${destination.lat}, ${destination.lng}` }
      ],
      isRouteOptimized: false,
      specialRequests: []
    }
  };
  const bodyText = JSON.stringify(requestBody);

  try {
    const timestamp = Date.now().toString();
    // Lalamove's documented raw signature format: TIMESTAMP\r\nMETHOD\r\nPATH\r\n\r\nBODY
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
      // Lalamove's error shape is typically { errors: [{ id, message }] } - surfaced as-is so the
      // real problem (e.g. an invalid serviceType for this city) is visible instead of guessed at.
      const message = data?.errors?.[0]?.message || data?.message || `Lalamove request failed (${lalamoveResponse.status}).`;
      return jsonResponse({ error: message, raw: data }, lalamoveResponse.status);
    }

    const price = data?.data?.priceBreakdown;
    return jsonResponse({
      quotationId: data?.data?.quotationId || null,
      expiresAt: data?.data?.expiresAt || null,
      serviceType,
      total: price ? Number(price.total) : null,
      currency: price?.currency || null,
      priceBreakdown: price || null,
      distanceMeters: data?.data?.distance ? Number(data.data.distance.value) : null,
      // stopId per stop is required to place an order from this quotation (delivery-lalamove-
      // place-order) - order is guaranteed [origin, destination] since that's the order stops
      // were submitted in above.
      stops: (data?.data?.stops || []).map((s: { stopId: string }) => ({ stopId: s.stopId })),
      isSandbox
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
