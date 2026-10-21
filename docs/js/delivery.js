// Delivery page logic (any active staff, same trust tier as Online Orders - reuses
// session.password captured at login, see auth.js, no re-unlock prompt beyond the stale-session
// fallback below). Renders a month calendar of DeliveryStops (admin_list_delivery_stops), lets
// staff assign an OnlineOrders row with ForDelivery=true to a date (admin_create_delivery_stop),
// then geocodes that order's ShippingAddress client-side via the Google Maps Geocoding API and
// caches the result on the stop (admin_update_delivery_stop_geocode) - see
// supabase_delivery_tables.sql for why the geocode cache lives on DeliveryStops rather than on
// OnlineOrders itself.
let currentSession = null;
let currentYear = null;
let currentMonth = null; // 0-11
let stopsByDate = {}; // 'YYYY-MM-DD' -> array of stop rows
let selectedDateKey = null; // last-clicked day cell, for the .selected highlight
let selectedOrderId = null;
let assignOrdersByOrderId = new Map(); // last-rendered assign-modal rows, keyed by order_id

// Pancake's generic identity for a sale rung up at the POS with no real customer picked - the
// CustomerName reads literally "POS WALKIN ORDERS" and the ShippingAddress literally "Walkin" on
// every such order. Per "if the customer is POS WALKIN ORDERS and Address is Walkin can you ask
// the user for Address and Name of customer once its assigned" - there's nowhere to plot "Walkin"
// on a map and nobody named "POS WALKIN ORDERS" for a driver to ask for at the door, so assigning
// one of these to a delivery prompts for both, same moment confirmAssign() already prompts for a
// plain missing address.
function isWalkInPlaceholderOrder(order) {
  const name = (order?.customer_name || '').trim().toLowerCase();
  const address = (order?.shipping_address || '').trim().toLowerCase();
  return name === 'pos walkin orders' || address === 'walkin';
}

// An address that isn't really an address - blank, or Pancake's own "Walkin" placeholder text.
// Used everywhere a stop's shipping_address is displayed or geocoded, so the placeholder is
// treated exactly like "no address on file" rather than shown (or plotted) as if it meant
// something.
// Assign-list row identity: advance orders and online orders are separate number series.
function assignOrderKey(o) {
  return `${o.source || 'online'}:${o.order_id}`;
}

// Same "ADV-" prefix the stops list / receipt use for an advance stop's order_id. An online order
// placed through the order wizard also shows its "AO-" request number, since that's what staff
// search by (supabase_delivery_assign_automated_order_search.sql). A confirmed bot/GMA order's
// order_id already IS "AO-00039", and so is a draft's (source 'automated') - no suffix for those.
function assignOrderLabel(o) {
  if (o.source === 'advance') return `ADV-${o.order_id}`;
  const id = o.order_id || '';
  return o.automated_order_no && o.automated_order_no !== id ? `${id} · ${o.automated_order_no}` : id;
}

function isPlaceholderAddress(address) {
  const a = (address || '').trim().toLowerCase();
  return !a || a === 'walkin';
}
let assignSearchDebounceHandle = null;
let assignSearch = '';
let assignPage = 1;
let assignPageSize = 50;
// Assign-list header sort - null = latest update first. Sorted server-side (the list is paged).
let assignSortColumn = null;
let assignSortDir = 'asc';
let dayMapInstance = null;
let driverDate = null; // 'YYYY-MM-DD' currently viewed in the Driver Route View (Delivery Team only)
let googleMapsReadyPromise = null;
let googleMapsApiKey = null; // fetched from PortalSettings (GOOGLE_MAPS_API_KEY) during init()
let routeScheduleByDayOfWeek = {}; // 0-6 -> {route_name, warehouse_ids, warehouse_names, vendor_codes, vendor_names}, from loadAndRenderRouteSchedule
let warehouseById = {}; // WarehouseID -> {name, address, latitude, longitude, geocode_status, geocoded_address}, from loadWarehouseLookup
let vendorByCode = {}; // VendorCode -> {name, address, contact_person, phone, email, latitude, longitude, geocode_status, geocoded_address}, from loadVendorLookup
let dateVendorsByDate = {}; // 'YYYY-MM-DD' -> [{vendor_code, vendor_name}], from loadMonthDateVendors - per-date (not weekly recurring) Vendor tags, super-user-assignable

// Live Driver Tracking - plotted onto dayMapInstance itself (see renderDayMap) rather than a
// separate map, so the driver's current position shows up right alongside today's stops/route.
let driverMarkers = {}; // username -> google.maps.Marker, attached to whichever map is dayMapInstance right now
let driverLocationsChannel = null; // Supabase Realtime channel, subscribed once at init
let dayMapDateKey = null; // date currently rendered on dayMapInstance - see renderDayMap/refreshDriverMarkers
let companyLogoUrl = null; // public.CompanyInfo.LogoUrl (see loadCompanyLogoUrl/js/companyBranding.js) - used as the driver marker icon when set

function toDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

// Production day off (Date.getDay(): 0 = Sunday ... 1 = Monday). Per "block the monday on our
// calendar.. its production day off so we cannot schedule on monday.. only super user can" - every
// Monday shows "Day Off" on the calendar, and only a Super User can still put a stop on it (server
// side too: sql/supabase_delivery_block_monday_superuser.sql).
const NO_DELIVERY_DAY_OF_WEEK = 1;
const DAY_OFF_MESSAGE = 'Mondays are production day off - only a Super User can schedule a delivery on a Monday.';

function isDayOffDateKey(dateKey) {
  if (!dateKey) return false;
  return new Date(`${dateKey}T00:00:00`).getDay() === NO_DELIVERY_DAY_OF_WEEK;
}

// Blocked = a day off AND the user isn't a Super User (they can override).
function isBlockedDeliveryDateKey(dateKey) {
  return isDayOffDateKey(dateKey) && !currentSession?.isSuperUser;
}

// GOOGLE_MAPS_API_KEY lives in public.PortalSettings (edited from general-setup.html), not
// js/config.js, so it can be changed without redeploying this file. Fetched once via the
// is_staff_authorized-gated admin_get_public_portal_setting RPC, which only returns the value
// because that row is flagged IsPublicToStaff = true - see supabase_portal_settings_table.sql.
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

// init() fetches the Maps key + company logo (driver marker icons) in the background rather than
// before the calendar - anything that draws a map comes through here, so it waits for both first.
let mapAssetsReady = Promise.resolve();

