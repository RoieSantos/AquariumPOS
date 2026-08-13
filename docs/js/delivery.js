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
let assignSearchDebounceHandle = null;
let assignSearch = '';
let assignPage = 1;
let assignPageSize = 50;
let dayMapInstance = null;
let googleMapsReadyPromise = null;
let googleMapsApiKey = null; // fetched from PortalSettings (GOOGLE_MAPS_API_KEY) during init()
let routeScheduleByDayOfWeek = {}; // 0-6 -> {route_name, warehouse_ids, warehouse_names, vendor_codes, vendor_names}, from loadAndRenderRouteSchedule
let warehouseById = {}; // WarehouseID -> {name, address, latitude, longitude, geocode_status, geocoded_address}, from loadWarehouseLookup
let vendorByCode = {}; // VendorCode -> {name, address, latitude, longitude, geocode_status, geocoded_address}, from loadVendorLookup

function toDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

// Store has no delivery truck out on Mondays - mirrored server-side in
// admin_create_delivery_stop / admin_move_delivery_stop (supabase_delivery_tables.sql) so this
// stays enforced even if a request bypasses this UI.
const NO_DELIVERY_DAY_OF_WEEK = 1; // Date.getDay(): 0 = Sunday ... 1 = Monday

function isBlockedDeliveryDateKey(dateKey) {
  if (!dateKey) return false;
  return new Date(`${dateKey}T00:00:00`).getDay() === NO_DELIVERY_DAY_OF_WEEK;
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

function loadGoogleMapsScript() {
  if (googleMapsReadyPromise) return googleMapsReadyPromise;

  googleMapsReadyPromise = new Promise((resolve, reject) => {
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
  });

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
    const classes = ['delivery-day-cell'];
    if (stops.length > 0) classes.push('has-stops');
    if (isToday) classes.push('today');
    if (key === selectedDateKey) classes.push('selected');
    if (isNoDelivery) classes.push('no-delivery');

    // Per "show the Fixed Route as actual Stop on the calendar so the user can see that it has
    // fixed route on that date" - every occurrence of that weekday gets a badge, not just the
    // weekday header column, so it's visible at a glance while browsing the month.
    const fixedRoute = !isNoDelivery ? routeScheduleByDayOfWeek[cellDate.getDay()] : null;
    // "add a stop on the date showing how many stops fixed" - count of Warehouses + Vendors
    // tagged for this weekday, separate from the real-order "X stops" badge below.
    const fixedCount = fixedRoute ? (fixedRoute.warehouse_names?.length || 0) + (fixedRoute.vendor_names?.length || 0) : 0;

    html += `
      <div class="${classes.join(' ')}" data-date="${key}">
        <div class="delivery-day-number">${day}</div>
        ${isNoDelivery ? '<span class="badge badge-neutral">No Delivery</span>' : ''}
        ${fixedRoute && fixedRoute.route_name ? `<span class="badge badge-purple" title="Fixed route for this day">${fixedRoute.route_name}</span>` : ''}
        ${fixedCount > 0 ? `<span class="badge badge-glass" title="${fixedCount} fixed Warehouse/Vendor stop${fixedCount === 1 ? '' : 's'} for this day">${fixedCount} Fixed</span>` : ''}
        ${stops.length > 0 ? `<span class="badge badge-primary">${stops.length} stop${stops.length === 1 ? '' : 's'}</span>` : ''}
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

  await loadMonthStops(year, month);
  renderCalendarGrid(year, month);
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

  const tags = [
    ...(route.warehouse_names || []).map((n) => `Warehouse: ${n}`),
    ...(route.vendor_names || []).map((n) => `Vendor: ${n}`)
  ];

  return `
    <tr class="delivery-fixed-route-row">
      <td>-</td>
      <td><em>Fixed Route</em></td>
      <td>${route.route_name}</td>
      <td><span class="badge badge-neutral">${tags.length} Fixed</span></td>
      <td colspan="2">${tags.join(', ')}</td>
      <td class="muted">Set in Delivery Setup</td>
      <td></td>
    </tr>
  `;
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

  const label = new Date(`${dateKey}T00:00:00`).toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
  });
  document.getElementById('dayDetailTitle').textContent = `Stops for ${label}`;

  const tbody = document.getElementById('dayStopsTableBody');
  const fixedRouteRow = fixedRouteRowHtml(dateKey);
  tbody.innerHTML = fixedRouteRow + (stops.length === 0
    ? '<tr><td colspan="8" class="muted">No stops scheduled for this day.</td></tr>'
    : stops.map((s) => {
        // Falls back to geocoded_address (a DeliveryStops-only field) when the order itself has
        // no ShippingAddress on file - that's where a manually-typed address from the "no
        // address" confirmation prompt in confirmAssign() ends up, since it's never written back
        // to OnlineOrders.ShippingAddress (a Pancake-synced field).
        const displayAddress = s.shipping_address || s.geocoded_address || '';
        return `
        <tr>
          <td>${s.order_id || ''}</td>
          <td>${s.customer_name || ''}</td>
          <td>${s.route_name || ''}</td>
          <td>${s.status || ''}</td>
          <td>${displayAddress}${!s.shipping_address && s.geocoded_address ? ' <span class="muted">(manually entered)</span>' : ''}</td>
          <td>${s.created_by || ''}</td>
          <td>${s.notes || ''}</td>
          <td>
            ${s.geocode_status !== 'ok' ? `<button class="btn btn-secondary btn-sm" data-retry-geocode-id="${s.stop_id}" data-retry-geocode-address="${encodeURIComponent(displayAddress)}" type="button">Retry Map</button>` : ''}
            ${currentSession.isSuperUser ? `<button class="btn btn-danger btn-sm" data-stop-id="${s.stop_id}" type="button">Remove</button>` : ''}
          </td>
        </tr>
      `;
      }).join(''));

  tbody.querySelectorAll('button[data-stop-id]').forEach((btn) => {
    btn.addEventListener('click', () => removeStop(btn.dataset.stopId, dateKey));
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

async function renderDayMap(stops, dateKey) {
  const mapEl = document.getElementById('dayMap');

  try {
    await loadGoogleMapsScript();
  } catch (err) {
    mapEl.textContent = err.message;
    return;
  }

  const plottedStops = stops.filter((s) => s.geocode_status === 'ok' && s.latitude && s.longitude);
  const warehouseMarkers = await resolveFixedRouteWarehouseMarkers(dateKey);
  const vendorMarkers = await resolveFixedRouteVendorMarkers(dateKey);

  if (plottedStops.length === 0 && warehouseMarkers.length === 0 && vendorMarkers.length === 0) {
    mapEl.innerHTML = '<p class="muted" style="padding:12px;">No geocoded locations to show for this day yet.</p>';
    dayMapInstance = null;
    return;
  }

  mapEl.innerHTML = '';
  dayMapInstance = new google.maps.Map(mapEl, { zoom: 12 });

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
    new google.maps.Marker({
      position,
      map: dayMapInstance,
      title: `Vendor: ${v.name}`,
      icon: 'https://maps.google.com/mapfiles/ms/icons/orange-dot.png'
    });
    bounds.extend(position);
  });

  plottedStops.forEach((s) => {
    const position = { lat: Number(s.latitude), lng: Number(s.longitude) };
    new google.maps.Marker({
      position,
      map: dayMapInstance,
      title: `${s.order_id} - ${s.customer_name || ''}`
    });
    bounds.extend(position);
  });

  dayMapInstance.fitBounds(bounds);
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
  // online_orders only returns orders NOT YET marked ForDelivery - by the time confirmAssign()
  // needs this order's shipping_address for geocoding, admin_create_delivery_stop has already
  // flipped ForDelivery to true, so a fresh lookup would come back empty.
  assignOrdersByOrderId = new Map((orders || []).map((o) => [o.order_id, o]));

  if (!orders || orders.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No deliverable orders found.</td></tr>';
    return;
  }

  // No-address orders are flagged here too (not just at confirmAssign's prompt) so staff can
  // spot them before picking one, per "in the assign Order to Delivery can you show the address
  // too".
  tbody.innerHTML = orders.map((o) => `
    <tr>
      <td><input type="radio" name="assignOrderRadio" value="${o.order_id}" /></td>
      <td>${o.order_id || ''}</td>
      <td>${o.customer_name || ''}</td>
      <td>${o.status || ''}</td>
      <td>${o.shipping_address ? o.shipping_address : '<span class="muted">No address</span>'}</td>
      <td>${o.scheduled_date || '-'}</td>
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
    errorEl.textContent = 'Mondays are not available for delivery - pick a different date.';
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
    p_page_size: assignPageSize
  });

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

