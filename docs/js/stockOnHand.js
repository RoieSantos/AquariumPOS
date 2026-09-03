// Stock On Hand report - reads public."ItemWarehouseStockCache" (see
// supabase_item_warehouse_stock.sql) via staff_list_item_warehouse_stock. That cache is only ever
// populated by staff clicking "Refresh from Pancake" (staff_refresh_item_warehouse_stock) - real
// per-warehouse stock lives in Pancake, not this app's own database, and walking the whole catalog
// against Pancake's per-product endpoint is too slow to run live on every page load.
let currentSession = null;
let allRows = [];
// Per "can we sort it manually per quantity on hand" - click any column header to sort by it,
// click again to flip direction. No default sort (natural DB order) until the staff member
// actually clicks a header - "manually" per the request, not an always-on sort.
let sortColumn = null;
let sortDirection = 'asc';
// Per "add another field Quantity 'This field is editable'... included on the printout" - a
// per-row order quantity staff type in on screen, keyed by "item_code|warehouse_id" (an item can
// appear on multiple rows, one per warehouse). Kept in this map (not read straight off the live
// <input> elements) so a value survives sorting/re-rendering, which rebuilds the table body's
// innerHTML from scratch. Only lives for this page session - not persisted beyond it except via
// the localStorage handoff to the print page (see printBtn's click handler below).
let enteredQuantities = new Map();

function stockRowKey(row) {
  return `${row.item_code}|${row.warehouse_id}`;
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatQty(value) {
  return value === null || value === undefined ? '-' : Number(value).toLocaleString();
}

function formatRefreshedAt(iso) {
  if (!iso) return 'Never refreshed yet.';
  const d = new Date(iso);
  return 'Last refreshed: ' + d.toLocaleString();
}

function sortRows(rows) {
  if (!sortColumn) return rows;
  const numeric = sortColumn === 'remain_quantity';
  const factor = sortDirection === 'asc' ? 1 : -1;
  return [...rows].sort((a, b) => {
    if (numeric) {
      // Nulls (no cached stock row for that item/warehouse yet) sort last regardless of direction
      // - an unknown quantity isn't meaningfully "less than zero".
      const av = a[sortColumn];
      const bv = b[sortColumn];
      if (av === null || av === undefined) return bv === null || bv === undefined ? 0 : 1;
      if (bv === null || bv === undefined) return -1;
      return (av - bv) * factor;
    }
    const av = (a[sortColumn] || '').toString().toLowerCase();
    const bv = (b[sortColumn] || '').toString().toLowerCase();
    return av.localeCompare(bv) * factor;
  });
}

function updateSortIndicators() {
  document.querySelectorAll('.sortable-th').forEach((th) => {
    const indicator = th.querySelector('.sort-indicator');
    indicator.textContent = th.dataset.sort === sortColumn ? (sortDirection === 'asc' ? ' ▲' : ' ▼') : '';
  });
}

function renderTable() {
  const tbody = document.getElementById('stockTableBody');
  const search = document.getElementById('searchInput').value.trim().toLowerCase();
  const filtered = search
    ? allRows.filter((r) => [r.item_code, r.item_name, r.variant_name].some((v) => (v || '').toString().toLowerCase().includes(search)))
    : allRows;
  const rows = sortRows(filtered);
  updateSortIndicators();

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No stock records found. Try "Refresh from Pancake" if this is the first time loading this page.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((r) => {
      const key = stockRowKey(r);
      const enteredValue = enteredQuantities.has(key) ? escapeHtml(enteredQuantities.get(key)) : '';
      return `
      <tr>
        <td>${escapeHtml(r.item_code)}</td>
        <td>${escapeHtml(r.item_name)}</td>
        <td>${r.variant_name ? escapeHtml(r.variant_name) : '<span class="muted">-</span>'}</td>
        <td>${escapeHtml(r.category_name)}</td>
        <td>${r.vendor_name ? escapeHtml(r.vendor_name) : '<span class="muted">-</span>'}</td>
        <td>${escapeHtml(r.warehouse_name)}</td>
        <td style="text-align:right;">${formatQty(r.remain_quantity)}</td>
        <td style="text-align:right;"><input type="number" class="stock-qty-input" data-key="${escapeHtml(key)}" value="${enteredValue}" min="0" inputmode="numeric" style="width:80px; text-align:right;" /></td>
      </tr>
    `;
    })
    .join('');
}

async function loadWarehouseOptions() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;

  const select = document.getElementById('warehouseFilter');
  data.forEach((w) => {
    const option = document.createElement('option');
    option.value = w.id;
    option.textContent = w.name;
    select.appendChild(option);
  });
}

// Per "when I open stock on hand i only need to show the ones included on stock on hand in the
// category setup" - only lists categories flagged Include in Stock Sync (Category Setup), not
// every category in the catalog like the picker this page used before.
async function loadCategoryOptions() {
  const { data, error } = await supabaseClient.rpc('staff_list_stock_sync_categories', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error || !data) return;

  const select = document.getElementById('categoryFilter');
  data.forEach((c) => {
    const option = document.createElement('option');
    option.value = c.code;
    option.textContent = c.description;
    select.appendChild(option);
  });
}

