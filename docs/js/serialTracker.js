// Serial Tracker page logic.
// Table: ItemSerialTracking ("RunningSerialNo" PK, "SerialNo", "ItemCode",
// "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedAtUtc",
// "CreatedBy", "UpdatedAtUtc", "VariantCode", "SoldReceiptNo", "SoldOnlineOrderId")

let allSerials = [];
let currentSession = null;
let isProductionWarehouseUser = true; // unrestricted unless resolveIsProductionWarehouse says otherwise
let isSerialAdmin = false; // StaffUsers."SerialAdmin" - gates the Location edit control below
let warehouseOptions = []; // [{ id, name }] loaded once, used by the edit-location dropdown
let editLocationSerialNo = null;
let urlLocationFilter = null; // ?location= from an Inventory Summary deep link - see openEditLocationModal's sibling, applyUrlFilters

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

// Warehouse list for the Edit Location dropdown - a fixed pick list (rather than free text) so
// values stay an exact match against Warehouses."Name", the same string the desktop POS writes
// via GetCurrentSerialTrackingLocation()/ApplyCurrentWarehouseToHeaderRows and now filters on in
// ProductSerialTrackingForm.GetAvailableSerials. staff_search_warehouses (not admin_list_warehouses)
// since Serial Admin is a staff-level flag, not necessarily a super user.
async function loadWarehouseOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    warehouseOptions = [];
    return;
  }

  warehouseOptions = (data || []).filter((w) => w.name).map((w) => ({ id: w.id, name: w.name }));
}

// True when the row's Location matches the acting Serial Admin's own warehouse, or when the
// account has no single warehouse assigned ("All warehouses" - nothing to restrict against, same
// precedent as the Location editor's own picker).
function isOwnWarehouseLocation(location) {
  const ownWarehouse = (currentSession?.warehouseName || '').trim().toLowerCase();
  if (!ownWarehouse) return true;
  return (location || '').trim().toLowerCase() === ownWarehouse;
}

function openEditLocationModal(serialNo, currentLocation) {
  editLocationSerialNo = serialNo;
  document.getElementById('editLocationSerialNo').textContent = serialNo;
  document.getElementById('editLocationError').classList.add('hidden');

  const select = document.getElementById('editLocationWarehouse');
  const ownWarehouse = (currentSession?.warehouseName || '').trim();

  if (ownWarehouse) {
    // A Serial Admin tied to a specific store (StaffUsers.WarehouseName) can only tag a serial as
    // belonging to their OWN warehouse - not reassign it to a different store - so the picker
    // collapses to that single, locked value instead of the full warehouse list.
    select.innerHTML = `<option value="${escapeHtml(ownWarehouse)}">${escapeHtml(ownWarehouse)}</option>`;
    select.value = ownWarehouse;
    select.disabled = true;
  } else {
    // No single WarehouseName on the account ("All warehouses") - nothing to restrict to, so keep
    // the full picker.
    const options = warehouseOptions.map((w) => `<option value="${escapeHtml(w.name)}">${escapeHtml(w.name)}</option>`).join('');
    select.innerHTML = '<option value="">(Unassigned)</option>' + options;
    select.value = currentLocation || '';
    select.disabled = false;
  }

  document.getElementById('editLocationModal').classList.remove('hidden');
}

