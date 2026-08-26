// Posted Purchase Orders page logic - read-only browse/search of posted Purchase Orders,
// archived into PostedPurchaseOrders/PostedPurchaseOrderLines by postPurchaseOrder() in
// purchaseOrders.js (see supabase_purchase_order_receiving.sql). Same shape as
// posted-transfer-orders.html/js's own read-only list.
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

function formatDateTime(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleString();
}

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
        <td>${po.posted_by || ''}</td>
        <td>${formatDateTime(po.posted_at_utc)}</td>
        <td><a href="purchase-order-print.html?po=${encodeURIComponent(po.po_no)}" class="btn btn-secondary btn-sm" onclick="event.stopPropagation();">Print</a></td>
      </tr>
    `)
    .join('');
}

async function loadPurchaseOrders() {
  const tbody = document.getElementById('poTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_posted_purchase_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="9" class="muted">No posted Purchase Orders found.</td></tr>'
    : poRowsHtml(rows);

  tbody.querySelectorAll('tr[data-po-no]').forEach((row) => {
    row.addEventListener('click', () => openViewModal(decodeURIComponent(row.dataset.poNo)));
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

function renderViewLines(lines) {
  const body = document.getElementById('viewLinesBody');
  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="5" class="muted">No line items.</td></tr>';
    return;
  }

  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.item_code || ''}</td>
        <td>${l.item_name || ''}</td>
        <td>${l.warehouse_name || ''}</td>
        <td style="text-align:right;">${Number(l.quantity || 0).toLocaleString()}</td>
        <td style="text-align:right;">${Number(l.qty_received || 0).toLocaleString()}</td>
      </tr>
    `)
    .join('');
}

async function openViewModal(poNo) {
  document.getElementById('viewModalTitle').textContent = `Purchase Order ${poNo}`;
  document.getElementById('viewPrintLink').href = `purchase-order-print.html?po=${encodeURIComponent(poNo)}`;
  const body = document.getElementById('viewLinesBody');
  body.innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';
  document.getElementById('viewModal').classList.remove('hidden');

  const [{ data: headerRows, error: headerError }, { data: lineRows, error: lineError }] = await Promise.all([
    supabaseClient.rpc('staff_get_posted_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    }),
    supabaseClient.rpc('staff_list_posted_purchase_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    })
  ]);

  if (headerError || !headerRows || headerRows.length === 0) {
    body.innerHTML = `<tr><td colspan="5" class="error-text">${headerError?.message || 'Posted Purchase Order not found.'}</td></tr>`;
    return;
  }

  const header = headerRows[0];
  document.getElementById('viewVendor').textContent = header.vendor_name || header.vendor_code || '';
  document.getElementById('viewOrderDate').textContent = formatDate(header.order_date);
  document.getElementById('viewNotes').textContent = header.notes || '-';
  document.getElementById('viewPostedBy').textContent = `${header.posted_by || 'unknown'} on ${formatDateTime(header.posted_at_utc)}`;

  if (lineError) {
    body.innerHTML = `<tr><td colspan="5" class="error-text">${lineError.message}</td></tr>`;
    return;
  }

  renderViewLines(lineRows || []);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Posted Purchase Orders');

  document.getElementById('poSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadPurchaseOrders();
    }, 300);
  });

  document.getElementById('closeViewModalBtn').addEventListener('click', () =>
    document.getElementById('viewModal').classList.add('hidden')
  );

  await loadPurchaseOrders();
})();
