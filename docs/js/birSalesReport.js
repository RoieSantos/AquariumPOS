// BIR Sales report - per "i need to extract my sales.. only for walkin, its for bir compliance.. can we
// have some feature to extract the sales base on BIR". Super users only (the RPC re-checks).
//
// admin_get_bir_walkin_sales (supabase_bir_walkin_sales_report.sql) returns every walk-in receipt in the
// date range as one jsonb array; the branch filter, the three views (Sales Journal / Daily Summary /
// Monthly Totals), the VAT or percentage-tax columns and the CSV export are all built here, so switching
// them doesn't re-query.
let currentSession = null;
let period = 'month'; // 'month' | 'prevmonth' | 'quarter' | 'prevquarter' | 'custom'
let view = 'journal'; // 'journal' | 'daily' | 'monthly'
let sales = [];
let companyInfo = null;
let rangeKeys = { from: '', to: '' };

const TAX_KEY = 'birSalesReport.taxType';
const VAT_RATE = 0.12;
const PERCENTAGE_TAX_RATE = 0.03;

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

function formatDate(key) {
  return new Date(key + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatMonth(key) {
  return new Date(key + '-01T00:00:00').toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
}

function round2(value) {
  return Math.round((Number(value) || 0) * 100) / 100;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Asia/Manila "today", so the periods match the Dashboard regardless of the browser's zone.
function manilaToday() {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const [y, m, d] = parts.split('-').map(Number);
  return new Date(y, m - 1, d);
}

function computeRange() {
  const today = manilaToday();
  const qStart = Math.floor(today.getMonth() / 3) * 3;
  if (period === 'prevmonth') {
    const from = new Date(today.getFullYear(), today.getMonth() - 1, 1);
    const to = new Date(today.getFullYear(), today.getMonth(), 0);
    return { from, to, label: from.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }) };
  }
  if (period === 'quarter') {
    const from = new Date(today.getFullYear(), qStart, 1);
    return { from, to: today, label: `Q${qStart / 3 + 1} ${today.getFullYear()} (quarter to date)` };
  }
  if (period === 'prevquarter') {
    const from = new Date(today.getFullYear(), qStart - 3, 1);
    const to = new Date(today.getFullYear(), qStart, 0);
    return { from, to, label: `Q${Math.floor(from.getMonth() / 3) + 1} ${from.getFullYear()}` };
  }
  if (period === 'custom') {
    const fromVal = document.getElementById('dateFrom').value;
    const toVal = document.getElementById('dateTo').value;
    const from = fromVal ? new Date(fromVal + 'T00:00:00') : today;
    const to = toVal ? new Date(toVal + 'T00:00:00') : today;
    return { from, to, label: `${formatDate(toDateKey(from))} - ${formatDate(toDateKey(to))}` };
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
    const range = computeRange();
    if (!document.getElementById('dateFrom').value) document.getElementById('dateFrom').value = toDateKey(new Date(range.from.getFullYear(), range.from.getMonth(), 1));
    if (!document.getElementById('dateTo').value) document.getElementById('dateTo').value = toDateKey(range.to);
    return; // waits for Apply
  }
  loadReport();
}

function taxType() {
  return document.getElementById('taxSelect').value;
}

// VAT-registered: prices are VAT-inclusive, so VATable = net / 1.12. Non-VAT: percentage tax on net.
function taxColumns() {
  return taxType() === 'vat'
    ? [{ key: 'vatable', label: 'VATable Sales' }, { key: 'vat', label: 'VAT (12%)' }]
    : [{ key: 'ptax', label: 'Percentage Tax (3%)' }];
}

function taxValues(net) {
  if (taxType() === 'vat') {
    const vatable = round2(net / (1 + VAT_RATE));
    return { vatable, vat: round2(net - vatable) };
  }
  return { ptax: round2(net * PERCENTAGE_TAX_RATE) };
}

function filteredSales() {
  const warehouse = document.getElementById('warehouseSelect').value;
  return sales.filter((s) => !warehouse || s.warehouse_name === warehouse);
}

function addTotals(target, s) {
  target.count += 1;
  target.gross += Number(s.gross) || 0;
  target.discount += Number(s.discount) || 0;
  target.net += Number(s.net) || 0;
}

// Receipt nos. sort by their digits, so RS-000099 comes before RS-000100.
function receiptOrder(a, b) {
  const na = Number(String(a).replace(/\D/g, ''));
  const nb = Number(String(b).replace(/\D/g, ''));
  return na !== nb ? na - nb : String(a).localeCompare(String(b));
}

// Each view as { columns: [{label, num}], rows: [[cell...]], total: [cell...] } - shared by the table
// and the CSV, so what's exported is exactly what's on screen. Money cells are plain numbers.
function buildView(list) {
  const taxCols = taxColumns();
  const moneyCols = (label) => ({ label, num: true });

  if (view === 'journal') {
    const columns = [
      { label: 'Date' }, { label: 'Receipt No.' }, { label: 'Order #' }, { label: 'Customer' }, { label: 'Branch' },
      moneyCols('Gross Sales'), moneyCols('Discount'), moneyCols('Net Sales'),
      ...taxCols.map((c) => moneyCols(c.label)),
      { label: 'Paid Via' }, { label: 'Cashier' }
    ];
    const total = { count: 0, gross: 0, discount: 0, net: 0 };
    const rows = list.map((s) => {
      addTotals(total, s);
      const tax = taxValues(Number(s.net) || 0);
      return [
        s.sale_date, s.receipt_no || '', s.order_id, s.customer_name || '', s.warehouse_name,
        round2(s.gross), round2(s.discount), round2(s.net),
        ...taxCols.map((c) => tax[c.key]),
        s.payments || '', s.cashier || ''
      ];
    });
    const tax = taxValues(total.net);
    return {
      columns, rows,
      total: [`Total (${total.count} receipts)`, '', '', '', '', round2(total.gross), round2(total.discount), round2(total.net), ...taxCols.map((c) => tax[c.key]), '', ''],
      dateCols: [0]
    };
  }

  if (view === 'daily') {
    const columns = [
      { label: 'Date' }, { label: 'Branch' }, { label: 'First Receipt No.' }, { label: 'Last Receipt No.' },
      { label: 'Receipts', num: true }, moneyCols('Gross Sales'), moneyCols('Discount'), moneyCols('Net Sales'),
      ...taxCols.map((c) => moneyCols(c.label))
    ];
    const groups = new Map();
    list.forEach((s) => {
      const key = `${s.sale_date}|${s.warehouse_name}`;
      const g = groups.get(key) || { date: s.sale_date, branch: s.warehouse_name, receipts: [], count: 0, gross: 0, discount: 0, net: 0 };
      addTotals(g, s);
      if (s.receipt_no) g.receipts.push(s.receipt_no);
      groups.set(key, g);
    });
    const total = { count: 0, gross: 0, discount: 0, net: 0 };
    const rows = [...groups.values()]
      .sort((a, b) => a.date.localeCompare(b.date) || a.branch.localeCompare(b.branch))
      .map((g) => {
        total.count += g.count; total.gross += g.gross; total.discount += g.discount; total.net += g.net;
        const sorted = g.receipts.sort(receiptOrder);
        const tax = taxValues(g.net);
        return [g.date, g.branch, sorted[0] || '', sorted[sorted.length - 1] || '', g.count,
          round2(g.gross), round2(g.discount), round2(g.net), ...taxCols.map((c) => tax[c.key])];
      });
    const tax = taxValues(total.net);
    return {
      columns, rows,
      total: ['Total', '', '', '', total.count, round2(total.gross), round2(total.discount), round2(total.net), ...taxCols.map((c) => tax[c.key])],
      dateCols: [0]
    };
  }

  const columns = [
    { label: 'Month' }, { label: 'Receipts', num: true }, moneyCols('Gross Sales'), moneyCols('Discount'), moneyCols('Net Sales'),
    ...taxCols.map((c) => moneyCols(c.label))
  ];
  const months = new Map();
  list.forEach((s) => {
    const key = s.sale_date.slice(0, 7);
    const m = months.get(key) || { month: key, count: 0, gross: 0, discount: 0, net: 0 };
    addTotals(m, s);
    months.set(key, m);
  });
  const total = { count: 0, gross: 0, discount: 0, net: 0 };
  const rows = [...months.values()]
    .sort((a, b) => a.month.localeCompare(b.month))
    .map((m) => {
      total.count += m.count; total.gross += m.gross; total.discount += m.discount; total.net += m.net;
      const tax = taxValues(m.net);
      return [m.month, m.count, round2(m.gross), round2(m.discount), round2(m.net), ...taxCols.map((c) => tax[c.key])];
    });
  const tax = taxValues(total.net);
  return {
    columns, rows,
    total: ['Total', total.count, round2(total.gross), round2(total.discount), round2(total.net), ...taxCols.map((c) => tax[c.key])],
    monthCols: [0]
  };
}

function displayCell(value, index, built) {
  const col = built.columns[index];
  if (built.dateCols?.includes(index) && /^\d{4}-\d{2}-\d{2}$/.test(value)) return escapeHtml(formatDate(value));
  if (built.monthCols?.includes(index) && /^\d{4}-\d{2}$/.test(value)) return escapeHtml(formatMonth(value));
  if (col.num && typeof value === 'number' && col.label !== 'Receipts') return formatMoney(value);
  return escapeHtml(value);
}

function render() {
  const list = filteredSales();
  const totals = list.reduce((t, s) => { addTotals(t, s); return t; }, { count: 0, gross: 0, discount: 0, net: 0 });
  const tax = taxValues(totals.net);

  document.getElementById('statNet').textContent = formatMoney(totals.net);
  document.getElementById('statDiscount').textContent = formatMoney(totals.discount);
  document.getElementById('statCount').textContent = totals.count.toLocaleString('en-PH');
  document.getElementById('statTaxLabel').textContent = taxType() === 'vat' ? 'Output VAT (12%)' : 'Percentage Tax (3%)';
  document.getElementById('statTax').textContent = formatMoney(taxType() === 'vat' ? tax.vat : tax.ptax);

  const missing = list.filter((s) => !s.receipt_no).length;
  const note = document.getElementById('missingReceiptNote');
  note.classList.toggle('hidden', missing === 0);
  note.textContent = `${missing} ${missing === 1 ? 'sale has' : 'sales have'} no POS receipt no. recorded (older or manually created walk-ins) - they are listed by Order # instead.`;

  const built = buildView(list);
  document.getElementById('birHead').innerHTML = `<tr>${built.columns
    .map((c) => `<th${c.num ? ' class="num"' : ''}>${escapeHtml(c.label)}</th>`).join('')}</tr>`;
  document.getElementById('birBody').innerHTML = built.rows.length
    ? built.rows.map((r) => `<tr>${r.map((v, i) => `<td${built.columns[i].num ? ' class="num"' : ''}>${displayCell(v, i, built)}</td>`).join('')}</tr>`).join('')
    : `<tr><td colspan="${built.columns.length}" class="muted">No walk-in sales in this period.</td></tr>`;
  document.getElementById('birFoot').innerHTML = built.rows.length
    ? `<tr>${built.total.map((v, i) => `<td${built.columns[i].num ? ' class="num"' : ''}>${displayCell(v, i, built)}</td>`).join('')}</tr>`
    : '';
}

function csvCell(value) {
  const text = typeof value === 'number' ? value.toFixed(2) : String(value ?? '');
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

// Header block (company, TIN, address, branch, period, tax type) then the view's table and its total.
function exportCsv() {
  const built = buildView(filteredSales());
  const warehouse = document.getElementById('warehouseSelect').value || 'All branches';
  const viewName = { journal: 'Sales Journal', daily: 'Daily Sales Summary', monthly: 'Monthly Sales Totals' }[view];
  const receiptsIndex = built.columns.findIndex((c) => c.label === 'Receipts');
  const cells = (row) => row.map((v, i) => (i === receiptsIndex ? String(v) : csvCell(v))).join(',');

  const lines = [
    csvCell(companyInfo?.CompanyName || 'RS Pet Stop'),
    companyInfo?.TinNo ? csvCell(`TIN: ${companyInfo.TinNo}`) : null,
    companyInfo?.Address ? csvCell(`Address: ${companyInfo.Address}`) : null,
    csvCell(`${viewName} - Walk-in Sales`),
    csvCell(`Branch: ${warehouse}`),
    csvCell(`Period: ${rangeKeys.from} to ${rangeKeys.to}`),
    csvCell(`Tax type: ${document.getElementById('taxSelect').selectedOptions[0].textContent}`),
    '',
    built.columns.map((c) => csvCell(c.label)).join(','),
    ...built.rows.map(cells),
    built.rows.length ? cells(built.total) : null
  ].filter((l) => l !== null);

  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `bir-walkin-${view}-${rangeKeys.from}-to-${rangeKeys.to}.csv`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function fillWarehouseSelect() {
  const select = document.getElementById('warehouseSelect');
  const current = select.value;
  const names = [...new Set(sales.map((s) => s.warehouse_name).filter(Boolean))].sort();
  select.innerHTML = '<option value="">All branches</option>' +
    names.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');
  if (names.includes(current)) select.value = current;
}

async function loadReport() {
  const loadingEl = document.getElementById('birLoading');
  const errorEl = document.getElementById('birError');
  const resultsEl = document.getElementById('birResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const range = computeRange();
  rangeKeys = { from: toDateKey(range.from), to: toDateKey(range.to) };
  document.getElementById('periodLabel').textContent = range.label;

  const { data, error } = await supabaseClient.rpc('admin_get_bir_walkin_sales', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_date_from: rangeKeys.from,
    p_date_to: rangeKeys.to
  });

  loadingEl.classList.add('hidden');
  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }

  sales = Array.isArray(data) ? data : [];
  fillWarehouseSelect();
  render();
  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('BIR Sales Report');

  if (!session.isSuperUser) {
    document.getElementById('birLoading').classList.add('hidden');
    const errorEl = document.getElementById('birError');
    errorEl.textContent = 'Only a Super User can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  try {
    const saved = localStorage.getItem(TAX_KEY);
    if (saved === 'vat' || saved === 'nonvat') document.getElementById('taxSelect').value = saved;
  } catch (e) { /* storage blocked - keep the default */ }

  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.addEventListener('click', () => setPeriod(btn.dataset.period));
  });
  document.getElementById('applyRangeBtn').addEventListener('click', loadReport);
  document.getElementById('warehouseSelect').addEventListener('change', render);
  document.getElementById('taxSelect').addEventListener('change', () => {
    try { localStorage.setItem(TAX_KEY, taxType()); } catch (e) { /* ignore */ }
    render();
  });
  document.querySelectorAll('[data-view]').forEach((btn) => {
    btn.addEventListener('click', () => {
      view = btn.dataset.view;
      document.querySelectorAll('[data-view]').forEach((b) => b.classList.toggle('active', b === btn));
      render();
    });
  });
  document.getElementById('exportBtn').addEventListener('click', exportCsv);

  fetchCompanyInfo().then((info) => { companyInfo = info; }).catch(() => {});
  await loadReport();
})();
