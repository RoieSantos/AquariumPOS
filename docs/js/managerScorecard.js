// Manager Scorecard - per "i want to have a view / report for my manager so i can say im gauging him/her with this
// numbers" (items on hand / sold / approximated inventory count).
//
// staff_get_manager_scorecard (sql/supabase_manager_scorecard.sql) returns ONE branch's month with no money-side
// figures (no costs, purchases, expenses, payroll or margin). A Store Manager always gets their own branch; a
// Super User can pick any branch. Each scorecard box below is scored against the GOALS here - change a number in
// GOALS to change what counts as on target / watch / below.
let currentSession = null;
let card = null;

const GOALS = {
  salesPacePct: { good: 100, warn: 90 },     // sales vs where the target says we should be by today, %
  growthPct: { good: 0, warn: -10 },         // sales vs the same days last month, %
  cashShort: { good: 100, warn: 1000 },      // total cash counted short in the month, ₱
  missingUnits: { good: 0, warn: 5 },        // units missing in counts + written off
  negativeItems: { good: 0, warn: 10 },      // items showing below-zero stock
  lateTransferDays: 3                        // a transfer not received after this many days counts as late
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function formatMoney(value) {
  const amount = Number(value) || 0;
  return (amount < 0 ? '-₱' : '₱') + Math.abs(amount).toLocaleString('en-PH', { maximumFractionDigits: 0 });
}

function formatQty(value) {
  return (Number(value) || 0).toLocaleString('en-PH', { maximumFractionDigits: 2 });
}

function pct(part, whole) {
  return whole ? Math.round((part / whole) * 100) : 0;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function shortDate(key) {
  const [, m, d] = String(key).split('-').map(Number);
  return `${MONTHS[m - 1]} ${d}`;
}

function manilaToday() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

function manilaMonthKey() {
  return manilaToday().slice(0, 7);
}

function shiftMonthKey(key, months) {
  const [y, m] = key.split('-').map(Number);
  const d = new Date(y, m - 1 + months, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function daysAgo(dateKey) {
  if (!dateKey) return 0;
  return Math.round((Date.parse(manilaToday() + 'T00:00:00Z') - Date.parse(dateKey + 'T00:00:00Z')) / 86400000);
}

function selectedMonthKey() {
  return document.getElementById('scMonth').value || manilaMonthKey();
}

function syncUrl() {
  const url = new URL(window.location.href);
  url.searchParams.set('month', selectedMonthKey());
  if (card && card.can_pick_branch) url.searchParams.set('branch', card.branch);
  window.history.replaceState(null, '', url.toString());
}

// Higher-is-better / lower-is-better scoring against a { good, warn } goal.
function scoreHigh(value, goal) {
  return value >= goal.good ? 'good' : value >= goal.warn ? 'warn' : 'bad';
}
function scoreLow(value, goal) {
  return value <= goal.good ? 'good' : value <= goal.warn ? 'warn' : 'bad';
}

function items() {
  return (card.items || []).map((x) => ({
    ...x,
    received: (Number(x.purchased) || 0) + (Number(x.produced) || 0) + (Number(x.transfer_in) || 0),
    lost: (Number(x.missing) || 0) + (Number(x.adj_minus) || 0)
  }));
}

function figures() {
  const isCurrent = card.through < card.month_end;
  const daysIn = Number(card.days_in_month);
  const daysDone = Number(card.days_elapsed);
  const sales = card.sales_days.reduce((s, d) => s + (Number(d.amount) || 0), 0);
  const target = Number(card.target) || 0;
  const expected = target * (daysDone / daysIn);
  const list = items();
  return {
    isCurrent, daysIn, daysDone, sales, target, expected,
    orders: card.sales_days.reduce((s, d) => s + (Number(d.count) || 0), 0),
    prevSame: Number(card.prev_same_days) || 0,
    prevFull: Number(card.prev_full_month) || 0,
    cashShort: -(Number(card.cash.short) || 0),
    cashOver: Number(card.cash.over) || 0,
    cashCounts: Number(card.cash.counts) || 0,
    shortDays: Number(card.cash.short_days) || 0,
    missing: list.reduce((s, x) => s + (Number(x.missing) || 0), 0),
    writtenOff: list.reduce((s, x) => s + (Number(x.adj_minus) || 0), 0),
    negative: list.filter((x) => x.closing < 0),
    late: card.transfer_gaps.filter((g) => g.to === card.branch && g.shipped > g.received && daysAgo(g.shipped_date) > GOALS.lateTransferDays),
    countDays: Number(card.count_days) || 0,
    countOpen: Number(card.count_open_lines) || 0
  };
}

function render() {
  const f = figures();
  document.getElementById('scTitle').textContent = `Manager Scorecard - ${card.branch}`;
  document.getElementById('periodLabel').textContent =
    `${card.branch} · ${shortDate(card.month)} - ${shortDate(card.through)}, ${card.month.slice(0, 4)}` +
    (f.isCurrent ? ` (day ${f.daysDone} of ${f.daysIn} - scores so far)` : ' (closed month)');
  document.getElementById('onHandHead').textContent = f.isCurrent ? 'Expected count (now)' : 'Expected count (month end)';

  const tiles = [];

  // 1. Sales vs target.
  if (f.target > 0) {
    const base = f.isCurrent ? f.expected : f.target;
    const p = pct(f.sales, base);
    tiles.push({
      name: 'Sales vs target', status: scoreHigh(p, GOALS.salesPacePct), value: `${p}%`,
      goal: f.isCurrent ? `Goal: ${GOALS.salesPacePct.good}% of where we should be today` : `Goal: ${GOALS.salesPacePct.good}% of target`,
      detail: `${formatMoney(f.sales)} of ${formatMoney(f.target)} target` +
        (f.isCurrent && f.sales < f.target ? ` · need ${formatMoney((f.target - f.sales) / Math.max(f.daysIn - f.daysDone, 1))}/day` : '')
    });
  } else {
    tiles.push({ name: 'Sales vs target', status: 'none', value: formatMoney(f.sales), goal: 'No target set for this month', detail: `${f.orders} orders` });
  }

  // 2. Growth vs last month.
  if (f.prevSame > 0) {
    const g = pct(f.sales - f.prevSame, f.prevSame);
    tiles.push({
      name: 'Sales vs last month', status: scoreHigh(g, GOALS.growthPct), value: `${g >= 0 ? '+' : ''}${g}%`,
      goal: `Goal: ${GOALS.growthPct.good}% or better (same days)`,
      detail: `${formatMoney(f.sales)} vs ${formatMoney(f.prevSame)}`
    });
  } else {
    tiles.push({ name: 'Sales vs last month', status: 'none', value: '-', goal: 'No sales last month to compare', detail: '' });
  }

  // 3. Cash counts.
  tiles.push({
    name: 'Cash count accuracy', status: f.cashCounts ? scoreLow(f.cashShort, GOALS.cashShort) : 'none',
    value: f.cashShort > 0 ? `${formatMoney(f.cashShort)} short` : 'Balanced',
    goal: `Goal: no more than ${formatMoney(GOALS.cashShort.good)} short`,
    detail: f.cashCounts ? `${f.shortDays} of ${f.cashCounts} cash counts short · over ${formatMoney(f.cashOver)}` : 'No cash counts this month'
  });

  // 4. Stock missing.
  const lost = f.missing + f.writtenOff;
  tiles.push({
    name: 'Stock missing', status: scoreLow(lost, GOALS.missingUnits), value: `${formatQty(lost)} units`,
    goal: `Goal: ${GOALS.missingUnits.good} units missing or written off`,
    detail: `${formatQty(f.missing)} missing in counts · ${formatQty(f.writtenOff)} written off`
  });

  // 5. Stock record accuracy.
  tiles.push({
    name: 'Items below zero', status: scoreLow(f.negative.length, GOALS.negativeItems), value: String(f.negative.length),
    goal: `Goal: ${GOALS.negativeItems.good} items (stock records match the shelf)`,
    detail: f.negative.length ? 'Sold or sent out with no stock on record - recount these' : 'All stock records are zero or above'
  });

  // 6. Transfers received on time.
  tiles.push({
    name: 'Transfers received on time', status: f.late.length ? 'bad' : 'good', value: f.late.length ? `${f.late.length} late` : 'All on time',
    goal: `Goal: receive within ${GOALS.lateTransferDays} days`,
    detail: f.late.length ? f.late.map((g) => g.doc).join(', ') : ''
  });

  // 7. Counting done.
  const counted = f.countDays > 0 || f.countOpen > 0;
  tiles.push({
    name: 'Inventory counted', status: counted ? 'good' : f.isCurrent ? 'warn' : 'bad',
    value: f.countDays > 0 ? `${f.countDays} count day${f.countDays === 1 ? '' : 's'}` : f.countOpen > 0 ? 'In progress' : 'Not yet',
    goal: 'Goal: at least one count posted this month',
    detail: (f.countOpen ? `${f.countOpen} lines counted, not posted yet. ` : '') +
      'From the Physical Inventory Journal (a count where everything matched leaves no record)'
  });

  const scored = tiles.filter((t) => t.status !== 'none');
  const good = scored.filter((t) => t.status === 'good').length;
  const bad = scored.filter((t) => t.status === 'bad').length;
  const warn = scored.length - good - bad;
  document.getElementById('overall').innerHTML = `
    <div class="sc-big ${bad ? 'sc-bad' : good === scored.length ? 'sc-good' : ''}">${good} / ${scored.length}</div>
    <div><strong>goals met</strong><br><span class="muted" style="font-size:13px;">${good} on target · ${warn} to watch · ${bad} below goal${f.isCurrent ? ' · so far this month' : ''}</span></div>`;

  const label = { good: 'On target', warn: 'Watch', bad: 'Below goal', none: 'Not scored' };
  const badge = { good: 'badge-success', warn: 'badge-warning', bad: 'badge-danger', none: 'badge-neutral' };
  document.getElementById('tiles').innerHTML = tiles.map((t) => `
    <div class="sc-tile is-${t.status}">
      <div class="sc-name"><span>${t.name}</span><span class="badge ${badge[t.status]}">${label[t.status]}</span></div>
      <div class="sc-value">${t.value}</div>
      <div class="sc-goal">${t.goal}</div>
      ${t.detail ? `<div class="sc-detail">${escapeHtml(t.detail)}</div>` : ''}
    </div>`).join('');

  renderMeter(f);
  renderTransfers();
  renderTop();
  renderItems();
}

function renderMeter(f) {
  const el = document.getElementById('targetMeter');
  if (!(f.target > 0)) {
    el.innerHTML = `<p style="margin:0;"><strong>${formatMoney(f.sales)}</strong> sold from ${f.orders} orders. <span class="muted">No target set for this month.</span></p>`;
    return;
  }
  const done = Math.min(pct(f.sales, f.target), 100);
  const mark = Math.min((f.expected / f.target) * 100, 100);
  el.innerHTML = `
    <div style="display:flex; justify-content:space-between; gap:8px; flex-wrap:wrap;">
      <strong>${formatMoney(f.sales)} of ${formatMoney(f.target)} (${pct(f.sales, f.target)}%)</strong>
      <span class="muted">${f.isCurrent ? `Should be at ${formatMoney(f.expected)} by today` : ''}</span>
    </div>
    <div class="sc-meter" role="meter" aria-valuemin="0" aria-valuemax="${f.target}" aria-valuenow="${f.sales}" aria-label="Sales vs target">
      <div class="sc-meter-fill${f.sales >= f.expected ? ' is-ahead' : ''}" style="width:${done}%;"></div>
      ${f.isCurrent ? `<div class="sc-meter-mark" style="left:calc(${mark}% - 1px);" title="Where we should be today"></div>` : ''}
    </div>
    <div class="muted" style="display:flex; justify-content:space-between; font-size:12px;">
      <span>₱0</span>${f.isCurrent ? '<span>│ = where we should be today</span>' : ''}<span>${formatMoney(f.target)}</span>
    </div>
    <p class="muted" style="font-size:13px; margin:8px 0 0;">${f.orders} orders · ${formatMoney(f.daysDone ? f.sales / f.daysDone : 0)} per day` +
    `${f.prevFull ? ` · last month's total ${formatMoney(f.prevFull)}` : ''}</p>`;
}

function renderTransfers() {
  const rows = card.transfer_gaps;
  document.getElementById('transferRows').innerHTML = rows.length
    ? rows.map((g) => {
      const age = daysAgo(g.shipped_date);
      const late = g.received > g.shipped || age > GOALS.lateTransferDays;
      const note = g.received > g.shipped ? 'received more than shipped' : g.received > 0 ? 'part received' : (g.status || 'not received');
      return `<tr><td>${escapeHtml(g.doc)}<br><span class="muted" style="font-size:12px;">${escapeHtml(note)}</span></td>
        <td>${escapeHtml(g.from || '?')} &rarr; ${escapeHtml(g.to || '?')}</td>
        <td class="num">${formatQty(g.shipped)}</td><td class="num">${formatQty(g.received)}</td>
        <td class="${late ? 'sc-bad' : ''}">${shortDate(g.shipped_date)} (${age}d)</td></tr>`;
    }).join('')
    : '<tr><td colspan="5" class="muted">All transfers fully received.</td></tr>';
}

function renderTop() {
  const rows = (card.top_items || []).slice().sort((a, b) => b.revenue - a.revenue).slice(0, 10);
  document.getElementById('topRows').innerHTML = rows.length
    ? rows.map((t) => `<tr><td>${escapeHtml(t.name)}</td><td class="num">${formatQty(t.qty)}</td><td class="num">${formatMoney(t.revenue)}</td></tr>`).join('')
    : '<tr><td colspan="3" class="muted">No sales yet.</td></tr>';
}

function filteredItems() {
  const view = document.getElementById('itemView').value;
  const q = document.getElementById('itemSearch').value.trim().toLowerCase();
  return items().filter((x) => {
    if (q && !`${x.code} ${x.name}`.toLowerCase().includes(q)) return false;
    if (view === 'stock') return x.closing !== 0;
    if (view === 'sold') return x.sold > 0;
    if (view === 'problems') return x.closing < 0 || x.lost > 0;
    return true;
  }).sort((a, b) => (a.category || '~').localeCompare(b.category || '~') || a.name.localeCompare(b.name));
}

function renderItems() {
  const rows = filteredItems();
  const n = (v) => (v ? formatQty(v) : '<span class="muted">·</span>');
  document.getElementById('itemCount').textContent = `${rows.length.toLocaleString()} item${rows.length === 1 ? '' : 's'}`;
  document.getElementById('itemRows').innerHTML = rows.length
    ? rows.map((x) => {
      const status = x.closing < 0 ? '<span class="badge badge-danger">Recount</span>'
        : x.lost > 0 ? '<span class="badge badge-warning">Had missing</span>'
          : '<span class="badge badge-success">OK</span>';
      return `<tr>
        <td>${escapeHtml(x.name)}<br><span class="muted" style="font-size:12px;">${escapeHtml(x.code)}</span></td>
        <td>${escapeHtml(x.category || '')}</td>
        <td class="num${x.closing < 0 ? ' sc-bad' : ''}"><strong>${formatQty(x.closing)}</strong></td>
        <td class="num sc-hide-on-sheet">${n(x.sold)}</td>
        <td class="num sc-hide-on-sheet">${n(x.received)}</td>
        <td class="num sc-hide-on-sheet">${n(x.transfer_out)}</td>
        <td class="num sc-hide-on-sheet${x.lost ? ' sc-bad' : ''}">${n(x.lost)}</td>
        <td class="sc-no-print">${status}</td>
        <td class="sc-count-col"></td>
      </tr>`;
    }).join('')
    : '<tr><td colspan="9" class="muted">No items match.</td></tr>';
}

function printCountSheet() {
  const view = document.getElementById('itemView');
  const search = document.getElementById('itemSearch');
  const before = { view: view.value, search: search.value };
  view.value = 'stock';
  search.value = '';
  renderItems();
  document.body.classList.add('sc-print-sheet');
  window.addEventListener('afterprint', function restore() {
    document.body.classList.remove('sc-print-sheet');
    view.value = before.view;
    search.value = before.search;
    renderItems();
    window.removeEventListener('afterprint', restore);
  });
  window.print();
}

async function loadCard() {
  const loadingEl = document.getElementById('scLoading');
  const errorEl = document.getElementById('scError');
  const resultsEl = document.getElementById('scResults');
  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  const key = selectedMonthKey();
  document.getElementById('nextMonthBtn').disabled = key >= manilaMonthKey();
  const branchSelect = document.getElementById('branchSelect');
  const wantedBranch = branchSelect.value || new URL(window.location.href).searchParams.get('branch') || null;

  const { data, error } = await supabaseClient.rpc('staff_get_manager_scorecard', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_month: `${key}-01`,
    p_warehouse: wantedBranch
  });
  loadingEl.classList.add('hidden');
  if (key !== selectedMonthKey()) return;
  if (error) {
    errorEl.textContent = /staff_get_manager_scorecard/.test(error.message) ? 'Run supabase_manager_scorecard.sql in Supabase first.' : error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }
  card = data;
  if (card.can_pick_branch) {
    branchSelect.innerHTML = card.branches.map((b) => `<option value="${escapeHtml(b)}">${escapeHtml(b)}</option>`).join('');
    branchSelect.value = card.branch;
    branchSelect.classList.remove('hidden');
  }
  syncUrl();
  resultsEl.classList.remove('hidden');
  render();
}

function setMonth(key) {
  document.getElementById('scMonth').value = key > manilaMonthKey() ? manilaMonthKey() : key;
  loadCard();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Manager Scorecard');

  if (!session.isSuperUser && !session.isStoreManager) {
    document.getElementById('scLoading').classList.add('hidden');
    const errorEl = document.getElementById('scError');
    errorEl.textContent = 'Only Store Managers and Super Users can view the scorecard.';
    errorEl.classList.remove('hidden');
    return;
  }

  const fromUrl = new URL(window.location.href).searchParams.get('month');
  const monthInput = document.getElementById('scMonth');
  monthInput.max = manilaMonthKey();
  monthInput.value = /^\d{4}-\d{2}$/.test(fromUrl || '') && fromUrl <= manilaMonthKey() ? fromUrl : manilaMonthKey();

  monthInput.addEventListener('change', loadCard);
  document.getElementById('prevMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), -1)));
  document.getElementById('nextMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), 1)));
  document.getElementById('thisMonthBtn').addEventListener('click', () => setMonth(manilaMonthKey()));
  document.getElementById('branchSelect').addEventListener('change', loadCard);
  document.getElementById('itemSearch').addEventListener('input', renderItems);
  document.getElementById('itemView').addEventListener('change', renderItems);
  document.getElementById('printBtn').addEventListener('click', () => window.print());
  document.getElementById('printSheetBtn').addEventListener('click', printCountSheet);

  await loadCard();
})();
