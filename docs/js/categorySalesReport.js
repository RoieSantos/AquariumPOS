// Category Sales report - per "can you create me a report for accessories or per category".
//
// admin_get_category_sales_report (supabase_category_sales_report.sql) returns one row per
// warehouse x online/walk-in x category x item x variant for the date range. Everything else -
// the scope / warehouse filters, the category ranking, drilling into one category (Per Item /
// Per Variant) and the rank-by switch - happens here, so none of it re-queries.
//
// The chosen category is kept in the URL (?category=ACCESSORIES) so a drill-down can be
// bookmarked or shared.
let currentSession = null;
let period = 'month'; // 'today' | 'month' | 'prevmonth' | '90d' | 'year' | 'custom'
let view = 'items'; // 'items' | 'variants' (inside a category)
let reportRows = [];

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

function setView(value) {
  view = value;
  document.querySelectorAll('[data-view]').forEach((btn) => {
    btn.className = `btn btn-${btn.dataset.view === value ? 'primary' : 'secondary'} btn-sm`;
  });
  render();
}

function selectedCategory() {
  return document.getElementById('categorySelect').value;
}

function selectCategory(code) {
  const select = document.getElementById('categorySelect');
  select.value = code;
  const url = new URL(window.location.href);
  if (code) url.searchParams.set('category', code);
  else url.searchParams.delete('category');
  history.replaceState(null, '', url);
  render();
}

function filteredRows() {
  const scope = document.getElementById('scopeSelect').value;
  const warehouse = document.getElementById('warehouseSelect').value;
  return reportRows
    .filter((r) => scope === 'all' || (scope === 'walkin' ? r.is_walkin : !r.is_walkin))
    .filter((r) => !warehouse || r.warehouse_name === warehouse);
}

// Rolls rows up by keyFn; init(row) gives a new entry's label fields. `members` collects the
// item|variant keys inside each entry.
function rollUp(rows, keyFn, init) {
  const byKey = new Map();
  rows.forEach((r) => {
    const key = keyFn(r);
    let entry = byKey.get(key);
    if (!entry) {
      entry = { ...init(r), qty: 0, revenue: 0, orders: 0, members: new Set() };
      byKey.set(key, entry);
    }
    entry.qty += Number(r.qty_sold) || 0;
    entry.revenue += Number(r.revenue) || 0;
    entry.orders += Number(r.order_count) || 0;
    entry.members.add(`${r.item_code}|${r.variant_id || ''}`);
  });
  return [...byKey.values()];
}

function shareCell(value, top, total) {
  return `
    <div class="pm-share">
      <div class="pm-share-track"><div class="pm-share-fill" style="width:${top > 0 ? Math.max(0, value / top) * 100 : 0}%; background:var(--pm-s1);"></div></div>
      <span class="pm-share-pct">${formatPercent(total > 0 ? value / total : 0)}</span>
    </div>`;
}

function itemCell(name, code) {
  return `${escapeHtml(name)}${code && code !== name ? `<div class="muted" style="font-size:12px;">${escapeHtml(code)}</div>` : ''}`;
}

