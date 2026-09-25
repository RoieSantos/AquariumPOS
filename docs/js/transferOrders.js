// Transfer Orders page logic.
// Tables: Transfer_Header ("No.", "Description", "Status", "Requested Date",
// "Estimated Delivery Date", "Transfer Date", "Receive Date",
// "From Warehouse ID", "From Warehouse", "To Warehouse ID", "To Warehouse",
// "Category Code", "Use Production Category", "Posted Date", "Sent To Online",
// "Is Locked", "Locked At", "Locked By")
// Transfer_Line ("Document No.", "Item No.", "Variant ID", "Description",
// "CategoryCode", "Line No.", "Available QTY", "Qty To Transfer",
// "Qty To Ship", "Qty Shipped", "Qty To Receive", "Qty Received")
// "Qty To Ship"/"Qty Shipped" are portal-only (added via supabase_transfer_orders_qty_columns.sql,
// not present on the desktop's Transfer Line tables). "Is Locked"/"Locked At"/"Locked By" are also
// portal-only (supabase_transfer_orders_lock_column.sql) - set automatically at creation time
// (saveNewTransfer below), shown as a lock icon on the list/Manage modal, and hides Cancel Order
// (so Cancel is effectively never available via the portal once an order exists - only Ship/
// Receive remain).
//
// Supports partial ship/receive: "Qty Shipped"/"Qty Received" are running cumulative totals, not
// one-time snapshots. Each Ship/Receive click adds whatever's entered (capped at the remaining
// unshipped/unreceived amount) to that running total, so an order can be shipped/received across
// several separate actions. "Qty To Ship"/"Qty To Receive" hold just the most recent increment,
// for reference. An order only reaches "Received" once every line's cumulative Qty Received
// equals its Qty To Transfer.
//
// These are the same tables the desktop app's TR- "Transfer Request" flow reads/writes, but the
// portal runs its own standalone status workflow rather than the desktop's Status vocabulary/
// posting logic - a deliberate choice so the portal doesn't need to track desktop-internal
// concepts (Sent To Online/Posted Date/Remote Transfer ID are never touched here).
//
// Status vocabulary: Requested -> Partial Shipped -> In-Transit (fully shipped, nothing received
// yet) -> Partial Received -> Received. Cancelled is available any time before Received. The
// "Partial" statuses reflect partial ship/receive (see computeAggregateStatus) - status is
// recomputed from cumulative line quantities after every Ship/Receive action, not just advanced
// linearly, so it always reflects the true state of all lines combined.
//
// "Received" is a transient status, not a resting state: the instant an order reaches it (see
// receiveTransferOrder), it's archived into Posted_Transfer_Header/Posted_Transfer_Line (exact
// schema copies - see supabase_posted_transfer_orders_tables.sql) and deleted from
// Transfer_Header/Transfer_Line. From then on it no longer appears on this page at all - the
// Posted tables are its permanent record.

let allHeaders = [];
let currentSession = null;

// Persist list-page filters across a real browser refresh (sessionStorage, not localStorage -
// clears per-tab close so a stale filter doesn't silently hide new orders in a future session).
const FILTERS_STORAGE_KEY = 'transferOrders.filters';

// Business Central-style Maximize for the two document modals, same treatment as the Purchase
// Order card (see the design comment in styles.css) - Manage and New are different jobs so each
// remembers its own layout separately.
const TO_MANAGE_MAXIMIZED_KEY = 'to-manage-modal-maximized';
const TO_NEW_MAXIMIZED_KEY = 'to-new-modal-maximized';
const TO_MANAGE_GENERAL_TAB_KEY = 'to-manage-general-tab-open';
const TO_NEW_GENERAL_TAB_KEY = 'to-new-general-tab-open';

function readStoredFlag(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value === null ? fallback : value === '1';
  } catch (err) {
    return fallback;
  }
}

function writeStoredFlag(key, value) {
  try {
    localStorage.setItem(key, value ? '1' : '0');
  } catch (err) {
    /* Preference simply won't persist - not worth surfacing. */
  }
}

// Shown on the New Transfer Order's General tab only while it is collapsed - same reasoning as
// the PO card's General tab summary.
function refreshNewTransferGeneralSummary() {
  const no = document.getElementById('newNo').value.trim();
  const description = document.getElementById('newDescription').value.trim();
  const fromWarehouse = document.getElementById('newFromWarehouse').value.trim();
  const toWarehouse = document.getElementById('newToWarehouse').value.trim();

  document.getElementById('newTransferGeneralSummary').textContent = [
    no && no !== 'Generating...' ? no : null,
    description,
    fromWarehouse && toWarehouse ? `${fromWarehouse} → ${toWarehouse}` : null
  ].filter(Boolean).join(' · ');
}

function applyModalMaximized(modalId, btnId, maximized) {
  const modal = document.getElementById(modalId);
  modal.classList.toggle('modal-maximized', maximized);
  modal.querySelector('.modal-panel').classList.toggle('modal-maximized', maximized);

  const btn = document.getElementById(btnId);
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized
    ? 'Restore this document to a window'
    : 'Maximize this document to fill the window';
}

function saveFilters() {
  const filters = {
    search: document.getElementById('searchInput').value,
    status: document.getElementById('statusFilter').value
  };
  sessionStorage.setItem(FILTERS_STORAGE_KEY, JSON.stringify(filters));
}

function restoreFilters() {
  const raw = sessionStorage.getItem(FILTERS_STORAGE_KEY);
  if (!raw) return;
  try {
    const filters = JSON.parse(raw);
    document.getElementById('searchInput').value = filters.search || '';
    document.getElementById('statusFilter').value = filters.status || '';
  } catch {
    // Ignore malformed/stale storage.
  }
}

// Page sizes match staff_search_items/staff_search_variants' own p_limit defaults - the RPCs
// don't echo back the limit they used, so the dropdown pagers compute total pages against these.
const ITEM_LOOKUP_PAGE_SIZE = 20;
const VARIANT_LOOKUP_PAGE_SIZE = 50;

function statusBadgeClass(status) {
  switch ((status || '').toLowerCase()) {
    case 'received': return 'badge-success';
    case 'cancelled': return 'badge-danger';
    case 'requested': return 'badge-warning';
    case 'in-transit': return 'badge-neutral';
    case 'in transit': return 'badge-neutral'; // legacy spelling on orders shipped before the "In-Transit" rename
    case 'partial shipped': return 'badge-primary';
    case 'partial received': return 'badge-purple';
    default: return 'badge-neutral';
  }
}

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}

