// Serial Tracker page logic.
// Table: ItemSerialTracking ("RunningSerialNo" PK, "SerialNo", "ItemCode",
// "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedAtUtc",
// "CreatedBy", "UpdatedAtUtc", "VariantCode", "SoldReceiptNo", "SoldOnlineOrderId")

let allSerials = [];
let currentSession = null;
let isProductionWarehouseUser = true; // unrestricted unless resolveIsProductionWarehouse says otherwise
let isSerialAdmin = false; // StaffUsers."SerialAdmin" - gates the Location edit control below
let canReprintLabels = false; // Super User / Production Manager - per-row Reprint (js/labelPrinter.js)
let warehouseOptions = []; // [{ id, name }] loaded once, used by the edit-location dropdown
let editLocationSerialNo = null;
let urlVariantFilter = null; // ?variant= from an Inventory Summary deep link - narrows to the exact variant that count's row represented, not just the item code
let serialSearchDebounceHandle = null;
let selectedSerialNo = null; // the selected list row - the action bar works on it (BC list, same as Online Orders)
let canBulkFloat = false; // Super User - tick column + Mark Floating / Release (admin_bulk_set_serial_status)
const checkedSerialNos = new Set(); // ticked for bulk Mark Floating / Release
let visibleSerialNos = []; // rows currently in the list, for the tick-all box

// Store staff limited to their own warehouse's serials (Serial Admins and production staff see every
// location) - the server-side restriction loadSerials / loadStatusCounts both apply.
function ownWarehouseRestriction() {
  return (!isProductionWarehouseUser && !isSerialAdmin && currentSession?.warehouseName) ? currentSession.warehouseName : null;
}

function locationFilterValue() {
  return document.getElementById('locationFilter').value.trim();
}

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

// Filter pane's Location pick list - the same warehouse list; keeps a deep-linked value
// (?location= from Inventory Summary) selectable even if it isn't in the list.
function fillLocationFilter(selectedValue) {
  const select = document.getElementById('locationFilter');
  const names = warehouseOptions.map((w) => w.name);
  if (selectedValue && !names.includes(selectedValue)) names.push(selectedValue);
  select.innerHTML = '<option value="">All locations</option>'
    + names.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');
  select.value = selectedValue || '';
}

// Category dropdown options - loaded once, same reasoning as loadWarehouseOptionsOnce (a fixed
// pick list rather than free text, so values stay an exact match against Items."CategoryCode").
async function loadCategoryOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('staff_list_categories', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error || !data) return;

  const select = document.getElementById('categoryFilter');
  const options = data.map((c) => `<option value="${escapeHtml(c.code)}">${escapeHtml(c.description)}</option>`).join('');
  select.innerHTML = '<option value="">All categories</option>' + options;
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
  loadStatusCounts();
}

