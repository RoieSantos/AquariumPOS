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

// Per the comment above: the exact valid serviceType key can differ by route within the same
// account/city (e.g. TRUCK330 accepted for one route, rejected for another in favor of TRUCK550
// or a _LD/VAN variant) - Lalamove's own error message names the actual accepted list for that
// specific route when a key is rejected. Rather than surface that raw error to the customer,
// each class the dropdown offers (docs/js/orderNow.js's ALLOWED_VEHICLE_KEYS) maps to an ordered
// list of acceptable substitutes of roughly the same size class, tried in order against whatever
// Lalamove says IS valid for this route - first one present wins.
const SERVICE_TYPE_FALLBACKS: Record<string, string[]> = {
  MOTORCYCLE: ['MOTORCYCLE'],
  SEDAN: ['SEDAN', 'SEDAN_INTERCITY'],
  MPV: ['MPV', 'MPV_INTERCITY', 'VAN', 'VAN1000', 'VAN_INTERCITY'],
  TRUCK330: ['TRUCK330', 'VAN1000', 'VAN', 'VAN_INTERCITY', '3000KG_TRUCK'],
  '2000KG_ALUMINUM': ['2000KG_ALUMINUM', '2000KG_ALUMINUM_LD', '2000KG_FB', '2000KG_FB_LD', '3000KG_TRUCK', '7000KG_TRUCK']
};

// Parses Lalamove's `value must be one of "A", "B", ...` validation message into ["A", "B", ...].
function parseAcceptedServiceTypes(message: string): string[] {
  const matches = message.match(/"([^"]+)"/g) || [];
  return matches.map((m) => m.slice(1, -1));
}

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

  function buildBody(serviceTypeToTry: string) {
    return JSON.stringify({
      data: {
        serviceType: serviceTypeToTry,
        language: 'en_PH',
        stops: [
          { coordinates: { lat: String(origin.lat), lng: String(origin.lng) }, address: origin.address || `${origin.lat}, ${origin.lng}` },
          { coordinates: { lat: String(destination.lat), lng: String(destination.lng) }, address: destination.address || `${destination.lat}, ${destination.lng}` }
        ],
        isRouteOptimized: false,
        specialRequests: []
      }
    });
  }

  async function sendQuoteRequest(serviceTypeToTry: string) {
    const bodyText = buildBody(serviceTypeToTry);
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
    return { ok: lalamoveResponse.ok, status: lalamoveResponse.status, data };
  }

  try {
    let result = await sendQuoteRequest(serviceType);
    let usedServiceType = serviceType;

    if (!result.ok) {
      // Lalamove's error shape is typically { errors: [{ id, message }] }. The valid serviceType
      // set can differ by exact route within the same account/city (see file header) - when that's
      // the failure, Lalamove's own message names what IS valid for this specific route. Walk this
      // vehicle class's fallback list (roughly same size class) and retry once with the first
      // entry Lalamove actually accepts here, instead of failing the whole estimate over a route-
      // specific key mismatch the customer has no way to know about.
      const message: string = result.data?.errors?.[0]?.message || result.data?.message || '';
      if (/value must be one of/i.test(message)) {
        const accepted = new Set(parseAcceptedServiceTypes(message));
        const fallbacks = SERVICE_TYPE_FALLBACKS[serviceType] || [];
        const substitute = fallbacks.find((candidate) => candidate !== serviceType && accepted.has(candidate));
        if (substitute) {
          result = await sendQuoteRequest(substitute);
          usedServiceType = substitute;
        }
      }
    }

    if (!result.ok) {
      const message = result.data?.errors?.[0]?.message || result.data?.message || `Lalamove request failed (${result.status}).`;
      return jsonResponse({ error: message, raw: result.data }, result.status);
    }

    const data = result.data;
    const price = data?.data?.priceBreakdown;
    return jsonResponse({
      quotationId: data?.data?.quotationId || null,
      expiresAt: data?.data?.expiresAt || null,
      serviceType: usedServiceType,
      requestedServiceType: serviceType,
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
