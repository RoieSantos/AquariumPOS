// Advance Order Lines drill-down page logic (super users only, read-only view).
// Reads ?transaction=<TransactionNo> from the URL - same trust model as advanceOrders.js.
// No password re-entry prompt - super user status alone is enough (reuses session.password
// captured at login, see auth.js).
let currentSession = null;
let transactionNo = null;
let currentPage = 1;
let currentPageSize = 50;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function renderLineRows(lines) {
  const tbody = document.getElementById('lineTableBody');

  if (!lines || lines.length === 0) {
    tbody.innerHTML = '<tr><td colspan="10" class="muted">No line items found for this order.</td></tr>';
    return;
  }

  tbody.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.line_no || ''}</td>
        <td>${l.type || ''}</td>
        <td>${l.item_no || ''}</td>
        <td>${l.description || ''}</td>
        <td>${l.quantity ?? ''}</td>
        <td>${formatMoney(l.price)}</td>
        <td>${formatMoney(l.discount)}</td>
        <td>${formatMoney(l.gross_amount)}</td>
        <td>${formatMoney(l.net_amount)}</td>
        <td>${l.user_id || ''}</td>
      </tr>
    `)
    .join('');
}

async function loadOrderSummary() {
  const { data, error } = await supabaseClient.rpc('admin_list_advance_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_transaction_no: transactionNo
  });

  const note = document.getElementById('orderSummaryNote');
  if (error || !data || data.length === 0) {
    note.textContent = `Transaction ${transactionNo} - line items:`;
    return;
  }

  const o = data[0];
  note.textContent = `Transaction ${o.transaction_no} (Receipt ${o.receipt_no || 'n/a'}) - ${o.customer_name || 'unknown customer'}`;
}

async function loadLines() {
  const { data, error } = await supabaseClient.rpc('admin_list_advance_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_transaction_no: transactionNo,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    document.getElementById('lineTableBody').innerHTML = `<tr><td colspan="10" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderLineRows(data);

  renderPaginationBar(
    document.getElementById('linePaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadLines(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadLines(); }
    }
  );
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Advance Orders');

  const params = new URLSearchParams(window.location.search);
  transactionNo = params.get('transaction');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!transactionNo) {
    document.getElementById('orderSummaryNote').textContent = 'No transaction specified.';
    document.getElementById('lineTableBody').innerHTML = '<tr><td colspan="10" class="error-text">Missing ?transaction= parameter.</td></tr>';
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
  await loadOrderSummary();
  await loadLines();
})();