async function saveEditLocation() {
  const errorEl = document.getElementById('editLocationError');
  errorEl.classList.add('hidden');

  // Force the own-warehouse value server-side-equivalent even if the (disabled) select were
  // somehow tampered with client-side - matches openEditLocationModal's restriction rather than
  // trusting the DOM value alone.
  const ownWarehouse = (currentSession?.warehouseName || '').trim();
  const newLocation = ownWarehouse || document.getElementById('editLocationWarehouse').value.trim();
  const saveBtn = document.getElementById('saveEditLocationBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { error } = await supabaseClient
    .from('ItemSerialTracking')
    .update({ Location: newLocation || null, UpdatedAtUtc: new Date().toISOString(), UpdatedBy: currentSession?.username || null })
    .eq('SerialNo', editLocationSerialNo);

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save';

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const row = allSerials.find((r) => r.SerialNo === editLocationSerialNo);
  if (row) {
    row.Location = newLocation || null;
    row.UpdatedAtUtc = new Date().toISOString();
    row.UpdatedBy = currentSession?.username || null;
  }

  document.getElementById('editLocationModal').classList.add('hidden');
  renderSerials();
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

function formatDateTime(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleString();
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
  tbody.innerHTML = '<tr><td colspan="10" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('ItemSerialTracking')
    .select('*')
    .order('CreatedAtUtc', { ascending: false })
    .limit(500);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="10" class="error-text">${error.message}</td></tr>`;
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
  // Serial Admins see every warehouse's serials regardless of their own production/non-production
  // status - they need the full cross-store picture to find and correct mistagged serials, even
  // though editing itself stays locked to their own warehouse (see openEditLocationModal/
  // saveEditLocation).
  if (!isProductionWarehouseUser && !isSerialAdmin && currentSession?.warehouseName) {
    const ownWarehouse = currentSession.warehouseName.trim().toLowerCase();
    rows = rows.filter((r) => (r.Location || '').trim().toLowerCase() === ownWarehouse);
  }
  if (urlLocationFilter) {
    const targetLocation = urlLocationFilter.toLowerCase();
    rows = rows.filter((r) => (r.Location || '').trim().toLowerCase() === targetLocation);
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
    tbody.innerHTML = '<tr><td colspan="10" class="muted">No serial records found.</td></tr>';
    return;
  }

  // Status stays otherwise read-only here - it's owned by whichever workflow moved the serial
  // (Stock Counts, Transfer Order shipment tagging, a sale, etc.) and editing it freely could
  // desync it from that workflow's own state. Serial Admins get one narrow, targeted exception -
  // a "Mark In Stock" action to restore a mistakenly SOLD/RETURNED/IN_TRANSIT serial back to
  // IN_STOCK - not a general status editor. Location's own Edit control is the other exception,
  // same admin gate. Mark In Stock only shows when the serial's current Location already matches
  // the admin's own warehouse - marking a serial physically tagged to a DIFFERENT store as
  // in-stock here would falsely claim that unit is on hand locally.
  tbody.innerHTML = rows
    .map((r) => `
      <tr>
        <td>${escapeHtml(r.SerialNo)}</td>
        <td>${escapeHtml(r.ItemCode)}</td>
        <td>${escapeHtml(r.ItemDescription)}</td>
        <td>${escapeHtml(r.Location)}${isSerialAdmin ? ` <button class="btn btn-secondary btn-sm edit-location-btn" data-serial="${encodeURIComponent(r.SerialNo)}" data-location="${encodeURIComponent(r.Location || '')}" type="button">Edit</button>` : ''}</td>
        <td><span class="badge ${statusBadgeClass(r.Status)}">${statusLabel(r.Status)}</span>${isSerialAdmin && (r.Status || '').toUpperCase() !== 'IN_STOCK' && isOwnWarehouseLocation(r.Location) ? ` <button class="btn btn-secondary btn-sm mark-in-stock-btn" data-serial="${encodeURIComponent(r.SerialNo)}" type="button">Mark In Stock</button>` : ''}</td>
        <td>${renderSourceDocCell(r.SourceDocumentNo)}</td>
        <td>${escapeHtml(r.SoldReceiptNo)}</td>
        <td>${escapeHtml(r.SoldOnlineOrderId)}</td>
        <td>${formatDateTime(r.UpdatedAtUtc)}</td>
        <td>${escapeHtml(r.UpdatedBy)}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('.source-doc-link').forEach((link) => {
    link.addEventListener('click', (event) => {
      event.preventDefault();
      resolveAndOpenSourceDoc(decodeURIComponent(link.dataset.docNo));
    });
  });

  tbody.querySelectorAll('.edit-location-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      openEditLocationModal(decodeURIComponent(btn.dataset.serial), decodeURIComponent(btn.dataset.location));
    });
  });

  tbody.querySelectorAll('.mark-in-stock-btn').forEach((btn) => {
    btn.addEventListener('click', () => markInStock(decodeURIComponent(btn.dataset.serial)));
  });
}

