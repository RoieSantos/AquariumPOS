// Online Orders page logic (any active staff).
//
// Reads straight from the persisted public."OnlineOrders" table via admin_list_online_orders() -
// no live Pancake calls for LISTING orders, since the background cron job
// (cron_sync_online_orders_from_pancake, runs every minute) already keeps that table fresh on
// its own. This makes the page load instantly regardless of backlog size, with no
// throttling/incremental-catch-up/chunked-paging complexity needed.
//
// Status IS writable from here though (see statusCellHtml/handleOrderTableClick below) -
// admin_update_online_order_status (supabase_online_order_portal_status_update.sql) pushes the
// change live to Pancake, mirroring the desktop app's OnlineOrdersForm grid instead of just
// reading whatever the last sync happened to pull in.
//
// Deliberately NOT a free-form status editor - per direct request, staff can't manually set an
// order to an arbitrary status from here. The only manual action offered is a "To Ship" button
// for the common packed-and-ready workflow (with a confirm() prompt before it fires); every other
// status transition (Shipped, Pending Transfer, In-Transit, Received, Production Done) only ever
// happens via the background Pancake sync, same as before this status-write feature existed.
//
// No password re-unlock prompt here (unlike the super-user-only setup pages) - since this page
// is open to any active staff member, it reuses the password captured at login (session.password,
// see auth.js) to satisfy the RPC's re-verification requirement without asking again.
let currentSession = null;
let orderSearchDebounceHandle = null;
let loadGeneration = 0;
let currentPage = 1;
let currentPageSize = 50;

// Deep-link filters from a Dashboard finance card (?period=month|today|prevmonth, ?scope=walkin,
// ?filter=outstanding) or a Sales by Staff figure (?confirmedBy=...&period=...) - set once in
// init() from the URL, then applied on every load/reload for the rest of this page view
// (search/status typed afterward combine with these, they don't replace them). See the
// finance-card hrefs in dashboard.html and staffStatLinkHtml in js/dashboard.js.
let currentPeriod = null;
let currentScope = null;
let outstandingOnly = false;
let currentConfirmedBy = null;

// Per "if the user is a online order staff They can only see Confirmed / Printed / To Ship" -
// applied as an exact-match IN-list server-side (see admin_list_online_orders' p_status_in in
// supabase_online_order_staff_status_scope.sql), not just a client-side hide, so the restriction
// holds even against a direct RPC call. "Please be aware that they dont need to see price" -
// hidePriceColumns strips the Delivery Fee column here (see orderRowsHtml) and every price column
// on the Online Order Lines drill-down (js/onlineOrderLines.js).
const ONLINE_ORDER_STAFF_STATUS_SCOPE = ['Confirmed', 'Printed', 'To Ship'];
let hidePriceColumns = false;

// Per "i want to show the online order per category: Confirmed / Printed / To-Ship... built it as
// a mobile GUI friendly. I want button style Confirmed Printed and ToShip, make it very Mobile
// friendly" - Online Order Staff get a tab per status (docs/online-orders.html's #groupedTabs)
// over a stacked card list (#groupedOrdersList) instead of the wide flat table, since this role
// works off a phone in the warehouse. Everyone else keeps the original flat table (#flatOrdersView)
// - see the isOnlineOrderStaff branch in loadOrders/init below.
const GROUP_COUNT_IDS = {
  'Confirmed': 'groupCountConfirmed',
  'Printed': 'groupCountPrinted',
  'To Ship': 'groupCountToShip'
};

// Which tab is currently showing in the grouped (Online Order Staff) view, and the last set of
// rows fetched for it - switching tabs just re-renders from this, no server round-trip needed
// since loadOrders already fetches all 3 statuses (up to the 200-row cap) in one call.
let activeGroupStatus = 'Confirmed';
let lastGroupedRows = [];

// Whether the logged-in staff's own warehouse is flagged Production - gates whether "To Ship"
// needs to check for serial-tracked lines at all (see EnsureOrderSerialTrackingAsync's own gate in
// OnlineOrdersForm.cs - a non-production store never needed this). Resolved once at init, same
// pattern (and duplicated for the same "no shared module system between these plain <script>
// pages" reason) as transferOrders.js/serialTracker.js's own resolveIsProductionWarehouse.
let currentSessionIsProductionWarehouse = true;

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

// Warehouse-scoped staff (StaffUsers.WarehouseName set) only see orders for their own
// warehouse - same convention as Transfer Orders (js/transferOrders.js). Orders with no
// resolved warehouse_name (e.g. LocationID didn't match any synced Warehouses row) are
// hidden while scoped, since we can't confirm they belong to this user's warehouse.
function matchesWarehouseFilter(order) {
  if (!currentSession.warehouseName) return true;
  return (order.warehouse_name || '') === currentSession.warehouseName;
}

const STATUS_SUMMARY_ELEMENT_IDS = {
  'Confirmed': 'statusCountConfirmed',
  'Printed': 'statusCountPrinted',
  'To Ship': 'statusCountToShip',
  'Shipped': 'statusCountShipped',
  'Cancelled': 'statusCountCancelled'
};

// Exact per-status record counts, from the persisted OnlineOrders table (kept fresh by the
// background cron sync) - fast/instant since it's a simple grouped count on a local table (see
// admin_get_online_order_status_summary in supabase_orders_sync_tables.sql).
async function loadStatusSummary() {
  if (!currentSession.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_online_order_status_summary', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_name: currentSession.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_online_order_status_summary failed:', error);
    return;
  }

  data.forEach((row) => {
    const elementId = STATUS_SUMMARY_ELEMENT_IDS[row.status_label];
    if (elementId) {
      document.getElementById(elementId).textContent = row.order_count;
    }
  });
}

