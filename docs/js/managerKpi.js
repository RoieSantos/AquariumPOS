// Manager KPI dashboard - per the "Manager KPI Scorecard System Requirements".
//
// staff_get_manager_kpi (sql/supabase_manager_kpi.sql) returns the selected branch's month (live, or frozen if the
// month was closed), the branch ranking and a 12-month trend. All scoring rules live in the SQL (_manager_kpi);
// this page only displays them. Store Managers get their own branch and no bonus %; Super Users pick a branch,
// rate Leadership (admin_set_leadership_rating) and close / reopen a finished month.
let currentSession = null;
let data = null;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const RATING_AREAS = [
  ['problem_solving', 'Problem Solving'], ['decision_making', 'Decision Making'], ['team_coaching', 'Team Coaching'],
  ['process_improvement', 'Process Improvement'], ['customer_handling', 'Customer Handling'], ['initiative', 'Initiative']
];
const RATING_LABELS = { 5: 'Outstanding', 4: 'Very Good', 3: 'Good', 2: 'Needs Improvement', 1: 'Poor' };

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function formatMoney(value) {
  const n = Number(value) || 0;
  return (n < 0 ? '-₱' : '₱') + Math.abs(n).toLocaleString('en-PH', { maximumFractionDigits: 0 });
}

function num(v, digits = 1) {
  return v == null ? null : Number(v).toLocaleString('en-PH', { maximumFractionDigits: digits });
}

function monthLabel(key, long) {
  const [y, m] = String(key).split('-').map(Number);
  return long ? `${new Date(y, m - 1, 1).toLocaleString('en-US', { month: 'long' })} ${y}` : `${MONTHS[m - 1]} ${String(y).slice(2)}`;
}

function manilaMonthKey() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }).slice(0, 7);
}