function loadGoogleMapsScript() {
  if (googleMapsReadyPromise) return googleMapsReadyPromise;

  googleMapsReadyPromise = mapAssetsReady.then(() => new Promise((resolve, reject) => {
    if (!googleMapsApiKey) {
      reject(new Error('Google Maps API key is not configured - set it in General Setup.'));
      return;
    }

    const script = document.createElement('script');
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(googleMapsApiKey)}`;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error('Failed to load the Google Maps script.'));
    document.head.appendChild(script);
  }));

  return googleMapsReadyPromise;
}

// Loaded once at init so the day map can resolve a fixed-route warehouse's Address/coordinates
// without a round-trip per day click. staff_search_warehouses already powers Delivery Setup's
// picker and Transfer Orders' From/To Warehouse fields - reused here rather than a new RPC.
async function loadWarehouseLookup() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });

  if (error) {
    console.error('staff_search_warehouses failed:', error);
    return;
  }

  warehouseById = {};
  (data || []).forEach((w) => { warehouseById[w.id] = w; });
}

// Mirrors geocodeAndSaveStop below, but for a Warehouse's Address instead of an order's
// ShippingAddress - persists via admin_update_warehouse_geocode (supabase_warehouse_address_
// geocode.sql) and updates the local warehouseById cache in place so the caller can immediately
// re-check geocode_status/latitude/longitude without re-fetching.
async function geocodeAndSaveWarehouse(warehouseId, address) {
  const warehouse = warehouseById[warehouseId];
  if (!warehouse) return;

  try {
    await loadGoogleMapsScript();
    const geocoder = new google.maps.Geocoder();
    const result = await new Promise((resolve) => {
      geocoder.geocode({ address }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0] : null);
      });
    });

    const payload = result
      ? { p_geocoded_address: address, p_latitude: result.geometry.location.lat(), p_longitude: result.geometry.location.lng(), p_geocode_status: 'ok' }
      : { p_geocoded_address: address, p_latitude: null, p_longitude: null, p_geocode_status: 'failed' };

    await supabaseClient.rpc('admin_update_warehouse_geocode', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_warehouse_id: warehouseId,
      ...payload
    });

    warehouse.geocoded_address = payload.p_geocoded_address;
    warehouse.latitude = payload.p_latitude;
    warehouse.longitude = payload.p_longitude;
    warehouse.geocode_status = payload.p_geocode_status;
  } catch (err) {
    console.error('Warehouse geocoding failed:', err);
  }
}

// Vendor counterparts of loadWarehouseLookup/geocodeAndSaveWarehouse above - same reasoning,
// staff_search_vendors/admin_update_vendor_geocode mirror the warehouse RPCs exactly (see
// supabase_vendor_address_geocode.sql).
async function loadVendorLookup() {
  const { data, error } = await supabaseClient.rpc('staff_search_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });

  if (error) {
    console.error('staff_search_vendors failed:', error);
    return;
  }

  vendorByCode = {};
  (data || []).forEach((v) => { vendorByCode[v.vendor_code] = v; });
}

// Per "can you include the details too on the delivery view? so the user can see the address /
// contacts and other details" - a vendor stop's Address/Contact Person/Phone (staff_search_
// vendors, supabase_vendor_address_geocode.sql), rendered as a single "Address · Contact ·
// Phone" line wherever a vendor tag is shown (fixedRouteRowHtml, renderDateVendorsSection, map
// marker titles below). Returns '' when the vendor lookup hasn't resolved or has none of these
// fields set, so callers can skip an empty detail line entirely.
function vendorDetailText(vendorCode) {
  const v = vendorByCode[vendorCode];
  if (!v) return '';
  const contact = [v.contact_person, v.phone].filter(Boolean).join(' - ');
  return [v.address, contact].filter(Boolean).join(' · ');
}

async function geocodeAndSaveVendor(vendorCode, address) {
  const vendor = vendorByCode[vendorCode];
  if (!vendor) return;

  try {
    await loadGoogleMapsScript();
    const geocoder = new google.maps.Geocoder();
    const result = await new Promise((resolve) => {
      geocoder.geocode({ address }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0] : null);
      });
    });

    const payload = result
      ? { p_geocoded_address: address, p_latitude: result.geometry.location.lat(), p_longitude: result.geometry.location.lng(), p_geocode_status: 'ok' }
      : { p_geocoded_address: address, p_latitude: null, p_longitude: null, p_geocode_status: 'failed' };

    await supabaseClient.rpc('admin_update_vendor_geocode', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendor_code: vendorCode,
      ...payload
    });

    vendor.geocoded_address = payload.p_geocoded_address;
    vendor.latitude = payload.p_latitude;
    vendor.longitude = payload.p_longitude;
    vendor.geocode_status = payload.p_geocode_status;
  } catch (err) {
    console.error('Vendor geocoding failed:', err);
  }
}

// Fixed weekly route labels (Delivery Setup, super users only) - purely informational, shown
// once under the weekday header row. Loaded once at init since the schedule rarely changes
// mid-session; Delivery Setup itself lives on a separate page.
async function loadAndRenderRouteSchedule() {
  const { data, error } = await supabaseClient.rpc('staff_get_delivery_route_schedule', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    console.error('staff_get_delivery_route_schedule failed:', error);
    return;
  }

  routeScheduleByDayOfWeek = {};
  (data || []).forEach((r) => {
    routeScheduleByDayOfWeek[r.day_of_week] = r;

    const label = document.querySelector(`.delivery-weekday-route[data-day="${r.day_of_week}"]`);
    if (!label) return;
    const tags = [...(r.warehouse_names || []), ...(r.vendor_names || [])];
    const parts = [r.route_name, tags.length ? tags.join(', ') : null].filter(Boolean);
    label.textContent = parts.length ? parts.join(' - ') : '';
    if (parts.length) label.title = parts.join(' - ');
  });
}

async function loadMonthStops(year, month) {
  const startDate = new Date(year, month, 1);
  const endDate = new Date(year, month + 1, 1);

  const { data, error } = await supabaseClient.rpc('admin_list_delivery_stops', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_start_date: toDateKey(startDate),
    p_end_date: toDateKey(endDate)
  });

  if (error) {
    console.error('admin_list_delivery_stops failed:', error);
    stopsByDate = {};
    return;
  }

  stopsByDate = {};
  (data || []).forEach((stop) => {
    const key = stop.delivery_date;
    if (!stopsByDate[key]) stopsByDate[key] = [];
    stopsByDate[key].push(stop);
  });
}

// Per-date Vendor tags (super-user-assignable, docs/delivery-setup.html's weekly recurring
// schedule is a separate thing) - see admin_assign_delivery_date_vendor/staff_list_delivery_date_
// vendors (supabase_delivery_date_vendors.sql). Loaded the same month-range way as loadMonthStops.
async function loadMonthDateVendors(year, month) {
  const startDate = new Date(year, month, 1);
  const endDate = new Date(year, month + 1, 1);

  const { data, error } = await supabaseClient.rpc('staff_list_delivery_date_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_start_date: toDateKey(startDate),
    p_end_date: toDateKey(endDate)
  });

  if (error) {
    console.error('staff_list_delivery_date_vendors failed:', error);
    dateVendorsByDate = {};
    return;
  }

  dateVendorsByDate = {};
  (data || []).forEach((row) => {
    const key = row.delivery_date;
    if (!dateVendorsByDate[key]) dateVendorsByDate[key] = [];
    dateVendorsByDate[key].push(row);
  });
}

function renderCalendarGrid(year, month) {
  const grid = document.getElementById('calendarGrid');
  const firstOfMonth = new Date(year, month, 1);
  const startOffset = firstOfMonth.getDay(); // 0 = Sunday
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const todayKey = toDateKey(new Date());

  let html = '';

  for (let i = 0; i < startOffset; i++) {
    html += '<div class="delivery-day-cell delivery-day-cell-empty"></div>';
  }

  for (let day = 1; day <= daysInMonth; day++) {
    const cellDate = new Date(year, month, day);
    const key = toDateKey(cellDate);
    const stops = stopsByDate[key] || [];
    const isToday = key === todayKey;
    const isNoDelivery = cellDate.getDay() === NO_DELIVERY_DAY_OF_WEEK;

    // Per "can you put the stops on the delivery calendar even if its vendor" - a vendor
    // pickup/drop counts as a stop for the day the same way an order does, whether it came from
    // the weekly recurring Delivery Setup route or a per-date tag (getDayVendorCodes dedupes the
    // two), so a day with vendors only still lights up as a day with stops.
    // Still listed on a day off - a Super User may have booked one there anyway.
    const vendorCodes = getDayVendorCodes(key);

    const classes = ['delivery-day-cell'];
    if (stops.length > 0 || vendorCodes.length > 0) classes.push('has-stops');
    if (isToday) classes.push('today');
    if (key === selectedDateKey) classes.push('selected');
    if (isNoDelivery) classes.push('no-delivery');

    // Per "show the Fixed Route as actual Stop on the calendar so the user can see that it has
    // fixed route on that date" - every occurrence of that weekday gets a badge, not just the
    // weekday header column, so it's visible at a glance while browsing the month.
    const fixedRoute = !isNoDelivery ? routeScheduleByDayOfWeek[cellDate.getDay()] : null;
    // "add a stop on the date showing how many stops fixed" - count of Warehouses tagged for this
    // weekday. Vendors used to be counted here too, but they now carry their own "N Vendor stop"
    // badge below (weekly + per-date together), so counting them twice would double up.
    const fixedCount = fixedRoute ? (fixedRoute.warehouse_names?.length || 0) : 0;
    const vendorNames = vendorCodes.map((code) => vendorByCode[code]?.name || code);
    // Combined drops count once - "2 drops · 3 orders" (groupStopsIntoDrops).
    const dropCount = groupStopsIntoDrops(stops).length;
    const stopsBadgeText = dropCount < stops.length
      ? `${dropCount} drop${dropCount === 1 ? '' : 's'} &middot; ${stops.length} orders`
      : `${stops.length} stop${stops.length === 1 ? '' : 's'}`;

    html += `
      <div class="${classes.join(' ')}" data-date="${key}">
        <div class="delivery-day-number">${day}</div>
        ${isNoDelivery ? '<span class="badge badge-neutral" title="Production day off - only a Super User can schedule">Day Off</span>' : ''}
        ${fixedRoute && fixedRoute.route_name ? `<span class="badge badge-purple" title="Fixed route for this day">${fixedRoute.route_name}</span>` : ''}
        ${fixedCount > 0 ? `<span class="badge badge-glass" title="${fixedCount} fixed Warehouse stop${fixedCount === 1 ? '' : 's'} for this day">${fixedCount} Fixed</span>` : ''}
        ${vendorCodes.length > 0 ? `<span class="badge badge-vendor" title="${vendorNames.join(', ')}">${vendorCodes.length} Vendor stop${vendorCodes.length === 1 ? '' : 's'}</span>` : ''}
        ${stops.length > 0 ? `<span class="badge badge-primary">${stopsBadgeText}</span>` : ''}
      </div>
    `;
  }

  grid.innerHTML = html;

  grid.querySelectorAll('.delivery-day-cell[data-date]').forEach((cell) => {
    cell.addEventListener('click', () => showDayDetail(cell.dataset.date));
  });
}

async function renderMonth(year, month) {
  document.getElementById('calendarMonthLabel').textContent = new Date(year, month, 1)
    .toLocaleDateString('en-US', { month: 'long', year: 'numeric' });

  await Promise.all([loadMonthStops(year, month), loadMonthDateVendors(year, month)]);
  renderCalendarGrid(year, month);
}

// Every Vendor tagged to this date - both the weekly recurring Delivery Setup schedule and the
// per-date ad hoc assignments (supabase_delivery_date_vendors.sql) - deduped by code so a vendor
// tagged both ways only shows once. Feeds vendorStopCardsHtml below (Driver Route View) and
// resolveFixedRouteVendorMarkers/resolveDateVendorMarkers already cover the map side separately.
function getDayVendorCodes(dateKey) {
  const dow = new Date(`${dateKey}T00:00:00`).getDay();
  const weeklyCodes = routeScheduleByDayOfWeek[dow]?.vendor_codes || [];
  const dateCodes = (dateVendorsByDate[dateKey] || []).map((v) => v.vendor_code);
  return Array.from(new Set([...weeklyCodes, ...dateCodes]));
}

// Per "can you show the details of the vendor on the stops for mobile version too" - the Driver
// Route View (Delivery Team's single-day mobile screen) only ever rendered order stops as cards;
// a vendor pickup/drop tagged to that date (weekly recurring or per-date) never showed there at
// all, even though it already plots on the driver's map (renderDayMap). Mirrors the order card's
// shape/classes (driver-stop-card/-header/-address/-notes) so it reads as the same kind of stop,
// with a distinct left-accent color + "Vendor" badge (see .driver-stop-card-vendor, css/
// styles.css) so a driver can tell a pickup apart from a delivery at a glance.
function vendorStopCardsHtml(dateKey) {
  const codes = getDayVendorCodes(dateKey);
  if (codes.length === 0) return '';

  return codes.map((code) => {
    const v = vendorByCode[code];
    const name = v?.name || code;
    const contact = [v?.contact_person, v?.phone].filter(Boolean).join(' - ');
    return `
      <div class="driver-stop-card driver-stop-card-vendor">
        <div class="driver-stop-card-header">
          <span class="driver-stop-customer" style="margin-bottom:0;">${name}</span>
          <span class="badge badge-vendor">Vendor</span>
        </div>
        ${v?.address ? `<div class="driver-stop-address">&#128205; ${v.address}</div>` : ''}
        ${contact ? `<div class="driver-stop-notes muted">&#128222; ${contact}</div>` : ''}
      </div>
    `;
  }).join('');
}

// Driver Route View (Delivery Team only) - a single day's stops as cards, plus its route map
// (renderDayMap reused with the driverRouteMap element id). stopsByDate must already cover this
// date's month - see changeDriverDay/init below, which call loadMonthStops before this.
async function renderDriverRouteView(dateKey) {
  driverDate = dateKey;

  document.getElementById('driverRouteDateLabel').textContent = new Date(`${dateKey}T00:00:00`)
    .toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' });

  const stops = stopsByDate[dateKey] || [];
  const cardsEl = document.getElementById('driverStopCards');
  const vendorCardsHtml = vendorStopCardsHtml(dateKey);

  // A day off still shows any stops a Super User booked on it - only an empty one gets the notice.
  if (isDayOffDateKey(dateKey) && stops.length === 0 && !vendorCardsHtml) {
    cardsEl.innerHTML = '<p class="muted" style="text-align:center; padding:20px;">No deliveries today - Monday is production day off.</p>';
  } else if (stops.length === 0 && !vendorCardsHtml) {
    cardsEl.innerHTML = '<p class="muted" style="text-align:center; padding:20px;">No stops scheduled for this day.</p>';
  } else {
    // Per "can you add the note_print on the stops so the driver can see" - Pancake's own print
    // note (falls back to line-level notes, admin_list_delivery_stops' note_print column), shown
    // as its own line separate from the staff-typed "Note" (DeliveryStops."Notes") above it -
    // same distinction as the desktop Stops table's "Print Note" column.
    // Per "show the details once the box has been clicked or tap" - the whole card opens Order
    // Details (wireDriverRouteNav), not only the order-id button.
    cardsEl.innerHTML = vendorCardsHtml + groupStopsIntoDrops(stops).map((group) => {
      if (group.stops.length > 1) return driverDropCardHtml(group);
      const s = group.stops[0];
      const displayAddress = isPlaceholderAddress(s.shipping_address) ? (s.geocoded_address || '') : s.shipping_address;
      return `
        <div class="driver-stop-card driver-stop-card-tappable" data-stop-id="${s.stop_id}" style="cursor:pointer;">
          <div class="driver-stop-card-header">
            <button type="button" class="driver-stop-order-id" data-stop-id="${s.stop_id}">${s.order_id || ''}</button>
            ${s.status ? `<span class="badge badge-primary">${s.status}</span>` : ''}
          </div>
          <div class="driver-stop-customer">${s.customer_name || ''}</div>
          ${driverBalanceHtml(s.balance)}
          <div class="driver-stop-address">&#128205; ${displayAddress || '<span class="muted">No address on file</span>'}</div>
          ${s.route_name ? `<div class="driver-stop-route muted">&#128666; Route: ${s.route_name}</div>` : ''}
          ${s.notes ? `<div class="driver-stop-notes muted">&#128221; Note: ${s.notes}</div>` : ''}
          ${s.note_print ? `<div class="driver-stop-notes muted">&#128204; Delivery Note: ${s.note_print}</div>` : ''}
          <div class="driver-stop-collections" data-collect-for="${s.stop_id}"></div>
          ${Number(s.balance) > 0 ? `<button type="button" class="btn btn-primary driver-collect-btn" data-collect-stop-id="${s.stop_id}" style="width:100%; margin-top:10px;">&#128176; Record Payment Collected</button>` : ''}
          <div class="driver-stop-done" data-done-for="${s.stop_id}" style="margin-top:10px;">
            <button type="button" class="btn btn-success driver-mark-done-btn" data-done-stop-id="${s.stop_id}" style="width:100%;">&#9989; Mark Done</button>
          </div>
        </div>
      `;
    }).join('');
    loadStopCompletions(stops.map((s) => s.stop_id));
    loadDriverCollections(stops.map((s) => s.stop_id));
  }

  await renderDayMap(stops, dateKey, 'driverRouteMap');
}

// One card for a combined drop (groupStopsIntoDrops): the customer / address once, each order as a
// line (tap to open its details), one combined balance, one Record Payment (split across the orders,
// saveCollection) and one Mark Done (one photo marks every order done, one Facebook post - see
// saveStopDone / postStop). The lead (first) stop stands for the card.
function driverDropCardHtml(group) {
  const lead = group.stops[0];
  const ids = group.stops.map((s) => s.stop_id).join(',');
  const displayAddress = isPlaceholderAddress(lead.shipping_address) ? (lead.geocoded_address || '') : lead.shipping_address;
  const totalBalance = group.stops.reduce((sum, s) => sum + Math.max(Number(s.balance) || 0, 0), 0);
  const knownBalance = group.stops.some((s) => s.balance !== null && s.balance !== undefined && s.balance !== '');
  const notes = Array.from(new Set(group.stops.map((s) => s.notes).filter(Boolean)));
  return `
    <div class="driver-stop-card driver-stop-card-tappable" data-stop-id="${lead.stop_id}" style="cursor:pointer;">
      <div class="driver-stop-card-header">
        <span class="badge badge-primary">&#127968; ${group.stops.length} orders &middot; one drop</span>
      </div>
      <div class="driver-stop-customer">${lead.customer_name || ''}</div>
      ${knownBalance ? driverBalanceHtml(totalBalance) : ''}
      <div class="driver-stop-address">&#128205; ${displayAddress || '<span class="muted">No address on file</span>'}</div>
      ${lead.route_name ? `<div class="driver-stop-route muted">&#128666; Route: ${lead.route_name}</div>` : ''}
      ${notes.map((n) => `<div class="driver-stop-notes muted">&#128221; Note: ${n}</div>`).join('')}
      ${group.stops.map((s) => `
        <div class="driver-drop-order" style="margin-top:8px; padding-top:8px; border-top:1px solid rgba(127,127,127,0.25);">
          <button type="button" class="driver-stop-order-id" data-stop-id="${s.stop_id}">${s.order_id || ''}</button>
          ${s.status ? `<span class="badge badge-primary">${s.status}</span>` : ''}
          ${Number(s.balance) > 0 ? `<span class="muted" style="font-size:12px;">&middot; ${pesoAmount(s.balance)}</span>` : ''}
          ${s.note_print ? `<div class="driver-stop-notes muted">&#128204; Delivery Note: ${s.note_print}</div>` : ''}
          <div class="driver-stop-collections" data-collect-for="${s.stop_id}"></div>
        </div>
      `).join('')}
      ${totalBalance > 0 ? `<button type="button" class="btn btn-primary driver-collect-btn" data-collect-stop-id="${lead.stop_id}" data-collect-drop-ids="${ids}" style="width:100%; margin-top:10px;">&#128176; Record Payment Collected (all ${group.stops.length} orders)</button>` : ''}
      <div class="driver-stop-done" data-done-for="${lead.stop_id}" data-done-members="${ids}" style="margin-top:10px;">
        <button type="button" class="btn btn-success driver-mark-done-btn" data-done-stop-id="${lead.stop_id}" data-done-drop-ids="${ids}" style="width:100%;">&#9989; Mark Done (all ${group.stops.length} orders)</button>
      </div>
    </div>
  `;
}

// --- Driver collections ----------------------------------------------------------------------
// Per "the driver is receiving money sometimes on the delivery.. how can we fullfill it from the
// system" - "Record Payment Collected" on a stop with a balance: amount (prefilled with the balance),
// method, reference. staff_record_delivery_collection (sql/supabase_delivery_driver_collections.sql)
// saves it and puts it on the order right away (Pancake via the POS Online Pay logic, AO- orders on
// their payments; advance orders are recorded only - the POS takes it at Pay In Full). The money then
// reads "With driver" until a Super User marks it Remitted on the day's Collections list.
// collectId is made once per modal and reused on Save retries, so a lost reply can't record it twice.
let collectStopId = null;
let collectId = null;
let collectBusy = false;
let collectMethodsPromise = null;

function newCollectionId() {
  if (window.crypto?.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const r = Math.random() * 16 | 0;
    return (ch === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function pesoAmount(value) {
  return `&#8369;${Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function loadCollectMethods() {
  if (!collectMethodsPromise) {
    collectMethodsPromise = supabaseClient.rpc('staff_list_delivery_payment_methods', {
      p_username: currentSession.username,
      p_password: currentSession.password
    }).then(({ data, error }) => {
      if (error) { collectMethodsPromise = null; throw error; }
      return data || [];
    });
  }
  return collectMethodsPromise;
}

async function fetchCollections(stopIds) {
  if (!stopIds.length) return [];
  const { data, error } = await supabaseClient.rpc('staff_list_delivery_collections', {
    p_username: currentSession.username,
    p_password: currentSession.password,
    p_stop_ids: stopIds
  });
  // Before supabase_delivery_driver_collections.sql is run the RPC doesn't exist - show nothing.
  if (error) return [];
  return data || [];
}

// "On the order" status, shared by the driver card and the day's Collections list.
function collectionApplyHtml(c) {
  if (c.apply_status === 'Applied') {
    const feePart = Number(c.amount) - Number(c.applied_amount || 0);
    return `<span class="badge badge-success" title="${escapeHtmlText(c.applied_in || '')}">&#9989; On the order</span>`
      + (feePart > 0.004 ? ` <span class="muted" style="font-size:12px;">(${pesoAmount(feePart)} delivery fee - stop only)</span>` : '');
  }
  if (c.apply_status === 'Record only') {
    return '<span class="badge badge-warning" title="Advance order - its balance is in the POS">Pay In Full in the POS</span>';
  }
  return `<span class="badge badge-danger">Not on the order yet</span>${c.apply_error ? `<div class="error-text" style="font-size:12px;">${escapeHtmlText(c.apply_error)}</div>` : ''}`;
}

function collectionMoneyHtml(c) {
  if (!c.remitted_at_utc) return '<span class="badge badge-warning">With driver</span>';
  const when = new Date(c.remitted_at_utc).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  return `<span class="badge badge-success">Remitted</span> <span class="muted" style="font-size:12px;">${escapeHtmlText(c.remitted_by || '')} &middot; ${when}</span>`;
}

async function loadDriverCollections(stopIds) {
  const rows = await fetchCollections(stopIds);
  const byStop = new Map();
  rows.forEach((c) => {
    if (!byStop.has(c.stop_id)) byStop.set(c.stop_id, []);
    byStop.get(c.stop_id).push(c);
  });
  document.querySelectorAll('.driver-stop-collections[data-collect-for]').forEach((el) => {
    const list = byStop.get(el.dataset.collectFor) || [];
    el.innerHTML = list.map((c) => {
      const when = new Date(c.collected_at_utc).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      return `<div class="driver-stop-collection" style="margin-top:8px; padding:8px; border-radius:6px; background:rgba(16,124,16,0.08);">
          <div><b>&#128181; Collected ${pesoAmount(c.amount)}</b> &middot; ${escapeHtmlText(c.method_name || '')}${c.reference ? ` <span class="muted">(${escapeHtmlText(c.reference)})</span>` : ''}</div>
          <div class="muted" style="font-size:12px;">${escapeHtmlText(c.collected_by || '')} &middot; ${when}</div>
          <div style="margin-top:4px;">${collectionApplyHtml(c)} ${collectionMoneyHtml(c)}</div>
          ${c.apply_status === 'Failed' ? `<button type="button" class="btn btn-secondary btn-sm driver-collect-retry-btn" data-retry-collection-id="${c.collection_id}" style="width:100%; margin-top:6px;">Try again</button>` : ''}
        </div>`;
    }).join('');
  });
}

function setCollectError(message) {
  const el = document.getElementById('collectError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

// Combined drop: [{ stopId, orderId, cap, collectionId }] - the amount is split across these in card
// order, each up to what's still owed on it (cap). Each part is its own collection with its own ID,
// made once per modal, so Save again after a partial failure never records a part twice.
let collectDropParts = null;

async function openCollectModal(stopId, dropIds = null) {
  const dayStops = stopsByDate[driverDate] || [];
  const stop = dayStops.find((s) => s.stop_id === stopId);
  if (!stop) return;
  collectStopId = stopId;
  collectId = newCollectionId();
  collectDropParts = null;
  let balance = Number(stop.balance || 0);
  let label = `${stop.order_id || ''} · ${stop.customer_name || ''}`;
  if (dropIds && dropIds.length > 1) {
    const members = dropIds.map((id) => dayStops.find((s) => s.stop_id === id)).filter(Boolean);
    // Same as _delivery_stop_collectable: balance minus collections not reflected in it yet.
    const collections = await fetchCollections(members.map((s) => s.stop_id));
    collectDropParts = members.map((s) => {
      const pending = collections.filter((c) => c.stop_id === s.stop_id)
        .reduce((sum, c) => sum + Number(c.amount || 0) - Number(c.applied_amount || 0), 0);
      return { stopId: s.stop_id, orderId: s.order_id, cap: Math.max(Math.round((Number(s.balance || 0) - pending) * 100) / 100, 0), collectionId: newCollectionId() };
    });
    balance = collectDropParts.reduce((sum, p) => sum + p.cap, 0);
    label = `${members.map((s) => s.order_id).join(' + ')} · ${stop.customer_name || ''}`;
  }
  document.getElementById('collectOrderLabel').textContent =
    `${label} · balance ₱${balance.toLocaleString('en-PH', { minimumFractionDigits: 2 })}`;
  document.getElementById('collectAmountInput').value = balance > 0 ? balance.toFixed(2) : '';
  document.getElementById('collectReferenceInput').value = '';
  setCollectError('');
  const select = document.getElementById('collectMethodSelect');
  select.innerHTML = '<option value="">Loading...</option>';
  document.getElementById('collectModal').classList.remove('hidden');
  try {
    const methods = await loadCollectMethods();
    select.innerHTML = methods.map((m) => `<option value="${escapeHtmlText(m.code)}">${escapeHtmlText(m.name)}</option>`).join('');
  } catch (err) {
    select.innerHTML = '<option value="CASH">Cash</option>';
    setCollectError(/schema cache|could not find the function|does not exist/i.test(err.message || '')
      ? 'Payment collection isn\'t set up yet - run sql/supabase_delivery_driver_collections.sql.'
      : `Could not load payment methods: ${err.message}`);
  }
}

function closeCollectModal() {
  if (collectBusy) return;
  document.getElementById('collectModal').classList.add('hidden');
  collectStopId = null;
  collectId = null;
  collectDropParts = null;
}

// Combined drop Save: one staff_record_delivery_collection per order with a share of the amount.
// Returns { failedApply: [...], error } - error = a part that didn't save (Save again retries safely).
async function saveDropCollection(amount, method, reference) {
  const total = collectDropParts.reduce((sum, p) => sum + p.cap, 0);
  if (amount > total + 0.005) {
    return { error: `The amount is more than the balance to collect (₱${total.toFixed(2)}).` };
  }
  if (!collectDropParts.some((p) => p.saved)) {
    collectDropParts.forEach((p) => { delete p.share; });
    collectDropParts.amount = amount;
  } else if (Math.abs(amount - collectDropParts.amount) > 0.004) {
    return { error: `Part of ₱${collectDropParts.amount.toFixed(2)} is already saved - keep that amount and Save again to finish.` };
  }
  let left = Math.round(amount * 100) / 100;
  const failedApply = [];
  for (const part of collectDropParts) {
    if (left <= 0.004) break;
    if (part.share === undefined) part.share = Math.min(left, part.cap);
    left = Math.round((left - part.share) * 100) / 100;
    if (part.share <= 0 || part.saved) continue;
    const { data, error } = await supabaseClient.rpc('staff_record_delivery_collection', {
      p_username: currentSession.username,
      p_password: currentSession.password,
      p_collection_id: part.collectionId,
      p_stop_id: part.stopId,
      p_amount: part.share,
      p_method_code: method,
      p_reference: reference
    });
    if (error) {
      const savedOnes = collectDropParts.filter((p) => p.saved).map((p) => p.orderId);
      return { error: `${part.orderId}: ${error.message}${savedOnes.length ? ` (already saved: ${savedOnes.join(', ')} - Save again finishes the rest)` : ''}` };
    }
    part.saved = true;
    const r = (data || [])[0];
    if (r && r.apply_status === 'Failed') failedApply.push(`${part.orderId}: ${r.apply_error || ''}`);
  }
  return { failedApply };
}

async function reloadDriverDay() {
  const viewed = new Date(`${driverDate}T00:00:00`);
  await loadMonthStops(viewed.getFullYear(), viewed.getMonth());
  await renderDriverRouteView(driverDate);
}

async function saveCollection() {
  if (collectBusy || !collectStopId) return;
  const amount = parseFloat(document.getElementById('collectAmountInput').value);
  const method = document.getElementById('collectMethodSelect').value;
  if (!(amount > 0)) { setCollectError('Enter the amount collected.'); return; }
  if (!method) { setCollectError('Pick how they paid.'); return; }
  const btn = document.getElementById('collectSaveBtn');
  collectBusy = true;
  btn.disabled = true;
  btn.textContent = 'Saving...';
  setCollectError('');
  if (collectDropParts) {
    const result = await saveDropCollection(amount, method, document.getElementById('collectReferenceInput').value.trim() || null);
    collectBusy = false;
    btn.disabled = false;
    btn.textContent = 'Save';
    if (result.error) { setCollectError(`Not saved: ${result.error}`); return; }
    closeCollectModal();
    if (result.failedApply.length) {
      alert(`The payment is saved as collected, but part of it could not be put on the order yet:\n${result.failedApply.join('\n')}\n\nTap "Try again" on the stop later.`);
    }
    await reloadDriverDay();
    return;
  }
  const { data, error } = await supabaseClient.rpc('staff_record_delivery_collection', {
    p_username: currentSession.username,
    p_password: currentSession.password,
    p_collection_id: collectId,
    p_stop_id: collectStopId,
    p_amount: amount,
    p_method_code: method,
    p_reference: document.getElementById('collectReferenceInput').value.trim() || null
  });
  collectBusy = false;
  btn.disabled = false;
  btn.textContent = 'Save';
  if (error) {
    // Same collectId on the next Save - if this one did reach the server it isn't recorded twice.
    setCollectError(`Not saved: ${error.message}`);
    return;
  }
  const r = (data || [])[0];
  closeCollectModal();
  if (r && r.apply_status === 'Failed') {
    alert(`The payment is saved as collected, but it could not be put on the order yet:\n${r.apply_error || ''}\n\nTap "Try again" on the stop later.`);
  }
  await reloadDriverDay();
}

async function retryCollection(collectionId, btn) {
  if (btn) { btn.disabled = true; btn.textContent = 'Trying...'; }
  const { data, error } = await supabaseClient.rpc('staff_retry_delivery_collection', {
    p_username: currentSession.username,
    p_password: currentSession.password,
    p_collection_id: collectionId
  });
  const r = (data || [])[0];
  if (error || (r && r.apply_status === 'Failed')) {
    alert(`Still not on the order: ${error ? error.message : r.apply_error || ''}`);
  }
}

function wireDriverCollections() {
  document.getElementById('driverStopCards').addEventListener('click', async (e) => {
    const collectBtn = e.target.closest('.driver-collect-btn');
    if (collectBtn) {
      openCollectModal(collectBtn.dataset.collectStopId, collectBtn.dataset.collectDropIds ? collectBtn.dataset.collectDropIds.split(',') : null);
      return;
    }
    const retryBtn = e.target.closest('.driver-collect-retry-btn');
    if (retryBtn) {
      await retryCollection(retryBtn.dataset.retryCollectionId, retryBtn);
      await reloadDriverDay();
    }
  });
  document.getElementById('collectSaveBtn').addEventListener('click', saveCollection);
  document.getElementById('collectCancelBtn').addEventListener('click', closeCollectModal);
}

// Office: the day's collections under the stops table - Retry for Failed ones, Super Users mark
// them Remitted once the driver hands the money over.
async function renderDayCollections(dateKey, stops) {
  const section = document.getElementById('dayCollectionsSection');
  const rows = await fetchCollections(stops.map((s) => s.stop_id));
  if (selectedDateKey !== dateKey) return; // another day opened meanwhile
  section.classList.toggle('hidden', !rows.length);
  if (!rows.length) return;
  const isSuper = !!currentSession.isSuperUser;
  const withDriver = rows.filter((c) => !c.remitted_at_utc);
  const withDriverTotal = withDriver.reduce((sum, c) => sum + Number(c.amount || 0), 0);
  const total = rows.reduce((sum, c) => sum + Number(c.amount || 0), 0);
  document.getElementById('dayCollectionsSummary').innerHTML =
    `${pesoAmount(total)} collected${withDriver.length ? ` &middot; ${pesoAmount(withDriverTotal)} still with driver` : ' &middot; all remitted'}`;
  const remitAllBtn = document.getElementById('remitAllCollectionsBtn');
  remitAllBtn.classList.toggle('hidden', !isSuper || withDriver.length < 2);
  remitAllBtn.onclick = () => remitCollections(withDriver.map((c) => c.collection_id), withDriverTotal, dateKey, stops);
  document.getElementById('dayCollectionsBody').innerHTML = rows.map((c) => {
    const stop = stops.find((s) => s.stop_id === c.stop_id);
    const when = new Date(c.collected_at_utc).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
    return `<tr>
        <td>${escapeHtmlText(c.order_ref || '')}<br><span class="muted">${escapeHtmlText(stop?.customer_name || '')}</span></td>
        <td class="num"><b>${pesoAmount(c.amount)}</b></td>
        <td>${escapeHtmlText(c.method_name || '')}${c.reference ? `<br><span class="muted">${escapeHtmlText(c.reference)}</span>` : ''}</td>
        <td>${escapeHtmlText(c.collected_by || '')}<br><span class="muted">${when}</span></td>
        <td>${collectionApplyHtml(c)}</td>
        <td>${collectionMoneyHtml(c)}</td>
        <td>
          ${c.apply_status === 'Failed' ? `<button class="btn btn-secondary btn-sm" type="button" data-retry-collection-id="${c.collection_id}">Retry</button>` : ''}
          ${isSuper && !c.remitted_at_utc ? `<button class="btn btn-primary btn-sm" type="button" data-remit-collection-id="${c.collection_id}">Mark Remitted</button>` : ''}
        </td>
      </tr>`;
  }).join('');
  document.querySelectorAll('#dayCollectionsBody button[data-retry-collection-id]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      await retryCollection(btn.dataset.retryCollectionId, btn);
      await renderMonth(currentYear, currentMonth);
      showDayDetail(dateKey);
    });
  });
  document.querySelectorAll('#dayCollectionsBody button[data-remit-collection-id]').forEach((btn) => {
    const c = rows.find((x) => x.collection_id === btn.dataset.remitCollectionId);
    btn.addEventListener('click', () => remitCollections([c.collection_id], Number(c.amount), dateKey, stops));
  });
}

async function remitCollections(ids, total, dateKey, stops) {
  if (!ids.length) return;
  const amountText = `₱${Number(total).toLocaleString('en-PH', { minimumFractionDigits: 2 })}`;
  if (!confirm(`Mark ${ids.length === 1 ? 'this collection' : `${ids.length} collections`} (${amountText}) as remitted - the driver handed the money to the office?`)) return;
  const { error } = await supabaseClient.rpc('admin_remit_delivery_collections', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_collection_ids: ids
  });
  if (error) { alert(`Could not mark remitted: ${error.message}`); return; }
  await renderDayCollections(dateKey, stops);
}

// Per "show in the view the actual balance of the customer ? show Fully paid if they are fully paid
// already" - the order's balance as admin_list_delivery_stops / admin_get_delivery_receipt return it
// (already adjusted for a manual delivery fee). Only the amount left to collect - item prices stay
// hidden from the driver. Unknown (null) shows nothing.
function driverBalanceHtml(balance) {
  if (balance === null || balance === undefined || balance === '') return '';
  const amount = Number(balance);
  if (!Number.isFinite(amount)) return '';
  if (amount <= 0) return '<div class="driver-stop-balance" style="margin:2px 0 6px;"><span class="badge badge-success">&#9989; Fully paid</span></div>';
  const peso = amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `<div class="driver-stop-balance" style="margin:2px 0 6px;"><span class="badge badge-warning">&#128176; Balance to collect: &#8369;${peso}</span></div>`;
}

// --- Mark Done -------------------------------------------------------------------------------
// Per "show a button mark Done ... it will ask for a picture then after taken picture it will
// proceed on posting": camera photo -> watermark (AI Bot Setup > Facebook Posts defaults), then
// two steps via facebook-page-post (shared helpers in js/facebookPostShared.js;
// supabase_delivery_stop_done_post.sql):
//   1. mark_done - saves the photo and marks the stop Done / its order "Delivered" (portal-only, not
//      sent to Pancake). No Facebook involved, so a delivery is recorded even if Facebook fails.
//   2. post_stop - the server writes the "Delivery Done / Setup Done" caption and posts the stored
//      photo to the GMA and Amaya Pages, at most ONCE per stop per Page (it claims the stop before posting, so a double
//      tap, a second phone or a retry can't post twice). If it fails, the card shows "Post to
//      Facebook" to try again later. No customer details are sent to the AI.
// Nothing here runs on a timer - every Facebook post starts from a tap.
const STUCK_POST_MINUTES = 10;
let markDoneStopId = null;
// Combined drop: every stop on the card (lead first) - all marked done with the one photo, and only
// the lead is posted to Facebook, so a drop is one post, not one per order.
let markDoneStopIds = [];
let markDonePhotoBase64 = null;
let markDoneStep = null; // 'save' | 'post' - what Try Again repeats
let markDoneBusy = false;
let fbPostReady = null; // { settings } once the watermark settings + logo have loaded

function ensureFbPostReady() {
  if (!fbPostReady) {
    fbPostReady = Promise.all([loadFacebookPostSettings(), loadCompanyLogo()]).then(([settings]) => ({ settings }));
  }
  return fbPostReady;
}

async function loadStopCompletions(stopIds) {
  if (!stopIds.length) return;
  const { data, error } = await supabaseClient.rpc('staff_list_delivery_stop_completions', {
    p_username: currentSession.username,
    p_password: currentSession.password,
    p_stop_ids: stopIds
  });
  // Before supabase_delivery_stop_done_post.sql is run the RPC doesn't exist - keep the buttons.
  if (error) return;
  const rows = data || [];
  rows.forEach((row) => {
    const el = document.querySelector(`.driver-stop-done[data-done-for="${row.stop_id}"]`);
    // A drop card reads Done only once every order on it is (a part-done drop keeps Mark Done,
    // which then marks the rest).
    const members = el?.dataset.doneMembers ? el.dataset.doneMembers.split(',') : null;
    if (members && !members.every((id) => rows.some((r) => r.stop_id === id))) return;
    showStopDone(row);
  });
}

function showStopDone(row) {
  const el = document.querySelector(`.driver-stop-done[data-done-for="${row.stop_id}"]`);
  if (!el) return;
  const when = row.done_at_utc ? new Date(row.done_at_utc).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : '';
  let postHtml;
  // One link per Page posted (GMA, and Amaya once supabase_delivery_stop_post_amaya.sql is run).
  const postLinks = [['GMA post', row.facebook_post_url], ['Amaya post', row.amaya_post_url]]
    .filter(([, url]) => url)
    .map(([label, url]) => ` &middot; <a href="${escapeHtmlText(url)}" target="_blank" rel="noopener" style="font-size:12px;">${label}</a>`)
    .join('');
  if (row.post_status === 'posted') {
    postHtml = postLinks || ' &middot; <span class="muted" style="font-size:12px;">Posted</span>';
  } else if (row.post_status === 'in_progress') {
    const minutes = row.post_claimed_at_utc ? (Date.now() - new Date(row.post_claimed_at_utc).getTime()) / 60000 : 0;
    // Never retried automatically - a post that may have gone out is checked by a person first.
    postHtml = minutes > STUCK_POST_MINUTES
      ? '<div class="error-text" style="font-size:12px; margin-top:4px;">Facebook post stuck - ask a super user to check the Page before posting again.</div>'
      : ' &middot; <span class="muted" style="font-size:12px;">Posting to Facebook...</span>';
  } else {
    // A Page that already went out still shows its link; Post to Facebook only posts the other one.
    postHtml = postLinks
      + `${row.post_error ? `<div class="error-text" style="font-size:12px; margin-top:4px;">Not posted: ${escapeHtmlText(row.post_error)}</div>` : ''}`
      + `<button type="button" class="btn btn-secondary btn-sm driver-post-stop-btn" data-post-stop-id="${row.stop_id}" style="width:100%; margin-top:6px;">&#128228; Post to Facebook</button>`;
  }
  el.innerHTML = `<span class="badge badge-success">&#9989; Done</span> <span class="muted" style="font-size:12px;">${escapeHtmlText(row.done_by || '')}${when ? ` &middot; ${when}` : ''}</span>${postHtml}`;
}

function escapeHtmlText(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function setMarkDoneState({ status, caption, error, canRetry }) {
  document.getElementById('markDoneStatus').textContent = status || '';
  if (caption !== undefined) document.getElementById('markDoneCaption').textContent = caption;
  const errorEl = document.getElementById('markDoneError');
  errorEl.textContent = error || '';
  errorEl.classList.toggle('hidden', !error);
  document.getElementById('markDoneRetryBtn').classList.toggle('hidden', !canRetry);
  document.getElementById('markDoneCloseBtn').disabled = markDoneBusy;
}

function openMarkDoneModal(previewSrc) {
  const preview = document.getElementById('markDonePreview');
  preview.classList.toggle('hidden', !previewSrc);
  if (previewSrc) preview.src = previewSrc;
  document.getElementById('markDoneModal').classList.remove('hidden');
}

// Re-reads this stop's Done / post state onto its card.
function refreshStopCard(stopId) {
  const members = document.querySelector(`.driver-stop-done[data-done-for="${stopId}"]`)?.dataset.doneMembers;
  return loadStopCompletions(members ? members.split(',') : [stopId]);
}

async function onMarkDonePhoto(e) {
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!file || !markDoneStopId || markDoneBusy) return;

  openMarkDoneModal(null);
  setMarkDoneState({ status: 'Preparing photo...', caption: '' });
  const objectUrl = URL.createObjectURL(file);
  try {
    const { settings } = await ensureFbPostReady();
    const sourceImg = await loadImage(objectUrl, false);
    const dataUrl = renderWatermarkedPhoto(sourceImg, watermarkOptionsFromSettings(settings));
    markDonePhotoBase64 = dataUrl.split(',')[1];
    openMarkDoneModal(dataUrl);
  } catch (err) {
    setMarkDoneState({ error: err.message || 'Could not read the photo.' });
    return;
  } finally {
    URL.revokeObjectURL(objectUrl);
  }

  if (await saveStopDone()) await postStop();
}

// Step 1 - true once the stop is recorded Done (or already was).
async function saveStopDone() {
  const stopId = markDoneStopId;
  markDoneStep = 'save';
  markDoneBusy = true;
  setMarkDoneState({ status: '💾 Saving delivery...', caption: '' });
  try {
    const ids = markDoneStopIds.length ? markDoneStopIds : [stopId];
    let allAlreadyDone = true;
    for (const id of ids) {
      if (ids.length > 1) setMarkDoneState({ status: `💾 Saving delivery (${ids.indexOf(id) + 1} of ${ids.length})...`, caption: '' });
      const result = await callFacebookPostFunction(currentSession, markDonePhotoBase64, { action: 'mark_done', stop_id: id });
      if (!result.already_done) allAlreadyDone = false;
    }
    markDoneBusy = false;
    await refreshStopCard(stopId);
    if (allAlreadyDone) {
      setMarkDoneState({ status: '✅ This stop was already marked done.' });
      return false;
    }
    return true;
  } catch (err) {
    markDoneBusy = false;
    setMarkDoneState({ status: 'Not saved yet - the delivery is not marked done.', error: err.message, canRetry: true });
    return false;
  }
}

// Step 2 - post the stored photo once. Safe to call again: the server refuses a stop that is
// already posted or being posted.
async function postStop() {
  const stopId = markDoneStopId;
  markDoneStep = 'post';
  markDoneBusy = true;
  setMarkDoneState({ status: '✅ Delivery saved. 📤 Posting to Facebook...', caption: '' });
  try {
    const result = await callFacebookPostFunction(currentSession, '', { action: 'post_stop', stop_id: stopId });
    markDoneBusy = false;
    setMarkDoneState({
      status: result.status === 'already_posted'
        ? '✅ Done! Already posted to the Facebook Pages.'
        : '✅ Done! Saved and posted to the GMA and Amaya Facebook Pages.',
      caption: result.caption || ''
    });
  } catch (err) {
    markDoneBusy = false;
    setMarkDoneState({
      status: '✅ Delivery saved, but the Facebook post did not go out.',
      error: `${err.message} You can try again now, or later with "Post to Facebook" on the stop.`,
      canRetry: true
    });
  }
  await refreshStopCard(stopId);
}

function wireMarkDone() {
  document.getElementById('driverStopCards').addEventListener('click', (e) => {
    if (markDoneBusy) return;
    const doneBtn = e.target.closest('.driver-mark-done-btn');
    if (doneBtn) {
      markDoneStopId = doneBtn.dataset.doneStopId;
      markDoneStopIds = doneBtn.dataset.doneDropIds ? doneBtn.dataset.doneDropIds.split(',') : [];
      // Start loading settings/logo while the driver reads the tip and takes the photo.
      ensureFbPostReady();
      // Per "while taking picture show a note" - a web page can't draw over the phone's own camera
      // screen, so the note shows right before it opens; Open Camera is the tap that opens it.
      document.getElementById('markDoneTipModal').classList.remove('hidden');
      return;
    }
    const postBtn = e.target.closest('.driver-post-stop-btn');
    if (postBtn) {
      markDoneStopId = postBtn.dataset.postStopId;
      markDoneStopIds = [];
      openMarkDoneModal(null);
      postStop();
    }
  });
  document.getElementById('markDoneOpenCameraBtn').addEventListener('click', () => {
    document.getElementById('markDoneTipModal').classList.add('hidden');
    document.getElementById('markDonePhotoInput').click();
  });
  // Per "add an option there to upload a photo choice" - an existing photo from the gallery instead
  // of the camera; same watermark / save / post flow (onMarkDonePhoto).
  document.getElementById('markDoneChooseGalleryBtn').addEventListener('click', () => {
    document.getElementById('markDoneTipModal').classList.add('hidden');
    document.getElementById('markDoneGalleryInput').click();
  });
  document.getElementById('markDoneGalleryInput').addEventListener('change', onMarkDonePhoto);
  document.getElementById('markDoneTipCancelBtn').addEventListener('click', () => {
    document.getElementById('markDoneTipModal').classList.add('hidden');
    markDoneStopId = null;
  });
  document.getElementById('markDonePhotoInput').addEventListener('change', onMarkDonePhoto);
  document.getElementById('markDoneRetryBtn').addEventListener('click', async () => {
    if (markDoneBusy) return;
    if (markDoneStep === 'save') {
      if (await saveStopDone()) await postStop();
    } else {
      await postStop();
    }
  });
  document.getElementById('markDoneCloseBtn').addEventListener('click', () => {
    if (markDoneBusy) return;
    document.getElementById('markDoneModal').classList.add('hidden');
  });
}


async function changeDriverDay(deltaDays) {
  const next = new Date(`${driverDate}T00:00:00`);
  next.setDate(next.getDate() + deltaDays);

  if (next.getFullYear() !== currentYear || next.getMonth() !== currentMonth) {
    currentYear = next.getFullYear();
    currentMonth = next.getMonth();
    await Promise.all([loadMonthStops(currentYear, currentMonth), loadMonthDateVendors(currentYear, currentMonth)]);
  }

  await renderDriverRouteView(toDateKey(next));
}

function wireDriverRouteNav() {
  document.getElementById('driverPrevDayBtn').addEventListener('click', () => changeDriverDay(-1));
  document.getElementById('driverNextDayBtn').addEventListener('click', () => changeDriverDay(1));

  // A tap anywhere on a stop card opens its details - except on the card's own buttons and links
  // (Mark Done, Post to Facebook, View post), which keep doing their own thing.
  document.getElementById('driverStopCards').addEventListener('click', (e) => {
    const btn = e.target.closest('.driver-stop-order-id');
    if (btn) { openDriverOrderDetail(btn.dataset.stopId); return; }
    if (e.target.closest('button, a, input, label')) return;
    const card = e.target.closest('.driver-stop-card-tappable');
    if (card) openDriverOrderDetail(card.dataset.stopId);
  });

  document.getElementById('driverOrderDetailCloseBtn').addEventListener('click', closeDriverOrderDetail);
}

// Per "can the driver see the details without the price" - reuses admin_get_delivery_receipt
// (built for the Print Manifest/Print stop receipt flow, supabase_delivery_receipt.sql, extended
// by supabase_delivery_receipt_line_details.sql to also return each line's line_id/line_note),
// keyed by stop_id rather than order_id since that's what a DeliveryStops row is identified by.
// It already omits per-line price/unit cost entirely (Description/Quantity/Note only) - the only
// price shown is the order's balance to collect (driverBalanceHtml, "Fully paid" at zero) - item
// prices and delivery_fee stay unrendered. Attachments reuse the existing
// admin_list_online_order_line_attachments RPC (same one Online Order Lines uses), matched to
// each line via line_id.
function isDriverAttachmentImage(fileName) {
  return /\.(png|jpe?g|gif|webp)$/i.test(fileName || '');
}

function driverAttachmentsHtml(attachments) {
  if (!attachments || attachments.length === 0) return '';
  return `<div class="driver-detail-attachments">${attachments.map((a) => {
    const label = a.file_name || 'attachment';
    return isDriverAttachmentImage(label)
      ? `<a href="${a.public_url}" target="_blank" rel="noopener" title="${label}"><img src="${a.public_url}" class="attachment-thumb" alt="${label}" /></a>`
      : `<a href="${a.public_url}" target="_blank" rel="noopener" class="attachment-file-chip">&#128206; ${label}</a>`;
  }).join('')}</div>`;
}

async function openDriverOrderDetail(stopId) {
  const modal = document.getElementById('driverOrderDetailModal');
  const body = document.getElementById('driverOrderDetailBody');
  document.getElementById('driverOrderDetailTitle').textContent = 'Order Details';
  body.innerHTML = '<p class="muted">Loading...</p>';
  modal.classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('admin_get_delivery_receipt', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_stop_id: stopId
  });

  if (error || !data || data.length === 0) {
    body.innerHTML = `<p class="error-text">${error ? error.message : 'Could not load order details.'}</p>`;
    return;
  }

  const header = data[0];
  const lines = data.filter((l) => l.line_no !== null);

  document.getElementById('driverOrderDetailTitle').textContent = `Order ${header.order_id || ''}`;

  const attachmentsByLineId = {};
  // Attachments only exist for online orders - an advance stop's "ADV-" id (or a not-yet-synced
  // "AO-" one) would never match.
  if (header.order_id && header.source !== 'advance' && header.source !== 'automated') {
    const { data: attachmentRows } = await supabaseClient.rpc('admin_list_online_order_line_attachments', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: header.order_id
    });
    (attachmentRows || []).forEach((a) => {
      if (!attachmentsByLineId[a.line_id]) attachmentsByLineId[a.line_id] = [];
      attachmentsByLineId[a.line_id].push(a);
    });
  }

  body.innerHTML = `
    <div class="driver-detail-row"><strong>Customer:</strong> ${header.customer_name || ''}</div>
    ${driverBalanceHtml(header.balance)}
    <div class="driver-detail-row"><strong>Phone:</strong> ${header.shipping_phone || '<span class="muted">Not on file</span>'}</div>
    <div class="driver-detail-row"><strong>Address:</strong> ${header.shipping_address || '<span class="muted">Not on file</span>'}</div>
    ${header.note_print ? `<div class="driver-detail-row"><strong>Notes:</strong> ${header.note_print}</div>` : ''}
    ${header.stop_notes ? `<div class="driver-detail-row"><strong>Delivery Instructions:</strong> ${header.stop_notes}</div>` : ''}
    <h3 class="driver-detail-products-heading">Products</h3>
    ${lines.length === 0
      ? '<p class="muted">No line items found.</p>'
      : `<ul class="driver-detail-products">${lines.map((l) => `
          <li>
            <div class="driver-detail-product-row">
              <span>${l.line_description || ''}</span>
              <span class="muted">&times; ${l.line_quantity ?? ''}</span>
            </div>
            ${l.line_note ? `<div class="driver-detail-product-note muted">Note: ${l.line_note}</div>` : ''}
            ${driverAttachmentsHtml(attachmentsByLineId[l.line_id])}
          </li>
        `).join('')}</ul>`}
  `;
}

function closeDriverOrderDetail() {
  document.getElementById('driverOrderDetailModal').classList.add('hidden');
}

// A synthetic (non-removable) row summarizing that weekday's fixed route (Delivery Setup),
// shown at the top of the day-detail stops table even on days with zero real orders assigned
// yet - per "once the delivery setup has been fill in .. i want it to show in the delivery as
// stops fixed for that date". Not counted toward the calendar's "X stops" badge - that count
// stays reserved for actual scheduled orders.
function fixedRouteRowHtml(dateKey) {
  const dow = new Date(`${dateKey}T00:00:00`).getDay();
  const route = routeScheduleByDayOfWeek[dow];
  if (!route || !route.route_name) return '';

  // Warehouses only - this weekday's Vendors used to be listed here too, but each one now gets
  // its own stop row (vendorStopRowsHtml) per "can you put the stops on the delivery calendar
  // even if its vendor", so repeating them here would just duplicate the same stops.
  const tags = (route.warehouse_names || []).map((n) => `Warehouse: ${n}`);

  return `
    <tr class="delivery-fixed-route-row">
      <td>-</td>
      <td><em>Fixed Route</em></td>
      <td>${route.route_name}</td>
      <td>${tags.length > 0 ? `<span class="badge badge-neutral">${tags.length} Fixed</span>` : ''}</td>
      <td colspan="2">${tags.join(', ')}</td>
      <td class="muted">Set in Delivery Setup</td>
      <td></td>
      <td></td>
    </tr>
  `;
}

// Per "can you put the stops on the delivery calendar even if its vendor" - the day-detail table
// only ever listed real order stops (plus the one summary Fixed Route row), so a vendor
// pickup/drop was visible only as a chip above the table or a tag inside that summary row, never
// as a stop in its own right. Each vendor tagged to this date (weekly recurring Delivery Setup
// route + per-date assignment, deduped by getDayVendorCodes) now gets its own row in the same
// table, mirroring vendorStopCardsHtml on the Driver Route View. Address/contact come from
// vendorByCode (loadVendorLookup), the same source the map markers use.
function vendorStopRowsHtml(dateKey) {
  const dow = new Date(`${dateKey}T00:00:00`).getDay();
  const weeklyRoute = routeScheduleByDayOfWeek[dow];
  const weeklyCodes = new Set(weeklyRoute?.vendor_codes || []);

  return getDayVendorCodes(dateKey).map((code) => {
    const vendor = vendorByCode[code];
    const name = vendor?.name || code;
    const contact = [vendor?.contact_person, vendor?.phone].filter(Boolean).join(' - ');
    const isWeekly = weeklyCodes.has(code);
    // Weekly recurring vendors are edited in Delivery Setup, so only the ad hoc per-date ones
    // get a Remove button here - same super-user gate as the vendor chips above the table
    // (removeDateVendor / admin_remove_delivery_date_vendor).
    const canRemove = !isWeekly && currentSession.isSuperUser;

    return `
      <tr class="delivery-vendor-stop-row">
        <td>-</td>
        <td>${name}</td>
        <td>${isWeekly && weeklyRoute?.route_name ? weeklyRoute.route_name : ''}</td>
        <td><span class="badge badge-vendor">Vendor</span></td>
        <td>${vendor?.address || '<span class="muted">No address on file</span>'}</td>
        <td class="muted">${isWeekly ? 'Delivery Setup' : 'Assigned to this date'}</td>
        <td>${contact}</td>
        <td></td>
        <td>${canRemove ? `<button class="btn btn-danger btn-sm" data-remove-vendor-stop-code="${code}" type="button">Remove</button>` : ''}</td>
      </tr>
    `;
  }).join('');
}

// Per-date Vendor tags (super-user-only assign/remove, everyone else sees them read-only) - the
// chip list + assign dropdown shown at the top of the day-detail panel. See
// admin_assign_delivery_date_vendor/admin_remove_delivery_date_vendor/dateVendorsByDate above.
function renderDateVendorsSection(dateKey) {
  const vendors = dateVendorsByDate[dateKey] || [];
  const chipsEl = document.getElementById('dateVendorChips');

  // Per "can you include the details too on the delivery view? so the user can see the address /
  // contacts and other details" - each assigned vendor now renders as a chip (name + remove)
  // plus a muted detail line underneath (address/contact person/phone, via vendorDetailText)
  // instead of a bare name-only pill.
  chipsEl.innerHTML = vendors.length === 0
    ? '<span class="muted" style="font-size:12px;">No vendors assigned to this date.</span>'
    : vendors.map((v) => {
        const details = vendorDetailText(v.vendor_code);
        return `
          <div class="delivery-vendor-detail-row">
            <span class="serial-tag-chip">
              Vendor: ${v.vendor_name}
              ${currentSession.isSuperUser ? `<span class="serial-tag-chip-remove" data-remove-vendor-code="${v.vendor_code}" title="Remove">&times;</span>` : ''}
            </span>
            ${details ? `<div class="muted delivery-vendor-detail-text">${details}</div>` : ''}
          </div>
        `;
      }).join('');

  chipsEl.querySelectorAll('[data-remove-vendor-code]').forEach((el) => {
    el.addEventListener('click', () => removeDateVendor(dateKey, el.dataset.removeVendorCode));
  });

  const controls = document.getElementById('assignVendorControls');
  controls.classList.toggle('hidden', !currentSession.isSuperUser);
  if (!currentSession.isSuperUser) return;

  const assignedCodes = new Set(vendors.map((v) => v.vendor_code));
  const availableVendors = Object.values(vendorByCode).filter((v) => !assignedCodes.has(v.vendor_code));
  const select = document.getElementById('assignVendorSelect');
  select.innerHTML = availableVendors.length === 0
    ? '<option value="">No more vendors available</option>'
    : availableVendors.map((v) => `<option value="${v.vendor_code}">${v.name}</option>`).join('');

  const assignBtn = document.getElementById('assignVendorBtn');
  assignBtn.disabled = availableVendors.length === 0 || isBlockedDeliveryDateKey(dateKey);
  assignBtn.title = isBlockedDeliveryDateKey(dateKey) ? DAY_OFF_MESSAGE : '';
}

async function assignDateVendor(dateKey) {
  const vendorCode = document.getElementById('assignVendorSelect').value;
  if (!vendorCode) return;

  const { data, error } = await supabaseClient.rpc('admin_assign_delivery_date_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_delivery_date: dateKey,
    p_vendor_code: vendorCode
  });

  const result = data?.[0];
  if (error || !result?.success) {
    window.alert((error && error.message) || result?.message || 'Could not assign vendor.');
    return;
  }

  await renderMonth(currentYear, currentMonth);
  showDayDetail(dateKey);
}

async function removeDateVendor(dateKey, vendorCode) {
  const { error } = await supabaseClient.rpc('admin_remove_delivery_date_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_delivery_date: dateKey,
    p_vendor_code: vendorCode
  });

  if (error) {
    console.error('admin_remove_delivery_date_vendor failed:', error);
    return;
  }

  await renderMonth(currentYear, currentMonth);
  showDayDetail(dateKey);
}

// Per "Dont allow to print an order if there is no delivery fee" - a stop's Print / Print Invoice /
// Print Job Order stay blocked until it has a fee (the stop's own from Calculate fee, or the order's).
// Client-side only, like the other print gating on this page.
function stopHasDeliveryFee(s) {
  // An order riding on another order's fee in a combined drop (fee_combined_with) has 0 on purpose.
  return Number(s?.delivery_fee) > 0 || !!s?.fee_combined_with;
}

// --- Combined drops ----------------------------------------------------------------------------
// Per "if an customer has multiple orders and plan to deliver it on one day" - stops on one date with
// the same customer + address (drop_key, sql/supabase_delivery_combined_drops.sql) are one drop: one
// header row in the office table, one driver card, one map pin, one Mark Done, one payment. Each order
// is still its own stop underneath. The drop is charged once (default) or per order
// (staff_set_delivery_drop_fee_mode) - the server moves the fee onto one order and 0 on the others.
// Groups keep the stops' own order, placed where the drop's first stop is. No drop_key = on its own.
function groupStopsIntoDrops(stops) {
  const groups = [];
  const byKey = new Map();
  (stops || []).forEach((s) => {
    if (s.drop_key && byKey.has(s.drop_key)) { byKey.get(s.drop_key).stops.push(s); return; }
    const group = { key: s.drop_key || null, stops: [s] };
    if (s.drop_key) byKey.set(s.drop_key, group);
    groups.push(group);
  });
  return groups;
}

// Per "Production manager / store manager and sales users" (+ Super User) - re-checked server side.
function canSetDropFeeMode() {
  const s = currentSession || {};
  return !!(s.isSuperUser || s.isProductionManager || s.isStoreManager || s.isSalesUser);
}

// The fee line under a stop's status in the office table.
function stopDropFeeNoteHtml(s, group) {
  if (!group || group.stops.length < 2) return '';
  if (s.fee_combined_with) {
    if (s.combined_fee_waived !== null && s.combined_fee_waived !== undefined) {
      return `<br><span class="muted">Delivery fee combined with ${escapeHtmlText(s.fee_combined_with)} (${pesoAmount(s.combined_fee_waived)} taken off)</span>`;
    }
    if (Number(s.delivery_fee) > 0) {
      return `<br><span class="error-text">Fee ${pesoAmount(s.delivery_fee)} already paid on this order, so it was not taken off - refund it or switch the drop to Per order</span>`;
    }
    return `<br><span class="muted">Delivery fee combined with ${escapeHtmlText(s.fee_combined_with)}</span>`;
  }
  if (group.stops.some((x) => x.fee_combined_with)) {
    return `<br><span class="muted">Carries the one delivery fee for this drop</span>`;
  }
  return '';
}

function dropHeaderRowHtml(group, dateKey) {
  const lead = group.stops[0];
  const address = isPlaceholderAddress(lead.shipping_address) ? (lead.geocoded_address || '') : lead.shipping_address;
  const mode = lead.drop_fee_mode || 'once';
  const disabled = canSetDropFeeMode() ? '' : ' disabled title="Only a Super User, Production Manager, Store Manager or Sales User can change this"';
  return `
    <tr class="delivery-drop-header-row" style="background:rgba(29,79,145,0.08);">
      <td colspan="9">
        &#127968; <strong>Combined delivery</strong> &middot; ${escapeHtmlText(lead.customer_name || '')} &middot; ${group.stops.length} orders
        <span class="muted">&middot; ${escapeHtmlText(address || '')}</span>
        <label style="margin-left:12px; white-space:nowrap;">Delivery fee:
          <select class="form-control" style="display:inline-block; width:auto; padding:2px 6px;" data-drop-fee-mode-key="${escapeHtmlText(group.key)}" data-drop-date="${dateKey}"${disabled}>
            <option value="once"${mode === 'once' ? ' selected' : ''}>Charge once (one trip)</option>
            <option value="per_order"${mode === 'per_order' ? ' selected' : ''}>Charge per order</option>
          </select>
        </label>
      </td>
    </tr>
  `;
}

async function setDropFeeMode(select) {
  const dateKey = select.dataset.dropDate;
  const mode = select.value;
  const previous = mode === 'once' ? 'per_order' : 'once';
  const message = mode === 'once'
    ? 'Charge ONE delivery fee for all these orders?\n\nOne order keeps its fee and the others go to 0. An order whose fee is already paid keeps it (refund it yourself if needed).'
    : 'Charge EACH order its own delivery fee?\n\nThe fees taken off for the combined delivery are put back on those orders, so the customer pays more.';
  if (!window.confirm(message)) { select.value = previous; return; }
  select.disabled = true;
  const { error } = await supabaseClient.rpc('staff_set_delivery_drop_fee_mode', {
    p_username: currentSession.username,
    p_password: currentSession.password,
    p_delivery_date: dateKey,
    p_drop_key: select.dataset.dropFeeModeKey,
    p_fee_mode: mode
  });
  if (error) {
    select.value = previous;
    select.disabled = false;
    window.alert(/could not find the function|schema cache/i.test(error.message)
      ? 'Combined deliveries aren\'t set up yet - run sql/supabase_delivery_combined_drops.sql.'
      : `Not changed: ${error.message}`);
    return;
  }
  await renderMonth(currentYear, currentMonth);
  showDayDetail(dateKey);
}

function guardStopPrint(stops, stopId) {
  const stop = stops.find((x) => x.stop_id === stopId);
  if (stopHasDeliveryFee(stop)) return true;
  window.alert(`Order ${stop?.order_id || ''} has no delivery fee yet, so it can't be printed. Open Edit Details, click Calculate fee, then Continue - then print.`);
  return false;
}