// Per "put a flag in the online header to show if an order has 10mm glass or 12mm glass custom
// aquarium it may need or require an attachment" - o.glass_thickness comes from
// admin_list_online_orders() (see supabase_orders_sync_tables.sql), which scans that order's
// synced lines for a 10mm/12mm mention. Blank when no such line was found.
function glassBadgeHtml(order) {
  if (!order.glass_thickness) return '';
  return `<span class="badge badge-glass" title="This order has a ${order.glass_thickness} glass custom aquarium line - it may need an attachment (see Online Order Lines).">${order.glass_thickness} glass</span>`;
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function statusCellHtml(o) {
  const status = o.status || '';
  const statusLower = status.trim().toLowerCase();
  if (statusLower === 'new') {
    return `<span title="Ask the online sales team to confirm this order first.">${escapeHtml(status)}</span>`;
  }

  // Mirrors the desktop app's IsPrintedStatusForRow gate on MarkRowAsToShipAsync (OnlineOrdersForm.cs)
  // and admin_update_online_order_status' matching server-side check - only a 'Printed' order can
  // be marked 'To Ship' from here, not 'Confirmed' or anything else, so the button only appears
  // then (the RPC would reject it anyway, but showing it only when it'll actually work avoids a
  // confusing rejection).
  const showToShipBtn = statusLower === 'printed';
  if (!showToShipBtn) {
    return escapeHtml(status);
  }

  return `
    <div class="status-cell-wrap" style="display:flex; flex-direction:column; gap:4px; align-items:flex-start;">
      <span class="status-text">${escapeHtml(status)}</span>
      <button type="button" class="btn btn-primary btn-sm status-to-ship-btn" style="font-size:12px; padding:3px 8px;">To Ship</button>
    </div>
  `;
}

function orderRowsHtml(orders) {
  return orders
    .map((o) => `
      <tr data-order-id="${o.order_id}">
        <td>${o.order_id || ''}</td>
        <td>${o.order_date || ''}</td>
        <td>${o.order_time || ''}</td>
        <td>${o.customer_name || ''}</td>
        <td>${statusCellHtml(o)}</td>
        <td>${o.confirmed_by || ''}</td>
        <td>${o.created_by || ''}</td>
        <td>${glassBadgeHtml(o)}</td>
        <td>${o.note_print || ''}</td>
        ${hidePriceColumns ? '' : `<td>${o.delivery_fee ? Number(o.delivery_fee).toFixed(2) : ''}</td>`}
        <td>${o.warehouse_name || o.location_id || ''}</td>
        <td><span class="badge ${o.for_delivery ? 'badge-success' : 'badge-neutral'}">${o.for_delivery ? 'Yes' : 'No'}</span></td>
        <td>${o.estimated_delivery_date || ''}</td>
        <td>${o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : ''}</td>
        <td><a href="online-order-lines.html?order=${encodeURIComponent(o.order_id)}">View</a></td>
      </tr>
    `)
    .join('');
}

// Stacked card for the grouped (Online Order Staff / mobile) view - one order's info as
// label/value rows instead of a wide table, so nothing gets clipped or forces horizontal
// scrolling on a phone. The "To Ship" button follows the same rule as statusCellHtml (only shown
// once an order is 'Printed').
function orderCardHtml(o) {
  const status = o.status || '';
  // Same 'Printed' gate as statusCellHtml above - see the comment there.
  const showToShipBtn = status.trim().toLowerCase() === 'printed';

  return `
    <div class="order-card" data-order-id="${o.order_id}">
      <div class="order-card-top">
        <span class="order-card-id">#${o.order_id || ''}</span>
        ${glassBadgeHtml(o)}
      </div>
      <div class="order-card-customer">${o.customer_name || 'No name on order'}</div>
      <div class="order-card-grid">
        <span class="order-card-label">Date</span><span>${o.order_date || ''} ${o.order_time || ''}</span>
        <span class="order-card-label">Warehouse</span><span>${o.warehouse_name || o.location_id || ''}</span>
        <span class="order-card-label">Delivery</span><span><span class="badge ${o.for_delivery ? 'badge-success' : 'badge-neutral'}">${o.for_delivery ? 'Yes' : 'No'}</span> ${o.estimated_delivery_date ? '&middot; ' + o.estimated_delivery_date : ''}</span>
        <span class="order-card-label">Confirmed By</span><span>${o.confirmed_by || '-'}</span>
        ${o.note_print ? `<span class="order-card-label">Print Note</span><span>${o.note_print}</span>` : ''}
      </div>
      <div class="order-card-actions">
        <a class="btn btn-secondary btn-sm" href="online-order-lines.html?order=${encodeURIComponent(o.order_id)}">View Order Lines</a>
        ${showToShipBtn ? '<button type="button" class="btn btn-primary status-to-ship-btn">To Ship</button>' : ''}
      </div>
    </div>
  `;
}

// Filters the last-fetched rows down to whichever status tab is active and renders them as cards
// - called both after a fresh fetch (loadOrders) and on a plain tab click (no re-fetch needed,
// see wireGroupedTabs below).
function renderActiveGroupTab() {
  const list = document.getElementById('groupedOrdersList');
  const bucket = lastGroupedRows.filter((o) => (o.status || '').trim().toLowerCase() === activeGroupStatus.toLowerCase());
  list.innerHTML = bucket.length === 0
    ? `<p class="muted">No ${activeGroupStatus} orders.</p>`
    : bucket.map(orderCardHtml).join('');
}

// Splits rows into the Confirmed/Printed/To Ship counts (see GROUP_COUNT_IDS above), stores them
// for tab switching, and renders whichever tab is currently active. fetchedCount/totalCount come
// straight from the server response (BEFORE the client-side warehouse/outstanding post-filters
// loadOrders applies) - used only to flag when the 200-row fetch cap might be hiding older
// matching orders, not to decide what's actually shown.
function renderGroupedOrders(rows, fetchedCount, totalCount) {
  lastGroupedRows = rows;

  ONLINE_ORDER_STAFF_STATUS_SCOPE.forEach((status) => {
    const count = rows.filter((o) => (o.status || '').trim().toLowerCase() === status.toLowerCase()).length;
    document.getElementById(GROUP_COUNT_IDS[status]).textContent = count;
  });

  renderActiveGroupTab();

  const note = document.getElementById('groupedOrdersNote');
  if (fetchedCount < totalCount) {
    note.textContent = `Showing the most recent ${fetchedCount} of ${totalCount} matching orders. Use search to find an older one if it's not listed below.`;
    note.classList.remove('hidden');
  } else {
    note.classList.add('hidden');
  }
}

function refreshCurrentOrders() {
  return loadOrders(document.getElementById('orderSearchInput').value.trim(), document.getElementById('statusFilterInput').value.trim());
}

// Shared apply step for the "To Ship" button. admin_update_online_order_status re-validates the
// transition server-side regardless of what's offered here (blocked-from-'new', 'To Ship' only).
// serialRunningNos (from the serial picker modal, production warehouses only - see
// handleToShipClick/supabase_online_order_to_ship_serials.sql) are claimed inside the same RPC
// call, atomically with the Pancake status PATCH - null/empty when no serial pick was needed.
//
// The photo (if any) is sent as its OWN separate call (admin_send_online_order_status_photo),
// per direct instruction - AFTER the status change/text message above has already gone through,
// never bundled into that RPC. This keeps admin_update_online_order_status's own runtime short
// (it used to chain a status PATCH + bank_payments snapshot/restore + text message + photo POST
// all in one request, long enough to occasionally hit the authenticator role's statement_timeout)
// and means a slow/failing photo attach can never roll back the actual status change.
async function applyStatusChange(orderId, newStatus, notifyCustomer, photoUrl, photoStoragePath, serialRunningNos, triggerEl) {
  triggerEl.disabled = true;

  const { data, error } = await supabaseClient.rpc('admin_update_online_order_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_new_status: newStatus,
    p_notify_customer: notifyCustomer,
    p_serial_running_nos: serialRunningNos && serialRunningNos.length > 0 ? serialRunningNos : null
  });

  if (error) {
    alert('Could not update status: ' + error.message);
    triggerEl.disabled = false;
    return;
  }

  const result = data && data[0];
  if (notifyCustomer && result && !result.message_sent) {
    alert('Status updated, but the customer notification failed to send: ' + (result.message_error || 'unknown error'));
  }

  if (photoUrl) {
    const { data: photoData, error: photoError } = await supabaseClient.rpc('admin_send_online_order_status_photo', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_photo_url: photoUrl,
      p_photo_storage_path: photoStoragePath
    });

    const photoResult = photoData && photoData[0];
    if (photoError || (photoResult && photoResult.photo_sent === false)) {
      // Status change (and text message, if requested) already went through fine - only the
      // photo attachment failed. Surface it so staff know to just describe the item to the
      // customer instead, without implying the whole notification failed.
      const detail = photoError ? photoError.message : (photoResult?.photo_error || 'unknown error');
      alert('Status updated, but the photo could not be attached: ' + detail);
    }
  }

  await refreshCurrentOrders();
}