function renderCategories(rows, rankKey) {
  const cats = rollUp(rows, (r) => r.category_code, (r) => ({ code: r.category_code, name: r.category_name }));
  cats.forEach((c) => { c.items = new Set([...c.members].map((m) => m.split('|')[0])).size; });
  cats.sort((a, b) => b[rankKey] - a[rankKey]);

  document.getElementById('csTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Category</th>
      <th style="text-align:right;">Revenue</th>
      <th style="text-align:right;">Units</th>
      <th style="min-width:160px;">Share</th>
      <th style="text-align:right;">Items Sold</th>
    </tr>`;
  const tbody = document.getElementById('csTableBody');
  if (cats.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No sales in this period.</td></tr>';
    return cats;
  }
  const top = Math.max(...cats.map((c) => c[rankKey]));
  const total = cats.reduce((sum, c) => sum + c[rankKey], 0);
  tbody.innerHTML = cats
    .map((c, i) => `
      <tr class="cs-row-link" data-category="${escapeHtml(c.code)}" tabindex="0" title="See items in ${escapeHtml(c.name)}">
        <td>${i + 1}</td>
        <td><a href="#" class="cs-link">${escapeHtml(c.name)}</a>${c.name !== c.code ? `<div class="muted" style="font-size:12px;">${escapeHtml(c.code)}</div>` : ''}</td>
        <td style="text-align:right;">${formatMoney(c.revenue)}</td>
        <td style="text-align:right;">${formatQty(c.qty)}</td>
        <td>${shareCell(c[rankKey], top, total)}</td>
        <td style="text-align:right;">${c.items}</td>
      </tr>`)
    .join('');

  tbody.querySelectorAll('.cs-row-link').forEach((tr) => {
    const open = (e) => { e.preventDefault(); selectCategory(tr.dataset.category); };
    tr.addEventListener('click', open);
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') open(e); });
  });
  return cats;
}

function renderCategoryDetail(rows, rankKey) {
  const perVariant = view === 'variants';
  const entries = perVariant
    ? rollUp(rows, (r) => `${r.item_code}|${r.variant_id || ''}`, (r) => ({
        code: r.item_code, name: r.item_name, variant: r.variant_name, sku: r.variant_sku, hasVariant: !!r.variant_id
      }))
    : rollUp(rows, (r) => r.item_code, (r) => ({ code: r.item_code, name: r.item_name }));
  entries.sort((a, b) => b[rankKey] - a[rankKey] || b.qty - a.qty);

  // Orders are exact per variant (each order sits in one warehouse / scope); merged per item they
  // would double-count an order holding two variants of it, so the item view shows variants instead.
  document.getElementById('csTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Item</th>
      ${perVariant ? '<th>Variant</th><th>SKU</th>' : ''}
      <th style="text-align:right;">Revenue</th>
      <th style="text-align:right;">Units</th>
      <th style="min-width:160px;">Share</th>
      <th style="text-align:right;">${perVariant ? 'Orders' : 'Variants Sold'}</th>
    </tr>`;
  const cols = perVariant ? 8 : 6;
  const tbody = document.getElementById('csTableBody');
  if (entries.length === 0) {
    tbody.innerHTML = `<tr><td colspan="${cols}" class="muted">No sales in this category for this period.</td></tr>`;
    return entries;
  }
  const top = Math.max(...entries.map((e) => e[rankKey]));
  const total = entries.reduce((sum, e) => sum + e[rankKey], 0);
  tbody.innerHTML = entries
    .map((e, i) => {
      const variantsSold = [...e.members].filter((m) => !m.endsWith('|')).length;
      return `
      <tr>
        <td>${i + 1}</td>
        <td>${itemCell(e.name, e.code)}</td>
        ${perVariant ? `<td>${e.hasVariant ? escapeHtml(e.variant || '-') : '<span class="muted">No variant</span>'}</td><td>${escapeHtml(e.sku || '-')}</td>` : ''}
        <td style="text-align:right;">${formatMoney(e.revenue)}</td>
        <td style="text-align:right;">${formatQty(e.qty)}</td>
        <td>${shareCell(e[rankKey], top, total)}</td>
        <td style="text-align:right;">${perVariant ? e.orders : (variantsSold || '-')}</td>
      </tr>`;
    })
    .join('');
  return entries;
}

function render() {
  const rankKey = document.getElementById('rankSelect').value;
  const category = selectedCategory();
  const rows = filteredRows();
  const inCategory = category ? rows.filter((r) => r.category_code === category) : rows;

  const revenue = inCategory.reduce((sum, r) => sum + (Number(r.revenue) || 0), 0);
  const units = inCategory.reduce((sum, r) => sum + (Number(r.qty_sold) || 0), 0);
  document.getElementById('statRevenue').textContent = formatMoney(revenue);
  document.getElementById('statUnits').textContent = formatQty(units);

  document.getElementById('backBtn').classList.toggle('hidden', !category);
  document.getElementById('viewToggle').classList.toggle('hidden', !category);

  if (category) {
    const name = reportRows.find((r) => r.category_code === category)?.category_name || category;
    document.getElementById('tableTitle').textContent = name;
    document.getElementById('statRevenueLabel').textContent = `${name} Revenue`;
    document.getElementById('statTopLabel').textContent = view === 'variants' ? 'Top Variant' : 'Top Item';
    const entries = renderCategoryDetail(inCategory, rankKey);
    const best = entries[0];
    document.getElementById('statTop').textContent = best
      ? (view === 'variants' && best.variant ? `${best.name} - ${best.variant}` : best.name)
      : 'No sales yet';
  } else {
    document.getElementById('tableTitle').textContent = 'Categories';
    document.getElementById('statRevenueLabel').textContent = 'Revenue';
    document.getElementById('statTopLabel').textContent = 'Top Category';
    const cats = renderCategories(rows, rankKey);
    document.getElementById('statTop').textContent = cats.length
      ? `${cats[0].name} (${formatPercent(cats[0][rankKey] / cats.reduce((s, c) => s + c[rankKey], 0))})`
      : 'No sales yet';
  }
}

function fillSelect(id, options, allLabel, current) {
  const select = document.getElementById(id);
  select.innerHTML = `<option value="">${allLabel}</option>` +
    options.map((o) => `<option value="${escapeHtml(o.value)}">${escapeHtml(o.label)}</option>`).join('');
  select.value = options.some((o) => o.value === current) ? current : '';
}

async function loadReport() {
  const loadingEl = document.getElementById('csLoading');
  const errorEl = document.getElementById('csError');
  const resultsEl = document.getElementById('csResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const range = computeRange();
  document.getElementById('periodLabel').textContent = range.label;

  const { data, error } = await supabaseClient.rpc('admin_get_category_sales_report', {
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
  const warehouses = [...new Set(reportRows.map((r) => r.warehouse_name).filter(Boolean))].sort();
  fillSelect('warehouseSelect', warehouses.map((w) => ({ value: w, label: w })), 'All warehouses', document.getElementById('warehouseSelect').value);

  // Keep the chosen category selectable even when it sold nothing this period.
  const cats = new Map(reportRows.map((r) => [r.category_code, r.category_name]));
  const wanted = selectedCategory() || new URL(window.location.href).searchParams.get('category') || '';
  if (wanted && !cats.has(wanted)) cats.set(wanted, wanted);
  fillSelect('categorySelect',
    [...cats].map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label)),
    'All categories', wanted);

  render();
  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Category Sales Report');

  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.addEventListener('click', () => setPeriod(btn.dataset.period));
  });
  document.querySelectorAll('[data-view]').forEach((btn) => {
    btn.addEventListener('click', () => setView(btn.dataset.view));
  });
  document.getElementById('applyRangeBtn').addEventListener('click', loadReport);
  document.getElementById('backBtn').addEventListener('click', () => selectCategory(''));
  document.getElementById('categorySelect').addEventListener('change', (e) => selectCategory(e.target.value));
  ['scopeSelect', 'warehouseSelect', 'rankSelect'].forEach((id) => {
    document.getElementById(id).addEventListener('change', render);
  });

  await loadReport();
})();