function showDayDetail(dateKey) {
  selectedDateKey = dateKey;
  document.querySelectorAll('.delivery-day-cell[data-date]').forEach((cell) => {
    cell.classList.toggle('selected', cell.dataset.date === dateKey);
  });

  const stops = stopsByDate[dateKey] || [];
  const panel = document.getElementById('dayDetailPanel');
  panel.classList.remove('hidden');
  panel.dataset.date = dateKey;

  renderDateVendorsSection(dateKey);

  const label = new Date(`${dateKey}T00:00:00`).toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
  });
  document.getElementById('dayDetailTitle').textContent = `Stops for ${label}`;

  const tbody = document.getElementById('dayStopsTableBody');
  const fixedRouteRow = fixedRouteRowHtml(dateKey);
  // Vendor stops sit between the Fixed Route summary row and the order stops, so a day whose
  // only work is a vendor pickup still reads as a day with stops instead of "No stops scheduled".
  const vendorRows = vendorStopRowsHtml(dateKey);
  tbody.innerHTML = fixedRouteRow + vendorRows + (stops.length === 0
    ? (vendorRows ? '' : '<tr><td colspan="9" class="muted">No stops scheduled for this day.</td></tr>')
    : groupStopsIntoDrops(stops).map((group) => (group.stops.length > 1 ? dropHeaderRowHtml(group, dateKey) : '') + group.stops.map((s) => {
        const inDrop = group.stops.length > 1;
        // Falls back to geocoded_address (a DeliveryStops-only field) when the order itself has
        // no real ShippingAddress on file - either genuinely blank, or Pancake's own "Walkin"
        // placeholder text (isPlaceholderAddress) - that's where a manually-typed address from
        // the "no address"/walk-in confirmation prompt in confirmAssign() ends up, since it's
        // never written back to OnlineOrders.ShippingAddress (a Pancake-synced field).
        const displayAddress = isPlaceholderAddress(s.shipping_address) ? (s.geocoded_address || '') : s.shipping_address;
        // "(manually entered)" fires either from the new is_manual_address flag (supabase_delivery_
        // stop_manual_address.sql - shipping_address IS the override once ManualAddress is set, real
        // Pancake address or not) or the older placeholder+geocoded_address combination, kept for
        // stops saved before that migration that only ever got a GeocodedAddress cache.
        const isManuallyEnteredAddress = s.is_manual_address || (isPlaceholderAddress(s.shipping_address) && s.geocoded_address);
        // Per "can you add the note_print on the stops so the driver can see" - Pancake's own
        // print note (falls back to line-level notes, see admin_list_delivery_stops' note_print
        // column, supabase_delivery_tables.sql), rendered in its own "Print Note" column,
        // separate from the "Notes" column above (DeliveryStops."Notes" - a staff-typed
        // scheduling note, an unrelated field).
        return `
        <tr${inDrop ? ' class="delivery-drop-member-row"' : ''}>
          <td>${inDrop ? '<span class="muted">&#8627;</span> ' : ''}${s.order_id || ''}</td>
          <td>${s.customer_name || ''}</td>
          <td>${s.route_name || ''}</td>
          <td>${s.status || ''}${s.is_manual_delivery_fee && !s.fee_combined_with ? `<br><span class="muted">Delivery fee ${Number(s.delivery_fee).toFixed(2)} (manual)</span>` : ''}${stopDropFeeNoteHtml(s, group)}${stopHasDeliveryFee(s) ? '' : '<br><span class="error-text">No delivery fee - can\'t print yet</span>'}</td>
          <td>${displayAddress}${isManuallyEnteredAddress ? ' <span class="muted">(manually entered)</span>' : ''}</td>
          <td>${s.created_by || ''}</td>
          <td>${s.notes || ''}</td>
          <td>${s.note_print || ''}</td>
          <td>
            <button class="btn btn-secondary btn-sm" data-print-stop-id="${s.stop_id}" type="button">Print</button>
            <button class="btn btn-secondary btn-sm" data-print-invoice-stop-id="${s.stop_id}" type="button">Print Invoice</button>
            <button class="btn btn-secondary btn-sm" data-print-joborder-stop-id="${s.stop_id}" type="button">Print Job Order</button>
            <button class="btn btn-secondary btn-sm" data-edit-stop-id="${s.stop_id}" type="button" title="Fix this stop's customer name/address">Edit Details</button>
            ${s.geocode_status !== 'ok' ? `<button class="btn btn-secondary btn-sm" data-retry-geocode-id="${s.stop_id}" data-retry-geocode-address="${encodeURIComponent(displayAddress)}" type="button">Retry Map</button>` : ''}
            ${currentSession.isSuperUser ? `<button class="btn btn-danger btn-sm" data-stop-id="${s.stop_id}" type="button">Remove</button>` : ''}
          </td>
        </tr>
      `;
      }).join('')).join(''));

  tbody.querySelectorAll('select[data-drop-fee-mode-key]').forEach((select) => {
    select.addEventListener('change', () => setDropFeeMode(select));
  });

  tbody.querySelectorAll('button[data-stop-id]').forEach((btn) => {
    btn.addEventListener('click', () => removeStop(btn.dataset.stopId, dateKey));
  });

  tbody.querySelectorAll('button[data-remove-vendor-stop-code]').forEach((btn) => {
    btn.addEventListener('click', () => removeDateVendor(dateKey, btn.dataset.removeVendorStopCode));
  });

  tbody.querySelectorAll('button[data-print-stop-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      if (!guardStopPrint(stops, btn.dataset.printStopId)) return;
      window.open(`delivery-receipt.html?stop=${encodeURIComponent(btn.dataset.printStopId)}`, '_blank');
    });
  });

  tbody.querySelectorAll('button[data-edit-stop-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const stop = stops.find((x) => x.stop_id === btn.dataset.editStopId);
      if (stop) openFixStopDetails(stop);
    });
  });

  tbody.querySelectorAll('button[data-print-invoice-stop-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      if (!guardStopPrint(stops, btn.dataset.printInvoiceStopId)) return;
      window.open(`invoice.html?stop=${encodeURIComponent(btn.dataset.printInvoiceStopId)}`, '_blank');
    });
  });

  tbody.querySelectorAll('button[data-print-joborder-stop-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      if (!guardStopPrint(stops, btn.dataset.printJoborderStopId)) return;
      window.open(`job-order.html?stop=${encodeURIComponent(btn.dataset.printJoborderStopId)}`, '_blank');
    });
  });

  tbody.querySelectorAll('button[data-retry-geocode-id]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      btn.textContent = 'Retrying...';
      const address = decodeURIComponent(btn.getAttribute('data-retry-geocode-address'));
      await geocodeAndSaveStop(btn.getAttribute('data-retry-geocode-id'), address);
      await renderMonth(currentYear, currentMonth);
      showDayDetail(dateKey);
    });
  });

  renderDayCollections(dateKey, stops);
  renderDayMap(stops, dateKey);
}