// Fetches which of this order's lines need a serial pick before shipping, and how many - see
// supabase_online_order_to_ship_serials.sql (resolves Pancake's item_code/category server-side and
// applies the same prefix/IsProductionCategory rule OnlineOrdersForm.cs uses, so the client doesn't
// need to duplicate that logic).
async function getOrderSerialRequirements(orderId) {
  const { data, error } = await supabaseClient.rpc('admin_get_online_order_serial_requirements', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });
  if (error) throw error;
  return data || [];
}

// --- Serial picker modal (#shipSerialModal) ---------------------------------------------------
// Reuses the .serial-tag-picker/.serial-tag-chip/.item-suggest-* styling and interaction pattern
// Transfer Orders already established (js/transferOrders.js's searchAvailableSerialsForRow etc.) -
// duplicated rather than shared, same "no module system" reason as resolveIsProductionWarehouse
// above. Only offers EXISTING IN_STOCK serials (see supabase_online_order_to_ship_serials.sql's
// header comment) - if staff can't find enough, Confirm blocks with a message pointing them to the
// desktop app instead of letting them ship short.

function getSelectedSerialsForShipPicker(picker) {
  try {
    return JSON.parse(picker.dataset.selected || '[]');
  } catch {
    return [];
  }
}

function updateShipSerialTagCount(picker) {
  const selected = getSelectedSerialsForShipPicker(picker);
  const required = Math.max(0, parseFloat(picker.dataset.required) || 0);
  const countEl = picker.querySelector('.serial-tag-count');
  const satisfied = selected.length === required;
  countEl.textContent = `${selected.length} / ${required} selected`;
  countEl.classList.toggle('satisfied', satisfied && required > 0);
  countEl.classList.toggle('unsatisfied', !satisfied);
}