async function geocodeAndSaveStop(stopId, address) {
  if (!address || !address.trim()) {
    await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_stop_id: stopId,
      p_geocoded_address: null,
      p_latitude: null,
      p_longitude: null,
      p_geocode_status: 'failed'
    });
    return;
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

    if (result) {
      await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_stop_id: stopId,
        p_geocoded_address: address,
        p_latitude: result.geometry.location.lat(),
        p_longitude: result.geometry.location.lng(),
        p_geocode_status: 'ok'
      });
    } else {
      await supabaseClient.rpc('admin_update_delivery_stop_geocode', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_stop_id: stopId,
        p_geocoded_address: address,
        p_latitude: null,
        p_longitude: null,
        p_geocode_status: 'failed'
      });
    }
  } catch (err) {
    console.error('Geocoding failed:', err);
  }
}

// Portal-styled replacement for window.confirm()/window.prompt() when the selected order has no
// shipping address - resolves to the manually-typed address (a string, or null if left blank) if
// the user clicks Continue, or `undefined` if they cancel. noAddressResolve is a module-level
// handle so the Cancel/Continue buttons (wired once in wireToolbarAndModal) can settle whichever
// promise is currently pending.
let noAddressResolve = null;

function openNoAddressModal(orderId) {
  document.getElementById('noAddressOrderId').textContent = orderId;
  document.getElementById('noAddressInput').value = '';
  document.getElementById('noAddressModal').classList.remove('hidden');
  document.getElementById('noAddressInput').focus();

  return new Promise((resolve) => { noAddressResolve = resolve; });
}

