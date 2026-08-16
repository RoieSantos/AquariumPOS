// Automated Orders page (any active staff) - reviews/actions customer order requests submitted
// through the public order wizard (order-now.html / js/orderNow.js), which land in
// public."AutomatedOrders"/"AutomatedOrderLines" via submit_automated_order() - see
// supabase_automated_orders_tables.sql. Same read/update pattern as Online Orders: every RPC
// re-verifies the acting staff member's username/password (session.password from auth.js), no
// direct anon table access.
let currentSession = null;
let orderSearchDebounceHandle = null;
let loadGeneration = 0;
let currentPage = 1;
let currentPageSize = 50;
let currentOrderNo = null;

const STATUS_BADGE_CLASS = {
  New: 'badge-primary',
  Contacted: 'badge-warning',
  Confirmed: 'badge-purple',
  Completed: 'badge-success',
  Cancelled: 'badge-danger'
};

function formatMoney(value) {
  return '₱' + Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function statusBadgeHtml(status) {
  const cls = STATUS_BADGE_CLASS[status] || 'badge-neutral';
  return `<span class="badge ${cls}">${status || 'New'}</span>`;
}

function orderRowsHtml(orders) {
  return orders
    .map((o) => `
      <tr class="clickable-row" data-order-no="${o.order_no}">
        <td>${o.order_no || ''}</td>
        <td>${o.created_at_utc ? new Date(o.created_at_utc).toLocaleString() : ''}</td>
        <td>${o.customer_name || ''}</td>
        <td>${o.customer_phone || ''}</td>
        <td>${o.fulfillment_type || ''}</td>
        <td>${formatMoney(o.estimated_total)}</td>
        <td>${statusBadgeHtml(o.status)}</td>
        <td><button type="button" class="btn btn-secondary btn-sm" data-view="${o.order_no}">View</button></td>
      </tr>
    `)
    .join('');
}

async function loadOrders(search, status) {
  const myGeneration = ++loadGeneration;
  const tbody = document.getElementById('orderTableBody');
  const trimmedSearch = (search || '').trim();
  const trimmedStatus = (status || '').trim();

  const { data, error } = await supabaseClient.rpc('admin_list_automated_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: trimmedSearch || null,
    p_status: trimmedStatus || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (myGeneration !== loadGeneration) return;

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${error.message}</td></tr>`;
    return;
  }

  tbody.innerHTML = (data || []).length === 0
    ? '<tr><td colspan="8" class="muted">No automated order requests found.</td></tr>'
    : orderRowsHtml(data);

  tbody.querySelectorAll('[data-view]').forEach((btn) => {
    btn.addEventListener('click', () => openOrderModal(btn.dataset.view));
  });
  tbody.querySelectorAll('tr.clickable-row').forEach((row) => {
    row.addEventListener('click', (event) => {
      if (event.target.closest('button')) return;
      openOrderModal(row.dataset.orderNo);
    });
  });

  renderPaginationBar(
    document.getElementById('orderPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadOrders(trimmedSearch, trimmedStatus); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadOrders(trimmedSearch, trimmedStatus); }
    }
  );
}

async function openOrderModal(orderNo) {
  currentOrderNo = orderNo;
  const modal = document.getElementById('orderModal');
  document.getElementById('modalStatusError').classList.add('hidden');
  modal.classList.remove('hidden');
  document.getElementById('modalOrderNo').textContent = 'Loading...';
  document.getElementById('modalLinesBody').innerHTML = '';

  const [{ data: orders, error: orderError }, { data: lines, error: lineError }] = await Promise.all([
    supabaseClient.rpc('admin_list_automated_orders', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_search: orderNo,
      p_status: null,
      p_page: 1,
      p_page_size: 1
    }),
    supabaseClient.rpc('admin_list_automated_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_no: orderNo
    })
  ]);

  if (orderError || lineError || !orders || orders.length === 0) {
    document.getElementById('modalOrderNo').textContent = orderNo;
    document.getElementById('modalStatusError').textContent = (orderError || lineError)?.message || 'Order not found.';
    document.getElementById('modalStatusError').classList.remove('hidden');
    return;
  }

  const order = orders[0];
  document.getElementById('modalOrderNo').textContent = order.order_no;
  document.getElementById('modalCustomerName').textContent = order.customer_name || '';
  document.getElementById('modalCustomerPhone').textContent = order.customer_phone || '';
  document.getElementById('modalCustomerEmail').textContent = order.customer_email || '-';
  document.getElementById('modalFulfillment').textContent = order.fulfillment_type || '';

  const addressRow = document.getElementById('modalAddressRow');
  addressRow.classList.toggle('hidden', order.fulfillment_type !== 'Delivery');
  document.getElementById('modalAddress').textContent = order.delivery_address || '';

  const notesRow = document.getElementById('modalNotesRow');
  notesRow.classList.toggle('hidden', !order.notes);
  document.getElementById('modalNotes').textContent = order.notes || '';

  document.getElementById('modalStatusSelect').value = order.status || 'New';

  document.getElementById('modalLinesBody').innerHTML = (lines || [])
    .map((l) => `
      <tr>
        <td>${l.item_name}</td>
        <td>${l.quantity}</td>
        <td>${formatMoney(l.price)}</td>
        <td>${formatMoney(l.quantity * l.price)}</td>
      </tr>
    `)
    .join('');
}

function closeOrderModal() {
  document.getElementById('orderModal').classList.add('hidden');
  currentOrderNo = null;
}

async function saveOrderStatus() {
  if (!currentOrderNo) return;
  const errorEl = document.getElementById('modalStatusError');
  errorEl.classList.add('hidden');
  const saveBtn = document.getElementById('modalSaveStatusBtn');
  saveBtn.disabled = true;

  const { error } = await supabaseClient.rpc('admin_update_automated_order_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: currentOrderNo,
    p_status: document.getElementById('modalStatusSelect').value
  });

  saveBtn.disabled = false;

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  closeOrderModal();
  loadOrders(document.getElementById('orderSearchInput').value, document.getElementById('statusFilterInput').value);
}

function wireOrderFilters() {
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');

  const reload = () => {
    currentPage = 1;
    clearTimeout(orderSearchDebounceHandle);
    orderSearchDebounceHandle = setTimeout(
      () => loadOrders(searchInput.value.trim(), statusInput.value.trim()),
      300
    );
  };

  searchInput.addEventListener('input', reload);
  statusInput.addEventListener('change', reload);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Automated Orders');

  wireOrderFilters();
  document.getElementById('modalCloseBtn').addEventListener('click', closeOrderModal);
  document.getElementById('modalSaveStatusBtn').addEventListener('click', saveOrderStatus);
  document.getElementById('orderModal').addEventListener('click', (event) => {
    if (event.target.id === 'orderModal') closeOrderModal();
  });

  await loadOrders('', '');
})();