function renderShipSerialTagChips(picker) {
  const chipsEl = picker.querySelector('.serial-tag-chips');
  const selected = getSelectedSerialsForShipPicker(picker);
  chipsEl.innerHTML = selected
    .map((s) => `
      <span class="serial-tag-chip" data-running-serial-no="${s.runningSerialNo}">
        ${escapeHtml(s.serialNo)}<span class="serial-tag-chip-remove" title="Remove">&times;</span>
      </span>
    `)
    .join('');

  chipsEl.querySelectorAll('.serial-tag-chip-remove').forEach((removeBtn) => {
    removeBtn.addEventListener('click', () => {
      const chip = removeBtn.closest('.serial-tag-chip');
      const runningSerialNo = Number(chip.dataset.runningSerialNo);
      const remaining = getSelectedSerialsForShipPicker(picker).filter((s) => s.runningSerialNo !== runningSerialNo);
      picker.dataset.selected = JSON.stringify(remaining);
      renderShipSerialTagChips(picker);
      updateShipSerialTagCount(picker);
    });
  });
}

function addSerialTagToShipPicker(picker, serial) {
  const selected = getSelectedSerialsForShipPicker(picker);
  if (selected.some((s) => s.runningSerialNo === serial.runningSerialNo)) return;
  selected.push(serial);
  picker.dataset.selected = JSON.stringify(selected);
  renderShipSerialTagChips(picker);
  updateShipSerialTagCount(picker);
}

async function searchAvailableSerialsForShipLine(lineEl, picker, searchText) {
  const dropdown = picker.querySelector('.serial-tag-dropdown');
  const itemCode = lineEl.dataset.itemCode;
  const variationId = lineEl.dataset.variationId;

  let query = supabaseClient
    .from('ItemSerialTracking')
    .select('RunningSerialNo, SerialNo, ItemCode, VariantCode')
    .eq('Status', 'IN_STOCK')
    .eq('ItemCode', itemCode);
  query = variationId ? query.eq('VariantCode', variationId) : query.or('VariantCode.is.null,VariantCode.eq.');
  // Only offer serials physically at the staff member's own location - same reasoning as Transfer
  // Orders' identical restriction (searchAvailableSerialsForRow). Staff with no assigned warehouse
  // stay unrestricted, same convention used everywhere else this session field is checked.
  if (currentSession?.warehouseName) {
    query = query.eq('Location', currentSession.warehouseName);
  }
  if (searchText && searchText.trim()) {
    query = query.ilike('SerialNo', `%${searchText.trim()}%`);
  }
  query = query.order('SerialNo').limit(20);

  const { data, error } = await query;

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${escapeHtml(error.message)}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const selected = getSelectedSerialsForShipPicker(picker);
  const alreadySelected = new Set(selected.map((s) => s.runningSerialNo));
  const available = (data || []).filter((s) => !alreadySelected.has(s.RunningSerialNo));

  if (available.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No available serials found.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = available
    .map((s) => `<div class="item-suggest-option" data-running-serial-no="${s.RunningSerialNo}" data-serial-no="${encodeURIComponent(s.SerialNo)}">${escapeHtml(s.SerialNo)}</div>`)
    .join('');
  dropdown.classList.remove('hidden');

  // mousedown + preventDefault, same reasoning as Transfer Orders' identical picker - keeps the
  // search input focused so there's no blur-vs-click race hiding the dropdown before a pick lands.
  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      addSerialTagToShipPicker(picker, {
        runningSerialNo: Number(opt.dataset.runningSerialNo),
        serialNo: decodeURIComponent(opt.dataset.serialNo)
      });
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
      picker.querySelector('.serial-tag-search').value = '';
    });
  });
}

function wireShipSerialPicker(lineEl, picker) {
  updateShipSerialTagCount(picker);

  const searchInput = picker.querySelector('.serial-tag-search');
  const dropdown = picker.querySelector('.serial-tag-dropdown');
  let debounceHandle = null;

  searchInput.addEventListener('input', (e) => {
    clearTimeout(debounceHandle);
    const value = e.target.value;
    debounceHandle = setTimeout(() => searchAvailableSerialsForShipLine(lineEl, picker, value), 250);
  });
  searchInput.addEventListener('focus', () => searchAvailableSerialsForShipLine(lineEl, picker, searchInput.value));
  searchInput.addEventListener('blur', () => {
    setTimeout(() => dropdown.classList.add('hidden'), 150);
  });
}

function renderShipSerialModal(requirements) {
  const container = document.getElementById('shipSerialModalLines');
  container.innerHTML = requirements
    .map((r) => `
      <div class="ship-serial-line" data-line-id="${r.line_id}" data-item-code="${escapeHtml(r.item_code)}" data-variation-id="${escapeHtml(r.variation_id || '')}" style="margin-bottom:18px;">
        <div class="ship-serial-line-label" style="font-weight:600; margin-bottom:6px;">${escapeHtml(r.description || r.item_code)} <span class="muted">(need ${r.quantity_needed})</span></div>
        <div class="serial-tag-picker" data-required="${r.quantity_needed}" data-selected="[]">
          <div class="serial-tag-count muted">0 / ${r.quantity_needed} selected</div>
          <div class="serial-tag-chips"></div>
          <input type="text" class="serial-tag-search" placeholder="Search serial no..." autocomplete="off" />
          <div class="serial-tag-dropdown hidden"></div>
        </div>
      </div>
    `)
    .join('');

  container.querySelectorAll('.ship-serial-line').forEach((lineEl) => {
    wireShipSerialPicker(lineEl, lineEl.querySelector('.serial-tag-picker'));
  });
}