// Resolves the day's fixed-route warehouses (Delivery Setup) to plot as distinct origin markers
// alongside the order stops - per "put on the Address of the warehouse so it can flow on the
// delivery address / maps". Geocodes lazily (and caches back via admin_update_warehouse_geocode)
// the first time a warehouse's Address hasn't been geocoded yet, or has changed since it last
// was (GeocodedAddress <> Address, same staleness check as order stops).
async function resolveFixedRouteWarehouseMarkers(dateKey) {
  const dow = new Date(`${dateKey}T00:00:00`).getDay();
  const warehouseIds = routeScheduleByDayOfWeek[dow]?.warehouse_ids || [];
  const markers = [];

  for (const warehouseId of warehouseIds) {
    const warehouse = warehouseById[warehouseId];
    if (!warehouse || !warehouse.address) continue;

    if (warehouse.geocode_status !== 'ok' || warehouse.geocoded_address !== warehouse.address) {
      await geocodeAndSaveWarehouse(warehouseId, warehouse.address);
    }

    if (warehouse.geocode_status === 'ok' && warehouse.latitude && warehouse.longitude) {
      markers.push(warehouse);
    }
  }

  return markers;
}

// Vendor counterpart of resolveFixedRouteWarehouseMarkers above - same lazy-geocode-and-cache
// approach, but reading routeScheduleByDayOfWeek's vendor_codes/vendorByCode instead.
async function resolveFixedRouteVendorMarkers(dateKey) {
  const dow = new Date(`${dateKey}T00:00:00`).getDay();
  const vendorCodes = routeScheduleByDayOfWeek[dow]?.vendor_codes || [];
  const markers = [];

  for (const vendorCode of vendorCodes) {
    const vendor = vendorByCode[vendorCode];
    if (!vendor || !vendor.address) continue;

    if (vendor.geocode_status !== 'ok' || vendor.geocoded_address !== vendor.address) {
      await geocodeAndSaveVendor(vendorCode, vendor.address);
    }

    if (vendor.geocode_status === 'ok' && vendor.latitude && vendor.longitude) {
      markers.push(vendor);
    }
  }

  return markers;
}