// "Today" as a yyyy-mm-dd string in the browser's local calendar date - NOT
// `new Date().toISOString().slice(0, 10)`, which converts to UTC first and silently rolls back
// to "yesterday" for any local time before UTC midnight (e.g. every local time before 8:00 AM in
// the Philippines, UTC+8). Every "today" written to Transfer_Header should go through this.
function todayLocalDateString() {
  const date = new Date();
  const yyyy = date.getFullYear();
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

async function loadHeaders() {
  const tbody = document.getElementById('headerTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .order('Requested Date', { ascending: false })
    .limit(300);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    return;
  }

  allHeaders = data || [];
  renderHeaders();
}

function renderHeaders() {
  const tbody = document.getElementById('headerTableBody');
  const search = document.getElementById('searchInput').value.trim().toLowerCase();
  const statusFilter = document.getElementById('statusFilter').value;

  // Always scoped to the staff's own warehouse (From or To) - no "show all" override. Staff with
  // no assigned warehouse (access to all) still see everything.
  let rows = allHeaders;
  if (currentSession?.warehouseName) {
    rows = rows.filter((r) =>
      (r['From Warehouse'] || '') === currentSession.warehouseName ||
      (r['To Warehouse'] || '') === currentSession.warehouseName
    );
  }
  if (statusFilter) {
    // Supports a comma-separated "multi-status" filter value (see the "Awaiting Receipt" option
    // in transfer-orders.html and dashboard.js's receiving notification) alongside the normal
    // single-status options - both just narrow to "Status is one of these".
    const statusList = statusFilter.split(',');
    rows = rows.filter((r) => statusList.includes(r['Status'] || ''));
  }
  if (search) {
    rows = rows.filter((r) =>
      [r['No.'], r['Description'], r['From Warehouse'], r['To Warehouse']]
        .some((v) => (v || '').toString().toLowerCase().includes(search))
    );
  }

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No transfer orders found.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((r) => `
      <tr class="clickable-row" data-doc-no="${encodeURIComponent(r['No.'] || '')}">
        <td>${r['Is Locked'] ? '<span title="Locked - no more changes except Ship/Receive">🔒</span> ' : ''}${r['No.'] || ''}</td>
        <td>${r['Description'] || ''}</td>
        <td><span class="badge ${statusBadgeClass(r['Status'])}">${r['Status'] || ''}</span></td>
        <td>${r['From Warehouse'] || ''}</td>
        <td>${r['To Warehouse'] || ''}</td>
        <td>${formatDate(r['Requested Date'])}</td>
        <td>${formatDate(r['Estimated Delivery Date'])}</td>
        <td>${formatDate(r['Transfer Date'])}</td>
        <td>${formatDate(r['Receive Date'])}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('tr[data-doc-no]').forEach((row) => {
    row.addEventListener('click', () => openManageModal(decodeURIComponent(row.dataset.docNo)));
  });
}

// Manage Transfer Order modal - view + the portal's own standalone Ship/Receive/Cancel
// workflow (Requested -> In-Transit -> Received, Cancelled available any time before Received).
// Deliberately NOT tied to the desktop's Status vocabulary or posting logic - see the plan doc
// for why (the two apps just happen to share the same Transfer_Header/Transfer_Line tables).
let currentManageDocNo = null;
let currentManageHeader = null;
let currentManageIsOwnToWarehouse = false;
let currentManageIsOwnFromWarehouse = false;
let currentManageHasAnyShipped = false;
let currentManageIsLocked = false;
// Resolved once at login (see resolveIsProductionWarehouse) - whether currentSession's own
// warehouse is flagged Production. Combined with currentManageIsOwnFromWarehouse below to decide
// who's allowed to search/pick serials for Ship: the requester (To Warehouse) never can, and even
// the shipper (From Warehouse) only can if that warehouse is itself a Production warehouse -
// non-production "Stock" warehouses ship things out too, but don't hold/generate serial-tracked
// production stock, so they have nothing legitimate to pick from.
let currentSessionIsProductionWarehouse = true;
let currentManageCanManageSerials = true;
// Item Nos on the currently-open order whose Category is a Production Category (see
// staff_get_item_production_flags in supabase_transfer_order_serial_tagging.sql) - these are the
// lines that require picking existing serials before Ship, mirroring the same IsProductionCategory
// flag Stock Counts now filters on (StockCountsForm.cs).
let currentManageProductionItemCodes = new Set();

function lineRemainingToShip(l) {
  return Math.max(0, (Number(l['Qty To Transfer']) || 0) - (Number(l['Qty Shipped']) || 0));
}

function lineRemainingToReceive(l) {
  return Math.max(0, (Number(l['Qty Shipped']) || 0) - (Number(l['Qty Received']) || 0));
}

// Ship/Receive are only ever blocked outright by status once an order is done (Received) or
// abandoned (Cancelled) - every other status (Requested, Partial Shipped, In-Transit, Partial
// Received) still allows either action, gated for real by whether any line has a remaining
// balance (see lineRemainingToShip/lineRemainingToReceive).
function isActiveStatus(status) {
  return status !== 'Received' && status !== 'Cancelled';
}

// Recomputes the header Status from cumulative line quantities after a Ship/Receive action -
// reflects the true combined state of all lines rather than assuming a linear progression, so it
// correctly reports e.g. "Partial Received" even if some lines are still unshipped while others
// have already been fully received.
function computeAggregateStatus(lineStates) {
  const totalToTransfer = lineStates.reduce((sum, l) => sum + l.qtyToTransfer, 0);
  const totalShipped = lineStates.reduce((sum, l) => sum + l.qtyShipped, 0);
  const totalReceived = lineStates.reduce((sum, l) => sum + l.qtyReceived, 0);

  if (totalReceived > 0 && totalReceived >= totalToTransfer) return 'Received';
  if (totalReceived > 0) return 'Partial Received';
  if (totalShipped > 0 && totalShipped >= totalToTransfer) return 'In-Transit';
  if (totalShipped > 0) return 'Partial Shipped';
  return 'Requested';
}

function renderManageHeader(header) {
  const status = header['Status'] || 'Requested';
  const badge = document.getElementById('viewLinesStatusBadge');
  badge.textContent = status;
  badge.className = `badge ${statusBadgeClass(status)}`;

  document.getElementById('viewFromWarehouse').textContent = header['From Warehouse'] || '';
  document.getElementById('viewToWarehouse').textContent = header['To Warehouse'] || '';
  document.getElementById('viewRequestedDate').textContent = formatDate(header['Requested Date']);
  // Transfer Date/Receive Date are set automatically by the first Ship/Receive action (today's
  // date), not manually entered - shown here as plain read-only text, same as the warehouse
  // fields. They don't change on later partial ship/receive actions for the same order.
  document.getElementById('viewTransferDate').textContent = formatDate(header['Transfer Date']);
  document.getElementById('viewReceiveDate').textContent = formatDate(header['Receive Date']);

  // Shown on the General tab only while it is collapsed, so folding it away never costs you the
  // fields you most need while working the lines - same reasoning as the PO card's General tab.
  document.getElementById('viewLinesGeneralSummary').textContent = [
    header['From Warehouse'] && `From: ${header['From Warehouse']}`,
    header['To Warehouse'] && `To: ${header['To Warehouse']}`
  ].filter(Boolean).join(' · ');

  // Staff at the destination (To) warehouse requested the order and will receive it, but can't
  // also ship it to themselves - shipping happens at the source (From) warehouse, by someone
  // else. Symmetrically, staff at the source (From) warehouse ship it out but can't also receive
  // it - receiving happens at the destination, by someone else. Staff with no assigned warehouse
  // (access to all) aren't restricted either way. Matched case/whitespace-insensitively - a
  // strict === here would silently and permanently deny both actions on any order whose warehouse
  // text differs from the staff's assigned name by only a rename or stray space.
  currentManageIsOwnToWarehouse = !!(
    currentSession?.warehouseName && warehouseNamesMatch(header['To Warehouse'], currentSession.warehouseName)
  );
  currentManageIsOwnFromWarehouse = !!(
    currentSession?.warehouseName && warehouseNamesMatch(header['From Warehouse'], currentSession.warehouseName)
  );

  // Only the shipper (From Warehouse) can search/pick serials at all - the requester (To
  // Warehouse) never can, per direct instruction - and even the shipper only can if their own
  // warehouse is flagged Production, since non-production "Stock" warehouses don't hold/generate
  // serial-tracked production stock to pick from. Staff with no assigned warehouse (access to
  // all) stay unrestricted, matching how currentManageIsOwnToWarehouse/currentManageIsOwnFromWarehouse
  // already treat them above.
  currentManageCanManageSerials = !currentSession?.warehouseName
    || (currentManageIsOwnFromWarehouse && currentSessionIsProductionWarehouse);

  currentManageIsLocked = !!header['Is Locked'];
  const lockIcon = document.getElementById('viewLinesLockIcon');
  lockIcon.classList.toggle('hidden', !currentManageIsLocked);
  lockIcon.title = header['Locked By']
    ? `Locked by ${header['Locked By']} - no more changes except Ship/Receive`
    : 'Locked - no more changes except Ship/Receive';
}

function warehouseNamesMatch(a, b) {
  return (a || '').trim().toLowerCase() === (b || '').trim().toLowerCase();
}

// Ship/Receive buttons depend on both the header status and whether any line still has a
// remaining balance to ship/receive - needs the fetched lines, not just the header, so this
// runs after renderManageLines rather than as part of renderManageHeader.
function updateManageActionButtons(status, lines) {
  const active = isActiveStatus(status);
  const hasRemainingToShip = active && lines.some((l) => lineRemainingToShip(l) > 0);
  const hasRemainingToReceive = active && lines.some((l) => lineRemainingToReceive(l) > 0);
  currentManageHasAnyShipped = lines.some((l) => (Number(l['Qty Shipped']) || 0) > 0);

  // Don't just let staff click into a guaranteed "not authorized to select serials" error -
  // requester and non-production-shipper staff never get a working Ship button on an order that
  // still needs a Production Category line shipped (see currentManageCanManageSerials).
  const hasUnmanageableSerialRequirement = active && !currentManageCanManageSerials && lines.some((l) =>
    lineRemainingToShip(l) > 0 && currentManageProductionItemCodes.has(l['Item No.'])
  );

  document.getElementById('shipTransferBtn').classList.toggle(
    'hidden',
    !hasRemainingToShip || currentManageIsOwnToWarehouse || hasUnmanageableSerialRequirement
  );
  document.getElementById('receiveTransferBtn').classList.toggle(
    'hidden',
    !hasRemainingToReceive || currentManageIsOwnFromWarehouse
  );
  // Cancelling is the requester's call, not the shipper's - staff at the source (From) warehouse
  // can ship but not cancel, same restriction shape as them not being able to receive either.
  // Once anything has shipped (even partially), cancelling is off the table entirely for
  // everyone - there's already stock physically moving, so the order has to be seen through.
  // Locking also blocks it - since every order is locked from the moment it's requested (see
  // saveNewTransfer), this means Cancel Order is effectively never shown via the portal; per
  // direct instruction, cancellation is no longer a portal-side action once an order is locked.
  document.getElementById('cancelTransferBtn').classList.toggle(
    'hidden',
    !active || currentManageIsOwnFromWarehouse || currentManageHasAnyShipped || currentManageIsLocked
  );

  // Create PO: only while something is still unshipped, and not for Store Managers - they have no
  // access to the Purchase Order pages (js/auth.js STORE_MANAGER_ALLOWED_PAGES), so a PO made here
  // would be one they can't open or print.
  document.getElementById('createPoFromTransferBtn').classList.toggle(
    'hidden',
    !hasRemainingToShip || !!currentSession?.isStoreManager
  );

  // Super-user-only "Delete Order" - removes the header and lines outright. Only offered while
  // nothing has shipped: shipping/receiving write Item Ledger entries, which deleting the order
  // wouldn't undo. Any status qualifies (a Cancelled order can be deleted too).
  document.getElementById('deleteTransferBtn').classList.toggle(
    'hidden',
    !currentSession?.isSuperUser || currentManageHasAnyShipped
  );

  // Super-user-only "Change From Warehouse" - same active/not-yet-shipped gating as Cancel above,
  // for the same reason: once anything has physically shipped, the source it shipped from can't be
  // rewritten after the fact. Unlike Cancel, this has no currentManageIsOwnFromWarehouse
  // restriction - a super user can do this regardless of which warehouse they're assigned to.
  closeFromWarehouseEdit();
  document.getElementById('editFromWarehouseBtn').classList.toggle(
    'hidden',
    !currentSession?.isSuperUser || !active || currentManageHasAnyShipped
  );
}

function renderManageLines(lines, status) {
  const body = document.getElementById('viewLinesBody');
  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="10" class="muted">No line items.</td></tr>';
    return;
  }

  // Partial-friendly per-line qty pipeline:
  //   Qty To Transfer - intended qty, set at creation (never editable here).
  //   Qty To Ship     - editable input while there's a remaining unshipped balance; defaults to
  //                      that full remaining balance, but staff can enter less for a partial
  //                      shipment. Added to the Qty Shipped running total when Ship is clicked.
  //   Qty Shipped     - read-only running total of everything shipped so far.
  //   Qty To Receive  - editable input while there's a remaining unreceived (already-shipped)
  //                      balance; same partial pattern, added to Qty Received when Receive is
  //                      clicked.
  //   Qty Received    - read-only running total of everything received so far.
  const canShip = isActiveStatus(status);
  const canReceive = isActiveStatus(status);

  body.innerHTML = lines
    .map((l) => {
      const qtyToTransfer = Number(l['Qty To Transfer']) || 0;
      const qtyShipped = Number(l['Qty Shipped']) || 0;
      const qtyReceived = Number(l['Qty Received']) || 0;
      const remainingToShip = lineRemainingToShip(l);
      const remainingToReceive = lineRemainingToReceive(l);

      const qtyToShipCell = canShip && remainingToShip > 0
        ? `<input type="number" class="manage-qty-to-ship" min="0" max="${remainingToShip}" step="0.01" value="${remainingToShip}" />`
        : '';

      const qtyShippedCell = qtyShipped > 0 ? qtyShipped : '';

      const qtyToReceiveCell = canReceive && remainingToReceive > 0
        ? `<input type="number" class="manage-qty-to-receive" min="0" max="${remainingToReceive}" step="0.01" value="${remainingToReceive}" />`
        : '';

      const qtyReceivedCell = qtyReceived > 0 ? qtyReceived : '';

      // Only Production Category items need a serial picked per unit before they can ship (see
      // openManageModal's staff_get_item_production_flags call) - everything else just shows a
      // dash. Only from EXISTING available (IN_STOCK) serials, never generated here - see
      // supabase_transfer_order_serial_tagging.sql's header comment.
      const requiresSerials = canShip && remainingToShip > 0 && currentManageProductionItemCodes.has(l['Item No.']);
      let serialsCell = '<span class="muted">&mdash;</span>';
      if (requiresSerials && currentManageCanManageSerials) {
        serialsCell = `
          <div class="serial-tag-picker" data-required="${remainingToShip}" data-selected="[]">
            <div class="serial-tag-count muted">0 / ${remainingToShip} selected</div>
            <div class="serial-tag-chips"></div>
            <input type="text" class="serial-tag-search" placeholder="Search serial no..." autocomplete="off" />
            <div class="serial-tag-dropdown hidden"></div>
          </div>
        `;
      } else if (requiresSerials) {
        // Requester, or a non-production shipper - can see the requirement but can't search/pick.
        // Still needs data-requires-serials so shipTransferOrder's validation blocks Ship instead
        // of silently treating "no .serial-tag-picker element" as "nothing needed here".
        serialsCell = `<span class="muted">${remainingToShip} serial(s) required - only the shipping production warehouse can select.</span>`;
      }

      return `
        <tr data-line-no="${l['Line No.']}" data-qty-to-transfer="${qtyToTransfer}" data-qty-shipped="${qtyShipped}" data-qty-received="${qtyReceived}" data-item-no="${l['Item No.'] || ''}" data-variant-id="${l['Variant ID'] || ''}" data-requires-serials="${requiresSerials}">
          <td>${l['Item No.'] || ''}</td>
          <td>${l['Variant Name'] || ''}</td>
          <td>${l['Description'] || ''}</td>
          <td class="available-stock-cell muted" data-available-line-no="${l['Line No.']}">&hellip;</td>
          <td>${qtyToTransfer}</td>
          <td>${qtyToShipCell}</td>
          <td>${serialsCell}</td>
          <td>${qtyShippedCell}</td>
          <td>${qtyToReceiveCell}</td>
          <td>${qtyReceivedCell}</td>
        </tr>
      `;
    })
    .join('');

  body.querySelectorAll('tr[data-line-no]').forEach((row) => {
    const picker = row.querySelector('.serial-tag-picker');
    if (picker) wireSerialTagPicker(row, picker);

    // Shipping less than the max remaining lowers how many serials are needed for this action
    // too - keep the picker's required count (and its "N / required" display) in sync live.
    const qtyInput = row.querySelector('.manage-qty-to-ship');
    if (qtyInput && picker) {
      qtyInput.addEventListener('input', () => {
        const required = Math.max(0, parseFloat(qtyInput.value) || 0);
        picker.dataset.required = String(required);
        updateSerialTagCount(picker);
      });
    }
  });
}

function getSelectedSerialsForPicker(picker) {
  try {
    return JSON.parse(picker.dataset.selected || '[]');
  } catch {
    return [];
  }
}

function updateSerialTagCount(picker) {
  const selected = getSelectedSerialsForPicker(picker);
  const required = Math.max(0, parseFloat(picker.dataset.required) || 0);
  const countEl = picker.querySelector('.serial-tag-count');
  const satisfied = selected.length === required;
  countEl.textContent = `${selected.length} / ${required} selected`;
  countEl.classList.toggle('satisfied', satisfied && required > 0);
  countEl.classList.toggle('unsatisfied', !satisfied);
}

function renderSerialTagChips(picker) {
  const chipsEl = picker.querySelector('.serial-tag-chips');
  const selected = getSelectedSerialsForPicker(picker);
  chipsEl.innerHTML = selected
    .map((s) => `
      <span class="serial-tag-chip" data-running-serial-no="${s.runningSerialNo}">
        ${s.serialNo}<span class="serial-tag-chip-remove" title="Remove">&times;</span>
      </span>
    `)
    .join('');

  chipsEl.querySelectorAll('.serial-tag-chip-remove').forEach((removeBtn) => {
    removeBtn.addEventListener('click', () => {
      const chip = removeBtn.closest('.serial-tag-chip');
      const runningSerialNo = Number(chip.dataset.runningSerialNo);
      const remaining = getSelectedSerialsForPicker(picker).filter((s) => s.runningSerialNo !== runningSerialNo);
      picker.dataset.selected = JSON.stringify(remaining);
      renderSerialTagChips(picker);
      updateSerialTagCount(picker);
    });
  });
}

function addSerialTagToPicker(picker, serial) {
  const selected = getSelectedSerialsForPicker(picker);
  if (selected.some((s) => s.runningSerialNo === serial.runningSerialNo)) return;
  selected.push(serial);
  picker.dataset.selected = JSON.stringify(selected);
  renderSerialTagChips(picker);
  updateSerialTagCount(picker);
}

async function searchAvailableSerialsForRow(row, picker, searchText) {
  const dropdown = picker.querySelector('.serial-tag-dropdown');
  const itemNo = row.dataset.itemNo;
  const variantId = row.dataset.variantId;

  let query = supabaseClient
    .from('ItemSerialTracking')
    .select('RunningSerialNo, SerialNo, ItemCode, VariantCode')
    .eq('Status', 'IN_STOCK')
    .eq('ItemCode', itemNo);
  query = variantId ? query.eq('VariantCode', variantId) : query.or('VariantCode.is.null,VariantCode.eq.');
  // Only offer serials physically at the staff member's own location - currentManageCanManageSerials
  // already requires them to be logged in at this order's From Warehouse to reach this picker at
  // all, so searching across every warehouse's stock here would let them tag units that aren't
  // actually sitting at the location doing the shipping. Staff with no assigned warehouse (access
  // to all) stay unrestricted, same convention as everywhere else this session field is used.
  if (currentSession?.warehouseName) {
    query = query.eq('Location', currentSession.warehouseName);
  }
  if (searchText && searchText.trim()) {
    query = query.ilike('SerialNo', `%${searchText.trim()}%`);
  }
  query = query.order('SerialNo').limit(20);

  const { data, error } = await query;

  if (error) {
    console.error('Serial search failed:', error);
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${error.message}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const selected = getSelectedSerialsForPicker(picker);
  const alreadySelected = new Set(selected.map((s) => s.runningSerialNo));
  const available = (data || []).filter((s) => !alreadySelected.has(s.RunningSerialNo));

  if (available.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No available serials found.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = available
    .map((s) => `<div class="item-suggest-option" data-running-serial-no="${s.RunningSerialNo}" data-serial-no="${encodeURIComponent(s.SerialNo)}">${s.SerialNo}</div>`)
    .join('');
  dropdown.classList.remove('hidden');

  // mousedown + preventDefault, same reasoning as the item/variant suggestion pickers - keeps the
  // search input focused so there's no blur-vs-click race hiding the dropdown before a pick lands.
  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      addSerialTagToPicker(picker, {
        runningSerialNo: Number(opt.dataset.runningSerialNo),
        serialNo: decodeURIComponent(opt.dataset.serialNo)
      });
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
      picker.querySelector('.serial-tag-search').value = '';
    });
  });
}

function wireSerialTagPicker(row, picker) {
  updateSerialTagCount(picker);

  const searchInput = picker.querySelector('.serial-tag-search');
  const dropdown = picker.querySelector('.serial-tag-dropdown');
  let debounceHandle = null;

  searchInput.addEventListener('input', (e) => {
    clearTimeout(debounceHandle);
    const value = e.target.value;
    debounceHandle = setTimeout(() => searchAvailableSerialsForRow(row, picker, value), 250);
  });
  searchInput.addEventListener('focus', () => searchAvailableSerialsForRow(row, picker, searchInput.value));
  searchInput.addEventListener('blur', () => {
    setTimeout(() => dropdown.classList.add('hidden'), 150);
  });
}

async function openManageModal(docNo) {
  currentManageDocNo = docNo;
  document.getElementById('viewLinesTitle').textContent = `Transfer Order ${docNo}`;
  document.getElementById('viewLinesError').classList.add('hidden');
  const body = document.getElementById('viewLinesBody');
  body.innerHTML = '<tr><td colspan="10" class="muted">Loading...</td></tr>';
  document.getElementById('viewLinesModal').classList.remove('hidden');

  // Restore the layout this browser last used, before the panel is seen.
  applyModalMaximized('viewLinesModal', 'viewLinesMaximizeBtn', readStoredFlag(TO_MANAGE_MAXIMIZED_KEY, false));
  document.getElementById('viewLinesGeneralTab').open = readStoredFlag(TO_MANAGE_GENERAL_TAB_KEY, true);

  const { data: headerRows, error: headerError } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .eq('"No."', docNo)
    .limit(1);

  if (headerError || !headerRows || headerRows.length === 0) {
    body.innerHTML = `<tr><td colspan="10" class="error-text">${headerError?.message || 'Transfer order not found.'}</td></tr>`;
    return;
  }

  const header = headerRows[0];
  currentManageHeader = header;
  renderManageHeader(header);

  const { data, error } = await supabaseClient
    .from('Transfer_Line')
    .select('*')
    .eq('"Document No."', docNo)
    .order('"Line No."', { ascending: true });

  if (error) {
    body.innerHTML = `<tr><td colspan="10" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const status = header['Status'] || 'Requested';
  const lines = data || [];

  // Determine which of this order's items require serial tagging before Ship, before rendering
  // the lines - renderManageLines needs this to decide which rows get a serial picker cell.
  currentManageProductionItemCodes = new Set();
  const itemCodes = Array.from(new Set(lines.map((l) => l['Item No.']).filter(Boolean)));
  if (itemCodes.length > 0) {
    const { data: flagRows, error: flagError } = await supabaseClient.rpc('staff_get_item_production_flags', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_item_codes: itemCodes
    });
    if (flagError) {
      console.error('staff_get_item_production_flags failed:', flagError);
    } else {
      (flagRows || []).forEach((row) => {
        if (row.is_production_category) currentManageProductionItemCodes.add(row.item_no);
      });
    }
  }

  renderManageLines(lines, status);
  updateManageActionButtons(status, lines);
  await loadAvailableStockForLines(docNo);
  await autoFillQtyToShip(docNo, lines);
}

// Qty To Ship is filled from what the From Warehouse has on hand: each line gets the lesser of
// what is still unshipped and what is available (never negative), and is saved straight away so
// the printout and anyone else opening the order see it. The box is filled for everyone who sees it,
// but only SAVED by someone who can actually ship this order (the Ship button is showing). Only
// while Transfer Orders post to the Item Ledger - with that off the ledger has no say over stock,
// so there is nothing reliable to fill from (a hand-typed value still saves then). A value typed in by
// hand is saved when the box loses focus and is then KEPT on later opens instead of being refilled
// from stock - see "Qty To Ship Manual" (supabase_transfer_line_qty_to_ship_manual.sql); Ship clears it.
async function autoFillQtyToShip(docNo, lines) {
  const fillFromStock = await isTransferLedgerPostingEnabled();
  const canShipHere = !document.getElementById('shipTransferBtn').classList.contains('hidden');

  const lineByNo = new Map((lines || []).map((l) => [String(l['Line No.']), l]));

  async function saveQtyToShip(lineNo, value, manual) {
    try {
      await upsertRow('Transfer_Line', { 'Document No.': docNo, 'Line No.': lineNo }, { 'Qty To Ship': value });
      const line = lineByNo.get(String(lineNo));
      if (line) line['Qty To Ship'] = value;
    } catch (err) {
      console.error('Saving Qty To Ship failed:', err);
      return;
    }
    // Remembering that a person chose this number (so the next open doesn't replace it with the
    // stock figure) needs "Qty To Ship Manual" (supabase_transfer_line_qty_to_ship_manual.sql). Its own
    // best-effort write, so the quantity itself still saves if that script hasn't been run yet.
    if (manual !== undefined) {
      try {
        await upsertRow('Transfer_Line', { 'Document No.': docNo, 'Line No.': lineNo }, { 'Qty To Ship Manual': manual });
      } catch (err) {
        console.error('Saving Qty To Ship Manual failed (has supabase_transfer_line_qty_to_ship_manual.sql been run?):', err);
      }
    }
  }

  const rows = Array.from(document.querySelectorAll('#viewLinesBody tr[data-line-no]'));

  // Wired for every row up front, before any awaiting below, so a number typed while the stock
  // figures are still being applied is never overwritten - the fill skips any box already touched.
  rows.forEach((row) => {
    const input = row.querySelector('.manage-qty-to-ship');
    if (!input) return;
    input.addEventListener('input', () => { input.dataset.touched = 'true'; });
    if (canShipHere) {
      input.addEventListener('change', () => {
        const typed = Math.min(Math.max(parseFloat(input.value) || 0, 0), parseFloat(input.max) || 0);
        saveQtyToShip(row.dataset.lineNo, typed, true);
      });
    }
  });

  for (const row of rows) {
    const input = row.querySelector('.manage-qty-to-ship');
    if (!input || input.dataset.touched === 'true') continue;
    const lineNo = row.dataset.lineNo;
    const line = lineByNo.get(String(lineNo)) || {};
    const remaining = parseFloat(input.max) || 0;
    const picker = row.querySelector('.serial-tag-picker');

    let fill;
    if (line['Qty To Ship Manual'] === true && line['Qty To Ship'] !== null && line['Qty To Ship'] !== undefined) {
      // Someone chose this number by hand - keep it (never more than is still unshipped).
      fill = Math.min(remaining, Math.max(0, Number(line['Qty To Ship']) || 0));
    } else {
      if (!fillFromStock) continue;
      const available = currentAvailableByLineNo.get(String(lineNo));
      if (!available || available.fetch_error) continue;
      fill = Math.min(remaining, Math.max(0, Number(available.available_quantity) || 0));
    }
    input.value = fill;

    // Keep a serial-tracked line's required count in step with the new quantity.
    if (picker) {
      picker.dataset.required = String(fill);
      updateSerialTagCount(picker);
    }

    if (canShipHere && line['Qty To Ship Manual'] !== true && Number(line['Qty To Ship']) !== fill) {
      await saveQtyToShip(lineNo, fill, undefined);
    }
  }
}

// "Available" column (Manage modal) - what this order's From Warehouse has on hand for each line,
// straight from the Item Ledger (staff_get_transfer_line_stock). Runs after renderManageLines has
// already put a per-line placeholder cell in the DOM (data-available-line-no), so this only ever
// fills those in. The numbers are also kept in currentAvailableByLineNo so Ship can check them
// before it does anything it can't undo (claiming serials).
let currentAvailableByLineNo = new Map();

async function loadAvailableStockForLines(docNo) {
  currentAvailableByLineNo = new Map();
  const cells = document.querySelectorAll('#viewLinesBody [data-available-line-no]');
  if (cells.length === 0) return;

  const { data, error } = await supabaseClient.rpc('staff_get_transfer_line_stock', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_document_no: docNo
  });

  if (error) {
    console.error('staff_get_transfer_line_stock failed:', error);
    cells.forEach((cell) => {
      cell.textContent = '?';
      cell.title = describeSupabaseError(error, 'Failed to load available stock.');
    });
    return;
  }

  currentAvailableByLineNo = new Map((data || []).map((row) => [String(row.line_no), row]));
  cells.forEach((cell) => {
    const row = currentAvailableByLineNo.get(cell.dataset.availableLineNo);
    if (!row) {
      cell.textContent = '?';
      return;
    }
    if (row.fetch_error) {
      cell.textContent = '?';
      cell.title = row.fetch_error;
    } else {
      cell.textContent = Number(row.available_quantity);
      cell.classList.remove('muted');
      cell.title = '';
    }
  });
}

