// Purchase Orders list page (any active staff, same access level as Stock On Hand - see
// supabase_purchase_orders.sql's header comment for why this is staff-gated, not admin-gated).
let currentSession = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let searchDebounceHandle = null;

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleDateString();
}

// Supabase/PostgREST errors often have an empty .message with the actual detail sitting in
// .details/.hint instead (e.g. check-constraint failures) - same helper as transferOrders.js'
// describeSupabaseError, copied locally since this page doesn't load that script.
function describeSupabaseError(err, fallback) {
  console.error(fallback, err);
  const parts = [err?.message, err?.details, err?.hint].filter(Boolean);
  if (parts.length > 0) return parts.join(' - ');
  if (err?.code) return `${fallback} (code: ${err.code})`;
  return fallback;
}

// Pancake's own error text (surfaced in the Pancake Sync panel below) is external content, so it
// gets escaped before going into innerHTML - same care transferOrders.js's own Pancake Sync panel
// takes with its escapeHtml helper.
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
}

// Receiving progress badge - purely a client-side read of total_quantity vs
// total_received_quantity (see staff_list_purchase_orders), no separate status column to keep
// in sync.
function receivedBadgeHtml(po) {
  const total = Number(po.total_quantity || 0);
  const received = Number(po.total_received_quantity || 0);
  if (received <= 0) return '<span class="badge badge-neutral">Not Received</span>';
  if (received >= total) return '<span class="badge badge-success">Fully Received</span>';
  return `<span class="badge badge-warning">${received.toLocaleString()} / ${total.toLocaleString()}</span>`;
}

function poRowsHtml(rows) {
  return rows
    .map((po) => `
      <tr class="clickable-row" data-po-no="${encodeURIComponent(po.po_no)}">
        <td>${po.po_no}</td>
        <td>${po.vendor_name || po.vendor_code || ''}</td>
        <td>${formatDate(po.order_date)}</td>
        <td style="text-align:right;">${po.line_count ?? 0}</td>
        <td style="text-align:right;">${Number(po.total_quantity || 0).toLocaleString()}</td>
        <td>${receivedBadgeHtml(po)}</td>
        <td>${po.created_by || ''}</td>
        <td>
          <a href="purchase-order-print.html?po=${encodeURIComponent(po.po_no)}" class="btn btn-secondary btn-sm" onclick="event.stopPropagation();">Print</a>
          <button class="btn btn-secondary btn-sm" data-delete-po="${encodeURIComponent(po.po_no)}" data-received-qty="${Number(po.total_received_quantity || 0)}" type="button" onclick="event.stopPropagation();">Delete</button>
        </td>
      </tr>
    `)
    .join('');
}

async function loadPurchaseOrders() {
  const tbody = document.getElementById('poTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_purchase_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="8" class="muted">No Purchase Orders yet - create one from Stock On Hand.</td></tr>'
    : poRowsHtml(rows);

  tbody.querySelectorAll('tr[data-po-no]').forEach((row) => {
    row.addEventListener('click', () => openReceiveModal(decodeURIComponent(row.dataset.poNo)));
  });

  renderPaginationBar(
    document.getElementById('poPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: rows[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadPurchaseOrders(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadPurchaseOrders(); }
    }
  );
}

async function deletePurchaseOrder(poNo, receivedQty) {
  // Receiving already pushed a real stock-in to Pancake (see staff_receive_purchase_order_lines) -
  // deleting the portal record does NOT reverse that, so make sure staff know before they delete
  // what looks like just a local document.
  const message = receivedQty > 0
    ? `Purchase Order ${poNo} has already received ${receivedQty} unit(s), which were pushed to Pancake as stock. Deleting this record will NOT reverse that Pancake stock-in - only the portal's own PO record is removed. Delete anyway?`
    : `Delete Purchase Order ${poNo}? This cannot be undone.`;
  if (!window.confirm(message)) return;

  const { error } = await supabaseClient.rpc('staff_delete_purchase_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_po_no: poNo
  });

  if (error) {
    window.alert(error.message);
    return;
  }

  await loadPurchaseOrders();
}