function statusBadgeClass(status) {
  switch ((status || '').toUpperCase()) {
    case 'IN_STOCK': return 'badge-success';
    case 'SOLD': return 'badge-neutral';
    case 'RESERVED': return 'badge-warning';
    case 'RETURNED': return 'badge-danger';
    case 'IN_TRANSIT': return 'badge-primary';
    case 'MISSING': return 'badge-danger';
    case 'FLOATING': return 'badge-warning';
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
    case 'MISSING': return 'Missing';
    case 'FLOATING': return 'Floating';
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

// Was a plain `.select('*').order('CreatedAtUtc', {desc}).limit(500)` - the 500 most RECENTLY
// CREATED rows across the WHOLE table, filtered client-side afterward. Once the table grew past
// 500 rows, an older batch of serials (e.g. a warehouse's whole AQ-001 stock) could fall outside
// that window and become invisible to every search/filter here, even though Inventory Summary's
// server-side aggregate (no such cap) still counted them correctly - see "why does Amaya have 38
// stocks in Inventory Summary but 0 in Serial Tracker". staff_search_item_serial_tracking
// (supabase_serial_tracker_search_rpc.sql) filters server-side FIRST, then limits, so a search
// always finds a matching row regardless of table size.
async function loadSerials() {
  const tbody = document.getElementById('serialTableBody');
  tbody.innerHTML = '<tr><td colspan="10" class="cell-msg">Loading...</td></tr>';

  const search = document.getElementById('searchInput').value.trim();
  const status = document.getElementById('statusFilter').value;
  const category = document.getElementById('categoryFilter').value;
  syncStatusTabs();
  loadStatusCounts();

  const { data, error } = await supabaseClient.rpc('staff_search_item_serial_tracking', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: search || null,
    p_status: status || null,
    p_location_restrict: ownWarehouseRestriction(),
    p_location_filter: locationFilterValue() || null,
    p_variant_filter: urlVariantFilter || null,
    p_category_code: category || null
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="10" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  allSerials = (data || []).map((r) => ({
    SerialNo: r.serial_no,
    ItemCode: r.item_code,
    ItemDescription: r.item_description,
    VariantCode: r.variant_code,
    VariantSku: r.variant_sku,
    Colour: r.colour,
    Location: r.location,
    Status: r.status,
    SourceDocumentNo: r.source_document_no,
    SoldReceiptNo: r.sold_receipt_no,
    SoldOnlineOrderId: r.sold_online_order_id,
    CreatedAtUtc: r.created_at_utc,
    UpdatedAtUtc: r.updated_at_utc,
    UpdatedBy: r.updated_by,
    Maker: null,
    Reprints: null
  }));
  // Latest change first (UpdatedAtUtc, else CreatedAtUtc) - same order the search RPC uses once
  // supabase_serial_tracker_sort_latest_update.sql is run.
  const lastChange = (r) => Date.parse(r.UpdatedAtUtc || r.CreatedAtUtc || '') || 0;
  allSerials.sort((a, b) => lastChange(b) - lastChange(a) || String(b.SerialNo).localeCompare(String(a.SerialNo)));
  renderSerials();
  attachSerialMakers();
  attachSerialReprints();
}

// Reprint count - per "can you show number of times they reprint it": how many times each serial's
// label was reprinted from this page (supabase_serial_label_reprints.sql). Loaded after the list like
// the Maker column; quietly hidden until that file is run.
async function attachSerialReprints() {
  const serialNos = allSerials.map((r) => r.SerialNo).filter(Boolean);
  if (!serialNos.length) return;
  const { data, error } = await supabaseClient.rpc('staff_get_serial_label_reprints', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_serial_nos: serialNos
  });
  if (error) { console.warn('staff_get_serial_label_reprints:', error.message); return; }
  const bySerial = new Map((data || []).map((p) => [p.serial_no, p]));
  allSerials.forEach((r) => { r.Reprints = bySerial.get(r.SerialNo) || null; });
  renderSerials();
}

function reprintCountHtml(r) {
  const p = r.Reprints;
  if (!p || !p.reprint_count) return '';
  const title = `Last reprinted ${formatDateTime(p.last_reprinted_at)}${p.last_reprinted_by ? ` by ${p.last_reprinted_by}` : ''}`;
  return `<div class="muted" style="font-size:11px; line-height:1.3;" title="${escapeHtml(title)}">Reprinted ${p.reprint_count}&times;</div>`;
}

// Maker column - per "in the Serial tracker can you show who is the maker?": the Tank / Stand Maker
// of the Production Order (or online order) that built each serial (supabase_serial_tracker_maker.sql).
// Loaded after the list so it never slows the search down; quietly "-" until that file is run.
async function attachSerialMakers() {
  const serialNos = allSerials.map((r) => r.SerialNo).filter(Boolean);
  if (!serialNos.length) return;
  const { data, error } = await supabaseClient.rpc('staff_get_serial_makers', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_serial_nos: serialNos
  });
  if (error) { console.warn('staff_get_serial_makers:', error.message); return; }
  const bySerial = new Map((data || []).map((m) => [m.serial_no, m]));
  allSerials.forEach((r) => { r.Maker = bySerial.get(r.SerialNo) || null; });
  renderSerials();
}

// The list grid fills the rest of the window (css/bc-list.css .bc-grid-wrap) - same as Purchase Orders.
function fitGridToViewport() {
  const el = document.getElementById('serialGridWrap');
  if (!el || el.offsetParent === null) return;
  const available = window.innerHeight - el.getBoundingClientRect().top - 24;
  el.style.maxHeight = Math.max(240, available) + 'px';
}

// Black / Clear sealant - the RPC's colour (from the variant SKU, same rule as the Production Order
// card; supabase_serial_variant_sku_colour.sql), else whatever the SKU / description text says.
function serialColour(r) {
  if (r.Colour) return r.Colour;
  for (const t of [r.VariantSku, r.ItemDescription]) {
    if (/black|\bblk\b/i.test(t || '')) return 'Black';
    if (/clear|\bclr\b/i.test(t || '')) return 'Clear';
  }
  return null;
}

// Same pill as the Production Order lines (productionOrders.js colourTagHtml).
function colourTagHtml(colour) {
  if (!colour) return '';
  const dot = colour === 'Black' ? 'background:#1b1b1b' : 'background:#fff;border:1.5px solid #7aa7d9;box-sizing:border-box';
  return ` <span class="prod-colour-tag" title="${escapeHtml(colour)}" style="display:inline-flex;align-items:center;gap:4px;padding:0 7px;border:1px solid #c9d3e0;border-radius:999px;font-size:11px;font-weight:700;white-space:nowrap;"><i style="width:9px;height:9px;border-radius:50%;display:inline-block;${dot}"></i>${escapeHtml(colour)}</span>`;
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
  if (locationFilterValue()) {
    const targetLocation = locationFilterValue().toLowerCase();
    rows = rows.filter((r) => (r.Location || '').trim().toLowerCase() === targetLocation);
  }
  if (urlVariantFilter) {
    rows = rows.filter((r) => (r.VariantCode || '').trim() === urlVariantFilter.trim());
  }
  if (statusFilter) {
    rows = rows.filter((r) => (r.Status || '') === statusFilter);
  }
  if (search) {
    rows = rows.filter((r) =>
      [r.SerialNo, r.ItemCode, r.ItemDescription, r.VariantSku].some((v) => (v || '').toString().toLowerCase().includes(search))
    );
  }

  const colCount = canBulkFloat ? 11 : 10;
  visibleSerialNos = rows.map((r) => r.SerialNo);
  // Ticks only count for rows still in the list (a filter change drops the rest).
  [...checkedSerialNos].forEach((sn) => { if (!visibleSerialNos.includes(sn)) checkedSerialNos.delete(sn); });

  if (rows.length === 0) {
    tbody.innerHTML = `<tr><td colspan="${colCount}" class="cell-msg">No serial records found.</td></tr>`;
    document.getElementById('serialCount').textContent = '0 serials';
    selectSerialRow(null);
    return;
  }
  if (selectedSerialNo && !rows.some((r) => r.SerialNo === selectedSerialNo)) selectedSerialNo = null;

  // Status stays otherwise read-only here - it's owned by whichever workflow moved the serial
  // (Stock Counts, Transfer Order shipment tagging, a sale, etc.) and editing it freely could
  // desync it from that workflow's own state. Serial Admins get two narrow, targeted exceptions -
  // "Mark In Stock" to restore a mistakenly SOLD/RETURNED/IN_TRANSIT serial back to IN_STOCK, and
  // "Mark Sold" for the reverse (a sale that happened without going through the normal POS/online
  // flow, e.g. a walk-in the desktop sync hasn't caught up on yet) - neither is a general status
  // editor, and "Mark Sold" here deliberately leaves SoldReceiptNo/SoldOnlineOrderId blank since
  // there's no real receipt/order behind a manual override. Location's own Edit control is the
  // other exception, same admin gate. Both Mark buttons only show when the serial's current
  // Location already matches the admin's own warehouse - acting on a serial physically tagged to
  // a DIFFERENT store here would misrepresent stock that isn't actually on hand locally.
  // Business Central list look (css/bc-list.css .bc-grid), same as Online Orders: no buttons in the
  // rows - click a row to select it and use the action bar (updateSerialActionState); the Serial No.
  // opens its card. Sold Receipt / Sold Online share one "Sold To" column and the update date / user
  // share "Last Updated".
  document.getElementById('serialCount').textContent = `${rows.length.toLocaleString()} serial${rows.length === 1 ? '' : 's'}`;
  const sub = (text) => (text ? `<div class="muted" style="font-size:11px; line-height:1.3;">${text}</div>` : '');
  tbody.innerHTML = rows
    .map((r) => {
      const soldTo = r.SoldReceiptNo
        ? `${escapeHtml(r.SoldReceiptNo)}${sub('POS receipt')}`
        : r.SoldOnlineOrderId
          ? `${escapeHtml(r.SoldOnlineOrderId)}${sub('Online order')}`
          : '<span class="muted">-</span>';
      return `
      <tr class="clickable-row${r.SerialNo === selectedSerialNo ? ' selected' : ''}" data-serial="${encodeURIComponent(r.SerialNo)}">
        ${canBulkFloat ? `<td><input type="checkbox" class="serial-tick" aria-label="Tick ${escapeHtml(r.SerialNo)}"${checkedSerialNos.has(r.SerialNo) ? ' checked' : ''} /></td>` : ''}
        <td style="white-space:nowrap;"><a href="#" class="bc-doc-no" data-open-serial="${encodeURIComponent(r.SerialNo)}">${escapeHtml(r.SerialNo)}</a>${reprintCountHtml(r)}</td>
        <td style="white-space:nowrap;">${escapeHtml(r.ItemCode)}</td>
        <td style="white-space:nowrap;">${escapeHtml(r.VariantSku) || '<span class="muted">-</span>'}${colourTagHtml(serialColour(r))}</td>
        <td class="cell-text" title="${escapeHtml(r.ItemDescription)}">${escapeHtml(r.ItemDescription)}</td>
        <td style="white-space:nowrap;">${escapeHtml(r.Location) || '<span class="muted">Unassigned</span>'}</td>
        <td style="white-space:nowrap;"><span class="badge ${statusBadgeClass(r.Status)}">${statusLabel(r.Status)}</span></td>
        <td style="white-space:nowrap;">${renderSourceDocCell(r.SourceDocumentNo) || '<span class="muted">-</span>'}</td>
        <td style="white-space:nowrap;">${r.Maker ? `${escapeHtml(r.Maker.maker_name || 'Not assigned')}${sub(`${r.Maker.part === 'stand' ? 'Stand' : 'Tank'} maker`)}` : '<span class="muted">-</span>'}</td>
        <td style="white-space:nowrap;">${soldTo}</td>
        <td style="white-space:nowrap;">${formatDateTime(r.UpdatedAtUtc) || '<span class="muted">-</span>'}${sub(escapeHtml(r.UpdatedBy))}</td>
      </tr>
    `;
    })
    .join('');
  fitGridToViewport();
  updateSerialActionState();
}

// ---- Selection + action bar (same pattern as Online Orders' selectOrderRow / updateOrderActionState)

function selectedSerialRow() {
  return selectedSerialNo ? allSerials.find((r) => r.SerialNo === selectedSerialNo) || null : null;
}

function selectSerialRow(serialNo) {
  selectedSerialNo = serialNo;
  document.querySelectorAll('#serialTableBody tr[data-serial]').forEach((tr) => {
    tr.classList.toggle('selected', decodeURIComponent(tr.dataset.serial) === serialNo);
  });
  updateSerialActionState();
}

// Same permission rules the old per-row links used: Reprint (Super User / Production Manager), Edit
// Location (Serial Admin), Mark In Stock (canMarkInStock), Mark Sold (Serial Admin, own warehouse,
// In Stock only). Buttons a user can never use stay hidden; the rest enable for the selected row.
function updateSerialActionState() {
  const r = selectedSerialRow();
  const setBtn = (id, visible, enabled, title) => {
    const btn = document.getElementById(id);
    btn.classList.toggle('hidden', !visible);
    btn.disabled = !enabled;
    if (title !== undefined) btn.title = title;
  };
  document.getElementById('openSerialBtn').disabled = !r;
  setBtn('reprintBtn', canReprintLabels, !!r);
  setBtn('editLocationBtn', isSerialAdmin, !!r);
  const canMarkAnySold = isSerialAdmin || isSuperUserSession();
  setBtn('markInStockBtn', canMarkAnySold, !!r && canMarkInStock(r),
    r && (r.Status || '').toUpperCase() === 'SOLD' && !isSuperUserSession()
      ? 'Only a Super User can put a Sold serial back In Stock' : 'Mark the selected serial In Stock');
  setBtn('markSoldBtn', isSerialAdmin, !!r && isOwnWarehouseLocation(r.Location) && (r.Status || '').toUpperCase() === 'IN_STOCK',
    'Mark the selected In Stock serial Sold (own warehouse only)');
  document.getElementById('adminCmdSep').classList.toggle('hidden', !(canReprintLabels || isSerialAdmin || canMarkAnySold || canBulkFloat));

  // Mark Floating / Release: the ticked serials, else the selected row.
  const bulkCount = checkedSerialNos.size || (r ? 1 : 0);
  const countSuffix = checkedSerialNos.size ? ` (${checkedSerialNos.size})` : '';
  setBtn('floatSerialsBtn', canBulkFloat, bulkCount > 0);
  setBtn('releaseSerialsBtn', canBulkFloat, bulkCount > 0);
  document.getElementById('floatSerialsLabel').textContent = `Mark Floating${countSuffix}`;
  document.getElementById('releaseSerialsLabel').textContent = `Release${countSuffix}`;
  const selectAll = document.getElementById('selectAllSerials');
  selectAll.checked = visibleSerialNos.length > 0 && checkedSerialNos.size === visibleSerialNos.length;
  selectAll.indeterminate = checkedSerialNos.size > 0 && checkedSerialNos.size < visibleSerialNos.length;
}

// Super User bulk Mark Floating / Release (supabase_serial_bulk_floating.sql). FLOATING = can't be
// sold (every picker only offers IN_STOCK); Release puts Floating serials back IN_STOCK. Sold / In
// Transit ones are skipped by the server.
async function bulkSetSerialStatus(status, btn) {
  const serialNos = checkedSerialNos.size ? [...checkedSerialNos] : (selectedSerialNo ? [selectedSerialNo] : []);
  if (!serialNos.length || !canBulkFloat) return;
  const floating = status === 'FLOATING';
  const plural = serialNos.length === 1 ? '' : 's';
  const preview = serialNos.slice(0, 10).join('\n') + (serialNos.length > 10 ? `\n...and ${serialNos.length - 10} more` : '');
  if (!confirm(floating
    ? `Mark ${serialNos.length} serial${plural} Floating?\n\n${preview}\n\n`
      + "They stay in the list but can't be picked for a sale anywhere (POS included) until released. "
      + 'Sold and In Transit serials are skipped. The Item Ledger is not changed.'
    : `Release ${serialNos.length} serial${plural} back In Stock?\n\n${preview}\n\nOnly Floating serials are changed.`)) return;

  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_bulk_set_serial_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_serial_nos: serialNos,
    p_status: status
  });
  btn.disabled = false;
  if (error) {
    alert(`Could not update: ${error.message}`);
    return;
  }

  const results = data || [];
  const changed = results.filter((x) => x.changed).length;
  const skipped = results.filter((x) => !x.changed);
  checkedSerialNos.clear();
  alert(`${floating ? 'Marked Floating' : 'Released'}: ${changed} serial${changed === 1 ? '' : 's'}.`
    + (skipped.length
      ? `\n\nSkipped ${skipped.length}:\n` + skipped.slice(0, 15).map((x) => `${x.serial_no} - ${x.reason}`).join('\n')
        + (skipped.length > 15 ? `\n...and ${skipped.length - 15} more` : '')
      : ''));
  await loadSerials();
}

