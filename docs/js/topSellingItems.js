// Top Selling Items report page logic (any active staff - matches reports.js, no super-user
// gate). Ranks items by quantity sold over a Daily/Weekly/Monthly period, navigated via an
// anchor date shifted by Prev/Next. Day/week/month bucketing is entirely client-side - the RPC
// (admin_get_top_selling_items) just takes a plain p_date_from/p_date_to range, same shape as
// admin_get_order_confirmation_timing.
let currentSession = null;
let granularity = 'daily'; // 'daily' | 'weekly' | 'monthly'
let anchorDate = new Date();
let topN = 10;

function toDateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function formatMoney(value) {
  const amount = Number(value) || 0;
  return '₱' + amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Monday-start week, matching the Order Timing Dashboard / Postgres date_trunc('week', ...) convention.
function startOfWeek(date) {
  const result = new Date(date);
  const day = result.getDay(); // 0 = Sunday
  const diffToMonday = day === 0 ? -6 : 1 - day;
  result.setDate(result.getDate() + diffToMonday);
  return result;
}

function computeRange() {
  if (granularity === 'daily') {
    const from = new Date(anchorDate);
    return { from, to: from, label: from.toLocaleDateString(undefined, { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' }) };
  }

  if (granularity === 'weekly') {
    const from = startOfWeek(anchorDate);
    const to = new Date(from);
    to.setDate(to.getDate() + 6);
    const fromLabel = from.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    const toLabel = to.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
    return { from, to, label: `Week of ${fromLabel} - ${toLabel}` };
  }

  // monthly
  const from = new Date(anchorDate.getFullYear(), anchorDate.getMonth(), 1);
  const to = new Date(anchorDate.getFullYear(), anchorDate.getMonth() + 1, 0);
  return { from, to, label: from.toLocaleDateString(undefined, { month: 'long', year: 'numeric' }) };
}

function shiftAnchor(direction) {
  const next = new Date(anchorDate);
  if (granularity === 'daily') next.setDate(next.getDate() + direction);
  else if (granularity === 'weekly') next.setDate(next.getDate() + direction * 7);
  else next.setMonth(next.getMonth() + direction);
  anchorDate = next;
}

function setGranularity(value) {
  granularity = value;
  document.getElementById('granularityDailyBtn').className = `btn btn-${value === 'daily' ? 'primary' : 'secondary'} btn-sm`;
  document.getElementById('granularityWeeklyBtn').className = `btn btn-${value === 'weekly' ? 'primary' : 'secondary'} btn-sm`;
  document.getElementById('granularityMonthlyBtn').className = `btn btn-${value === 'monthly' ? 'primary' : 'secondary'} btn-sm`;
  loadItems();
}

function renderChart(rows) {
  const container = document.getElementById('itemRankChart');
  if (!rows || rows.length === 0) {
    container.innerHTML = '<p class="muted">No sales in this period.</p>';
    return;
  }

  const max = Math.max(1, ...rows.map((r) => Number(r.qty_sold) || 0));
  container.innerHTML = rows
    .map((r) => {
      const qty = Number(r.qty_sold) || 0;
      const widthPct = Math.round((qty / max) * 100);
      const label = r.item_name || r.item_code || 'Unknown item';
      return `
        <div class="item-rank-row" title="${label}: ${qty} sold">
          <div class="item-rank-label">${label}</div>
          <div class="item-rank-bar-track"><div class="item-rank-bar-fill" style="width:${widthPct}%;"></div></div>
          <div class="item-rank-count">${qty} sold</div>
        </div>
      `;
    })
    .join('');
}

function renderTable(rows) {
  const tbody = document.getElementById('itemsTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No sales in this period.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((r, index) => `
      <tr>
        <td>${index + 1}</td>
        <td>${r.item_code || ''}</td>
        <td>${r.item_name || ''}</td>
        <td>${r.category_code || ''}</td>
        <td style="text-align:right;">${Number(r.qty_sold) || 0}</td>
        <td style="text-align:right;">${formatMoney(r.revenue)}</td>
        <td style="text-align:right;">${r.order_count || 0}</td>
      </tr>
    `)
    .join('');
}

async function loadItems() {
  const loadingEl = document.getElementById('itemsLoading');
  const errorEl = document.getElementById('itemsError');
  const resultsEl = document.getElementById('itemsResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  resultsEl.classList.add('hidden');

  const range = computeRange();
  document.getElementById('periodLabel').textContent = range.label;

  const todayKey = toDateKey(new Date());
  document.getElementById('nextPeriodBtn').disabled = toDateKey(range.to) >= todayKey;

  const { data, error } = await supabaseClient.rpc('admin_get_top_selling_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_date_from: toDateKey(range.from),
    p_date_to: toDateKey(range.to),
    p_limit: topN
  });

  loadingEl.classList.add('hidden');

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const rows = data || [];
  const totalCount = rows[0]?.total_count || 0;

  document.getElementById('statItemsSold').textContent = totalCount;
  document.getElementById('statTopItem').textContent = rows.length > 0
    ? `${rows[0].item_name || rows[0].item_code} (${Number(rows[0].qty_sold) || 0} sold)`
    : 'No sales yet';

  renderChart(rows);
  renderTable(rows);

  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Top Selling Items');

  document.getElementById('granularityDailyBtn').addEventListener('click', () => setGranularity('daily'));
  document.getElementById('granularityWeeklyBtn').addEventListener('click', () => setGranularity('weekly'));
  document.getElementById('granularityMonthlyBtn').addEventListener('click', () => setGranularity('monthly'));

  document.getElementById('prevPeriodBtn').addEventListener('click', () => { shiftAnchor(-1); loadItems(); });
  document.getElementById('nextPeriodBtn').addEventListener('click', () => { shiftAnchor(1); loadItems(); });

  document.getElementById('topNSelect').addEventListener('change', (e) => {
    topN = Number(e.target.value) || 10;
    loadItems();
  });

  await loadItems();
})();