// Per "I want a field on the items 'Vendor No.'... whenever we run a report it will show who is
// the supplier" - reuses the existing staff_search_vendors (supabase_vendor_tables.sql, already
// used by the Delivery page), same staff-facing vendor lookup, no new RPC needed for this list.
async function loadVendorOptions() {
  const { data, error } = await supabaseClient.rpc('staff_search_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;

  const select = document.getElementById('vendorFilter');
  data.forEach((v) => {
    const option = document.createElement('option');
    option.value = v.vendor_code;
    option.textContent = v.name;
    select.appendChild(option);
  });
}

async function loadStock() {
  const loadingEl = document.getElementById('stockLoading');
  const errorEl = document.getElementById('stockError');
  const wrapEl = document.getElementById('stockTableWrap');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  wrapEl.classList.add('hidden');

  const { data, error } = await supabaseClient.rpc('staff_list_item_warehouse_stock', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_id: document.getElementById('warehouseFilter').value || null,
    p_search: null,
    p_category_code: document.getElementById('categoryFilter').value || null,
    p_vendor_code: document.getElementById('vendorFilter').value || null
  });

  loadingEl.classList.add('hidden');

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  allRows = data || [];
  document.getElementById('lastRefreshedLabel').textContent = formatRefreshedAt(allRows[0] && allRows[0].last_refreshed_at_utc);
  wrapEl.classList.remove('hidden');
  renderTable();
}

// Driven from here rather than one big Postgres RPC looping over the whole catalog - a first
// attempt at that hit Supabase's statement timeout on a real catalog. Instead
// staff_start_item_warehouse_stock_refresh() hands back the product ids for whichever categories
// are currently flagged "Include in Stock Sync" on Category Setup (see
// supabase_item_warehouse_stock_category_refresh.sql), then this walks that list calling
// staff_refresh_item_warehouse_stock_product() a few at a time - each call is bounded by a single
// Pancake HTTP request, so no individual call can ever approach the timeout no matter how large
// the catalog grows. The scope is set once on Category Setup, not picked here - refresh always
// syncs the same configured set regardless of this page's own Category filter (which is just for
// viewing what's already cached).
const REFRESH_CONCURRENCY = 3;

