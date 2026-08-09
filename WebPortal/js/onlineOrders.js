// Online Orders page logic (any active staff, read-only).
//
// Reads straight from the persisted public."OnlineOrders" table via admin_list_online_orders() -
// no live Pancake calls from this page anymore, since the background cron job
// (cron_sync_online_orders_from_pancake, runs every minute) already keeps that table fresh on
// its own. This makes the page load instantly regardless of backlog size, with no
// throttling/incremental-catch-up/chunked-paging complexity needed.
//
// No password re-unlock prompt here (unlike the super-user-only setup pages) - since this page
// is open to any active staff member, it reuses the password captured at login (session.password,
// see auth.js) to satisfy the RPC's re-verification requirement without asking again.
let currentSession = null;
let orderSearchDebounceHandle = null;
let loadGeneration = 0;
let currentPage = 1;
let currentPageSize = 50;

// Deep-link filters from a Dashboard finance card (?period=month|today|prevmonth, ?scope=walkin,
// ?filter=outstanding) or a Sales by Staff figure (?confirmedBy=...&period=...) - set once in
// init() from the URL, then applied on every load/reload for the rest of this page view
// (search/status typed afterward combine with these, they don't replace them). See the
// finance-card hrefs in dashboard.html and staffStatLinkHtml in js/dashboard.js.
let currentPeriod = null;
let currentScope = null;
let outstandingOnly = false;
let currentConfirmedBy = null;

// Warehouse-scoped staff (StaffUsers.WarehouseName set) only see orders for their own
// warehouse - same convention as Transfer Orders (js/transferOrders.js). Orders with no
// resolved warehouse_name (e.g. LocationID didn't match any synced Warehouses row) are
// hidden while scoped, since we can't confirm they belong to this user's warehouse.
function matchesWarehouseFilter(order) {
  if (!currentSession.warehouseName) return true;
  return (order.warehouse_name || '') === currentSession.warehouseName;
}

const STATUS_SUMMARY_ELEMENT_IDS = {
  'Confirmed': 'statusCountConfirmed',
  'Printed': 'statusCountPrinted',
  'To Ship': 'statusCountToShip',
  'Shipped': 'statusCountShipped',
  'Cancelled': 'statusCountCancelled'
};

// Exact per-status record counts, from the persisted OnlineOrders table (kept fresh by the
// background cron sync) - fast/instant since it's a simple grouped count on a local table (see
// admin_get_online_order_status_summary in supabase_orders_sync_tables.sql).
async function loadStatusSummary() {
  if (!currentSession.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_online_order_status_summary', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_name: currentSession.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_online_order_status_summary failed:', error);
    return;
  }

  data.forEach((row) => {
    const elementId = STATUS_SUMMARY_ELEMENT_IDS[row.status_label];
    if (elementId) {
      document.getElementById(elementId).textContent = row.order_count;
    }
  });
}

// Per "put a flag in the online header to show if an order has 10mm glass or 12mm glass custom
// aquarium it may need or require an attachment" - o.glass_thickness comes from
// admin_list_online_orders() (see supabase_orders_sync_tables.sql), which scans that order's
// synced lines for a 10mm/12mm mention. Blank when no such line was found.
function glassBadgeHtml(order) {
  if (!order.glass_thickness) return '';
  return `<span class="badge badge-glass" title="This order has a ${order.glass_thickness} glass custom aquarium line - it may need an attachment (see Online Order Lines).">${order.glass_thickness} glass</span>`;
}

function orderRowsHtml(orders) {
  return orders
    .map((o) => `
      <tr data-order-id="${o.order_id}">
        <td>${o.order_id || ''}</td>
        <td>${o.order_date || ''}</td>
        <td>${o.order_time || ''}</td>
        <td>${o.customer_name || ''}</td>
        <td>${o.status || ''}</td>
        <td>${o.confirmed_by || ''}</td>
        <td>${o.created_by || ''}</td>
        <td>${glassBadgeHtml(o)}</td>
        <td>${o.warehouse_name || o.location_id || ''}</td>
        <td><span class="badge ${o.for_delivery ? 'badge-success' : 'badge-neutral'}">${o.for_delivery ? 'Yes' : 'No'}</span></td>
        <td>${o.estimated_delivery_date || ''}</td>
        <td>${o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : ''}</td>
        <td><a href="online-order-lines.html?order=${encodeURIComponent(o.order_id)}">View</a></td>
      </tr>
    `)
    .join('');
}

