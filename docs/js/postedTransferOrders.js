// Posted Transfer Orders page logic - read-only browse/search of fully-received Transfer Orders
// archived into Posted_Transfer_Header/Posted_Transfer_Line by receiveTransferOrder() in
// transferOrders.js (see supabase_posted_transfer_orders_tables.sql). Same column set as
// Transfer_Header/Transfer_Line, just permanently moved here once received - nothing on this
// page is ever edited.

let allHeaders = [];
let currentSession = null;

// Persist list-page filters across a real browser refresh - same sessionStorage pattern as
// Transfer Orders' own list page.
const FILTERS_STORAGE_KEY = 'postedTransferOrders.filters';

function saveFilters() {
  const filters = {
    search: document.getElementById('searchInput').value,
    showAllWarehouses: document.getElementById('showAllWarehousesCheck').checked
  };
  sessionStorage.setItem(FILTERS_STORAGE_KEY, JSON.stringify(filters));
}

function restoreFilters() {
  const raw = sessionStorage.getItem(FILTERS_STORAGE_KEY);
  if (!raw) return;
  try {
    const filters = JSON.parse(raw);
    document.getElementById('searchInput').value = filters.search || '';
    document.getElementById('showAllWarehousesCheck').checked = !!filters.showAllWarehouses;
  } catch {
    // Ignore malformed/stale storage.
  }
}

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}

async function loadHeaders() {
  const tbody = document.getElementById('headerTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('Posted_Transfer_Header')
    .select('*')
    .order('"Receive Date"', { ascending: false })
    .limit(300);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  allHeaders = data || [];
  renderHeaders();
}

function renderHeaders() {
  const tbody = document.getElementById('headerTableBody');
  const search = document.getElementById('searchInput').value.trim().toLowerCase();
  const showAllWarehouses = document.getElementById('showAllWarehousesCheck').checked;

  let rows = allHeaders;
  if (currentSession?.warehouseName && !showAllWarehouses) {
    rows = rows.filter((r) =>
      (r['From Warehouse'] || '') === currentSession.warehouseName ||
      (r['To Warehouse'] || '') === currentSession.warehouseName
    );
  }
  if (search) {
    rows = rows.filter((r) =>
      [r['No.'], r['Description'], r['From Warehouse'], r['To Warehouse']]
        .some((v) => (v || '').toString().toLowerCase().includes(search))
    );
  }

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No posted transfer orders found.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((r) => `
      <tr class="clickable-row" data-doc-no="${encodeURIComponent(r['No.'] || '')}">
        <td>${r['No.'] || ''}</td>
        <td>${r['Description'] || ''}</td>
        <td>${r['From Warehouse'] || ''}</td>
        <td>${r['To Warehouse'] || ''}</td>
        <td>${formatDate(r['Requested Date'])}</td>
        <td>${formatDate(r['Transfer Date'])}</td>
        <td>${formatDate(r['Receive Date'])}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('tr[data-doc-no]').forEach((row) => {
    row.addEventListener('click', () => openViewModal(decodeURIComponent(row.dataset.docNo)));
  });
}

function renderViewHeader(header) {
  document.getElementById('viewFromWarehouse').textContent = header['From Warehouse'] || '';
  document.getElementById('viewToWarehouse').textContent = header['To Warehouse'] || '';
  document.getElementById('viewRequestedDate').textContent = formatDate(header['Requested Date']);
  document.getElementById('viewTransferDate').textContent = formatDate(header['Transfer Date']);
  document.getElementById('viewReceiveDate').textContent = formatDate(header['Receive Date']);
}

function renderViewLines(lines) {
  const body = document.getElementById('viewLinesBody');
  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="6" class="muted">No line items.</td></tr>';
    return;
  }

  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l['Item No.'] || ''}</td>
        <td>${l['Variant Name'] || ''}</td>
        <td>${l['Description'] || ''}</td>
        <td>${l['Qty To Transfer'] ?? ''}</td>
        <td>${l['Qty Shipped'] ?? ''}</td>
        <td>${l['Qty Received'] ?? ''}</td>
      </tr>
    `)
    .join('');
}

let currentViewDocNo = null;

async function openViewModal(docNo) {
  currentViewDocNo = docNo;
  document.getElementById('viewLinesTitle').textContent = `Transfer Order ${docNo}`;
  document.getElementById('viewLinesError').classList.add('hidden');
  const body = document.getElementById('viewLinesBody');
  body.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';
  document.getElementById('viewLinesModal').classList.remove('hidden');

  const { data: headerRows, error: headerError } = await supabaseClient
    .from('Posted_Transfer_Header')
    .select('*')
    .eq('"No."', docNo)
    .limit(1);

  if (headerError || !headerRows || headerRows.length === 0) {
    body.innerHTML = `<tr><td colspan="6" class="error-text">${headerError?.message || 'Posted transfer order not found.'}</td></tr>`;
    return;
  }

  renderViewHeader(headerRows[0]);

  const { data, error } = await supabaseClient
    .from('Posted_Transfer_Line')
    .select('*')
    .eq('"Document No."', docNo)
    .order('"Line No."', { ascending: true });

  if (error) {
    body.innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderViewLines(data || []);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Posted Transfers');

  if (session.warehouseName) {
    document.getElementById('myWarehouseName').textContent = session.warehouseName;
    document.getElementById('warehouseFilterLabel').classList.remove('hidden');
  }

  restoreFilters();

  document.getElementById('searchInput').addEventListener('input', () => {
    saveFilters();
    renderHeaders();
  });
  document.getElementById('showAllWarehousesCheck').addEventListener('change', () => {
    saveFilters();
    renderHeaders();
  });
  document.getElementById('refreshBtn').addEventListener('click', loadHeaders);
  document.getElementById('closeViewLinesBtn').addEventListener('click', () =>
    document.getElementById('viewLinesModal').classList.add('hidden')
  );
  document.getElementById('printTransferBtn').addEventListener('click', () => {
    if (currentViewDocNo) window.open(`transfer-order-print.html?no=${encodeURIComponent(currentViewDocNo)}`, '_blank');
  });

  await loadHeaders();

  // Deep-link from Serial Tracker's Source Doc. column (see resolveAndOpenSourceDoc in
  // serialTracker.js), for serials whose Transfer Order has already been received/archived here.
  const docParam = new URLSearchParams(window.location.search).get('doc');
  if (docParam) {
    await openViewModal(docParam);
  }
})();
