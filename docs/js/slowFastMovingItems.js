// Slow & Fast Moving Items report (Reports > Sales, same audience as Top Selling Items).
// One RPC call (admin_get_slow_fast_moving_items, sql/supabase_slow_fast_moving_report.sql) returns
// every item with its class (Fast / Medium / Slow / Not Moving) for the chosen look-back window;
// tabs, search, category, "in stock only", sorting and paging are all client-side on that result.
// Cost / stock value columns only appear for Super Users (the RPC returns null cost to others).
let currentSession = null;
let periodDays = 90;
let allRows = [];
let classFilter = '';
let sortKey = 'default';
let sortDir = 1;
let visibleCount = 100;
let showCost = false;
let topN = 10; // how many bars each chart shows ("Show top" 10/20/50/100)
const PAGE_SIZE = 100;

const CLASS_BADGE = {
  'Fast': 'badge-success',
  'Medium': 'badge-primary',
  'Slow': 'badge-warning',
  'Not Moving': 'badge-danger'
};
const CLASS_ORDER = { 'Fast': 0, 'Medium': 1, 'Slow': 2, 'Not Moving': 3 };

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function formatMoney(value) {
  const amount = Number(value) || 0;
  return '₱' + amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatQty(value) {
  const n = Number(value) || 0;
  return n.toLocaleString('en-PH', { maximumFractionDigits: 2 });
}

function todayManila() {
  // YYYY-MM-DD for the shop's day, matching the RPC's Asia/Manila "today".
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

function daysBetween(fromKey, toKey) {
  return Math.round((Date.parse(toKey + 'T00:00:00Z') - Date.parse(fromKey + 'T00:00:00Z')) / 86400000);
}

// Derived per-row numbers, computed once after load.
function enrich(rows) {
  const today = todayManila();
  return rows.map((r) => {
    const qty = Number(r.qty_sold) || 0;
    const onHand = Number(r.stock_on_hand) || 0;
    const perDay = qty / periodDays;
    const cost = r.unit_cost == null ? null : Number(r.unit_cost);
    return {
      ...r,
      qty,
      onHand,
      perMonth: perDay * 30,
      // Days the current stock would last at this period's sales rate (null = no sales -> never).
      cover: perDay > 0 ? onHand / perDay : null,
      daysSinceSold: r.last_sold_date ? daysBetween(r.last_sold_date, today) : null,
      daysSinceEntry: r.last_entry_date ? daysBetween(r.last_entry_date, today) : null,
      stockValue: cost == null ? null : Math.max(onHand, 0) * cost
    };
  });
}

function filteredRows() {
  const search = document.getElementById('searchInput').value.trim().toLowerCase();
  const category = document.getElementById('categorySelect').value;
  const inStockOnly = document.getElementById('inStockOnly').checked;

  let rows = allRows.filter((r) => {
    if (classFilter && r.movement_class !== classFilter) return false;
    if (category && (r.category_code || '') !== category) return false;
    if (inStockOnly && r.onHand <= 0) return false;
    if (search && !(`${r.item_code} ${r.item_name}`.toLowerCase().includes(search))) return false;
    return true;
  });

  if (sortKey !== 'default') {
    const col = COLUMNS.find((c) => c.key === sortKey);
    rows = rows.slice().sort((a, b) => {
      const av = col.sortValue(a);
      const bv = col.sortValue(b);
      // Blanks always sink to the bottom whichever way we sort.
      if (av == null && bv == null) return 0;
      if (av == null) return 1;
      if (bv == null) return -1;
      if (typeof av === 'string') return av.localeCompare(bv) * sortDir;
      return (av - bv) * sortDir;
    });
  } else if (classFilter === 'Slow' || classFilter === 'Not Moving') {
    // For slow lists the useful default is "what's sitting on the shelf the most".
    rows = rows.slice().sort((a, b) => (b.stockValue ?? b.onHand) - (a.stockValue ?? a.onHand) || b.onHand - a.onHand);
  }
  return rows;
}

const COLUMNS = [
  { key: 'class', label: 'Class', sortValue: (r) => CLASS_ORDER[r.movement_class],
    cell: (r) => `<span class="badge ${CLASS_BADGE[r.movement_class] || 'badge-neutral'}">${escapeHtml(r.movement_class)}</span>` },
  { key: 'rank', label: 'Rank', align: 'right', sortValue: (r) => r.sales_rank == null ? null : Number(r.sales_rank),
    cell: (r) => r.sales_rank == null ? '<span class="muted">-</span>' : `#${r.sales_rank}` },
  { key: 'code', label: 'Item Code', sortValue: (r) => r.item_code || '', cell: (r) => escapeHtml(r.item_code) },
  { key: 'name', label: 'Item Name', sortValue: (r) => r.item_name || '',
    cell: (r) => `${escapeHtml(r.item_name)}${r.is_active === false ? ' <span class="badge badge-neutral">Inactive</span>' : ''}` },
  { key: 'category', label: 'Category', sortValue: (r) => r.category_name || '', cell: (r) => escapeHtml(r.category_name || '') },
  { key: 'qty', label: 'Qty Sold', align: 'right', sortValue: (r) => r.qty, cell: (r) => formatQty(r.qty) },
  { key: 'perMonth', label: 'Avg / Month', align: 'right', sortValue: (r) => r.perMonth,
    cell: (r) => r.perMonth > 0 ? formatQty(Math.round(r.perMonth * 10) / 10) : '<span class="muted">0</span>' },
  { key: 'orders', label: 'Orders', align: 'right', sortValue: (r) => Number(r.order_count) || 0, cell: (r) => Number(r.order_count) || 0 },
  { key: 'revenue', label: 'Revenue', align: 'right', sortValue: (r) => Number(r.revenue) || 0, cell: (r) => formatMoney(r.revenue) },
  { key: 'lastSold', label: 'Last Sold', sortValue: (r) => r.daysSinceSold,
    cell: (r) => r.last_sold_date
      ? `${escapeHtml(r.last_sold_date)} <span class="muted">(${r.daysSinceSold}d ago)</span>`
      : '<span class="muted">Never</span>' },
  // Latest Item Ledger entry of any kind (purchase, transfer, adjustment, sale posting).
  { key: 'lastEntry', label: 'Last Movement', sortValue: (r) => r.daysSinceEntry,
    title: 'Latest Item Ledger entry (click the row for the full history)',
    cell: (r) => r.last_entry_date
      ? `${escapeHtml(r.last_entry_date)} <span class="muted">(${r.daysSinceEntry}d ago)</span><br>` +
        `<span class="muted" style="font-size:12px;">${escapeHtml(r.last_entry_type || '')}${r.last_entry_doc ? ' · ' + escapeHtml(r.last_entry_doc) : ''}</span>`
      : '<span class="muted">None</span>' },
  { key: 'onHand', label: 'On Hand', align: 'right', sortValue: (r) => r.onHand,
    cell: (r) => r.onHand < 0 ? `<span class="error-text">${formatQty(r.onHand)}</span>` : formatQty(r.onHand) },
  { key: 'cover', label: 'Days of Stock', align: 'right', sortValue: (r) => r.onHand <= 0 ? null : (r.cover ?? Infinity),
    title: 'How many days the stock on hand lasts at this period\'s sales rate',
    cell: (r) => {
      if (r.onHand <= 0) return '<span class="muted">-</span>';
      if (r.cover == null) return '<span class="badge badge-danger">No sales</span>';
      const days = Math.round(r.cover);
      const cls = days > 180 ? 'badge-danger' : days > 90 ? 'badge-warning' : days < 14 ? 'badge-primary' : '';
      return cls ? `<span class="badge ${cls}">${days.toLocaleString()}</span>` : days.toLocaleString();
    } },
  { key: 'stockValue', label: 'Stock Value (Cost)', align: 'right', costOnly: true, sortValue: (r) => r.stockValue,
    cell: (r) => r.stockValue == null ? '<span class="muted">-</span>' : formatMoney(r.stockValue) }
];

function visibleColumns() {
  return COLUMNS.filter((c) => !c.costOnly || showCost);
}

function renderHead() {
  document.getElementById('movingTableHead').innerHTML = visibleColumns()
    .map((c) => {
      const arrow = sortKey === c.key ? (sortDir === 1 ? ' ▲' : ' ▼') : '';
      const align = c.align === 'right' ? 'text-align:right;' : '';
      return `<th data-key="${c.key}" style="cursor:pointer; white-space:nowrap; ${align}" title="${escapeHtml(c.title || 'Sort')}">${c.label}${arrow}</th>`;
    })
    .join('');
}

function renderTable() {
  const rows = filteredRows();
  const cols = visibleColumns();
  const tbody = document.getElementById('movingTableBody');
  renderHead();

  document.getElementById('rowCountLabel').textContent =
    `${rows.length.toLocaleString()} item${rows.length === 1 ? '' : 's'}` +
    (rows.length > visibleCount ? ` - showing first ${visibleCount.toLocaleString()}` : '');

  if (rows.length === 0) {
    tbody.innerHTML = `<tr><td colspan="${cols.length}" class="muted">No items match these filters.</td></tr>`;
  } else {
    tbody.innerHTML = rows.slice(0, visibleCount)
      .map((r) => `<tr class="moving-row" data-code="${escapeHtml(r.item_code)}" title="Click to see recent transactions">${cols.map((c) => `<td${c.align === 'right' ? ' style="text-align:right;"' : ''}>${c.cell(r)}</td>`).join('')}</tr>`)
      .join('');
  }

  document.getElementById('showMoreBtn').classList.toggle('hidden', rows.length <= visibleCount);
}

function renderBars(containerId, rows, valueFn, labelFn, emptyText, fillClass) {
  const container = document.getElementById(containerId);
  if (rows.length === 0) {
    container.innerHTML = `<p class="muted">${emptyText}</p>`;
    return;
  }
  const max = Math.max(1, ...rows.map(valueFn));
  container.innerHTML = rows
    .map((r) => {
      const widthPct = Math.max(2, Math.round((valueFn(r) / max) * 100));
      const name = escapeHtml(r.item_name || r.item_code);
      return `
        <div class="item-rank-row" title="${name}: ${escapeHtml(labelFn(r))}">
          <div class="item-rank-label">${name}</div>
          <div class="item-rank-bar-track"><div class="item-rank-bar-fill ${fillClass || ''}" style="width:${widthPct}%;"></div></div>
          <div class="item-rank-count">${escapeHtml(labelFn(r))}</div>
        </div>`;
    })
    .join('');
}

function renderSummary() {
  const byClass = (cls) => allRows.filter((r) => r.movement_class === cls);
  const sumQty = (rows) => rows.reduce((s, r) => s + r.qty, 0);
  const totalQty = sumQty(allRows) || 1;

  const fast = byClass('Fast');
  const medium = byClass('Medium');
  const slow = byClass('Slow');
  const dead = byClass('Not Moving');
  const deadWithStock = dead.filter((r) => r.onHand > 0);

  document.getElementById('statFast').textContent = fast.length.toLocaleString();
  document.getElementById('statFastSub').textContent = `${Math.round(sumQty(fast) / totalQty * 100)}% of units sold`;
  document.getElementById('statMedium').textContent = medium.length.toLocaleString();
  document.getElementById('statMediumSub').textContent = `${Math.round(sumQty(medium) / totalQty * 100)}% of units sold`;
  document.getElementById('statSlow').textContent = slow.length.toLocaleString();
  document.getElementById('statSlowSub').textContent = `${Math.round(sumQty(slow) / totalQty * 100)}% of units sold`;
  document.getElementById('statDead').textContent = dead.length.toLocaleString();
  document.getElementById('statDeadSub').textContent = `${deadWithStock.length.toLocaleString()} still have stock on hand`;

  const tiedUpCard = document.getElementById('statTiedUpCard');
  tiedUpCard.classList.toggle('hidden', !showCost);
  if (showCost) {
    const tied = slow.concat(dead).reduce((s, r) => s + (r.stockValue || 0), 0);
    document.getElementById('statTiedUp').textContent = formatMoney(tied);
  }

  document.querySelectorAll('.topNLabel').forEach((el) => { el.textContent = topN; });
  renderBars('fastChart', fast.slice(0, topN), (r) => r.qty, (r) => `${formatQty(r.qty)} sold`,
    'No sales in this period.');

  const slowStocked = slow.concat(dead)
    .filter((r) => r.onHand > 0)
    .sort((a, b) => (showCost ? (b.stockValue || 0) - (a.stockValue || 0) : 0) || b.onHand - a.onHand)
    .slice(0, topN);
  renderBars('slowChart', slowStocked,
    (r) => showCost ? (r.stockValue || 0) : r.onHand,
    (r) => showCost && r.stockValue ? `${formatQty(r.onHand)} pcs · ${formatMoney(r.stockValue)}` : `${formatQty(r.onHand)} on hand`,
    'No slow or non-moving stock on hand.', 'moving-bar-slow');
}

function fillCategories() {
  const select = document.getElementById('categorySelect');
  const current = select.value;
  const cats = new Map();
  allRows.forEach((r) => { if (r.category_code) cats.set(r.category_code, r.category_name || r.category_code); });
  const options = [...cats.entries()].sort((a, b) => a[1].localeCompare(b[1]));
  select.innerHTML = '<option value="">All categories</option>' +
    options.map(([code, name]) => `<option value="${escapeHtml(code)}">${escapeHtml(name)}</option>`).join('');
  if (cats.has(current)) select.value = current;
}

function setClassFilter(cls) {
  classFilter = cls;
  document.querySelectorAll('#classTabs button').forEach((b) => {
    b.className = `btn btn-${b.dataset.class === cls ? 'primary' : 'secondary'} btn-sm`;
  });
  visibleCount = PAGE_SIZE;
  renderTable();
}

function exportCsv() {
  const cols = ['Class', 'Rank', 'Item Code', 'Item Name', 'Category', 'Active', 'Qty Sold', 'Avg / Month', 'Orders',
    'Revenue', 'Last Sold', 'Days Since Sold', 'Last Movement', 'Last Movement Type', 'Last Movement Doc',
    'On Hand', 'Days of Stock'];
  if (showCost) cols.push('Unit Cost', 'Stock Value (Cost)');
  const csvCell = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [cols.map(csvCell).join(',')];
  filteredRows().forEach((r) => {
    const row = [r.movement_class, r.sales_rank ?? '', r.item_code, r.item_name, r.category_name || '',
      r.is_active === false ? 'No' : 'Yes', r.qty, Math.round(r.perMonth * 10) / 10, r.order_count || 0,
      Number(r.revenue || 0).toFixed(2), r.last_sold_date || '', r.daysSinceSold ?? '',
      r.last_entry_date || '', r.last_entry_type || '', r.last_entry_doc || '', r.onHand,
      r.cover == null ? '' : Math.round(r.cover)];
    if (showCost) row.push(r.unit_cost ?? '', r.stockValue == null ? '' : r.stockValue.toFixed(2));
    lines.push(row.map(csvCell).join(','));
  });
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `moving-items-${periodDays}d-${todayManila()}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// Where a document number opens: sales orders and advance orders have their own pages; anything
// else goes to Item Ledger Entries filtered on the document number.
function documentLink(docType, docNo) {
  if (!docNo) return '';
  const enc = encodeURIComponent(docNo);
  const type = String(docType || '').replace(/ Reversal$/, '');
  let href = `item-ledger-entries.html?search=${enc}`;
  if (type === 'Sales Order') href = `online-order-lines.html?order=${enc}`;
  else if (type === 'Advance Order') href = `advance-order-lines.html?transaction=${encodeURIComponent(docNo.replace(/^ADV-/, ''))}`;
  return `<a href="${href}" target="_blank" rel="noopener">${escapeHtml(docNo)}</a>`;
}

function txTable(headers, bodyRows, emptyText) {
  if (bodyRows.length === 0) return `<p class="muted">${emptyText}</p>`;
  return `<div class="table-wrap"><table><thead><tr>${headers.map((h) =>
    `<th${h.right ? ' style="text-align:right;"' : ''}>${h.label}</th>`).join('')}</tr></thead>
    <tbody>${bodyRows.join('')}</tbody></table></div>`;
}

async function openItemTransactions(code) {
  const item = allRows.find((r) => r.item_code === code);
  const modal = document.getElementById('itemTxModal');
  const body = document.getElementById('itemTxBody');
  document.getElementById('itemTxTitle').textContent = item ? `${item.item_name} (${item.item_code})` : code;
  document.getElementById('itemTxLedgerLink').href = `item-ledger-entries.html?search=${encodeURIComponent(code)}`;
  body.innerHTML = '<p class="muted">Loading...</p>';
  modal.classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('admin_get_item_recent_transactions', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: code,
    p_limit: 20
  });
  if (error) {
    body.innerHTML = `<p class="error-text">${escapeHtml(error.message)}</p>`;
    return;
  }

  const rows = data || [];
  const sales = rows.filter((r) => r.section === 'sale');
  const ledger = rows.filter((r) => r.section === 'ledger');
  const isCancelled = (s) => /^cancel/i.test(String(s || '').trim());

  const salesHtml = txTable(
    [{ label: 'Date' }, { label: 'Order' }, { label: 'Type' }, { label: 'Customer' }, { label: 'Branch' },
      { label: 'Qty', right: true }, { label: 'Amount', right: true }, { label: 'Status' }],
    sales.map((s) => `<tr${isCancelled(s.status) ? ' class="muted" style="text-decoration:line-through;"' : ''}>
      <td style="white-space:nowrap;">${escapeHtml(s.tx_date || '')}</td>
      <td>${documentLink('Sales Order', s.document_no)}</td>
      <td>${escapeHtml(s.entry_type || '')}</td>
      <td>${escapeHtml(s.party || '')}</td>
      <td>${escapeHtml(s.warehouse_name || '')}</td>
      <td style="text-align:right;">${formatQty(s.quantity)}</td>
      <td style="text-align:right;">${formatMoney(s.amount)}</td>
      <td>${escapeHtml(s.status || '')}</td></tr>`),
    'No sales orders for this item.');

  const ledgerHtml = txTable(
    [{ label: 'Posting Date' }, { label: 'Entry Type' }, { label: 'Document' }, { label: 'Description' },
      { label: 'Warehouse' }, { label: 'Qty', right: true }, { label: 'Posted By' }],
    ledger.map((e) => {
      const qty = Number(e.quantity) || 0;
      return `<tr>
      <td style="white-space:nowrap;">${escapeHtml(e.tx_date || '')}</td>
      <td>${escapeHtml(e.entry_type || '')}${e.status ? ` <span class="badge badge-neutral">${escapeHtml(e.status)}</span>` : ''}</td>
      <td>${escapeHtml(e.document_type || '')} ${documentLink(e.document_type, e.document_no)}</td>
      <td>${escapeHtml(e.party || '')}</td>
      <td>${escapeHtml(e.warehouse_name || '')}</td>
      <td style="text-align:right;" class="${qty < 0 ? 'error-text' : ''}">${qty > 0 ? '+' : ''}${formatQty(qty)}</td>
      <td>${escapeHtml(e.posted_by || '')}</td></tr>`;
    }),
    'No Item Ledger entries for this item.');

  body.innerHTML = `
    <h3 style="margin:8px 0;">Recent Sales Orders <span class="muted" style="font-size:12px; font-weight:normal;">(latest ${sales.length})</span></h3>
    ${salesHtml}
    <h3 style="margin:18px 0 8px;">Recent Stock Movements <span class="muted" style="font-size:12px; font-weight:normal;">(Item Ledger, latest ${ledger.length})</span></h3>
    ${ledgerHtml}`;
}

function closeItemTransactions() {
  document.getElementById('itemTxModal').classList.add('hidden');
}

async function loadReport() {
  const loadingEl = document.getElementById('movingLoading');
  const errorEl = document.getElementById('movingError');
  const resultsEl = document.getElementById('movingResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  resultsEl.classList.add('hidden');

  document.querySelectorAll('#periodButtons button').forEach((b) => {
    b.className = `btn btn-${Number(b.dataset.days) === periodDays ? 'primary' : 'secondary'} btn-sm`;
  });

  const { data, error } = await supabaseClient.rpc('admin_get_slow_fast_moving_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_days: periodDays
  });

  loadingEl.classList.add('hidden');

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  allRows = enrich(data || []);
  showCost = allRows.some((r) => r.unit_cost != null);
  visibleCount = PAGE_SIZE;

  fillCategories();
  renderSummary();
  renderTable();
  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Slow & Fast Moving');

  document.querySelectorAll('#periodButtons button').forEach((b) => {
    b.addEventListener('click', () => { periodDays = Number(b.dataset.days); loadReport(); });
  });
  document.querySelectorAll('#classTabs button').forEach((b) => {
    b.addEventListener('click', () => setClassFilter(b.dataset.class));
  });
  document.querySelectorAll('.moving-stat').forEach((card) => {
    card.addEventListener('click', () => {
      setClassFilter(card.dataset.class);
      document.getElementById('classTabs').scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  });

  let searchTimer = null;
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { visibleCount = PAGE_SIZE; renderTable(); }, 200);
  });
  document.getElementById('categorySelect').addEventListener('change', () => { visibleCount = PAGE_SIZE; renderTable(); });
  document.getElementById('inStockOnly').addEventListener('change', () => { visibleCount = PAGE_SIZE; renderTable(); });
  document.getElementById('showMoreBtn').addEventListener('click', () => { visibleCount += PAGE_SIZE; renderTable(); });
  document.getElementById('exportCsvBtn').addEventListener('click', exportCsv);
  document.getElementById('movingTableBody').addEventListener('click', (e) => {
    if (e.target.closest('a')) return;
    const tr = e.target.closest('tr[data-code]');
    if (tr) openItemTransactions(tr.dataset.code);
  });
  document.getElementById('itemTxCloseBtn').addEventListener('click', closeItemTransactions);
  document.getElementById('itemTxModal').addEventListener('click', (e) => {
    if (e.target.id === 'itemTxModal') closeItemTransactions();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeItemTransactions(); });
  document.getElementById('topNSelect').addEventListener('change', (e) => {
    topN = Number(e.target.value) || 10;
    renderSummary();
  });

  document.getElementById('movingTableHead').addEventListener('click', (e) => {
    const th = e.target.closest('th[data-key]');
    if (!th) return;
    const key = th.dataset.key;
    if (sortKey === key) sortDir = -sortDir;
    else {
      sortKey = key;
      // Numbers read best biggest-first; text A-Z.
      sortDir = ['code', 'name', 'category', 'class', 'rank'].includes(key) ? 1 : -1;
    }
    renderTable();
  });

  await loadReport();
})();
