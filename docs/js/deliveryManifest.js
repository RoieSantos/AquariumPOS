// Printable Delivery Manifest for a single date (?date=YYYY-MM-DD), linked from the "Print
// Manifest" button on a Delivery day-detail panel (see js/delivery.js). Reuses
// admin_list_delivery_stops (supabase_delivery_tables.sql) with a one-day range - no new RPC
// needed. Same trust tier as Delivery itself (any active staff, reuses session.password, no
// re-unlock prompt beyond the stale-session fallback).
let currentSession = null;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

// An address that isn't really an address - blank, or Pancake's own "Walkin" placeholder text
// used on a walk-in POS sale with no real customer picked. Same check as delivery.js's own
// isPlaceholderAddress, so "Walkin" prints as the manually-entered address instead of the literal
// placeholder - per "this will fall under the printout too".
function isPlaceholderAddress(address) {
  const a = (address || '').trim().toLowerCase();
  return !a || a === 'walkin';
}

function renderManifestRows(stops) {
  const tbody = document.getElementById('manifestTableBody');

  if (!stops || stops.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No stops scheduled for this day.</td></tr>';
    return;
  }

  // Falls back to geocoded_address when the order has no real ShippingAddress on file - either
  // genuinely blank, or the "Walkin" placeholder (isPlaceholderAddress) - that's where a
  // manually-typed address from the "no address"/walk-in confirmation prompt on the Delivery
  // page ends up (see delivery.js's confirmAssign), since it's never written back to
  // OnlineOrders.ShippingAddress (a Pancake-synced field). customer_name needs no such fallback
  // here - admin_list_delivery_stops already substitutes the manually-entered name server-side.
  tbody.innerHTML = stops
    .map((s, index) => `
      <tr>
        <td>${index + 1}</td>
        <td>${s.order_id || ''}</td>
        <td>${s.customer_name || ''}</td>
        <td>${isPlaceholderAddress(s.shipping_address) ? (s.geocoded_address || '') : s.shipping_address}</td>
        <td>${formatMoney(s.balance)}</td>
        <td>${s.notes || ''}</td>
      </tr>
    `)
    .join('');
}

async function loadManifest(dateKey) {
  const startDate = dateKey;
  const endDate = new Date(`${dateKey}T00:00:00`);
  endDate.setDate(endDate.getDate() + 1);
  const endDateKey = endDate.toISOString().slice(0, 10);

  const { data, error } = await supabaseClient.rpc('admin_list_delivery_stops', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_start_date: startDate,
    p_end_date: endDateKey
  });

  if (error) {
    document.getElementById('manifestTableBody').innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const truckName = (data && data[0] && data[0].truck_name) || 'Delivery Truck';
  const routeName = data && data[0] && data[0].route_name;
  const label = new Date(`${dateKey}T00:00:00`).toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
  });
  document.getElementById('manifestTitle').textContent = `Delivery Manifest - ${truckName}`;
  const subtitleParts = [label, `${(data || []).length} stop${(data || []).length === 1 ? '' : 's'}`];
  if (routeName) subtitleParts.push(routeName);
  document.getElementById('manifestSubtitle').textContent = subtitleParts.join(' - ');

  renderManifestRows(data);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Delivery');
  await renderCompanyLetterhead('companyLetterhead');

  const dateKey = new URLSearchParams(window.location.search).get('date');
  if (!dateKey) {
    document.getElementById('manifestTableBody').innerHTML = '<tr><td colspan="6" class="error-text">Missing ?date= parameter.</td></tr>';
    document.getElementById('manifestContent').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Delivery Manifest.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('manifestContent').classList.remove('hidden');
  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadManifest(dateKey);
})();
