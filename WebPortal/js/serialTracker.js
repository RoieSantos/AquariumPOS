// Serial Tracker page logic.
// Table: ItemSerialTracking ("RunningSerialNo" PK, "SerialNo", "ItemCode",
// "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedAtUtc",
// "CreatedBy", "UpdatedAtUtc", "VariantCode", "SoldReceiptNo", "SoldOnlineOrderId")

let allSerials = [];
let currentSession = null;
let isProductionWarehouseUser = true; // unrestricted unless resolveIsProductionWarehouse says otherwise

// Non-production (store) warehouses only see serial activity for their own location - Production
// staff need the full cross-warehouse picture (that's who runs Stock Counts / ships Transfer
// Orders to everyone else), so they stay unrestricted. Mirrors the same
// StockCountsForm.GetCurrentWarehouse-style production/non-production split used to gate Stock
// Counts locally, just resolved here via staff_search_warehouses since the Portal only has the
// warehouse *name* from the login session (see verify_login() in supabase_staff_users_table.sql).
async function resolveIsProductionWarehouse(session) {
  if (!session?.warehouseName) return true;

  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_search: session.warehouseName
  });
  if (error || !data) return true;

  const match = data.find((w) => (w.name || '').trim().toLowerCase() === session.warehouseName.trim().toLowerCase());
  return match ? !!match.is_production_warehouse : true;
}

function statusBadgeClass(status) {
  switch ((status || '').toUpperCase()) {
    case 'IN_STOCK': return 'badge-success';
    case 'SOLD': return 'badge-neutral';
    case 'RESERVED': return 'badge-warning';
    case 'RETURNED': return 'badge-danger';
    case 'IN_TRANSIT': return 'badge-primary';
    default: return 'badge-neutral';
  }
}

function statusLabel(status) {
  switch ((status || '').toUpperCase()) {
    case 'IN_STOCK': return 'In Stock';
    case 'SOLD': return 'Sold';
    case 'RESERVED': return 'Reserved';
    case 'RETURNED': return 'Returned';
    case 'IN_TRANSIT': return 'In Transit';
    default: return status || '';
  }
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Serials tagged onto a Transfer Order shipment have SourceDocumentNo set to that order's own
// "No." (see staff_claim_serials_for_transfer_shipment in supabase_transfer_order_serial_tagging.sql),
// which always carries the "TR-" prefix minted by staff_next_transfer_no (see generateTransferNo
// in transferOrders.js). Anything else (e.g. Stock Counts' "STOCKCOUNTS_yyyyMMdd_HHmmss" batch
// docs) isn't a Transfer Order and has nothing to link to.
function renderSourceDocCell(sourceDocumentNo) {
  const value = sourceDocumentNo || '';
  if (!value) return '';
  if (value.startsWith('TR-')) {
    return `<a href="#" class="source-doc-link" data-doc-no="${encodeURIComponent(value)}">${escapeHtml(value)}</a>`;
  }
  return escapeHtml(value);
}

function statusBadgeClassForTransfer(status) {
  switch ((status || '').toLowerCase()) {
    case 'received': return 'badge-success';
    case 'cancelled': return 'badge-danger';
    case 'requested': return 'badge-warning';
    case 'in-transit': return 'badge-neutral';
    case 'in transit': return 'badge-neutral';
    case 'partial shipped': return 'badge-primary';
    case 'partial received': return 'badge-purple';
    default: return 'badge-neutral';
  }
}

function formatTransferDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}