// Resolves with an array of runningSerialNo once every line is fully picked and Confirm is
// clicked, or null if staff cancels - handleToShipClick treats null as "abort To Ship entirely".
let shipSerialModalResolve = null;

function openShipSerialModal(requirements) {
  return new Promise((resolve) => {
    shipSerialModalResolve = resolve;
    document.getElementById('shipSerialModalError').classList.add('hidden');
    renderShipSerialModal(requirements);
    document.getElementById('shipSerialModal').classList.remove('hidden');
  });
}

function closeShipSerialModal(result) {
  document.getElementById('shipSerialModal').classList.add('hidden');
  const resolve = shipSerialModalResolve;
  shipSerialModalResolve = null;
  if (resolve) resolve(result);
}

function wireShipSerialModalButtons() {
  document.getElementById('shipSerialModalCancelBtn').addEventListener('click', () => closeShipSerialModal(null));

  document.getElementById('shipSerialModalConfirmBtn').addEventListener('click', () => {
    const pickers = Array.from(document.querySelectorAll('#shipSerialModalLines .serial-tag-picker'));
    const errorEl = document.getElementById('shipSerialModalError');
    const incompleteLabels = [];
    const allSelected = [];

    pickers.forEach((picker) => {
      const required = Math.max(0, parseFloat(picker.dataset.required) || 0);
      const selected = getSelectedSerialsForShipPicker(picker);
      if (selected.length < required) {
        const label = picker.closest('.ship-serial-line').querySelector('.ship-serial-line-label').textContent.trim();
        incompleteLabels.push(label);
      }
      allSelected.push(...selected);
    });

    if (incompleteLabels.length > 0) {
      errorEl.textContent = `Pick a serial for every unit needed: ${incompleteLabels.join(', ')}. If there aren't enough available, finish this order on the desktop app instead.`;
      errorEl.classList.remove('hidden');
      return;
    }

    closeShipSerialModal(allSelected.map((s) => s.runningSerialNo));
  });
}

// Tracks which order/button is waiting on the shared #toShipPhotoInput's result (see
// handleToShipClick/handleToShipPhotoSelected/handleToShipPhotoCancelled below).
let pendingToShip = null;

function handleOrderTableClick(event) {
  const toShipBtn = event.target.closest('.status-to-ship-btn');
  if (!toShipBtn) return;

  // Generic [data-order-id] (not tr[data-order-id]) - matches both the flat table's <tr> rows and
  // the grouped view's <div class="order-card"> cards (see orderCardHtml above), since the same
  // handler covers both.
  const row = event.target.closest('[data-order-id]');
  if (!row) return;

  handleToShipClick(row.dataset.orderId, toShipBtn);
}

// Mirrors OnlineOrdersForm.cs's EnsureOrderSerialTrackingAsync gate: at a production warehouse, a
// serial-tracked line (e.g. a custom aquarium) needs a physical unit's serial picked and tied to
// this order before it can ship - see supabase_online_order_to_ship_serials.sql. Only checked at
// all when the logged-in staff's own warehouse is Production (currentSessionIsProductionWarehouse,
// resolved once at init) - a regular store's To Ship never needed this, same as the desktop.
// Cancelling the serial picker aborts the whole To Ship action (nothing sent, nothing changed).
async function handleToShipClick(orderId, toShipBtn) {
  let serialRunningNos = null;

  if (currentSessionIsProductionWarehouse) {
    toShipBtn.disabled = true;
    let requirements;
    try {
      requirements = await getOrderSerialRequirements(orderId);
    } catch (err) {
      alert('Could not check serial requirements for this order: ' + (err?.message || 'unknown error'));
      toShipBtn.disabled = false;
      return;
    }
    toShipBtn.disabled = false;

    if (requirements.length > 0) {
      serialRunningNos = await openShipSerialModal(requirements);
      if (serialRunningNos === null) return; // cancelled - To Ship not sent at all
    }
  }

  // Mirrors OnlineOrdersForm.cs's "To Ship" behavior: asks staff to confirm before notifying the
  // customer (the status change itself always goes through either way - the confirm only gates the
  // message/photo). This is the only manual status action offered on this page (see the comment
  // near the top of this file) - the button click plus the confirm() prompt means a status change
  // can never fire from a single accidental click.
  //
  // Per direct request, staff can snap a photo of the packed order on their phone and have it go
  // out with the ready notification - only prompted when notifying, since a photo is pointless
  // otherwise. Cancelling the camera/file picker just sends the text-only message.
  const notifyCustomer = window.confirm('Order complete? Do you want to update the customer?');

  if (!notifyCustomer) {
    applyStatusChange(orderId, 'To Ship', false, null, null, serialRunningNos, toShipBtn);
    return;
  }

  pendingToShip = { orderId, triggerEl: toShipBtn, serialRunningNos };
  document.getElementById('toShipPhotoInput').click();
}

