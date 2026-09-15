// Delivery Quote page logic (any active staff, same trust tier as Delivery - see js/delivery.js).
// Lets staff pick a From location (a saved Warehouse, or a one-off address) and one or more To
// locations (js/delivery.js's #toStopsList "Location 1, 2, ..." rows, per "From Store to Location
// 1 to location 2, let the user add how many location do they want to deliver"), then estimates
// the whole route's driving distance/time via the Google Maps Directions service (getMultiStopRoute)
// and computes price = DELIVERY_BASE_FEE + DELIVERY_RATE_PER_KM * total_distance_km + toll fee -
// one base fee and one toll charge for the whole trip, not per stop, same as a real delivery run.
// Lalamove mode is unchanged and stays single-stop only (its booking flow assumes exactly one
// sender/recipient pair) - wireForm collapses back to one stop whenever that method is selected.
// DELIVERY_BASE_FEE/DELIVERY_RATE_PER_KM/DELIVERY_TOLL_FEE live in public.PortalSettings (edited
// from general-setup.html) alongside GOOGLE_MAPS_API_KEY - reused here via the same
// admin_get_public_portal_setting RPC.
// The toll fee itself is resolved by resolveTollFee() below: it first tries a real per-route
// price from Google's Routes API (via the delivery-toll-price Supabase Edge Function, since that
// API has no browser CORS support), and falls back to the flat DELIVERY_TOLL_FEE setting - applied
// only when routeUsesTolls() detects the route actually uses a toll road - whenever Google has no
// price data for the route (common for Philippine expressways) or the Edge Function isn't
// reachable. Nothing here is persisted; it's a client-side quoting tool only, same "nothing saved"
// spirit as stand-calculator.html.
let currentSession = null;
let googleMapsReadyPromise = null;
let googleMapsApiKey = null;
let deliveryBaseFee = null;
let deliveryRatePerKm = null;
let deliveryTollFee = 0; // optional - defaults to 0 (no surcharge) if DELIVERY_TOLL_FEE isn't set
// Per "if its multiple location can you add a 50% markup?" - applied to the base fee + distance
// subtotal (not the toll, a pass-through actual cost) whenever a quote has more than one "To"
// stop. Configurable like the other delivery pricing settings (General Setup, "Visible to all
// staff") via DELIVERY_MULTI_STOP_MARKUP_PERCENT, but defaults to 50 so it works out of the box
// without that key needing to be set first.
let deliveryMultiStopMarkupPercent = 50;
let warehousesById = {}; // warehouse id -> row from staff_search_warehouses

async function loadGoogleMapsApiKey() {
  const { data, error } = await supabaseClient.rpc('admin_get_public_portal_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_setting_key: 'GOOGLE_MAPS_API_KEY'
  });

  if (error) {
    console.error('admin_get_public_portal_setting failed:', error);
    return;
  }

  googleMapsApiKey = data || null;
}

async function loadDeliveryPricingSettings() {
  const [baseFeeResult, ratePerKmResult, tollFeeResult, multiStopMarkupResult] = await Promise.all([
    supabaseClient.rpc('admin_get_public_portal_setting', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_setting_key: 'DELIVERY_BASE_FEE'
    }),
    supabaseClient.rpc('admin_get_public_portal_setting', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_setting_key: 'DELIVERY_RATE_PER_KM'
    }),
    supabaseClient.rpc('admin_get_public_portal_setting', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_setting_key: 'DELIVERY_TOLL_FEE'
    }),
    supabaseClient.rpc('admin_get_public_portal_setting', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_setting_key: 'DELIVERY_MULTI_STOP_MARKUP_PERCENT'
    })
  ]);

  if (baseFeeResult.error) console.error('admin_get_public_portal_setting (DELIVERY_BASE_FEE) failed:', baseFeeResult.error);
  if (ratePerKmResult.error) console.error('admin_get_public_portal_setting (DELIVERY_RATE_PER_KM) failed:', ratePerKmResult.error);
  if (tollFeeResult.error) console.error('admin_get_public_portal_setting (DELIVERY_TOLL_FEE) failed:', tollFeeResult.error);
  if (multiStopMarkupResult.error) console.error('admin_get_public_portal_setting (DELIVERY_MULTI_STOP_MARKUP_PERCENT) failed:', multiStopMarkupResult.error);

  deliveryBaseFee = baseFeeResult.data != null && baseFeeResult.data !== '' ? Number(baseFeeResult.data) : null;
  deliveryRatePerKm = ratePerKmResult.data != null && ratePerKmResult.data !== '' ? Number(ratePerKmResult.data) : null;
  deliveryTollFee = tollFeeResult.data != null && tollFeeResult.data !== '' ? Number(tollFeeResult.data) : 0;
  deliveryMultiStopMarkupPercent = multiStopMarkupResult.data != null && multiStopMarkupResult.data !== '' ? Number(multiStopMarkupResult.data) : 50;
}

