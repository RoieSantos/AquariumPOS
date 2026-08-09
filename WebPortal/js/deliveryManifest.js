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

function renderManifestRows(stops) {
  const tbody = document.getElementById('manifestTableBody');

  if (!stops || stops.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No stops scheduled for this day.</td></tr>';
    return;
  }

  tbody.innerHTML = stops
    .map((s, index) => `
      <tr>
        <td>${index + 1}</td>
        <td>${s.order_id || ''}</td>
        <td>${s.customer_name || ''}</td>
        <td>${s.shipping_address || ''}</td>
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
  const label = new Date(`${dateKey}T00:00:00`).toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
  });
  document.getElementById('manifestTitle').textContent = `Delivery Manifest - ${truckName}`;
  document.getElementById('manifestSubtitle').textContent = `${label} - ${(data || []).length} stop${(data || []).length === 1 ? '' : 's'}`;

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
