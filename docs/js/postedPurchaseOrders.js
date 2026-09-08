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

// Description is unconstrained free text (js/purchaseOrders.js), unlike item_code/item_name which
// come from a catalog picker - escaped before going into innerHTML.
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatDateTime(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleString();
}

// Business Central-style document view state (maximize + General FastTab), same as the live
// Purchase Order card (js/purchaseOrders.js) - remembered per browser under this page's own keys,
// since maximizing to read a posted order is a separate habit from maximizing to work an open one.
//
// localStorage is wrapped because it throws outright in some privacy modes rather than just
// returning null - a stored preference must never be able to stop the view modal from opening.
const VIEW_MAXIMIZED_KEY = 'posted-po-view-modal-maximized';
const VIEW_GENERAL_TAB_KEY = 'posted-po-view-general-tab-open';

function readStoredFlag(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value === null ? fallback : value === '1';
  } catch (err) {
    return fallback;
  }
}

function writeStoredFlag(key, value) {
  try {
    localStorage.setItem(key, value ? '1' : '0');
  } catch (err) {
    /* Preference simply won't persist - not worth surfacing. */
  }
}

function applyViewMaximized(maximized) {
  document.getElementById('viewModal').classList.toggle('modal-maximized', maximized);
  document.getElementById('viewModal').querySelector('.modal-panel')
    .classList.toggle('modal-maximized', maximized);

  const btn = document.getElementById('viewMaximizeBtn');
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized
    ? 'Restore this document to a window'
    : 'Maximize this document to fill the window';
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
        <td>${escapeHtml(po.warehouse_name || '')}</td>
        <td>${formatDate(po.order_date)}</td>
        <td style="text-align:right;">${po.line_count ?? 0}</td>
        <td style="text-align:right;">${Number(po.total_quantity || 0).toLocaleString()}</td>
        <td>${receivedBadgeHtml(po)}</td>
        <td style="text-align:right;">${Number(po.total_cost || 0).toFixed(2)}</td>
        <td>${escapeHtml(po.payment_method || '')}</td>
        <td>${po.posted_by || ''}</td>
        <td>${formatDateTime(po.posted_at_utc)}</td>
        <td><a href="purchase-order-print.html?po=${encodeURIComponent(po.po_no)}" class="btn btn-secondary btn-sm" onclick="event.stopPropagation();">Print</a></td>
      </tr>
    `)
    .join('');
}

async function loadPurchaseOrders() {
  const tbody = document.getElementById('poTableBody');
  tbody.innerHTML = '<tr><td colspan="12" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_posted_purchase_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="12" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="12" class="muted">No posted Purchase Orders found.</td></tr>'
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

// "(5 BOX)" under a base quantity, for a line that was ordered in something other than the item's
// base unit - the same note the open PO shows (js/purchaseOrders.js). Quantities in the archive
// are base units; this is how many boxes that was. See supabase_units_of_measure.sql.
// Priced per the unit the line was ordered in (unit_cost_uom, see
// supabase_purchase_order_line_uom_edit.sql) - a line showing "5 BOX" has to show the box price
// beside it, not the per-piece one, or the quantity and the cost read as different things.
function unitCostPerUomHtml(l) {
  const value = l.unit_cost_uom ?? l.unit_cost;
  if (value === null || value === undefined) return '<span class="muted">-</span>';

  // The Quantity column leads with the base quantity, so the base price is carried underneath -
  // same pairing the open PO's Unit Cost cell shows (js/purchaseOrders.js).
  const baseNote = Number(l.qty_per_uom || 1) !== 1
    ? `<div class="muted" style="font-size:11px;">${Number(l.unit_cost).toFixed(2)} / base</div>`
    : '';

  return `${Number(value).toFixed(2)}${baseNote}`;
}

// Quantity in the unit the line was ordered in, with the base quantity underneath - the same
// pairing the open PO uses and the same one the Unit Cost column beside it uses, so a row reads
// "5 BOX x 480.00" straight across. Qty Received next to it stays in base units: that is what
// actually arrived. See supabase_units_of_measure.sql.
function qtyOrderedHtml(l) {
  const qtyPer = Number(l.qty_per_uom || 1);
  // A line archived before units existed carries no QuantityUom; its Quantity was already the
  // typed number, at a conversion of 1.
  const qtyUom = l.quantity_uom === null || l.quantity_uom === undefined
    ? Number(l.quantity || 0)
    : Number(l.quantity_uom);

  if (qtyPer === 1) return qtyUom.toLocaleString();

  return `${qtyUom.toLocaleString()} ${escapeHtml(l.uom_code || '')}`.trim()
    + `<div class="muted" style="font-size:11px;">${Number(l.quantity || 0).toLocaleString()} base</div>`;
}

function renderViewLines(lines) {
  const body = document.getElementById('viewLinesBody');
  const totalEl = document.getElementById('viewTotalCost');
  const totalNoteEl = document.getElementById('viewTotalCostNote');

  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="8" class="muted">No line items.</td></tr>';
    if (totalEl) totalEl.textContent = '0.00';
    if (totalNoteEl) totalNoteEl.classList.add('hidden');
    return;
  }

  // NOTE: a posted line's line_cost is costed against Qty RECEIVED, not Qty Ordered (see
  // staff_list_posted_purchase_order_lines) - the archive records money actually committed, so a
  // short-shipped line did not cost the full ordered quantity.
  if (totalEl) {
    totalEl.textContent = lines
      .reduce((sum, l) => sum + (Number(l.line_cost) || 0), 0)
      .toFixed(2);
  }

  // staff_post_purchase_order refuses to post while any RECEIVED line has no Unit Cost (see
  // supabase_gl_posting_integration.sql), so this should be rare - but a PO posted before that
  // check existed can still have one. An unreceived line's $0 is correct (nothing was received,
  // nothing was spent); only a RECEIVED-but-uncosted line means the total is actually missing
  // money, same distinction the open PO's own Total Cost note makes.
  if (totalNoteEl) {
    const uncostedReceivedCount = lines.filter((l) =>
      (l.unit_cost === null || l.unit_cost === undefined) && Number(l.qty_received || 0) > 0
    ).length;
    if (uncostedReceivedCount > 0) {
      totalNoteEl.textContent = `Excludes ${uncostedReceivedCount} received item${uncostedReceivedCount === 1 ? '' : 's'} with no Unit Cost - total is understated`;
      totalNoteEl.classList.remove('hidden');
    } else {
      totalNoteEl.classList.add('hidden');
    }
  }

  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.item_code || ''}</td>
        <td>${l.item_name || ''}</td>
        <td>${escapeHtml(l.description || '')}</td>
        <td>${l.warehouse_name || ''}</td>
        <td style="text-align:right;">${qtyOrderedHtml(l)}</td>
        <td style="text-align:right;">${Number(l.qty_received || 0).toLocaleString()}</td>
        <td style="text-align:right;">${unitCostPerUomHtml(l)}</td>
        <td style="text-align:right;">${l.unit_cost === null || l.unit_cost === undefined ? '<span class="muted">-</span>' : Number(l.line_cost || 0).toFixed(2)}</td>
      </tr>
    `)
    .join('');
}