function loadGoogleMapsScript() {
  if (googleMapsReadyPromise) return googleMapsReadyPromise;

  googleMapsReadyPromise = new Promise((resolve, reject) => {
    if (!googleMapsApiKey) {
      reject(new Error('Google Maps API key is not configured - set it in General Setup.'));
      return;
    }

    // &libraries=places pulls in google.maps.places.Autocomplete for the From/To address
    // suggestions - Geocoder/DistanceMatrixService below don't need it, but it's harmless to
    // always request alongside them since this script tag is only ever loaded once per page.
    const script = document.createElement('script');
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(googleMapsApiKey)}&libraries=places`;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error('Failed to load the Google Maps script.'));
    document.head.appendChild(script);
  });

  return googleMapsReadyPromise;
}

// staff_search_warehouses already powers Delivery's warehouse lookup (js/delivery.js) and
// Transfer Orders' From/To Warehouse fields - reused here as the "From" pickup point list since
// its rows already carry a saved Latitude/Longitude, letting a known warehouse skip geocoding
// entirely on quote.
async function loadWarehouses() {
  const select = document.getElementById('fromWarehouseSelect');
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });

  if (error) {
    console.error('staff_search_warehouses failed:', error);
    select.innerHTML = '<option value="">Failed to load warehouses</option><option value="__other__">Other address...</option>';
    return;
  }

  warehousesById = {};
  (data || []).forEach((w) => { warehousesById[w.id] = w; });

  const options = (data || []).map((w) => `<option value="${w.id}">${w.name}</option>`).join('');
  select.innerHTML = options + '<option value="__other__">Other address...</option>';
}

function geocodeAddress(address) {
  return loadGoogleMapsScript().then(() => {
    const geocoder = new google.maps.Geocoder();
    return new Promise((resolve) => {
      geocoder.geocode({ address }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0].geometry.location : null);
      });
    });
  });
}

// Address-from-coordinates counterpart of geocodeAddress above, used when a pin is dragged to a
// new spot - turns the drop position back into a human-readable address for the text field.
function reverseGeocode(lat, lng) {
  return loadGoogleMapsScript().then(() => {
    const geocoder = new google.maps.Geocoder();
    return new Promise((resolve) => {
      geocoder.geocode({ location: { lat, lng } }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0].formatted_address : null);
      });
    });
  });
}

// Mirrors geocodeAndSaveWarehouse in js/delivery.js - persists via admin_update_warehouse_geocode
// (staff_authorized, not admin-only) and updates the local warehousesById cache in place, so a
// warehouse only needs to be geocoded once across this page and Delivery's day map.
async function geocodeAndCacheWarehouse(warehouse) {
  const location = await geocodeAddress(warehouse.address);

  const payload = location
    ? { p_geocoded_address: warehouse.address, p_latitude: location.lat(), p_longitude: location.lng(), p_geocode_status: 'ok' }
    : { p_geocoded_address: warehouse.address, p_latitude: null, p_longitude: null, p_geocode_status: 'failed' };

  await supabaseClient.rpc('admin_update_warehouse_geocode', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_id: warehouse.id,
    ...payload
  });

  warehouse.geocoded_address = payload.p_geocoded_address;
  warehouse.latitude = payload.p_latitude;
  warehouse.longitude = payload.p_longitude;
  warehouse.geocode_status = payload.p_geocode_status;
}

async function resolveFromLocation() {
  const select = document.getElementById('fromWarehouseSelect');
  const value = select.value;

  if (value === '__other__') {
    const address = document.getElementById('fromOtherInput').value.trim();
    if (!address) throw new Error('Enter a From address.');

    // If the user picked a suggestion from the Places Autocomplete dropdown, its coordinates are
    // already known - skip a redundant Geocoder call as long as the input hasn't been edited
    // since (resolvedFromOtherLocation is cleared on every keystroke, see wirePlacesAutocomplete).
    if (resolvedFromOtherLocation && resolvedFromOtherLocation.address === address) {
      return { lat: resolvedFromOtherLocation.lat, lng: resolvedFromOtherLocation.lng, label: address };
    }

    const location = await geocodeAddress(address);
    if (!location) throw new Error(`Could not find "${address}" on the map. Try a more specific address.`);
    return { lat: location.lat(), lng: location.lng(), label: address };
  }

  const warehouse = warehousesById[value];
  if (!warehouse) throw new Error('Pick a From location.');

  // Geocode lazily (and cache back to Warehouses) the first time this warehouse's saved lat/lng
  // is missing or stale, same staleness check as delivery.js's resolveFixedRouteWarehouseMarkers.
  if (warehouse.geocode_status !== 'ok' || warehouse.geocoded_address !== warehouse.address) {
    if (!warehouse.address) {
      throw new Error(`${warehouse.name} has no Address on file - set one in Warehouse Setup, or pick "Other address...".`);
    }
    await geocodeAndCacheWarehouse(warehouse);
  }

  if (warehouse.geocode_status !== 'ok' || warehouse.latitude == null || warehouse.longitude == null) {
    throw new Error(`Could not find ${warehouse.name}'s address ("${warehouse.address}") on the map. Check it in Warehouse Setup, or pick "Other address...".`);
  }

  return { lat: Number(warehouse.latitude), lng: Number(warehouse.longitude), label: warehouse.name };
}

// Turns an origin plus an ordered list of stops (1 or more {lat,lng} points, the last one being
// the final destination and every one before it a waypoint) into a single driving route via
// DirectionsService - used for both the classic single-stop quote and the "add a location" multi-
// stop route (js/delivery.js's Job Order/Delivery Receipt printouts are unrelated - this is only
// this page's own routing). Returns the full DirectionsResult so callers can read routes[0].legs
// (one leg per origin/stop-to-stop hop, in order) for per-leg or summed distance/duration, and so
// the same result can be handed straight to a DirectionsRenderer for the map polyline.
function getMultiStopRoute(origin, stops) {
  return loadGoogleMapsScript().then(() => {
    const directionsService = new google.maps.DirectionsService();
    const destination = stops[stops.length - 1];
    const waypoints = stops.slice(0, -1).map((s) => ({ location: { lat: s.lat, lng: s.lng }, stopover: true }));

    return new Promise((resolve, reject) => {
      directionsService.route({
        origin: { lat: origin.lat, lng: origin.lng },
        destination: { lat: destination.lat, lng: destination.lng },
        waypoints,
        optimizeWaypoints: false,
        travelMode: google.maps.TravelMode.DRIVING
      }, (result, status) => {
        if (status !== 'OK' || !result.routes || !result.routes[0]) {
          // REQUEST_DENIED here almost always means the Directions API itself isn't enabled (or
          // billing isn't set up) for this Google Maps API key - Geocoding/Maps JavaScript API
          // being enabled (used elsewhere in the portal) doesn't imply Directions is too.
          const hint = status === 'REQUEST_DENIED'
            ? ' Check that the Directions API is enabled (and billing is active) for this Google Maps API key in Google Cloud Console.'
            : '';
          reject(new Error(`Could not calculate a driving route for these stops (${status}).${hint}`));
          return;
        }
        resolve(result);
      });
    });
  });
}

function sumRouteLegs(route, key) {
  return route.legs.reduce((sum, leg) => sum + leg[key].value, 0);
}

function formatDurationSeconds(totalSeconds) {
  const totalMinutes = Math.round(totalSeconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours === 0) return `${minutes} min${minutes === 1 ? '' : 's'}`;
  return `${hours} hour${hours === 1 ? '' : 's'} ${minutes} min${minutes === 1 ? '' : 's'}`;
}

