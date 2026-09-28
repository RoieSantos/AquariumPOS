// Payment Methods report - per "under reports can you create me a new report for per payment type?
// i want to see all the payments and who is using bigger". Super users only (the RPCs re-check).
//
// admin_get_payment_method_report (supabase_payment_method_report.sql) returns one row per
// warehouse x online/walk-in x method for the date range; the scope / warehouse filters and the
// totals are applied here, so switching them doesn't re-query.
//
// Colour follows the method, never its rank: each method's slot comes from the Payment Methods
// master order (Cash first, then by name - admin_list_payment_methods), so GCash keeps its colour
// whatever the period or filter. Past the 8 categorical slots, methods fold into "Other".
let currentSession = null;
let period = 'month'; // 'today' | 'month' | 'prevmonth' | 'custom'
let reportRows = [];
let methodSlots = new Map(); // method code -> slot 1..8
let backfillRunning = false;

const MAX_SLOTS = 8;
const OTHER_KEY = '__other';
const UNRECORDED_KEY = '__unrecorded';

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

function formatPercent(fraction) {
  const pct = fraction * 100;
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
  if (period === 'today') {
    return { from: today, to: today, label: today.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' }) };
  }
  if (period === 'prevmonth') {
    const from = new Date(today.getFullYear(), today.getMonth() - 1, 1);
    const to = new Date(today.getFullYear(), today.getMonth(), 0);
    return { from, to, label: from.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }) };
  }
  if (period === 'custom') {
    const fromVal = document.getElementById('dateFrom').value;
    const toVal = document.getElementById('dateTo').value;
    const from = fromVal ? new Date(fromVal + 'T00:00:00') : today;
    const to = toVal ? new Date(toVal + 'T00:00:00') : today;
    const fmt = { month: 'short', day: 'numeric', year: 'numeric' };
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
    const range = computeRange();
    if (!document.getElementById('dateFrom').value) document.getElementById('dateFrom').value = toDateKey(new Date(range.from.getFullYear(), range.from.getMonth(), 1));
    if (!document.getElementById('dateTo').value) document.getElementById('dateTo').value = toDateKey(range.to);
    return; // waits for Apply
  }
  loadReport();
}

async function loadMethodSlots() {
  const { data, error } = await supabaseClient.rpc('admin_list_payment_methods', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) {
    console.error('admin_list_payment_methods failed:', error);
    return;
  }
  methodSlots = new Map();
  (data || []).forEach((m, index) => {
    if (index < MAX_SLOTS) methodSlots.set(m.code, index + 1);
  });
}

function seriesKey(code) {
  if (code === null || code === undefined) return UNRECORDED_KEY;
  return methodSlots.has(code) ? code : OTHER_KEY;
}

function seriesColor(key) {
  if (key === UNRECORDED_KEY) return 'url(#pmHatch)';
  if (key === OTHER_KEY) return 'var(--pm-other)';
  return `var(--pm-s${methodSlots.get(key)})`;
}

function swatchStyle(key) {
  if (key === UNRECORDED_KEY) return 'background: repeating-linear-gradient(45deg, var(--pm-other) 0 2px, transparent 2px 5px); border: 1px solid var(--pm-other);';
  return `background:${seriesColor(key)};`;
}

// Rows for the current scope/warehouse, merged per series (method, "Other" or "not recorded").
function aggregate() {
  const scope = document.getElementById('scopeSelect').value;
  const warehouse = document.getElementById('warehouseSelect').value;
  const bySeries = new Map();

  reportRows
    .filter((r) => r.method_code !== '__coverage')
    .filter((r) => scope === 'all' || (scope === 'walkin' ? r.is_walkin : !r.is_walkin))
    .filter((r) => !warehouse || r.warehouse_name === warehouse)
    .forEach((r) => {
      const key = seriesKey(r.method_code);
      const entry = bySeries.get(key) || {
        key,
        name: key === OTHER_KEY ? 'Other methods' : r.method_name,
        type: key === OTHER_KEY ? 'Mixed' : (key === UNRECORDED_KEY ? '-' : r.method_type),
        amount: 0,
        orders: 0
      };
      entry.amount += Number(r.amount) || 0;
      entry.orders += Number(r.order_count) || 0;
      bySeries.set(key, entry);
    });

  return [...bySeries.values()]
    .filter((s) => s.amount > 0)
    .sort((a, b) => {
      // "Method not recorded" always last - it isn't a method competing for the top.
      if (a.key === UNRECORDED_KEY) return 1;
      if (b.key === UNRECORDED_KEY) return -1;
      return b.amount - a.amount;
    });
}