function wireSerialListActions() {
  const tbody = document.getElementById('serialTableBody');
  tbody.addEventListener('click', (event) => {
    const tick = event.target.closest('.serial-tick');
    if (tick) {
      const serialNo = decodeURIComponent(tick.closest('tr[data-serial]').dataset.serial);
      if (tick.checked) checkedSerialNos.add(serialNo);
      else checkedSerialNos.delete(serialNo);
      updateSerialActionState();
      return;
    }
    const openLink = event.target.closest('[data-open-serial]');
    if (openLink) {
      event.preventDefault();
      const serialNo = decodeURIComponent(openLink.dataset.openSerial);
      selectSerialRow(serialNo);
      openSerialCard(serialNo);
      return;
    }
    const docLink = event.target.closest('.source-doc-link');
    if (docLink) {
      event.preventDefault();
      resolveAndOpenSourceDoc(decodeURIComponent(docLink.dataset.docNo));
      return;
    }
    const tr = event.target.closest('tr[data-serial]');
    if (tr) selectSerialRow(decodeURIComponent(tr.dataset.serial));
  });
  tbody.addEventListener('dblclick', (event) => {
    const tr = event.target.closest('tr[data-serial]');
    if (tr && !event.target.closest('a')) openSerialCard(decodeURIComponent(tr.dataset.serial));
  });

  document.getElementById('openSerialBtn').addEventListener('click', () => selectedSerialNo && openSerialCard(selectedSerialNo));
  document.getElementById('reprintBtn').addEventListener('click', (e) => selectedSerialNo && reprintSerialLabel(selectedSerialNo, e.currentTarget));
  document.getElementById('editLocationBtn').addEventListener('click', () => {
    const r = selectedSerialRow();
    if (r) openEditLocationModal(r.SerialNo, r.Location || '');
  });
  document.getElementById('markInStockBtn').addEventListener('click', () => selectedSerialNo && markInStock(selectedSerialNo));
  document.getElementById('markSoldBtn').addEventListener('click', () => selectedSerialNo && markSold(selectedSerialNo));
  document.getElementById('floatSerialsBtn').addEventListener('click', (e) => bulkSetSerialStatus('FLOATING', e.currentTarget));
  document.getElementById('releaseSerialsBtn').addEventListener('click', (e) => bulkSetSerialStatus('IN_STOCK', e.currentTarget));
  document.getElementById('selectAllSerials').addEventListener('change', (e) => {
    if (e.target.checked) visibleSerialNos.forEach((sn) => checkedSerialNos.add(sn));
    else checkedSerialNos.clear();
    document.querySelectorAll('#serialTableBody .serial-tick').forEach((box) => { box.checked = e.target.checked; });
    updateSerialActionState();
  });
}