// Per-date (ad hoc, super-user-assigned) Vendor counterpart of resolveFixedRouteVendorMarkers
// above - same lazy-geocode-and-cache approach, but reading dateVendorsByDate for this exact
// date instead of the weekly recurring schedule. Plotted with a distinct marker color (see
// renderDayMap below) so it reads as "one-off for this date" rather than "every week".
async function resolveDateVendorMarkers(dateKey) {
  const vendorCodes = (dateVendorsByDate[dateKey] || []).map((v) => v.vendor_code);
  const markers = [];

  for (const vendorCode of vendorCodes) {
    const vendor = vendorByCode[vendorCode];
    if (!vendor || !vendor.address) continue;

    if (vendor.geocode_status !== 'ok' || vendor.geocoded_address !== vendor.address) {
      await geocodeAndSaveVendor(vendorCode, vendor.address);
    }

    if (vendor.geocode_status === 'ok' && vendor.latitude && vendor.longitude) {
      markers.push(vendor);
    }
  }

  return markers;
}

// Dark map style matching the Driver Route View's "tech" motif (#driverRouteView in
// css/styles.css) - applied only to the driverRouteMap element below, never to the admin
// calendar's dayMap, which stays on the default light Google Maps look.
const DRIVER_MAP_DARK_STYLE = [
  { elementType: 'geometry', stylers: [{ color: '#0b1220' }] },
  { elementType: 'labels.text.stroke', stylers: [{ color: '#0b1220' }] },
  { elementType: 'labels.text.fill', stylers: [{ color: '#7c8aa5' }] },
  { featureType: 'administrative', elementType: 'geometry', stylers: [{ color: '#22314b' }] },
  { featureType: 'poi', elementType: 'geometry', stylers: [{ color: '#111a2c' }] },
  { featureType: 'poi', elementType: 'labels.text.fill', stylers: [{ color: '#4a5a78' }] },
  { featureType: 'road', elementType: 'geometry', stylers: [{ color: '#1e2a42' }] },
  { featureType: 'road', elementType: 'geometry.stroke', stylers: [{ color: '#111a2c' }] },
  { featureType: 'road.highway', elementType: 'geometry', stylers: [{ color: '#28405c' }] },
  { featureType: 'transit', elementType: 'geometry', stylers: [{ color: '#111a2c' }] },
  { featureType: 'water', elementType: 'geometry', stylers: [{ color: '#060b14' }] }
];

// Small floating chip showing an order's ID beside its pin on the admin calendar's map (per "the
// red pin its an order id from customer.. can you add a small order ID beside the pin") - a plain
// google.maps.Marker `label` draws text centered inside the pin itself, which is too cramped for
// an order id, so this instead anchors a small HTML chip to the map's overlay pane, positioned
// just above-right of the pin's head. Re-created on every renderDayMap() call along with the
// markers - no manual cleanup needed since renderDayMap wipes mapEl.innerHTML (which includes the
// map's overlay panes this attaches into) before rebuilding.
//
// Built lazily (not as a top-level `class ... extends google.maps.OverlayView`) because
// google.maps doesn't exist yet when this file first parses - the Maps script is only injected
// later, on demand, by loadGoogleMapsScript() above. A top-level `extends google.maps.OverlayView`
// would throw as soon as this script loads, breaking the whole page.
let OrderIdLabelOverlayClass = null;
function getOrderIdLabelOverlayClass() {
  if (!OrderIdLabelOverlayClass) {
    OrderIdLabelOverlayClass = class extends google.maps.OverlayView {
      constructor(position, text) {
        super();
        this.position = position;
        this.text = text;
      }

      onAdd() {
        const div = document.createElement('div');
        div.style.position = 'absolute';
        div.style.transform = 'translate(10px, -34px)';
        div.style.background = '#ffffff';
        div.style.border = '1px solid #dc2626';
        div.style.borderRadius = '4px';
        div.style.padding = '1px 5px';
        div.style.fontSize = '11px';
        div.style.fontWeight = '600';
        div.style.color = '#111827';
        div.style.whiteSpace = 'nowrap';
        div.style.pointerEvents = 'none';
        div.textContent = this.text;
        this.div = div;
        this.getPanes().overlayMouseTarget.appendChild(div);
      }

      draw() {
        const point = this.getProjection()?.fromLatLngToDivPixel(this.position);
        if (point && this.div) {
          this.div.style.left = `${point.x}px`;
          this.div.style.top = `${point.y}px`;
        }
      }

      onRemove() {
        if (this.div) {
          this.div.parentNode.removeChild(this.div);
          this.div = null;
        }
      }
    };
  }
  return OrderIdLabelOverlayClass;
}

// A stop marked GeocodeStatus = 'stale' had its address changed from the Online Orders card
// (admin_set_portal_order_shipping_details, supabase_online_order_shipping_details_sync.sql - SQL can't
// geocode). Geocoded here the first time its day is drawn, saved, and patched into `stops` in place so
// this same render plots it.
async function replotStaleStops(stops) {
  for (const s of stops) {
    if (s.geocode_status !== 'stale') continue;
    const address = isPlaceholderAddress(s.shipping_address) ? '' : (s.shipping_address || '').trim();
    const result = !address ? null : await new Promise((resolve) => {
      new google.maps.Geocoder().geocode({ address }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0] : null);
      });
    });
    const coords = result ? { lat: result.geometry.location.lat(), lng: result.geometry.location.lng() } : null;
    const { error } = await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_stop_id: s.stop_id,
      p_geocoded_address: address || null,
      p_latitude: coords ? coords.lat : null,
      p_longitude: coords ? coords.lng : null,
      p_geocode_status: coords ? 'ok' : 'failed'
    });
    if (error) {
      console.error('Re-plotting stale stop failed:', error);
      continue;
    }
    s.geocode_status = coords ? 'ok' : 'failed';
    s.geocoded_address = address || null;
    s.latitude = coords ? coords.lat : null;
    s.longitude = coords ? coords.lng : null;
  }
}

// mapElId defaults to the admin day-detail panel's map ('dayMap'); the Driver Route View passes
// 'driverRouteMap' to reuse this same marker/bounds logic for its single-day map.
async function renderDayMap(stops, dateKey, mapElId = 'dayMap') {
  const mapEl = document.getElementById(mapElId);
  const isDriverMap = mapElId === 'driverRouteMap';
  const isToday = dateKey === toDateKey(new Date());

  dayMapDateKey = dateKey;

  try {
    await loadGoogleMapsScript();
  } catch (err) {
    mapEl.textContent = err.message;
    return;
  }

  await replotStaleStops(stops);

  const plottedStops = stops.filter((s) => s.geocode_status === 'ok' && s.latitude && s.longitude);
  const warehouseMarkers = await resolveFixedRouteWarehouseMarkers(dateKey);
  const vendorMarkers = await resolveFixedRouteVendorMarkers(dateKey);
  const dateVendorMarkers = await resolveDateVendorMarkers(dateKey);
  // Live driver pins are only meaningful for TODAY's map - a driver's *current* location has no
  // relationship to a day being browsed in the past/future (see plotDriverMarkers below).
  const driverLocations = isToday ? await fetchDriverLocations() : [];

  if (plottedStops.length === 0 && warehouseMarkers.length === 0 && vendorMarkers.length === 0 && dateVendorMarkers.length === 0 && driverLocations.length === 0) {
    mapEl.innerHTML = '<p class="muted" style="padding:12px;">No geocoded locations to show for this day yet.</p>';
    dayMapInstance = null;
    clearDriverMarkers();
    return;
  }

  mapEl.innerHTML = '';
  dayMapInstance = new google.maps.Map(mapEl, {
    zoom: 12,
    ...(isDriverMap ? { styles: DRIVER_MAP_DARK_STYLE } : {})
  });

  const bounds = new google.maps.LatLngBounds();

  warehouseMarkers.forEach((w) => {
    const position = { lat: Number(w.latitude), lng: Number(w.longitude) };
    new google.maps.Marker({
      position,
      map: dayMapInstance,
      title: `Warehouse: ${w.name}`,
      icon: 'https://maps.google.com/mapfiles/ms/icons/green-dot.png'
    });
    bounds.extend(position);
  });

  vendorMarkers.forEach((v) => {
    const position = { lat: Number(v.latitude), lng: Number(v.longitude) };
    const details = vendorDetailText(v.vendor_code);
    new google.maps.Marker({
      position,
      map: dayMapInstance,
      title: `Vendor: ${v.name}${details ? ` - ${details}` : ''}`,
      icon: 'https://maps.google.com/mapfiles/ms/icons/orange-dot.png'
    });
    bounds.extend(position);
  });

  // Per-date (one-off, super-user-assigned) vendors get a distinct purple pin so they read as
  // "just for this date" rather than the weekly-recurring orange ones above.
  dateVendorMarkers.forEach((v) => {
    const position = { lat: Number(v.latitude), lng: Number(v.longitude) };
    const details = vendorDetailText(v.vendor_code);
    new google.maps.Marker({
      position,
      map: dayMapInstance,
      title: `Vendor (this date): ${v.name}${details ? ` - ${details}` : ''}`,
      icon: 'https://maps.google.com/mapfiles/ms/icons/purple-dot.png'
    });
    bounds.extend(position);
  });

  // Super Users can drag an order's pin on the admin calendar map to move the stop - see
  // onStopPinDragged (confirms via Edit Details before saving).
  const canDragPins = !isDriverMap && currentSession.isSuperUser;

  // A combined drop is one pin (its first stop's spot) labelled with every order on it. Not
  // draggable - moving one pin would only move its first order out of the drop.
  const plottedDrops = groupStopsIntoDrops(plottedStops);
  plottedDrops.forEach((group) => {
    const s = group.stops[0];
    const isDrop = group.stops.length > 1;
    const orderIds = group.stops.map((x) => x.order_id).filter(Boolean).join(' + ');
    const draggable = canDragPins && !isDrop;
    const position = { lat: Number(s.latitude), lng: Number(s.longitude) };
    const marker = new google.maps.Marker({
      position,
      map: dayMapInstance,
      title: `${orderIds} - ${s.customer_name || ''}${draggable ? ' (drag to move)' : ''}`,
      draggable,
      // Cyan pin on the driver map to match the tech motif's accent color - default red pin on
      // the admin calendar's map stays untouched.
      icon: isDriverMap ? 'https://maps.google.com/mapfiles/ms/icons/ltblue-dot.png' : undefined
    });
    bounds.extend(position);

    // Order id chip beside the pin - admin calendar map only (see OrderIdLabelOverlay above); the
    // driver map already shows this via the tooltip/marker title and doesn't need the extra chip.
    let chip = null;
    if (!isDriverMap && orderIds) {
      const OrderIdLabelOverlay = getOrderIdLabelOverlayClass();
      chip = new OrderIdLabelOverlay(new google.maps.LatLng(position.lat, position.lng), orderIds);
      chip.setMap(dayMapInstance);
    }

    if (draggable) {
      marker.addListener('drag', () => {
        if (chip) { chip.position = marker.getPosition(); chip.draw(); }
      });
      marker.addListener('dragend', () => onStopPinDragged(s, marker, chip, position));
    }
  });

  // Per "the driver can view the per day route" - a straight-line path connecting the day's
  // stops in list order, not real driving directions (would need the separately-billed Directions
  // API) - just enough to read as "today's route" the way a delivery app's route line does.
  if (plottedDrops.length > 1) {
    new google.maps.Polyline({
      path: plottedDrops.map(({ stops: [s] }) => ({ lat: Number(s.latitude), lng: Number(s.longitude) })),
      map: dayMapInstance,
      strokeColor: '#1d4f91',
      strokeOpacity: 0.8,
      strokeWeight: 3
    });
  }

  if (isToday) {
    plotDriverMarkers(driverLocations).forEach((position) => bounds.extend(position));
  } else {
    clearDriverMarkers();
  }

  dayMapInstance.fitBounds(bounds);
}

