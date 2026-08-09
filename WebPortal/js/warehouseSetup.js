// Warehouse Setup page logic (super users only, read-only view + manual sync).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js).
let currentSession = null;
let currentPage = 1;
let currentPageSize = 50;

function renderWarehouseRows(warehouses) {
  const tbody = document.getElementById('warehouseTableBody');

  if (!warehouses || warehouses.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No warehouses synced yet.</td></tr>';
    return;
  }

  tbody.innerHTML = warehouses
    .map((w) => `
      <tr data-id="${w.id}">
        <td>${w.id || ''}</td>
        <td>${w.name || ''}</td>
        <td><input type="checkbox" class="warehouse-flag-input" data-flag="production" data-id="${w.id}" ${w.is_production_warehouse ? 'checked' : ''} /></td>
        <td><input type="checkbox" class="warehouse-flag-input" data-flag="stock" data-id="${w.id}" ${w.is_stock_warehouse ? 'checked' : ''} /></td>
        <td><input type="checkbox" class="warehouse-flag-input" data-flag="active" data-id="${w.id}" ${w.is_active ? 'checked' : ''} /></td>
        <td>
          <input type="number" step="0.01" class="sales-target-input" data-id="${w.id}" value="${w.sales_target ?? ''}" style="width:110px;" />
          <button class="btn btn-secondary btn-sm" data-action="save-sales-target" data-id="${w.id}" type="button">Save</button>
          <span class="sales-target-saved muted hidden" data-id="${w.id}">Saved</span>
        </td>
        <td>${w.synced_at_utc ? new Date(w.synced_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('button[data-action="save-sales-target"]').forEach((btn) => {
    btn.addEventListener('click', () => saveSalesTarget(btn.dataset.id));
  });
  // Auto-saves on toggle, same as the Local POS's WarehouseSetupForm checkbox grid
  // (Dgv_CellEndEdit -> SaveWarehouseFlag) - no separate Save button for these two.
  tbody.querySelectorAll('.warehouse-flag-input').forEach((cb) => {
    cb.addEventListener('change', () => saveWarehouseFlags(cb.dataset.id));
  });
}

async function saveWarehouseFlags(warehouseId) {
  const row = document.querySelector(`tr[data-id="${warehouseId}"]`);
  const productionCb = row.querySelector('.warehouse-flag-input[data-flag="production"]');
  const stockCb = row.querySelector('.warehouse-flag-input[data-flag="stock"]');
  const activeCb = row.querySelector('.warehouse-flag-input[data-flag="active"]');

  const { error } = await supabaseClient.rpc('admin_update_warehouse_flags', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_id: warehouseId,
    p_is_production_warehouse: productionCb.checked,
    p_is_stock_warehouse: stockCb.checked,
    p_is_active: activeCb.checked
  });

  if (error) {
    window.alert(`Failed to save warehouse flags: ${error.message}`);
    // Reload from the server to discard the failed toggle rather than leaving the
    // checkbox showing a state that was never actually saved.
    await loadWarehouses();
  }
}

async function saveSalesTarget(warehouseId) {
  const input = document.querySelector(`.sales-target-input[data-id="${warehouseId}"]`);
  const savedLabel = document.querySelector(`.sales-target-saved[data-id="${warehouseId}"]`);
  const raw = input.value.trim();
  const value = raw === '' ? null : Number(raw);

  if (raw !== '' && Number.isNaN(value)) {
    window.alert('Sales Target must be a number.');
    return;
  }

  const { error } = await supabaseClient.rpc('admin_update_warehouse_sales_target', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_id: warehouseId,
    p_sales_target: value
  });

  if (error) {
    window.alert(`Failed to save Sales Target: ${error.message}`);
    return;
  }

  savedLabel.classList.remove('hidden');
  setTimeout(() => savedLabel.classList.add('hidden'), 1500);
}

async function loadWarehouses() {
  const tbody = document.getElementById('warehouseTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderWarehouseRows(data);

  renderPaginationBar(
    document.getElementById('warehousePaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadWarehouses(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadWarehouses(); }
    }
  );
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Warehouse Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Warehouse Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  await loadWarehouses();
})();