// Uploads the captured photo via the same signed-upload flow as Online Order Line attachments (see
// supabase_online_order_status_photo.sql) - returns {url, storagePath}, or null (with an alert) if
// the upload itself failed, so the caller can still fall back to sending the text-only message.
async function uploadToShipPhoto(orderId, file) {
  const { data, error } = await supabaseClient.rpc('admin_create_online_order_status_photo_upload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_file_name: file.name || 'photo.jpg'
  });

  if (error || !data || !data[0]) {
    alert('Could not prepare the photo upload, sending the text-only message instead: ' + (error ? error.message : 'unknown error'));
    return null;
  }

  const { storage_path, upload_token, public_url } = data[0];
  const { error: uploadError } = await supabaseClient.storage
    .from('online-order-status-photos')
    .uploadToSignedUrl(storage_path, upload_token, file);

  if (uploadError) {
    alert('Photo upload failed, sending the text-only message instead: ' + uploadError.message);
    return null;
  }

  return { url: public_url, storagePath: storage_path };
}

async function handleToShipPhotoSelected(event) {
  const input = event.target;
  const file = input.files && input.files[0];
  const pending = pendingToShip;
  pendingToShip = null;
  input.value = ''; // reset so picking the same file again still fires 'change' next time

  if (!pending) return;

  if (!file) {
    // Some browsers fire 'change' with an empty file list instead of a 'cancel' event.
    applyStatusChange(pending.orderId, 'To Ship', true, null, null, pending.serialRunningNos, pending.triggerEl);
    return;
  }

  const photo = await uploadToShipPhoto(pending.orderId, file);
  applyStatusChange(pending.orderId, 'To Ship', true, photo ? photo.url : null, photo ? photo.storagePath : null, pending.serialRunningNos, pending.triggerEl);
}

function handleToShipPhotoCancelled() {
  const pending = pendingToShip;
  pendingToShip = null;
  if (!pending) return;
  applyStatusChange(pending.orderId, 'To Ship', true, null, null, pending.serialRunningNos, pending.triggerEl);
}

async function loadOrders(search, status) {
  const myGeneration = ++loadGeneration;
  const grouped = !!currentSession.isOnlineOrderStaff;
  const trimmedSearch = (search || '').trim();
  const trimmedStatus = (status || '').trim();

  const { data, error } = await supabaseClient.rpc('admin_list_online_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: trimmedSearch || null,
    p_status: trimmedStatus || null,
    p_period: currentPeriod,
    p_walkin_only: currentScope === 'walkin',
    p_page: currentPage,
    p_page_size: currentPageSize,
    p_confirmed_by: currentConfirmedBy,
    p_status_in: grouped ? ONLINE_ORDER_STAFF_STATUS_SCOPE : null
  });

  if (myGeneration !== loadGeneration) return;

  if (error) {
    if (grouped) {
      document.getElementById('groupedOrdersList').innerHTML = `<p class="error-text">${error.message}</p>`;
    } else {
      document.getElementById('orderTableBody').innerHTML = `<tr><td colspan="15" class="error-text">${error.message}</td></tr>`;
    }
    return;
  }

  // NOTE: warehouse-scoping/outstanding-only are client-side post-filters (no matching server
  // param), applied AFTER the server already paged the unfiltered result - a warehouse-scoped
  // or outstanding-only view can therefore show fewer than pageSize rows on a page, and the
  // pagination bar's total/page count reflects the pre-filter total, not the filtered count
  // actually shown. Same pre-existing tradeoff the old fixed-500-row fetch had; not something
  // this pagination pass changes.
  let rows = (data || []).filter(matchesWarehouseFilter);
  if (outstandingOnly) {
    rows = rows.filter((o) => Number(o.balance) > 0);
  }

  // Online Order Staff get the tabbed card view (renderGroupedOrders) instead of the flat table +
  // pagination bar - see the isOnlineOrderStaff branch in init() below, which hides
  // #flatOrdersView/shows #groupedOrdersView and bumps currentPageSize to the server's 200-row
  // cap so this single fetch covers their whole Confirmed/Printed/To Ship queue.
  if (grouped) {
    renderGroupedOrders(rows, (data || []).length, data?.[0]?.total_count || 0);
    return;
  }

  const tbody = document.getElementById('orderTableBody');
  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="15" class="muted">No online orders found.</td></tr>'
    : orderRowsHtml(rows);

  renderPaginationBar(
    document.getElementById('orderPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadOrders(trimmedSearch, trimmedStatus); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadOrders(trimmedSearch, trimmedStatus); }
    }
  );
}