// ---------------------------------------------------------------------------
// Live Driver Tracking - plotted directly onto whichever day map (dayMap or driverRouteMap) is
// currently showing TODAY, rather than a separate map, so dispatchers see the driver's current
// position right alongside today's stops/route. See renderDayMap above, which calls
// fetchDriverLocations/plotDriverMarkers/clearDriverMarkers as part of its own render.

const DRIVER_LOCATION_STALE_MS = 5 * 60 * 1000; // pin's badge turns amber if no ping in 5 minutes

// 'live' (green badge) / 'stale' (amber - tracking on, but no ping in a while) / 'stopped' (grey -
// driver_stop_tracking was called, e.g. the driver logged out). Shared by the badge color and the
// tooltip text below so the two can never disagree with each other.
function driverStatusCategory(loc) {
  if (!loc.is_tracking) return 'stopped';
  const ageMs = Date.now() - new Date(loc.updated_at_utc).getTime();
  return ageMs > DRIVER_LOCATION_STALE_MS ? 'stale' : 'live';
}

const DRIVER_STATUS_BADGE_COLORS = { live: '#22c55e', stale: '#f59e0b', stopped: '#9ca3af' };

function driverLocationStatusText(loc) {
  const category = driverStatusCategory(loc);
  if (category === 'stopped') return 'Stopped';
  if (category === 'stale') {
    const ageMs = Date.now() - new Date(loc.updated_at_utc).getTime();
    return `Last seen ${Math.round(ageMs / 60000)} min ago`;
  }
  return 'Live';
}

async function fetchDriverLocations() {
  const { data, error } = await supabaseClient.rpc('admin_get_driver_locations', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    console.error('admin_get_driver_locations failed:', error);
    return [];
  }

  return data || [];
}

// Fallback truck glyph (white on a portal-blue circle, matching the route polyline's #1d4f91),
// used only if General Setup hasn't uploaded a company logo yet - see loadCompanyLogoUrl. Sized to
// sit inside the same 44x44 badge frame as the logo version below.
const DRIVER_TRUCK_GLYPH_SVG = `
<g transform="translate(9,13)" fill="#ffffff">
  <path d="M0 0h13v9H0z"/>
  <path d="M13 3h4.5l3.5 3.5V9h-8z"/>
  <circle cx="4" cy="12" r="2.3" fill="#1d4f91" stroke="#ffffff" stroke-width="1.3"/>
  <circle cx="16.5" cy="12" r="2.3" fill="#1d4f91" stroke="#ffffff" stroke-width="1.3"/>
</g>`.trim();

// public.CompanyInfo.LogoUrl - same table/column js/companyBranding.js reads for the printable
// letterhead, readable directly via RLS with no RPC/session needed (see that file's header
// comment). Not loaded via companyBranding.js itself since delivery.html doesn't otherwise need
// its DOM-rendering helpers (renderCompanyLetterhead/applyAppBackground) - just this one field.
async function loadCompanyLogoUrl() {
  const { data, error } = await supabaseClient.from('CompanyInfo').select('"LogoUrl"').eq('"Id"', 1).limit(1);
  if (error || !data || data.length === 0) return;
  companyLogoUrl = data[0]['LogoUrl'] || null;
  if (companyLogoUrl) await buildDriverLogoCompositeIcons();
}

// url -> loaded <img>, so a failed/loading image never gets embedded into a Google Maps marker
// icon (which silently shows nothing useful for a broken image reference).
function loadImageElement(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    // Needed so the canvas draw below isn't a "tainted canvas" once toDataURL() is called -
    // requires the image response to allow cross-origin reads, which Supabase Storage's public
    // buckets do by default. If this specific logo URL doesn't, the catch in
    // buildDriverLogoCompositeIcons falls back to the plain truck icon instead of failing loudly.
    img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`Failed to load image: ${url}`));
    img.src = url;
  });
}

// One composited PNG data URL per status color, built once (not per-marker-per-render) and cached
// here - driverMarkerIcon() just looks these up. Drawn on a <canvas> rather than referencing the
// logo via an inline SVG <image href> because a data-URI SVG used as a Maps marker icon is loaded
// in "image context", where browsers block it from fetching any external resource it references -
// the logo would never actually appear. A canvas has no such restriction (once cross-origin
// loading succeeds, see loadImageElement above).
let driverLogoCompositeUrls = null; // { live, stale, stopped } -> data:image/png URL, or null if unbuilt/failed

async function buildDriverLogoCompositeIcons() {
  try {
    const img = await loadImageElement(companyLogoUrl);
    const urls = {};
    for (const category of Object.keys(DRIVER_STATUS_BADGE_COLORS)) {
      urls[category] = renderDriverLogoBadgeCanvas(img, DRIVER_STATUS_BADGE_COLORS[category]);
    }
    driverLogoCompositeUrls = urls;
  } catch (err) {
    console.error('Could not composite the company logo for driver markers - falling back to the truck icon.', err);
    driverLogoCompositeUrls = null;
  }
}

function renderDriverLogoBadgeCanvas(img, badgeColor) {
  const size = 44;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');

  ctx.beginPath();
  ctx.arc(size / 2, size / 2, 19, 0, Math.PI * 2);
  ctx.fillStyle = '#ffffff';
  ctx.fill();

  // Clip to a circle and draw the logo cropped to a square from its center (like CSS
  // object-fit: cover) so non-square logos don't get squashed.
  ctx.save();
  ctx.beginPath();
  ctx.arc(size / 2, size / 2, 18, 0, Math.PI * 2);
  ctx.clip();
  const side = Math.min(img.naturalWidth, img.naturalHeight);
  const sx = (img.naturalWidth - side) / 2;
  const sy = (img.naturalHeight - side) / 2;
  ctx.drawImage(img, sx, sy, side, side, 2, 2, size - 4, size - 4);
  ctx.restore();

  ctx.beginPath();
  ctx.arc(34, 34, 7, 0, Math.PI * 2);
  ctx.fillStyle = badgeColor;
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.strokeStyle = '#ffffff';
  ctx.stroke();

  return canvas.toDataURL('image/png');
}

// Builds the driver pin as one composite icon: the company logo (or the truck glyph, if no logo
// is set, or if the logo failed to load/composite) inside a circular frame, with a small colored
// status dot badged onto the bottom-right corner - green/amber/grey for live/stale/stopped (see
// driverStatusCategory) - so status reads at a glance on the map itself, the way an "online" dot
// reads on a chat avatar, rather than only being available by hovering for the marker's tooltip.
//
// Deferred into a function (rather than a top-level constant) since google.maps.Size/Point don't
// exist until loadGoogleMapsScript() resolves, which happens before this is ever called.
function driverMarkerIcon(loc) {
  const category = driverStatusCategory(loc);

  if (driverLogoCompositeUrls?.[category]) {
    return {
      url: driverLogoCompositeUrls[category],
      scaledSize: new google.maps.Size(44, 44),
      anchor: new google.maps.Point(22, 22)
    };
  }

  const svg = `
<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44" viewBox="0 0 44 44">
  <circle cx="20" cy="20" r="19" fill="#1d4f91" stroke="#ffffff" stroke-width="2"/>
  ${DRIVER_TRUCK_GLYPH_SVG}
  <circle cx="34" cy="34" r="7" fill="${DRIVER_STATUS_BADGE_COLORS[category]}" stroke="#ffffff" stroke-width="2"/>
</svg>`.trim();

  return {
    url: `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`,
    scaledSize: new google.maps.Size(44, 44),
    anchor: new google.maps.Point(22, 22)
  };
}

// Adds/updates one marker per driver on dayMapInstance (creating it if new, moving it in place if
// not - so a Realtime-triggered refresh doesn't recreate markers from scratch every ping) and
// removes markers for drivers no longer returned. Returns the plotted positions so the caller can
// extend its own bounds/fitBounds - this function never calls fitBounds itself, since it's also
// used for live updates where re-fitting/re-zooming on every ping would be jarring.
function plotDriverMarkers(locations) {
  const seenUsernames = new Set();
  const positions = [];

  locations.forEach((loc) => {
    seenUsernames.add(loc.username);
    const position = { lat: Number(loc.latitude), lng: Number(loc.longitude) };
    positions.push(position);

    const title = `${loc.display_name || loc.username} (Driver) - ${driverLocationStatusText(loc)}`;
    // Re-built on every call (not just marker creation) since the status badge can change - e.g.
    // a driver going from "live" to "stale" - purely from time passing, with no new location row
    // to trigger a normal update. See the periodic refreshDriverMarkers() call in init() below.
    const icon = driverMarkerIcon(loc);

    let marker = driverMarkers[loc.username];
    if (!marker) {
      marker = new google.maps.Marker({ position, map: dayMapInstance, title, icon, zIndex: 999 });
      driverMarkers[loc.username] = marker;
    } else {
      marker.setMap(dayMapInstance);
      marker.setPosition(position);
      marker.setTitle(title);
      marker.setIcon(icon);
    }
  });

  Object.keys(driverMarkers).forEach((username) => {
    if (!seenUsernames.has(username)) {
      driverMarkers[username].setMap(null);
      delete driverMarkers[username];
    }
  });

  return positions;
}

function clearDriverMarkers() {
  Object.values(driverMarkers).forEach((m) => m.setMap(null));
  driverMarkers = {};
}

// Re-invoked on every Realtime change to DriverLocations - just moves the existing pin(s) on
// whichever day map is currently showing TODAY, without re-running the full renderDayMap (which
// also re-fetches warehouse/vendor markers - unnecessary just to move a driver).
async function refreshDriverMarkers() {
  if (!dayMapInstance || dayMapDateKey !== toDateKey(new Date())) return;
  plotDriverMarkers(await fetchDriverLocations());
}

// A driver going quiet mid-route (phone died, lost signal, OEM killed the background service)
// never produces a DriverLocations row change - nothing would otherwise re-render their badge
// from green to amber. This periodic sweep is what catches that, purely from time passing.
function startDriverMarkerStaleCheck() {
  setInterval(refreshDriverMarkers, 60000);
}

// First use of Supabase Realtime postgres_changes in this codebase (chat.js uses Broadcast
// channels instead) - DriverLocations has its own permissive RLS select policy specifically so
// this subscription can see row changes; see supabase_driver_locations_table.sql. Subscribed once
// at page init (not gated behind any toggle) so a day map already open for today updates live.
function subscribeToDriverLocations() {
  if (driverLocationsChannel) return;

  driverLocationsChannel = supabaseClient
    .channel('driver-locations')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'DriverLocations' }, () => {
      refreshDriverMarkers();
    })
    .subscribe();

  window.addEventListener('beforeunload', () => {
    supabaseClient.removeChannel(driverLocationsChannel);
  });
}

async function removeStop(stopId, dateKey) {
  const { error } = await supabaseClient.rpc('admin_delete_delivery_stop', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_stop_id: stopId
  });

  if (error) {
    console.error('admin_delete_delivery_stop failed:', error);
    return;
  }

  await renderMonth(currentYear, currentMonth);
  showDayDetail(dateKey);
}

function renderAssignOrdersTable(orders) {
  const tbody = document.getElementById('assignOrdersTableBody');

  // Cached here (rather than re-fetched after assignment) because admin_list_deliverable_
  // online_orders only returns orders with no delivery stop yet - by the time confirmAssign()
  // needs this order's shipping_address for geocoding, admin_create_delivery_stop has already
  // created one, so a fresh lookup would come back empty.
  // Keyed by source + id - an advance order's TransactionNo can be the same number as an online
  // OrderID (supabase_delivery_advance_and_walkin_orders.sql lists both).
  assignOrdersByOrderId = new Map((orders || []).map((o) => [assignOrderKey(o), o]));

  if (!orders || orders.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No deliverable orders found.</td></tr>';
    return;
  }

  // No-address orders are flagged here too (not just at confirmAssign's prompt) so staff can
  // spot them before picking one, per "in the assign Order to Delivery can you show the address
  // too". A "Walkin" address is Pancake's own placeholder text, not a real one - flagged the same
  // way (isPlaceholderAddress) so it reads as missing here too, rather than as an actual address.
  tbody.innerHTML = orders.map((o) => `
    <tr>
      <td><input type="radio" name="assignOrderRadio" value="${assignOrderKey(o)}" /></td>
      <td>${assignOrderLabel(o)}</td>
      <td>${o.customer_name || ''}</td>
      <td>${o.status || ''}</td>
      <td>${isPlaceholderAddress(o.shipping_address) ? '<span class="muted">No address</span>' : o.shipping_address}</td>
      <td>${o.source === 'advance' ? 'Advance' : o.source === 'automated' ? 'Order Form' : (o.is_walk_in || isWalkInPlaceholderOrder(o) ? 'Walk-in' : 'Online')}</td>
    </tr>
  `).join('');

  tbody.querySelectorAll('input[name="assignOrderRadio"]').forEach((radio) => {
    radio.addEventListener('change', () => {
      selectedOrderId = radio.value;
      updateConfirmAssignButtonState();
    });
  });
}

// Re-evaluated whenever the selected order or delivery date changes - keeps "Assign to Selected
// Date" disabled (with an explanation) whenever the chosen date is a Monday, regardless of
// whether the modal was opened from the toolbar or prefilled from a Monday's day-detail panel.
function updateConfirmAssignButtonState() {
  const dateKey = document.getElementById('assignDateInput').value;
  const errorEl = document.getElementById('assignError');
  const confirmBtn = document.getElementById('confirmAssignBtn');

  if (isBlockedDeliveryDateKey(dateKey)) {
    errorEl.textContent = DAY_OFF_MESSAGE;
    errorEl.classList.remove('hidden');
    confirmBtn.disabled = true;
    return;
  }

  errorEl.classList.add('hidden');
  confirmBtn.disabled = !selectedOrderId;
}

async function loadAssignOrders() {
  const { data, error } = await supabaseClient.rpc('admin_list_deliverable_online_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: assignSearch || null,
    p_page: assignPage,
    p_page_size: assignPageSize,
    p_sort_column: assignSortColumn,
    p_sort_dir: assignSortDir
  });

  updateAssignSortIndicators();

  if (error) {
    document.getElementById('assignOrdersTableBody').innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderAssignOrdersTable(data);

  renderPaginationBar(
    document.getElementById('assignOrdersPaginationBar'),
    { page: assignPage, pageSize: assignPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { assignPage = newPage; loadAssignOrders(); },
      onPageSizeChange: (newSize) => { assignPageSize = newSize; assignPage = 1; loadAssignOrders(); }
    }
  );
}

function updateAssignSortIndicators() {
  document.querySelectorAll('.assign-sort-th').forEach((th) => {
    th.querySelector('.sort-indicator').textContent =
      th.dataset.sort === assignSortColumn ? (assignSortDir === 'asc' ? ' ▲' : ' ▼') : '';
  });
}

// Click a header to sort by it, click again to reverse - back to page 1 since the order changed.
function wireAssignSortHeaders() {
  document.querySelectorAll('.assign-sort-th').forEach((th) => {
    th.addEventListener('click', () => {
      const column = th.dataset.sort;
      assignSortDir = assignSortColumn === column && assignSortDir === 'asc' ? 'desc' : 'asc';
      assignSortColumn = column;
      assignPage = 1;
      loadAssignOrders();
    });
  });
}

function openAssignModal(prefilledDate) {
  selectedOrderId = null;
  document.getElementById('assignError').classList.add('hidden');
  document.getElementById('assignSearchInput').value = '';
  assignSearch = '';
  assignPage = 1;
  document.getElementById('assignDateInput').value = prefilledDate || toDateKey(new Date());
  document.getElementById('assignModal').classList.remove('hidden');
  updateConfirmAssignButtonState();
  loadAssignOrders();
}

function closeAssignModal() {
  document.getElementById('assignModal').classList.add('hidden');
}

