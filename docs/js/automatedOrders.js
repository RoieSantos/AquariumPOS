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
// Verbatim request body from the open order's most recent Pancake push attempt - see
// renderPancakeStatus / viewPancakePayload.
let lastSentPayload = null;

const STATUS_BADGE_CLASS = {
  New: 'badge-primary',
  Contacted: 'badge-warning',
  Confirmed: 'badge-purple',
  Completed: 'badge-success',
  Cancelled: 'badge-danger'
};

const PANCAKE_BADGE_CLASS = {
  Synced: 'badge-success',
  Failed: 'badge-danger',
  Pending: 'badge-neutral'
};

function pancakeBadgeHtml(status) {
  const cls = PANCAKE_BADGE_CLASS[status] || 'badge-neutral';
  return `<span class="badge ${cls}">${status || 'Pending'}</span>`;
}

// Sync-status badge plus, whenever Pancake actually returned an order_link (only true once
// PancakeSyncStatus reaches 'Synced'), a visible "#id" link under it straight to the order in
// Pancake's own dashboard. The link is the real "order_link" field from Pancake's own order-
// creation response (stored verbatim as PancakeOrderId/PancakeOrderLink by
// _push_automated_order_to_pancake) - NOT constructed client-side, since PancakeOrderId
// (Pancake's short internal id, e.g. "74398") turned out not to be the id order_link actually
// uses (a much longer numeric id) - confirmed live via Postman. A badge alone doesn't read as
// clickable, so the order id is shown as an explicit link rather than only wrapping the badge.
function pancakeBadgeWithLinkHtml(status, pancakeOrderId, pancakeOrderLink) {
  const badge = pancakeBadgeHtml(status);
  if (!pancakeOrderId || !pancakeOrderLink) return badge;
  const link = `<a href="${pancakeOrderLink}" target="_blank" rel="noopener" class="pancake-order-id-link" title="Open this order in Pancake">#${pancakeOrderId} &#8599;</a>`;
  return `${badge}<br>${link}`;
}

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
        <td>${pancakeBadgeWithLinkHtml(o.pancake_sync_status, o.pancake_order_id, o.pancake_order_link)}</td>
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
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    return;
  }

  tbody.innerHTML = (data || []).length === 0
    ? '<tr><td colspan="9" class="muted">No automated order requests found.</td></tr>'
    : orderRowsHtml(data);

  tbody.querySelectorAll('[data-view]').forEach((btn) => {
    btn.addEventListener('click', () => openOrderModal(btn.dataset.view));
  });
  tbody.querySelectorAll('tr.clickable-row').forEach((row) => {
    row.addEventListener('click', (event) => {
      // Ignore the Pancake order-id link too, same as the View button - otherwise clicking it
      // would both open Pancake in a new tab AND pop the order detail modal in this one.
      if (event.target.closest('button, a')) return;
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
  document.getElementById('modalPayloadBox').classList.add('hidden');
  document.getElementById('modalPayloadError').classList.add('hidden');
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
  document.getElementById('modalLocation').textContent = order.location || '-';

  renderPancakeStatus(order);

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

function renderPancakeStatus(order) {
  const statusBox = document.getElementById('modalPancakeStatus');
  const errorBox = document.getElementById('modalPancakeError');
  const retryBtn = document.getElementById('modalRetryPancakeBtn');

  lastSentPayload = order.pancake_last_payload || null;

  const orderIdText = (order.pancake_order_id && order.pancake_order_link)
    ? ` <a href="${order.pancake_order_link}" target="_blank" rel="noopener">Pancake order id: ${order.pancake_order_id} &#8599;</a>`
    : '';
  statusBox.innerHTML = pancakeBadgeHtml(order.pancake_sync_status) + orderIdText;

  if (order.pancake_sync_status === 'Failed' && order.pancake_sync_error) {
    errorBox.textContent = order.pancake_sync_error;
    errorBox.classList.remove('hidden');
  } else {
    errorBox.classList.add('hidden');
  }

  // Retrying a 'Synced' order would create a SECOND order in Pancake (no idempotency key to
  // upsert against server-side) - only offer it once a push has actually failed.
  retryBtn.classList.toggle('hidden', order.pancake_sync_status !== 'Failed');
}

async function retryPancakePush() {
  if (!currentOrderNo) return;
  const retryBtn = document.getElementById('modalRetryPancakeBtn');
  retryBtn.disabled = true;
  retryBtn.textContent = 'Retrying...';

  const { data, error } = await supabaseClient.rpc('admin_retry_automated_order_pancake_push', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: currentOrderNo
  });

  retryBtn.disabled = false;
  retryBtn.textContent = 'Retry Push to Pancake';

  if (error || !data || data.length === 0) {
    const errorBox = document.getElementById('modalPancakeError');
    errorBox.textContent = error?.message || 'Retry failed.';
    errorBox.classList.remove('hidden');
    return;
  }

  renderPancakeStatus({
    pancake_sync_status: data[0].pancake_sync_status,
    pancake_sync_error: data[0].pancake_sync_error,
    pancake_order_id: data[0].pancake_order_id,
    pancake_order_link: data[0].pancake_order_link,
    pancake_last_payload: data[0].pancake_last_payload
  });
  loadOrders(document.getElementById('orderSearchInput').value, document.getElementById('statusFilterInput').value);
}

async function viewPancakePayload() {
  if (!currentOrderNo) return;
  const viewBtn = document.getElementById('modalViewPayloadBtn');
  const box = document.getElementById('modalPayloadBox');
  const urlEl = document.getElementById('modalPayloadUrl');
  const jsonEl = document.getElementById('modalPayloadJson');
  const errorBox = document.getElementById('modalPayloadError');

  errorBox.classList.add('hidden');
  viewBtn.disabled = true;
  viewBtn.textContent = 'Loading...';

  const { data, error } = await supabaseClient.rpc('admin_debug_automated_order_pancake_payload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: currentOrderNo
  });

  viewBtn.disabled = false;
  viewBtn.textContent = 'View Endpoint & Payload';

  if (error || !data || data.length === 0) {
    errorBox.textContent = error?.message || 'Could not load payload.';
    errorBox.classList.remove('hidden');
    return;
  }

  urlEl.textContent = data[0].url || '';
  // Prefer the body actually sent on the last attempt (AutomatedOrders."PancakeLastPayload",
  // captured verbatim inside the push function) over the dry-run rebuild - copying a re-rendered
  // payload into Postman has repeatedly "matched" by eye while the real request still failed, so
  // what's shown here needs to be the true bytes, unreformatted.
  jsonEl.textContent = lastSentPayload || JSON.stringify(data[0].payload, null, 2);
  box.classList.remove('hidden');
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
  document.getElementById('modalRetryPancakeBtn').addEventListener('click', retryPancakePush);
  document.getElementById('modalViewPayloadBtn').addEventListener('click', viewPancakePayload);
  document.getElementById('orderModal').addEventListener('click', (event) => {
    if (event.target.id === 'orderModal') closeOrderModal();
  });

  await loadOrders('', '');
})();
