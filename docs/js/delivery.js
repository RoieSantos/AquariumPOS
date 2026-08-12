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

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function toDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
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
    const classes = ['delivery-day-cell'];
    if (stops.length > 0) classes.push('has-stops');
    if (isToday) classes.push('today');
    if (key === selectedDateKey) classes.push('selected');

    html += `
      <div class="${classes.join(' ')}" data-date="${key}">
        <div class="delivery-day-number">${day}</div>
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
  tbody.innerHTML = stops.length === 0
    ? '<tr><td colspan="7" class="muted">No stops scheduled for this day.</td></tr>'
    : stops.map((s) => `
        <tr>
          <td>${s.order_id || ''}</td>
          <td>${s.customer_name || ''}</td>
          <td>${s.status || ''}</td>
          <td>${s.shipping_address || ''}</td>
          <td>${formatMoney(s.balance)}</td>
          <td>${s.notes || ''}</td>
          <td>
            ${s.geocode_status !== 'ok' ? `<button class="btn btn-secondary btn-sm" data-retry-geocode-id="${s.stop_id}" data-retry-geocode-address="${encodeURIComponent(s.shipping_address || '')}" type="button">Retry Map</button>` : ''}
            <button class="btn btn-danger btn-sm" data-stop-id="${s.stop_id}" type="button">Remove</button>
          </td>
        </tr>
      `).join('');

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

  renderDayMap(stops);
}

async function renderDayMap(stops) {
  const mapEl = document.getElementById('dayMap');

  try {
    await loadGoogleMapsScript();
  } catch (err) {
    mapEl.textContent = err.message;
    return;
  }

  const plotted = stops.filter((s) => s.geocode_status === 'ok' && s.latitude && s.longitude);

  if (plotted.length === 0) {
    mapEl.innerHTML = '<p class="muted" style="padding:12px;">No geocoded locations to show for this day yet.</p>';
    dayMapInstance = null;
    return;
  }

  mapEl.innerHTML = '';
  dayMapInstance = new google.maps.Map(mapEl, { zoom: 12 });

  const bounds = new google.maps.LatLngBounds();
  plotted.forEach((s) => {
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

  tbody.innerHTML = orders.map((o) => `
    <tr>
      <td><input type="radio" name="assignOrderRadio" value="${o.order_id}" /></td>
      <td>${o.order_id || ''}</td>
      <td>${o.customer_name || ''}</td>
      <td>${o.status || ''}</td>
      <td>${formatMoney(o.balance)}</td>
      <td>${o.scheduled_date || '-'}</td>
    </tr>
  `).join('');

  tbody.querySelectorAll('input[name="assignOrderRadio"]').forEach((radio) => {
    radio.addEventListener('change', () => {
      selectedOrderId = radio.value;
      document.getElementById('confirmAssignBtn').disabled = false;
    });
  });
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
  document.getElementById('confirmAssignBtn').disabled = true;
  document.getElementById('assignError').classList.add('hidden');
  document.getElementById('assignSearchInput').value = '';
  assignSearch = '';
  assignPage = 1;
  document.getElementById('assignDateInput').value = prefilledDate || toDateKey(new Date());
  document.getElementById('assignModal').classList.remove('hidden');
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

async function confirmAssign() {
  const errorEl = document.getElementById('assignError');
  errorEl.classList.add('hidden');

  const deliveryDate = document.getElementById('assignDateInput').value;
  if (!selectedOrderId || !deliveryDate) {
    errorEl.textContent = 'Pick an order and a delivery date.';
    errorEl.classList.remove('hidden');
    return;
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

  const assignedOrderId = selectedOrderId;
  const orderMonth = new Date(`${deliveryDate}T00:00:00`);
  if (orderMonth.getFullYear() !== currentYear || orderMonth.getMonth() !== currentMonth) {
    currentYear = orderMonth.getFullYear();
    currentMonth = orderMonth.getMonth();
  }
  await renderMonth(currentYear, currentMonth);
  showDayDetail(deliveryDate);

  const matchedOrder = assignOrdersByOrderId.get(assignedOrderId);
  await geocodeAndSaveStop(stopId, matchedOrder ? matchedOrder.shipping_address : null);

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

  const today = new Date();
  currentYear = today.getFullYear();
  currentMonth = today.getMonth();
  await renderMonth(currentYear, currentMonth);
})();