function arcPath(cx, cy, rOuter, rInner, startAngle, endAngle) {
  // A lone full-circle slice can't be drawn as one arc - split it in two.
  if (endAngle - startAngle >= Math.PI * 2 - 1e-6) {
    const mid = startAngle + Math.PI;
    return arcPath(cx, cy, rOuter, rInner, startAngle, mid) + ' ' + arcPath(cx, cy, rOuter, rInner, mid, endAngle);
  }
  const pt = (r, a) => [cx + r * Math.sin(a), cy - r * Math.cos(a)];
  const large = endAngle - startAngle > Math.PI ? 1 : 0;
  const [x1, y1] = pt(rOuter, startAngle);
  const [x2, y2] = pt(rOuter, endAngle);
  const [x3, y3] = pt(rInner, endAngle);
  const [x4, y4] = pt(rInner, startAngle);
  return `M${x1},${y1} A${rOuter},${rOuter} 0 ${large} 1 ${x2},${y2} L${x3},${y3} A${rInner},${rInner} 0 ${large} 0 ${x4},${y4} Z`;
}

function renderDonut(series, total) {
  const svg = document.getElementById('donut');
  const hatch = `
    <defs>
      <pattern id="pmHatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <rect width="6" height="6" style="fill:var(--pm-surface)"></rect>
        <rect width="2.5" height="6" style="fill:var(--pm-other)"></rect>
      </pattern>
    </defs>`;

  if (total <= 0) {
    svg.innerHTML = `${hatch}<circle cx="100" cy="100" r="76" style="fill:none; stroke:var(--pm-empty); stroke-width:36"></circle>`;
    document.getElementById('donutCenterValue').textContent = formatMoney(0);
    document.getElementById('donutCenterLabel').textContent = 'no payments';
    document.getElementById('donutLegend').innerHTML = '';
    return;
  }

  let angle = 0;
  const slices = series.map((s) => {
    const sweep = (s.amount / total) * Math.PI * 2;
    const path = arcPath(100, 100, 94, 58, angle, angle + sweep);
    angle += sweep;
    return `<path class="pm-slice" d="${path}" style="fill:${seriesColor(s.key)}" data-key="${escapeHtml(s.key)}"></path>`;
  });
  svg.innerHTML = hatch + slices.join('');

  document.getElementById('donutCenterValue').textContent = formatMoney(total);
  document.getElementById('donutCenterLabel').textContent = 'collected';

  document.getElementById('donutLegend').innerHTML = series
    .map((s) => `
      <div class="pm-legend-row" data-key="${escapeHtml(s.key)}">
        <span class="pm-swatch" style="${swatchStyle(s.key)}"></span>
        <span class="pm-legend-name">${escapeHtml(s.name)}</span>
        <span class="pm-legend-pct">${formatPercent(s.amount / total)}</span>
      </div>
    `)
    .join('');

  wireDonutHover(series, total);
}

function wireDonutHover(series, total) {
  const wrap = document.getElementById('donutWrap');
  const tooltip = document.getElementById('donutTooltip');
  const byKey = new Map(series.map((s) => [s.key, s]));

  const highlight = (key) => {
    document.querySelectorAll('.pm-slice').forEach((el) => el.classList.toggle('pm-dim', key !== null && el.dataset.key !== key));
    document.querySelectorAll('.pm-legend-row').forEach((el) => el.classList.toggle('pm-dim', key !== null && el.dataset.key !== key));
  };

  document.querySelectorAll('.pm-slice').forEach((el) => {
    el.addEventListener('mousemove', (e) => {
      const s = byKey.get(el.dataset.key);
      if (!s) return;
      highlight(s.key);
      tooltip.innerHTML = `
        <div class="pm-tooltip-title"><span class="pm-swatch" style="${swatchStyle(s.key)}"></span>${escapeHtml(s.name)}</div>
        <div><strong>${formatMoney(s.amount)}</strong> · ${formatPercent(s.amount / total)}</div>
        <div class="muted">${s.orders} ${s.orders === 1 ? 'order' : 'orders'}</div>`;
      tooltip.classList.remove('hidden');
      const box = wrap.getBoundingClientRect();
      tooltip.style.left = `${Math.min(e.clientX - box.left + 12, box.width - tooltip.offsetWidth - 4)}px`;
      tooltip.style.top = `${e.clientY - box.top + 12}px`;
    });
    el.addEventListener('mouseleave', () => {
      tooltip.classList.add('hidden');
      highlight(null);
    });
  });

  document.querySelectorAll('.pm-legend-row').forEach((el) => {
    el.addEventListener('mouseenter', () => highlight(el.dataset.key));
    el.addEventListener('mouseleave', () => highlight(null));
  });
}

