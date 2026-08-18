// Delivery Quote page logic (any active staff, same trust tier as Delivery - see js/delivery.js).
// Lets staff pick a From location (a saved Warehouse, or a one-off address) and a To address,
// then estimates driving distance/time via the Google Maps Distance Matrix service and computes
// price = DELIVERY_BASE_FEE + DELIVERY_RATE_PER_KM * distance_km + toll fee.
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
  const [baseFeeResult, ratePerKmResult, tollFeeResult] = await Promise.all([
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
    })
  ]);

  if (baseFeeResult.error) console.error('admin_get_public_portal_setting (DELIVERY_BASE_FEE) failed:', baseFeeResult.error);
  if (ratePerKmResult.error) console.error('admin_get_public_portal_setting (DELIVERY_RATE_PER_KM) failed:', ratePerKmResult.error);
  if (tollFeeResult.error) console.error('admin_get_public_portal_setting (DELIVERY_TOLL_FEE) failed:', tollFeeResult.error);

  deliveryBaseFee = baseFeeResult.data != null && baseFeeResult.data !== '' ? Number(baseFeeResult.data) : null;
  deliveryRatePerKm = ratePerKmResult.data != null && ratePerKmResult.data !== '' ? Number(ratePerKmResult.data) : null;
  deliveryTollFee = tollFeeResult.data != null && tollFeeResult.data !== '' ? Number(tollFeeResult.data) : 0;
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

// Distance Matrix, not the Geocoder-only pattern used elsewhere in this app, is the piece that
// actually turns two points into a driving distance/time. Uses the browser-side
// google.maps.DistanceMatrixService (loaded as part of the same Maps JavaScript API script as
// Geocoder) rather than the REST distancematrix/json endpoint, which has no CORS support and
// would need a server-side proxy to call from here.
function getDrivingDistance(origin, destination) {
  return loadGoogleMapsScript().then(() => {
    const service = new google.maps.DistanceMatrixService();
    return new Promise((resolve, reject) => {
      service.getDistanceMatrix({
        origins: [origin],
        destinations: [destination],
        travelMode: 'DRIVING',
        unitSystem: google.maps.UnitSystem.METRIC
      }, (response, status) => {
        if (status !== 'OK') {
          // REQUEST_DENIED here almost always means the Distance Matrix API itself isn't enabled
          // (or billing isn't set up) for this Google Maps API key - Geocoding/Maps JavaScript API
          // being enabled (used elsewhere in the portal) doesn't imply Distance Matrix is too.
          const hint = status === 'REQUEST_DENIED'
            ? ' Check that the Distance Matrix API is enabled (and billing is active) for this Google Maps API key in Google Cloud Console.'
            : '';
          reject(new Error(`Could not calculate driving distance (${status}).${hint}`));
          return;
        }

        const element = response?.rows?.[0]?.elements?.[0];
        if (!element || element.status !== 'OK') {
          reject(new Error(`No driving route found between those two locations (${element?.status || 'unknown'}).`));
          return;
        }

        resolve({
          distanceMeters: element.distance.value,
          distanceText: element.distance.text,
          durationText: element.duration.text
        });
      });
    });
  });
}

