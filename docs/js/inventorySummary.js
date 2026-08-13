// Inventory Summary page logic - counts of serial-tracked Aquarium/Stand/Sump units by
// Location (Warehouse), via staff_get_serial_category_counts_by_location.
let currentSession = null;
let allItemRows = []; // last-loaded staff_get_serial_item_counts_by_location result, filtered client-side by productSearchInput

function formatCount(value) {
  return Number(value || 0).toLocaleString();
}

function categoryLabel(bucket) {
  switch ((bucket || '').toUpperCase()) {
    case 'AQUARIUM': return 'Aquarium';
    case 'STAND': return 'Stand';
    case 'SUMP': return 'Sump';
    default: return bucket || '';
  }
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Links a count to Serial Tracker, pre-filtered to exactly the units that make up that count -
// same item code, same location, same status filter that was active when this count was computed
// (see loadItemBreakdown's p_status). "(Unassigned)" is this page's own display placeholder for a
// blank/null Location (see the RPC's coalesce), not a real stored value, so it's left out of the
// link rather than passed through as a location that would never actually match anything there.
function buildSerialTrackerLink(itemCode, location, status) {
  const params = new URLSearchParams();
  if (itemCode) params.set('item', itemCode);
  if (location && location !== '(Unassigned)') params.set('location', location);
  if (status) params.set('status', status);
  const query = params.toString();
  return `serial-tracker.html${query ? '?' + query : ''}`;
}

function renderItemTable(rows) {
  const tbody = document.getElementById('itemTableBody');
  rows = rows || [];

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No serial records found for this filter.</td></tr>';
    return;
  }

  const status = document.getElementById('statusFilter').value;

  tbody.innerHTML = rows
    .map((r) => `
      <tr>
        <td>${escapeHtml(r.item_code)}</td>
        <td>${escapeHtml(r.item_description)}</td>
        <td>${categoryLabel(r.category)}</td>
        <td>${escapeHtml(r.location)}</td>
        <td style="text-align:right;"><a href="${buildSerialTrackerLink(r.item_code, r.location, status)}">${formatCount(r.unit_count)}</a></td>
      </tr>
    `)
    .join('');
}

async function loadItemBreakdown() {
  const status = document.getElementById('statusFilter').value;
  const category = document.getElementById('categoryFilter').value;

  const { data, error } = await supabaseClient.rpc('staff_get_serial_item_counts_by_location', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_status: status || null,
    p_category: category || null
  });

  if (error) {
    document.getElementById('itemTableBody').innerHTML = `<tr><td colspan="5" class="error-text">${error.message}</td></tr>`;
    return;
  }

  allItemRows = data || [];
  renderFilteredItemTable();
}

// productSearchInput filters client-side against the already-loaded result (same pattern as
// Serial Tracker's own search box) - no need to round-trip to Supabase for a plain text filter.
function renderFilteredItemTable() {
  const search = document.getElementById('productSearchInput').value.trim().toLowerCase();
  const rows = search
    ? allItemRows.filter((r) =>
        [r.item_code, r.item_description].some((v) => (v || '').toString().toLowerCase().includes(search))
      )
    : allItemRows;
  renderItemTable(rows);
}

function renderSummary(rows) {
  const tbody = document.getElementById('summaryTableBody');
  rows = rows || [];

  let aquariumTotal = 0;
  let standTotal = 0;
  let sumpTotal = 0;
  let grandTotal = 0;

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No serial records found for this status.</td></tr>';
  } else {
    tbody.innerHTML = rows
      .map((r) => {
        aquariumTotal += Number(r.aquarium_count || 0);
        standTotal += Number(r.stand_count || 0);
        sumpTotal += Number(r.sump_count || 0);
        grandTotal += Number(r.total_count || 0);
        return `
          <tr>
            <td>${r.location || ''}</td>
            <td style="text-align:right;">${formatCount(r.aquarium_count)}</td>
            <td style="text-align:right;">${formatCount(r.stand_count)}</td>
            <td style="text-align:right;">${formatCount(r.sump_count)}</td>
            <td style="text-align:right; font-weight:600;">${formatCount(r.total_count)}</td>
          </tr>
        `;
      })
      .join('');
  }

  document.getElementById('statAquariumTotal').textContent = formatCount(aquariumTotal);
  document.getElementById('statStandTotal').textContent = formatCount(standTotal);
  document.getElementById('statSumpTotal').textContent = formatCount(sumpTotal);
  document.getElementById('statGrandTotal').textContent = formatCount(grandTotal);
}

async function loadSummary() {
  const loadingEl = document.getElementById('summaryLoading');
  const errorEl = document.getElementById('summaryError');
  const resultsEl = document.getElementById('summaryResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  resultsEl.classList.add('hidden');

  const status = document.getElementById('statusFilter').value;

  const { data, error } = await supabaseClient.rpc('staff_get_serial_category_counts_by_location', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_status: status || null
  });

  loadingEl.classList.add('hidden');

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  renderSummary(data);
  resultsEl.classList.remove('hidden');
}

async function refreshAll() {
  await Promise.all([loadSummary(), loadItemBreakdown()]);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Inventory Summary');

  document.getElementById('statusFilter').addEventListener('change', refreshAll);
  document.getElementById('categoryFilter').addEventListener('change', loadItemBreakdown);
  document.getElementById('productSearchInput').addEventListener('input', renderFilteredItemTable);
  document.getElementById('refreshBtn').addEventListener('click', refreshAll);

  await refreshAll();
})();