function closeNoAddressModal(proceed) {
  const address = document.getElementById('noAddressInput').value.trim();
  document.getElementById('noAddressModal').classList.add('hidden');

  if (noAddressResolve) {
    noAddressResolve(proceed ? (address || null) : undefined);
    noAddressResolve = null;
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
    errorEl.textContent = 'Mondays are not available for delivery - pick a different date.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Per "show confirmation if the order ID has no address... if still they want to proceed can
  // we ask the user to fill in the address manually" - checked BEFORE creating the stop, so
  // Cancel aborts the whole assignment rather than leaving an unaddressed stop behind. The
  // manually-typed address (if any) is only used to geocode/plot this stop - it does not write
  // back to OnlineOrders.ShippingAddress (a Pancake-synced field), so a manual entry here can't
  // get silently overwritten or drift from what Pancake has on file.
  const matchedOrder = assignOrdersByOrderId.get(selectedOrderId);
  let addressForGeocode = matchedOrder ? matchedOrder.shipping_address : null;

  if (!addressForGeocode || !addressForGeocode.trim()) {
    const manualAddress = await openNoAddressModal(selectedOrderId);
    if (manualAddress === undefined) return; // cancelled
    addressForGeocode = manualAddress;
  }

  const { data: stopId, error } = await supabaseClient.rpc('admin_create_delivery_stop', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: selectedOrderId,
    p_delivery_date: deliveryDate
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

  await geocodeAndSaveStop(stopId, addressForGeocode);

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
  wireToolbarAndModal();
  await loadGoogleMapsApiKey();
  await loadWarehouseLookup();
  await loadVendorLookup();
  await loadAndRenderRouteSchedule();

  const today = new Date();
  currentYear = today.getFullYear();
  currentMonth = today.getMonth();
  await renderMonth(currentYear, currentMonth);
})();