function renderTable(series, total) {
  const tbody = document.getElementById('pmTableBody');
  if (series.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No payments in this period.</td></tr>';
    return;
  }
  const top = Math.max(...series.map((s) => s.amount));
  tbody.innerHTML = series
    .map((s) => `
      <tr>
        <td><span class="pm-swatch" style="${swatchStyle(s.key)}"></span>${escapeHtml(s.name)}</td>
        <td>${escapeHtml(s.type || '')}</td>
        <td style="text-align:right;">${formatMoney(s.amount)}</td>
        <td>
          <div class="pm-share">
            <div class="pm-share-track"><div class="pm-share-fill" style="width:${(s.amount / top) * 100}%; ${swatchStyle(s.key)}"></div></div>
            <span class="pm-share-pct">${formatPercent(s.amount / total)}</span>
          </div>
        </td>
        <td style="text-align:right;">${s.orders}</td>
        <td style="text-align:right;">${formatMoney(s.orders ? s.amount / s.orders : 0)}</td>
      </tr>
    `)
    .join('');
}

function render() {
  const series = aggregate();
  const total = series.reduce((sum, s) => sum + s.amount, 0);
  const methods = series.filter((s) => s.key !== UNRECORDED_KEY);

  document.getElementById('statTotal').textContent = formatMoney(total);
  document.getElementById('statTop').textContent = methods.length
    ? `${methods[0].name} (${formatPercent(methods[0].amount / total)})`
    : 'No payments yet';
  document.getElementById('statCount').textContent = series.reduce((sum, s) => sum + s.orders, 0);

  renderDonut(series, total);
  renderTable(series, total);
}

function fillWarehouseSelect() {
  const select = document.getElementById('warehouseSelect');
  const current = select.value;
  const names = [...new Set(reportRows.map((r) => r.warehouse_name).filter(Boolean))].sort();
  select.innerHTML = '<option value="">All warehouses</option>' +
    names.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');
  if (names.includes(current)) select.value = current;
}

function renderCoverage() {
  const coverage = reportRows.find((r) => r.method_code === '__coverage');
  const missing = Number(coverage?.order_count) || 0;
  const note = document.getElementById('coverageNote');
  if (missing > 0 && !backfillRunning) {
    document.getElementById('coverageText').textContent =
      `${missing} ${missing === 1 ? 'order' : 'orders'} in this period ${missing === 1 ? 'has' : 'have'} no payment details loaded yet, so the totals are incomplete.`;
    note.classList.remove('hidden');
  } else if (!backfillRunning) {
    note.classList.add('hidden');
  }
}

async function loadReport() {
  const loadingEl = document.getElementById('pmLoading');
  const errorEl = document.getElementById('pmError');
  const resultsEl = document.getElementById('pmResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const range = computeRange();
  document.getElementById('periodLabel').textContent = range.label;

  const { data, error } = await supabaseClient.rpc('admin_get_payment_method_report', {
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
  fillWarehouseSelect();
  renderCoverage();
  render();
  resultsEl.classList.remove('hidden');
}

// Pancake pages newest-first, 100 orders per call, one call per request (stays under the API
// statement timeout). Stops at an empty/short page.
async function runBackfill() {
  if (backfillRunning) return;
  backfillRunning = true;
  const btn = document.getElementById('backfillBtn');
  const text = document.getElementById('coverageText');
  btn.disabled = true;

  let page = 1;
  let failed = null;
  try {
    for (; page <= 500; page++) {
      text.textContent = `Loading payment history... page ${page}`;
      const { data, error } = await supabaseClient.rpc('admin_backfill_order_payments_step', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_page: page
      });
      if (error) {
        failed = error.message;
        break;
      }
      const row = Array.isArray(data) ? data[0] : data;
      const oldest = row?.oldest_order_date
        ? new Date(row.oldest_order_date + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
        : null;
      text.textContent = `Loading payment history... page ${page}${oldest ? ` · back to ${oldest}` : ''}`;
      if (!row || (Number(row.orders_seen) || 0) < 100) break;
    }
  } finally {
    backfillRunning = false;
    btn.disabled = false;
  }

  if (failed) {
    text.textContent = `Stopped on page ${page}: ${failed}. Click again to retry.`;
    return;
  }
  await loadReport();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payment Methods Report');

  if (!session.isSuperUser) {
    document.getElementById('pmLoading').classList.add('hidden');
    const errorEl = document.getElementById('pmError');
    errorEl.textContent = 'Only a Super User can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.addEventListener('click', () => setPeriod(btn.dataset.period));
  });
  document.getElementById('applyRangeBtn').addEventListener('click', loadReport);
  document.getElementById('scopeSelect').addEventListener('change', render);
  document.getElementById('warehouseSelect').addEventListener('change', render);
  document.getElementById('backfillBtn').addEventListener('click', runBackfill);

  await loadMethodSlots();
  await loadReport();
})();