// Whether Transfer Orders currently post to the Item Ledger at all (General Setup > Item Ledger,
// see supabase_item_ledger_transfer_posting_toggle.sql). Fetched fresh each time rather than
// cached, since it can be flipped from another tab/session at any moment. Defaults to true (the
// feature's own default) if the check itself fails, so a transient error here doesn't accidentally
// let a real stock shortage through - it just falls back to the normal, stricter behaviour.
async function isTransferLedgerPostingEnabled() {
  const { data, error } = await supabaseClient.rpc('admin_get_item_ledger_transfer_posting_enabled', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) {
    console.error('admin_get_item_ledger_transfer_posting_enabled failed:', error);
    return true;
  }
  return !!data;
}

// ---- Create PO for the items this order's From Warehouse is short of ----
// "Missing" = still-unshipped quantity minus what the From Warehouse has on hand (Item Ledger, the
// same figure as the Available column). Grouped by each item's primary vendor, one Purchase Order
// per vendor, received into the From Warehouse (that is where the stock is needed to ship from).
let createPoGroups = []; // [{ vendorCode, vendorName, lines: [{ itemCode, itemName, variantId, variantName, onHand, missing }] }]
let createPoNoVendor = [];

async function openCreatePoModal(docNo) {
  const errorEl = document.getElementById('viewLinesError');
  errorEl.classList.add('hidden');
  await loadAvailableStockForLines(docNo);

  const rows = Array.from(document.getElementById('viewLinesBody').querySelectorAll('tr[data-line-no]'));
  const missingLines = [];
  const unchecked = [];
  rows.forEach((row) => {
    const remaining = Math.max(0, (Number(row.dataset.qtyToTransfer) || 0) - (Number(row.dataset.qtyShipped) || 0));
    if (remaining <= 0) return;
    const available = currentAvailableByLineNo.get(String(row.dataset.lineNo));
    if (!available || available.fetch_error) {
      unchecked.push(row.dataset.itemNo);
      return;
    }
    const onHand = Math.max(0, Number(available.available_quantity) || 0);
    const missing = remaining - onHand;
    if (missing > 0) {
      missingLines.push({
        itemCode: row.dataset.itemNo,
        itemName: row.cells[2]?.textContent.trim() || row.dataset.itemNo,
        variantId: row.dataset.variantId || '',
        variantName: row.cells[1]?.textContent.trim() || '',
        onHand,
        missing
      });
    }
  });

  if (missingLines.length === 0) {
    errorEl.textContent = unchecked.length
      ? `Nothing to buy for the lines that could be checked. Stock could not be checked for: ${unchecked.join(', ')}.`
      : `Nothing is missing - ${currentManageHeader?.['From Warehouse'] || 'the From Warehouse'} has enough stock for everything still to ship.`;
    errorEl.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_get_items_vendor_info', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_codes: Array.from(new Set(missingLines.map((l) => l.itemCode)))
  });
  if (error) {
    errorEl.textContent = 'Could not look up suppliers: ' + describeSupabaseError(error, 'unknown error') + ' (has supabase_transfer_order_create_po.sql been run?)';
    errorEl.classList.remove('hidden');
    return;
  }
  const vendorByItem = new Map((data || []).map((r) => [r.item_code, r]));

  const byVendor = new Map();
  createPoNoVendor = [];
  missingLines.forEach((l) => {
    const info = vendorByItem.get(l.itemCode);
    if (!info || !info.vendor_code) {
      createPoNoVendor.push(l);
      return;
    }
    if (!byVendor.has(info.vendor_code)) {
      byVendor.set(info.vendor_code, { vendorCode: info.vendor_code, vendorName: info.vendor_name || info.vendor_code, lines: [] });
    }
    byVendor.get(info.vendor_code).lines.push({ ...l, itemName: info.item_name || l.itemName });
  });
  createPoGroups = Array.from(byVendor.values());

  const fromName = currentManageHeader?.['From Warehouse'] || 'the From Warehouse';
  document.getElementById('createPoIntro').textContent =
    `Transfer Order ${docNo}: ${missingLines.length} line(s) where ${fromName} does not have enough stock. One Purchase Order is created per supplier, received into ${fromName}. Adjust quantities or untick a supplier to skip it.`;

  const groupsHtml = createPoGroups.map((g, gi) => `
    <div style="margin-bottom:14px;">
      <label style="display:flex; gap:8px; align-items:center; font-weight:600; margin-bottom:4px;">
        <input type="checkbox" class="create-po-vendor-check" data-group="${gi}" checked /> ${escapeHtml(g.vendorName)} <span class="muted" style="font-weight:400;">(${escapeHtml(g.vendorCode)})</span>
      </label>
      <div class="table-wrap"><table>
        <thead><tr><th>Item No.</th><th>Variant</th><th>Description</th><th>On Hand</th><th>Missing</th><th>Order Qty</th></tr></thead>
        <tbody>${g.lines.map((l, li) => `
          <tr>
            <td>${escapeHtml(l.itemCode)}</td><td>${escapeHtml(l.variantName)}</td><td>${escapeHtml(l.itemName)}</td>
            <td>${l.onHand}</td><td>${l.missing}</td>
            <td><input type="number" class="create-po-qty" data-group="${gi}" data-line="${li}" min="0" step="1" value="${l.missing}" style="width:90px;" /></td>
          </tr>`).join('')}
        </tbody>
      </table></div>
    </div>`).join('');

  const noVendorHtml = createPoNoVendor.length
    ? `<div class="error-text" style="margin-bottom:8px;">No supplier set on: ${createPoNoVendor.map((l) => escapeHtml(l.itemCode)).join(', ')} - set the Vendor No. in Item Setup, then try again. These are not included.</div>`
    : '';
  const uncheckedHtml = unchecked.length
    ? `<div class="muted" style="margin-bottom:8px;">Stock could not be checked for: ${unchecked.map(escapeHtml).join(', ')} - not included.</div>`
    : '';

  document.getElementById('createPoBody').innerHTML = noVendorHtml + uncheckedHtml + (groupsHtml || '<p class="muted">No missing item has a supplier set.</p>');
  document.getElementById('createPoError').classList.add('hidden');
  document.getElementById('createPoResult').innerHTML = '';
  document.getElementById('createPoConfirmBtn').classList.toggle('hidden', createPoGroups.length === 0);
  document.getElementById('createPoConfirmBtn').disabled = false;
  document.getElementById('createPoModal').classList.remove('hidden');
}