// ---- Serial card (read-only)

function openSerialCard(serialNo) {
  const r = allSerials.find((row) => row.SerialNo === serialNo);
  if (!r) return;
  document.getElementById('serialCardTitle').textContent = r.SerialNo;
  const badge = document.getElementById('serialCardStatus');
  badge.textContent = statusLabel(r.Status);
  badge.className = `badge ${statusBadgeClass(r.Status)}`;

  const dash = '<span class="muted">-</span>';
  const field = (label, html) => `<div class="form-row"><label>${label}</label><div>${html || dash}</div></div>`;
  const p = r.Reprints;
  document.getElementById('serialCardFields').innerHTML = [
    field('Item', escapeHtml(r.ItemCode)),
    field('SKU', `${escapeHtml(r.VariantSku)}${colourTagHtml(serialColour(r))}`),
    field('Description', escapeHtml(r.ItemDescription)),
    field('Variant', escapeHtml(r.VariantCode)),
    field('Location', escapeHtml(r.Location) || '<span class="muted">Unassigned</span>'),
    field('Source Doc.', renderSourceDocCell(r.SourceDocumentNo)),
    field('Maker', r.Maker ? `${escapeHtml(r.Maker.maker_name || 'Not assigned')} <span class="muted">(${r.Maker.part === 'stand' ? 'Stand' : 'Tank'} maker)</span>` : ''),
    field('Sold To', r.SoldReceiptNo ? `${escapeHtml(r.SoldReceiptNo)} <span class="muted">(POS receipt)</span>`
      : r.SoldOnlineOrderId ? `${escapeHtml(r.SoldOnlineOrderId)} <span class="muted">(Online order)</span>` : ''),
    field('Created', escapeHtml(formatDateTime(r.CreatedAtUtc))),
    field('Last Updated', `${escapeHtml(formatDateTime(r.UpdatedAtUtc))}${r.UpdatedBy ? ` <span class="muted">by ${escapeHtml(r.UpdatedBy)}</span>` : ''}`),
    field('Label Reprints', p && p.reprint_count ? `${p.reprint_count}&times; <span class="muted">(last ${escapeHtml(formatDateTime(p.last_reprinted_at))}${p.last_reprinted_by ? ` by ${escapeHtml(p.last_reprinted_by)}` : ''})</span>` : '')
  ].join('');

  document.getElementById('serialCardFields').querySelectorAll('.source-doc-link').forEach((link) => {
    link.addEventListener('click', (event) => {
      event.preventDefault();
      resolveAndOpenSourceDoc(decodeURIComponent(link.dataset.docNo));
    });
  });
  document.getElementById('serialCardModal').classList.remove('hidden');
}

