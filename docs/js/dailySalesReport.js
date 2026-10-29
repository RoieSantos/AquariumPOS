// Daily Sales report - per "Do we have a daily sales reporting?" / "yes please".
//
// admin_get_daily_sales_report (supabase_daily_sales_report.sql) returns the whole day as one jsonb
// value: orders, tenders, categories, cash counts, expenses, advance orders (placed / collected) and
// the yesterday / last-week totals.
// The branch filter and every table are built here from that, so switching branch doesn't re-query.
//
// The day is kept in the URL (?date=2026-10-29) so a report can be bookmarked or shared.
let currentSession = null;
let report = null;

function toDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function fromDateKey(key) {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(y, m - 1, d);
}

function formatMoney(value) {
  const amount = Number(value) || 0;
  return '₱' + amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatQty(value) {
  return (Number(value) || 0).toLocaleString('en-PH', { maximumFractionDigits: 2 });
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Asia/Manila "today", so Today matches the Dashboard's cards regardless of the browser's zone.
function manilaToday() {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return fromDateKey(parts);
}

function selectedDateKey() {
  return document.getElementById('reportDate').value || toDateKey(manilaToday());
}

function selectedWarehouse() {
  return document.getElementById('warehouseSelect').value;
}

function inBranch(row) {
  const wh = selectedWarehouse();
  return !wh || row.warehouse === wh;
}

// Online / walk-in / total / orders per key, for the By Branch / Tender / Staff tables.
function rollUp(rows, keyFn, amountFn, countFn) {
  const map = new Map();
  rows.forEach((r) => {
    const key = keyFn(r);
    const entry = map.get(key) || { key, online: 0, walkin: 0, count: 0 };
    entry[r.is_walkin ? 'walkin' : 'online'] += Number(amountFn(r)) || 0;
    entry.count += countFn(r);
    map.set(key, entry);
  });
  return [...map.values()].sort((a, b) => (b.online + b.walkin) - (a.online + a.walkin));
}

// linkField ('warehouse' | 'staff') makes the Online / Walk-In / Total amounts open the Receipts list
// filtered to that row (and type); the Total row filters by type only.
function splitRowsHtml(entries, emptyText, countWord, extraCell, linkField) {
  if (!entries.length) return `<tr><td colspan="${extraCell ? 6 : 5}" class="muted">${emptyText}</td></tr>`;
  const total = { online: 0, walkin: 0, count: 0 };
  const cell = (amount, type, value) => {
    if (!linkField || !amount) return `<td class="num">${formatMoney(amount)}</td>`;
    const attrs = `data-rcpt-type="${type}" data-rcpt-field="${value === null ? '' : linkField}" data-rcpt-value="${escapeHtml(value ?? '')}"`;
    return `<td class="num"><a class="ds-exp-link" ${attrs} title="Show these receipts">${formatMoney(amount)}</a></td>`;
  };
  const rows = entries.map((e) => {
    total.online += e.online;
    total.walkin += e.walkin;
    total.count += e.count;
    return `<tr><td>${escapeHtml(e.key)}</td>${cell(e.online, 'online', e.key)}${cell(e.walkin, 'walkin', e.key)}`
      + `${cell(e.online + e.walkin, '', e.key)}<td class="num">${e.count}</td>${extraCell ? extraCell(e) : ''}</tr>`;
  });
  if (entries.length > 1) {
    rows.push(`<tr class="ds-total"><td>Total</td>${cell(total.online, 'online', null)}${cell(total.walkin, 'walkin', null)}`
      + `${cell(total.online + total.walkin, '', null)}<td class="num">${countWord ? total.count : ''}</td>${extraCell ? extraCell(null) : ''}</tr>`);
  }
  return rows.join('');
}

// Receipts filter - set by clicking the Online / Walk-In / Total Sales cards or an amount in By Branch /
// By Staff. type '' | 'online' | 'walkin'; field '' | 'warehouse' | 'staff'.
let receiptFilter = { type: '', field: '', value: '' };

function openReceipts(type, field, value) {
  receiptFilter = { type: type || '', field: field || '', value: value || '' };
  render();
  document.getElementById('ordersSection').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function receiptMatches(o) {
  const f = receiptFilter;
  if (f.type && (f.type === 'walkin') !== !!o.is_walkin) return false;
  if (f.field === 'warehouse' && o.warehouse !== f.value) return false;
  if (f.field === 'staff' && (o.staff || '(Unknown)') !== f.value) return false;
  return true;
}

function compareText(label, current, past) {
  if (!past) return '';
  const pastTotal = (Number(past.online_sales) || 0) + (Number(past.walkin_sales) || 0);
  if (!pastTotal) return `${label}: ${formatMoney(0)}`;
  const pct = ((current - pastTotal) / pastTotal) * 100;
  const sign = pct >= 0 ? '+' : '';
  return `${label}: ${formatMoney(pastTotal)} (${sign}${pct.toFixed(0)}%)`;
}

function render() {
  if (!report) return;
  const wh = selectedWarehouse();
  const orders = (report.orders || []).filter(inBranch);
  const online = orders.filter((o) => !o.is_walkin);
  const walkin = orders.filter((o) => o.is_walkin);
  const sum = (rows) => rows.reduce((s, o) => s + (Number(o.total) || 0), 0);
  const onlineTotal = sum(online);
  const walkinTotal = sum(walkin);
  const expenses = (report.expenses || []).filter(inBranch);
  const expenseTotal = expenses.reduce((s, e) => s + (Number(e.amount) || 0), 0);
  const expenseCount = expenses.reduce((s, e) => s + (Number(e.count) || 0), 0);

  document.getElementById('statTotal').textContent = formatMoney(onlineTotal + walkinTotal);
  document.getElementById('statTotalSub').textContent = plural(orders.length, 'order');
  document.getElementById('statOnline').textContent = formatMoney(onlineTotal);
  document.getElementById('statOnlineSub').textContent = plural(online.length, 'order');
  document.getElementById('statWalkin').textContent = formatMoney(walkinTotal);
  document.getElementById('statWalkinSub').textContent = plural(walkin.length, 'receipt');
  document.getElementById('statExpense').textContent = formatMoney(expenseTotal);
  document.getElementById('statExpenseSub').textContent = `${expenseCount} ${expenseCount === 1 ? 'entry' : 'entries'} ·Sales less expenses ${formatMoney(onlineTotal + walkinTotal - expenseTotal)}`;

  // The compare totals are all branches, so only show them when no branch is picked.
  const compareEl = document.getElementById('compareNote');
  if (wh) {
    compareEl.textContent = '';
  } else {
    const current = onlineTotal + walkinTotal;
    compareEl.textContent = [
      compareText('Yesterday', current, report.compare?.yesterday),
      compareText('Same day last week', current, report.compare?.last_week)
    ].filter(Boolean).join(' · ');
  }

  // By Branch (always every branch, with expenses alongside).
  const branchEntries = rollUp(orders, (o) => o.warehouse, (o) => o.total, () => 1);
  expenses.forEach((e) => {
    if (!branchEntries.some((b) => b.key === e.warehouse)) branchEntries.push({ key: e.warehouse, online: 0, walkin: 0, count: 0 });
  });
  const expenseByWh = new Map(expenses.map((e) => [e.warehouse, Number(e.amount) || 0]));
  document.getElementById('branchBody').innerHTML = splitRowsHtml(branchEntries, 'No sales this day.', true, (e) => {
    const amount = e ? (expenseByWh.get(e.key) || 0) : expenseTotal;
    return amount
      ? `<td class="num"><a class="ds-exp-link" data-exp-branch="${escapeHtml(e ? e.key : '')}" title="Show these expenses">${formatMoney(amount)}</a></td>`
      : `<td class="num">${formatMoney(0)}</td>`;
  }, 'warehouse');
  renderExpenseLines();

  const tenders = (report.tenders || []).filter(inBranch);
  document.getElementById('tenderBody').innerHTML = splitRowsHtml(
    rollUp(tenders, (t) => t.method, (t) => t.amount, (t) => Number(t.order_count) || 0),
    'No payments this day.', false);

  document.getElementById('staffBody').innerHTML = splitRowsHtml(
    rollUp(orders, (o) => o.staff || '(Unknown)', (o) => o.total, () => 1),
    'No sales this day.', true, null, 'staff');

  const catMap = new Map();
  (report.categories || []).filter(inBranch).forEach((c) => {
    const entry = catMap.get(c.category) || { name: c.category, qty: 0, revenue: 0 };
    entry.qty += Number(c.qty) || 0;
    entry.revenue += Number(c.revenue) || 0;
    catMap.set(c.category, entry);
  });
  const cats = [...catMap.values()].sort((a, b) => b.revenue - a.revenue);
  const catTotal = cats.reduce((s, c) => s + c.revenue, 0);
  document.getElementById('categoryBody').innerHTML = cats.length
    ? cats.map((c) => `<tr><td>${escapeHtml(c.name)}</td><td class="num">${formatQty(c.qty)}</td><td class="num">${formatMoney(c.revenue)}</td>`
        + `<td class="num">${catTotal ? ((c.revenue / catTotal) * 100).toFixed(1) : '0.0'}%</td></tr>`).join('')
      + `<tr class="ds-total"><td>Total</td><td class="num">${formatQty(cats.reduce((s, c) => s + c.qty, 0))}</td><td class="num">${formatMoney(catTotal)}</td><td class="num">100%</td></tr>`
    : '<tr><td colspan="4" class="muted">No items sold this day.</td></tr>';

  renderAdvance(onlineTotal + walkinTotal, orders);

  const cash = (report.cash || []).filter(inBranch);
  document.getElementById('cashBody').innerHTML = cash.length
    ? cash.map((c) => {
        const v = Number(c.variance) || 0;
        const cls = v < 0 ? 'ds-short' : (v > 0 ? 'ds-over' : '');
        const label = v < 0 ? `Short ${formatMoney(-v)}` : (v > 0 ? `Over ${formatMoney(v)}` : formatMoney(0));
        return `<tr><td>${escapeHtml(c.warehouse)}</td><td>${escapeHtml(c.user_id)}</td><td>${escapeHtml(c.time)}</td>`
          + `<td class="num">${formatMoney(c.float)}</td><td class="num">${formatMoney(c.cash_sales)}</td><td class="num">${formatMoney(c.expected)}</td>`
          + `<td class="num">${formatMoney(c.declared)}</td><td class="num ${cls}">${label}</td><td>${escapeHtml(c.reason)}</td></tr>`;
      }).join('')
    : '<tr><td colspan="9" class="muted">No cash count posted from the POS for this day yet.</td></tr>';

  const shown = orders.filter(receiptMatches);
  const f = receiptFilter;
  const filterLabel = [f.type === 'online' ? 'Online' : (f.type === 'walkin' ? 'Walk-In' : ''), f.field ? f.value : '']
    .filter(Boolean).join(' · ');
  document.getElementById('ordersTitle').textContent =
    `Receipts${filterLabel ? ' - ' + filterLabel : ''} (${shown.length} · ${formatMoney(sum(shown))})`;
  document.getElementById('ordersAllBtn').classList.toggle('hidden', !filterLabel);
  document.getElementById('ordersBody').innerHTML = shown.length
    ? shown.map((o) => `<tr><td>${o.is_walkin ? 'Walk-in' : (o.for_delivery ? 'Online · Delivery' : 'Online')}${o.advance_copy ? ' · Advance' : ''}</td>`
        + `<td>${escapeHtml(o.receipt_no || o.order_id)}</td><td>${escapeHtml(orderTime(o))}</td><td>${escapeHtml(o.warehouse)}</td>`
        + `<td>${escapeHtml(o.customer)}</td><td>${escapeHtml(o.staff)}</td><td>${escapeHtml(o.status)}</td><td>${escapeHtml(o.payments || '')}</td>`
        + `<td class="num">${formatMoney(o.total)}</td><td class="num">${Number(o.balance) ? formatMoney(o.balance) : ''}</td></tr>`).join('')
    : `<tr><td colspan="10" class="muted">${filterLabel ? 'No receipts match this filter.' : 'No sales this day.'}</td></tr>`;
}

// Expenses drill-down - opened from the Expenses card (current branch filter) or a branch's expense
// amount in By Branch (just that branch). null = closed.
let expenseBranch = null;

function openExpenses(branch) {
  expenseBranch = branch || '';
  renderExpenseLines();
  document.getElementById('expenseSection').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function renderExpenseLines() {
  const section = document.getElementById('expenseSection');
  if (expenseBranch === null || !report) {
    section.classList.add('hidden');
    return;
  }
  section.classList.remove('hidden');
  const wh = expenseBranch || selectedWarehouse();
  const lines = (report.expense_lines || []).filter((x) => !wh || x.warehouse === wh);
  const total = lines.reduce((s, x) => s + (Number(x.amount) || 0), 0);
  document.getElementById('expenseTitle').textContent = `Expenses${wh ? ' - ' + wh : ''} (${formatMoney(total)})`;
  document.getElementById('expenseAllBtn').classList.toggle('hidden', !expenseBranch || !!selectedWarehouse());
  document.getElementById('expenseBody').innerHTML = lines.length
    ? lines.map((x) => `<tr><td>${escapeHtml(x.source)}</td>`
        + `<td>${x.ref ? `<a href="expense-entry-lines.html?receipt=${encodeURIComponent(x.ref)}">${escapeHtml(x.ref)}</a>` : ''}</td>`
        + `<td>${escapeHtml(x.entry_time)}</td><td>${escapeHtml(x.warehouse)}</td><td>${escapeHtml(x.category)}</td>`
        + `<td>${escapeHtml(x.description)}</td><td>${escapeHtml(x.staff)}</td><td class="num">${formatMoney(x.amount)}</td></tr>`).join('')
      + (lines.length > 1 ? `<tr class="ds-total"><td colspan="7">Total</td><td class="num">${formatMoney(total)}</td></tr>` : '')
    : `<tr><td colspan="8" class="muted">${report.expense_lines ? 'No expenses this day.' : 'Re-run supabase_daily_sales_report.sql to see the expense details.'}</td></tr>`;
}

// Advance orders live in their own table, so they're kept apart from the sales above (like the
// Dashboard's advance card): Placed = new orders this day, Collected = money taken this day on any
// advance order. Old Pancake copies of advance orders (in the sales above) are flagged so the
// "Sales + Advance Collected" figure isn't read as clean when they overlap.
function renderAdvance(salesTotal, orders) {
  const placed = (report.advance_placed || []).filter(inBranch);
  const collected = (report.advance_collected || []).filter(inBranch);
  const placedTotal = placed.reduce((s, a) => s + (Number(a.net) || 0), 0);
  const placedDown = placed.reduce((s, a) => s + (Number(a.downpayment) || 0), 0);
  const placedBal = placed.reduce((s, a) => s + (Number(a.balance) || 0), 0);
  const collectedTotal = collected.reduce((s, c) => s + (Number(c.amount) || 0), 0);
  const collectedCount = collected.reduce((s, c) => s + (Number(c.payment_count) || 0), 0);

  document.getElementById('statAdvPlaced').textContent = formatMoney(placedTotal);
  document.getElementById('statAdvPlacedSub').textContent =
    `${plural(placed.length, 'order')} · ${formatMoney(placedDown)} downpayment · ${formatMoney(placedBal)} balance`;
  document.getElementById('statAdvCollected').textContent = formatMoney(collectedTotal);
  document.getElementById('statAdvCollectedSub').textContent = plural(collectedCount, 'payment');
  // Rows that are really an advance order (POS Pay In Full receipt / old Pancake copy) would count
  // the same money twice, so they're left out of the combined figure.
  const copies = orders.filter((o) => o.advance_copy);
  const copiesTotal = copies.reduce((s, o) => s + (Number(o.total) || 0), 0);
  document.getElementById('statAllIn').textContent = formatMoney(salesTotal - copiesTotal + collectedTotal);
  document.getElementById('advCopyNote').textContent = copies.length
    ? `${plural(copies.length, 'sale')} (${formatMoney(copiesTotal)}) in the sales above ${copies.length === 1 ? 'is an advance order' : 'are advance orders'} (marked "Advance" in Receipts) - the POS records a fully paid advance order as a walk-in receipt too. ${copies.length === 1 ? 'It is' : 'They are'} left out of Sales + Advance Collected, since that money is already under Advance Collected.`
    : '';

  document.getElementById('advTenderBody').innerHTML = collected.length
    ? collected.map((c) => `<tr><td>${escapeHtml(c.tender)}</td><td>${escapeHtml(c.warehouse)}</td>`
        + `<td class="num">${Number(c.payment_count) || 0}</td><td class="num">${formatMoney(c.amount)}</td></tr>`).join('')
      + (collected.length > 1
        ? `<tr class="ds-total"><td>Total</td><td></td><td class="num">${collectedCount}</td><td class="num">${formatMoney(collectedTotal)}</td></tr>`
        : '')
    : '<tr><td colspan="4" class="muted">No advance-order payments this day.</td></tr>';

  document.getElementById('advPlacedBody').innerHTML = placed.length
    ? placed.map((a) => `<tr><td>${escapeHtml(a.receipt_no || a.transaction_no)}</td><td>${escapeHtml(a.time)}</td><td>${escapeHtml(a.warehouse)}</td>`
        + `<td>${escapeHtml(a.customer)}</td><td>${escapeHtml(a.description)}</td><td>${escapeHtml(a.staff)}</td>`
        + `<td class="num">${formatMoney(a.net)}</td><td class="num">${formatMoney(a.downpayment)}</td><td class="num">${Number(a.balance) ? formatMoney(a.balance) : ''}</td></tr>`).join('')
    : '<tr><td colspan="9" class="muted">No advance orders placed this day.</td></tr>';
}

// Online orders show when they were confirmed (that's what puts them on this day); walk-ins their sale time.
function orderTime(o) {
  if (!o.is_walkin && o.confirmed_at) {
    return new Date(o.confirmed_at).toLocaleTimeString('en-US', { timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit' });
  }
  return o.time || '';
}

function fillWarehouseSelect() {
  const select = document.getElementById('warehouseSelect');
  const current = select.value || new URL(window.location.href).searchParams.get('branch') || '';
  const names = new Set();
  ['orders', 'expenses', 'cash', 'advance_placed', 'advance_collected'].forEach((k) => (report[k] || []).forEach((r) => r.warehouse && names.add(r.warehouse)));
  if (current) names.add(current);
  select.innerHTML = '<option value="">All branches</option>' + [...names].sort()
    .map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');
  select.value = current;
}

function syncUrl() {
  const url = new URL(window.location.href);
  url.searchParams.set('date', selectedDateKey());
  if (selectedWarehouse()) url.searchParams.set('branch', selectedWarehouse());
  else url.searchParams.delete('branch');
  window.history.replaceState(null, '', url);
}

async function loadReport() {
  const loadingEl = document.getElementById('dsLoading');
  const errorEl = document.getElementById('dsError');
  const resultsEl = document.getElementById('dsResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const key = selectedDateKey();
  document.getElementById('dateLabel').textContent = fromDateKey(key)
    .toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
  document.getElementById('nextDayBtn').disabled = key >= toDateKey(manilaToday());
  syncUrl();

  const { data, error } = await supabaseClient.rpc('admin_get_daily_sales_report', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_date: key
  });

  loadingEl.classList.add('hidden');
  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }

  report = data || {};
  fillWarehouseSelect();
  render();
  resultsEl.classList.remove('hidden');
}

function setDate(date) {
  document.getElementById('reportDate').value = toDateKey(date);
  loadReport();
}

function shiftDay(days) {
  const d = fromDateKey(selectedDateKey());
  d.setDate(d.getDate() + days);
  setDate(d);
}

function csvCell(value) {
  const text = typeof value === 'number' ? value.toFixed(2) : String(value ?? '');
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function exportCsv() {
  if (!report) return;
  const orders = (report.orders || []).filter(inBranch).filter(receiptMatches);
  const header =['Type', 'Order / Receipt', 'Time', 'Branch', 'Customer', 'Staff', 'Status', 'Paid Via', 'Discount', 'Total', 'Paid', 'Balance'];
  const lines = [
    csvCell(`Daily Sales - ${selectedDateKey()}`),
    csvCell(`Branch: ${selectedWarehouse() || 'All branches'}`),
    '',
    header.map(csvCell).join(','),
    ...orders.map((o) => [
      (o.is_walkin ? 'Walk-in' : 'Online') + (o.advance_copy ? ' (Advance)' : ''), o.receipt_no || o.order_id, orderTime(o), o.warehouse, o.customer, o.staff,
      o.status, o.payments || '', Number(o.discount) || 0, Number(o.total) || 0, Number(o.paid) || 0, Number(o.balance) || 0
    ].map(csvCell).join(','))
  ];

  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `daily-sales-${selectedDateKey()}${selectedWarehouse() ? '-' + selectedWarehouse().replace(/\s+/g, '-') : ''}.csv`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Daily Sales Report');

  if (!session.isSuperUser) {
    document.getElementById('dsLoading').classList.add('hidden');
    const errorEl = document.getElementById('dsError');
    errorEl.textContent = 'Only a Super User can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  const fromUrl = new URL(window.location.href).searchParams.get('date');
  const dateInput = document.getElementById('reportDate');
  dateInput.max = toDateKey(manilaToday());
  dateInput.value = /^\d{4}-\d{2}-\d{2}$/.test(fromUrl || '') ? fromUrl : toDateKey(manilaToday());

  dateInput.addEventListener('change', loadReport);
  document.getElementById('prevDayBtn').addEventListener('click', () => shiftDay(-1));
  document.getElementById('nextDayBtn').addEventListener('click', () => shiftDay(1));
  document.getElementById('todayBtn').addEventListener('click', () => setDate(manilaToday()));
  document.getElementById('yesterdayBtn').addEventListener('click', () => {
    const d = manilaToday();
    d.setDate(d.getDate() - 1);
    setDate(d);
  });
  document.getElementById('warehouseSelect').addEventListener('change', () => { syncUrl(); render(); });
  document.getElementById('exportBtn').addEventListener('click', exportCsv);
  const expenseCard = document.getElementById('expenseCard');
  expenseCard.addEventListener('click', () => openExpenses(''));
  expenseCard.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openExpenses(''); }
  });
  document.getElementById('branchBody').addEventListener('click', (e) => {
    const link = e.target.closest('[data-exp-branch]');
    if (link) openExpenses(link.dataset.expBranch);
  });
  document.getElementById('expenseAllBtn').addEventListener('click', () => openExpenses(''));
  [['totalCard', ''], ['onlineCard', 'online'], ['walkinCard', 'walkin']].forEach(([id, type]) => {
    const card = document.getElementById(id);
    card.addEventListener('click', () => openReceipts(type));
    card.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openReceipts(type); }
    });
  });
  // By Branch / By Staff amounts (rendered by splitRowsHtml with data-rcpt-*).
  document.getElementById('dsResults').addEventListener('click', (e) => {
    const link = e.target.closest('[data-rcpt-type]');
    if (link) openReceipts(link.dataset.rcptType, link.dataset.rcptField, link.dataset.rcptValue);
  });
  document.getElementById('ordersAllBtn').addEventListener('click', () => openReceipts(''));
  document.getElementById('expenseCloseBtn').addEventListener('click', () => {
    expenseBranch = null;
    renderExpenseLines();
  });
  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadReport();
})();