async function confirmCreatePo() {
  const errorEl = document.getElementById('createPoError');
  errorEl.classList.add('hidden');
  const fromId = currentManageHeader?.['From Warehouse ID'];
  const fromName = currentManageHeader?.['From Warehouse'];
  if (!fromId) {
    errorEl.textContent = 'This order has no From Warehouse ID.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('createPoConfirmBtn');
  btn.disabled = true;
  const results = [];
  const failures = [];

  for (let gi = 0; gi < createPoGroups.length; gi++) {
    const group = createPoGroups[gi];
    const check = document.querySelector(`.create-po-vendor-check[data-group="${gi}"]`);
    if (!check?.checked) continue;

    const lines = group.lines.map((l, li) => {
      const qty = Number(document.querySelector(`.create-po-qty[data-group="${gi}"][data-line="${li}"]`)?.value) || 0;
      return {
        item_code: l.itemCode,
        item_name: l.itemName,
        quantity: qty,
        variant_code: l.variantId || null,
        variant_name: l.variantName || null
      };
    }).filter((l) => l.quantity > 0);
    if (lines.length === 0) continue;

    const { data, error } = await supabaseClient.rpc('staff_create_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendor_code: group.vendorCode,
      p_notes: `Created from Transfer Order ${currentManageDocNo} (missing stock)`,
      p_lines: lines,
      p_warehouse_id: fromId,
      p_warehouse_name: fromName || null
    });
    if (error) {
      failures.push(`${group.vendorName}: ${describeSupabaseError(error, 'unknown error')}`);
    } else {
      results.push({ vendor: group.vendorName, poNo: data });
      // Done - stop it being created twice by an accidental second click.
      check.checked = false;
      check.disabled = true;
    }
  }

  btn.disabled = false;
  if (failures.length) {
    errorEl.textContent = 'Some Purchase Orders could not be created - ' + failures.join('; ');
    errorEl.classList.remove('hidden');
  }
  if (results.length) {
    document.getElementById('createPoResult').innerHTML = '<p><strong>Created:</strong></p><ul>' + results.map((r) =>
      `<li>${escapeHtml(r.vendor)}: <a href="purchase-order-print.html?po=${encodeURIComponent(r.poNo)}">${escapeHtml(r.poNo)}</a></li>`).join('') + '</ul>';
  } else if (!failures.length) {
    errorEl.textContent = 'Nothing to create - tick a supplier and enter a quantity above 0.';
    errorEl.classList.remove('hidden');
  }
}

