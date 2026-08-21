// Stock On Hand report - reads public."ItemWarehouseStockCache" (see
// supabase_item_warehouse_stock.sql) via staff_list_item_warehouse_stock. That cache is only ever
// populated by staff clicking "Refresh from Pancake" (staff_refresh_item_warehouse_stock) - real
// per-warehouse stock lives in Pancake, not this app's own database, and walking the whole catalog
// against Pancake's per-product endpoint is too slow to run live on every page load.
let currentSession = null;
let allRows = [];

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

function renderTable() {
  const tbody = document.getElementById('stockTableBody');
  const search = document.getElementById('searchInput').value.trim().toLowerCase();
  const rows = search
    ? allRows.filter((r) => [r.item_code, r.item_name].some((v) => (v || '').toString().toLowerCase().includes(search)))
    : allRows;

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No stock records found. Try "Refresh from Pancake" if this is the first time loading this page.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((r) => `
      <tr>
        <td>${escapeHtml(r.item_code)}</td>
        <td>${escapeHtml(r.item_name)}</td>
        <td>${escapeHtml(r.category_name)}</td>
        <td>${escapeHtml(r.warehouse_name)}</td>
        <td style="text-align:right;">${formatQty(r.remain_quantity)}</td>
      </tr>
    `)
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

async function loadCategoryOptions() {
  const { data, error } = await supabaseClient.rpc('staff_list_categories', {
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
    p_category_code: document.getElementById('categoryFilter').value || null
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
// staff_start_item_warehouse_stock_refresh() truncates the cache and hands back every product id,
// then this walks that list calling staff_refresh_item_warehouse_stock_product() a few at a time -
// each call is bounded by a single Pancake HTTP request, so no individual call can ever approach
// the timeout no matter how large the catalog grows.
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
  document.getElementById('refreshViewBtn').addEventListener('click', loadStock);
  document.getElementById('refreshFromPancakeBtn').addEventListener('click', refreshFromPancake);

  await Promise.all([loadWarehouseOptions(), loadCategoryOptions()]);
  await loadStock();
})();