// Detects whether the default driving route uses a toll road at all, by requesting the same
// origin/destination twice via DirectionsService - once normally, once forced to avoid tolls -
// and checking whether that changes the route. If avoiding tolls produces a different distance,
// the normal route relied on a toll road somewhere; if it's identical, it didn't. This is a
// route-shape heuristic, not real toll pricing - Google's toll-price estimation has unreliable
// coverage for Philippine expressways, so it can't be trusted for an actual peso amount, but road
// network data (what this comparison relies on) is solid everywhere DirectionsService works.
// Requires the Directions API to be enabled for GOOGLE_MAPS_API_KEY, separately from Distance
// Matrix/Places/Geocoding. waypoints (plain {lat,lng}[], every intermediate stop before the final
// destination) lets a multi-location quote check the whole route at once instead of leg-by-leg -
// any toll usage anywhere along it is enough to apply the flat fee once for the whole trip.
function routeUsesTolls(origin, destination, waypoints = []) {
  return loadGoogleMapsScript().then(() => {
    const directionsService = new google.maps.DirectionsService();
    const routeWaypoints = waypoints.map((w) => ({ location: { lat: w.lat, lng: w.lng }, stopover: true }));

    const requestRoute = (avoidTolls) => new Promise((resolve, reject) => {
      directionsService.route({
        origin,
        destination,
        waypoints: routeWaypoints,
        optimizeWaypoints: false,
        travelMode: google.maps.TravelMode.DRIVING,
        avoidTolls
      }, (result, status) => {
        if (status !== 'OK' || !result.routes || !result.routes[0]) {
          reject(new Error(`Could not check for toll roads (${status}).`));
          return;
        }
        resolve(result.routes[0]);
      });
    });

    return Promise.all([requestRoute(false), requestRoute(true)]).then(([normalRoute, noTollRoute]) => {
      return sumRouteLegs(normalRoute, 'distance') !== sumRouteLegs(noTollRoute, 'distance')
        || sumRouteLegs(normalRoute, 'duration') !== sumRouteLegs(noTollRoute, 'duration');
    });
  });
}

