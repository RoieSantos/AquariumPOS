// Advance Orders page logic (super users only, read-only view).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js).
let currentSession = null;
let orderSearchDebounceHandle = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function renderOrderRows(orders) {
  const tbody = document.getElementById('orderTableBody');

  if (!orders || orders.length === 0) {
    tbody.innerHTML = '<tr><td colspan="11" class="muted">No advance orders found.</td></tr>';
    return;
  }

  tbody.innerHTML = orders
    .map((o) => `
      <tr>
        <td>${o.transaction_no || ''}</td>
        <td>${o.receipt_no || ''}</td>
        <td>${o.user_id || ''}</td>
        <td>${o.customer_name || ''}</td>
        <td>${o.order_description || ''}</td>
        <td>${o.order_date || ''}</td>
        <td>${o.order_time || ''}</td>
        <td>${formatMoney(o.net_amount)}</td>
        <td>${formatMoney(o.downpayment)}</td>
        <td>${formatMoney(o.balance)}</td>
        <td><a href="advance-order-lines.html?transaction=${encodeURIComponent(o.transaction_no)}">View</a></td>
      </tr>
    `)
    .join('');
}

async function loadOrders() {
  const tbody = document.getElementById('orderTableBody');
  tbody.innerHTML = '<tr><td colspan="11" class="muted">Loading...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_advance_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return; // a newer search/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="11" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderOrderRows(data);

  renderPaginationBar(
    document.getElementById('orderPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadOrders(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadOrders(); }
    }
  );
}

function wireOrderSearch() {
  document.getElementById('orderSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(orderSearchDebounceHandle);
    orderSearchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadOrders();
    }, 300);
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Advance Orders');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Advance Orders.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  wireOrderSearch();
  await loadOrders();
})();