// details is { customerName, phone, notes } - only ever passed with real values from
// confirmAssign() for a walk-in placeholder order (see isWalkInPlaceholderOrder) or from
// openFixStopDetails' edit flow. Every other caller (a plain missing-address prompt, the
// "Retry Map" button) omits it, and admin_update_delivery_stop_geocode leaves whatever is already
// stored untouched whenever a field comes in null, so those calls can never blank out a name/
// phone/note entered earlier.
//
// Returns true on success, false if the save itself failed - callers that matter to the user
// (confirmAssign, openFixStopDetails) surface that rather than letting it fail silently. Earlier
// versions of this function ignored the RPC's own {error} entirely, so a bad call here (wrong
// argument name, an ambiguous overload, a schema-cache that hadn't picked up a just-run migration
// yet) looked identical to success: the stop existed, nothing on screen said otherwise, and the
// manual details just never appeared. Per "it never fill in the stops address and customer".
// setManualAddress: true only from openFixStopDetails ("Edit Details" - a staff member actually
// typed this address). Left false for the routine auto-geocode at stop creation and for "Retry
// Map" (both just re-geocode whatever address is already showing, not a new manual entry) - see
// supabase_delivery_stop_manual_address.sql for why that distinction matters (a real Pancake
// address can still legitimately change later; a manual override should only freeze it once
// someone has actually corrected it by hand).
//
// pinnedLocation ({lat, lng}) - a Super User placed the pin by hand (Edit Details' map, or dragging
// the stop's pin on the day map - see setupPinPicker/onStopPinDragged). Saved as-is instead of
// geocoding the address text, which would snap it back to wherever Google thinks the text is.
async function geocodeAndSaveStop(stopId, address, details = null, { setManualAddress = false, pinnedLocation = null } = {}) {
  if (pinnedLocation) {
    const label = (address || '').trim() || `Pinned location (${pinnedLocation.lat.toFixed(6)}, ${pinnedLocation.lng.toFixed(6)})`;
    const { error } = await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_stop_id: stopId,
      p_geocoded_address: label,
      p_latitude: pinnedLocation.lat,
      p_longitude: pinnedLocation.lng,
      p_geocode_status: 'ok',
      p_customer_name: details?.customerName || null,
      p_contact_number: details?.phone || null,
      p_notes: details?.notes || null,
      p_note_print: details?.notePrint || null,
      p_set_manual_address: true,
      ...(details?.deliveryFee !== null && details?.deliveryFee !== undefined ? { p_delivery_fee: details.deliveryFee } : {})
    });
    if (error) {
      console.error('admin_update_delivery_stop_geocode failed:', error);
      window.alert(`Saving the new address / pin failed: ${error.message}`);
      return false;
    }
    return true;
  }

  const customerName = details?.customerName || null;
  const phone = details?.phone || null;
  const notes = details?.notes || null;
  const notePrint = details?.notePrint || null;
  // Manual delivery fee (supabase_delivery_stop_manual_fee.sql) - only sent when one was typed, so a
  // plain save still works before that SQL is run.
  const feeParam = details?.deliveryFee !== null && details?.deliveryFee !== undefined
    ? { p_delivery_fee: details.deliveryFee }
    : {};

  if (!address || !address.trim()) {
    const { error } = await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_stop_id: stopId,
      p_geocoded_address: null,
      p_latitude: null,
      p_longitude: null,
      p_geocode_status: 'failed',
      p_customer_name: customerName,
      p_contact_number: phone,
      p_notes: notes,
      p_note_print: notePrint,
      p_set_manual_address: setManualAddress,
      ...feeParam
    });
    if (error) {
      console.error('admin_update_delivery_stop_geocode failed:', error);
      window.alert(`The stop was created, but saving its manual details failed: ${error.message}. Use "Edit Details" on this stop to try again.`);
      return false;
    }
    return true;
  }

  try {
    await loadGoogleMapsScript();
    const geocoder = new google.maps.Geocoder();
    const result = await new Promise((resolve) => {
      geocoder.geocode({ address }, (results, status) => {
        if (status === 'OK' && results && results[0]) {
          resolve(results[0]);
        } else {
          resolve(null);
        }
      });
    });

    const { error } = result
      ? await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_stop_id: stopId,
          p_geocoded_address: address,
          p_latitude: result.geometry.location.lat(),
          p_longitude: result.geometry.location.lng(),
          p_geocode_status: 'ok',
          p_customer_name: customerName,
          p_contact_number: phone,
          p_notes: notes,
          p_note_print: notePrint,
          p_set_manual_address: setManualAddress,
          ...feeParam
        })
      : await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_stop_id: stopId,
          p_geocoded_address: address,
          p_latitude: null,
          p_longitude: null,
          p_geocode_status: 'failed',
          p_customer_name: customerName,
          p_contact_number: phone,
          p_notes: notes,
          p_note_print: notePrint,
          p_set_manual_address: setManualAddress,
          ...feeParam
        });

    if (error) {
      console.error('admin_update_delivery_stop_geocode failed:', error);
      window.alert(`The stop was created, but saving its manual details failed: ${error.message}. Use "Edit Details" on this stop to try again.`);
      return false;
    }
    return true;
  } catch (err) {
    console.error('Geocoding failed:', err);
    window.alert(`The stop was created, but plotting its address failed: ${err.message || err}. Use "Edit Details" or "Retry Map" on this stop to try again.`);
    return false;
  }
}

// Portal-styled replacement for window.confirm()/window.prompt() when the selected order has no
// shipping address, or is a walk-in placeholder needing a name/contact number/note too
// (isWalkInPlaceholderOrder) - resolves to { address, customerName, phone, notes } (any of which
// can be null if left blank) if the user clicks Continue, or `undefined` if they cancel.
// noAddressResolve is a module-level handle so the Cancel/Continue buttons (wired once in
// wireToolbarAndModal) can settle whichever promise is currently pending.
let noAddressResolve = null;

// Super User map pin on the Edit Details modal (#noAddressPinRow) - per "let the super user change
// the address of the order by typing the address or moving the pin". pinPickerMoved is only set
// once the pin is placed by hand (drag / map click / "Find typed address on map"), so a plain
// text-only edit still geocodes the typed address the way it always did.
let pinPickerMarker = null;
let pinPickerMoved = false;
// How the pin got where it is: 'hand' (dragged / map click - never overridden) or 'find' (geocoded
// from pinFoundForAddress). "Calculate fee" re-finds a non-hand pin whenever the typed address differs.
let pinPickerSource = null;
let pinFoundForAddress = null;
const PIN_PICKER_DEFAULT_CENTER = { lat: 14.5995, lng: 120.9842 }; // Metro Manila, when the stop has no pin yet

function reverseGeocode(position) {
  return new Promise((resolve) => {
    new google.maps.Geocoder().geocode({ location: position }, (results, status) => {
      resolve(status === 'OK' && results && results[0] ? results[0].formatted_address : null);
    });
  });
}

function setPinPickerStatus(text) {
  document.getElementById('noAddressPinStatus').textContent = text;
}

// Pin dropped by hand: remember it, and fill the address box with Google's address for that spot
// (still editable - e.g. to add a unit no. or landmark - the pin itself is what gets saved).
async function onPinPickerPlaced(latLng) {
  pinPickerMarker.setPosition(latLng);
  pinPickerMoved = true;
  pinPickerSource = 'hand';
  invalidateFeeQuote();
  setPinPickerStatus('Looking up address...');
  const address = await reverseGeocode(latLng);
  if (address) document.getElementById('noAddressInput').value = address;
  setPinPickerStatus('Pin moved - this exact spot will be saved.');
}

// pinPicker: { position: {lat, lng} | null, moved: bool } - moved=true when opened from a pin
// already dragged on the day map, so Save keeps that spot.
async function setupPinPicker(pinPicker) {
  pinPickerMarker = null;
  pinPickerMoved = false;
  pinPickerSource = null;
  // The stop's saved pin already matches its saved address - no re-find until the text changes.
  pinFoundForAddress = pinPicker.position ? feeQuoteContext.prefillAddress : null;
  setPinPickerStatus('');
  try {
    await loadGoogleMapsScript();
  } catch (err) {
    document.getElementById('noAddressPinMap').textContent = err.message;
    return;
  }
  const start = pinPicker.position || PIN_PICKER_DEFAULT_CENTER;
  const map = new google.maps.Map(document.getElementById('noAddressPinMap'), {
    center: start,
    zoom: pinPicker.position ? 16 : 11,
    mapTypeControl: false,
    streetViewControl: false
  });
  pinPickerMarker = new google.maps.Marker({ position: start, map, draggable: true });
  pinPickerMarker.addListener('dragend', (e) => onPinPickerPlaced(e.latLng));
  map.addListener('click', (e) => onPinPickerPlaced(e.latLng));

  if (pinPicker.moved) {
    pinPickerMoved = true;
    pinPickerSource = 'hand';
    setPinPickerStatus('Pin moved - this exact spot will be saved.');
  } else if (!pinPicker.position) {
    setPinPickerStatus('No pin yet - drag it or click the map, or use "Find typed address on map".');
  }
}

// Returns true once the pin is on the typed address (also run automatically by "Calculate fee").
async function findTypedAddressOnPinMap() {
  const address = document.getElementById('noAddressInput').value.trim();
  if (!address || !pinPickerMarker) return false;
  setPinPickerStatus('Searching...');
  const result = await new Promise((resolve) => {
    new google.maps.Geocoder().geocode({ address }, (results, status) => {
      resolve(status === 'OK' && results && results[0] ? results[0] : null);
    });
  });
  if (!result) {
    setPinPickerStatus("Couldn't find that address - drag the pin to the spot instead.");
    return false;
  }
  pinPickerMarker.setPosition(result.geometry.location);
  pinPickerMarker.getMap().setCenter(result.geometry.location);
  pinPickerMarker.getMap().setZoom(17);
  pinPickerMoved = true;
  pinPickerSource = 'find';
  pinFoundForAddress = address;
  invalidateFeeQuote();
  setPinPickerStatus('Pin moved to the typed address - drag it to fine-tune.');
  return true;
}

// "Calculate fee" on the modal - per "on actual adding the delivery fee can we use the delivery quote?
// ... calculate the fee base on the address they input and fill in the delivery fee automatically..
// dont allow the user to edit the delivery fee" and "the origin should be base on the warehouse
// location .. dont allow the user to edit this delivery fee and delivery from". The fee box is
// read-only and this is the only way to fill it. The branch the truck leaves from is the order's own
// warehouse (admin_get_order_delivery_branch, supabase_delivery_order_branch.sql) - shown, never picked.
// Priced by the delivery-fee-from-pin Edge Function - the same official formula (base fee + per km +
// toll) as Conversations' quote window and Alice. Quotes to the hand-placed pin if there is one, else
// the stop's saved pin while the address is unchanged, else the typed address.
let feeQuoteContext = { prefillAddress: '', prefillFee: '', stopPin: null, branchOrder: null, branch: undefined, quoted: false, seq: 0 };

function setFeeQuoteStatus(html) {
  document.getElementById('noAddressFeeQuoteStatus').innerHTML = html;
}

// Address / pin changed after a quote - the quoted fee no longer matches, so put the box back.
function invalidateFeeQuote() {
  if (!feeQuoteContext.quoted) return;
  feeQuoteContext.quoted = false;
  feeQuoteContext.seq++;
  document.getElementById('noAddressDeliveryFeeInput').value = feeQuoteContext.prefillFee;
  setFeeQuoteStatus('Address changed - click <strong>Calculate fee</strong> again.');
}

// 'GMA' / 'Amaya' from the order's warehouse, looked up once per modal open; null = unknown.
async function resolveFeeBranch() {
  if (feeQuoteContext.branch !== undefined) return feeQuoteContext.branch;
  const order = feeQuoteContext.branchOrder;
  if (!order?.orderId) return null;
  const { data, error } = await supabaseClient.rpc('admin_get_order_delivery_branch', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(order.orderId),
    p_source: order.source || 'online'
  });
  if (error) throw new Error(`couldn't look up the order's warehouse: ${error.message}`);
  feeQuoteContext.branch = data || null;
  return feeQuoteContext.branch;
}