// Calls the delivery-toll-price Supabase Edge Function (supabase/functions/delivery-toll-price),
// a thin proxy in front of Google's Routes API TOLLS computation - that endpoint has no CORS
// support so it can't be called directly from browser JS. Throws if the function isn't deployed
// yet/unreachable or the request otherwise fails - resolveTollFee below is what catches that and
// falls back cleanly, so this function stays a plain "give me the answer or an error" call.
async function fetchGoogleTollPrice(origin, destination, waypoints = []) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-toll-price`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ origin, destination, waypoints })
  });

  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new Error(body?.error || `Toll price lookup failed (${response.status}).`);
  }

  return response.json(); // { hasTollInfo, estimatedPrice, currencyCode }
}

// Decides what toll amount (if any) applies to this quote. Tries Google's real per-route price
// first (source: 'google'); Philippine expressway coverage for that data is unconfirmed, so it
// commonly comes back with hasTollInfo: false even on a route that does use a toll road - in that
// case, and whenever the Edge Function itself isn't reachable (e.g. not deployed yet), falls back
// to the route-shape toll detection + flat DELIVERY_TOLL_FEE (source: 'flat') as the safety net,
// per "our truck is always using toll fee" rather than silently undercharging.
async function resolveTollFee(origin, destination, waypoints = []) {
  try {
    const googleToll = await fetchGoogleTollPrice(origin, destination, waypoints);
    if (googleToll.hasTollInfo && googleToll.estimatedPrice > 0) {
      return { amount: googleToll.estimatedPrice, detected: true, source: 'google' };
    }
  } catch (err) {
    console.warn('Google toll price lookup unavailable, falling back to configured toll fee:', err);
  }

  if (!(deliveryTollFee > 0)) return { amount: 0, detected: null, source: 'none' };

  try {
    const usesToll = await routeUsesTolls(origin, destination, waypoints);
    return { amount: usesToll ? deliveryTollFee : 0, detected: usesToll, source: 'flat' };
  } catch (err) {
    console.error('Could not detect toll road usage, defaulting to applying the configured toll fee:', err);
    return { amount: deliveryTollFee, detected: null, source: 'flat' };
  }
}

// Philippines-wide default view, shown as soon as the page loads (before any location is
// resolved) per "show the map directly upon open Delivery Quote" - narrows down once a From
// and/or To marker is placed.
const DEFAULT_MAP_CENTER = { lat: 12.8797, lng: 121.7740 };
const DEFAULT_MAP_ZOOM = 6;

let quoteMapInstance = null;
let fromMarker = null;
let toMarkers = []; // one per "Location N" stop row, in order
let routeRenderer = null; // google.maps.DirectionsRenderer - the driving-route polyline for the in-house multi-stop path
let resolvedFromOtherLocation = null; // {lat, lng, address} from Places Autocomplete on fromOtherInput

// Created once (not per-quote like the old renderQuoteMap) so the map persists across From/To
// changes instead of being torn down and rebuilt on every Get Quote click.
async function ensureQuoteMap() {
  if (quoteMapInstance) return quoteMapInstance;
  await loadGoogleMapsScript();
  const mapEl = document.getElementById('quoteMap');
  mapEl.classList.remove('hidden');
  quoteMapInstance = new google.maps.Map(mapEl, { center: DEFAULT_MAP_CENTER, zoom: DEFAULT_MAP_ZOOM });
  return quoteMapInstance;
}

function refitMap() {
  if (!quoteMapInstance) return;

  const markers = [fromMarker, ...toMarkers].filter(Boolean);
  if (markers.length === 0) return;

  if (markers.length === 1) {
    quoteMapInstance.setCenter(markers[0].getPosition());
    quoteMapInstance.setZoom(14);
    return;
  }

  const bounds = new google.maps.LatLngBounds();
  markers.forEach((m) => bounds.extend(m.getPosition()));
  quoteMapInstance.fitBounds(bounds);
}

// Draws the actual driving route (all stops in order) as a polyline once an in-house quote has
// computed it via getMultiStopRoute - suppressMarkers/preserveViewport are both true since the
// numbered pin markers (setToMarkers) and viewport (refitMap) are already handled separately here.
async function renderRoutePolyline(directionsResult) {
  await ensureQuoteMap();
  if (!routeRenderer) {
    routeRenderer = new google.maps.DirectionsRenderer({
      map: quoteMapInstance,
      suppressMarkers: true,
      preserveViewport: true
    });
  }
  routeRenderer.setDirections(directionsResult);
}

// Cleared for the Lalamove path (which has no multi-stop route to draw) so a stale in-house
// polyline never lingers after switching Delivery Method.
function clearRoutePolyline() {
  if (routeRenderer) routeRenderer.setDirections({ routes: [] });
}

// Reverse-geocodes a dragged pin's drop position, writes it into the matching text field/cache so
// it flows through resolveFromLocation/getQuote exactly like a typed or Autocomplete-picked
// address would, then re-quotes - per "drag the pin and auto compute / change the delivery
// address". Falls back to a raw "lat, lng" label if reverse geocoding itself fails (still usable
// for pricing/mapping, just less readable).
async function handleFromMarkerDragEnd(latLng) {
  const lat = latLng.lat();
  const lng = latLng.lng();
  const address = (await reverseGeocode(lat, lng)) || `${lat.toFixed(6)}, ${lng.toFixed(6)}`;

  resolvedFromOtherLocation = { lat, lng, address };

  // A dragged pin no longer matches the selected warehouse's saved location, so switch the
  // dropdown to "Other address..." to make that visible rather than leaving it silently stale.
  document.getElementById('fromWarehouseSelect').value = '__other__';
  document.getElementById('fromOtherRow').classList.remove('hidden');
  document.getElementById('fromOtherInput').value = address;
  if (fromMarker) fromMarker.setTitle(`From: ${address}`);

  getQuote();
}

// stopIndex ties the dragged pin back to its own "Location N" row/input (js/delivery.js's
// isPlaceholderAddress-style single-To assumption doesn't apply here - each stop is independent).
async function handleToMarkerDragEnd(stopIndex, latLng) {
  const lat = latLng.lat();
  const lng = latLng.lng();
  const address = (await reverseGeocode(lat, lng)) || `${lat.toFixed(6)}, ${lng.toFixed(6)}`;

  const input = stopRowsEls()[stopIndex]?.querySelector('.to-stop-input');
  if (input) {
    input._resolvedLocation = { lat, lng, address };
    input.value = address;
  }
  if (toMarkers[stopIndex]) toMarkers[stopIndex].setTitle(`Location ${stopIndex + 1}: ${address}`);

  getQuote();
}

// Lets staff visually confirm the geocoder/Autocomplete found the right place before trusting the
// distance/price - updates live as From/To change, not just after a full Get Quote. Draggable so
// a slightly-off pin can be fine-tuned by hand (see handleFromMarkerDragEnd/handleToMarkerDragEnd).
async function setFromMarker(loc) {
  await ensureQuoteMap();
  if (fromMarker) fromMarker.setMap(null);

  if (!loc) {
    fromMarker = null;
  } else {
    fromMarker = new google.maps.Marker({
      position: { lat: loc.lat, lng: loc.lng },
      map: quoteMapInstance,
      title: `From: ${loc.label}`,
      icon: 'https://maps.google.com/mapfiles/ms/icons/green-dot.png',
      draggable: true
    });
    fromMarker.addListener('dragend', () => handleFromMarkerDragEnd(fromMarker.getPosition()));
  }
  refitMap();
}

// Replaces every "To" marker on each call (rather than diffing) - simplest correct behavior given
// stops can be added/removed/reordered between calls, and there are normally only a handful of
// them. Each pin is labeled with its stop number so it reads the same way as the "Location N"
// rows in the form.
async function setToMarkers(stops) {
  await ensureQuoteMap();
  toMarkers.forEach((m) => m.setMap(null));
  toMarkers = [];

  stops.forEach((loc, i) => {
    const marker = new google.maps.Marker({
      position: { lat: loc.lat, lng: loc.lng },
      map: quoteMapInstance,
      label: String(i + 1),
      title: `Location ${i + 1}: ${loc.label}`,
      draggable: true
    });
    marker.addListener('dragend', () => handleToMarkerDragEnd(i, marker.getPosition()));
    toMarkers.push(marker);
  });

  refitMap();
}

// Wires the same address-suggestion-as-you-type box Google Maps itself uses
// (google.maps.places.Autocomplete) onto a text input. onPlaceSelected only fires once the user
// actually picks a suggestion (Enter/click) - typing without picking one falls back to the
// existing Geocoder path in resolveFromLocation/getQuote, same as before this was added.
function wirePlacesAutocomplete(inputEl, onPlaceSelected) {
  loadGoogleMapsScript().then(() => {
    const autocomplete = new google.maps.places.Autocomplete(inputEl, {
      fields: ['geometry'],
      componentRestrictions: { country: 'ph' }
    });

    autocomplete.addListener('place_changed', () => {
      const place = autocomplete.getPlace();
      if (!place.geometry || !place.geometry.location) {
        // Reached when Enter is pressed with no suggestion picked, but also when clicking a
        // suggestion silently fails to fetch Place Details (e.g. the Places API isn't enabled/
        // billed for this key, even though predictions still render) - logged so that failure
        // mode isn't indistinguishable from "nothing happened."
        console.warn('Places Autocomplete returned no geometry for the selected place - check that the Places API is enabled for GOOGLE_MAPS_API_KEY.', place);
        return;
      }
      // Google's widget already overwrote inputEl.value with the exact suggestion text the user
      // clicked (e.g. "Robertson Plaza, Kawit, Cavite, Philippines") before this event fires - use
      // that instead of place.formatted_address, which drops the establishment/place name for
      // things like malls or hotels (returning just "Kawit, Cavite, Philippines" and leaving no
      // way to tell which "Robertson" result was actually picked).
      onPlaceSelected({
        lat: place.geometry.location.lat(),
        lng: place.geometry.location.lng(),
        address: inputEl.value.trim()
      });
    });
  }).catch((err) => console.error('Failed to initialize address suggestions:', err));
}

// Per "From Store to Location 1 to location 2, let the user add how many location do they want to
// deliver" - #toStopsList holds one row per delivery stop, each just an address input with its own
// Autocomplete + a Remove button (hidden while it's the only row left, since there must always be
// at least one destination). Order in the DOM is the delivery order used for pricing/routing.
function stopRowsEls() {
  return Array.from(document.querySelectorAll('#toStopsList .delivery-quote-stop-row'));
}

function renumberStopRows() {
  stopRowsEls().forEach((row, i) => {
    row.querySelector('.delivery-quote-stop-label').textContent = `Location ${i + 1}`;
  });
}

function updateStopRemoveButtons() {
  const rows = stopRowsEls();
  rows.forEach((row) => {
    row.querySelector('.to-stop-remove-btn').classList.toggle('hidden', rows.length <= 1);
  });
}

function addStopRow(prefillAddress) {
  const list = document.getElementById('toStopsList');
  const row = document.createElement('div');
  row.className = 'delivery-quote-stop-row';
  row.style.cssText = 'display:flex; align-items:center; gap:8px; margin-bottom:8px;';
  row.innerHTML = `
    <span class="muted delivery-quote-stop-label" style="min-width:82px;">Location</span>
    <input type="text" class="to-stop-input" placeholder="e.g. 456 Sample Ave, Makati City" style="flex:1;" />
    <button class="btn btn-danger btn-sm to-stop-remove-btn hidden" type="button" title="Remove this location">Remove</button>
  `;
  list.appendChild(row);

  const input = row.querySelector('.to-stop-input');
  if (prefillAddress) input.value = prefillAddress;

  // Same "typing invalidates the cached Autocomplete pick" convention as fromOtherInput/the old
  // single toAddressInput - _resolvedLocation lives on the input element itself rather than in a
  // parallel array, so it stays correct no matter how rows get added/removed/reordered around it.
  input.addEventListener('input', () => { input._resolvedLocation = null; });
  input.addEventListener('blur', () => { if (input.value.trim()) getQuote(); });
  wirePlacesAutocomplete(input, (loc) => {
    input._resolvedLocation = loc;
    getQuote();
  });

  row.querySelector('.to-stop-remove-btn').addEventListener('click', () => {
    row.remove();
    renumberStopRows();
    updateStopRemoveButtons();
    getQuote();
  });

  renumberStopRows();
  updateStopRemoveButtons();
}

// Mirrors resolveFromLocation's "Other address" branch - reuses a cached Autocomplete pick when
// the text hasn't changed since, otherwise falls back to a fresh Geocoder call.
async function resolveToStop(input) {
  const address = input.value.trim();

  if (input._resolvedLocation && input._resolvedLocation.address === address) {
    return { lat: input._resolvedLocation.lat, lng: input._resolvedLocation.lng, label: address };
  }

  const location = await geocodeAddress(address);
  if (!location) throw new Error(`Could not find "${address}" on the map. Try a more specific address.`);
  return { lat: location.lat(), lng: location.lng(), label: address };
}

function formatCurrency(amount) {
  return '₱' + Number(amount || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

let lalamoveVehicleTypes = []; // [{key, description}] from delivery-lalamove-vehicle-types
let lalamoveVehicleTypesLoaded = false;

// Calls the delivery-lalamove-vehicle-types Supabase Edge Function (supabase/functions/delivery-
// lalamove-vehicle-types), which proxies Lalamove's Get City Info endpoint - per "i think there
// are vehicle type in lalamove right?", this replaces the earlier hardcoded TRUCK330 guess with
// the account's actual configured service types. Lazy-loaded (only once, on first switch to
// Lalamove mode) rather than on every page load, since it's a Lalamove API call that isn't needed
// for the in-house pricing path most users will stay on.
async function loadLalamoveVehicleTypes() {
  const select = document.getElementById('lalamoveVehicleTypeSelect');
  if (lalamoveVehicleTypesLoaded) return;
  lalamoveVehicleTypesLoaded = true;

  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-lalamove-vehicle-types`, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      }
    });

    const body = await response.json().catch(() => null);
    if (!response.ok) throw new Error(body?.error || `Failed to load vehicle types (${response.status}).`);

    lalamoveVehicleTypes = body.vehicleTypes || [];
    if (lalamoveVehicleTypes.length === 0) throw new Error('Lalamove returned no vehicle types for this account/market.');

    // Just the key (e.g. "TRUCK550"), not Lalamove's longer description text - keeps the dropdown
    // scannable; the description is still available as a title tooltip on hover.
    select.innerHTML = lalamoveVehicleTypes.map((v) => `<option value="${v.key}" title="${v.description}">${v.key}</option>`).join('');
    // Defaults to MOTORCYCLE when the account actually offers it - falls through to whatever the
    // <select> lands on naturally (its first option) if not, rather than erroring.
    const motorcycleOption = lalamoveVehicleTypes.find((v) => v.key === 'MOTORCYCLE');
    if (motorcycleOption) select.value = motorcycleOption.key;
  } catch (err) {
    console.error('Could not load Lalamove vehicle types:', err);
    select.innerHTML = `<option value="">Failed to load - ${err.message}</option>`;
  }
}