async function refreshFromPancake() {
  const btn = document.getElementById('refreshFromPancakeBtn');
  const statusEl = document.getElementById('refreshStatus');
  btn.disabled = true;
  statusEl.className = 'muted';
  statusEl.textContent = 'Starting refresh...';
  statusEl.classList.remove('hidden');

  const { data: productRows, error: startError } = await supabaseClient.rpc('staff_start_item_warehouse_stock_refresh', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (startError) {
    statusEl.className = 'error-text';
    statusEl.textContent = 'Refresh failed to start: ' + startError.message;
    btn.disabled = false;
    return;
  }

  const productIds = (productRows || []).map((r) => r.product_id);

  if (productIds.length === 0) {
    btn.disabled = false;
    statusEl.className = 'error-text';
    statusEl.textContent = 'No categories are marked "Include in Stock Sync" yet - set that up on Category Setup first.';
    return;
  }

  let processed = 0;
  let failed = 0;
  let rowsWritten = 0;

  for (let i = 0; i < productIds.length; i += REFRESH_CONCURRENCY) {
    const batch = productIds.slice(i, i + REFRESH_CONCURRENCY);
    const results = await Promise.all(
      batch.map((productId) => supabaseClient.rpc('staff_refresh_item_warehouse_stock_product', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_product_id: productId
      }))
    );

    results.forEach((result) => {
      const row = result.data && result.data[0];
      if (result.error || (row && row.fetch_error)) {
        failed++;
      } else {
        processed++;
        rowsWritten += (row && row.rows_written) || 0;
      }
    });

    const done = Math.min(i + REFRESH_CONCURRENCY, productIds.length);
    btn.textContent = `Refreshing... ${done}/${productIds.length} products`;
    statusEl.textContent = `Refreshing... ${done}/${productIds.length} products (${failed} failed so far)`;
  }

  btn.disabled = false;
  btn.textContent = 'Refresh from Pancake';
  statusEl.className = failed > 0 ? 'error-text' : 'rule-notice-positive';
  statusEl.textContent = `Refreshed ${processed} product(s), ${rowsWritten} stock row(s) written` +
    (failed > 0 ? `, ${failed} product(s) failed to fetch.` : '.');

  await loadStock();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Stock On Hand');

  document.getElementById('searchInput').addEventListener('input', renderTable);
  document.getElementById('warehouseFilter').addEventListener('change', loadStock);
  document.getElementById('categoryFilter').addEventListener('change', loadStock);
  document.getElementById('vendorFilter').addEventListener('change', loadStock);
  document.getElementById('refreshViewBtn').addEventListener('click', loadStock);
  document.getElementById('refreshFromPancakeBtn').addEventListener('click', refreshFromPancake);

  // Per "can I request a printout per vendor? so I can order stocks" - carries whatever's
  // currently filtered/on screen through to the print page (js/stockOnHandPrint.js), so picking a
  // Vendor first and then Print gives a printout scoped to just that vendor's items.
  document.getElementById('printBtn').addEventListener('click', () => {
    const params = new URLSearchParams();
    const warehouseSelect = document.getElementById('warehouseFilter');
    const categorySelect = document.getElementById('categoryFilter');
    const vendorSelect = document.getElementById('vendorFilter');
    const search = document.getElementById('searchInput').value.trim();

    if (warehouseSelect.value) {
      params.set('warehouse', warehouseSelect.value);
      params.set('warehouseName', warehouseSelect.selectedOptions[0]?.textContent || '');
    }
    if (categorySelect.value) {
      params.set('category', categorySelect.value);
      params.set('categoryName', categorySelect.selectedOptions[0]?.textContent || '');
    }
    if (vendorSelect.value) {
      params.set('vendor', vendorSelect.value);
      params.set('vendorName', vendorSelect.selectedOptions[0]?.textContent || '');
    }
    if (search) params.set('search', search);

    // Hand the entered Quantity values off to the print page via localStorage (persists across
    // navigations, unlike an in-memory JS variable) - always overwritten fresh here so a later
    // print never shows stale leftovers from an earlier session.
    localStorage.setItem('stockOnHandEnteredQuantities', JSON.stringify(Object.fromEntries(enteredQuantities)));

    // Same-tab navigation, NOT window.open(..., '_blank') - the portal login session lives in
    // sessionStorage (js/auth.js), which browsers don't reliably carry over into a new tab. A new
    // tab with no inherited session immediately bounces to the login page, which looked like (and
    // was reported as) "opening this logs me out" - it never actually touched the real session on
    // the original tab, but same-tab navigation avoids the whole class of bug outright.
    window.location.href = 'stock-on-hand-print.html?' + params.toString();
  });

  // Per "once I input the quantity on the stock on hand can you convert it to Purchase Order?
  // with the actual quantity that i requested" - a PO is inherently tied to one vendor
  // (supabase_purchase_orders.sql), so this requires the Vendor filter to already be narrowed to
  // exactly one vendor, same way Print doesn't strictly require it but this does.
  document.getElementById('createPoBtn').addEventListener('click', async () => {
    const vendorSelect = document.getElementById('vendorFilter');
    const vendorCode = vendorSelect.value;
    if (!vendorCode) {
      window.alert('Pick a single Vendor from the filter above first - a Purchase Order belongs to one vendor.');
      return;
    }

    // Only rows for the selected vendor with a positive entered Quantity - guards against stale
    // entries left over from before switching the Vendor filter to a different vendor.
    const lines = allRows
      .filter((r) => r.vendor_code === vendorCode)
      .map((r) => ({ row: r, qty: enteredQuantities.get(stockRowKey(r)) }))
      .filter(({ qty }) => qty && Number(qty) > 0)
      .map(({ row, qty }) => ({
        item_code: row.item_code,
        item_name: row.item_name,
        warehouse_id: row.warehouse_id,
        warehouse_name: row.warehouse_name,
        quantity: Number(qty)
      }));

    if (lines.length === 0) {
      window.alert('Type a Quantity for at least one item from this vendor first.');
      return;
    }

    const btn = document.getElementById('createPoBtn');
    btn.disabled = true;
    btn.textContent = 'Creating...';

    const { data, error } = await supabaseClient.rpc('staff_create_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendor_code: vendorCode,
      p_notes: null,
      p_lines: lines
    });

    btn.disabled = false;
    btn.textContent = 'Create Purchase Order';

    if (error) {
      window.alert('Failed to create Purchase Order: ' + error.message);
      return;
    }

    // Clear only the lines that just became a PO (this vendor's entered quantities) - other
    // vendors' in-progress entries, if any, are left untouched.
    lines.forEach((l) => enteredQuantities.delete(`${l.item_code}|${l.warehouse_id}`));
    renderTable();

    window.alert(`Purchase Order ${data} created.`);
    // Same-tab navigation - see the Print button's handler above for why (sessionStorage-based
    // login session doesn't reliably survive a new tab).
    window.location.href = `purchase-order-print.html?po=${encodeURIComponent(data)}`;
  });

  // Delegated on the tbody (not per-row, since renderTable rebuilds the row markup on every sort/
  // filter/search) - keeps enteredQuantities in sync as the staff member types, so a value
  // survives re-sorting or switching filters and back.
  document.getElementById('stockTableBody').addEventListener('input', (e) => {
    if (!e.target.classList.contains('stock-qty-input')) return;
    const key = e.target.dataset.key;
    if (e.target.value === '') {
      enteredQuantities.delete(key);
    } else {
      enteredQuantities.set(key, e.target.value);
    }
  });

  document.querySelectorAll('.sortable-th').forEach((th) => {
    th.addEventListener('click', () => {
      const column = th.dataset.sort;
      sortDirection = sortColumn === column && sortDirection === 'asc' ? 'desc' : 'asc';
      sortColumn = column;
      renderTable();
    });
  });

  await Promise.all([loadWarehouseOptions(), loadCategoryOptions(), loadVendorOptions()]);
  await loadStock();
})();
