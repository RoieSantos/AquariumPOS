// Monthly Sales report - per "can we build monthly sales report then i want to filter it out by the month
// and by warehouse".
//
// admin_get_monthly_sales_report (supabase_monthly_sales_report.sql) returns the whole month as one jsonb
// value, already summed per branch (and per day): days, tenders, staff, categories, expenses, cash counts,
// advance orders, and the previous-month / last-year totals per branch.
// The branch filter and every table are built here from that, so switching branch doesn't re-query.
// Same rules as the Daily Sales Report; a day's row links to that day's report for the receipts.
//
// Month and branch are kept in the URL (?month=2026-11&branch=...) so a report can be bookmarked or shared.
let currentSession = null;
let report = null;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

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

// 'YYYY-MM-DD' -> 'Nov 3' / 'Nov 3, 2026'
function shortDate(key, withYear) {
  const [y, m, d] = String(key).split('-').map(Number);
  return `${MONTHS[m - 1]} ${d}${withYear ? ', ' + y : ''}`;
}

function weekday(key) {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString('en-US', { weekday: 'short' });
}

// Asia/Manila "this month" as 'YYYY-MM'.
function manilaMonthKey() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit' })
    .format(new Date()).slice(0, 7);
}

function shiftMonthKey(key, months) {
  const [y, m] = key.split('-').map(Number);
  const d = new Date(y, m - 1 + months, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function selectedMonthKey() {
  return document.getElementById('msMonth').value || manilaMonthKey();
}

function selectedWarehouse() {
  return document.getElementById('warehouseSelect').value;
}

function inBranch(row) {
  const wh = selectedWarehouse();
  return !wh || row.warehouse === wh;
}

function sumOf(rows, field) {
  return rows.reduce((s, r) => s + (Number(r[field]) || 0), 0);
}

// Online / walk-in / total / count per key, for the By Branch / Tender / Staff tables.
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

function splitRowsHtml(entries, emptyText, showCount, extraCell) {
  const cols = 5 + (extraCell ? extraCell.cols : 0);
  if (!entries.length) return `<tr><td colspan="${cols}" class="muted">${emptyText}</td></tr>`;
  const total = { online: 0, walkin: 0, count: 0 };
  const rows = entries.map((e) => {
    total.online += e.online;
    total.walkin += e.walkin;
    total.count += e.count;
    return `<tr><td>${escapeHtml(e.key)}</td><td class="num">${formatMoney(e.online)}</td><td class="num">${formatMoney(e.walkin)}</td>`
      + `<td class="num">${formatMoney(e.online + e.walkin)}</td><td class="num">${e.count}</td>${extraCell ? extraCell.html(e) : ''}</tr>`;
  });
  if (entries.length > 1) {
    rows.push(`<tr class="ms-total"><td>Total</td><td class="num">${formatMoney(total.online)}</td><td class="num">${formatMoney(total.walkin)}</td>`
      + `<td class="num">${formatMoney(total.online + total.walkin)}</td><td class="num">${showCount ? total.count : ''}</td>${extraCell ? extraCell.html(null) : ''}</tr>`);
  }
  return rows.join('');
}

function pctChange(current, past) {
  if (!past) return null;
  return ((current - past) / past) * 100;
}

function pctHtml(pct) {
  if (pct === null) return '<span class="muted">-</span>';
  const cls = pct >= 0 ? 'ms-up' : 'ms-down';
  return `<span class="${cls}">${pct >= 0 ? '+' : ''}${pct.toFixed(0)}%</span>`;
}

function compareTotal(rows) {
  return (rows || []).filter(inBranch).reduce((s, r) => s + (Number(r.online_sales) || 0) + (Number(r.walkin_sales) || 0), 0);
}

function compareText(label, from, to, current, rows) {
  const past = compareTotal(rows);
  const range = `${shortDate(from)}-${shortDate(to).split(' ')[1]}, ${from.slice(0, 4)}`;
  if (!past) return `${label} (${range}): ${formatMoney(0)}`;
  const pct = pctChange(current, past);
  return `${label} (${range}): ${formatMoney(past)} (${pct >= 0 ? '+' : ''}${pct.toFixed(0)}%)`;
}

function render() {
  if (!report) return;
  const wh = selectedWarehouse();
  const days = (report.days || []).filter(inBranch);
  const online = days.filter((d) => !d.is_walkin);
  const walkin = days.filter((d) => d.is_walkin);
  const onlineTotal = sumOf(online, 'amount');
  const walkinTotal = sumOf(walkin, 'amount');
  const salesTotal = onlineTotal + walkinTotal;
  const orderCount = sumOf(days, 'count');
  const expenses = (report.expenses || []).filter(inBranch);
  const expenseTotal = sumOf(expenses, 'amount');
  const expenseCount = sumOf(expenses, 'count');
  const advCollected = (report.advance_collected || []).filter(inBranch);

  // Days elapsed (current month runs to today) for the per-day average.
  const dayKeys = [];
  const [y, m] = report.month.split('-').map(Number);
  const lastDay = Number(String(report.through).split('-')[2]);
  if (report.through >= report.month) {
    for (let d = 1; d <= lastDay; d += 1) dayKeys.push(`${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`);
  }
  const avg = dayKeys.length ? salesTotal / dayKeys.length : 0;

  document.getElementById('statTotal').textContent = formatMoney(salesTotal);
  document.getElementById('statTotalSub').textContent = `${plural(orderCount, 'order')} · avg ${formatMoney(avg)} / day`;
  document.getElementById('statOnline').textContent = formatMoney(onlineTotal);
  document.getElementById('statOnlineSub').textContent = plural(sumOf(online, 'count'), 'order');
  document.getElementById('statWalkin').textContent = formatMoney(walkinTotal);
  document.getElementById('statWalkinSub').textContent = plural(sumOf(walkin, 'count'), 'receipt');
  document.getElementById('statExpense').textContent = formatMoney(expenseTotal);
  document.getElementById('statExpenseSub').textContent =
    `${expenseCount} ${expenseCount === 1 ? 'entry' : 'entries'} · Sales less expenses ${formatMoney(salesTotal - expenseTotal)}`;

  const c = report.compare || {};
  document.getElementById('compareNote').textContent = [
    c.prev_from ? compareText('Previous month', c.prev_from, c.prev_to, salesTotal, c.prev) : '',
    c.ly_from ? compareText('Same month last year', c.ly_from, c.ly_to, salesTotal, c.last_year) : ''
  ].filter(Boolean).join(' · ') + (wh ? ` - ${wh} only` : '');

  renderDays(dayKeys, days, expenses, advCollected);

  // By Branch (always every branch with sales or expenses, with expenses and the previous-month change).
  const branchEntries = rollUp(days, (d) => d.warehouse, (d) => d.amount, (d) => Number(d.count) || 0);
  const expenseByWh = new Map();
  expenses.forEach((e) => expenseByWh.set(e.warehouse, (expenseByWh.get(e.warehouse) || 0) + (Number(e.amount) || 0)));
  expenseByWh.forEach((_, key) => {
    if (!branchEntries.some((b) => b.key === key)) branchEntries.push({ key, online: 0, walkin: 0, count: 0 });
  });
  const prevByWh = new Map((c.prev || []).map((r) => [r.warehouse, (Number(r.online_sales) || 0) + (Number(r.walkin_sales) || 0)]));
  const prevAll = compareTotal(c.prev);
  document.getElementById('branchBody').innerHTML = splitRowsHtml(branchEntries, 'No sales this month.', true, {
    cols: 2,
    html: (e) => {
      const exp = e ? (expenseByWh.get(e.key) || 0) : expenseTotal;
      const pct = e ? pctChange(e.online + e.walkin, prevByWh.get(e.key) || 0) : pctChange(salesTotal, prevAll);
      return `<td class="num">${formatMoney(exp)}</td><td class="num">${pctHtml(pct)}</td>`;
    }
  });

  document.getElementById('tenderBody').innerHTML = splitRowsHtml(
    rollUp((report.tenders || []).filter(inBranch), (t) => t.method, (t) => t.amount, (t) => Number(t.order_count) || 0),
    'No payments this month.', false);

  document.getElementById('staffBody').innerHTML = splitRowsHtml(
    rollUp((report.staff || []).filter(inBranch), (s) => s.staff || '(Unknown)', (s) => s.amount, (s) => Number(s.count) || 0),
    'No sales this month.', true);

  renderCategories();
  renderExpenseCategories();
  renderAdvance(salesTotal, days, advCollected);
  renderCash();
  renderMatrix(dayKeys);
}

// ---------------------------------------------------------------------------
// Matrix view ("Branches side by side"): Day by Day, By Tender, By Staff and By Category turn into
// rows x one column per branch + a Total column, with a Total row. Only with All branches picked.
const MATRIX_TABLES = ['dayBody', 'tenderBody', 'staffBody', 'categoryBody'];
const defaultHeads = {};

function headOf(bodyId) {
  return document.getElementById(bodyId).closest('table').querySelector('thead');
}

function matrixOn() {
  return document.getElementById('matrixToggle').checked && !selectedWarehouse();
}

// Branch columns: every branch with sales or expenses this month, biggest sales first.
function branchColumns() {
  const totals = new Map();
  (report.days || []).forEach((d) => totals.set(d.warehouse, (totals.get(d.warehouse) || 0) + (Number(d.amount) || 0)));
  (report.expenses || []).forEach((e) => { if (!totals.has(e.warehouse)) totals.set(e.warehouse, 0); });
  return [...totals.entries()].sort((a, b) => b[1] - a[1]).map(([k]) => k);
}

// rows: [{ key, label (html) }]; value(rowKey, branch) -> number; link(rowKey, branch|null) -> href or ''.
// sortByTotal puts the biggest row first (days keep their order).
function matrixHtml(bodyId, firstHeader, rows, branches, value, opts = {}) {
  const fmt = opts.fmt || formatMoney;
  headOf(bodyId).innerHTML = `<tr><th>${escapeHtml(firstHeader)}</th>`
    + branches.map((b) => `<th class="num">${escapeHtml(b)}</th>`).join('')
    + '<th class="num ms-rowtotal">Total</th></tr>';
  const table = document.getElementById(bodyId).closest('table');
  table.classList.add('ms-matrix');

  let data = rows.map((r) => {
    const cells = branches.map((b) => Number(value(r.key, b)) || 0);
    return { ...r, cells, total: cells.reduce((s, n) => s + n, 0) };
  });
  if (opts.sortByTotal) data = data.sort((a, b) => b.total - a.total);
  if (!data.length) {
    document.getElementById(bodyId).innerHTML = `<tr><td colspan="${branches.length + 2}" class="muted">${opts.emptyText || 'Nothing this month.'}</td></tr>`;
    return;
  }
  const cell = (n, href, extraClass) => {
    const text = n ? fmt(n) : '<span class="muted">-</span>';
    return `<td class="num${extraClass ? ' ' + extraClass : ''}">${href && n ? `<a href="${href}">${text}</a>` : text}</td>`;
  };
  const colTotals = branches.map((_, i) => data.reduce((s, r) => s + r.cells[i], 0));
  const grand = colTotals.reduce((s, n) => s + n, 0);
  document.getElementById(bodyId).innerHTML = data.map((r) => {
    const empty = !r.total && r.cells.every((n) => !n);
    return `<tr${empty ? ' class="ms-zero"' : ''}><td>${r.label}</td>`
      + r.cells.map((n, i) => cell(n, opts.link ? opts.link(r.key, branches[i]) : '')).join('')
      + cell(r.total, opts.link ? opts.link(r.key, null) : '', 'ms-rowtotal') + '</tr>';
  }).join('')
    + `<tr class="ms-total"><td>Total</td>${colTotals.map((n) => cell(n, '')).join('')}${cell(grand, '', 'ms-rowtotal')}</tr>`;
}

function renderMatrix(dayKeys) {
  const on = matrixOn();
  document.getElementById('matrixMetric').classList.toggle('hidden', !on);
  const note = document.getElementById('matrixNote');
  note.classList.toggle('hidden', !(document.getElementById('matrixToggle').checked && selectedWarehouse()));
  note.textContent = 'Branches side by side needs "All branches" - showing the list for this branch.';
  if (!on) {
    MATRIX_TABLES.forEach((id) => {
      headOf(id).innerHTML = defaultHeads[id];
      document.getElementById(id).closest('table').classList.remove('ms-matrix');
    });
    return;
  }
  const branches = branchColumns();
  const metric = document.getElementById('matrixMetric').value;

  // Day by Day: day x branch for the picked figure.
  const cellMap = new Map();
  const at = (day, wh) => {
    const k = `${day}|${wh}`;
    if (!cellMap.has(k)) cellMap.set(k, { online: 0, walkin: 0, count: 0, expense: 0 });
    return cellMap.get(k);
  };
  (report.days || []).forEach((d) => {
    const e = at(d.date, d.warehouse);
    e[d.is_walkin ? 'walkin' : 'online'] += Number(d.amount) || 0;
    e.count += Number(d.count) || 0;
  });
  (report.expenses || []).forEach((x) => { at(x.date, x.warehouse).expense += Number(x.amount) || 0; });
  const dayValue = (day, wh) => {
    const e = cellMap.get(`${day}|${wh}`);
    if (!e) return 0;
    switch (metric) {
      case 'online': return e.online;
      case 'walkin': return e.walkin;
      case 'count': return e.count;
      case 'expense': return e.expense;
      case 'net': return e.online + e.walkin - e.expense;
      default: return e.online + e.walkin;
    }
  };
  const allDays = [...new Set([...dayKeys, ...[...cellMap.keys()].map((k) => k.split('|')[0])])].sort();
  matrixHtml('dayBody', 'Date', allDays.map((k) => ({
    key: k,
    label: `<a href="daily-sales-report.html?date=${k}" title="Open this day's Daily Sales Report">${escapeHtml(weekday(k))} ${escapeHtml(shortDate(k))}</a>`
  })), branches, dayValue, {
    fmt: metric === 'count' ? (n) => String(n) : formatMoney,
    link: (day, wh) => `daily-sales-report.html?date=${day}${wh ? '&branch=' + encodeURIComponent(wh) : ''}`,
    emptyText: 'This month hasn\'t started yet.'
  });

  // Tender / Staff / Category: summed per row key + branch (online and walk-in together).
  const pivot = (rows, keyFn, amountField) => {
    const m = new Map();
    rows.forEach((r) => {
      const k = `${keyFn(r)}|${r.warehouse}`;
      m.set(k, (m.get(k) || 0) + (Number(r[amountField]) || 0));
    });
    const keys = [...new Set(rows.map(keyFn))];
    return { rows: keys.map((k) => ({ key: k, label: escapeHtml(k) })), value: (k, wh) => m.get(`${k}|${wh}`) || 0 };
  };
  const t = pivot(report.tenders || [], (r) => r.method, 'amount');
  matrixHtml('tenderBody', 'Tender', t.rows, branches, t.value, { sortByTotal: true, emptyText: 'No payments this month.' });
  const s = pivot(report.staff || [], (r) => r.staff || '(Unknown)', 'amount');
  matrixHtml('staffBody', 'Staff', s.rows, branches, s.value, { sortByTotal: true, emptyText: 'No sales this month.' });
  const c = pivot(report.categories || [], (r) => r.category, 'revenue');
  matrixHtml('categoryBody', 'Category (revenue)', c.rows, branches, c.value, { sortByTotal: true, emptyText: 'No items sold this month.' });
}

function renderDays(dayKeys, days, expenses, advCollected) {
  const wh = selectedWarehouse();
  const byDay = new Map(dayKeys.map((k) => [k, { online: 0, walkin: 0, count: 0, expense: 0, adv: 0 }]));
  const at = (k) => {
    if (!byDay.has(k)) byDay.set(k, { online: 0, walkin: 0, count: 0, expense: 0, adv: 0 });
    return byDay.get(k);
  };
  days.forEach((d) => {
    const e = at(d.date);
    e[d.is_walkin ? 'walkin' : 'online'] += Number(d.amount) || 0;
    e.count += Number(d.count) || 0;
  });
  expenses.forEach((x) => { at(x.date).expense += Number(x.amount) || 0; });
  advCollected.forEach((x) => { at(x.date).adv += Number(x.amount) || 0; });

  const keys = [...byDay.keys()].sort();
  const t = { online: 0, walkin: 0, count: 0, expense: 0, adv: 0 };
  const rows = keys.map((k) => {
    const e = byDay.get(k);
    Object.keys(t).forEach((f) => { t[f] += e[f]; });
    const total = e.online + e.walkin;
    const href = `daily-sales-report.html?date=${k}${wh ? '&branch=' + encodeURIComponent(wh) : ''}`;
    const empty = !total && !e.expense && !e.adv;
    return `<tr${empty ? ' class="ms-zero"' : ''}><td><a href="${href}" title="Open this day's Daily Sales Report">${escapeHtml(weekday(k))} ${escapeHtml(shortDate(k))}</a></td>`
      + `<td class="num">${formatMoney(e.online)}</td><td class="num">${formatMoney(e.walkin)}</td><td class="num">${formatMoney(total)}</td>`
      + `<td class="num">${e.count}</td><td class="num">${formatMoney(e.expense)}</td><td class="num">${formatMoney(total - e.expense)}</td>`
      + `<td class="num">${e.adv ? formatMoney(e.adv) : ''}</td></tr>`;
  });
  if (!rows.length) {
    document.getElementById('dayBody').innerHTML = '<tr><td colspan="8" class="muted">This month hasn\'t started yet.</td></tr>';
    return;
  }
  rows.push(`<tr class="ms-total"><td>Total</td><td class="num">${formatMoney(t.online)}</td><td class="num">${formatMoney(t.walkin)}</td>`
    + `<td class="num">${formatMoney(t.online + t.walkin)}</td><td class="num">${t.count}</td><td class="num">${formatMoney(t.expense)}</td>`
    + `<td class="num">${formatMoney(t.online + t.walkin - t.expense)}</td><td class="num">${formatMoney(t.adv)}</td></tr>`);
  document.getElementById('dayBody').innerHTML = rows.join('');
}

function shareTable(bodyId, rows, countLabel, emptyText) {
  const total = rows.reduce((s, r) => s + r.amount, 0);
  document.getElementById(bodyId).innerHTML = rows.length
    ? rows.map((r) => `<tr><td>${escapeHtml(r.name)}</td><td class="num">${countLabel(r.count)}</td><td class="num">${formatMoney(r.amount)}</td>`
        + `<td class="num">${total ? ((r.amount / total) * 100).toFixed(1) : '0.0'}%</td></tr>`).join('')
      + `<tr class="ms-total"><td>Total</td><td class="num">${countLabel(rows.reduce((s, r) => s + r.count, 0))}</td><td class="num">${formatMoney(total)}</td><td class="num">100%</td></tr>`
    : `<tr><td colspan="4" class="muted">${emptyText}</td></tr>`;
}

function groupSum(rows, keyField, countField, amountField) {
  const map = new Map();
  rows.forEach((r) => {
    const entry = map.get(r[keyField]) || { name: r[keyField], count: 0, amount: 0 };
    entry.count += Number(r[countField]) || 0;
    entry.amount += Number(r[amountField]) || 0;
    map.set(r[keyField], entry);
  });
  return [...map.values()].sort((a, b) => b.amount - a.amount);
}

function renderCategories() {
  shareTable('categoryBody', groupSum((report.categories || []).filter(inBranch), 'category', 'qty', 'revenue'),
    formatQty, 'No items sold this month.');
}

function renderExpenseCategories() {
  shareTable('expCatBody', groupSum((report.expense_categories || []).filter(inBranch), 'category', 'count', 'amount'),
    (n) => String(n), 'No expenses this month.');
}

// Advance orders live in their own table, so they're kept apart from the sales (like the daily report).
// Sales rows that are really an advance order (advance_copy) are left out of "Sales + Advance Collected".
function renderAdvance(salesTotal, days, collected) {
  const placed = (report.advance_placed || []).filter(inBranch);
  document.getElementById('statAdvPlaced').textContent = formatMoney(sumOf(placed, 'net'));
  document.getElementById('statAdvPlacedSub').textContent =
    `${plural(sumOf(placed, 'count'), 'order')} · ${formatMoney(sumOf(placed, 'downpayment'))} downpayment · ${formatMoney(sumOf(placed, 'balance'))} balance`;
  const collectedTotal = sumOf(collected, 'amount');
  const collectedCount = sumOf(collected, 'payment_count');
  document.getElementById('statAdvCollected').textContent = formatMoney(collectedTotal);
  document.getElementById('statAdvCollectedSub').textContent = plural(collectedCount, 'payment');
  const copies = sumOf(days, 'advance_copy');
  document.getElementById('statAllIn').textContent = formatMoney(salesTotal - copies + collectedTotal);
  document.getElementById('statAllInSub').textContent = copies
    ? `Total Sales plus advance collections, less ${formatMoney(copies)} of sales that are fully paid advance orders (already under Advance Collected)`
    : 'Total Sales plus money taken on advance orders (fully paid advance orders counted once)';

  const tenders = groupSum(collected, 'tender', 'payment_count', 'amount');
  document.getElementById('advTenderBody').innerHTML = tenders.length
    ? tenders.map((t) => `<tr><td>${escapeHtml(t.name)}</td><td class="num">${t.count}</td><td class="num">${formatMoney(t.amount)}</td></tr>`).join('')
      + (tenders.length > 1 ? `<tr class="ms-total"><td>Total</td><td class="num">${collectedCount}</td><td class="num">${formatMoney(collectedTotal)}</td></tr>` : '')
    : '<tr><td colspan="3" class="muted">No advance-order payments this month.</td></tr>';
}

function renderCash() {
  const cash = (report.cash || []).filter(inBranch);
  const varianceHtml = (v) => {
    const n = Number(v) || 0;
    if (n < 0) return `<span class="ms-short">Short ${formatMoney(-n)}</span>`;
    if (n > 0) return `<span class="ms-over">Over ${formatMoney(n)}</span>`;
    return formatMoney(0);
  };
  const row = (r) => `<td class="num">${r.counts}</td><td class="num">${formatMoney(r.cash_sales)}</td>`
    + `<td class="num">${Number(r.short) ? `<span class="ms-short">${formatMoney(-r.short)}</span>` : formatMoney(0)}</td>`
    + `<td class="num">${Number(r.over) ? `<span class="ms-over">${formatMoney(r.over)}</span>` : formatMoney(0)}</td>`
    + `<td class="num">${varianceHtml(r.variance)}</td><td class="num">${r.short_days}</td>`;
  if (!cash.length) {
    document.getElementById('cashBody').innerHTML = '<tr><td colspan="7" class="muted">No cash counts posted from the POS this month.</td></tr>';
    return;
  }
  const total = { counts: sumOf(cash, 'counts'), cash_sales: sumOf(cash, 'cash_sales'), short: sumOf(cash, 'short'),
    over: sumOf(cash, 'over'), variance: sumOf(cash, 'variance'), short_days: sumOf(cash, 'short_days') };
  document.getElementById('cashBody').innerHTML = cash.map((r) => `<tr><td>${escapeHtml(r.warehouse)}</td>${row(r)}</tr>`).join('')
    + (cash.length > 1 ? `<tr class="ms-total"><td>Total</td>${row(total)}</tr>` : '');
}

// source = the loaded report (month or year); listFields = its arrays that carry a warehouse.
function fillWarehouseSelect(source, listFields) {
  const select = document.getElementById('warehouseSelect');
  const current = select.value || new URL(window.location.href).searchParams.get('branch') || '';
  const names = new Set(source.warehouses || []);
  listFields.forEach((k) => (source[k] || []).forEach((r) => r.warehouse && names.add(r.warehouse)));
  if (current) names.add(current);
  select.innerHTML = '<option value="">All branches</option>' + [...names].sort()
    .map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');
  select.value = current;
}

function syncUrl() {
  const url = new URL(window.location.href);
  if (period === 'year') {
    url.searchParams.set('period', 'year');
    url.searchParams.set('year', selectedYear());
  } else {
    url.searchParams.delete('period');
    url.searchParams.delete('year');
  }
  url.searchParams.set('month', selectedMonthKey());
  if (selectedWarehouse()) url.searchParams.set('branch', selectedWarehouse());
  else url.searchParams.delete('branch');
  if (document.getElementById('matrixToggle').checked) url.searchParams.set('view', 'matrix');
  else url.searchParams.delete('view');
  const metric = document.getElementById('matrixMetric').value;
  if (document.getElementById('matrixToggle').checked && metric !== 'total') url.searchParams.set('show', metric);
  else url.searchParams.delete('show');
  window.history.replaceState(null, '', url);
}

async function loadReport() {
  const loadingEl = document.getElementById('msLoading');
  const errorEl = document.getElementById('msError');
  const resultsEl = document.getElementById('msResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const key = selectedMonthKey();
  const [y, m] = key.split('-').map(Number);
  document.getElementById('nextMonthBtn').disabled = key >= manilaMonthKey();
  syncUrl();

  const { data, error } = await supabaseClient.rpc('admin_get_monthly_sales_report', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_month: `${key}-01`
  });

  loadingEl.classList.add('hidden');
  if (period !== 'month') return;
  if (error) {
    errorEl.textContent = /admin_get_monthly_sales_report/.test(error.message)
      ? 'Run supabase_monthly_sales_report.sql in Supabase first.'
      : error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }

  report = data || {};
  const monthName = new Date(y, m - 1, 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  document.getElementById('monthLabel').textContent = report.through && report.through < report.month_end
    ? `${monthName} - so far (${shortDate(report.month)} to ${shortDate(report.through)})`
    : monthName;
  fillWarehouseSelect(report, ['days', 'expenses', 'cash', 'advance_placed', 'advance_collected']);
  render();
  resultsEl.classList.remove('hidden');
}

function setMonth(key) {
  document.getElementById('msMonth').value = key;
  loadReport();
}

// ---------------------------------------------------------------------------
// Year view: months x branches for one year (admin_get_yearly_sales_report, supabase_yearly_sales_report.sql),
// with growth vs the previous month or the same month last year. The year before is loaded too, so January
// compares with last December. The running month is compared on the same days (sales figures only).
let period = 'month';
let yearReport = null;

const SALES_METRICS = ['total', 'online', 'walkin', 'count', 'avg'];

function selectedYear() {
  return Number(document.getElementById('yrYear').value) || Number(manilaMonthKey().slice(0, 4));
}

function fillYearSelect(firstYear, value) {
  const curYear = Number(manilaMonthKey().slice(0, 4));
  const select = document.getElementById('yrYear');
  const keep = value || selectedYear();
  const from = Math.min(firstYear, keep);
  let html = '';
  for (let y = curYear; y >= from; y -= 1) html += `<option value="${y}">${y}</option>`;
  select.innerHTML = html;
  select.value = String(keep);
  document.getElementById('nextYearBtn').disabled = keep >= curYear;
}

function setYear(y) {
  const curYear = Number(manilaMonthKey().slice(0, 4));
  if (y > curYear) return;
  fillYearSelect(Math.min(y, curYear - 5), y);
  loadYear();
}

async function setPeriod(p) {
  period = p;
  const year = p === 'year';
  document.getElementById('monthViewBtn').classList.toggle('btn-primary', !year);
  document.getElementById('yearViewBtn').classList.toggle('btn-primary', year);
  document.getElementById('monthControls').classList.toggle('hidden', year);
  document.getElementById('yearControls').classList.toggle('hidden', !year);
  document.getElementById('matrixToggleLabel').classList.toggle('hidden', year);
  document.getElementById('msResults').classList.add('hidden');
  document.getElementById('yrResults').classList.add('hidden');
  document.querySelector('h1').textContent = year ? 'Sales by Month' : 'Monthly Sales';
  if (year) await loadYear();
  else await loadReport();
}

async function loadYear() {
  const loadingEl = document.getElementById('msLoading');
  const errorEl = document.getElementById('msError');
  const resultsEl = document.getElementById('yrResults');
  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  document.getElementById('nextYearBtn').disabled = selectedYear() >= Number(manilaMonthKey().slice(0, 4));
  syncUrl();

  const { data, error } = await supabaseClient.rpc('admin_get_yearly_sales_report', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_year: selectedYear()
  });
  loadingEl.classList.add('hidden');
  if (period !== 'year') return;
  if (error) {
    errorEl.textContent = /admin_get_yearly_sales_report/.test(error.message)
      ? 'Run supabase_yearly_sales_report.sql in Supabase first.'
      : error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }
  yearReport = data || {};
  if (yearReport.first_year) fillYearSelect(yearReport.first_year, selectedYear());
  fillWarehouseSelect(yearReport, ['sales', 'expenses', 'advance_collected']);
  renderYear();
  resultsEl.classList.remove('hidden');
}

function monthStart(y, i) {
  return `${y}-${String(i + 1).padStart(2, '0')}-01`;
}

// Year view figures, summed for a list of months [y, i] and branches.
function yearData() {
  const r = yearReport;
  const sales = new Map();
  (r.sales || []).forEach((s) => sales.set(`${s.month}|${s.warehouse}`, s));
  const sumBy = (rows) => {
    const m = new Map();
    (rows || []).forEach((x) => m.set(`${x.month}|${x.warehouse}`, (m.get(`${x.month}|${x.warehouse}`) || 0) + (Number(x.amount) || 0)));
    return m;
  };
  const expenses = sumBy(r.expenses);
  const adv = sumBy(r.advance_collected);

  const comp = (months, whs) => {
    const c = { online: 0, walkin: 0, count: 0, expense: 0, adv: 0 };
    months.forEach(([y, i]) => whs.forEach((wh) => {
      const k = `${monthStart(y, i)}|${wh}`;
      const s = sales.get(k);
      if (s) {
        c.online += Number(s.online) || 0;
        c.walkin += Number(s.walkin) || 0;
        c.count += (Number(s.online_count) || 0) + (Number(s.walkin_count) || 0);
      }
      c.expense += expenses.get(k) || 0;
      c.adv += adv.get(k) || 0;
    }));
    return c;
  };
  // Same days of the previous month / last year, for the running month ('prev' | 'last_year').
  const partialComp = (kind, whs) => {
    const c = { online: 0, walkin: 0, count: 0, expense: 0, adv: 0 };
    ((r.partial && r.partial[kind]) || []).filter((x) => whs.includes(x.warehouse)).forEach((x) => {
      c.online += Number(x.online_sales) || 0;
      c.walkin += Number(x.walkin_sales) || 0;
      c.count += (Number(x.online_count) || 0) + (Number(x.walkin_count) || 0);
    });
    return c;
  };
  return { comp, partialComp };
}

function metricValue(c, metric) {
  switch (metric) {
    case 'online': return c.online;
    case 'walkin': return c.walkin;
    case 'count': return c.count;
    case 'avg': return c.count ? (c.online + c.walkin) / c.count : 0;
    case 'expense': return c.expense;
    case 'net': return c.online + c.walkin - c.expense;
    case 'adv': return c.adv;
    default: return c.online + c.walkin;
  }
}

function yearPct(cur, base) {
  if (base === null || base === undefined || !base) return null;
  return ((cur - base) / Math.abs(base)) * 100;
}

// Up is good, except for expenses.
function yearPctHtml(pct, metric) {
  if (pct === null) return '';
  const good = metric === 'expense' ? pct <= 0 : pct >= 0;
  return `<span class="ms-pct ${good ? 'ms-up' : 'ms-down'}">${pct >= 0 ? '▲ +' : '▼ '}${pct.toFixed(0)}%</span>`;
}

// What the year grid shows - also used by the CSV export.
function yearGrid() {
  const r = yearReport;
  const y = Number(r.year);
  const metric = document.getElementById('yrMetric').value;
  const compare = document.getElementById('yrCompare').value;
  const salesMetric = SALES_METRICS.includes(metric);
  const [cy, cm] = String(r.current_month).split('-').map(Number);
  const elapsed = y < cy ? 12 : (y === cy ? cm : 0);
  const partialIdx = y === cy ? cm - 1 : -1;
  const { comp, partialComp } = yearData();

  // Columns: every branch with figures in either year, biggest sales this year first (or just the picked one).
  const totals = new Map();
  [...(r.sales || []), ...(r.expenses || []), ...(r.advance_collected || [])].forEach((x) => {
    const own = String(x.month).startsWith(String(y));
    totals.set(x.warehouse, (totals.get(x.warehouse) || 0) + (own ? (Number(x.online) || 0) + (Number(x.walkin) || 0) : 0));
  });
  const wh = selectedWarehouse();
  const branches = wh ? [wh] : [...totals.entries()].sort((a, b) => b[1] - a[1]).map(([k]) => k);
  const cols = branches.map((b) => ({ label: b, whs: [b] }));
  if (cols.length > 1) cols.push({ label: 'Total', whs: branches, total: true });

  const fmt = metric === 'count' ? (n) => formatQty(n) : formatMoney;
  const cellFor = (i, whs) => {
    if (i >= elapsed) return null;
    const value = metricValue(comp([[y, i]], whs), metric);
    let base = null;
    if (i === partialIdx) {
      if (salesMetric && compare !== 'none') base = metricValue(partialComp(compare === 'mom' ? 'prev' : 'last_year', whs), metric);
    } else if (compare === 'mom') {
      base = metricValue(comp([i === 0 ? [y - 1, 11] : [y, i - 1]], whs), metric);
    } else if (compare === 'yoy') {
      base = metricValue(comp([[y - 1, i]], whs), metric);
    }
    return { value, pct: yearPct(value, base) };
  };

  // Year total vs last year's same period (the running month on the same days; non-sales figures of a
  // running year have no fair base, so no %).
  const months = [...Array(elapsed).keys()].map((i) => [y, i]);
  const lyMonths = [...Array(y === cy ? elapsed - 1 : 12).keys()].map((i) => [y - 1, i]);
  const yearTotal = (whs) => {
    const c = comp(months, whs);
    const value = metricValue(c, metric);
    let base = null;
    if (y < cy) base = metricValue(comp([...Array(12).keys()].map((i) => [y - 1, i]), whs), metric);
    else if (y === cy && salesMetric) {
      const ly = comp(lyMonths, whs);
      const p = partialComp('last_year', whs);
      base = metricValue({ online: ly.online + p.online, walkin: ly.walkin + p.walkin, count: ly.count + p.count, expense: 0, adv: 0 }, metric);
    }
    return { value, pct: yearPct(value, base), base };
  };

  return { y, cy, cm, metric, compare, elapsed, partialIdx, cols, fmt, cellFor, yearTotal, comp, partialComp, lyMonths, months };
}

function renderYear() {
  if (!yearReport || period !== 'year') return;
  const g = yearGrid();
  const wh = selectedWarehouse();

  document.getElementById('yearLabel').textContent = g.y === g.cy
    ? `${g.y} - so far (to ${shortDate(yearReport.today, true)})${wh ? ' · ' + wh : ''}`
    : `${g.y}${wh ? ' · ' + wh : ''}`;
  document.getElementById('yrHead').innerHTML = `<tr><th>Month</th>${g.cols.map((c) =>
    `<th class="num${c.total ? ' ms-rowtotal' : ''}">${escapeHtml(c.label)}</th>`).join('')}</tr>`;

  const show = (cell, extraClass) => {
    if (!cell) return `<td class="num${extraClass ? ' ' + extraClass : ''}"><span class="muted">-</span></td>`;
    return `<td class="num${extraClass ? ' ' + extraClass : ''}">${cell.value ? g.fmt(cell.value) : '<span class="muted">-</span>'}`
      + `${g.compare === 'none' ? '' : yearPctHtml(cell.pct, g.metric)}</td>`;
  };
  const rows = [];
  for (let i = 0; i < 12; i += 1) {
    const key = monthStart(g.y, i).slice(0, 7);
    const partial = i === g.partialIdx;
    const label = `<a href="monthly-sales-report.html?month=${key}${wh ? '&branch=' + encodeURIComponent(wh) : ''}" title="Open ${MONTHS[i]} in Month view">${MONTHS[i]}</a>${partial ? ' <span class="muted ms-partial">(so far)</span>' : ''}`;
    rows.push(`<tr${i >= g.elapsed ? ' class="ms-zero"' : ''}><td>${label}</td>`
      + g.cols.map((c) => show(g.cellFor(i, c.whs), c.total ? 'ms-rowtotal' : '')).join('') + '</tr>');
  }
  const totalLabel = g.metric === 'avg' ? `${g.y} average` : `${g.y} total`;
  rows.push(`<tr class="ms-total"><td>${totalLabel}<span class="ms-pct muted" style="font-weight:400;">vs ${g.y - 1}${g.y === g.cy ? ' same period' : ''}</span></td>`
    + g.cols.map((c) => {
      const t = g.yearTotal(c.whs);
      return `<td class="num${c.total ? ' ms-rowtotal' : ''}">${t.value ? g.fmt(t.value) : '<span class="muted">-</span>'}${yearPctHtml(t.pct, g.metric)}</td>`;
    }).join('') + '</tr>');
  document.getElementById('yrBody').innerHTML = rows.join('');

  document.getElementById('yrPartialNote').textContent = g.partialIdx >= 0
    ? `${MONTHS[g.partialIdx]} is still running, so its sales % compares the same days (${MONTHS[g.partialIdx]} 1-${Number(yearReport.today.slice(8))}); expenses and advance figures for ${MONTHS[g.partialIdx]} have no % until the month ends.`
    : '';

  renderYearCards(g);
}

function renderYearCards(g) {
  const wh = selectedWarehouse();
  const allBranches = g.cols.filter((c) => !c.total).map((c) => c.label);
  const whs = wh ? [wh] : allBranches;
  const totalSales = (c) => c.online + c.walkin;

  const cur = g.comp(g.months, whs);
  document.getElementById('yrStatTitle').textContent = g.y === g.cy ? `Sales in ${g.y} so far` : `Sales in ${g.y}`;
  document.getElementById('yrStatTotal').textContent = formatMoney(totalSales(cur));
  document.getElementById('yrStatTotalSub').textContent =
    `${plural(cur.count, 'order')} · avg ${formatMoney(g.elapsed ? totalSales(cur) / g.elapsed : 0)} / month`;

  // Last year's sales for the same period (the running month on the same days).
  const lastYearSales = (list) => (g.y === g.cy
    ? totalSales(g.comp(g.lyMonths, list)) + totalSales(g.partialComp('last_year', list))
    : totalSales(g.comp([...Array(12).keys()].map((i) => [g.y - 1, i]), list)));
  const lyBase = lastYearSales(whs);
  const lyPct = yearPct(totalSales(cur), lyBase);
  document.getElementById('yrStatLyTitle').textContent = g.y === g.cy ? `${g.y - 1}, same period` : `Sales in ${g.y - 1}`;
  document.getElementById('yrStatLy').textContent = formatMoney(lyBase);
  document.getElementById('yrStatLySub').innerHTML = lyPct === null
    ? 'No sales to compare with'
    : `${g.y} is <span class="${lyPct >= 0 ? 'ms-up' : 'ms-down'}">${lyPct >= 0 ? 'up' : 'down'} ${Math.abs(lyPct).toFixed(0)}%</span> (${lyPct >= 0 ? '+' : '-'}${formatMoney(Math.abs(totalSales(cur) - lyBase))})`;

  // Best full month (the running month only if it's the only one).
  let best = null;
  for (let i = 0; i < g.elapsed; i += 1) {
    if (i === g.partialIdx && g.elapsed > 1) continue;
    const v = totalSales(g.comp([[g.y, i]], whs));
    if (!best || v > best.v) best = { i, v };
  }
  document.getElementById('yrStatBest').textContent = best && best.v ? MONTHS[best.i] : '-';
  document.getElementById('yrStatBestSub').textContent = best && best.v ? formatMoney(best.v) : '';

  // Fastest growing branch vs last year, same period (branches with sales last year only).
  let grow = null;
  allBranches.forEach((b) => {
    const pct = yearPct(totalSales(g.comp(g.months, [b])), lastYearSales([b]));
    if (pct !== null && (!grow || pct > grow.pct)) grow = { b, pct };
  });
  document.getElementById('yrStatGrow').textContent = grow ? grow.b : '-';
  document.getElementById('yrStatGrowSub').innerHTML = grow
    ? `<span class="${grow.pct >= 0 ? 'ms-up' : 'ms-down'}">${grow.pct >= 0 ? '+' : ''}${grow.pct.toFixed(0)}%</span> vs ${g.y - 1}${g.y === g.cy ? ' same period' : ''}`
    : `No branch had sales in ${g.y - 1} to compare`;
}

function exportYearCsv() {
  if (!yearReport) return;
  const g = yearGrid();
  const label = document.getElementById('yrMetric').selectedOptions[0].textContent;
  const withPct = g.compare !== 'none';
  const pctLabel = g.compare === 'mom' ? 'vs prev month %' : 'vs last year %';
  const lines = [
    csvCell(`Sales by Month - ${g.y} - ${label}`),
    csvCell(`Branch: ${selectedWarehouse() || 'All branches'}`),
    '',
    ['Month', ...g.cols.flatMap((c) => (withPct ? [c.label, `${c.label} ${pctLabel}`] : [c.label]))].map(csvCell).join(',')
  ];
  for (let i = 0; i < 12; i += 1) {
    lines.push([MONTHS[i] + (i === g.partialIdx ? ' (so far)' : ''), ...g.cols.flatMap((c) => {
      const cell = g.cellFor(i, c.whs);
      const v = cell ? Number(cell.value) : '';
      return withPct ? [v, cell && cell.pct !== null ? `${cell.pct.toFixed(1)}%` : ''] : [v];
    })].map(csvCell).join(','));
  }
  lines.push([`${g.y} total`, ...g.cols.flatMap((c) => {
    const t = g.yearTotal(c.whs);
    return withPct ? [Number(t.value), t.pct !== null ? `${t.pct.toFixed(1)}% vs ${g.y - 1}` : ''] : [Number(t.value)];
  })].map(csvCell).join(','));
  downloadCsv(lines, `sales-by-month-${g.y}${selectedWarehouse() ? '-' + selectedWarehouse().replace(/\s+/g, '-') : ''}.csv`);
}

function csvCell(value) {
  const text = typeof value === 'number' ? value.toFixed(2) : String(value ?? '');
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

// The Day by Day table as CSV (current branch filter); in Year view, the months x branches grid.
function exportCsv() {
  if (period === 'year') {
    exportYearCsv();
    return;
  }
  if (!report) return;
  const lines = [
    csvCell(`Monthly Sales - ${selectedMonthKey()}`),
    csvCell(`Branch: ${selectedWarehouse() || 'All branches'}`),
    ''
  ];
  const table = document.getElementById('dayBody').closest('table');
  table.querySelectorAll('tr').forEach((tr) => {
    lines.push([...tr.children].map((cell) => {
      const text = cell.textContent.trim();
      const num = text.replace(/[₱,]/g, '');
      return csvCell(cell.classList.contains('num') && num !== '' && !Number.isNaN(Number(num)) ? Number(num) : text);
    }).join(','));
  });

  downloadCsv(lines, `monthly-sales-${selectedMonthKey()}${selectedWarehouse() ? '-' + selectedWarehouse().replace(/\s+/g, '-') : ''}.csv`);
}

function downloadCsv(lines, fileName) {
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Monthly Sales Report');

  if (!session.isSuperUser) {
    document.getElementById('msLoading').classList.add('hidden');
    const errorEl = document.getElementById('msError');
    errorEl.textContent = 'Only a Super User can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  const fromUrl = new URL(window.location.href).searchParams.get('month');
  const monthInput = document.getElementById('msMonth');
  monthInput.max = manilaMonthKey();
  monthInput.value = /^\d{4}-\d{2}$/.test(fromUrl || '') && fromUrl <= manilaMonthKey() ? fromUrl : manilaMonthKey();

  monthInput.addEventListener('change', loadReport);
  document.getElementById('prevMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), -1)));
  document.getElementById('nextMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), 1)));
  document.getElementById('thisMonthBtn').addEventListener('click', () => setMonth(manilaMonthKey()));
  document.getElementById('lastMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(manilaMonthKey(), -1)));
  document.getElementById('warehouseSelect').addEventListener('change', () => {
    syncUrl();
    if (period === 'year') renderYear();
    else render();
  });

  // Year view - months x branches for a whole year (?period=year&year=2026).
  const curYear = Number(manilaMonthKey().slice(0, 4));
  const urlYear = Number(new URL(window.location.href).searchParams.get('year'));
  fillYearSelect(curYear - 5, urlYear >= 2000 && urlYear <= curYear ? urlYear : curYear);
  document.getElementById('yrYear').addEventListener('change', loadYear);
  document.getElementById('prevYearBtn').addEventListener('click', () => setYear(selectedYear() - 1));
  document.getElementById('nextYearBtn').addEventListener('click', () => setYear(selectedYear() + 1));
  document.getElementById('thisYearBtn').addEventListener('click', () => setYear(curYear));
  document.getElementById('yrMetric').addEventListener('change', renderYear);
  document.getElementById('yrCompare').addEventListener('change', renderYear);
  document.getElementById('monthViewBtn').addEventListener('click', () => setPeriod('month'));
  document.getElementById('yearViewBtn').addEventListener('click', () => setPeriod('year'));

  // Branches side by side (matrix) - remembered in the URL (?view=matrix&show=net).
  MATRIX_TABLES.forEach((id) => { defaultHeads[id] = headOf(id).innerHTML; });
  const params = new URL(window.location.href).searchParams;
  document.getElementById('matrixToggle').checked = params.get('view') === 'matrix';
  const metricSelect = document.getElementById('matrixMetric');
  if ([...metricSelect.options].some((o) => o.value === params.get('show'))) metricSelect.value = params.get('show');
  document.getElementById('matrixToggle').addEventListener('change', () => { syncUrl(); render(); });
  metricSelect.addEventListener('change', () => { syncUrl(); render(); });
  document.getElementById('exportBtn').addEventListener('click', exportCsv);
  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await setPeriod(new URL(window.location.href).searchParams.get('period') === 'year' ? 'year' : 'month');
})();
