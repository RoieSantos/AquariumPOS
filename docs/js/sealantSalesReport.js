// Sealant Sales report - per "can you create me a report to see what is the best selling aquarium
// sealant? the sealant is per variant". Black / Clear sealant are variants of each aquarium / sump.
//
// admin_get_sealant_sales_report (supabase_sealant_sales_report.sql) returns one row per
// warehouse x online/walk-in x product x sealant for the date range; the scope / warehouse /
// category filters, the two views and the ranking are applied here, so switching them doesn't
// re-query.
let currentSession = null;
let period = 'year'; // 'month' | 'prevmonth' | '90d' | 'year' | 'custom'
let view = 'variants'; // 'variants' | 'products'
let reportRows = [];

const SEALANTS = ['Black', 'Clear'];

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

function swatch(sealant) {
  return `<span class="ss-swatch ss-${sealant === 'Black' ? 'black' : 'clear'}"></span>`;
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
    if (!document.getElementById('dateFrom').value) document.getElementById('dateFrom').value = toDateKey(new Date(today.getFullYear(), 0, 1));
    if (!document.getElementById('dateTo').value) document.getElementById('dateTo').value = toDateKey(today);
    return; // waits for Apply
  }
  loadReport();
}

function setView(value) {
  view = value;
  document.querySelectorAll('[data-view]').forEach((btn) => {
    btn.className = `btn btn-${btn.dataset.view === value ? 'primary' : 'secondary'} btn-sm`;
  });
  render();
}

function filteredRows() {
  const scope = document.getElementById('scopeSelect').value;
  const warehouse = document.getElementById('warehouseSelect').value;
  const category = document.getElementById('categorySelect').value;
  return reportRows
    .filter((r) => scope === 'all' || (scope === 'walkin' ? r.is_walkin : !r.is_walkin))
    .filter((r) => !warehouse || r.warehouse_name === warehouse)
    .filter((r) => !category || (r.category_code || '(No category)') === category);
}

// One entry per product x sealant (merged across warehouses / online / walk-in).
function aggregateVariants(rows) {
  const byKey = new Map();
  rows.forEach((r) => {
    const key = `${r.item_code}|${r.sealant}`;
    const entry = byKey.get(key) || {
      itemCode: r.item_code, itemName: r.item_name, category: r.category_code,
      sealant: r.sealant, sku: r.variant_sku, qty: 0, revenue: 0, orders: 0
    };
    entry.qty += Number(r.qty_sold) || 0;
    entry.revenue += Number(r.revenue) || 0;
    entry.orders += Number(r.order_count) || 0;
    if (!entry.sku && r.variant_sku) entry.sku = r.variant_sku;
    byKey.set(key, entry);
  });
  return [...byKey.values()];
}

// One entry per product, Black and Clear side by side.
function aggregateProducts(variants) {
  const byItem = new Map();
  variants.forEach((v) => {
    const entry = byItem.get(v.itemCode) || {
      itemCode: v.itemCode, itemName: v.itemName, category: v.category,
      Black: { qty: 0, revenue: 0 }, Clear: { qty: 0, revenue: 0 }, qty: 0, revenue: 0
    };
    entry[v.sealant].qty += v.qty;
    entry[v.sealant].revenue += v.revenue;
    entry.qty += v.qty;
    entry.revenue += v.revenue;
    byItem.set(v.itemCode, entry);
  });
  return [...byItem.values()];
}

function renderSplit(totals, grand) {
  const bar = document.getElementById('splitBar');
  const legend = document.getElementById('splitLegend');
  if (grand <= 0) {
    bar.innerHTML = '<div class="ss-split-empty"></div>';
    legend.innerHTML = '<span class="muted">No sealant sales in this period.</span>';
    return;
  }
  bar.innerHTML = SEALANTS
    .filter((s) => totals[s].qty > 0)
    .map((s) => `<div class="ss-split-seg ss-${s.toLowerCase()}" style="flex-grow:${totals[s].qty};" title="${s} sealant: ${formatQty(totals[s].qty)} units (${formatPercent(totals[s].qty / grand)})"></div>`)
    .join('');
  legend.innerHTML = SEALANTS
    .map((s) => `
      <div class="ss-split-legend-row">
        ${swatch(s)}<span>${s} sealant</span>
        <strong>${formatPercent(totals[s].qty / grand)}</strong>
        <span class="muted">${formatQty(totals[s].qty)} units · ${formatMoney(totals[s].revenue)}</span>
      </div>`)
    .join('');
}

function shareCell(value, top, total, sealant) {
  return `
    <div class="pm-share">
      <div class="pm-share-track"><div class="pm-share-fill ss-${sealant === 'Black' ? 'black' : 'clear'}" style="width:${top > 0 ? (value / top) * 100 : 0}%;"></div></div>
      <span class="pm-share-pct">${formatPercent(total > 0 ? value / total : 0)}</span>
    </div>`;
}