async function openViewModal(poNo) {
  document.getElementById('viewModalTitle').textContent = `Purchase Order ${poNo}`;
  document.getElementById('viewPrintLink').href = `purchase-order-print.html?po=${encodeURIComponent(poNo)}`;
  const body = document.getElementById('viewLinesBody');
  body.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';
  document.getElementById('viewModal').classList.remove('hidden');

  // Restore the layout this browser last used, before the panel is seen.
  applyViewMaximized(readStoredFlag(VIEW_MAXIMIZED_KEY, false));
  document.getElementById('viewGeneralTab').open = readStoredFlag(VIEW_GENERAL_TAB_KEY, true);

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
    body.innerHTML = `<tr><td colspan="8" class="error-text">${headerError?.message || 'Posted Purchase Order not found.'}</td></tr>`;
    return;
  }

  const header = headerRows[0];
  document.getElementById('viewVendor').textContent = header.vendor_name || header.vendor_code || '';
  // Carried over from the live PO when it was posted (see the trigger in
  // supabase_purchase_order_header_warehouse.sql); blank on orders posted before that existed.
  document.getElementById('viewWarehouse').textContent = header.warehouse_name || '-';
  document.getElementById('viewOrderDate').textContent = formatDate(header.order_date);
  // Carried over from the live PO when it was posted (supabase_purchase_order_payment_method.sql's
  // TR_PostedPurchaseOrders_FillPaymentMethod trigger); blank on orders posted before that existed.
  document.getElementById('viewPaymentMethod').textContent = header.payment_method || '-';
  document.getElementById('viewNotes').textContent = header.notes || '-';
  document.getElementById('viewPostedBy').textContent = `${header.posted_by || 'unknown'} on ${formatDateTime(header.posted_at_utc)}`;

  // Shown on the General tab only while it is collapsed, so folding the tab away never costs you
  // the fields you most need at a glance - same rule the live PO card uses.
  document.getElementById('viewGeneralSummary').textContent =
    [header.vendor_name || header.vendor_code, header.warehouse_name, formatDate(header.order_date)]
      .filter(Boolean).join(' · ');

  if (lineError) {
    body.innerHTML = `<tr><td colspan="8" class="error-text">${lineError.message}</td></tr>`;
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
  document.getElementById('viewMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('viewModal').classList.contains('modal-maximized');
    applyViewMaximized(nowMaximized);
    writeStoredFlag(VIEW_MAXIMIZED_KEY, nowMaximized);
  });
  document.getElementById('viewGeneralTab').addEventListener('toggle', (e) => {
    writeStoredFlag(VIEW_GENERAL_TAB_KEY, e.target.open);
  });

  await loadPurchaseOrders();
})();