// ---- Status view tabs

function syncStatusTabs() {
  const status = document.getElementById('statusFilter').value;
  document.querySelectorAll('#statusTabs [data-status]').forEach((tab) => {
    tab.classList.toggle('active', tab.dataset.status === status);
  });
}

// One exact count per status at the location being viewed (own-warehouse restriction / Location
// filter) - head-only counts, so nothing is downloaded. Not narrowed by search / category, same as
// Online Orders' status tabs counting the whole list.
let statusCountsSeq = 0;
async function loadStatusCounts() {
  const seq = ++statusCountsSeq;
  const location = locationFilterValue() || ownWarehouseRestriction();
  const tabs = Array.from(document.querySelectorAll('#statusTabs [data-count]'));
  const results = await Promise.all(tabs.map(async (el) => {
    let query = supabaseClient.from('ItemSerialTracking').select('SerialNo', { count: 'exact', head: true });
    if (el.dataset.count) query = query.eq('Status', el.dataset.count);
    if (location) query = query.eq('Location', location);
    const { count, error } = await query;
    return error ? null : count;
  }));
  if (seq !== statusCountsSeq) return; // a newer filter change already asked again
  tabs.forEach((el, i) => { el.textContent = results[i] == null ? '-' : results[i].toLocaleString(); });
}