async function loadOrders(search, status) {
  const myGeneration = ++loadGeneration;
  const tbody = document.getElementById('orderTableBody');
  const trimmedSearch = (search || '').trim();
  const trimmedStatus = (status || '').trim();

  const { data, error } = await supabaseClient.rpc('admin_list_online_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: trimmedSearch || null,
    p_status: trimmedStatus || null,
    p_period: currentPeriod,
    p_walkin_only: currentScope === 'walkin',
    p_page: currentPage,
    p_page_size: currentPageSize,
    p_confirmed_by: currentConfirmedBy
  });

  if (myGeneration !== loadGeneration) return;

  if (error) {
    tbody.innerHTML = `<tr><td colspan="13" class="error-text">${error.message}</td></tr>`;
    return;
  }

  // NOTE: warehouse-scoping/outstanding-only are client-side post-filters (no matching server
  // param), applied AFTER the server already paged the unfiltered result - a warehouse-scoped
  // or outstanding-only view can therefore show fewer than pageSize rows on a page, and the
  // pagination bar's total/page count reflects the pre-filter total, not the filtered count
  // actually shown. Same pre-existing tradeoff the old fixed-500-row fetch had; not something
  // this pagination pass changes.
  let rows = (data || []).filter(matchesWarehouseFilter);
  if (outstandingOnly) {
    rows = rows.filter((o) => Number(o.balance) > 0);
  }

  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="13" class="muted">No online orders found.</td></tr>'
    : orderRowsHtml(rows);

  renderPaginationBar(
    document.getElementById('orderPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadOrders(trimmedSearch, trimmedStatus); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadOrders(trimmedSearch, trimmedStatus); }
    }
  );
}

