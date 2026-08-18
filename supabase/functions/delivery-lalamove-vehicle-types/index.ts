// Proxies Lalamove's Get City Info endpoint (GET /v3/cities) so docs/js/deliveryQuote.js can
// populate a real "Vehicle Type" dropdown for Lalamove quotes - per "i think there are vehicle
// type in lalamove right?" - instead of guessing a single hardcoded serviceType like TRUCK330
// (which delivery-lalamove-quote used as an unconfirmed default before this existed). Same
// HMAC-signing/CORS constraints as delivery-lalamove-quote, and shares its secrets:
//   LALAMOVE_API_KEY / LALAMOVE_API_SECRET / LALAMOVE_ENV
// (see that function's header comment - nothing new to configure here if it's already deployed).
// Deploy: supabase functions deploy delivery-lalamove-vehicle-types --project-ref hymcmesqgpliyyeghpgq

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS'
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

  if (req.method !== 'GET') {
    return jsonResponse({ error: 'Use GET.' }, 405);
  }

  const apiKey = Deno.env.get('LALAMOVE_API_KEY');
  const apiSecret = Deno.env.get('LALAMOVE_API_SECRET');
  if (!apiKey || !apiSecret) {
    return jsonResponse({ error: 'LALAMOVE_API_KEY / LALAMOVE_API_SECRET secrets are not configured on this function.' }, 500);
  }

  const isSandbox = (Deno.env.get('LALAMOVE_ENV') || 'sandbox').toLowerCase() !== 'production';
  const baseUrl = isSandbox ? 'https://rest.sandbox.lalamove.com' : 'https://rest.lalamove.com';
  const path = '/v3/cities';

  try {
    const timestamp = Date.now().toString();
    // GET requests carry no body, but the raw signature still needs the trailing \r\n\r\n per
    // Lalamove's documented format (TIMESTAMP\r\nMETHOD\r\nPATH\r\n\r\nBODY, BODY empty here).
    const rawSignature = `${timestamp}\r\nGET\r\n${path}\r\n\r\n`;
    const signature = await hmacSha256Hex(apiSecret, rawSignature);

    const lalamoveResponse = await fetch(`${baseUrl}${path}`, {
      method: 'GET',
      headers: {
        'Authorization': `hmac ${apiKey}:${timestamp}:${signature}`,
        'Market': 'PH',
        'Request-ID': crypto.randomUUID()
      }
    });

    const data = await lalamoveResponse.json();

    if (!lalamoveResponse.ok) {
      const message = data?.errors?.[0]?.message || data?.message || `Lalamove request failed (${lalamoveResponse.status}).`;
      return jsonResponse({ error: message, raw: data }, lalamoveResponse.status);
    }

    // PH has multiple cities (Manila/South Luzon, Cebu, North/Central Luzon) that can each offer
    // slightly different service types - flattened and deduplicated by key here since this
    // powers one dropdown, not a per-city picker. First occurrence of a given key wins if
    // descriptions differ slightly between cities.
    const cities = data?.data || [];
    const seen = new Map<string, { key: string; description: string; specialRequests: unknown[] }>();
    for (const city of cities) {
      for (const service of city?.services || []) {
        if (service?.key && !seen.has(service.key)) {
          seen.set(service.key, {
            key: service.key,
            description: service.description || service.key,
            // Includes per-service special requests (e.g. Cash-on-Delivery keys, PPE, etc.) as
            // Lalamove returns them, unfiltered - see docs/js/deliveryQuote.js for what's actually
            // used from this today.
            specialRequests: service.specialRequests || []
          });
        }
      }
    }

    return jsonResponse({
      vehicleTypes: Array.from(seen.values()),
      isSandbox
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