function wireStatusTabsAndFilterPane() {
  document.querySelectorAll('#statusTabs [data-status]').forEach((tab) => {
    tab.addEventListener('click', () => {
      const select = document.getElementById('statusFilter');
      // Clicking the active tab again clears it (All).
      select.value = select.value === tab.dataset.status ? '' : tab.dataset.status;
      loadSerials();
    });
  });

  let filterPaneOpen = true;
  document.getElementById('filterPaneBtn').addEventListener('click', () => {
    filterPaneOpen = !filterPaneOpen;
    document.getElementById('filterPane').classList.toggle('hidden', !filterPaneOpen);
    document.getElementById('serialListView').classList.toggle('no-filterpane', !filterPaneOpen);
    document.getElementById('filterPaneBtn').setAttribute('aria-pressed', filterPaneOpen ? 'true' : 'false');
    fitGridToViewport();
  });

  document.getElementById('clearFiltersBtn').addEventListener('click', () => {
    document.getElementById('statusFilter').value = '';
    document.getElementById('categoryFilter').value = '';
    document.getElementById('locationFilter').value = '';
    urlVariantFilter = null;
    showWarehouseRestrictionNote();
    loadSerials();
  });
}

// "Showing serials at <store> only." for store staff limited to their own warehouse; hidden otherwise.
function showWarehouseRestrictionNote() {
  const note = document.getElementById('warehouseFilterNote');
  const own = ownWarehouseRestriction();
  note.textContent = own ? `Showing serials at ${own} only.` : '';
  note.classList.toggle('hidden', !own);
}