function escapeCsvValue(value) {
  const str = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(str) ? '"' + str.replace(/"/g, '""') + '"' : str;
}

// Super-user-only "Export to Excel" (exportExcelBtn - see init()'s session.isSuperUser gate).
// Exports every order matching the CURRENT search/status/period/scope/confirmedBy/warehouse
// filters, not just the page currently on screen - loops admin_list_online_orders at its own
// max page size (200, see v_page_size in supabase_orders_sync_tables.sql) until exhausted.
// Plain CSV (not a real .xlsx) - Excel opens it natively with no extra library/CDN dependency;
// the UTF-8 BOM prefix keeps Excel from mangling the Peso sign in any money fields later added.
async function exportOrdersToExcel() {
  const btn = document.getElementById('exportExcelBtn');
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');
  const trimmedSearch = searchInput.value.trim();
  const trimmedStatus = statusInput.value.trim();
  const exportPageSize = 200;

  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Exporting...';

  try {
    const allRows = [];
    let page = 1;
    for (;;) {
      const { data, error } = await supabaseClient.rpc('admin_list_online_orders', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_search: trimmedSearch || null,
        p_status: trimmedStatus || null,
        p_period: currentPeriod,
        p_walkin_only: currentScope === 'walkin',
        p_page: page,
        p_page_size: exportPageSize,
        p_confirmed_by: currentConfirmedBy
      });

      if (error) {
        alert('Export failed: ' + error.message);
        return;
      }

      let rows = (data || []).filter(matchesWarehouseFilter);
      if (outstandingOnly) {
        rows = rows.filter((o) => Number(o.balance) > 0);
      }
      allRows.push(...rows);

      if (!data || data.length < exportPageSize) break;
      page += 1;
    }

    if (allRows.length === 0) {
      alert('No orders to export for the current filters.');
      return;
    }

    // Every field admin_list_online_orders returns (except total_count, which is pagination
    // metadata, not an order field) - per "include all available fields in the export".
    const headers = [
      'Order ID', 'Date', 'Time', 'Status', 'Customer', 'Location ID', 'Warehouse',
      'Money To Collect', 'Amount Paid', 'Discount', 'Balance', 'For Delivery',
      'Shipping Address', 'Est. Delivery Date', 'Last Updated', 'Synced At', 'Glass Thickness',
      'Created By', 'Confirmed By'
    ];
    const csvLines = [headers.map(escapeCsvValue).join(',')];
    allRows.forEach((o) => {
      csvLines.push([
        o.order_id,
        o.order_date,
        o.order_time,
        o.status,
        o.customer_name,
        o.location_id,
        o.warehouse_name,
        o.money_to_collect,
        o.amount_paid,
        o.discount,
        o.balance,
        o.for_delivery ? 'Yes' : 'No',
        o.shipping_address,
        o.estimated_delivery_date,
        o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : '',
        o.synced_at_utc ? new Date(o.synced_at_utc).toLocaleString() : '',
        o.glass_thickness,
        o.created_by,
        o.confirmed_by
      ].map(escapeCsvValue).join(','));
    });

    const blob = new Blob(['﻿' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    const link = document.createElement('a');
    link.href = url;
    link.download = `online-orders-${stamp}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

// Highlights whichever status-summary pill matches the current status filter text (case-
// insensitive), so clicking a pill (or typing a status directly into the filter box) gives a
// clear "this is the active filter" indication.
function updateStatusPillActiveState() {
  const currentStatus = document.getElementById('statusFilterInput').value.trim().toLowerCase();
  document.querySelectorAll('#statusSummaryBar .status-summary-pill').forEach((pill) => {
    pill.classList.toggle('active', currentStatus !== '' && pill.dataset.status.toLowerCase() === currentStatus);
  });
}

function wireOrderFilters() {
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');

  const reload = () => {
    updateStatusPillActiveState();
    currentPage = 1;
    clearTimeout(orderSearchDebounceHandle);
    orderSearchDebounceHandle = setTimeout(
      () => loadOrders(searchInput.value.trim(), statusInput.value.trim()),
      300
    );
  };

  searchInput.addEventListener('input', reload);
  statusInput.addEventListener('input', reload);

  // Per "make that button clickable so the user can filter out based on status" - clicking a
  // status-summary pill sets the status filter box to that status (or clears it if the same
  // pill is clicked again while already active) and reloads immediately, no debounce needed
  // since it's a discrete click rather than free-text typing.
  document.getElementById('statusSummaryBar').addEventListener('click', (event) => {
    const pill = event.target.closest('.status-summary-pill');
    if (!pill) return;

    const clickedStatus = pill.dataset.status;
    const alreadyActive = statusInput.value.trim().toLowerCase() === clickedStatus.toLowerCase();
    statusInput.value = alreadyActive ? '' : clickedStatus;
    updateStatusPillActiveState();
    currentPage = 1;

    clearTimeout(orderSearchDebounceHandle);
    loadOrders(searchInput.value.trim(), statusInput.value.trim());
  });

  document.getElementById('exportExcelBtn').addEventListener('click', exportOrdersToExcel);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Online Orders');

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Online Orders.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('exportExcelBtn').classList.toggle('hidden', !session.isSuperUser);
  wireOrderFilters();

  // Supports deep-linking from the Dashboard's status cards, e.g. online-orders.html?status=Shipped,
  // from the Dashboard's finance cards, e.g. ?period=month|today|prevmonth, ?scope=walkin,
  // ?filter=outstanding, and from a Sales by Staff figure, e.g. ?confirmedBy=Juan+Dela+Cruz&period=month
  // (see dashboard.html's finance-card hrefs / staffStatLinkHtml in js/dashboard.js / the
  // module-level comment on currentPeriod above).
  const urlParams = new URLSearchParams(window.location.search);
  const statusParam = urlParams.get('status') || '';
  const periodParam = urlParams.get('period') || '';
  const scopeParam = urlParams.get('scope') || '';
  const filterParam = urlParams.get('filter') || '';
  const confirmedByParam = urlParams.get('confirmedBy') || '';

  if (statusParam) {
    document.getElementById('statusFilterInput').value = statusParam;
  }
  updateStatusPillActiveState();

  currentPeriod = periodParam === 'month' || periodParam === 'today' || periodParam === 'prevmonth' ? periodParam : null;
  currentScope = scopeParam === 'walkin' ? 'walkin' : null;
  outstandingOnly = filterParam === 'outstanding';
  currentConfirmedBy = confirmedByParam.trim() || null;

  const noteParts = [];
  if (currentConfirmedBy) {
    noteParts.push(`orders confirmed by ${currentConfirmedBy}`);
  } else {
    if (currentScope === 'walkin') noteParts.push('walk-in');
    noteParts.push(currentScope === 'walkin' ? 'sales' : 'online orders');
  }
  if (currentPeriod === 'month') {
    noteParts.push('for ' + new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
  } else if (currentPeriod === 'today') {
    noteParts.push('for today (' + new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) + ')');
  } else if (currentPeriod === 'prevmonth') {
    const prevMonthDate = new Date();
    prevMonthDate.setDate(1);
    prevMonthDate.setMonth(prevMonthDate.getMonth() - 1);
    noteParts.push('for ' + prevMonthDate.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
  }
  if (outstandingOnly) noteParts.push('with an outstanding balance');

  const activeFilterNote = document.getElementById('activeFilterNote');
  if (currentPeriod || currentScope || outstandingOnly || currentConfirmedBy) {
    activeFilterNote.innerHTML = `Showing ${noteParts.join(' ')}. <a href="online-orders.html">Clear filters</a>`;
    activeFilterNote.classList.remove('hidden');
  }

  // The status summary bar/pills only ever count non-walk-in orders (see
  // admin_get_online_order_status_summary) - hide it entirely rather than show misleading
  // counts when viewing a walk-in-scoped deep link.
  const showStatusSummary = currentScope !== 'walkin';
  document.getElementById('statusSummaryBar').classList.toggle('hidden', !showStatusSummary);

  const loaders = [loadOrders('', statusParam)];
  if (showStatusSummary) loaders.push(loadStatusSummary());
  await Promise.all(loaders);
})();