// Calls the delivery-lalamove-quote Supabase Edge Function (supabase/functions/delivery-
// lalamove-quote) - a signing proxy in front of Lalamove's Quotation API, since the required HMAC
// secret can never live in browser JS. Throws on failure the same way fetchGoogleTollPrice does;
// runLalamoveQuote below is what catches that and shows it to the user.
async function fetchLalamoveQuote(origin, destination, serviceType) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-lalamove-quote`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ origin, destination, serviceType })
  });

  const body = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(body?.error || `Lalamove quote failed (${response.status}).`);
  }
  return body; // { quotationId, expiresAt, serviceType, total, currency, priceBreakdown, distanceMeters, isSandbox }
}

// In-house pricing path (base fee + rate/km + toll, applied once per whole trip - not per leg -
// over the full route distance), split out of getQuote so it can sit alongside runLalamoveQuote
// below. `stops` is 1+ resolved {lat,lng,label} locations in delivery order (Location 1, 2, ...);
// per "From Store to Location 1 to location 2 ... the price will adjust accordingly", the whole
// multi-stop route is priced as one trip via getMultiStopRoute, same as the original single-To
// path just generalized to N legs instead of always exactly 1.
async function runInHouseQuote(from, stops) {
  if (deliveryBaseFee == null || deliveryRatePerKm == null) {
    throw new Error('Delivery pricing isn\'t configured yet - set DELIVERY_BASE_FEE and DELIVERY_RATE_PER_KM in General Setup.');
  }

  const origin = { lat: from.lat, lng: from.lng };
  const destination = { lat: stops[stops.length - 1].lat, lng: stops[stops.length - 1].lng };
  const intermediateStops = stops.slice(0, -1).map((s) => ({ lat: s.lat, lng: s.lng }));

  const [routeResult, toll] = await Promise.all([
    getMultiStopRoute(origin, stops.map((s) => ({ lat: s.lat, lng: s.lng }))),
    resolveTollFee(origin, destination, intermediateStops)
  ]);

  const route = routeResult.routes[0];
  const distanceMeters = sumRouteLegs(route, 'distance');
  const durationSeconds = sumRouteLegs(route, 'duration');
  const distanceKm = distanceMeters / 1000;
  const subtotal = deliveryBaseFee + deliveryRatePerKm * distanceKm;

  // Per "if its multiple location can you add a 50% markup?" - applied to the base fee + distance
  // subtotal only, not the toll (a pass-through actual cost, not delivery service pricing).
  const isMultiStop = stops.length > 1;
  const markupAmount = isMultiStop ? subtotal * (deliveryMultiStopMarkupPercent / 100) : 0;
  const price = subtotal + markupAmount + toll.amount;

  document.getElementById('resultDistance').textContent = `${distanceKm.toFixed(2)} km`;
  document.getElementById('resultDuration').textContent = formatDurationSeconds(durationSeconds);
  document.getElementById('resultTollUsed').textContent = toll.detected === null ? 'Unknown' : (toll.detected ? 'Yes' : 'No');
  document.getElementById('resultPrice').textContent = formatCurrency(price);

  let tollPart = '';
  if (toll.amount > 0) {
    const sourceNote = toll.source === 'google'
      ? ' (Google toll estimate)'
      : (toll.detected === null ? ' (couldn\'t verify route, applied by default)' : '');
    tollPart = ` + ${formatCurrency(toll.amount)} toll fee${sourceNote}`;
  } else if (toll.detected === false) {
    tollPart = ' (no toll road detected on this route)';
  }
  const markupPart = isMultiStop ? ` + ${deliveryMultiStopMarkupPercent}% multi-stop markup (${formatCurrency(markupAmount)})` : '';
  const routeLabel = [from.label, ...stops.map((s) => s.label)].join(' → ');
  document.getElementById('resultBreakdown').textContent =
    `${formatCurrency(deliveryBaseFee)} base fee + ${formatCurrency(deliveryRatePerKm)}/km x ${distanceKm.toFixed(2)} km${markupPart}${tollPart}, route: ${routeLabel}.`;

  await renderRoutePolyline(routeResult);
}

let lastLalamoveQuote = null; // {quotationId, expiresAt, stops: [{stopId}, {stopId}], isSandbox} - needed to book
let lastBookedOrder = null; // {orderId, ...} from a successful bookLalamoveDelivery, for cancelOrder

// Lalamove pricing path - calls their real Quotation API (via the signing proxy) instead of the
// in-house formula. Reuses the same stat-card slots as the in-house path with different meanings
// (Drive Time/Toll Road don't map cleanly onto what Lalamove's quotation response returns), rather
// than adding separate result markup for each mode.
async function runLalamoveQuote(from, to) {
  const serviceType = document.getElementById('lalamoveVehicleTypeSelect').value || undefined;
  const quote = await fetchLalamoveQuote(
    { lat: from.lat, lng: from.lng, address: from.label },
    { lat: to.lat, lng: to.lng, address: to.label },
    serviceType
  );
  lastLalamoveQuote = quote;

  const distanceKm = quote.distanceMeters != null ? quote.distanceMeters / 1000 : null;

  document.getElementById('resultDistance').textContent = distanceKm != null ? `${distanceKm.toFixed(2)} km` : '-';
  document.getElementById('resultDuration').textContent = 'N/A (Lalamove)';
  document.getElementById('resultTollUsed').textContent = 'Included in price';
  document.getElementById('resultPrice').textContent = quote.total != null
    ? `${quote.currency || '₱'} ${Number(quote.total).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    : '-';

  const expiry = quote.expiresAt ? ` Valid until ${new Date(quote.expiresAt).toLocaleTimeString()}.` : '';
  document.getElementById('resultBreakdown').textContent =
    `Lalamove ${quote.isSandbox ? 'SANDBOX (test data, not a real price)' : 'quote'} - ${quote.serviceType}, from ${from.label} to ${to.label}.${expiry}`;

  // Only offer booking when the quote actually carries what a booking needs (a quotationId plus
  // both stops' stopIds) - defensive in case Lalamove's response shape ever changes.
  const canBook = !!(quote.quotationId && quote.stops?.length === 2 && quote.stops[0]?.stopId && quote.stops[1]?.stopId);
  // Booking dispatches a real driver and charges the Lalamove wallet (see bookLalamoveDelivery's
  // header comment) - restricted to super users, per direct request. Non-super users still get
  // quotes normally; they just never see a Book button, with a note explaining why in its place.
  const isSuperUser = !!currentSession?.isSuperUser;
  document.getElementById('bookDeliverySection').classList.toggle('hidden', !canBook || !isSuperUser);
  document.getElementById('bookDeliveryRestrictedNote').classList.toggle('hidden', !canBook || isSuperUser);
  const bookBtn = document.getElementById('bookDeliveryBtn');
  bookBtn.disabled = false;
  bookBtn.textContent = 'Book Delivery';
}

