// Proxies Google's Routes API (computeRoutes with extraComputations: ["TOLLS"]) so
// docs/js/deliveryQuote.js can get a real per-route toll price estimate. That endpoint
// (routes.googleapis.com) does not send CORS headers for browser callers, so it can't be hit
// directly from client-side JS the way Geocoder/DirectionsService/DistanceMatrixService are (those
// run through the maps/api/js script tag, which sidesteps CORS entirely) - hence this thin proxy.
//
// Uses its own server-side secret (GOOGLE_ROUTES_API_KEY) rather than the browser
// GOOGLE_MAPS_API_KEY from PortalSettings, because that key is typically HTTP-referrer-restricted
// for browser use, which would reject calls made from here (no browser Referer header). Set the
// secret with:
//   supabase secrets set GOOGLE_ROUTES_API_KEY=<a key restricted to just the Routes API> --project-ref hymcmesqgpliyyeghpgq
// Deploy with:
//   supabase functions deploy delivery-toll-price --project-ref hymcmesqgpliyyeghpgq
//
// Philippine expressway coverage for Google's toll-price data is unconfirmed - this may come back
// with hasTollInfo: false even on routes that do use tolls. deliveryQuote.js's resolveTollFee()
// already falls back to the flat DELIVERY_TOLL_FEE PortalSettings value (plus its own
// route-shape toll detection) whenever this returns no price, so that's expected/handled, not a
// bug.

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

  const apiKey = Deno.env.get('GOOGLE_ROUTES_API_KEY');
  if (!apiKey) {
    return jsonResponse({ error: 'GOOGLE_ROUTES_API_KEY secret is not configured on this function.' }, 500);
  }

  let origin: { lat: number; lng: number };
  let destination: { lat: number; lng: number };
  try {
    const body = await req.json();
    origin = body.origin;
    destination = body.destination;
    if (!origin || !destination || typeof origin.lat !== 'number' || typeof destination.lat !== 'number') {
      throw new Error('missing/invalid origin or destination');
    }
  } catch {
    return jsonResponse({ error: 'Body must be JSON: { origin: {lat,lng}, destination: {lat,lng} }.' }, 400);
  }

  try {
    const googleResponse = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': 'routes.travelAdvisory.tollInfo,routes.distanceMeters,routes.duration'
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
        destination: { location: { latLng: { latitude: destination.lat, longitude: destination.lng } } },
        travelMode: 'DRIVE',
        extraComputations: ['TOLLS']
      })
    });

    const data = await googleResponse.json();

    if (!googleResponse.ok) {
      return jsonResponse({ error: data?.error?.message || 'Google Routes API request failed.' }, googleResponse.status);
    }

    const route = data?.routes?.[0];
    const price = route?.travelAdvisory?.tollInfo?.estimatedPrice?.[0];
    // Google's Money type splits the amount into whole "units" (string, to avoid int64 precision
    // loss in JSON) and fractional "nanos" (billionths) - combine them into a plain decimal.
    const estimatedPrice = price ? Number(price.units || 0) + (price.nanos || 0) / 1e9 : null;

    return jsonResponse({
      hasTollInfo: !!price,
      estimatedPrice,
      currencyCode: price?.currencyCode || null
    });
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