async function shipTransferOrder(docNo) {
  const errorEl = document.getElementById('viewLinesError');
  errorEl.classList.add('hidden');

  if (currentManageIsOwnToWarehouse) {
    errorEl.textContent = 'You cannot ship a transfer order requested for your own warehouse - shipping is done by the source warehouse.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Reads each row's existing cumulative Qty Shipped (embedded as a data attribute when the
  // lines were rendered) and adds this action's entered amount to it - a partial shipment just
  // means the entered amount is less than the remaining balance, leaving more to ship later.
  const rows = Array.from(document.getElementById('viewLinesBody').querySelectorAll('tr[data-line-no]'));
  const lineUpdates = rows.map((row) => {
    const qtyToTransfer = Number(row.dataset.qtyToTransfer) || 0;
    const existingShipped = Number(row.dataset.qtyShipped) || 0;
    const existingReceived = Number(row.dataset.qtyReceived) || 0;
    const remaining = Math.max(0, qtyToTransfer - existingShipped);
    const entered = parseFloat(row.querySelector('.manage-qty-to-ship')?.value) || 0;
    const increment = Math.min(Math.max(entered, 0), remaining);
    return {
      lineNo: row.dataset.lineNo,
      increment,
      qtyToTransfer,
      qtyShipped: existingShipped + increment,
      qtyReceived: existingReceived
    };
  });

  if (!lineUpdates.some((l) => l.increment > 0)) {
    errorEl.textContent = 'At least one line must have a Qty To Ship greater than 0 to ship.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Production Category lines need exactly one picked (existing, IN_STOCK) serial per unit being
  // shipped this action - see renderManageLines' serial-tag-picker cell. Checked client-side here
  // (just counting what's already been picked) before anything server-side happens; the actual
  // atomic claim - which also re-verifies availability - happens further down, once stock is confirmed.
  const incompleteSerialLines = [];
  const serialRunningNosToClaim = [];
  for (const line of lineUpdates) {
    if (line.increment <= 0) continue;
    const row = rows.find((r) => r.dataset.lineNo === line.lineNo);
    if (row?.dataset.requiresSerials !== 'true') continue; // not a Production Category line - no serial requirement

    const picker = row?.querySelector('.serial-tag-picker');
    if (!picker) {
      // Requires serials, but this staff member isn't allowed to search/pick them (requester, or
      // a non-production shipper - see currentManageCanManageSerials) - block Ship outright rather
      // than silently letting it through with nothing claimed.
      incompleteSerialLines.push(`${row.dataset.itemNo} (not authorized to select serials for this warehouse)`);
      continue;
    }

    const selected = getSelectedSerialsForPicker(picker);
    if (selected.length !== line.increment) {
      incompleteSerialLines.push(`${row.dataset.itemNo} (${selected.length}/${line.increment} serials picked)`);
    } else {
      selected.forEach((s) => serialRunningNosToClaim.push(s.runningSerialNo));
    }
  }

  if (incompleteSerialLines.length > 0) {
    errorEl.textContent = `Pick a serial for every unit being shipped: ${incompleteSerialLines.join(', ')}.`;
    errorEl.classList.remove('hidden');
    return;
  }

  const shipBtn = document.getElementById('shipTransferBtn');
  shipBtn.disabled = true;
  try {
    // The From Warehouse must actually have what is being shipped - checked against the Item Ledger
    // BEFORE claiming serials, since that claim is the one step here that isn't undone if Ship then
    // fails. (The ledger trigger on Transfer_Line enforces the same rule again server-side, which is
    // what protects against two people shipping the same stock at the same moment.)
    if (!currentManageHeader?.['From Warehouse ID'] || !currentManageHeader?.['To Warehouse ID']) {
      errorEl.textContent = 'Cannot ship - this order is missing a From/To Warehouse ID.';
      errorEl.classList.remove('hidden');
      return;
    }

    // Only worth checking/blocking on ledger stock while Transfer Orders actually post to the
    // Item Ledger (General Setup > Item Ledger) - when that's off, the ledger has no say over
    // this shipment at all (the same setting also makes the server-side trigger skip its own
    // stock check, so this isn't just a client-side bypass of a rule still enforced underneath).
    await loadAvailableStockForLines(docNo);
    const ledgerPostingEnabled = await isTransferLedgerPostingEnabled();
    if (ledgerPostingEnabled) {
      const shortages = [];
      for (const line of lineUpdates) {
        if (line.increment <= 0) continue;
        const row = rows.find((r) => r.dataset.lineNo === line.lineNo);
        const available = currentAvailableByLineNo.get(String(line.lineNo));
        const label = row?.dataset.itemNo || `line ${line.lineNo}`;
        if (!available || available.fetch_error) {
          shortages.push(`${label} (${available?.fetch_error || 'stock could not be checked'})`);
        } else if (Number(available.available_quantity) < line.increment) {
          shortages.push(`${label} (${Number(available.available_quantity)} on hand, shipping ${line.increment})`);
        }
      }
      if (shortages.length > 0) {
        errorEl.textContent = `Cannot ship - not enough stock at ${currentManageHeader['From Warehouse'] || 'the From Warehouse'}: ${shortages.join('; ')}.`;
        errorEl.classList.remove('hidden');
        return;
      }
    }

    // Stock confirmed - now atomically claim the picked serials (IN_STOCK -> IN_TRANSIT,
    // Location -> "In Transit to {To Warehouse}") before committing anything locally. This
    // re-verifies availability server-side (see staff_claim_serials_for_transfer_shipment) in
    // case someone else grabbed the same serial in the meantime - rare, but if it happens
    // nothing is written, so retry once the picker is refreshed with what's still actually
    // available.
    if (serialRunningNosToClaim.length > 0) {
      try {
        const { error: claimError } = await supabaseClient.rpc('staff_claim_serials_for_transfer_shipment', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_document_no: docNo,
          p_to_warehouse_name: currentManageHeader?.['To Warehouse'] || null,
          p_running_serial_nos: serialRunningNosToClaim
        });
        if (claimError) throw claimError;
      } catch (err) {
        errorEl.textContent = `Cannot ship - could not claim the picked serials: ${describeSupabaseError(err, 'unknown error')}. Nothing was shipped - re-pick serials and try Ship again, or contact an admin if this persists.`;
        errorEl.classList.remove('hidden');
        return;
      }
    }

    // Only reached once stock is confirmed and serials (if any) are claimed - now commit it. The
    // ledger entry is written by the trigger on this same Transfer_Line update (see
    // supabase_item_ledger_hooks.sql), in the same transaction.
    for (const line of lineUpdates) {
      if (line.increment <= 0) continue;
      // 'Last Actor' is who to credit the Item Ledger entry to - a trigger on Transfer_Line posts
      // the shipment to the ledger off this same update (supabase_item_ledger_hooks.sql).
      await upsertRow('Transfer_Line', { 'Document No.': docNo, 'Line No.': line.lineNo }, {
        'Qty To Ship': line.increment,
        'Qty Shipped': line.qtyShipped,
        'Last Actor': currentSession?.username || null
      });
      // A shipment uses up whatever was chosen, so the next round fills from stock again. Best-effort:
      // the column comes from supabase_transfer_line_qty_to_ship_manual.sql.
      try {
        await upsertRow('Transfer_Line', { 'Document No.': docNo, 'Line No.': line.lineNo }, { 'Qty To Ship Manual': false });
      } catch (err) {
        console.error('Clearing Qty To Ship Manual failed:', err);
      }
    }

    // Transfer Date/Shipped By mark the first shipment out, not every partial shipment - leave
    // them alone once already set.
    const headerPayload = { 'Status': computeAggregateStatus(lineUpdates) };
    if (!currentManageHeader?.['Transfer Date']) {
      headerPayload['Transfer Date'] = todayLocalDateString();
      headerPayload['Shipped By'] = currentSession?.displayName || currentSession?.username || null;
    }
    await upsertRow('Transfer_Header', { 'No.': docNo }, headerPayload);

    await openManageModal(docNo);
    await loadHeaders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to ship transfer order.');
    errorEl.classList.remove('hidden');
  } finally {
    shipBtn.disabled = false;
  }
}

// Mirrors the serial-matching filter searchAvailableSerialsForRow uses when picking serials to
// ship, but the other direction: releases serials this shipment already tagged IN_TRANSIT (see
// staff_claim_serials_for_transfer_shipment) back to IN_STOCK at the receiving warehouse, so
// they're sellable there. Doesn't require the user to re-pick which physical serials arrived -
// we already know exactly which ones are on this shipment (Status='IN_TRANSIT' AND
// SourceDocumentNo=docNo for this item/variant); on a full receive every one of them gets
// released. On a partial receive (quantity below what's tagged IN_TRANSIT for this line), this
// releases the oldest-tagged `quantity` of them by RunningSerialNo - an arbitrary but reasonable
// choice, since nothing on this screen currently identifies which specific unit went missing.
async function releaseReceivedSerials(docNo, itemNo, variantId, quantity, toWarehouseName) {
  if (!itemNo || quantity <= 0) return;

  let query = supabaseClient
    .from('ItemSerialTracking')
    .select('RunningSerialNo')
    .eq('Status', 'IN_TRANSIT')
    .eq('SourceDocumentNo', docNo)
    .eq('ItemCode', itemNo);
  query = variantId ? query.eq('VariantCode', variantId) : query.or('VariantCode.is.null,VariantCode.eq.');
  query = query.order('RunningSerialNo').limit(quantity);

  const { data, error } = await query;
  if (error) {
    console.error('Failed to look up in-transit serials to release:', error);
    return;
  }
  if (!data || data.length === 0) return;

  const { error: updateError } = await supabaseClient
    .from('ItemSerialTracking')
    .update({
      Status: 'IN_STOCK',
      Location: toWarehouseName || null,
      UpdatedAtUtc: new Date().toISOString(),
      UpdatedBy: currentSession?.username || null
    })
    .in('RunningSerialNo', data.map((r) => r.RunningSerialNo));
  if (updateError) {
    console.error('Failed to release received serials to IN_STOCK:', updateError);
  }
}

async function receiveTransferOrder(docNo) {
  const errorEl = document.getElementById('viewLinesError');
  errorEl.classList.add('hidden');

  if (currentManageIsOwnFromWarehouse) {
    errorEl.textContent = 'You cannot receive a transfer order shipped from your own warehouse - receiving is done by the destination warehouse.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Same running-total pattern as shipping: entered amount is added to the existing cumulative
  // Qty Received, capped at what's actually been shipped so far.
  const rows = Array.from(document.getElementById('viewLinesBody').querySelectorAll('tr[data-line-no]'));
  const lineUpdates = rows.map((row) => {
    const qtyToTransfer = Number(row.dataset.qtyToTransfer) || 0;
    const existingShipped = Number(row.dataset.qtyShipped) || 0;
    const existingReceived = Number(row.dataset.qtyReceived) || 0;
    const remaining = Math.max(0, existingShipped - existingReceived);
    const entered = parseFloat(row.querySelector('.manage-qty-to-receive')?.value) || 0;
    const increment = Math.min(Math.max(entered, 0), remaining);
    return {
      lineNo: row.dataset.lineNo,
      qtyToTransfer,
      increment,
      qtyShipped: existingShipped,
      qtyReceived: existingReceived + increment,
      itemNo: row.dataset.itemNo || '',
      variantId: row.dataset.variantId || ''
    };
  });

  if (!lineUpdates.some((l) => l.increment > 0)) {
    errorEl.textContent = 'At least one line must have a Qty To Receive greater than 0 to receive.';
    errorEl.classList.remove('hidden');
    return;
  }

  const receiveBtn = document.getElementById('receiveTransferBtn');
  receiveBtn.disabled = true;
  try {
    // Commit locally - the trigger on Transfer_Line adds the received stock to the To Warehouse in
    // the Item Ledger as part of this same update.
    const toWarehouseName = currentManageHeader?.['To Warehouse'] || '';
    for (const line of lineUpdates) {
      if (line.increment <= 0) continue;
      await upsertRow('Transfer_Line', { 'Document No.': docNo, 'Line No.': line.lineNo }, {
        'Qty To Receive': line.increment,
        'Qty Received': line.qtyReceived,
        'Last Actor': currentSession?.username || null
      });
      await releaseReceivedSerials(docNo, line.itemNo, line.variantId, line.increment, toWarehouseName);
    }

    // For a partial receipt, Receive Date marks the first receipt and is left alone once
    // already set. Once the order becomes fully Received, Receive Date is always overwritten
    // with today - the completion date, not whichever partial receipt happened to be first.
    const status = computeAggregateStatus(lineUpdates);
    const headerPayload = { 'Status': status };
    if (status === 'Received' || !currentManageHeader?.['Receive Date']) {
      headerPayload['Receive Date'] = todayLocalDateString();
    }
    await upsertRow('Transfer_Header', { 'No.': docNo }, headerPayload);

    if (status === 'Received') {
      // Fully received - archive to Posted_Transfer_Header/Posted_Transfer_Line and remove from
      // the live tables, rather than leaving a completed order in the working set forever.
      await archiveReceivedTransferOrder(docNo);
      document.getElementById('viewLinesModal').classList.add('hidden');
      await loadHeaders();
      window.alert(`Order ${docNo} has been fulfilled - moving into Posted Transfers.`);
      return;
    }

    await openManageModal(docNo);
    await loadHeaders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to receive transfer order.');
    errorEl.classList.remove('hidden');
  } finally {
    receiveBtn.disabled = false;
  }
}

// Moves a fully-Received order out of the live Transfer_Header/Transfer_Line tables into
// Posted_Transfer_Header/Posted_Transfer_Line (see supabase_posted_transfer_orders_tables.sql) -
// inserts into the Posted tables first, then deletes from the live tables, so a failure partway
// through leaves a recoverable duplicate rather than losing the order entirely.
//
// Explicitly whitelists fields rather than forwarding select('*') straight into the insert -
// Transfer_Header actually carries extra desktop-sync-only columns (e.g. "Online Transfer
// Response", "Remote Transfer ID") that don't exist on Posted_Transfer_Header and that the portal
// never reads/writes, so blindly spreading the raw row breaks with a schema-cache error the
// moment any such column is present.
async function archiveReceivedTransferOrder(docNo) {
  const { data: headerRows, error: headerError } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .eq('"No."', docNo)
    .limit(1);
  if (headerError) throw headerError;
  if (!headerRows || headerRows.length === 0) return;

  const { data: lineRows, error: lineError } = await supabaseClient
    .from('Transfer_Line')
    .select('*')
    .eq('"Document No."', docNo)
    .order('"Line No."', { ascending: true });
  if (lineError) throw lineError;

  const header = headerRows[0];
  const postedHeader = {
    'No.': header['No.'],
    'Description': header['Description'] ?? null,
    'Status': header['Status'] ?? null,
    'Requested Date': header['Requested Date'] ?? null,
    'Estimated Delivery Date': header['Estimated Delivery Date'] ?? null,
    'Transfer Date': header['Transfer Date'] ?? null,
    'Receive Date': header['Receive Date'] ?? null,
    'From Warehouse ID': header['From Warehouse ID'] ?? null,
    'From Warehouse': header['From Warehouse'] ?? null,
    'To Warehouse ID': header['To Warehouse ID'] ?? null,
    'To Warehouse': header['To Warehouse'] ?? null,
    'Category Code': header['Category Code'] ?? null,
    'Use Production Category': header['Use Production Category'] ?? null,
    'Posted Date': header['Posted Date'] ?? null,
    'Sent To Online': header['Sent To Online'] ?? null,
    'Requested By': header['Requested By'] ?? null,
    'Shipped By': header['Shipped By'] ?? null
  };

  const { error: insertHeaderError } = await supabaseClient.from('Posted_Transfer_Header').insert(postedHeader);
  if (insertHeaderError) throw insertHeaderError;

  if (lineRows && lineRows.length > 0) {
    const postedLines = lineRows.map((line) => ({
      'Document No.': line['Document No.'],
      'Item No.': line['Item No.'] ?? null,
      'Variant ID': line['Variant ID'] ?? null,
      'Variant Name': line['Variant Name'] ?? null,
      'Description': line['Description'] ?? null,
      'CategoryCode': line['CategoryCode'] ?? null,
      'Line No.': line['Line No.'],
      'Available QTY': line['Available QTY'] ?? null,
      'Qty To Transfer': line['Qty To Transfer'] ?? null,
      'Qty To Ship': line['Qty To Ship'] ?? null,
      'Qty Shipped': line['Qty Shipped'] ?? null,
      'Qty To Receive': line['Qty To Receive'] ?? null,
      'Qty Received': line['Qty Received'] ?? null
    }));
    const { error: insertLineError } = await supabaseClient.from('Posted_Transfer_Line').insert(postedLines);
    if (insertLineError) throw insertLineError;
  }

  const { error: deleteLineError } = await supabaseClient.from('Transfer_Line').delete().eq('"Document No."', docNo);
  if (deleteLineError) throw deleteLineError;

  const { error: deleteHeaderError } = await supabaseClient.from('Transfer_Header').delete().eq('"No."', docNo);
  if (deleteHeaderError) throw deleteHeaderError;
}

async function cancelTransferOrder(docNo) {
  const errorEl = document.getElementById('viewLinesError');
  errorEl.classList.add('hidden');

  if (currentManageIsOwnFromWarehouse) {
    errorEl.textContent = 'You cannot cancel a transfer order shipped from your own warehouse - cancelling is done by the requesting warehouse.';
    errorEl.classList.remove('hidden');
    return;
  }

  if (currentManageHasAnyShipped) {
    errorEl.textContent = 'This order can no longer be cancelled - at least one item has already been shipped.';
    errorEl.classList.remove('hidden');
    return;
  }

  if (!window.confirm(`Cancel transfer order ${docNo}? This cannot be undone.`)) return;

  const cancelBtn = document.getElementById('cancelTransferBtn');
  cancelBtn.disabled = true;
  try {
    await upsertRow('Transfer_Header', { 'No.': docNo }, { 'Status': 'Cancelled' });
    await openManageModal(docNo);
    await loadHeaders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to cancel transfer order.');
    errorEl.classList.remove('hidden');
  } finally {
    cancelBtn.disabled = false;
  }
}

// Super-user-only. Deletes the Transfer_Header and every Transfer_Line, but only if nothing has
// been shipped or received - re-read from the database right before deleting, since the modal's
// copy of the lines can be stale (someone else may have shipped since it was opened).
async function deleteTransferOrder(docNo) {
  const errorEl = document.getElementById('viewLinesError');
  errorEl.classList.add('hidden');

  if (!currentSession?.isSuperUser) {
    errorEl.textContent = 'Only a super user can delete a transfer order.';
    errorEl.classList.remove('hidden');
    return;
  }

  const deleteBtn = document.getElementById('deleteTransferBtn');
  deleteBtn.disabled = true;
  try {
    const { data: lines, error: linesError } = await supabaseClient
      .from('Transfer_Line')
      .select('"Qty Shipped", "Qty Received"')
      .eq('"Document No."', docNo);
    if (linesError) throw linesError;

    if ((lines || []).some((l) => (Number(l['Qty Shipped']) || 0) > 0 || (Number(l['Qty Received']) || 0) > 0)) {
      errorEl.textContent = 'This order cannot be deleted - at least one item has already been shipped.';
      errorEl.classList.remove('hidden');
      return;
    }

    if (!window.confirm(`Permanently delete transfer order ${docNo} and its ${(lines || []).length} line(s)? This cannot be undone.`)) return;

    const { error: deleteLineError } = await supabaseClient.from('Transfer_Line').delete().eq('"Document No."', docNo);
    if (deleteLineError) throw deleteLineError;
    const { error: deleteHeaderError } = await supabaseClient.from('Transfer_Header').delete().eq('"No."', docNo);
    if (deleteHeaderError) throw deleteHeaderError;

    document.getElementById('viewLinesModal').classList.add('hidden');
    await loadHeaders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to delete transfer order.');
    errorEl.classList.remove('hidden');
  } finally {
    deleteBtn.disabled = false;
  }
}

// Super-user-only override of an already-created order's From Warehouse - see the
// "editFromWarehouseBtn" toggle in updateManageActionButtons for why this is only ever offered
// before anything has shipped. Populates from the same staff_search_warehouses list
// applyPreferredFromWarehouse uses, just without its Production/Stock preference filtering - a
// super user overriding this should be able to pick any warehouse, not just the auto-picked ones.
async function openFromWarehouseEdit() {
  const select = document.getElementById('viewFromWarehouseSelect');
  select.innerHTML = '<option value="">Loading...</option>';
  document.getElementById('editFromWarehouseBtn').classList.add('hidden');
  document.getElementById('viewFromWarehouseEditRow').classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error || !data) {
    select.innerHTML = '<option value="">Failed to load warehouses</option>';
    return;
  }

  const currentId = currentManageHeader?.['From Warehouse ID'] || '';
  select.innerHTML = data
    .map((w) => `<option value="${w.id}" ${w.id === currentId ? 'selected' : ''}>${w.name}</option>`)
    .join('');
}

function closeFromWarehouseEdit() {
  document.getElementById('viewFromWarehouseEditRow').classList.add('hidden');
}

async function saveFromWarehouseEdit() {
  const errorEl = document.getElementById('viewLinesError');
  errorEl.classList.add('hidden');

  const select = document.getElementById('viewFromWarehouseSelect');
  const newId = select.value;
  const newName = select.options[select.selectedIndex]?.textContent || '';
  if (!newId) return;

  const saveBtn = document.getElementById('saveFromWarehouseBtn');
  saveBtn.disabled = true;
  try {
    await upsertRow('Transfer_Header', { 'No.': currentManageDocNo }, {
      'From Warehouse ID': newId,
      'From Warehouse': newName
    });
    await openManageModal(currentManageDocNo);
    await loadHeaders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to change From Warehouse.');
    errorEl.classList.remove('hidden');
  } finally {
    saveBtn.disabled = false;
  }
}

// "Print Production Order" - just opens the warehouse packing list layout
// (transfer-order-print-production.html) in a new tab. Locking no longer happens here - every
// order is locked automatically the moment it's requested (see saveNewTransfer's header payload
// below), so by the time an order can be opened in the Manage modal at all, it's already locked.
function printProductionOrder(docNo) {
  if (!docNo) return;
  window.open(`transfer-order-print-production.html?no=${encodeURIComponent(docNo)}`, '_blank');
}

// Supabase/PostgREST errors often have an empty .message with the actual detail sitting in
// .details/.hint/.code instead (e.g. RLS violations, check-constraint failures) - surfacing only
// err.message (the old behavior) silently showed a generic fallback in exactly those cases with
// nothing logged anywhere to explain why. This builds the fullest message available and always
// logs the raw error too, so DevTools console has the real cause even if the UI text is terse.
function describeSupabaseError(err, fallback) {
  console.error(fallback, err);
  const parts = [err?.message, err?.details, err?.hint].filter(Boolean);
  if (parts.length > 0) return parts.join(' - ');
  if (err?.code) return `${fallback} (code: ${err.code})`;
  return fallback;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
}


// Sequential per-warehouse Document No. (TR-{WarehouseName}0001, ...) via staff_next_transfer_no,
// which pulls its Prefix/Padding/Starting No. from the 'TRANSFER-ORDER' No. Series (General Setup
// -> No. Series, see supabase_no_series_tables.sql) - scoped to the To Warehouse (the requesting/
// destination store), since that's what's already known synchronously from the session at
// modal-open time, before the warehouse lookups below even resolve an ID.
async function generateTransferNo() {
  const warehouseName = currentSession?.warehouseName || '';
  const { data, error } = await supabaseClient.rpc('staff_next_transfer_no', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_name: warehouseName
  });

  if (error) {
    console.error('staff_next_transfer_no failed:', error);
    // Fall back to a timestamp-based number so order creation still works even if this RPC fails.
    const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    return `TR-${warehouseName}${stamp}`;
  }

  return data;
}

// Item/variant lookup for line items - staff_search_items/staff_search_variants (any active
// staff, unlike Item/Variant Setup's admin_list_items/admin_list_variants which are super-user
// only) so Transfer Orders (open to all staff) can still offer a picker. See
// supabase_warehouses_items_tables.sql.
//
// Bidirectional: searching Item No. scopes the Variant suggestions to that item; searching
// Variant directly (before an Item is picked) auto-fills Item No. + Description from whichever
// variant gets picked, using the linked item_name staff_search_variants joins in.

function applyItemSelection(row, code, name) {
  row.querySelector('.line-item-no').value = code;
  row.querySelector('.line-description').value = name || '';
  // A different item invalidates any previously picked variant - it belonged to the old item.
  if (row.dataset.variantItemCode !== code) {
    clearVariantSelection(row);
  }
  updateProductionCategoryLock();
}

// Once a line item is picked, changing "Use Production Category" (which drives which From
// Warehouse gets auto-selected - see applyPreferredFromWarehouse) could silently invalidate
// items already chosen against the old warehouse/category filter, so both lock together. Mirrors
// the desktop's own "Production Category checkbox locks once lines exist" pattern
// (TransferOrderLinesForm.cs).
function hasAnyLineItemSelected() {
  return Array.from(document.getElementById('newLinesBody').querySelectorAll('.line-item-no'))
    .some((input) => input.value.trim() !== '');
}

function updateProductionCategoryLock() {
  const locked = hasAnyLineItemSelected();
  document.getElementById('newUseProductionCategory').disabled = locked;
  document.getElementById('useProductionCategoryLockHint').classList.toggle('hidden', !locked);
}

function clearVariantSelection(row) {
  row.querySelector('.line-variant-search').value = '';
  row.querySelector('.line-variant-id').value = '';
  delete row.dataset.variantItemCode;
}

// Shared Prev/Next pager for the item/variant lookup dropdowns - onPageChange is a fresh closure
// built by the caller each render (just re-runs the same search on a different page), so no extra
// per-row page-tracking state is needed anywhere.
function buildSuggestPagerHtml(page, totalCount, pageSize) {
  const totalPages = Math.max(1, Math.ceil((totalCount || 0) / pageSize));
  if (totalPages <= 1) return '';
  return `
    <div class="item-suggest-pager">
      <button type="button" class="btn btn-secondary btn-sm suggest-prev-btn" ${page <= 1 ? 'disabled' : ''}>&lsaquo; Prev</button>
      <span class="muted">Page ${page} of ${totalPages}</span>
      <button type="button" class="btn btn-secondary btn-sm suggest-next-btn" ${page >= totalPages ? 'disabled' : ''}>Next &rsaquo;</button>
    </div>
  `;
}

function wireSuggestPager(dropdown, page, totalCount, pageSize, onPageChange) {
  const totalPages = Math.max(1, Math.ceil((totalCount || 0) / pageSize));
  const prevBtn = dropdown.querySelector('.suggest-prev-btn');
  const nextBtn = dropdown.querySelector('.suggest-next-btn');
  // mousedown + preventDefault (not click) so clicking Prev/Next never blurs the search input -
  // a blur would arm the input's own 150ms hide-dropdown timeout and close this right back up.
  if (prevBtn) {
    prevBtn.addEventListener('mousedown', (e) => {
      e.preventDefault();
      if (page > 1) onPageChange(page - 1);
    });
  }
  if (nextBtn) {
    nextBtn.addEventListener('mousedown', (e) => {
      e.preventDefault();
      if (page < totalPages) onPageChange(page + 1);
    });
  }
}

function renderItemSuggestions(row, items, page, totalCount, onPageChange) {
  const dropdown = row.querySelector('.item-suggest-dropdown');
  if (!items || items.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No items found.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const optionsHtml = items
    .map((it) => `
      <div class="item-suggest-option" data-code="${encodeURIComponent(it.code)}" data-name="${encodeURIComponent(it.name || '')}">
        <span class="item-suggest-code">${it.code}</span><span class="item-suggest-name">${it.name || ''}</span>
      </div>
    `)
    .join('');

  dropdown.innerHTML = optionsHtml + buildSuggestPagerHtml(page, totalCount, ITEM_LOOKUP_PAGE_SIZE);
  dropdown.classList.remove('hidden');

  // mousedown + preventDefault (not click) - same reasoning as wireSuggestPager's Prev/Next
  // buttons below: preventDefault on mousedown stops the browser from ever blurring the search
  // input, so there's no race against the input's own 150ms hide-dropdown timeout (a plain
  // 'click' handler here left a real window where a click could land after blur had already
  // wiped the dropdown, making the option appear unresponsive).
  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      applyItemSelection(row, decodeURIComponent(opt.dataset.code), decodeURIComponent(opt.dataset.name));
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
  wireSuggestPager(dropdown, page, totalCount, ITEM_LOOKUP_PAGE_SIZE, onPageChange);
}

// Mirrors the desktop's "Use Production Category" checkbox, which filters the item/variant
// lookup catalog by Category.IsProductionCategory (RefreshItemLookupOptions in
// TransferOrderLinesForm.cs) - only exists on the New Transfer Order form, which is the only
// place these lookups run.
function getUseProductionCategory() {
  return document.getElementById('newUseProductionCategory')?.checked ?? false;
}

async function searchItemsForRow(row, searchText, page = 1) {
  const dropdown = row.querySelector('.item-suggest-dropdown');

  // Mirrors the desktop's SetSourceWarehouse -> AllowUserToAddRows gating: line items can't be
  // looked up at all until a From Warehouse is picked (TransferOrderLinesForm.cs).
  if (!document.getElementById('newFromWarehouseId').value) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">Select a From Warehouse first.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  // Blank search still queries (staff_search_items returns a browsable first page instead of
  // nothing) so clicking into an empty field shows something right away, same as the Warehouse
  // lookup - not gated on having typed text like the old behavior.
  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: searchText && searchText.trim() ? searchText.trim() : null,
    p_use_production_category: getUseProductionCategory(),
    p_page: page
  });

  if (error) {
    console.error('staff_search_items failed:', error);
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${error.message}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  renderItemSuggestions(row, data || [], page, data?.[0]?.total_count || 0, (newPage) => searchItemsForRow(row, searchText, newPage));
}

function renderVariantSuggestions(row, variants, page, totalCount, onPageChange) {
  const dropdown = row.querySelector('.variant-suggest-dropdown');
  if (!variants || variants.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No variants found.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const optionsHtml = variants
    .map((v) => {
      const itemCode = v.item_code || v.main_item_code || '';
      // SKU leads as the primary label (was variant_name) - SKU is the identifier staff
      // actually recognize from Pancake, per direct request.
      const label = v.sku || v.variant_name || v.variation_id;
      const itemLabel = itemCode + (v.item_name ? ` - ${v.item_name}` : '');
      const variantNameLabel = v.variant_name ? ` | ${v.variant_name}` : '';
      return `
        <div class="item-suggest-option"
             data-variation-id="${encodeURIComponent(v.variation_id)}"
             data-item-code="${encodeURIComponent(itemCode)}"
             data-item-name="${encodeURIComponent(v.item_name || '')}"
             data-sku="${encodeURIComponent(v.sku || '')}"
             data-label="${encodeURIComponent(label)}">
          <span class="item-suggest-code">${label}</span><span class="item-suggest-name">${itemLabel}${variantNameLabel}</span>
        </div>
      `;
    })
    .join('');

  dropdown.innerHTML = optionsHtml + buildSuggestPagerHtml(page, totalCount, VARIANT_LOOKUP_PAGE_SIZE);
  dropdown.classList.remove('hidden');

  // mousedown + preventDefault, same reasoning as renderItemSuggestions above.
  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const variationId = decodeURIComponent(opt.dataset.variationId);
      const itemCode = decodeURIComponent(opt.dataset.itemCode);
      const itemName = decodeURIComponent(opt.dataset.itemName);
      const sku = decodeURIComponent(opt.dataset.sku);
      const label = decodeURIComponent(opt.dataset.label);

      row.querySelector('.line-variant-search').value = label;
      row.querySelector('.line-variant-id').value = variationId;
      row.dataset.variantItemCode = itemCode;

      // Picking a variant before typing an Item auto-fills Item No. + Description from the
      // variant's linked item - the other lookup direction.
      const itemInput = row.querySelector('.line-item-no');
      if (itemCode && itemInput.value.trim() !== itemCode) {
        itemInput.value = itemCode;
        if (itemName) {
          row.querySelector('.line-description').value = itemName;
        }
      }

      // Tack the SKU onto the description too - strip any SKU suffix from a previous
      // selection first so re-picking a variant doesn't stack duplicates.
      const descriptionInput = row.querySelector('.line-description');
      const baseDescription = descriptionInput.value.replace(/\s*\(SKU:[^)]*\)\s*$/, '').trim();
      descriptionInput.value = sku ? `${baseDescription}${baseDescription ? ' ' : ''}(SKU: ${sku})` : baseDescription;
      updateProductionCategoryLock();

      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
  wireSuggestPager(dropdown, page, totalCount, VARIANT_LOOKUP_PAGE_SIZE, onPageChange);
}

async function searchVariantsForRow(row, searchText, page = 1) {
  const dropdown = row.querySelector('.variant-suggest-dropdown');
  const itemCode = row.querySelector('.line-item-no').value.trim();

  if (!itemCode && (!searchText || !searchText.trim())) {
    dropdown.classList.add('hidden');
    dropdown.innerHTML = '';
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: itemCode || null,
    p_search: searchText && searchText.trim() ? searchText.trim() : null,
    p_use_production_category: getUseProductionCategory(),
    p_page: page
  });

  if (error) {
    console.error('staff_search_variants failed:', error);
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${error.message}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  renderVariantSuggestions(row, data || [], page, data?.[0]?.total_count || 0, (newPage) => searchVariantsForRow(row, searchText, newPage));
}

// From/To Warehouse are locked (disabled inputs, per direct request) - these two functions are
// now the ONLY way those fields ever get a value, there's no manual lookup/override anymore.

// Auto-picks a preferred From Warehouse the way the desktop's ApplyPreferredFromWarehouse does:
// the first warehouse flagged Production (if useProductionCategory) or Stock (otherwise).
async function applyPreferredFromWarehouse(useProductionCategory) {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error || !data) return;

  const preferred = data.find((w) => useProductionCategory ? w.is_production_warehouse : w.is_stock_warehouse);
  if (!preferred) return;

  document.getElementById('newFromWarehouse').value = preferred.name || '';
  document.getElementById('newFromWarehouseId').value = preferred.id || '';
}