// Per "can you allow super user and production manager to reprint serials in Serial tracker": the
// same 100x30mm label Online Orders / Production Orders print (js/labelPrinter.js - QZ Tray to General
// Setup's Barcode Printer, else the print dialog), for any serial, tied to an order or not.
async function reprintSerialLabel(serialNo, btn) {
  const row = allSerials.find((r) => r.SerialNo === serialNo);
  if (!row || !canReprintLabels) return;
  btn.disabled = true;
  try {
    const result = await LabelPrinter.printSerialLabels([{
      serialNo: row.SerialNo, itemCode: row.ItemCode, description: row.ItemDescription, sku: row.VariantSku || undefined
    }]);
    if (result.via !== 'qz') console.info('Serial label:', result.message);
    if (result.via !== 'none') await logSerialReprint(row);
  } catch (err) {
    alert(`Could not print the label: ${err?.message || err}`);
  } finally {
    btn.disabled = false;
  }
}

// Counts the reprint (supabase_serial_label_reprints.sql) - a failure never blocks the print itself.
async function logSerialReprint(row) {
  const { data, error } = await supabaseClient.rpc('staff_log_serial_label_reprint', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_serial_no: row.SerialNo
  });
  if (error) { console.warn('staff_log_serial_label_reprint:', error.message); return; }
  row.Reprints = {
    reprint_count: Number(data) || 0,
    last_reprinted_at: new Date().toISOString(),
    last_reprinted_by: currentSession.username
  };
  renderSerials();
}

// Per "in the serial tracker once its sold dont let it mark in stock unless if your a super user": a
// SOLD serial is a unit that left with a customer, so putting it back In Stock is Super User only (and
// they may do it from any location - e.g. a return handled from head office). Every other status
// (Returned, In Transit, Reserved...) keeps the Serial Admin + own-warehouse rule.
function isSuperUserSession() {
  return !!currentSession?.isSuperUser;
}

function canMarkInStock(r) {
  const statusUpper = (r.Status || '').toUpperCase();
  if (statusUpper === 'IN_STOCK') return false;
  if (statusUpper === 'SOLD') return isSuperUserSession();
  return isSerialAdmin && isOwnWarehouseLocation(r.Location);
}

async function markInStock(serialNo) {
  // Re-check against the row itself, not just the (already-filtered) button that was clicked -
  // matches saveEditLocation's own defensive re-check rather than trusting the DOM alone.
  const row = allSerials.find((r) => r.SerialNo === serialNo);
  if (!row || !canMarkInStock(row)) {
    alert((row?.Status || '').toUpperCase() === 'SOLD'
      ? 'This serial is already SOLD - only a Super User can put a sold serial back In Stock.'
      : 'This serial is tagged to a different warehouse - it can only be marked In Stock from its own location.');
    renderSerials();
    return;
  }
  if ((row.Status || '').toUpperCase() === 'SOLD'
    && !confirm(`${serialNo} is SOLD${row.SoldReceiptNo ? ` (receipt ${row.SoldReceiptNo})` : row.SoldOnlineOrderId ? ` (online order ${row.SoldOnlineOrderId})` : ''}.\n\nPutting it back In Stock means the unit is physically back on hand (e.g. a return). Continue?`)) return;

  if ((row.Status || '').toUpperCase() !== 'SOLD' && !confirm(`Mark ${serialNo} as IN_STOCK?`)) return;

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
  loadStatusCounts();
}