// Receive Purchase Order modal - view a PO's lines and receive stock against them (running
// cumulative QtyReceived, capped at each line's ordered Quantity - see
// staff_receive_purchase_order_lines in supabase_purchase_order_receiving.sql), then post the
// whole order into Posted Purchase Orders once done receiving.
let currentReceivePoNo = null;

function receiveLineRemaining(l) {
  return Math.max(0, (Number(l.quantity) || 0) - (Number(l.qty_received) || 0));
}

// Adding/removing lines on an existing PO is super-user only, per direct instruction - see
// staff_add_purchase_order_line/staff_remove_purchase_order_line in
// supabase_purchase_order_edit_lines.sql, which enforce the same gate server-side (this client
// check is just what shows the controls, not the actual security boundary).
function receiveLinesColspan() {
  return currentSession?.isSuperUser ? 7 : 6;
}

function renderReceiveLines(lines) {
  const body = document.getElementById('receiveLinesBody');
  document.getElementById('receiveLinesActionsHeader').classList.toggle('hidden', !currentSession?.isSuperUser);

  if (!lines || lines.length === 0) {
    body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="muted">No line items.</td></tr>`;
    return;
  }

  body.innerHTML = lines
    .map((l) => {
      const remaining = receiveLineRemaining(l);
      const receiveInput = remaining > 0
        ? `<input type="number" class="receive-qty-input" min="0" max="${remaining}" step="0.01" value="${remaining}" style="width:90px; text-align:right;" />`
        : '<span class="muted">&mdash;</span>';
      // A line with anything already received can't be removed (see
      // staff_remove_purchase_order_line's own server-side check) - shown disabled rather than
      // simply hidden, so it's clear removal was considered and blocked, not just unavailable.
      const qtyReceived = Number(l.qty_received || 0);
      const removeCell = !currentSession?.isSuperUser
        ? ''
        : qtyReceived > 0
          ? `<td><button type="button" class="btn btn-danger btn-sm" disabled title="Already received against - cannot be removed">Remove</button></td>`
          : `<td><button type="button" class="btn btn-danger btn-sm" data-remove-entry-no="${l.entry_no}" data-remove-item-code="${escapeHtml(l.item_code)}">Remove</button></td>`;
      return `
        <tr data-entry-no="${l.entry_no}">
          <td>${l.item_code || ''}</td>
          <td>${l.item_name || ''}</td>
          <td>${l.warehouse_name || ''}</td>
          <td style="text-align:right;">${Number(l.quantity || 0).toLocaleString()}</td>
          <td style="text-align:right;">${Number(l.qty_received || 0).toLocaleString()}</td>
          <td style="text-align:right;">${receiveInput}</td>
          ${removeCell}
        </tr>
      `;
    })
    .join('');
}

let currentReceiveVendorCode = null;

async function openReceiveModal(poNo) {
  currentReceivePoNo = poNo;
  currentReceiveVendorCode = null;
  document.getElementById('receiveModalTitle').textContent = `Purchase Order ${poNo}`;
  document.getElementById('receiveModalError').classList.add('hidden');
  document.getElementById('receivePrintLink').href = `purchase-order-print.html?po=${encodeURIComponent(poNo)}`;
  const body = document.getElementById('receiveLinesBody');
  body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="muted">Loading...</td></tr>`;
  document.getElementById('receiveModal').classList.remove('hidden');
  document.getElementById('poEditSection').classList.toggle('hidden', !currentSession?.isSuperUser);
  resetPoAddItemFields();

  const [{ data: headerRows, error: headerError }, { data: lineRows, error: lineError }] = await Promise.all([
    supabaseClient.rpc('staff_get_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    }),
    supabaseClient.rpc('staff_list_purchase_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    })
  ]);

  if (headerError || !headerRows || headerRows.length === 0) {
    body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="error-text">${headerError?.message || 'Purchase Order not found.'}</td></tr>`;
    return;
  }

  const header = headerRows[0];
  currentReceiveVendorCode = header.vendor_code || null;
  document.getElementById('receiveVendor').textContent = header.vendor_name || header.vendor_code || '';
  document.getElementById('receiveOrderDate').textContent = formatDate(header.order_date);
  document.getElementById('receiveNotes').textContent = header.notes || '-';

  if (lineError) {
    body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="error-text">${lineError.message}</td></tr>`;
    return;
  }

  renderReceiveLines(lineRows || []);
  await loadPancakeSyncStatus(poNo);
}

// Pancake Sync panel - one row per Receive action's Pancake purchase attempt (grouped by
// Warehouse - see staff_receive_purchase_order_lines in supabase_purchase_order_pancake_sync.sql).
// Hidden entirely if this PO has never been received against.
function pancakeSyncBadgeClass(status) {
  switch (status) {
    case 'Synced': return 'badge-success';
    case 'Failed': return 'badge-danger';
    case 'Rejected': return 'badge-danger';
    default: return 'badge-neutral';
  }
}

async function loadPancakeSyncStatus(poNo) {
  const section = document.getElementById('pancakeSyncSection');
  const body = document.getElementById('pancakeSyncBody');

  const { data, error } = await supabaseClient.rpc('staff_list_purchase_order_pancake_purchases', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_po_no: poNo
  });

  if (error || !data || data.length === 0) {
    section.classList.add('hidden');
    return;
  }

  section.classList.remove('hidden');
  body.innerHTML = data
    .map((row) => `
      <tr>
        <td>${row.received_at_utc ? new Date(row.received_at_utc).toLocaleString() : ''}</td>
        <td>${row.warehouse_name || row.warehouse_id || ''}</td>
        <td>${escapeHtml(row.pancake_purchase_id) || '-'}</td>
        <td><span class="badge ${pancakeSyncBadgeClass(row.sync_status)}">${escapeHtml(row.sync_status)}</span></td>
        <td class="muted" title="${escapeHtml(row.sync_error)}">${escapeHtml(row.sync_error)}</td>
      </tr>
    `)
    .join('');
}

async function receivePurchaseOrderQuantities() {
  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const rows = Array.from(document.getElementById('receiveLinesBody').querySelectorAll('tr[data-entry-no]'));
  const lines = rows
    .map((row) => {
      const input = row.querySelector('.receive-qty-input');
      const quantity = input ? parseFloat(input.value) || 0 : 0;
      return { entry_no: Number(row.dataset.entryNo), quantity };
    })
    .filter((l) => l.quantity > 0);

  if (lines.length === 0) {
    errorEl.textContent = 'Enter a Receive Now quantity for at least one line first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('receiveQtyBtn');
  btn.disabled = true;
  try {
    // Each call syncs to Pancake per warehouse before updating anything locally - a row here can
    // come back 'Failed'/'Rejected' without the overall RPC call itself erroring, so a successful
    // call must still be checked for per-warehouse failures (see
    // staff_receive_purchase_order_lines's header comment for why those aren't auto-retried).
    const { data, error } = await supabaseClient.rpc('staff_receive_purchase_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: currentReceivePoNo,
      p_lines: lines
    });
    if (error) throw error;

    const failed = (data || []).filter((r) => r.sync_status !== 'Synced');
    if (failed.length > 0) {
      const details = failed
        .map((r) => `${r.warehouse_name || r.warehouse_id} - ${r.sync_error || r.sync_status}`)
        .join('; ');
      errorEl.textContent = `Some warehouse(s) failed to sync to Pancake and were NOT received: ${details}`;
      errorEl.classList.remove('hidden');
    }

    await openReceiveModal(currentReceivePoNo);
    await loadPurchaseOrders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to receive Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

async function postPurchaseOrder() {
  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const rows = Array.from(document.getElementById('receiveLinesBody').querySelectorAll('tr[data-entry-no]'));
  const anyUnreceived = rows.some((row) => {
    const input = row.querySelector('.receive-qty-input');
    return !!input; // an input only renders while a line still has a remaining balance
  });

  const confirmMessage = anyUnreceived
    ? `Purchase Order ${currentReceivePoNo} still has unreceived quantity. Post it to Posted Purchase Orders anyway?`
    : `Post Purchase Order ${currentReceivePoNo} to Posted Purchase Orders? This cannot be undone.`;
  if (!window.confirm(confirmMessage)) return;

  const btn = document.getElementById('postPoBtn');
  btn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('staff_post_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: currentReceivePoNo
    });
    if (error) throw error;

    document.getElementById('receiveModal').classList.add('hidden');
    await loadPurchaseOrders();
    window.alert(`Purchase Order ${currentReceivePoNo} has been posted.`);
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to post Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

// Add/remove lines on an existing Purchase Order - super users only (currentSession.isSuperUser
// gates the UI; staff_add_purchase_order_line/staff_remove_purchase_order_line re-check server-
// side, see supabase_purchase_order_edit_lines.sql). Item search reuses the same vendor-scoped
// staff_search_items pattern as the New Purchase Order modal, scoped to the PO's own vendor
// (currentReceiveVendorCode, set in openReceiveModal) rather than a picker of its own.
let poAddItemSelectedCode = '';
let poAddItemSelectedName = '';

function resetPoAddItemFields() {
  poAddItemSelectedCode = '';
  poAddItemSelectedName = '';
  const input = document.getElementById('poAddItemInput');
  if (input) input.value = '';
  const dropdown = document.getElementById('poAddItemDropdown');
  if (dropdown) { dropdown.classList.add('hidden'); dropdown.innerHTML = ''; }
  const warehouseSelect = document.getElementById('poAddItemWarehouse');
  if (warehouseSelect) warehouseSelect.innerHTML = newPoWarehouseOptionsHtml;
  const qtyInput = document.getElementById('poAddItemQty');
  if (qtyInput) qtyInput.value = '1';
}

async function searchItemsForAddToPo(searchText) {
  const dropdown = document.getElementById('poAddItemDropdown');

  if (!currentReceiveVendorCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">This Purchase Order has no vendor set.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: searchText || null,
    p_limit: 20,
    p_vendor_code: currentReceiveVendorCode
  });

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${describeSupabaseError(error, 'Search failed.')}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const items = data || [];
  if (items.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No items found for this vendor.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = items
    .map((it) => `
      <div class="item-suggest-option" data-code="${encodeURIComponent(it.code)}" data-name="${encodeURIComponent(it.name || '')}">
        <span class="item-suggest-code">${escapeHtml(it.code)}</span><span class="item-suggest-name">${escapeHtml(it.name || '')}</span>
      </div>
    `)
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      poAddItemSelectedCode = decodeURIComponent(opt.dataset.code);
      poAddItemSelectedName = decodeURIComponent(opt.dataset.name);
      document.getElementById('poAddItemInput').value = poAddItemSelectedCode;
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
}

async function addItemToExistingPurchaseOrder() {
  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const quantity = parseFloat(document.getElementById('poAddItemQty').value) || 0;
  if (!poAddItemSelectedCode || quantity <= 0) {
    errorEl.textContent = 'Pick an item (from the suggestions) and a Quantity greater than 0 first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const warehouseSelect = document.getElementById('poAddItemWarehouse');
  const warehouseOption = warehouseSelect.selectedOptions[0];

  const btn = document.getElementById('poAddItemBtn');
  btn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('staff_add_purchase_order_line', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: currentReceivePoNo,
      p_item_code: poAddItemSelectedCode,
      p_item_name: poAddItemSelectedName,
      p_warehouse_id: warehouseSelect.value || null,
      p_warehouse_name: warehouseSelect.value ? warehouseOption.dataset.name : null,
      p_quantity: quantity
    });
    if (error) throw error;

    await openReceiveModal(currentReceivePoNo);
    await loadPurchaseOrders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to add item to Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

async function removePurchaseOrderLine(entryNo, itemCode) {
  if (!window.confirm(`Remove ${itemCode} from this Purchase Order?`)) return;

  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const { error } = await supabaseClient.rpc('staff_remove_purchase_order_line', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: entryNo
  });

  if (error) {
    errorEl.textContent = describeSupabaseError(error, 'Failed to remove item.');
    errorEl.classList.remove('hidden');
    return;
  }

  await openReceiveModal(currentReceivePoNo);
  await loadPurchaseOrders();
}

// New Purchase Order modal - manual entry, independent of Stock On Hand's cache (so an item
// missing a warehouse row there - see supabase_stock_on_hand_missing_warehouse_diagnostic.sql -
// can still be ordered directly). Calls the same staff_create_purchase_order RPC Stock On Hand's
// own "Create Purchase Order" button uses (supabase_purchase_orders.sql) - no new backend needed.
let newPoWarehouseOptionsHtml = '<option value="">No warehouse</option>';

async function loadNewPoVendorOptions() {
  const select = document.getElementById('newPoVendor');
  const { data, error } = await supabaseClient.rpc('staff_search_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;

  select.innerHTML = '<option value="">Select a vendor...</option>' +
    data.map((v) => `<option value="${escapeHtml(v.vendor_code)}">${escapeHtml(v.name)}</option>`).join('');
}

async function loadNewPoWarehouseOptionsHtml() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;

  newPoWarehouseOptionsHtml = '<option value="">No warehouse</option>' +
    data.map((w) => `<option value="${escapeHtml(w.id)}" data-name="${escapeHtml(w.name)}">${escapeHtml(w.name)}</option>`).join('');
}

function applyNewPoItemSelection(row, code, name) {
  row.querySelector('.new-po-line-item').value = code;
  row.dataset.itemCode = code;
  row.dataset.itemName = name || '';
}

async function searchItemsForNewPoRow(row, searchText) {
  const dropdown = row.querySelector('.item-suggest-dropdown');

  // Mirrors Transfer Orders' own "Select a From Warehouse first" gate (transferOrders.js) - a
  // Purchase Order belongs to one vendor, so items are scoped to that vendor's own catalog
  // (Items."VendorCode") rather than showing the whole item list before a vendor is even picked.
  const vendorCode = document.getElementById('newPoVendor').value;
  if (!vendorCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">Select a Vendor first.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: searchText || null,
    p_limit: 20,
    p_vendor_code: vendorCode
  });

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${describeSupabaseError(error, 'Search failed.')}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const items = data || [];
  if (items.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No items found for this vendor.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = items
    .map((it) => `
      <div class="item-suggest-option" data-code="${encodeURIComponent(it.code)}" data-name="${encodeURIComponent(it.name || '')}">
        <span class="item-suggest-code">${escapeHtml(it.code)}</span><span class="item-suggest-name">${escapeHtml(it.name || '')}</span>
      </div>
    `)
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      applyNewPoItemSelection(row, decodeURIComponent(opt.dataset.code), decodeURIComponent(opt.dataset.name));
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
}

function addNewPoLineRow() {
  const tbody = document.getElementById('newPoLinesBody');
  const row = document.createElement('tr');
  row.innerHTML = `
    <td class="item-search-cell">
      <input type="text" class="new-po-line-item" placeholder="Search item code or name..." autocomplete="off" />
      <div class="item-suggest-dropdown hidden"></div>
    </td>
    <td><select class="new-po-line-warehouse">${newPoWarehouseOptionsHtml}</select></td>
    <td><input type="number" class="new-po-line-qty" min="0" step="0.01" value="1" style="width:90px; text-align:right;" /></td>
    <td><button type="button" class="btn btn-danger btn-sm">Remove</button></td>
  `;
  row.querySelector('button.btn-danger').addEventListener('click', () => row.remove());

  const itemInput = row.querySelector('.new-po-line-item');
  let debounceHandle = null;
  itemInput.addEventListener('input', (e) => {
    row.dataset.itemCode = '';
    row.dataset.itemName = '';
    clearTimeout(debounceHandle);
    const value = e.target.value;
    debounceHandle = setTimeout(() => searchItemsForNewPoRow(row, value), 250);
  });
  itemInput.addEventListener('focus', () => searchItemsForNewPoRow(row, itemInput.value));
  itemInput.addEventListener('blur', () => {
    setTimeout(() => row.querySelector('.item-suggest-dropdown').classList.add('hidden'), 150);
  });

  tbody.appendChild(row);
}

function resetNewPoModal() {
  document.getElementById('newPoVendor').value = '';
  document.getElementById('newPoNotes').value = '';
  document.getElementById('newPoModalError').classList.add('hidden');
  document.getElementById('newPoLinesBody').innerHTML = '';
  addNewPoLineRow();
  addNewPoLineRow();
}

async function openNewPoModal() {
  resetNewPoModal();
  document.getElementById('newPoModal').classList.remove('hidden');
}

async function createNewPurchaseOrder() {
  const errorEl = document.getElementById('newPoModalError');
  errorEl.classList.add('hidden');

  const vendorCode = document.getElementById('newPoVendor').value;
  if (!vendorCode) {
    errorEl.textContent = 'Select a Vendor first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const rows = Array.from(document.getElementById('newPoLinesBody').querySelectorAll('tr'));
  const lines = rows
    .map((row) => {
      const warehouseSelect = row.querySelector('.new-po-line-warehouse');
      const warehouseOption = warehouseSelect.selectedOptions[0];
      const quantity = parseFloat(row.querySelector('.new-po-line-qty')?.value) || 0;
      return {
        item_code: row.dataset.itemCode || '',
        item_name: row.dataset.itemName || '',
        warehouse_id: warehouseSelect.value || null,
        warehouse_name: warehouseSelect.value ? warehouseOption.dataset.name : null,
        quantity
      };
    })
    .filter((l) => l.item_code && l.quantity > 0);

  if (lines.length === 0) {
    errorEl.textContent = 'Pick an item (from the suggestions) and a Quantity greater than 0 for at least one line.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('createNewPoBtn');
  btn.disabled = true;
  try {
    const { data, error } = await supabaseClient.rpc('staff_create_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendor_code: vendorCode,
      p_notes: document.getElementById('newPoNotes').value.trim() || null,
      p_lines: lines
    });
    if (error) throw error;

    document.getElementById('newPoModal').classList.add('hidden');
    window.alert(`Purchase Order ${data} created.`);
    window.location.href = `purchase-order-print.html?po=${encodeURIComponent(data)}`;
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to create Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Purchase Orders');

  document.getElementById('poSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadPurchaseOrders();
    }, 300);
  });

  document.getElementById('poTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-delete-po]');
    if (!btn) return;
    deletePurchaseOrder(decodeURIComponent(btn.dataset.deletePo), Number(btn.dataset.receivedQty || 0));
  });

  document.getElementById('closeReceiveModalBtn').addEventListener('click', () =>
    document.getElementById('receiveModal').classList.add('hidden')
  );
  document.getElementById('receiveQtyBtn').addEventListener('click', receivePurchaseOrderQuantities);
  document.getElementById('postPoBtn').addEventListener('click', postPurchaseOrder);

  document.getElementById('receiveLinesBody').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-remove-entry-no]');
    if (!btn) return;
    removePurchaseOrderLine(Number(btn.dataset.removeEntryNo), btn.dataset.removeItemCode);
  });

  let poAddItemDebounceHandle = null;
  const poAddItemInput = document.getElementById('poAddItemInput');
  poAddItemInput.addEventListener('input', (e) => {
    poAddItemSelectedCode = '';
    poAddItemSelectedName = '';
    clearTimeout(poAddItemDebounceHandle);
    const value = e.target.value;
    poAddItemDebounceHandle = setTimeout(() => searchItemsForAddToPo(value), 250);
  });
  poAddItemInput.addEventListener('focus', () => searchItemsForAddToPo(poAddItemInput.value));
  poAddItemInput.addEventListener('blur', () => {
    setTimeout(() => document.getElementById('poAddItemDropdown').classList.add('hidden'), 150);
  });
  document.getElementById('poAddItemBtn').addEventListener('click', addItemToExistingPurchaseOrder);

  document.getElementById('newPoBtn').addEventListener('click', openNewPoModal);
  document.getElementById('closeNewPoModalBtn').addEventListener('click', () =>
    document.getElementById('newPoModal').classList.add('hidden')
  );
  document.getElementById('addNewPoLineBtn').addEventListener('click', addNewPoLineRow);
  document.getElementById('createNewPoBtn').addEventListener('click', createNewPurchaseOrder);

  await Promise.all([loadNewPoVendorOptions(), loadNewPoWarehouseOptionsHtml()]);
  await loadPurchaseOrders();
})();