function shiftMonthKey(key, months) {
  const [y, m] = key.split('-').map(Number);
  const d = new Date(y, m - 1 + months, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function selectedMonthKey() {
  return document.getElementById('kpiMonth').value || manilaMonthKey();
}

function creds() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

function scoreClass(score) {
  if (score == null) return '';
  return score >= 90 ? 'kpi-good' : score < 70 ? 'kpi-bad' : '';
}

// ---------------------------------------------------------------------------------------------- render

function render() {
  const d = data.detail;
  const closed = !!d.closed_at;
  document.getElementById('kpiTitle').textContent = `Manager KPI - ${data.branch}`;
  document.getElementById('scorecardLink').href = `manager-scorecard.html?month=${selectedMonthKey()}&branch=${encodeURIComponent(data.branch)}`;
  document.getElementById('periodLabel').innerHTML =
    `${escapeHtml(data.branch)} · ${escapeHtml(d.manager_name || 'no manager set')} · ${monthLabel(data.month, true)}` +
    (d.is_current ? ` · <strong>live, through ${escapeHtml(d.through)}</strong>` : '') +
    (closed ? ` · <span class="kpi-closed">🔒 closed ${new Date(d.closed_at).toLocaleDateString('en-PH')}${d.closed_by ? ' by ' + escapeHtml(d.closed_by) : ''} - scores frozen</span>` : '');

  const isPast = selectedMonthKey() < manilaMonthKey();
  document.getElementById('closeMonthBtn').classList.toggle('hidden', !data.is_super || !isPast);
  document.getElementById('closeMonthBtn').textContent = closed ? 'Close again (re-save scores)' : 'Close month & save scores';
  document.getElementById('reopenMonthBtn').classList.toggle('hidden', !data.is_super || !closed);

  renderSummary();
  renderBreakdown();
  renderRating();
  renderTrends();
  renderRanking();
}

function renderSummary() {
  const d = data.detail;
  const prev = data.previous;
  const rankIdx = data.ranking.findIndex((r) => r.branch === data.branch);
  const sales = (d.kpis || []).find((k) => k.key === 'sales') || {};
  const card = (icon, label, value, sub, cls) => `
    <div class="stat-card"><div class="stat-label"><span class="stat-icon">${icon}</span> ${label}</div>
      <div class="stat-value ${cls || ''}">${value}</div><div class="muted" style="font-size:13px;">${sub}</div></div>`;

  const delta = d.final != null && prev && prev.final != null ? Number(d.final) - Number(prev.final) : null;
  const cards = [
    card('🎯', d.is_current ? 'Current score (so far)' : 'Score', d.final != null ? num(d.final) : '-',
      escapeHtml(d.rating || 'Not enough data') + (Number(d.measured_weight) < 100 && d.final != null ? ` · based on ${num(d.measured_weight, 0)}% of the weights` : ''),
      scoreClass(Number(d.final))),
    card('🗓️', 'Previous month', prev && prev.final != null ? num(prev.final) : '-',
      delta == null ? (prev ? monthLabel(prev.month, true) : '') : `<span class="${delta >= 0 ? 'kpi-good' : 'kpi-bad'}">${delta >= 0 ? '▲' : '▼'} ${num(Math.abs(delta))}</span> this month`),
    card('🏆', 'Branch ranking', rankIdx >= 0 && d.final != null ? `#${rankIdx + 1}` : '-', `of ${data.ranking.length} branch${data.ranking.length === 1 ? '' : 'es'}`),
    card('💰', 'Sales vs target', sales.actual != null ? `${num(sales.actual)}%` : formatMoney(sales.sales),
      sales.sales_target > 0 ? `${formatMoney(sales.sales)} of ${formatMoney(sales.sales_target)}` : 'No target set', sales.actual != null ? (sales.actual >= 100 ? 'kpi-good' : sales.actual < 90 ? 'kpi-bad' : '') : '')
  ];
  if (data.is_super) {
    cards.push(card('🎁', 'Bonus eligibility', d.bonus_pct != null ? `${d.bonus_pct}%` : '-',
      '95+ = 100% · 90-94 = 75% · 80-89 = 50% · 70-79 = 25% · below 70 = none'));
  }
  document.getElementById('summaryCards').innerHTML = cards.join('');
}

function renderBreakdown() {
  const kpis = data.detail.kpis || [];
  if (!kpis.length) {
    document.getElementById('kpiRows').innerHTML = `<tr><td colspan="8" class="muted">${escapeHtml(data.detail.note || 'No KPI data for this month.')}</td></tr>`;
    return;
  }
  const cats = ['Financial', 'Operations', 'People', 'Leadership'];
  const rows = [];
  cats.forEach((cat) => {
    const list = kpis.filter((k) => k.category === cat);
    const catWeight = list.reduce((s, k) => s + Number(k.weight), 0);
    const catScore = list.reduce((s, k) => s + (Number(k.weighted_score) || 0), 0);
    rows.push(`<tr class="kpi-cat"><td colspan="5">${cat} (${catWeight}%)</td><td></td><td class="num">${num(catScore)}</td><td></td></tr>`);
    list.forEach((k) => {
      const actual = k.actual == null ? '<span class="muted">-</span>' : `${num(k.actual, 2)}${k.unit === '%' ? '%' : ' ' + escapeHtml(k.unit)}`;
      const score = k.off ? '<span class="badge badge-neutral">Off</span>'
        : k.score == null ? '<span class="badge badge-neutral">No data</span>'
          : `<span class="kpi-bar"><span style="width:${Math.min(Number(k.score), 100)}%;"></span></span><span class="${scoreClass(Number(k.score))}">${num(k.score)}</span>`;
      rows.push(`<tr class="${k.off || k.score == null ? 'kpi-off' : ''}">
        <td style="padding-left:20px;">${escapeHtml(k.name)}</td>
        <td>${escapeHtml(k.target)}</td>
        <td class="num">${actual}</td>
        <td style="white-space:nowrap;">${score}</td>
        <td class="num">${k.weight}%</td>
        <td class="num">${k.score == null ? '<span class="muted">0%</span>' : num(k.effective_weight) + '%'}</td>
        <td class="num">${k.weighted_score == null ? '<span class="muted">-</span>' : num(k.weighted_score)}</td>
        <td class="muted" style="font-size:12px;">${escapeHtml(k.note || '')}</td>
      </tr>`);
    });
  });
  const d = data.detail;
  rows.push(`<tr class="kpi-total"><td colspan="6">Final score${d.rating ? ' - ' + escapeHtml(d.rating) : ''}</td>
    <td class="num ${scoreClass(Number(d.final))}">${d.final != null ? num(d.final) : '-'}</td><td></td></tr>`);
  document.getElementById('kpiRows').innerHTML = rows.join('');
}

function renderRating() {
  const cardEl = document.getElementById('ratingCard');
  cardEl.classList.toggle('hidden', !data.is_super || !!data.detail.closed_at);
  if (!data.is_super) return;
  const lead = (data.detail.kpis || []).find((k) => k.key === 'leadership') || {};
  const current = lead.rating || {};
  document.getElementById('ratingFields').innerHTML = RATING_AREAS.map(([key, label]) => `
    <label>${label}
      <select data-key="${key}">
        <option value="">- pick -</option>
        ${[5, 4, 3, 2, 1].map((v) => `<option value="${v}"${Number(current[key]) === v ? ' selected' : ''}>${v} - ${RATING_LABELS[v]}</option>`).join('')}
      </select>
    </label>`).join('');
  document.getElementById('ratingNotes').value = current.notes || '';
  document.getElementById('ratingMsg').textContent = lead.rating ? 'Rated - change and save to update.' : 'Not rated yet for this month.';
}

async function saveRating() {
  const msg = document.getElementById('ratingMsg');
  const rating = { notes: document.getElementById('ratingNotes').value };
  for (const sel of document.querySelectorAll('#ratingFields select')) {
    if (!sel.value) { msg.textContent = 'Pick a rating for every area.'; return; }
    rating[sel.dataset.key] = Number(sel.value);
  }
  msg.textContent = 'Saving...';
  const { error } = await supabaseClient.rpc('admin_set_leadership_rating', {
    ...creds(), p_month: `${selectedMonthKey()}-01`, p_warehouse: data.branch, p_rating: rating
  });
  if (error) { msg.textContent = error.message; return; }
  await loadKpi();
}

// One series per chart (12 months, oldest first); null months leave a gap.
function lineChart(elId, points, fmt, opts = {}) {
  const el = document.getElementById(elId);
  const vals = points.map((p) => p.v).filter((v) => v != null);
  if (!vals.length) { el.innerHTML = '<p class="muted" style="margin:0;">No data yet.</p>'; return; }
  const W = 420; const H = 170; const L = 44; const R = 10; const T = 12; const B = 24;
  const maxY = Math.max(opts.max || 0, ...vals) * 1.08 || 1;
  const n = points.length;
  const x = (i) => L + (i / Math.max(n - 1, 1)) * (W - L - R);
  const y = (v) => T + (1 - v / maxY) * (H - T - B);
  let path = ''; let pen = false;
  points.forEach((p, i) => {
    if (p.v == null) { pen = false; return; }
    path += `${pen ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.v).toFixed(1)} `;
    pen = true;
  });
  const ticks = [0, 0.5, 1].map((t) => maxY * t);
  const ref = opts.ref != null ? `<line x1="${L}" x2="${W - R}" y1="${y(opts.ref)}" y2="${y(opts.ref)}" stroke="var(--text-muted)" stroke-width="1.5" stroke-dasharray="5 4"/>
      <text x="${W - R}" y="${y(opts.ref) - 4}" text-anchor="end" font-size="10" fill="var(--text-muted)">${escapeHtml(opts.refLabel || '')}</text>` : '';
  el.innerHTML = `
    <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeHtml(opts.label || '')} by month">
      ${ticks.map((t) => `<line x1="${L}" x2="${W - R}" y1="${y(t)}" y2="${y(t)}" stroke="var(--panel-border)" stroke-width="1"/>
        <text x="${L - 6}" y="${y(t) + 4}" text-anchor="end" font-size="10" fill="var(--text-muted)">${fmt(t, true)}</text>`).join('')}
      ${points.map((p, i) => (i % 2 === (n - 1) % 2) ? `<text x="${x(i)}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${monthLabel(p.month)}</text>` : '').join('')}
      ${ref}
      <path d="${path}" fill="none" stroke="var(--primary)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
      ${points.map((p, i) => p.v == null ? '' : `<circle cx="${x(i)}" cy="${y(p.v)}" r="${i === n - 1 ? 4 : 2.5}" fill="var(--primary)" stroke="var(--panel-bg)" stroke-width="1.5"/>`).join('')}
      ${points.map((p, i) => `<rect class="kpi-hit" data-i="${i}" x="${x(i) - (W - L - R) / (2 * Math.max(n - 1, 1))}" y="${T}" width="${(W - L - R) / Math.max(n - 1, 1)}" height="${H - T - B}" fill="transparent"/>`).join('')}
    </svg>
    <div class="kpi-tip hidden"></div>`;
  const svg = el.querySelector('svg');
  const tip = el.querySelector('.kpi-tip');
  el.querySelectorAll('.kpi-hit').forEach((rect) => {
    const show = () => {
      const p = points[Number(rect.dataset.i)];
      tip.innerHTML = `<strong>${monthLabel(p.month, true)}</strong><br>${p.v == null ? 'No data' : fmt(p.v)}`;
      tip.classList.remove('hidden');
      const box = svg.getBoundingClientRect();
      const px = (x(Number(rect.dataset.i)) / W) * box.width;
      tip.style.left = `${Math.min(Math.max(px - tip.offsetWidth / 2, 0), box.width - tip.offsetWidth)}px`;
      tip.style.top = `${((p.v == null ? H / 2 : y(p.v)) / H) * box.height - 46}px`;
    };
    rect.addEventListener('mouseenter', show);
    rect.addEventListener('touchstart', show, { passive: true });
    rect.addEventListener('mouseleave', () => tip.classList.add('hidden'));
  });
}

function renderTrends() {
  const t = data.trend || [];
  const pts = (key) => t.map((m) => ({ month: m.month, v: m[key] == null ? null : Number(m[key]) }));
  const pct = (v, axis) => (axis ? `${Math.round(v)}` : `${num(v)}%`);
  lineChart('trendScore', pts('final'), (v, axis) => (axis ? `${Math.round(v)}` : `${num(v)} points`), { max: 100, ref: 80, refLabel: 'Exceeds (80)', label: 'KPI score' });
  lineChart('trendSales', pts('sales'), (v, axis) => (axis ? (v >= 1000 ? `₱${Math.round(v / 1000)}k` : `₱${Math.round(v)}`) : formatMoney(v)), { label: 'Sales' });
  lineChart('trendAttendance', pts('attendance_pct'), pct, { max: 100, ref: 97, refLabel: 'Target 97%', label: 'Attendance' });
  lineChart('trendAccuracy', pts('accuracy_pct'), pct, { max: 100, ref: 99, refLabel: 'Target 99%', label: 'Inventory accuracy' });
}

function renderRanking() {
  const showBonus = data.is_super;
  document.getElementById('rankHead').innerHTML = `<th class="num">Rank</th><th>Branch</th><th>Manager</th><th class="num">KPI score</th><th>Rating</th>${showBonus ? '<th class="num">Bonus</th>' : ''}`;
  let rank = 0;
  document.getElementById('rankRows').innerHTML = data.ranking.length
    ? data.ranking.map((r) => {
      if (r.final != null) rank += 1;
      const mine = r.branch === data.branch;
      return `<tr${mine ? ' style="font-weight:700;"' : ''}>
        <td class="num">${r.final != null ? '#' + rank : '-'}</td>
        <td>${escapeHtml(r.branch)}${r.closed_at ? ' 🔒' : ''}</td>
        <td>${escapeHtml(r.manager_name || '-')}</td>
        <td class="num ${scoreClass(Number(r.final))}">${r.final != null ? num(r.final) : '-'}</td>
        <td>${escapeHtml(r.rating || 'Not enough data')}</td>
        ${showBonus ? `<td class="num">${r.bonus_pct != null ? r.bonus_pct + '%' : '-'}</td>` : ''}
      </tr>`;
    }).join('')
    : `<tr><td colspan="${showBonus ? 6 : 5}" class="muted">No branches scored - set a Store Manager's branch in User Setup or a sales target.</td></tr>`;
}

// ---------------------------------------------------------------------------------------------- load / actions

async function loadKpi() {
  const loadingEl = document.getElementById('kpiLoading');
  const errorEl = document.getElementById('kpiError');
  const resultsEl = document.getElementById('kpiResults');
  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  const key = selectedMonthKey();
  document.getElementById('nextMonthBtn').disabled = key >= manilaMonthKey();
  const branchSelect = document.getElementById('branchSelect');
  const wanted = branchSelect.value || new URL(window.location.href).searchParams.get('branch') || null;

  const { data: result, error } = await supabaseClient.rpc('staff_get_manager_kpi', { ...creds(), p_month: `${key}-01`, p_warehouse: wanted });
  loadingEl.classList.add('hidden');
  if (key !== selectedMonthKey()) return;
  if (error) {
    errorEl.textContent = /staff_get_manager_kpi/.test(error.message) ? 'Run supabase_manager_kpi.sql in Supabase first.' : error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }
  data = result;
  if (data.is_super) {
    branchSelect.innerHTML = data.ranking.map((r) => `<option value="${escapeHtml(r.branch)}">${escapeHtml(r.branch)}</option>`).join('');
    branchSelect.value = data.branch;
    branchSelect.classList.remove('hidden');
  }
  const url = new URL(window.location.href);
  url.searchParams.set('month', key);
  if (data.is_super) url.searchParams.set('branch', data.branch);
  window.history.replaceState(null, '', url.toString());
  resultsEl.classList.remove('hidden');
  render();
}

async function closeMonth() {
  const key = selectedMonthKey();
  if (!confirm(`Freeze the ${monthLabel(key, true)} scores for every branch? Later changes to that month's sales or counts won't change them (you can reopen it).`)) return;
  const { error } = await supabaseClient.rpc('admin_close_manager_kpi_month', { ...creds(), p_month: `${key}-01` });
  if (error) { alert(error.message); return; }
  await loadKpi();
}

async function reopenMonth() {
  const key = selectedMonthKey();
  if (!confirm(`Reopen ${monthLabel(key, true)}? Scores go back to being calculated live.`)) return;
  const { error } = await supabaseClient.rpc('admin_reopen_manager_kpi_month', { ...creds(), p_month: `${key}-01` });
  if (error) { alert(error.message); return; }
  await loadKpi();
}

function setMonth(key) {
  document.getElementById('kpiMonth').value = key > manilaMonthKey() ? manilaMonthKey() : key;
  loadKpi();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Manager KPI');

  if (!session.isSuperUser && !session.isStoreManager) {
    document.getElementById('kpiLoading').classList.add('hidden');
    const errorEl = document.getElementById('kpiError');
    errorEl.textContent = 'Only Store Managers and Super Users can view Manager KPI.';
    errorEl.classList.remove('hidden');
    return;
  }

  const fromUrl = new URL(window.location.href).searchParams.get('month');
  const monthInput = document.getElementById('kpiMonth');
  monthInput.max = manilaMonthKey();
  monthInput.value = /^\d{4}-\d{2}$/.test(fromUrl || '') && fromUrl <= manilaMonthKey() ? fromUrl : manilaMonthKey();

  monthInput.addEventListener('change', loadKpi);
  document.getElementById('prevMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), -1)));
  document.getElementById('nextMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), 1)));
  document.getElementById('thisMonthBtn').addEventListener('click', () => setMonth(manilaMonthKey()));
  document.getElementById('branchSelect').addEventListener('change', loadKpi);
  document.getElementById('saveRatingBtn').addEventListener('click', saveRating);
  document.getElementById('closeMonthBtn').addEventListener('click', closeMonth);
  document.getElementById('reopenMonthBtn').addEventListener('click', reopenMonth);
  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadKpi();
})();