async function calculateDeliveryFeeQuote() {
  const address = document.getElementById('noAddressInput').value.trim();
  // Per "once the calculate fee is clicked.. automate the find type address on map" - with the map pin
  // showing (Super User), a typed address the pin isn't on yet is found on the map first, so the fee is
  // measured to (and Save keeps) that spot. A pin placed by hand is never moved.
  if (pinPickerMarker && pinPickerSource !== 'hand' && address.length >= 5 && address !== pinFoundForAddress) {
    const found = await findTypedAddressOnPinMap();
    if (!found) {
      setFeeQuoteStatus('<span class="error-text">Couldn\'t find that address on the map - make it more specific, or drag the pin to the spot.</span>');
      return;
    }
  }
  let pin = null;
  if (pinPickerMoved && pinPickerMarker) {
    pin = { lat: pinPickerMarker.getPosition().lat(), lng: pinPickerMarker.getPosition().lng() };
  } else if (feeQuoteContext.stopPin && address === feeQuoteContext.prefillAddress) {
    pin = feeQuoteContext.stopPin;
  }
  if (!pin && address.length < 5) {
    setFeeQuoteStatus('<span class="error-text">Type the full delivery address first (street, barangay, city).</span>');
    return;
  }

  const seq = ++feeQuoteContext.seq;
  const btn = document.getElementById('noAddressCalcFeeBtn');
  btn.disabled = true;
  setFeeQuoteStatus('Calculating...');
  try {
    const branch = await resolveFeeBranch();
    if (seq !== feeQuoteContext.seq) return;
    document.getElementById('noAddressFeeBranch').textContent = branch ? `From ${branch}` : '';
    if (!branch) throw new Error('this order has no GMA / Amaya warehouse on file - set the order\'s warehouse first.');

    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-fee-from-pin`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        address,
        branches: [branch],
        ...(pin ? { latitude: pin.lat, longitude: pin.lng } : {})
      })
    });
    const body = await response.json().catch(() => null);
    if (seq !== feeQuoteContext.seq) return; // address changed / newer quote since
    if (!response.ok || !body?.quotes) {
      const reason = response.status === 403
        ? 'your account can\'t calculate delivery fees (Super User / Conversations Access only)'
        : (body?.error || `Request failed (${response.status}).`);
      throw new Error(reason);
    }
    const q = body.quotes[branch];
    if (!q || q.error || q.estimatedFee == null) throw new Error(q?.error || `no quote from ${branch}.`);
    document.getElementById('noAddressDeliveryFeeInput').value = Number(q.estimatedFee).toFixed(2);
    feeQuoteContext.quoted = true;
    setFeeQuoteStatus(`From ${branch} (order's warehouse): ₱${Number(q.estimatedFee).toLocaleString('en-PH')} &middot; ${q.distanceKm} km`);
  } catch (err) {
    if (seq === feeQuoteContext.seq) setFeeQuoteStatus(`<span class="error-text">Could not calculate the fee: ${err.message}</span>`);
  } finally {
    if (seq === feeQuoteContext.seq) btn.disabled = false;
  }
}

// title/message/prefill* let openFixStopDetails (below) reuse this same modal as a general "edit
// an existing stop's details" tool, with its own wording and the values it already has typed in
// rather than blank boxes. pinPicker (Super User + Edit Details only) shows the map pin - see
// setupPinPicker. stopPin = the stop's saved pin, for "Calculate fee" (see calculateDeliveryFeeQuote).
function openNoAddressModal(orderId, { askDetails = false, title, message, prefillAddress = '', prefillName = '', prefillPhone = '', prefillNotes = '', prefillNotePrint = '', prefillDeliveryFee = '', orderDeliveryFee = null, pinPicker = null, stopPin = null, branchOrder = null } = {}) {
  const feeInput = document.getElementById('noAddressDeliveryFeeInput');
  feeInput.value = prefillDeliveryFee === null || prefillDeliveryFee === undefined ? '' : prefillDeliveryFee;
  feeQuoteContext = { prefillAddress: (prefillAddress || '').trim(), prefillFee: feeInput.value, stopPin, branchOrder, branch: undefined, quoted: false, seq: feeQuoteContext.seq + 1 };
  document.getElementById('noAddressFeeBranch').textContent = '';
  document.getElementById('noAddressCalcFeeBtn').disabled = false;
  setFeeQuoteStatus('');
  // Shows the order's own fee as the hint, so it's clear what blank keeps.
  feeInput.placeholder = orderDeliveryFee !== null && orderDeliveryFee !== undefined && orderDeliveryFee !== ''
    ? `Blank = keep the order's fee (${Number(orderDeliveryFee).toFixed(2)})`
    : "Blank = keep the order's fee";
  document.getElementById('noAddressOrderId').textContent = orderId;
  document.getElementById('noAddressInput').value = prefillAddress || '';
  document.getElementById('noAddressNameInput').value = prefillName || '';
  document.getElementById('noAddressPhoneInput').value = prefillPhone || '';
  document.getElementById('noAddressNotesInput').value = prefillNotes || '';
  document.getElementById('noAddressNotePrintInput').value = prefillNotePrint || '';
  document.querySelectorAll('.walkin-extra-row').forEach((row) => row.classList.toggle('hidden', !askDetails));

  // The walk-in wording explains WHY these extra fields are being asked for (Pancake's own
  // generic placeholder, not this order's real customer) - the plain missing-address prompt keeps
  // its original text unchanged, since that path existed before walk-in orders were a
  // consideration.
  document.getElementById('noAddressTitle').textContent = title || (askDetails
    ? 'Walk-in Order - Delivery Details'
    : 'No Delivery Address');
  document.getElementById('noAddressMessage').innerHTML = message || (askDetails
    ? `Order <strong>${orderId}</strong> is logged under Pancake's generic "POS WALKIN ORDERS" customer with no real address on file. Who is this delivery actually for, and where is it going?`
    : `Order <strong>${orderId}</strong> has no shipping address on file. Enter one below to plot it on the map, or leave it blank to continue without one.`);
  document.getElementById('noAddressModal').classList.remove('hidden');
  // Shown (and the map built) only after the modal is visible, so Google Maps sizes it correctly.
  document.getElementById('noAddressPinRow').classList.toggle('hidden', !pinPicker);
  pinPickerMarker = null;
  pinPickerMoved = false;
  pinPickerSource = null;
  if (pinPicker) setupPinPicker(pinPicker);
  document.getElementById(askDetails ? 'noAddressNameInput' : 'noAddressInput').focus();

  return new Promise((resolve) => { noAddressResolve = resolve; });
}

function closeNoAddressModal(proceed) {
  const address = document.getElementById('noAddressInput').value.trim();
  const customerName = document.getElementById('noAddressNameInput').value.trim();
  const phone = document.getElementById('noAddressPhoneInput').value.trim();
  const notes = document.getElementById('noAddressNotesInput').value.trim();
  const notePrint = document.getElementById('noAddressNotePrintInput').value.trim();
  // Commas / peso sign / spaces are stripped ("1,500", "₱ 500"). Anything still unreadable stops the
  // save with a message instead of quietly counting as "blank = keep" - that silent drop is what made
  // a typed fee look like it never saved.
  const feeText = document.getElementById('noAddressDeliveryFeeInput').value.replace(/[,\s₱]|php/gi, '');
  const deliveryFee = feeText === '' ? null : Number(feeText);
  if (proceed && deliveryFee !== null && (!Number.isFinite(deliveryFee) || deliveryFee < 0)) {
    window.alert(`"${document.getElementById('noAddressDeliveryFeeInput').value}" isn't a valid delivery fee. Click Calculate fee again.`);
    document.getElementById('noAddressDeliveryFeeInput').focus();
    return;
  }
  document.getElementById('noAddressModal').classList.add('hidden');

  if (noAddressResolve) {
    noAddressResolve(proceed
      ? {
          address: address || null, customerName: customerName || null, phone: phone || null, notes: notes || null, notePrint: notePrint || null, deliveryFee,
          pinnedLocation: pinPickerMoved && pinPickerMarker
            ? { lat: pinPickerMarker.getPosition().lat(), lng: pinPickerMarker.getPosition().lng() }
            : null
        }
      : undefined);
    noAddressResolve = null;
  }
}

// Fixes an ALREADY-CREATED stop's manual details, per "it never fill in the stops address and
// customer" - confirmAssign()'s prompt only ever fires once, at the moment a stop is created, so
// until now there was no way back in if it was skipped, mistyped, or (per the error handling just
// added to geocodeAndSaveStop) silently failed to save. Available on every stop, not just a
// walk-in placeholder - the same gap applies to any stop whose details need correcting later.
//
// Prefills with whatever is on the stop already, so this reads as "edit" rather than "start over" -
// the manually-entered address (isPlaceholderAddress covers a stop that still shows the raw
// "Walkin" text because nothing has been saved for it yet), the current customer_name (already
// resolved to the manual one if admin_list_delivery_stops has one on file), and the stop's own
// contact_number/notes.
//
// droppedPin ({ position: {lat, lng}, address }) - set when a Super User dragged this stop's pin on
// the day map (onStopPinDragged): opens with the pin already at the new spot and the address box
// prefilled from Google's reverse geocode, so they confirm/tweak before anything is saved.
// Returns true once saved, false if cancelled or the save failed.
async function openFixStopDetails(stop, droppedPin = null) {
  const currentAddress = isPlaceholderAddress(stop.shipping_address) ? (stop.geocoded_address || '') : stop.shipping_address;
  const hasPin = stop.geocode_status === 'ok' && stop.latitude && stop.longitude;
  const pinPicker = !currentSession.isSuperUser ? null : droppedPin
    ? { position: droppedPin.position, moved: true }
    : { position: hasPin ? { lat: Number(stop.latitude), lng: Number(stop.longitude) } : null, moved: false };
  const manualDetails = await openNoAddressModal(stop.order_id, {
    askDetails: true,
    title: 'Edit Delivery Details',
    message: droppedPin
      ? `Move order <strong>${stop.order_id}</strong> to the new pin? The address below was looked up from where you dropped it - edit it if needed (e.g. add a unit no. or landmark), then Continue. This also updates the order in the portal; nothing is changed in Pancake.`
      : `Update the delivery details shown for order <strong>${stop.order_id}</strong>. A changed address, contact number or fee also updates the order in the portal. Nothing is changed in Pancake.`
        + (stop.fee_combined_with ? `<br><br>This order is in a <strong>combined delivery</strong> charged once - its fee rides on <strong>${escapeHtmlText(stop.fee_combined_with)}</strong>. A fee typed here goes to the drop (the biggest fee is kept); to charge it separately, switch the drop to "Charge per order".` : ''),
    prefillAddress: droppedPin ? (droppedPin.address || currentAddress || '') : (currentAddress || ''),
    pinPicker,
    stopPin: hasPin ? { lat: Number(stop.latitude), lng: Number(stop.longitude) } : null,
    branchOrder: { orderId: stop.order_id, source: stop.source },
    prefillName: stop.customer_name || '',
    prefillPhone: stop.contact_number || '',
    prefillNotes: stop.notes || '',
    prefillNotePrint: stop.note_print || '',
    // Only a fee typed here before is prefilled - the order's own fee shows as the hint instead, so
    // saving without touching the box doesn't freeze the Pancake fee as a manual one.
    prefillDeliveryFee: stop.is_manual_delivery_fee ? stop.delivery_fee : '',
    orderDeliveryFee: stop.is_manual_delivery_fee ? null : stop.delivery_fee
  });
  if (manualDetails === undefined) return false; // cancelled

  const saved = await geocodeAndSaveStop(stop.stop_id, manualDetails.address, manualDetails, {
    setManualAddress: true,
    pinnedLocation: manualDetails.pinnedLocation
  });
  if (!saved) return false; // geocodeAndSaveStop already alerted why

  await syncOrderFromStop(stop, manualDetails, currentAddress);

  await renderMonth(currentYear, currentMonth);
  showDayDetail(selectedDateKey);
  return true;
}

// Per "if i change the delivery fee on the calendar.. will it change the delivery fee on the order
// itself?" and "can we apply that to the Address too? add a new field Shipping address, Shipping
// contact number" - a changed address / contact number / typed fee in Edit Details also updates a
// portal (AO-) order (admin_set_portal_order_shipping_details / admin_set_portal_order_delivery_fee,
// supabase_online_order_shipping_details_sync.sql - the server re-checks delivery order, still open).
// Per "if an order id is detected in the portal.. change the details to the portal directly no need to
// change the pancake" this now covers Pancake orders too: the portal's copy of the order is updated and
// kept over every Pancake sync (that file's step 0); nothing is sent to Pancake. The stop itself is
// already saved either way.
async function syncOrderFromStop(stop, details, previousAddress) {
  if (stop.source === 'advance' || stop.source === 'automated') return;
  const orderId = String(stop.order_id || '');
  // Blank boxes mean "keep" (same as the stop save) - not "erase it on the order".
  const address = details.address || previousAddress || '';
  const phone = details.phone || stop.contact_number || '';
  const shippingChanged = address !== (previousAddress || '') || phone !== (stop.contact_number || '');
  const feeChanged = details.deliveryFee !== null;
  if (!shippingChanged && !feeChanged) return;

  if (!orderId) return;

  const failures = [];
  const reasonOf = (error) => (/not authorized/i.test(error.message)
    ? 'your account can\'t edit orders (Super User / Conversations Access only)'
    : error.message);
  if (shippingChanged) {
    const { error } = await supabaseClient.rpc('admin_set_portal_order_shipping_details', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_shipping_address: address,
      p_shipping_phone: phone,
      p_from_stop_id: stop.stop_id
    });
    if (error) { console.error('admin_set_portal_order_shipping_details failed:', error); failures.push(`address / contact number: ${reasonOf(error)}`); }
  }
  if (feeChanged) {
    const { error } = await supabaseClient.rpc('admin_set_portal_order_delivery_fee', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_delivery_fee: details.deliveryFee
    });
    if (error) { console.error('admin_set_portal_order_delivery_fee failed:', error); failures.push(`delivery fee: ${reasonOf(error)}`); }
  }
  if (failures.length) {
    window.alert(`Saved for this delivery stop, but order ${orderId} itself was NOT updated -\n${failures.join('\n')}`);
  }
}

// Super User dragged an order's pin on the day map - reverse-geocode the drop spot and hand off to
// Edit Details to confirm. Cancel (or a failed save) snaps the pin and its order-id chip back.
async function onStopPinDragged(stop, marker, chip, originalPosition) {
  const position = { lat: marker.getPosition().lat(), lng: marker.getPosition().lng() };
  const address = await reverseGeocode(position);
  const saved = await openFixStopDetails(stop, { position, address });
  if (!saved) {
    marker.setPosition(originalPosition);
    if (chip) { chip.position = new google.maps.LatLng(originalPosition.lat, originalPosition.lng); chip.draw(); }
  }
}

async function confirmAssign() {
  const errorEl = document.getElementById('assignError');
  errorEl.classList.add('hidden');

  const deliveryDate = document.getElementById('assignDateInput').value;
  if (!selectedOrderId || !deliveryDate) {
    errorEl.textContent = 'Pick an order and a delivery date.';
    errorEl.classList.remove('hidden');
    return;
  }

  if (isBlockedDeliveryDateKey(deliveryDate)) {
    errorEl.textContent = DAY_OFF_MESSAGE;
    errorEl.classList.remove('hidden');
    return;
  }

  // Per "show confirmation if the order ID has no address... if still they want to proceed can
  // we ask the user to fill in the address manually" - checked BEFORE creating the stop, so
  // Cancel aborts the whole assignment rather than leaving an unaddressed stop behind. The
  // manually-typed address (if any) is only used to geocode/plot this stop - it does not write
  // back to OnlineOrders.ShippingAddress (a Pancake-synced field), so a manual entry here can't
  // get silently overwritten or drift from what Pancake has on file.
  //
  // A walk-in placeholder order (isWalkInPlaceholderOrder) gets the same prompt PLUS Customer
  // Name/Contact Number/Delivery Instructions fields, per "if the customer is POS WALKIN ORDERS and
  // Address is Walkin can you ask the user for Address and Name of customer once its assigned",
  // "can you fill in notes too together with Name and Address" and "also add the contact number" -
  // "Walkin" isn't a real address either, so it is treated the same as a genuinely missing one
  // (isPlaceholderAddress).
  const matchedOrder = assignOrdersByOrderId.get(selectedOrderId);
  let addressForGeocode = matchedOrder ? matchedOrder.shipping_address : null;
  let detailsForStop = null;

  // Advance orders have no address / phone on file at all, so they always get the full details
  // prompt (prefilled with the advance order's customer name).
  const isAdvance = matchedOrder?.source === 'advance';
  const needsWalkInDetails = isAdvance || isWalkInPlaceholderOrder(matchedOrder);
  // Tracks whether addressForGeocode ends up being something a staff member actually typed (via
  // the prompt below) rather than Pancake's own ShippingAddress - passed through to
  // geocodeAndSaveStop as setManualAddress so a genuinely manual address sticks as an override
  // (supabase_delivery_stop_manual_address.sql), the same as an "Edit Details" edit would.
  const manuallyEnteredAddress = needsWalkInDetails || isPlaceholderAddress(addressForGeocode);
  if (manuallyEnteredAddress) {
    // Prefill whatever is already known - the walk-in name / phone typed on Online Orders, or the
    // advance order's customer - but not Pancake's generic walk-in placeholders.
    const knownName = (matchedOrder?.customer_name || '').trim();
    const knownPhone = (matchedOrder?.contact_number || '').trim();
    const manualDetails = await openNoAddressModal(matchedOrder ? assignOrderLabel(matchedOrder) : selectedOrderId, {
      askDetails: needsWalkInDetails,
      title: isAdvance ? 'Advance Order - Delivery Details' : undefined,
      message: isAdvance
        ? `Advance order <strong>${assignOrderLabel(matchedOrder)}</strong> has no delivery address on file. Where is it going, and who should the driver contact?`
        : undefined,
      prefillName: knownName.toLowerCase() === 'pos walkin orders' ? '' : knownName,
      prefillPhone: knownPhone === '11111' ? '' : knownPhone,
      branchOrder: { orderId: matchedOrder ? matchedOrder.order_id : selectedOrderId, source: matchedOrder?.source || 'online' }
    });
    if (manualDetails === undefined) return; // cancelled
    addressForGeocode = manualDetails.address;
    detailsForStop = manualDetails;
  }

  const { data: stopId, error } = await supabaseClient.rpc('admin_create_delivery_stop', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: matchedOrder ? matchedOrder.order_id : selectedOrderId,
    p_delivery_date: deliveryDate,
    p_source: matchedOrder?.source || 'online'
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  closeAssignModal();

  const orderMonth = new Date(`${deliveryDate}T00:00:00`);
  if (orderMonth.getFullYear() !== currentYear || orderMonth.getMonth() !== currentMonth) {
    currentYear = orderMonth.getFullYear();
    currentMonth = orderMonth.getMonth();
  }
  await renderMonth(currentYear, currentMonth);
  showDayDetail(deliveryDate);

  await geocodeAndSaveStop(stopId, addressForGeocode, detailsForStop, { setManualAddress: manuallyEnteredAddress });

  await renderMonth(currentYear, currentMonth);
  showDayDetail(deliveryDate);
}

function wireToolbarAndModal() {
  document.getElementById('prevMonthBtn').addEventListener('click', async () => {
    currentMonth -= 1;
    if (currentMonth < 0) { currentMonth = 11; currentYear -= 1; }
    document.getElementById('dayDetailPanel').classList.add('hidden');
    await renderMonth(currentYear, currentMonth);
  });

  document.getElementById('nextMonthBtn').addEventListener('click', async () => {
    currentMonth += 1;
    if (currentMonth > 11) { currentMonth = 0; currentYear += 1; }
    document.getElementById('dayDetailPanel').classList.add('hidden');
    await renderMonth(currentYear, currentMonth);
  });

  document.getElementById('closeDayDetailBtn').addEventListener('click', () => {
    document.getElementById('dayDetailPanel').classList.add('hidden');
  });

  document.getElementById('printManifestBtn').addEventListener('click', () => {
    const dateKey = document.getElementById('dayDetailPanel').dataset.date;
    if (dateKey) window.open(`delivery-manifest.html?date=${encodeURIComponent(dateKey)}`, '_blank');
  });

  document.getElementById('assignVendorBtn').addEventListener('click', () => {
    const dateKey = document.getElementById('dayDetailPanel').dataset.date;
    if (dateKey) assignDateVendor(dateKey);
  });

  document.getElementById('assignOrderBtn').addEventListener('click', () => {
    const panel = document.getElementById('dayDetailPanel');
    const prefilledDate = !panel.classList.contains('hidden') ? panel.dataset.date : null;
    openAssignModal(prefilledDate);
  });

  document.getElementById('closeAssignModalBtn').addEventListener('click', closeAssignModal);
  document.getElementById('confirmAssignBtn').addEventListener('click', confirmAssign);
  document.getElementById('assignDateInput').addEventListener('change', updateConfirmAssignButtonState);

  document.getElementById('noAddressCloseBtn').addEventListener('click', () => closeNoAddressModal(false));
  document.getElementById('noAddressContinueBtn').addEventListener('click', () => closeNoAddressModal(true));
  document.getElementById('noAddressFindOnMapBtn').addEventListener('click', findTypedAddressOnPinMap);
  document.getElementById('noAddressCalcFeeBtn').addEventListener('click', calculateDeliveryFeeQuote);
  document.getElementById('noAddressInput').addEventListener('input', invalidateFeeQuote);

  wireAssignSortHeaders();

  document.getElementById('assignSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(assignSearchDebounceHandle);
    assignSearchDebounceHandle = setTimeout(() => {
      assignSearch = value;
      assignPage = 1;
      loadAssignOrders();
    }, 300);
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Delivery');

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Delivery.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');

  mapAssetsReady = Promise.all([loadGoogleMapsApiKey(), loadCompanyLogoUrl()]);
  subscribeToDriverLocations();
  startDriverMarkerStaleCheck();

  // Route-change push notifications (supabase_delivery_route_change_push.sql) open
  // delivery.html?date=YYYY-MM-DD - start on that day instead of today.
  const dateParam = new URLSearchParams(window.location.search).get('date');
  const today = /^\d{4}-\d{2}-\d{2}$/.test(dateParam || '') ? new Date(`${dateParam}T00:00:00`) : new Date();
  currentYear = today.getFullYear();
  currentMonth = today.getMonth();

  // Lookups + this month's stops fetched in parallel (previously 5 round trips one after another
  // before the calendar appeared); both views below draw only once all of them are in.
  await Promise.all([
    loadWarehouseLookup(),
    loadVendorLookup(),
    loadAndRenderRouteSchedule(),
    loadMonthStops(currentYear, currentMonth),
    loadMonthDateVendors(currentYear, currentMonth)
  ]);

  // Delivery Team / Dispatchers get asked to turn on route-change notifications (js/pushNotifications.js).
  maybeShowPushLoginPrompt(session).catch(() => {});

  // Per "if user is delivery team they cannot assign order / they cannot do print" - rather than
  // hiding buttons inside the full admin calendar, Delivery Team gets its own single-day Driver
  // Route View entirely (map + stop cards, no month grid, no Assign/Print) - see
  // renderDriverRouteView above. The admin calendar (#calendarView) never renders for this group,
  // so there's no assign/print control to gate in the first place. Client-side only, same trust
  // tier as the rest of this page's role gating (e.g. the Remove button's isSuperUser check
  // below) - not enforced RPC-side.
  if (session.isDeliveryTeam) {
    document.getElementById('driverRouteView').classList.remove('hidden');
    document.getElementById('calendarView').classList.add('hidden');
    wireDriverRouteNav();
    wireMarkDone();
    wireDriverCollections();
    await renderDriverRouteView(toDateKey(today));

    // Reload the day when the driver comes back to the app (e.g. after a route-change
    // notification) so an already-open screen doesn't show the old stops.
    document.addEventListener('visibilitychange', async () => {
      if (document.visibilityState !== 'visible' || !driverDate) return;
      const viewed = new Date(`${driverDate}T00:00:00`);
      await Promise.all([loadMonthStops(viewed.getFullYear(), viewed.getMonth()), loadMonthDateVendors(viewed.getFullYear(), viewed.getMonth())]);
      await renderDriverRouteView(driverDate);
    });
    return;
  }

  wireToolbarAndModal();
  // Month data was already fetched above - just draw it (renderMonth would fetch it again).
  document.getElementById('calendarMonthLabel').textContent = new Date(currentYear, currentMonth, 1)
    .toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  renderCalendarGrid(currentYear, currentMonth);
})();