function renderTransferLines(lines) {
  const body = document.getElementById('viewTransferLinesBody');
  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="6" class="muted">No line items.</td></tr>';
    return;
  }
  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${escapeHtml(l['Item No.'])}</td>
        <td>${escapeHtml(l['Variant Name'])}</td>
        <td>${escapeHtml(l['Description'])}</td>
        <td>${l['Qty To Transfer'] ?? ''}</td>
        <td>${l['Qty Shipped'] ?? ''}</td>
        <td>${l['Qty Received'] ?? ''}</td>
      </tr>
    `)
    .join('');
}

// The same "No." lives in exactly one of these two table pairs at any given time -
// Transfer_Header/Transfer_Line while the order is still in progress (Requested/Partial
// Shipped/In-Transit), or Posted_Transfer_Header/Posted_Transfer_Line once
// receiveTransferOrder() has fully received and archived it (see archiveReceivedTransferOrder
// in transferOrders.js, which deletes from Transfer_Header/Line as part of that move). Shown
// in-place in a read-only modal here (rather than navigating to transfer-orders.html /
// posted-transfer-orders.html) so Serial Tracker stays the active page, per direct instruction.
let currentViewTransferDocNo = null;
let currentViewTransferIsPosted = false;

async function resolveAndOpenSourceDoc(docNo) {
  const modal = document.getElementById('viewTransferModal');
  const errorEl = document.getElementById('viewTransferError');
  const openModuleBtn = document.getElementById('openTransferModuleBtn');
  errorEl.classList.add('hidden');
  openModuleBtn.classList.add('hidden');
  document.getElementById('viewTransferTitle').textContent = `Transfer Order ${docNo}`;
  document.getElementById('viewTransferStatusBadge').textContent = '';
  document.getElementById('viewTransferLinesBody').innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';
  modal.classList.remove('hidden');

  const { data: activeRows } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .eq('"No."', docNo)
    .limit(1);

  let header = activeRows && activeRows.length > 0 ? activeRows[0] : null;
  let lineTable = 'Transfer_Line';
  let isPosted = false;

  if (!header) {
    const { data: postedRows } = await supabaseClient
      .from('Posted_Transfer_Header')
      .select('*')
      .eq('"No."', docNo)
      .limit(1);
    if (postedRows && postedRows.length > 0) {
      header = postedRows[0];
      lineTable = 'Posted_Transfer_Line';
      isPosted = true;
    }
  }

  if (!header) {
    document.getElementById('viewTransferLinesBody').innerHTML = '';
    errorEl.textContent = `Transfer order ${docNo} was not found (it may have been cancelled or deleted).`;
    errorEl.classList.remove('hidden');
    return;
  }

  // "Open in Transfer Orders" - jumps to the actual module (transfer-orders.html's Manage modal,
  // or posted-transfer-orders.html's view modal, via the same ?doc= deep link both pages already
  // support) for staff who need to act on the order (Ship/Receive/Cancel), not just read it here.
  currentViewTransferDocNo = docNo;
  currentViewTransferIsPosted = isPosted;
  openModuleBtn.classList.remove('hidden');

  const statusBadge = document.getElementById('viewTransferStatusBadge');
  statusBadge.textContent = header['Status'] || (lineTable === 'Posted_Transfer_Line' ? 'Received' : '');
  statusBadge.className = `badge ${statusBadgeClassForTransfer(header['Status'] || (lineTable === 'Posted_Transfer_Line' ? 'Received' : ''))}`;
  document.getElementById('viewTransferFromWarehouse').textContent = header['From Warehouse'] || '';
  document.getElementById('viewTransferToWarehouse').textContent = header['To Warehouse'] || '';
  document.getElementById('viewTransferRequestedDate').textContent = formatTransferDate(header['Requested Date']);
  document.getElementById('viewTransferTransferDate').textContent = formatTransferDate(header['Transfer Date']);
  document.getElementById('viewTransferReceiveDate').textContent = formatTransferDate(header['Receive Date']);

  const { data: lineRows, error: lineError } = await supabaseClient
    .from(lineTable)
    .select('*')
    .eq('"Document No."', docNo)
    .order('"Line No."', { ascending: true });

  if (lineError) {
    errorEl.textContent = lineError.message;
    errorEl.classList.remove('hidden');
    return;
  }

  renderTransferLines(lineRows || []);
}

async function loadSerials() {
  const tbody = document.getElementById('serialTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('ItemSerialTracking')
    .select('*')
    .order('CreatedAtUtc', { ascending: false })
    .limit(500);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  allSerials = data || [];
  renderSerials();
}

function renderSerials() {
  const tbody = document.getElementById('serialTableBody');
  const search = document.getElementById('searchInput').value.trim().toLowerCase();
  const statusFilter = document.getElementById('statusFilter').value;

  let rows = allSerials;
  if (!isProductionWarehouseUser && currentSession?.warehouseName) {
    const ownWarehouse = currentSession.warehouseName.trim().toLowerCase();
    rows = rows.filter((r) => (r.Location || '').trim().toLowerCase() === ownWarehouse);
  }
  if (statusFilter) {
    rows = rows.filter((r) => (r.Status || '') === statusFilter);
  }
  if (search) {
    rows = rows.filter((r) =>
      [r.SerialNo, r.ItemCode, r.ItemDescription].some((v) => (v || '').toString().toLowerCase().includes(search))
    );
  }

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No serial records found.</td></tr>';
    return;
  }

  // Location and Status are set by whichever workflow moved the serial (Stock Counts, Transfer
  // Order shipment tagging, a sale, etc.) - editing them freely here could desync them from that
  // workflow's own state, so this page is read-only for both, per direct instruction.
  tbody.innerHTML = rows
    .map((r) => `
      <tr>
        <td>${escapeHtml(r.SerialNo)}</td>
        <td>${escapeHtml(r.ItemCode)}</td>
        <td>${escapeHtml(r.ItemDescription)}</td>
        <td>${escapeHtml(r.Location)}</td>
        <td><span class="badge ${statusBadgeClass(r.Status)}">${statusLabel(r.Status)}</span></td>
        <td>${renderSourceDocCell(r.SourceDocumentNo)}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('.source-doc-link').forEach((link) => {
    link.addEventListener('click', (event) => {
      event.preventDefault();
      resolveAndOpenSourceDoc(decodeURIComponent(link.dataset.docNo));
    });
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Serial Tracker');

  isProductionWarehouseUser = await resolveIsProductionWarehouse(session);
  if (!isProductionWarehouseUser && session.warehouseName) {
    const note = document.getElementById('warehouseFilterNote');
    note.textContent = `Showing serials at ${session.warehouseName} only.`;
    note.classList.remove('hidden');
  }

  document.getElementById('searchInput').addEventListener('input', renderSerials);
  document.getElementById('statusFilter').addEventListener('change', renderSerials);
  document.getElementById('refreshBtn').addEventListener('click', loadSerials);
  document.getElementById('closeViewTransferBtn').addEventListener('click', () =>
    document.getElementById('viewTransferModal').classList.add('hidden')
  );
  document.getElementById('openTransferModuleBtn').addEventListener('click', () => {
    if (!currentViewTransferDocNo) return;
    const page = currentViewTransferIsPosted ? 'posted-transfer-orders.html' : 'transfer-orders.html';
    window.open(`${page}?doc=${encodeURIComponent(currentViewTransferDocNo)}`, '_blank');
  });

  await loadSerials();
})();