async function markInStock(serialNo) {
  // Re-check against the row's actual current Location, not just the (already-filtered) button
  // that was clicked - matches saveEditLocation's own defensive re-check rather than trusting the
  // DOM alone.
  const row = allSerials.find((r) => r.SerialNo === serialNo);
  if (!row || !isOwnWarehouseLocation(row.Location)) {
    alert('This serial is tagged to a different warehouse - it can only be marked In Stock from its own location.');
    renderSerials();
    return;
  }

  if (!confirm(`Mark ${serialNo} as IN_STOCK?`)) return;

  const { error } = await supabaseClient
    .from('ItemSerialTracking')
    .update({ Status: 'IN_STOCK', UpdatedAtUtc: new Date().toISOString(), UpdatedBy: currentSession?.username || null })
    .eq('SerialNo', serialNo);

  if (error) {
    alert(`Failed to update status: ${error.message}`);
    return;
  }

  row.Status = 'IN_STOCK';
  row.UpdatedAtUtc = new Date().toISOString();
  row.UpdatedBy = currentSession?.username || null;
  renderSerials();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Serial Tracker');

  isProductionWarehouseUser = await resolveIsProductionWarehouse(session);
  isSerialAdmin = !!session.isSerialAdmin;

  // Serial Admins always see every warehouse (see renderSerials), so the "restricted to your own
  // warehouse" note would be inaccurate for them even though they're non-production.
  if (!isProductionWarehouseUser && !isSerialAdmin && session.warehouseName) {
    const note = document.getElementById('warehouseFilterNote');
    note.textContent = `Showing serials at ${session.warehouseName} only.`;
    note.classList.remove('hidden');
  }

  if (isSerialAdmin) {
    await loadWarehouseOptionsOnce();
  }

  // Deep link from Inventory Summary's clickable counts (see inventorySummary.js) - pre-fills the
  // search/status filters and adds a Location filter (which this page otherwise doesn't expose as
  // its own control) so clicking a count there lands here already narrowed to exactly those units.
  const urlParams = new URLSearchParams(window.location.search);
  const urlItem = urlParams.get('item');
  const urlStatus = urlParams.get('status');
  const urlLocation = urlParams.get('location');
  if (urlItem) document.getElementById('searchInput').value = urlItem;
  if (urlStatus) document.getElementById('statusFilter').value = urlStatus;
  if (urlLocation) {
    urlLocationFilter = urlLocation;
    const note = document.getElementById('warehouseFilterNote');
    note.innerHTML = `Filtered by location: ${escapeHtml(urlLocation)} (from Inventory Summary) - <a href="serial-tracker.html">Clear</a>`;
    note.classList.remove('hidden');
  }

  document.getElementById('searchInput').addEventListener('input', renderSerials);
  document.getElementById('statusFilter').addEventListener('change', renderSerials);
  document.getElementById('refreshBtn').addEventListener('click', loadSerials);
  document.getElementById('closeViewTransferBtn').addEventListener('click', () =>
    document.getElementById('viewTransferModal').classList.add('hidden')
  );
  document.getElementById('closeEditLocationBtn').addEventListener('click', () =>
    document.getElementById('editLocationModal').classList.add('hidden')
  );
  document.getElementById('saveEditLocationBtn').addEventListener('click', saveEditLocation);
  document.getElementById('openTransferModuleBtn').addEventListener('click', () => {
    if (!currentViewTransferDocNo) return;
    const page = currentViewTransferIsPosted ? 'posted-transfer-orders.html' : 'transfer-orders.html';
    window.open(`${page}?doc=${encodeURIComponent(currentViewTransferDocNo)}`, '_blank');
  });

  await loadSerials();
})();