// Reverse of markInStock() - manually flips a serial to SOLD without a linked receipt/online
// order (SoldReceiptNo/SoldOnlineOrderId stay whatever they already were), for a sale that
// happened outside the normal POS/online flow. Only offered from IN_STOCK (see renderSerials) so
// this can't be used to relabel a serial that's already SOLD/IN_TRANSIT/etc - use Mark In Stock
// first to undo a mistake, then Mark Sold, rather than jumping straight status to status.
async function markSold(serialNo) {
  const row = allSerials.find((r) => r.SerialNo === serialNo);
  if (!row || !isOwnWarehouseLocation(row.Location)) {
    alert('This serial is tagged to a different warehouse - it can only be marked Sold from its own location.');
    renderSerials();
    return;
  }

  if (!confirm(`Mark ${serialNo} as SOLD? This does not link a receipt or online order - only use this for a sale that didn't go through the normal flow.`)) return;

  const { error } = await supabaseClient
    .from('ItemSerialTracking')
    .update({ Status: 'SOLD', UpdatedAtUtc: new Date().toISOString(), UpdatedBy: currentSession?.username || null })
    .eq('SerialNo', serialNo);

  if (error) {
    alert(`Failed to update status: ${error.message}`);
    return;
  }

  row.Status = 'SOLD';
  row.UpdatedAtUtc = new Date().toISOString();
  row.UpdatedBy = currentSession?.username || null;
  renderSerials();
  loadStatusCounts();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Serial Tracker');

  isProductionWarehouseUser = await resolveIsProductionWarehouse(session);
  isSerialAdmin = !!session.isSerialAdmin;
  canReprintLabels = !!(session.isSuperUser || session.isProductionManager) && !!window.LabelPrinter;
  canBulkFloat = !!session.isSuperUser;
  document.getElementById('selectAllHead').classList.toggle('hidden', !canBulkFloat);
  if (canReprintLabels) LabelPrinter.init(session);

  // Serial Admins always see every warehouse (see renderSerials), so the "restricted to your own
  // warehouse" note would be inaccurate for them even though they're non-production. Store staff
  // limited to their own warehouse get no Location filter - there's nothing else for them to pick.
  showWarehouseRestrictionNote();
  if (ownWarehouseRestriction()) {
    document.getElementById('locationFilterField').classList.add('hidden');
  } else {
    await loadWarehouseOptionsOnce();
  }

  await loadCategoryOptionsOnce();

  // Deep link from Inventory Summary's clickable counts (see inventorySummary.js) - pre-fills the
  // search / status / location filters so clicking a count there lands here already narrowed to
  // exactly those units.
  const urlParams = new URLSearchParams(window.location.search);
  const urlItem = urlParams.get('item');
  const urlStatus = urlParams.get('status');
  const urlLocation = urlParams.get('location');
  const urlVariant = urlParams.get('variant');
  if (urlItem) document.getElementById('searchInput').value = urlItem;
  if (urlStatus) document.getElementById('statusFilter').value = urlStatus;
  if (urlVariant) urlVariantFilter = urlVariant;
  if (!ownWarehouseRestriction()) fillLocationFilter(urlLocation || '');
  if (urlLocation || urlVariant) {
    const note = document.getElementById('warehouseFilterNote');
    note.innerHTML = `Filtered from Inventory Summary${urlLocation ? ` - location: ${escapeHtml(urlLocation)}` : ''}${urlVariant ? `, variant: ${escapeHtml(urlVariant)}` : ''} - <a href="serial-tracker.html">Clear</a>`;
    note.classList.remove('hidden');
  }

  // Debounced re-fetch (not just a local re-render) - search/status now filter server-side, via
  // loadSerials(), so typing a search term can find rows outside whatever page loaded initially.
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(serialSearchDebounceHandle);
    serialSearchDebounceHandle = setTimeout(loadSerials, 300);
  });
  document.getElementById('statusFilter').addEventListener('change', loadSerials);
  document.getElementById('categoryFilter').addEventListener('change', loadSerials);
  document.getElementById('locationFilter').addEventListener('change', loadSerials);
  document.getElementById('refreshBtn').addEventListener('click', loadSerials);
  wireSerialListActions();
  wireStatusTabsAndFilterPane();
  document.getElementById('closeSerialCardBtn').addEventListener('click', () =>
    document.getElementById('serialCardModal').classList.add('hidden')
  );
  window.addEventListener('resize', fitGridToViewport);
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