// Calls the delivery-lalamove-place-order Supabase Edge Function (supabase/functions/delivery-
// lalamove-place-order) - signs and forwards a real (or in sandbox, realistic-test) booking
// request. Per "the user has the capability to book it" - gated behind a confirm() prompt since
// this is a dispatch action, not just a lookup, and unlike quoting can't be silently retried
// without consequence once LALAMOVE_ENV is production.
async function bookLalamoveDelivery() {
  const errorEl = document.getElementById('bookDeliveryError');
  const bookBtn = document.getElementById('bookDeliveryBtn');
  errorEl.classList.add('hidden');

  // Belt-and-suspenders alongside runLalamoveQuote's isSuperUser check that hides this button in
  // the first place - guards a stale/already-rendered button (e.g. a super user's session getting
  // demoted mid-page without a refresh) from still being able to dispatch a real booking.
  if (!currentSession?.isSuperUser) {
    errorEl.textContent = 'Only super users can book deliveries.';
    errorEl.classList.remove('hidden');
    return;
  }

  if (!lastLalamoveQuote) {
    errorEl.textContent = 'Get a Lalamove quote first.';
    errorEl.classList.remove('hidden');
    return;
  }

  if (lastLalamoveQuote.expiresAt && new Date(lastLalamoveQuote.expiresAt).getTime() < Date.now()) {
    errorEl.textContent = 'This quote has expired (Lalamove quotes are valid ~5 minutes) - click Get Quote again before booking.';
    errorEl.classList.remove('hidden');
    return;
  }

  const senderName = document.getElementById('lalamoveSenderNameInput').value.trim();
  const senderPhone = document.getElementById('lalamoveSenderPhoneInput').value.trim();
  const recipientName = document.getElementById('lalamoveRecipientNameInput').value.trim();
  const recipientPhone = document.getElementById('lalamoveRecipientPhoneInput').value.trim();

  if (!senderName || !senderPhone || !recipientName || !recipientPhone) {
    errorEl.textContent = 'Fill in Sender Name/Phone and Recipient Name/Phone before booking.';
    errorEl.classList.remove('hidden');
    return;
  }

  const confirmed = window.confirm(
    lastLalamoveQuote.isSandbox
      ? 'Book this delivery in Lalamove\'s SANDBOX environment? This creates a test order, not a real one.'
      : 'Book this delivery via Lalamove? This dispatches a real driver and charges your Lalamove wallet.'
  );
  if (!confirmed) return;

  bookBtn.disabled = true;
  bookBtn.textContent = 'Booking...';

  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-lalamove-place-order`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        quotationId: lastLalamoveQuote.quotationId,
        sender: { stopId: lastLalamoveQuote.stops[0].stopId, name: senderName, phone: senderPhone },
        recipient: { stopId: lastLalamoveQuote.stops[1].stopId, name: recipientName, phone: recipientPhone }
      })
    });

    const body = await response.json().catch(() => null);
    if (!response.ok) throw new Error(body?.error || `Booking failed (${response.status}).`);

    lastBookedOrder = body;
    document.getElementById('bookedOrderId').textContent = body.orderId || '-';
    document.getElementById('bookedStatus').textContent = body.status || '-';
    document.getElementById('bookedTotal').textContent = body.total != null
      ? `${body.currency || '₱'} ${Number(body.total).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
      : '-';
    const shareLinkEl = document.getElementById('bookedShareLink');
    if (body.shareLink) {
      shareLinkEl.href = body.shareLink;
      shareLinkEl.classList.remove('hidden');
    } else {
      shareLinkEl.classList.add('hidden');
    }
    document.getElementById('bookDeliveryResult').classList.remove('hidden');
    document.getElementById('cancelOrderError').classList.add('hidden');

    // A quotationId is spent once used - block re-booking the same quote to avoid an accidental
    // double order; a fresh Get Quote is required (which re-enables this via runLalamoveQuote).
    bookBtn.disabled = true;
    bookBtn.textContent = 'Booked';
  } catch (err) {
    errorEl.textContent = err.message;
    errorEl.classList.remove('hidden');
    bookBtn.disabled = false;
    bookBtn.textContent = 'Book Delivery';
  }
}