// Whether the logged-in staff's own warehouse is flagged Production - gates who can search/pick
// serials for Ship (see currentManageCanManageSerials). Mirrors the same resolver in
// serialTracker.js; duplicated rather than shared since these are separate plain <script> files
// with no module system between the portal's pages.
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

// Resolves the logged-in staff's own warehouse name to its ID (the login session only carries
// warehouseName, no id - see verify_login() in supabase_staff_users_table.sql).
async function resolveWarehouseIdByName(name) {
  if (!name) return '';
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: name
  });
  if (error || !data) return '';

  const exactMatch = data.find((w) => (w.name || '').toLowerCase() === name.toLowerCase());
  return exactMatch?.id || '';
}

// Production needs lead time to build stock before a delivery run - the Estimated Delivery Date
// is never sooner than this many full calendar days after the Requested Date, even if that means
// skipping an otherwise-eligible Wed/Sun that's too close to give production enough time to
// build. Time-of-day doesn't matter, only which calendar day the request falls on.
const PRODUCTION_LEAD_DAYS = 3;

// Estimated Delivery Date is locked (disabled input) and always computed - the store's delivery
// schedule is Wednesday and Sunday only, so this finds the next one on or after fromDateStr plus
// the production lead time (inclusive - if that shifted date already falls on a delivery day,
// it's used as-is).
function computeNextDeliveryDate(fromDateStr) {
  let date;
  if (fromDateStr) {
    const [y, m, d] = fromDateStr.split('-').map(Number);
    date = new Date(y, m - 1, d);
  } else {
    date = new Date();
    date.setHours(0, 0, 0, 0);
  }

  date.setDate(date.getDate() + PRODUCTION_LEAD_DAYS);

  while (date.getDay() !== 0 && date.getDay() !== 3) { // Sunday=0, Wednesday=3
    date.setDate(date.getDate() + 1);
  }

  const yyyy = date.getFullYear();
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

function applyEstimatedDeliveryDate() {
  const requestedDate = document.getElementById('newRequestedDate').value;
  document.getElementById('newEstimatedDeliveryDate').value = computeNextDeliveryDate(requestedDate);
}

function addNewLineRow() {
  const tbody = document.getElementById('newLinesBody');
  const row = document.createElement('tr');
  row.innerHTML = `
    <td class="item-search-cell">
      <input type="text" class="line-item-no" placeholder="Search item code or name..." autocomplete="off" />
      <div class="item-suggest-dropdown hidden"></div>
    </td>
    <td class="item-search-cell">
      <input type="text" class="line-variant-search" placeholder="Search variant..." autocomplete="off" />
      <input type="hidden" class="line-variant-id" value="" />
      <div class="variant-suggest-dropdown hidden"></div>
    </td>
    <td><input type="text" class="line-description" /></td>
    <td><input type="number" class="line-qty" min="0" step="0.01" value="1" /></td>
    <td><button type="button" class="btn btn-danger btn-sm remove-line-btn">Remove</button></td>
  `;
  row.querySelector('.remove-line-btn').addEventListener('click', () => {
    row.remove();
    updateProductionCategoryLock();
  });

  const itemInput = row.querySelector('.line-item-no');
  let itemSearchDebounceHandle = null;
  itemInput.addEventListener('input', (e) => {
    clearTimeout(itemSearchDebounceHandle);
    const value = e.target.value;
    itemSearchDebounceHandle = setTimeout(() => searchItemsForRow(row, value), 250);
  });
  itemInput.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    clearTimeout(itemSearchDebounceHandle);
    searchItemsForRow(row, itemInput.value);
  });
  itemInput.addEventListener('focus', () => {
    // Always shows suggestions on click, even on an empty field - staff_search_items returns a
    // browsable first page for a blank search, so there's always something to pick from.
    searchItemsForRow(row, itemInput.value);
  });
  itemInput.addEventListener('blur', () => {
    // Delay so a suggestion's click still registers before we hide the dropdown (blur fires
    // before click on the option otherwise).
    setTimeout(() => {
      row.querySelector('.item-suggest-dropdown').classList.add('hidden');
      // Fallback for a manually-typed code (no suggestion clicked) - a changed code invalidates
      // any variant selection that belonged to the previous item.
      const typedCode = itemInput.value.trim();
      if (typedCode && row.dataset.variantItemCode !== typedCode) {
        clearVariantSelection(row);
      }
    }, 150);
  });

  const variantInput = row.querySelector('.line-variant-search');
  const variantIdInput = row.querySelector('.line-variant-id');
  let variantSearchDebounceHandle = null;
  variantInput.addEventListener('input', (e) => {
    variantIdInput.value = ''; // typing invalidates any prior selection
    delete row.dataset.variantItemCode;
    clearTimeout(variantSearchDebounceHandle);
    const value = e.target.value;
    variantSearchDebounceHandle = setTimeout(() => searchVariantsForRow(row, value), 250);
  });
  variantInput.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    clearTimeout(variantSearchDebounceHandle);
    searchVariantsForRow(row, variantInput.value);
  });
  variantInput.addEventListener('focus', () => {
    // Re-show suggestions on click: either the Item is already set (scoped variants, even
    // before typing) or there's already variant text to re-search on.
    if (itemInput.value.trim() || variantInput.value.trim()) {
      searchVariantsForRow(row, variantInput.value);
    }
  });
  variantInput.addEventListener('blur', () => {
    setTimeout(() => {
      row.querySelector('.variant-suggest-dropdown').classList.add('hidden');
    }, 150);
  });

  tbody.appendChild(row);
}

