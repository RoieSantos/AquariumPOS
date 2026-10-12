// Delivery fee to a customer's map pin, for GMA Conversations - per "can you show the price too base on
// the customer's pin". Staff-only (Conversations login). Uses the bot's own official formula
// (computeDeliveryQuote in _shared/chatbot-engine.ts: base fee + rate per km + toll, Google Routes API),
// measured to the exact pin rather than a typed address, so staff and Vic always quote the same number.
//
// POST { admin_username, admin_password, latitude + longitude (a pin) OR address (typed), branches?: ['GMA', 'Amaya'], vehicle_type? }
//  -> { quotes: { GMA: { estimatedFee, distanceKm, ... } | { error }, Amaya: ... } }
// With vehicle_type (MOTORCYCLE / SEDAN / MPV / TRUCK330 / 2000KG_ALUMINUM): a live Lalamove quote to the
// pin instead (computeLalamoveQuote -> { total, distanceKm, ... }).
//
// Deploy with --no-verify-jwt (the page sends the anon key; the staff login is checked here).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { computeDeliveryQuote, computeLalamoveQuote } from '../_shared/chatbot-engine.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const BRANCHES = ['GMA', 'Amaya'];
const LALAMOVE_VEHICLES = ['MOTORCYCLE', 'SEDAN', 'MPV', 'TRUCK330', '2000KG_ALUMINUM'];

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'delivery-fee-from-pin is missing its Supabase secrets.' }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON.' }, 400);
  }
  // Either a pin (latitude + longitude) or a typed address (the Delivery quote window).
  const latitude = Number(body.latitude);
  const longitude = Number(body.longitude);
  const hasPin = body.latitude != null && body.longitude != null && Number.isFinite(latitude) && Number.isFinite(longitude);
  const address = typeof body.address === 'string' ? body.address.trim().slice(0, 500) : '';
  if (!body.admin_username || !body.admin_password || (!hasPin && address.length < 5)) {
    return jsonResponse({ error: 'Body must be { admin_username, admin_password, latitude + longitude or address, branches?, vehicle_type? }.' }, 400);
  }
  const branches = Array.isArray(body.branches)
    ? BRANCHES.filter((b) => (body.branches as unknown[]).includes(b))
    : BRANCHES;

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_conversations_authorized', {
    p_username: String(body.admin_username),
    p_password: String(body.admin_password)
  });
  if (authError || authorized !== true) return jsonResponse({ error: 'Not authorized.' }, 403);

  // vehicle_type set = a live Lalamove quote for that vehicle instead of our own truck's fee.
  const vehicleType = typeof body.vehicle_type === 'string' && LALAMOVE_VEHICLES.includes(body.vehicle_type) ? body.vehicle_type : null;
  const destination = hasPin
    ? { destination_address: address, destination_latitude: latitude, destination_longitude: longitude }
    : { destination_address: address };
  const results = await Promise.all(branches.map((branch) => vehicleType
    ? computeLalamoveQuote(supabase, { origin_location: branch, vehicle_type: vehicleType, ...destination })
    : computeDeliveryQuote(supabase, { origin_location: branch, ...destination })));
  return jsonResponse({ quotes: Object.fromEntries(branches.map((b, i) => [b, results[i]])) });
});