async function cancelBookedOrder() {
  const errorEl = document.getElementById('cancelOrderError');
  const cancelBtn = document.getElementById('cancelOrderBtn');
  errorEl.classList.add('hidden');

  if (!lastBookedOrder?.orderId) return;

  const confirmed = window.confirm('Cancel this Lalamove order? This only works while a driver hasn\'t been assigned yet (or within ~5 minutes of assignment).');
  if (!confirmed) return;

  cancelBtn.disabled = true;
  cancelBtn.textContent = 'Cancelling...';

  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-lalamove-cancel-order`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({ orderId: lastBookedOrder.orderId })
    });

    const body = await response.json().catch(() => null);
    if (!response.ok) throw new Error(body?.error || `Cancellation failed (${response.status}).`);

    document.getElementById('bookedStatus').textContent = 'CANCELLED';
    cancelBtn.textContent = 'Cancelled';
  } catch (err) {
    errorEl.textContent = err.message;
    errorEl.classList.remove('hidden');
    cancelBtn.disabled = false;
    cancelBtn.textContent = 'Cancel Order';
  }
}

async function getQuote() {
  const errorEl = document.getElementById('quoteError');
  const resultEl = document.getElementById('quoteResult');
  const getQuoteBtn = document.getElementById('getQuoteBtn');

  // Per "make sure that we change every field the price will be auto populated" - nearly every
  // pricing-relevant field now triggers its own getQuote() call (see wireForm below), so a quick
  // run of edits (e.g. picking a From warehouse then immediately blurring To) can otherwise fire
  // overlapping calls. Skip a new call while one is already in flight rather than letting them
  // race - the button is re-enabled in the finally block below once the in-flight one finishes.
  if (getQuoteBtn.disabled) return;

  errorEl.classList.add('hidden');
  resultEl.classList.add('hidden');

  // A fresh quote invalidates any earlier Lalamove quotationId/booking context - clear it so a
  // stale "Book Delivery"/"Cancel Order" state can't linger under a new quote.
  lastLalamoveQuote = null;
  lastBookedOrder = null;
  document.getElementById('bookDeliverySection').classList.add('hidden');
  document.getElementById('bookDeliveryResult').classList.add('hidden');

  const method = document.getElementById('deliveryMethodSelect').value;

  // Blank rows are skipped rather than treated as errors - e.g. clicking "+ Add Location" and not
  // having typed into it yet shouldn't block quoting on whatever's already filled in.
  const stopInputs = stopRowsEls().map((row) => row.querySelector('.to-stop-input')).filter((input) => input.value.trim());
  if (stopInputs.length === 0) {
    errorEl.textContent = 'Enter at least one delivery address.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Lalamove booking only ever deals with exactly 2 stops (sender/recipient) - wireForm's
  // deliveryMethodSelect handler already collapses back to a single row when Lalamove is picked,
  // this is just a defensive backstop in case that state ever gets out of sync.
  if (method === 'lalamove' && stopInputs.length > 1) {
    errorEl.textContent = 'Lalamove quotes only support a single delivery address - remove the extra locations, or switch to In-House Delivery.';
    errorEl.classList.remove('hidden');
    return;
  }

  getQuoteBtn.disabled = true;
  getQuoteBtn.textContent = 'Getting Quote...';

  try {
    const from = await resolveFromLocation();
    await setFromMarker(from);

    const stops = [];
    for (const input of stopInputs) {
      stops.push(await resolveToStop(input));
    }
    await setToMarkers(stops);

    if (method === 'lalamove') {
      await runLalamoveQuote(from, stops[0]);
      clearRoutePolyline();
    } else {
      await runInHouseQuote(from, stops);
    }
    resultEl.classList.remove('hidden');
  } catch (err) {
    errorEl.textContent = err.message;
    errorEl.classList.remove('hidden');
  } finally {
    getQuoteBtn.disabled = false;
    getQuoteBtn.textContent = 'Get Quote';
  }
}

function wireForm() {
  const fromSelect = document.getElementById('fromWarehouseSelect');
  const fromOtherInput = document.getElementById('fromOtherInput');
  const deliveryMethodSelect = document.getElementById('deliveryMethodSelect');

  const lalamoveOnlyRowIds = [
    'lalamoveVehicleTypeRow', 'lalamoveSenderNameRow', 'lalamoveSenderPhoneRow',
    'lalamoveRecipientNameRow', 'lalamoveRecipientPhoneRow'
  ];

  // Per "make sure that we change every field the price will be auto populated" - switching
  // between in-house/Lalamove pricing is itself a request for a new price, same as picking a
  // different Lalamove vehicle type below. loadLalamoveVehicleTypes() sets the vehicle <select>'s
  // default (MOTORCYCLE) BEFORE getQuote() runs here, since a programmatic value assignment
  // doesn't dispatch its own 'change' event to trigger a second, redundant quote.
  deliveryMethodSelect.addEventListener('change', async (e) => {
    const isLalamove = e.target.value === 'lalamove';
    document.getElementById('lalamoveSandboxNote').classList.toggle('hidden', !isLalamove);
    lalamoveOnlyRowIds.forEach((id) => document.getElementById(id).classList.toggle('hidden', !isLalamove));

    // Lalamove booking only ever supports one sender/recipient pair - collapse back down to a
    // single stop rather than letting an invalid combination sit in the form (see the defensive
    // check in getQuote too).
    document.getElementById('addStopBtn').classList.toggle('hidden', isLalamove);
    document.getElementById('lalamoveMultiStopNote').classList.toggle('hidden', !isLalamove);
    if (isLalamove) {
      const rows = stopRowsEls();
      for (let i = rows.length - 1; i >= 1; i--) rows[i].remove();
      renumberStopRows();
      updateStopRemoveButtons();
    }

    if (isLalamove) await loadLalamoveVehicleTypes();
    getQuote();
  });

  document.getElementById('bookDeliveryBtn').addEventListener('click', bookLalamoveDelivery);
  document.getElementById('cancelOrderBtn').addEventListener('click', cancelBookedOrder);

  // Picking a different vehicle type is itself a request for a new price, same reasoning as
  // auto-quoting on a To-address Autocomplete pick - only fires on a genuine user selection
  // (programmatic select.value assignment, e.g. loadLalamoveVehicleTypes' MOTORCYCLE default,
  // does not dispatch a 'change' event).
  document.getElementById('lalamoveVehicleTypeSelect').addEventListener('change', () => {
    getQuote();
  });

  fromSelect.addEventListener('change', async (e) => {
    const isOther = e.target.value === '__other__';
    document.getElementById('fromOtherRow').classList.toggle('hidden', !isOther);

    if (isOther) {
      const address = fromOtherInput.value.trim();
      const cached = resolvedFromOtherLocation && resolvedFromOtherLocation.address === address ? resolvedFromOtherLocation : null;
      await setFromMarker(cached ? { ...cached, label: address } : null);
      // Only a cached/already-resolved "Other" address is quotable immediately here - an empty
      // or not-yet-geocoded one waits for the blur/Autocomplete-pick handlers below, same as
      // switching TO "Other address..." with nothing typed yet shouldn't error immediately.
      if (cached) getQuote();
      return;
    }

    try {
      await setFromMarker(await resolveFromLocation());
      // Per "make sure that we change every field the price will be auto populated" - picking a
      // saved warehouse is itself a complete, immediately-quotable From location.
      getQuote();
    } catch (err) {
      console.error('Could not resolve From location for map preview:', err);
      await setFromMarker(null);
    }
  });

  // Cleared on every keystroke so a stale Autocomplete pick never gets reused after the user
  // edits the text further - resolveFromLocation/getQuote fall back to Geocoder when this is null.
  fromOtherInput.addEventListener('input', () => { resolvedFromOtherLocation = null; });

  // Blur (not 'input') re-quotes once the user finishes typing a manual address without picking
  // an Autocomplete suggestion - picking a suggestion already re-quotes immediately via the
  // wirePlacesAutocomplete callback below, so this only covers the "typed it and tabbed/clicked
  // away" path. Per "make sure that we change every field the price will be auto populated". Each
  // "Location N" stop row gets the equivalent input/blur/Autocomplete wiring inline in addStopRow.
  fromOtherInput.addEventListener('blur', () => {
    if (fromSelect.value === '__other__' && fromOtherInput.value.trim()) getQuote();
  });

  wirePlacesAutocomplete(fromOtherInput, (loc) => {
    resolvedFromOtherLocation = loc;
    if (fromSelect.value === '__other__') {
      setFromMarker({ ...loc, label: loc.address });
      getQuote();
    }
  });

  document.getElementById('addStopBtn').addEventListener('click', () => addStopRow());
  document.getElementById('getQuoteBtn').addEventListener('click', getQuote);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Delivery Quote');

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Delivery Quote.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');

  await loadGoogleMapsApiKey();
  await loadDeliveryPricingSettings();
  await loadWarehouses();

  if (deliveryBaseFee == null || deliveryRatePerKm == null) {
    document.getElementById('pricingNotConfigured').classList.remove('hidden');
  }

  addStopRow();
  wireForm();

  // Show the map immediately on open, per "show the map directly upon open Delivery Quote" -
  // plots the default-selected From warehouse right away rather than waiting for Get Quote.
  try {
    await setFromMarker(await resolveFromLocation());
  } catch (err) {
    console.error('Could not resolve default From location for map preview:', err);
    await ensureQuoteMap();
  }
})();