async function openNewTransferModal() {
  document.getElementById('newNo').value = 'Generating...';
  document.getElementById('newDescription').value = '';
  document.getElementById('newToWarehouse').value = currentSession?.warehouseName || '';
  document.getElementById('newToWarehouseId').value = '';
  document.getElementById('newRequestedDate').value = todayLocalDateString();
  applyEstimatedDeliveryDate();
  document.getElementById('newUseProductionCategory').checked = false;
  document.getElementById('newLinesBody').innerHTML = '';
  document.getElementById('newTransferError').classList.add('hidden');
  addNewLineRow();
  updateProductionCategoryLock();
  document.getElementById('newTransferModal').classList.remove('hidden');

  // Restore the layout this browser last used before the panel is seen. Defaults to maximized -
  // this is a wide entry grid, same reasoning as the New Purchase Order card.
  applyModalMaximized('newTransferModal', 'newTransferMaximizeBtn', readStoredFlag(TO_NEW_MAXIMIZED_KEY, true));
  document.getElementById('newTransferGeneralTab').open = readStoredFlag(TO_NEW_GENERAL_TAB_KEY, true);
  refreshNewTransferGeneralSummary();

  // From Warehouse defaults to the Production/Stock-flagged warehouse (per the checkbox); To
  // Warehouse defaults to the logged-in staff's own warehouse - same split the desktop app uses,
  // just resolved against Supabase instead of local SQL.
  await applyPreferredFromWarehouse(false);
  document.getElementById('newToWarehouseId').value = await resolveWarehouseIdByName(currentSession?.warehouseName);
  document.getElementById('newNo').value = await generateTransferNo();
  refreshNewTransferGeneralSummary();
}