// Detects whether the default driving route uses a toll road at all, by requesting the same
// origin/destination twice via DirectionsService - once normally, once forced to avoid tolls -
// and checking whether that changes the route. If avoiding tolls produces a different distance,
// the normal route relied on a toll road somewhere; if it's identical, it didn't. This is a
// route-shape heuristic, not real toll pricing - Google's toll-price estimation has unreliable
// coverage for Philippine expressways, so it can't be trusted for an actual peso amount, but road
// network data (what this comparison relies on) is solid everywhere DirectionsService works.
// Requires the Directions API to be enabled for GOOGLE_MAPS_API_KEY, separately from Distance
// Matrix/Places/Geocoding.
function routeUsesTolls(origin, destination) {
  return loadGoogleMapsScript().then(() => {
    const directionsService = new google.maps.DirectionsService();

    const requestRoute = (avoidTolls) => new Promise((resolve, reject) => {
      directionsService.route({
        origin,
        destination,
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
      const normalLeg = normalRoute.legs[0];
      const noTollLeg = noTollRoute.legs[0];
      return normalLeg.distance.value !== noTollLeg.distance.value || normalLeg.duration.value !== noTollLeg.duration.value;
    });
  });
}

// Calls the delivery-toll-price Supabase Edge Function (supabase/functions/delivery-toll-price),
// a thin proxy in front of Google's Routes API TOLLS computation - that endpoint has no CORS
// support so it can't be called directly from browser JS. Throws if the function isn't deployed
// yet/unreachable or the request otherwise fails - resolveTollFee below is what catches that and
// falls back cleanly, so this function stays a plain "give me the answer or an error" call.
async function fetchGoogleTollPrice(origin, destination) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-toll-price`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ origin, destination })
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
async function resolveTollFee(origin, destination) {
  try {
    const googleToll = await fetchGoogleTollPrice(origin, destination);
    if (googleToll.hasTollInfo && googleToll.estimatedPrice > 0) {
      return { amount: googleToll.estimatedPrice, detected: true, source: 'google' };
    }
  } catch (err) {
    console.warn('Google toll price lookup unavailable, falling back to configured toll fee:', err);
  }

  if (!(deliveryTollFee > 0)) return { amount: 0, detected: null, source: 'none' };

  try {
    const usesToll = await routeUsesTolls(origin, destination);
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
let toMarker = null;
let resolvedFromOtherLocation = null; // {lat, lng, address} from Places Autocomplete on fromOtherInput
let resolvedToLocation = null; // {lat, lng, address} from Places Autocomplete on toAddressInput

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

  if (fromMarker && toMarker) {
    const bounds = new google.maps.LatLngBounds();
    bounds.extend(fromMarker.getPosition());
    bounds.extend(toMarker.getPosition());
    quoteMapInstance.fitBounds(bounds);
  } else if (fromMarker) {
    quoteMapInstance.setCenter(fromMarker.getPosition());
    quoteMapInstance.setZoom(14);
  } else if (toMarker) {
    quoteMapInstance.setCenter(toMarker.getPosition());
    quoteMapInstance.setZoom(14);
  }
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

async function handleToMarkerDragEnd(latLng) {
  const lat = latLng.lat();
  const lng = latLng.lng();
  const address = (await reverseGeocode(lat, lng)) || `${lat.toFixed(6)}, ${lng.toFixed(6)}`;

  resolvedToLocation = { lat, lng, address };
  document.getElementById('toAddressInput').value = address;
  if (toMarker) toMarker.setTitle(`To: ${address}`);

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

async function setToMarker(loc) {
  await ensureQuoteMap();
  if (toMarker) toMarker.setMap(null);

  if (!loc) {
    toMarker = null;
  } else {
    toMarker = new google.maps.Marker({
      position: { lat: loc.lat, lng: loc.lng },
      map: quoteMapInstance,
      title: `To: ${loc.label}`,
      draggable: true
    });
    toMarker.addListener('dragend', () => handleToMarkerDragEnd(toMarker.getPosition()));
  }
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

function formatCurrency(amount) {
  return '₱' + Number(amount || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

async function getQuote() {
  const errorEl = document.getElementById('quoteError');
  const resultEl = document.getElementById('quoteResult');
  const getQuoteBtn = document.getElementById('getQuoteBtn');
  errorEl.classList.add('hidden');
  resultEl.classList.add('hidden');

  if (deliveryBaseFee == null || deliveryRatePerKm == null) {
    errorEl.textContent = 'Delivery pricing isn\'t configured yet - set DELIVERY_BASE_FEE and DELIVERY_RATE_PER_KM in General Setup.';
    errorEl.classList.remove('hidden');
    return;
  }

  const toAddress = document.getElementById('toAddressInput').value.trim();
  if (!toAddress) {
    errorEl.textContent = 'Enter a To (delivery) address.';
    errorEl.classList.remove('hidden');
    return;
  }

  getQuoteBtn.disabled = true;
  getQuoteBtn.textContent = 'Getting Quote...';

  try {
    const from = await resolveFromLocation();
    await setFromMarker(from);

    // Same cached-Autocomplete-pick shortcut as resolveFromLocation's "Other address" branch.
    let to;
    if (resolvedToLocation && resolvedToLocation.address === toAddress) {
      to = { lat: resolvedToLocation.lat, lng: resolvedToLocation.lng, label: toAddress };
    } else {
      const toLocation = await geocodeAddress(toAddress);
      if (!toLocation) throw new Error(`Could not find "${toAddress}" on the map. Try a more specific address.`);
      to = { lat: toLocation.lat(), lng: toLocation.lng(), label: toAddress };
    }
    await setToMarker(to);

    const origin = { lat: from.lat, lng: from.lng };
    const destination = { lat: to.lat, lng: to.lng };

    const [{ distanceMeters, distanceText, durationText }, toll] = await Promise.all([
      getDrivingDistance(origin, destination),
      resolveTollFee(origin, destination)
    ]);

    const distanceKm = distanceMeters / 1000;
    const price = deliveryBaseFee + deliveryRatePerKm * distanceKm + toll.amount;

    document.getElementById('resultDistance').textContent = distanceText;
    document.getElementById('resultDuration').textContent = durationText;
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
    document.getElementById('resultBreakdown').textContent =
      `${formatCurrency(deliveryBaseFee)} base fee + ${formatCurrency(deliveryRatePerKm)}/km x ${distanceKm.toFixed(2)} km${tollPart}, from ${from.label} to ${toAddress}.`;
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
  const toAddressInput = document.getElementById('toAddressInput');

  fromSelect.addEventListener('change', async (e) => {
    const isOther = e.target.value === '__other__';
    document.getElementById('fromOtherRow').classList.toggle('hidden', !isOther);

    if (isOther) {
      const address = fromOtherInput.value.trim();
      const cached = resolvedFromOtherLocation && resolvedFromOtherLocation.address === address ? resolvedFromOtherLocation : null;
      await setFromMarker(cached ? { ...cached, label: address } : null);
      return;
    }

    try {
      await setFromMarker(await resolveFromLocation());
    } catch (err) {
      console.error('Could not resolve From location for map preview:', err);
      await setFromMarker(null);
    }
  });

  // Cleared on every keystroke so a stale Autocomplete pick never gets reused after the user
  // edits the text further - resolveFromLocation/getQuote fall back to Geocoder when this is null.
  fromOtherInput.addEventListener('input', () => { resolvedFromOtherLocation = null; });
  toAddressInput.addEventListener('input', () => { resolvedToLocation = null; });

  wirePlacesAutocomplete(fromOtherInput, (loc) => {
    resolvedFromOtherLocation = loc;
    if (fromSelect.value === '__other__') setFromMarker({ ...loc, label: loc.address });
  });

  wirePlacesAutocomplete(toAddressInput, (loc) => {
    resolvedToLocation = loc;
    setToMarker({ ...loc, label: loc.address });
    // Per "once the To Delivery has been clicked, auto Get Quote" - picking a suggestion is
    // itself a strong enough signal to price it immediately, no separate button press needed.
    getQuote();
  });

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
