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

function poRowsHtml(rows) {
  return rows
    .map((po) => `
      <tr>
        <td><a href="purchase-order-print.html?po=${encodeURIComponent(po.po_no)}" target="_blank">${po.po_no}</a></td>
        <td>${po.vendor_name || po.vendor_code || ''}</td>
        <td>${formatDate(po.order_date)}</td>
        <td style="text-align:right;">${po.line_count ?? 0}</td>
        <td style="text-align:right;">${Number(po.total_quantity || 0).toLocaleString()}</td>
        <td>${po.created_by || ''}</td>
        <td>
          <a href="purchase-order-print.html?po=${encodeURIComponent(po.po_no)}" target="_blank" class="btn btn-secondary btn-sm">Print</a>
          <button class="btn btn-secondary btn-sm" data-delete-po="${encodeURIComponent(po.po_no)}" type="button">Delete</button>
        </td>
      </tr>
    `)
    .join('');
}

async function loadPurchaseOrders() {
  const tbody = document.getElementById('poTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_purchase_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="7" class="muted">No Purchase Orders yet - create one from Stock On Hand.</td></tr>'
    : poRowsHtml(rows);

  renderPaginationBar(
    document.getElementById('poPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: rows[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadPurchaseOrders(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadPurchaseOrders(); }
    }
  );
}

async function deletePurchaseOrder(poNo) {
  if (!window.confirm(`Delete Purchase Order ${poNo}? This cannot be undone.`)) return;

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
    deletePurchaseOrder(decodeURIComponent(btn.dataset.deletePo));
  });

  await loadPurchaseOrders();
})();