async function saveNewTransfer() {
  const errorEl = document.getElementById('newTransferError');
  errorEl.classList.add('hidden');

  const no = document.getElementById('newNo').value.trim();
  if (!no) {
    errorEl.textContent = 'Document No. is required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const description = document.getElementById('newDescription').value.trim();
  const fromWarehouse = document.getElementById('newFromWarehouse').value.trim();
  const fromWarehouseId = document.getElementById('newFromWarehouseId').value.trim();
  const toWarehouse = document.getElementById('newToWarehouse').value.trim();
  const toWarehouseId = document.getElementById('newToWarehouseId').value.trim();
  const requestedDate = document.getElementById('newRequestedDate').value || null;
  const estimatedDeliveryDate = document.getElementById('newEstimatedDeliveryDate').value || null;
  const useProductionCategory = document.getElementById('newUseProductionCategory').checked;

  // Same guard as the desktop's IsSameWarehouse - compare by ID when both sides have one,
  // otherwise fall back to name.
  const sameWarehouse = fromWarehouseId && toWarehouseId
    ? fromWarehouseId === toWarehouseId
    : fromWarehouse && toWarehouse && fromWarehouse.toLowerCase() === toWarehouse.toLowerCase();
  if (fromWarehouse && toWarehouse && sameWarehouse) {
    errorEl.textContent = 'From Warehouse cannot be the same as To Warehouse.';
    errorEl.classList.remove('hidden');
    return;
  }

  const lineRows = Array.from(document.getElementById('newLinesBody').querySelectorAll('tr'));
  const lines = lineRows
    .map((row, index) => ({
      itemNo: row.querySelector('.line-item-no').value.trim(),
      variantId: row.querySelector('.line-variant-id').value || null,
      variantName: row.querySelector('.line-variant-search').value.trim() || null,
      description: row.querySelector('.line-description').value.trim(),
      qty: parseFloat(row.querySelector('.line-qty').value) || 0,
      lineNo: (index + 1) * 10000
    }))
    .filter((l) => l.itemNo);

  if (lines.length === 0) {
    errorEl.textContent = 'Add at least one line item with an Item No.';
    errorEl.classList.remove('hidden');
    return;
  }

  // A variant-carrying item can't be transferred against the parent item alone - it'd be
  // ambiguous which variant actually ships. Checked here (not just at pick time) so it also
  // catches a manually-typed Item No. and a variant selection that got cleared afterward (typing
  // a different code invalidates it - see the item input's blur handler).
  const linesMissingVariant = [];
  for (const line of lines) {
    if (line.variantId) continue;
    const { data, error } = await supabaseClient.rpc('staff_search_variants', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_item_code: line.itemNo,
      p_page: 1
    });
    if (!error && data && data.length > 0) {
      linesMissingVariant.push(line.itemNo);
    }
  }

  if (linesMissingVariant.length > 0) {
    errorEl.textContent = `Select a variant for: ${linesMissingVariant.join(', ')} - ${linesMissingVariant.length > 1 ? 'these items have' : 'this item has'} variants, so a specific one must be chosen.`;
    errorEl.classList.remove('hidden');
    return;
  }

  if (!window.confirm(`This will send request to ${fromWarehouse} would you like to proceed?`)) {
    return;
  }

  const saveBtn = document.getElementById('saveTransferBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  try {
    await upsertRow('Transfer_Header', { 'No.': no }, {
      'Description': description || null,
      'Status': 'Requested',
      'Requested Date': requestedDate,
      'Estimated Delivery Date': estimatedDeliveryDate,
      'From Warehouse ID': fromWarehouseId || null,
      'From Warehouse': fromWarehouse || null,
      'To Warehouse ID': toWarehouseId || null,
      'To Warehouse': toWarehouse || null,
      'Use Production Category': useProductionCategory,
      'Requested By': currentSession?.displayName || currentSession?.username || null,
      // Locked from the moment it's requested - no line/qty editing surface has ever existed
      // post-creation anyway, this just makes that permanent/explicit and shows the lock icon
      // right away (see supabase_transfer_orders_lock_column.sql). Does NOT block Cancel - see
      // updateManageActionButtons' comment on cancelTransferBtn.
      'Is Locked': true,
      'Locked At': new Date().toISOString(),
      'Locked By': currentSession?.displayName || currentSession?.username || null
    });

    for (const line of lines) {
      await upsertRow('Transfer_Line', { 'Document No.': no, 'Line No.': line.lineNo }, {
        'Item No.': line.itemNo,
        'Variant ID': line.variantId,
        'Variant Name': line.variantName,
        'Description': line.description || null,
        'Qty To Transfer': line.qty
      });
    }

    document.getElementById('newTransferModal').classList.add('hidden');
    await loadHeaders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to save transfer order.');
    errorEl.classList.remove('hidden');
  } finally {
    saveBtn.disabled = false;
    saveBtn.textContent = 'Save Transfer Order';
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Transfer Orders');

  currentSessionIsProductionWarehouse = await resolveIsProductionWarehouse(session);

  restoreFilters();

  // Deep-link from the Dashboard's notification center, e.g. transfer-orders.html?status=Requested -
  // takes precedence over whatever status filter was previously persisted for this tab.
  const statusParam = new URLSearchParams(window.location.search).get('status');
  if (statusParam) {
    document.getElementById('statusFilter').value = statusParam;
    saveFilters();
  }

  document.getElementById('searchInput').addEventListener('input', () => {
    saveFilters();
    renderHeaders();
  });
  document.getElementById('statusFilter').addEventListener('change', () => {
    saveFilters();
    renderHeaders();
  });
  document.getElementById('refreshBtn').addEventListener('click', loadHeaders);
  document.getElementById('newTransferBtn').addEventListener('click', openNewTransferModal);
  document.getElementById('closeNewTransferBtn').addEventListener('click', () =>
    document.getElementById('newTransferModal').classList.add('hidden')
  );
  document.getElementById('closeViewLinesBtn').addEventListener('click', () =>
    document.getElementById('viewLinesModal').classList.add('hidden')
  );
  document.getElementById('newTransferMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('newTransferModal').classList.contains('modal-maximized');
    applyModalMaximized('newTransferModal', 'newTransferMaximizeBtn', nowMaximized);
    writeStoredFlag(TO_NEW_MAXIMIZED_KEY, nowMaximized);
  });
  document.getElementById('viewLinesMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('viewLinesModal').classList.contains('modal-maximized');
    applyModalMaximized('viewLinesModal', 'viewLinesMaximizeBtn', nowMaximized);
    writeStoredFlag(TO_MANAGE_MAXIMIZED_KEY, nowMaximized);
  });
  document.getElementById('newTransferGeneralTab').addEventListener('toggle', (e) => {
    writeStoredFlag(TO_NEW_GENERAL_TAB_KEY, e.target.open);
  });
  document.getElementById('viewLinesGeneralTab').addEventListener('toggle', (e) => {
    writeStoredFlag(TO_MANAGE_GENERAL_TAB_KEY, e.target.open);
  });
  document.getElementById('newNo').addEventListener('input', refreshNewTransferGeneralSummary);
  document.getElementById('newDescription').addEventListener('input', refreshNewTransferGeneralSummary);
  document.getElementById('printTransferBtn').addEventListener('click', () => {
    if (currentManageDocNo) window.open(`transfer-order-print.html?no=${encodeURIComponent(currentManageDocNo)}`, '_blank');
  });
  document.getElementById('printProductionBtn').addEventListener('click', () => printProductionOrder(currentManageDocNo));
  document.getElementById('addLineBtn').addEventListener('click', addNewLineRow);
  document.getElementById('saveTransferBtn').addEventListener('click', saveNewTransfer);
  document.getElementById('shipTransferBtn').addEventListener('click', () => shipTransferOrder(currentManageDocNo));
  document.getElementById('createPoFromTransferBtn').addEventListener('click', () => openCreatePoModal(currentManageDocNo));
  document.getElementById('createPoConfirmBtn').addEventListener('click', confirmCreatePo);
  document.getElementById('createPoCloseBtn').addEventListener('click', () => document.getElementById('createPoModal').classList.add('hidden'));
  document.getElementById('receiveTransferBtn').addEventListener('click', () => receiveTransferOrder(currentManageDocNo));
  document.getElementById('cancelTransferBtn').addEventListener('click', () => cancelTransferOrder(currentManageDocNo));
  document.getElementById('deleteTransferBtn').addEventListener('click', () => deleteTransferOrder(currentManageDocNo));
  document.getElementById('editFromWarehouseBtn').addEventListener('click', openFromWarehouseEdit);
  document.getElementById('cancelFromWarehouseEditBtn').addEventListener('click', closeFromWarehouseEdit);
  document.getElementById('saveFromWarehouseBtn').addEventListener('click', saveFromWarehouseEdit);
  document.getElementById('newUseProductionCategory').addEventListener('change', (e) =>
    applyPreferredFromWarehouse(e.target.checked)
  );

  await loadHeaders();

  // Deep-link from Serial Tracker's Source Doc. column (see renderSourceDocCell in
  // serialTracker.js) - opens straight into the Manage modal for that order.
  const docParam = new URLSearchParams(window.location.search).get('doc');
  if (docParam) {
    await openManageModal(docParam);
  }
})();
