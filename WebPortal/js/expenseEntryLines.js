// Expense Entry Lines drill-down page logic (super users only, read-only view).
// Reads ?receipt=<ReceiptNo> from the URL. No password re-entry prompt - super user status
// alone is enough, same trust model as Online Orders (reuses session.password, see auth.js).
let currentSession = null;
let receiptNo = null;
let currentPage = 1;
let currentPageSize = 50;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function renderLineRows(lines) {
  const tbody = document.getElementById('lineTableBody');

  if (!lines || lines.length === 0) {
    tbody.innerHTML = '<tr><td colspan="10" class="muted">No line items found for this expense.</td></tr>';
    return;
  }

  tbody.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.line_id || ''}</td>
        <td>${l.item_code || ''}</td>
        <td>${l.description || ''}</td>
        <td>${l.quantity ?? ''}</td>
        <td>${formatMoney(l.unit_cost)}</td>
        <td>${formatMoney(l.price)}</td>
        <td>${formatMoney(l.discount)}</td>
        <td>${formatMoney(l.gross_amount)}</td>
        <td>${formatMoney(l.net_amount)}</td>
        <td>${l.user_id || ''}</td>
      </tr>
    `)
    .join('');
}

async function loadEntrySummary() {
  const { data, error } = await supabaseClient.rpc('admin_list_expense_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_receipt_no: receiptNo
  });

  const note = document.getElementById('entrySummaryNote');
  if (error || !data || data.length === 0) {
    note.textContent = `Receipt ${receiptNo} - line items:`;
    return;
  }

  const e = data[0];
  note.textContent = `Receipt ${e.receipt_no} - ${e.expense_category || 'Uncategorized'} - ${e.description || 'no description'}`;
}

async function loadLines() {
  const { data, error } = await supabaseClient.rpc('admin_list_expense_entry_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_receipt_no: receiptNo,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    document.getElementById('lineTableBody').innerHTML = `<tr><td colspan="10" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderLineRows(data);
  await loadEntrySummary();

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
  renderTopNav('Expenses');

  const params = new URLSearchParams(window.location.search);
  receiptNo = params.get('receipt');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!receiptNo) {
    document.getElementById('entrySummaryNote').textContent = 'No receipt specified.';
    document.getElementById('lineTableBody').innerHTML = '<tr><td colspan="10" class="error-text">Missing ?receipt= parameter.</td></tr>';
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Expenses.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  await loadLines();
})();