function escapeCsvValue(value) {
  const str = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(str) ? '"' + str.replace(/"/g, '""') + '"' : str;
}

// Super-user-only "Export to Excel" (exportExcelBtn - see init()'s session.isSuperUser gate).
// Exports every order matching the CURRENT search/status/period/scope/confirmedBy/warehouse
// filters, not just the page currently on screen - loops admin_list_online_orders at its own
// max page size (200, see v_page_size in supabase_orders_sync_tables.sql) until exhausted.
// Plain CSV (not a real .xlsx) - Excel opens it natively with no extra library/CDN dependency;
// the UTF-8 BOM prefix keeps Excel from mangling the Peso sign in any money fields later added.
async function exportOrdersToExcel() {
  const btn = document.getElementById('exportExcelBtn');
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');
  const trimmedSearch = searchInput.value.trim();
  const trimmedStatus = statusInput.value.trim();
  const exportPageSize = 200;

  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Exporting...';

  try {
    const allRows = [];
    let page = 1;
    for (;;) {
      const { data, error } = await supabaseClient.rpc('admin_list_online_orders', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_search: trimmedSearch || null,
        p_status: trimmedStatus || null,
        p_period: currentPeriod,
        p_walkin_only: currentScope === 'walkin',
        p_page: page,
        p_page_size: exportPageSize,
        p_confirmed_by: currentConfirmedBy
      });

      if (error) {
        alert('Export failed: ' + error.message);
        return;
      }

      let rows = (data || []).filter(matchesWarehouseFilter);
      if (outstandingOnly) {
        rows = rows.filter((o) => Number(o.balance) > 0);
      }
      allRows.push(...rows);

      if (!data || data.length < exportPageSize) break;
      page += 1;
    }

    if (allRows.length === 0) {
      alert('No orders to export for the current filters.');
      return;
    }

    // Every field admin_list_online_orders returns (except total_count, which is pagination
    // metadata, not an order field) - per "include all available fields in the export".
    const headers = [
      'Order ID', 'Date', 'Time', 'Status', 'Customer', 'Location ID', 'Warehouse',
      'Money To Collect', 'Amount Paid', 'Discount', 'Balance', 'For Delivery',
      'Shipping Address', 'Est. Delivery Date', 'Last Updated', 'Synced At', 'Glass Thickness',
      'Created By', 'Confirmed By', 'Print Note', 'Delivery Fee'
    ];
    const csvLines = [headers.map(escapeCsvValue).join(',')];
    allRows.forEach((o) => {
      csvLines.push([
        o.order_id,
        o.order_date,
        o.order_time,
        o.status,
        o.customer_name,
        o.location_id,
        o.warehouse_name,
        o.money_to_collect,
        o.amount_paid,
        o.discount,
        o.balance,
        o.for_delivery ? 'Yes' : 'No',
        o.shipping_address,
        o.estimated_delivery_date,
        o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : '',
        o.synced_at_utc ? new Date(o.synced_at_utc).toLocaleString() : '',
        o.glass_thickness,
        o.created_by,
        o.confirmed_by,
        o.note_print,
        o.delivery_fee
      ].map(escapeCsvValue).join(','));
    });

    const blob = new Blob(['﻿' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    const link = document.createElement('a');
    link.href = url;
    link.download = `online-orders-${stamp}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

// Highlights whichever status-summary pill matches the current status filter text (case-
// insensitive), so clicking a pill (or typing a status directly into the filter box) gives a
// clear "this is the active filter" indication.
function updateStatusPillActiveState() {
  const currentStatus = document.getElementById('statusFilterInput').value.trim().toLowerCase();
  document.querySelectorAll('#statusSummaryBar .status-summary-pill').forEach((pill) => {
    pill.classList.toggle('active', currentStatus !== '' && pill.dataset.status.toLowerCase() === currentStatus);
  });
}

// Tab buttons for the grouped (Online Order Staff) view - switching tabs re-renders from the
// last-fetched rows (lastGroupedRows) rather than re-querying the server, so it's instant.
function wireGroupedTabs() {
  document.getElementById('groupedTabs').addEventListener('click', (event) => {
    const tabBtn = event.target.closest('.grouped-tab-btn');
    if (!tabBtn) return;

    activeGroupStatus = tabBtn.dataset.status;
    document.querySelectorAll('#groupedTabs .grouped-tab-btn').forEach((btn) => {
      btn.classList.toggle('active', btn === tabBtn);
    });
    renderActiveGroupTab();
  });
}

function wireOrderFilters() {
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');

  const reload = () => {
    updateStatusPillActiveState();
    currentPage = 1;
    clearTimeout(orderSearchDebounceHandle);
    orderSearchDebounceHandle = setTimeout(
      () => loadOrders(searchInput.value.trim(), statusInput.value.trim()),
      300
    );
  };

  searchInput.addEventListener('input', reload);
  statusInput.addEventListener('input', reload);

  // Per "make that button clickable so the user can filter out based on status" - clicking a
  // status-summary pill sets the status filter box to that status (or clears it if the same
  // pill is clicked again while already active) and reloads immediately, no debounce needed
  // since it's a discrete click rather than free-text typing.
  document.getElementById('statusSummaryBar').addEventListener('click', (event) => {
    const pill = event.target.closest('.status-summary-pill');
    if (!pill) return;

    const clickedStatus = pill.dataset.status;
    const alreadyActive = statusInput.value.trim().toLowerCase() === clickedStatus.toLowerCase();
    statusInput.value = alreadyActive ? '' : clickedStatus;
    updateStatusPillActiveState();
    currentPage = 1;

    clearTimeout(orderSearchDebounceHandle);
    loadOrders(searchInput.value.trim(), statusInput.value.trim());
  });

  document.getElementById('exportExcelBtn').addEventListener('click', exportOrdersToExcel);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Online Orders');

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Online Orders.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('exportExcelBtn').classList.toggle('hidden', !session.isSuperUser);
  // Delegated on #setupContent (not #orderTableBody directly) so the same "To Ship" handling
  // works whether the click lands in the flat table or one of the three grouped-view tables
  // (see the isOnlineOrderStaff branch below) - handleOrderTableClick already finds its target
  // via .closest(), so it doesn't care which table fired the event.
  document.getElementById('setupContent').addEventListener('click', handleOrderTableClick);
  document.getElementById('toShipPhotoInput').addEventListener('change', handleToShipPhotoSelected);
  document.getElementById('toShipPhotoInput').addEventListener('cancel', handleToShipPhotoCancelled);
  wireOrderFilters();
  wireShipSerialModalButtons();
  // Swipe-down-to-refresh (js/pullToRefresh.js) - re-runs whatever's currently on screen, same
  // as the search/status filters' own reload, so a refresh mid-search doesn't clear it.
  if (window.initPullToRefresh) initPullToRefresh(refreshCurrentOrders);
  currentSessionIsProductionWarehouse = await resolveIsProductionWarehouse(session);

  // Supports deep-linking from the Dashboard's status cards, e.g. online-orders.html?status=Shipped,
  // from the Dashboard's finance cards, e.g. ?period=month|today|prevmonth, ?scope=walkin,
  // ?filter=outstanding, and from a Sales by Staff figure, e.g. ?confirmedBy=Juan+Dela+Cruz&period=month
  // (see dashboard.html's finance-card hrefs / staffStatLinkHtml in js/dashboard.js / the
  // module-level comment on currentPeriod above).
  const urlParams = new URLSearchParams(window.location.search);
  const periodParam = urlParams.get('period') || '';
  const scopeParam = urlParams.get('scope') || '';
  const filterParam = urlParams.get('filter') || '';
  const confirmedByParam = urlParams.get('confirmedBy') || '';

  // Per "if the user is a online order staff They can only see Confirmed / Printed / To Ship" -
  // hard-locked server-side via p_status_in (see loadOrders/ONLINE_ORDER_STAFF_STATUS_SCOPE
  // above), not just a default they can clear/change (ignores any ?status= deep link too). The
  // text here is just a display label for the disabled box - loadOrders always sends the real
  // 3-status list for this role regardless of what this string says. The status filter box and
  // status-summary pills are disabled rather than hidden so it's still visible/obvious why
  // nothing else shows up.
  const statusParam = session.isOnlineOrderStaff ? ONLINE_ORDER_STAFF_STATUS_SCOPE.join(', ') : (urlParams.get('status') || '');

  if (statusParam) {
    document.getElementById('statusFilterInput').value = statusParam;
  }
  if (session.isOnlineOrderStaff) {
    hidePriceColumns = true;
    document.getElementById('deliveryFeeHeader').classList.add('hidden');
    const statusInput = document.getElementById('statusFilterInput');
    statusInput.disabled = true;
    statusInput.title = 'Your account only shows Confirmed, Printed, and To Ship orders.';
    document.getElementById('statusSummaryBar').classList.add('hidden');

    // Per "i want to show the online order per category: Confirmed / Printed / To-Ship" - swap
    // the flat table for the three-section grouped view (see renderGroupedOrders/loadOrders
    // above), and fetch at the server's max page size (200, see admin_list_online_orders) in one
    // shot instead of paging, since this role's whole queue is only ever these 3 statuses.
    document.getElementById('flatOrdersView').classList.add('hidden');
    document.getElementById('groupedOrdersView').classList.remove('hidden');
    currentPageSize = 200;
    wireGroupedTabs();
  }
  updateStatusPillActiveState();

  currentPeriod = periodParam === 'month' || periodParam === 'today' || periodParam === 'prevmonth' ? periodParam : null;
  currentScope = scopeParam === 'walkin' ? 'walkin' : null;
  outstandingOnly = filterParam === 'outstanding';
  currentConfirmedBy = confirmedByParam.trim() || null;

  const noteParts = [];
  if (currentConfirmedBy) {
    noteParts.push(`orders confirmed by ${currentConfirmedBy}`);
  } else {
    if (currentScope === 'walkin') noteParts.push('walk-in');
    noteParts.push(currentScope === 'walkin' ? 'sales' : 'online orders');
  }
  if (currentPeriod === 'month') {
    noteParts.push('for ' + new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
  } else if (currentPeriod === 'today') {
    noteParts.push('for today (' + new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) + ')');
  } else if (currentPeriod === 'prevmonth') {
    const prevMonthDate = new Date();
    prevMonthDate.setDate(1);
    prevMonthDate.setMonth(prevMonthDate.getMonth() - 1);
    noteParts.push('for ' + prevMonthDate.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
  }
  if (outstandingOnly) noteParts.push('with an outstanding balance');

  const activeFilterNote = document.getElementById('activeFilterNote');
  if (currentPeriod || currentScope || outstandingOnly || currentConfirmedBy) {
    activeFilterNote.innerHTML = `Showing ${noteParts.join(' ')}. <a href="online-orders.html">Clear filters</a>`;
    activeFilterNote.classList.remove('hidden');
  }

  // The status summary bar/pills only ever count non-walk-in orders (see
  // admin_get_online_order_status_summary) - hide it entirely rather than show misleading
  // counts when viewing a walk-in-scoped deep link. Stays hidden for Online Order Staff
  // regardless (already hidden above) - a summary across every status isn't useful when this
  // account can only ever see Printed orders anyway.
  const showStatusSummary = currentScope !== 'walkin' && !session.isOnlineOrderStaff;
  document.getElementById('statusSummaryBar').classList.toggle('hidden', !showStatusSummary);

  const loaders = [loadOrders('', statusParam)];
  if (showStatusSummary) loaders.push(loadStatusSummary());
  await Promise.all(loaders);
})();
