// Purchases & Expenses report - per "can you create me a report of the total expense and what
// causing the expense percentage.. i want to see purchase and expense".
//
// admin_get_spending_report (supabase_spending_report.sql) returns one row per source (Purchase /
// Expense) x channel x warehouse x cause x vendor x detail for the date range. Everything else -
// the type / warehouse filters, ranking the causes, their share of the total and drilling into one
// cause - happens here, so none of it re-queries.
let currentSession = null;
let period = 'month'; // 'today' | 'month' | 'prevmonth' | '90d' | 'year' | 'custom'
let reportRows = [];
let selected = null; // { source, key } of the cause being drilled into, else null

const SOURCE_COLOR = { Purchase: 'var(--pm-s1)', Expense: 'var(--pm-s2)' };

function toDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function formatMoney(value) {
  const amount = Number(value) || 0;
  return '₱' + amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatQty(value) {
  return (Number(value) || 0).toLocaleString('en-PH', { maximumFractionDigits: 2 });
}

function formatPercent(fraction) {
  const pct = (fraction || 0) * 100;
  return (pct > 0 && pct < 0.1 ? '<0.1' : pct.toFixed(1)) + '%';
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Asia/Manila "today", so the periods match the Dashboard's cards regardless of the browser's zone.
function manilaToday() {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const [y, m, d] = parts.split('-').map(Number);
  return new Date(y, m - 1, d);
}

function computeRange() {
  const today = manilaToday();
  const fmt = { month: 'short', day: 'numeric', year: 'numeric' };
  if (period === 'today') {
    return { from: today, to: today, label: today.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' }) };
  }
  if (period === 'prevmonth') {
    const from = new Date(today.getFullYear(), today.getMonth() - 1, 1);
    const to = new Date(today.getFullYear(), today.getMonth(), 0);
    return { from, to, label: from.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }) };
  }
  if (period === '90d') {
    const from = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 89);
    return { from, to: today, label: `Last 90 days (${from.toLocaleDateString('en-US', fmt)} - ${today.toLocaleDateString('en-US', fmt)})` };
  }
  if (period === 'year') {
    const from = new Date(today.getFullYear(), 0, 1);
    return { from, to: today, label: `${today.getFullYear()} (year to date)` };
  }
  if (period === 'custom') {
    const fromVal = document.getElementById('dateFrom').value;
    const toVal = document.getElementById('dateTo').value;
    const from = fromVal ? new Date(fromVal + 'T00:00:00') : today;
    const to = toVal ? new Date(toVal + 'T00:00:00') : today;
    return { from, to, label: `${from.toLocaleDateString('en-US', fmt)} - ${to.toLocaleDateString('en-US', fmt)}` };
  }
  const from = new Date(today.getFullYear(), today.getMonth(), 1);
  return { from, to: today, label: `${from.toLocaleDateString('en-US', { month: 'long', year: 'numeric' })} (month to date)` };
}

function setPeriod(value) {
  period = value;
  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.className = `btn btn-${btn.dataset.period === value ? 'primary' : 'secondary'} btn-sm`;
  });
  document.getElementById('customRange').classList.toggle('hidden', value !== 'custom');
  if (value === 'custom') {
    const today = manilaToday();
    if (!document.getElementById('dateFrom').value) document.getElementById('dateFrom').value = toDateKey(new Date(today.getFullYear(), today.getMonth(), 1));
    if (!document.getElementById('dateTo').value) document.getElementById('dateTo').value = toDateKey(today);
    return; // waits for Apply
  }
  loadReport();
}

function sumAmount(rows) {
  return rows.reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
}

function warehouseRows() {
  const warehouse = document.getElementById('warehouseSelect').value;
  return reportRows.filter((r) => !warehouse || r.warehouse_name === warehouse);
}

function filteredRows() {
  const source = document.getElementById('sourceSelect').value;
  return warehouseRows().filter((r) => source === 'all' || r.source === source);
}

// A purchase's cause is its item category or its vendor (the "Group purchases by" switch); an
// expense's is always its Expense Category. Keyed case-insensitively so "Food" and "FOOD" merge.
function causeOf(row) {
  const groupBy = document.getElementById('purchaseGroupSelect').value;
  const name = row.source === 'Purchase' ? (row[groupBy] || '(None)') : row.cause;
  return { key: `${row.source}|${String(name).trim().toLowerCase()}`, name };
}

function causeKind(source) {
  if (source === 'Expense') return 'Expense category';
  return document.getElementById('purchaseGroupSelect').value === 'vendor_name' ? 'Vendor' : 'Item category';
}

function swatch(source) {
  return `<span class="pm-swatch" style="background:${SOURCE_COLOR[source]};"></span>`;
}

function shareCell(value, top, total, source) {
  return `
    <div class="pm-share">
      <div class="pm-share-track"><div class="pm-share-fill" style="width:${top > 0 ? Math.max(0, value / top) * 100 : 0}%; background:${SOURCE_COLOR[source]};"></div></div>
      <span class="pm-share-pct">${formatPercent(total > 0 ? value / total : 0)}</span>
    </div>`;
}