function renderVariantTable(variants, rankKey) {
  document.getElementById('ssTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Product</th>
      <th>Sealant</th>
      <th>Variant SKU</th>
      <th style="text-align:right;">Units</th>
      <th style="min-width:160px;">Share</th>
      <th style="text-align:right;">Revenue</th>
      <th style="text-align:right;">Orders</th>
    </tr>`;
  const tbody = document.getElementById('ssTableBody');
  if (variants.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No sealant sales in this period.</td></tr>';
    return;
  }
  const top = Math.max(...variants.map((v) => v[rankKey]));
  const total = variants.reduce((sum, v) => sum + v[rankKey], 0);
  tbody.innerHTML = variants
    .map((v, i) => `
      <tr>
        <td>${i + 1}</td>
        <td>${escapeHtml(v.itemName)}<div class="muted" style="font-size:12px;">${escapeHtml(v.itemCode)}${v.category ? ' · ' + escapeHtml(v.category) : ''}</div></td>
        <td style="white-space:nowrap;">${swatch(v.sealant)}${escapeHtml(v.sealant)}</td>
        <td>${escapeHtml(v.sku || '-')}</td>
        <td style="text-align:right;">${formatQty(v.qty)}</td>
        <td>${shareCell(v[rankKey], top, total, v.sealant)}</td>
        <td style="text-align:right;">${formatMoney(v.revenue)}</td>
        <td style="text-align:right;">${v.orders}</td>
      </tr>`)
    .join('');
}

function renderProductTable(products, rankKey) {
  document.getElementById('ssTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Product</th>
      <th style="text-align:right;">${swatch('Black')}Black</th>
      <th style="text-align:right;">${swatch('Clear')}Clear</th>
      <th style="text-align:right;">Total ${rankKey === 'qty' ? 'Units' : 'Revenue'}</th>
      <th style="min-width:180px;">Black vs Clear</th>
      <th>Preferred</th>
    </tr>`;
  const tbody = document.getElementById('ssTableBody');
  if (products.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No sealant sales in this period.</td></tr>';
    return;
  }
  const fmt = rankKey === 'qty' ? formatQty : formatMoney;
  tbody.innerHTML = products
    .map((p, i) => {
      const black = p.Black[rankKey];
      const clear = p.Clear[rankKey];
      const sum = black + clear;
      const preferred = black === clear ? 'Even' : (black > clear ? 'Black' : 'Clear');
      return `
      <tr>
        <td>${i + 1}</td>
        <td>${escapeHtml(p.itemName)}<div class="muted" style="font-size:12px;">${escapeHtml(p.itemCode)}${p.category ? ' · ' + escapeHtml(p.category) : ''}</div></td>
        <td style="text-align:right;">${fmt(black)}</td>
        <td style="text-align:right;">${fmt(clear)}</td>
        <td style="text-align:right;"><strong>${fmt(sum)}</strong></td>
        <td>
          <div class="ss-split-bar ss-split-bar-sm">
            ${black > 0 ? `<div class="ss-split-seg ss-black" style="flex-grow:${black};"></div>` : ''}
            ${clear > 0 ? `<div class="ss-split-seg ss-clear" style="flex-grow:${clear};"></div>` : ''}
            ${sum <= 0 ? '<div class="ss-split-empty"></div>' : ''}
          </div>
          <div class="muted" style="font-size:12px;">${sum > 0 ? `${formatPercent(black / sum)} black · ${formatPercent(clear / sum)} clear` : '-'}</div>
        </td>
        <td style="white-space:nowrap;">${preferred === 'Even' ? 'Even' : swatch(preferred) + preferred}</td>
      </tr>`;
    })
    .join('');
}

function render() {
  const rankKey = document.getElementById('rankSelect').value;
  const variants = aggregateVariants(filteredRows());

  const totals = { Black: { qty: 0, revenue: 0 }, Clear: { qty: 0, revenue: 0 } };
  variants.forEach((v) => {
    totals[v.sealant].qty += v.qty;
    totals[v.sealant].revenue += v.revenue;
  });
  const grand = totals.Black.qty + totals.Clear.qty;

  SEALANTS.forEach((s) => {
    document.getElementById(`stat${s}`).textContent = grand > 0
      ? `${formatQty(totals[s].qty)} units (${formatPercent(totals[s].qty / grand)})`
      : '0 units';
  });

  variants.sort((a, b) => b[rankKey] - a[rankKey] || b.qty - a.qty);
  document.getElementById('statTop').innerHTML = variants.length
    ? `${swatch(variants[0].sealant)}${escapeHtml(variants[0].itemName)} - ${escapeHtml(variants[0].sealant)}`
    : 'No sales yet';

  renderSplit(totals, grand);

  if (view === 'products') {
    const products = aggregateProducts(variants);
    products.sort((a, b) => b[rankKey] - a[rankKey]);
    renderProductTable(products, rankKey);
  } else {
    renderVariantTable(variants, rankKey);
  }
}

function fillSelect(id, values, allLabel) {
  const select = document.getElementById(id);
  const current = select.value;
  select.innerHTML = `<option value="">${allLabel}</option>` +
    values.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');
  if (values.includes(current)) select.value = current;
}

async function loadReport() {
  const loadingEl = document.getElementById('ssLoading');
  const errorEl = document.getElementById('ssError');
  const resultsEl = document.getElementById('ssResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const range = computeRange();
  document.getElementById('periodLabel').textContent = range.label;

  const { data, error } = await supabaseClient.rpc('admin_get_sealant_sales_report', {
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
  fillSelect('warehouseSelect', [...new Set(reportRows.map((r) => r.warehouse_name).filter(Boolean))].sort(), 'All warehouses');
  fillSelect('categorySelect', [...new Set(reportRows.map((r) => r.category_code || '(No category)'))].sort(), 'All categories');
  render();
  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Sealant Sales Report');

  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.addEventListener('click', () => setPeriod(btn.dataset.period));
  });
  document.querySelectorAll('[data-view]').forEach((btn) => {
    btn.addEventListener('click', () => setView(btn.dataset.view));
  });
  document.getElementById('applyRangeBtn').addEventListener('click', loadReport);
  ['scopeSelect', 'warehouseSelect', 'categorySelect', 'rankSelect'].forEach((id) => {
    document.getElementById(id).addEventListener('change', render);
  });

  await loadReport();
})();