function renderSplit(purchase, expense) {
  const bar = document.getElementById('splitBar');
  const legend = document.getElementById('splitLegend');
  const grand = purchase + expense;
  const parts = [['Purchase', 'Purchases', purchase], ['Expense', 'Expenses', expense]];
  bar.innerHTML = grand > 0
    ? parts.filter((p) => p[2] > 0)
        .map(([source, label, amount]) => `<div class="ss-split-seg" style="flex-grow:${amount}; background:${SOURCE_COLOR[source]};" title="${label}: ${formatMoney(amount)} (${formatPercent(amount / grand)})"></div>`)
        .join('')
    : '<div class="ss-split-empty"></div>';
  legend.innerHTML = parts
    .map(([source, label, amount]) => `
      <div class="ss-split-legend-row">
        ${swatch(source)}<strong>${label}</strong>
        <span>${formatMoney(amount)}</span>
        <span class="muted">${formatPercent(grand > 0 ? amount / grand : 0)}</span>
      </div>`)
    .join('');
}

function renderCauses(rows, total) {
  const byKey = new Map();
  rows.forEach((r) => {
    const { key, name } = causeOf(r);
    let entry = byKey.get(key);
    if (!entry) {
      entry = { key, name, source: r.source, amount: 0, entries: 0, details: new Set() };
      byKey.set(key, entry);
    }
    entry.amount += Number(r.amount) || 0;
    entry.entries += Number(r.entry_count) || 0;
    entry.details.add(r.detail);
  });
  const causes = [...byKey.values()].sort((a, b) => b.amount - a.amount);

  document.getElementById('spTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Cause</th>
      <th>Type</th>
      <th style="text-align:right;">Amount</th>
      <th style="min-width:180px;">% of Total</th>
      <th style="text-align:right;">Count</th>
    </tr>`;
  const tbody = document.getElementById('spTableBody');
  if (causes.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No purchases or expenses in this period.</td></tr>';
    return causes;
  }
  const top = causes[0].amount;
  tbody.innerHTML = causes
    .map((c, i) => `
      <tr class="cs-row-link" data-key="${escapeHtml(c.key)}" data-source="${c.source}" tabindex="0" title="See what is inside ${escapeHtml(c.name)}">
        <td>${i + 1}</td>
        <td><a href="#" class="cs-link">${escapeHtml(c.name)}</a><div class="muted" style="font-size:12px;">${causeKind(c.source)}</div></td>
        <td style="white-space:nowrap;">${swatch(c.source)}${c.source}</td>
        <td style="text-align:right;">${formatMoney(c.amount)}</td>
        <td>${shareCell(c.amount, top, total, c.source)}</td>
        <td style="text-align:right; white-space:nowrap;">${c.source === 'Purchase' ? `${c.details.size} item${c.details.size === 1 ? '' : 's'}` : `${c.entries} entr${c.entries === 1 ? 'y' : 'ies'}`}</td>
      </tr>`)
    .join('');

  tbody.querySelectorAll('.cs-row-link').forEach((tr) => {
    const open = (e) => { e.preventDefault(); selected = { source: tr.dataset.source, key: tr.dataset.key }; render(); };
    tr.addEventListener('click', open);
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') open(e); });
  });
  return causes;
}

// Inside one cause: purchases list the items bought (with the other grouping - vendor or category -
// beside them), expenses list each description with where it was recorded.
function renderDetail(rows, total) {
  const isPurchase = selected.source === 'Purchase';
  const otherKey = document.getElementById('purchaseGroupSelect').value === 'vendor_name' ? 'cause' : 'vendor_name';
  const byKey = new Map();
  rows.forEach((r) => {
    const second = isPurchase ? r[otherKey] : r.channel;
    const key = `${r.detail}|${second}`;
    let entry = byKey.get(key);
    if (!entry) {
      entry = { detail: r.detail, second, amount: 0, qty: 0, entries: 0 };
      byKey.set(key, entry);
    }
    entry.amount += Number(r.amount) || 0;
    entry.qty += Number(r.qty) || 0;
    entry.entries += Number(r.entry_count) || 0;
  });
  const entries = [...byKey.values()].sort((a, b) => b.amount - a.amount);
  const causeTotal = sumAmount(rows);

  document.getElementById('spTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>${isPurchase ? 'Item' : 'Description'}</th>
      <th>${isPurchase ? (otherKey === 'vendor_name' ? 'Vendor' : 'Category') : 'Recorded In'}</th>
      <th style="text-align:right;">${isPurchase ? 'Qty Received' : 'Entries'}</th>
      <th style="text-align:right;">Amount</th>
      <th style="min-width:180px;">% of This Cause</th>
      <th style="text-align:right;">% of Total</th>
    </tr>`;
  const tbody = document.getElementById('spTableBody');
  if (entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">Nothing under this cause for the chosen filters.</td></tr>';
    return;
  }
  const top = entries[0].amount;
  tbody.innerHTML = entries
    .map((e, i) => `
      <tr>
        <td>${i + 1}</td>
        <td>${escapeHtml(e.detail)}</td>
        <td>${escapeHtml(e.second || '-')}</td>
        <td style="text-align:right;">${isPurchase ? formatQty(e.qty) : e.entries}</td>
        <td style="text-align:right;">${formatMoney(e.amount)}</td>
        <td>${shareCell(e.amount, top, causeTotal, selected.source)}</td>
        <td style="text-align:right;">${formatPercent(total > 0 ? e.amount / total : 0)}</td>
      </tr>`)
    .join('');
}

function render() {
  const rows = filteredRows();
  const total = sumAmount(rows);

  // The two type cards and the split bar always compare purchases against expenses for the chosen
  // warehouse, even when the table is narrowed to one type.
  const whRows = warehouseRows();
  const purchase = sumAmount(whRows.filter((r) => r.source === 'Purchase'));
  const expense = sumAmount(whRows.filter((r) => r.source === 'Expense'));
  const grand = purchase + expense;
  document.getElementById('statTotal').textContent = formatMoney(total);
  document.getElementById('statPurchase').textContent = formatMoney(purchase);
  document.getElementById('statPurchaseSub').textContent = `${formatPercent(grand > 0 ? purchase / grand : 0)} of spending`;
  document.getElementById('statExpense').textContent = formatMoney(expense);
  document.getElementById('statExpenseSub').textContent = `${formatPercent(grand > 0 ? expense / grand : 0)} of spending`;
  renderSplit(purchase, expense);

  const uncosted = rows.reduce((sum, r) => sum + (Number(r.uncosted_lines) || 0), 0);
  const uncostedEl = document.getElementById('uncostedNote');
  uncostedEl.textContent = uncosted > 0
    ? `${uncosted} received purchase order line${uncosted === 1 ? ' has' : 's have'} no unit cost yet and count as ₱0 - purchases are understated until they are costed.`
    : '';
  uncostedEl.classList.toggle('hidden', uncosted === 0);

  const inCause = selected ? rows.filter((r) => causeOf(r).key === selected.key) : [];
  if (selected && inCause.length === 0) selected = null; // filtered away - back to the overview

  document.getElementById('backBtn').classList.toggle('hidden', !selected);
  document.getElementById('groupByWrap').classList.toggle('hidden', !!selected);

  if (selected) {
    const name = causeOf(inCause[0]).name;
    const causeTotal = sumAmount(inCause);
    document.getElementById('tableTitle').textContent = `${name} (${selected.source})`;
    document.getElementById('statTopLabel').textContent = name;
    document.getElementById('statTop').textContent = `${formatMoney(causeTotal)} (${formatPercent(total > 0 ? causeTotal / total : 0)})`;
    renderDetail(inCause, total);
  } else {
    document.getElementById('tableTitle').textContent = 'What is causing the spending';
    document.getElementById('statTopLabel').textContent = 'Biggest Cause';
    const causes = renderCauses(rows, total);
    document.getElementById('statTop').textContent = causes.length
      ? `${causes[0].name} (${formatPercent(total > 0 ? causes[0].amount / total : 0)})`
      : 'Nothing spent yet';
  }
}

async function loadReport() {
  const loadingEl = document.getElementById('spLoading');
  const errorEl = document.getElementById('spError');
  const resultsEl = document.getElementById('spResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const range = computeRange();
  document.getElementById('periodLabel').textContent = range.label;

  const { data, error } = await supabaseClient.rpc('admin_get_spending_report', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_date_from: toDateKey(range.from),
    p_date_to: toDateKey(range.to)
  });

  loadingEl.classList.add('hidden');
  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }

  reportRows = data || [];
  const select = document.getElementById('warehouseSelect');
  const current = select.value;
  const warehouses = [...new Set(reportRows.map((r) => r.warehouse_name).filter(Boolean))].sort();
  select.innerHTML = '<option value="">All warehouses</option>' +
    warehouses.map((w) => `<option value="${escapeHtml(w)}">${escapeHtml(w)}</option>`).join('');
  select.value = warehouses.includes(current) ? current : '';

  render();
  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Purchases & Expenses Report');

  if (!session.isSuperUser) {
    document.getElementById('spLoading').classList.add('hidden');
    const errorEl = document.getElementById('spError');
    errorEl.textContent = 'Only a Super User can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.addEventListener('click', () => setPeriod(btn.dataset.period));
  });
  document.getElementById('applyRangeBtn').addEventListener('click', loadReport);
  document.getElementById('backBtn').addEventListener('click', () => { selected = null; render(); });
  ['sourceSelect', 'warehouseSelect', 'purchaseGroupSelect'].forEach((id) => {
    document.getElementById(id).addEventListener('change', render);
  });

  await loadReport();
})();
