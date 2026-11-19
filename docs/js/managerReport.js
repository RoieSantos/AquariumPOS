// Manager's Report - per "can you give me a manager's report.. are we losing? are we selling? how much? is the
// inventory losing anything? ... target sales and sales as of the month".
//
// admin_get_manager_report (sql/supabase_manager_report.sql) returns the whole month as one jsonb value, summed per
// branch: daily sales, targets, purchases, expenses, payroll, cash counts, margin, and the Item Ledger movements per
// item x branch. Branch filtering, the verdict, the pace chart and every table are built here from that, so
// switching branch never re-queries. Targets are saved with admin_set_sales_target.
//
// Month and branch are kept in the URL (?month=2026-11&branch=Amaya).
let currentSession = null;
let report = null;
let itemLimit = 100;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function formatMoney(value, noDecimals) {
  const amount = Number(value) || 0;
  const digits = noDecimals ? 0 : 2;
  return (amount < 0 ? '-₱' : '₱') + Math.abs(amount).toLocaleString('en-PH', { minimumFractionDigits: digits, maximumFractionDigits: digits });
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
  return document.getElementById('mrMonth').value || manilaMonthKey();
}

function selectedBranch() {
  return document.getElementById('warehouseSelect').value;
}

function inBranch(row) {
  const wh = selectedBranch();
  return !wh || row.warehouse === wh;
}

function sumOf(rows, field) {
  return (rows || []).reduce((s, r) => s + (Number(r[field]) || 0), 0);
}

function branchSum(rows, field) {
  return sumOf((rows || []).filter(inBranch), field);
}

function syncUrl() {
  const url = new URL(window.location.href);
  url.searchParams.set('month', selectedMonthKey());
  if (selectedBranch()) url.searchParams.set('branch', selectedBranch());
  else url.searchParams.delete('branch');
  window.history.replaceState(null, '', url.toString());
}

// ---------------------------------------------------------------------------------------------- derived figures

function figures() {
  const r = report;
  const isCurrent = r.through < r.month_end;
  const daysIn = Number(r.days_in_month);
  const daysDone = Number(r.days_elapsed);
  const sales = branchSum(r.sales_days, 'amount');
  const advanceCopies = branchSum(r.sales_days, 'advance_copy');
  const target = branchSum(r.targets, 'target');
  const prevSame = branchSum(r.compare.prev, 'amount');
  const prevFull = branchSum(r.compare.prev_full, 'amount');
  const lastYear = branchSum(r.compare.last_year, 'amount');
  const forecast = isCurrent && daysDone > 0 ? (sales / daysDone) * daysIn : sales;
  const expectedByNow = target * (daysDone / daysIn);

  const advanceCollected = branchSum(r.advance_collected, 'amount');
  const purchases = branchSum(r.purchases, 'amount');
  const expenses = branchSum(r.expenses, 'amount');
  const payrollAll = (Number(r.payroll.net_pay) || 0) + (Number(r.payroll.cash_advance) || 0);
  const payroll = selectedBranch() ? 0 : payrollAll;
  const moneyIn = sales - advanceCopies + advanceCollected;
  const moneyOut = purchases + expenses + payroll;

  const cashShort = branchSum(r.cash, 'short');
  const cashOver = branchSum(r.cash, 'over');

  return { isCurrent, daysIn, daysDone, sales, advanceCopies, target, prevSame, prevFull, lastYear, forecast, expectedByNow,
           advanceCollected, purchases, expenses, payroll, payrollAll, moneyIn, moneyOut, cashShort, cashOver };
}

// Item rows for the selected branch (All = summed across branches per item).
function itemRows() {
  const fields = ['opening', 'purchased', 'produced', 'transfer_in', 'transfer_out', 'sold', 'used', 'found', 'missing', 'adj_plus', 'adj_minus', 'closing'];
  const rows = report.items.filter(inBranch);
  if (selectedBranch()) return rows.map((x) => ({ ...x }));
  const map = new Map();
  rows.forEach((x) => {
    const e = map.get(x.code) || { ...x, warehouse: 'All', ...Object.fromEntries(fields.map((f) => [f, 0])) };
    fields.forEach((f) => { e[f] += Number(x[f]) || 0; });
    map.set(x.code, e);
  });
  return [...map.values()];
}

function inventoryFigures(items) {
  const val = (qty, x) => (Number(qty) || 0) * (Number(x.cost) || 0);
  return {
    stockValue: items.reduce((s, x) => s + Math.max(x.closing, 0) * (Number(x.cost) || 0), 0),
    stockUncosted: items.filter((x) => x.closing > 0 && !(Number(x.cost) > 0)).length,
    stockItems: items.filter((x) => x.closing > 0).length,
    missingQty: sumOf(items, 'missing'),
    missingValue: items.reduce((s, x) => s + val(x.missing, x), 0),
    foundValue: items.reduce((s, x) => s + val(x.found, x), 0),
    writtenOffQty: sumOf(items, 'adj_minus'),
    writtenOffValue: items.reduce((s, x) => s + val(x.adj_minus, x), 0),
    usedValue: items.reduce((s, x) => s + val(x.used, x), 0),
    usedQty: sumOf(items, 'used'),
    soldQty: sumOf(items, 'sold'),
    inQty: items.reduce((s, x) => s + x.purchased + x.produced, 0),
    negative: items.filter((x) => x.closing < 0)
  };
}

function branchTransfers() {
  const wh = selectedBranch();
  return report.transfer_gaps.filter((g) => !wh || g.from === wh || g.to === wh);
}

// ---------------------------------------------------------------------------------------------- render

function render() {
  const f = figures();
  const items = itemRows();
  const inv = inventoryFigures(items);
  const branchLabel = selectedBranch() || 'All branches';

  document.getElementById('monthLabel').textContent =
    `${branchLabel} · ${shortDate(report.month)} - ${shortDate(report.through)}, ${report.month.slice(0, 4)}` +
    (f.isCurrent ? ` (day ${f.daysDone} of ${f.daysIn})` : '');

  renderVerdict(f, inv);
  renderStats(f);
  renderTargetMeter(f);
  renderPaceChart(f);
  renderTargetEditor();
  renderMoney(f);
  renderMargin();
  renderInventoryCards(f, inv);
  renderLosses(items);
  renderTransfers();
  renderBelowCost();
  renderTopItems();
  renderItems();
}

function renderVerdict(f, inv) {
  const points = [];
  let tone = 'is-good';

  // Selling?
  if (f.target > 0) {
    const fc = pct(f.forecast, f.target);
    if (f.isCurrent) {
      if (f.sales >= f.expectedByNow) points.push(`<span class="mr-good">Ahead of target</span> - ${formatMoney(f.sales, true)} sold vs ${formatMoney(f.expectedByNow, true)} expected by today; on pace for ${fc}% of target.`);
      else {
        const perDay = (f.target - f.sales) / Math.max(f.daysIn - f.daysDone, 1);
        points.push(`<span class="mr-bad">Behind target</span> - ${formatMoney(f.expectedByNow - f.sales, true)} short of where we should be today. Need ${formatMoney(perDay, true)}/day for the last ${f.daysIn - f.daysDone} days.`);
        tone = 'is-warn';
      }
    } else {
      points.push(f.sales >= f.target
        ? `<span class="mr-good">Target hit</span> - ${pct(f.sales, f.target)}% of ${formatMoney(f.target, true)}.`
        : `<span class="mr-bad">Target missed</span> - ${pct(f.sales, f.target)}% of ${formatMoney(f.target, true)}.`);
      if (f.sales < f.target) tone = 'is-warn';
    }
  } else {
    points.push('No sales target set for this month yet - set one below.');
  }
  if (f.prevSame > 0) {
    const ch = pct(f.sales - f.prevSame, f.prevSame);
    points.push(`Sales are ${ch >= 0 ? `<span class="mr-good">up ${ch}%</span>` : `<span class="mr-bad">down ${Math.abs(ch)}%</span>`} vs the same days last month (${formatMoney(f.prevSame, true)}).`);
  }

  // Losing?
  const netOps = f.moneyIn - (f.expenses + f.payroll);
  const net = f.moneyIn - f.moneyOut;
  if (selectedBranch() && f.moneyIn === 0 && f.target === 0) {
    // A branch that doesn't sell (e.g. the main Warehouse) only spends - that's not "losing".
    points.push(`This branch has no sales of its own - it spent ${formatMoney(f.moneyOut, true)} this month (stock purchases ${formatMoney(f.purchases, true)}, expenses ${formatMoney(f.expenses, true)}). See "All branches" for profit.`);
  } else if (net >= 0) points.push(`<span class="mr-good">More money came in than went out</span> (${formatMoney(net, true)}${selectedBranch() ? ', payroll not included for one branch' : ''}).`);
  else if (netOps >= 0) points.push(`Spent ${formatMoney(-net, true)} more than came in, but only because of stock purchases (${formatMoney(f.purchases, true)}). Without purchases we are ${formatMoney(netOps, true)} ahead.`);
  else { points.push(`<span class="mr-bad">Losing money</span> - expenses${selectedBranch() ? '' : ' and payroll'} alone are ${formatMoney(-netOps, true)} more than what came in.`); tone = 'is-bad'; }

  // Inventory / cash leaks.
  const leaks = [];
  if (inv.missingQty > 0) leaks.push(`${formatQty(inv.missingQty)} units missing in counts (${formatMoney(inv.missingValue, true)})`);
  if (inv.writtenOffQty > 0) leaks.push(`${formatQty(inv.writtenOffQty)} units written off (${formatMoney(inv.writtenOffValue, true)})`);
  if (f.cashShort < 0) leaks.push(`cash counts short ${formatMoney(-f.cashShort, true)}`);
  const lateTransfers = branchTransfers().filter((g) => g.shipped > g.received && daysAgo(g.shipped_date) > 3);
  if (lateTransfers.length) leaks.push(`${lateTransfers.length} transfer${lateTransfers.length === 1 ? '' : 's'} not received after 3+ days`);
  if (inv.negative.length) leaks.push(`${inv.negative.length} items show negative stock (sold without stock on record)`);
  if (leaks.length) {
    points.push(`<span class="mr-bad">Watch:</span> ${leaks.join('; ')}.`);
    if (tone === 'is-good') tone = 'is-warn';
  } else {
    points.push('<span class="mr-good">No stock went missing</span> and cash counts balanced.');
  }

  const icon = tone === 'is-good' ? '✅' : tone === 'is-bad' ? '🔴' : '⚠️';
  const title = tone === 'is-good' ? 'Looking good' : tone === 'is-bad' ? 'Needs attention now' : 'Mostly fine - a few things to check';
  document.getElementById('verdict').innerHTML = `
    <div class="mr-verdict ${tone}">
      <div class="mr-verdict-icon">${icon}</div>
      <div><h3>${title}</h3><ul>${points.map((p) => `<li>${p}</li>`).join('')}</ul></div>
    </div>`;
}

function daysAgo(dateKey) {
  if (!dateKey) return 0;
  const today = Date.parse(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }) + 'T00:00:00Z');
  return Math.round((today - Date.parse(dateKey + 'T00:00:00Z')) / 86400000);
}

function renderStats(f) {
  document.getElementById('statSales').textContent = formatMoney(f.sales, true);
  const subs = [];
  if (f.prevSame > 0) {
    const ch = pct(f.sales - f.prevSame, f.prevSame);
    subs.push(`<span class="${ch >= 0 ? 'mr-good' : 'mr-bad'}">${ch >= 0 ? '▲' : '▼'} ${Math.abs(ch)}%</span> vs same days last month`);
  }
  subs.push(`${formatMoney(f.daysDone ? f.sales / f.daysDone : 0, true)} / day`);
  document.getElementById('statSalesSub').innerHTML = subs.join(' · ');

  document.getElementById('statTarget').textContent = f.target > 0 ? formatMoney(f.target, true) : 'Not set';
  document.getElementById('statTargetSub').innerHTML = f.target > 0
    ? `${pct(f.sales, f.target)}% reached · ${formatMoney(Math.max(f.target - f.sales, 0), true)} to go`
    : '<a href="#targetEditor" id="setTargetLink">Set a target</a>';
  const link = document.getElementById('setTargetLink');
  if (link) link.addEventListener('click', () => { document.getElementById('targetEditor').open = true; });

  const fcEl = document.getElementById('statForecast');
  fcEl.textContent = formatMoney(f.forecast, true);
  fcEl.className = 'stat-value' + (f.target > 0 ? (f.forecast >= f.target ? ' mr-good' : ' mr-bad') : '');
  document.getElementById('statForecastSub').innerHTML = f.isCurrent
    ? `At this month's daily pace${f.target > 0 ? ` · ${pct(f.forecast, f.target)}% of target` : ''}${f.prevFull > 0 ? ` · last month ${formatMoney(f.prevFull, true)}` : ''}`
    : 'Month is closed (actual)';

  const net = f.moneyIn - f.moneyOut;
  const netEl = document.getElementById('statNet');
  netEl.textContent = formatMoney(net, true);
  netEl.className = 'stat-value ' + (net >= 0 ? 'mr-good' : 'mr-bad');
  document.getElementById('statNetSub').textContent =
    `In ${formatMoney(f.moneyIn, true)} · Out ${formatMoney(f.moneyOut, true)}${selectedBranch() ? ' (no payroll)' : ''}`;
}

function renderTargetMeter(f) {
  const el = document.getElementById('targetMeter');
  if (!(f.target > 0)) {
    el.innerHTML = `<p class="muted" style="margin:0;">No target for ${escapeHtml(selectedBranch() || 'any branch')} this month. Open "Set monthly targets per branch" below.</p>`;
    return;
  }
  const done = Math.min(pct(f.sales, f.target), 100);
  const mark = Math.min((f.expectedByNow / f.target) * 100, 100);
  const ahead = f.sales >= f.expectedByNow;
  el.innerHTML = `
    <div style="display:flex; justify-content:space-between; gap:8px; flex-wrap:wrap;">
      <strong>${formatMoney(f.sales, true)} of ${formatMoney(f.target, true)} (${pct(f.sales, f.target)}%)</strong>
      <span class="muted">${f.isCurrent ? `Expected by today: ${formatMoney(f.expectedByNow, true)}` : ''}</span>
    </div>
    <div class="mr-meter" role="meter" aria-valuemin="0" aria-valuemax="${f.target}" aria-valuenow="${f.sales}" aria-label="Sales vs target">
      <div class="mr-meter-fill${ahead ? ' is-ahead' : ''}" style="width:${done}%;"></div>
      ${f.isCurrent ? `<div class="mr-meter-mark" style="left:calc(${mark}% - 1px);" title="Where we should be today"></div>` : ''}
    </div>
    <div class="mr-meter-legend muted"><span>₱0</span>${f.isCurrent ? '<span>│ = where we should be today</span>' : ''}<span>${formatMoney(f.target, true)}</span></div>`;
}

// Cumulative sales by day vs the straight-line target pace. One series + one reference line.
function renderPaceChart(f) {
  const el = document.getElementById('paceChart');
  const byDay = new Map();
  report.sales_days.filter(inBranch).forEach((d) => byDay.set(d.date, (byDay.get(d.date) || 0) + (Number(d.amount) || 0)));
  const [y, m] = report.month.split('-').map(Number);
  const points = [];
  let run = 0;
  for (let day = 1; day <= f.daysDone; day += 1) {
    const key = `${y}-${String(m).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
    const amt = byDay.get(key) || 0;
    run += amt;
    points.push({ day, key, amt, run });
  }
  if (!points.length) { el.innerHTML = ''; return; }

  const W = 640; const H = 220; const L = 56; const R = 12; const T = 12; const B = 26;
  const maxY = Math.max(run, f.target, 1) * 1.05;
  const x = (day) => L + ((day - 1) / Math.max(f.daysIn - 1, 1)) * (W - L - R);
  const yy = (v) => T + (1 - v / maxY) * (H - T - B);
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((t) => maxY * t);
  const short = (v) => v >= 1e6 ? `₱${(v / 1e6).toFixed(1)}M` : v >= 1e3 ? `₱${Math.round(v / 1e3)}k` : `₱${Math.round(v)}`;
  const path = points.map((p, i) => `${i ? 'L' : 'M'}${x(p.day).toFixed(1)},${yy(p.run).toFixed(1)}`).join(' ');
  const last = points[points.length - 1];
  const xLabels = [1, 8, 15, 22, f.daysIn];

  el.innerHTML = `
    <div style="margin-bottom:6px;">
      <span class="mr-key"><i></i>Sales so far (running total)</span>
      ${f.target > 0 ? '<span class="mr-key"><i class="dash"></i>Target pace</span>' : ''}
    </div>
    <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Running total of sales by day${f.target > 0 ? ' against the target pace' : ''}">
      ${ticks.map((t) => `<line x1="${L}" x2="${W - R}" y1="${yy(t)}" y2="${yy(t)}" stroke="var(--panel-border)" stroke-width="1"/>
        <text x="${L - 6}" y="${yy(t) + 4}" text-anchor="end" font-size="11" fill="var(--text-muted)">${short(t)}</text>`).join('')}
      ${xLabels.map((d) => `<text x="${x(d)}" y="${H - 6}" text-anchor="middle" font-size="11" fill="var(--text-muted)">${MONTHS[m - 1]} ${d}</text>`).join('')}
      ${f.target > 0 ? `<line x1="${x(1)}" y1="${yy(0)}" x2="${x(f.daysIn)}" y2="${yy(f.target)}" stroke="var(--text-muted)" stroke-width="2" stroke-dasharray="6 5"/>` : ''}
      <path d="${path}" fill="none" stroke="var(--primary)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
      <circle cx="${x(last.day)}" cy="${yy(last.run)}" r="4" fill="var(--primary)" stroke="var(--panel-bg)" stroke-width="2"/>
      <text x="${Math.min(x(last.day) + 8, W - R - 60)}" y="${yy(last.run) - 8}" font-size="12" font-weight="600" fill="var(--text-main)">${short(last.run)}</text>
      <line id="paceCross" x1="0" x2="0" y1="${T}" y2="${H - B}" stroke="var(--text-muted)" stroke-width="1" visibility="hidden"/>
      <circle id="paceDot" r="5" fill="var(--primary)" stroke="var(--panel-bg)" stroke-width="2" visibility="hidden"/>
      <rect id="paceHit" x="${L}" y="${T}" width="${W - L - R}" height="${H - T - B}" fill="transparent"/>
    </svg>
    <div class="mr-tip hidden" id="paceTip"></div>`;

  const svg = el.querySelector('svg');
  const tip = document.getElementById('paceTip');
  const cross = document.getElementById('paceCross');
  const dot = document.getElementById('paceDot');
  const hide = () => { tip.classList.add('hidden'); cross.setAttribute('visibility', 'hidden'); dot.setAttribute('visibility', 'hidden'); };
  const show = (evt) => {
    const rect = svg.getBoundingClientRect();
    const sx = ((evt.clientX - rect.left) / rect.width) * W;
    const day = Math.round(((sx - L) / (W - L - R)) * Math.max(f.daysIn - 1, 1)) + 1;
    const p = points[Math.min(Math.max(day, 1), points.length) - 1];
    if (!p) return hide();
    cross.setAttribute('x1', x(p.day)); cross.setAttribute('x2', x(p.day)); cross.setAttribute('visibility', 'visible');
    dot.setAttribute('cx', x(p.day)); dot.setAttribute('cy', yy(p.run)); dot.setAttribute('visibility', 'visible');
    const pace = f.target > 0 ? f.target * (p.day / f.daysIn) : 0;
    tip.innerHTML = `<strong>${shortDate(p.key)}</strong><br>That day: ${formatMoney(p.amt, true)}<br>Running total: ${formatMoney(p.run, true)}` +
      (pace ? `<br>Target pace: ${formatMoney(pace, true)} <span class="${p.run >= pace ? 'mr-good' : 'mr-bad'}">(${p.run >= pace ? '+' : ''}${formatMoney(p.run - pace, true)})</span>` : '');
    tip.classList.remove('hidden');
    const px = (x(p.day) / W) * rect.width;
    tip.style.left = `${Math.min(px + 12, rect.width - tip.offsetWidth - 4)}px`;
    tip.style.top = `${(yy(p.run) / H) * rect.height - 10}px`;
  };
  const hit = document.getElementById('paceHit');
  hit.addEventListener('mousemove', show);
  hit.addEventListener('mouseleave', hide);
  hit.addEventListener('touchstart', (e) => show(e.touches[0]), { passive: true });
}

function renderTargetEditor() {
  const prevTargets = new Map(report.prev_targets.map((t) => [t.warehouse, Number(t.target) || 0]));
  const targets = new Map(report.targets.map((t) => [t.warehouse, Number(t.target) || 0]));
  const prevSales = new Map();
  report.compare.prev_full.forEach((r) => prevSales.set(r.warehouse, (prevSales.get(r.warehouse) || 0) + (Number(r.amount) || 0)));
  document.getElementById('targetRows').innerHTML = report.warehouses.map((wh) => `
    <tr>
      <td>${escapeHtml(wh)}</td>
      <td class="num">${prevTargets.get(wh) ? formatMoney(prevTargets.get(wh), true) : '<span class="muted">-</span>'}</td>
      <td class="num">${formatMoney(prevSales.get(wh) || 0, true)}</td>
      <td class="num"><input type="number" min="0" step="1000" class="mr-target-input" data-wh="${escapeHtml(wh)}"
           data-prev="${prevTargets.get(wh) || ''}" value="${targets.get(wh) || ''}" placeholder="0" /></td>
    </tr>`).join('');
  document.getElementById('copyTargetsBtn').disabled = report.prev_targets.length === 0;
}

async function saveTargets() {
  const msg = document.getElementById('targetMsg');
  const current = new Map(report.targets.map((t) => [t.warehouse, Number(t.target) || 0]));
  const changes = [...document.querySelectorAll('.mr-target-input')]
    .map((inp) => ({ wh: inp.dataset.wh, amount: Number(inp.value) || 0 }))
    .filter((c) => c.amount !== (current.get(c.wh) || 0));
  if (!changes.length) { msg.textContent = 'Nothing changed.'; return; }
  if (changes.some((c) => c.amount < 0)) { msg.textContent = 'Targets cannot be negative.'; return; }
  const btn = document.getElementById('saveTargetsBtn');
  btn.disabled = true;
  msg.textContent = 'Saving...';
  for (const c of changes) {
    const { error } = await supabaseClient.rpc('admin_set_sales_target', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_month: `${selectedMonthKey()}-01`,
      p_warehouse: c.wh,
      p_amount: c.amount
    });
    if (error) { msg.textContent = `Could not save ${c.wh}: ${error.message}`; btn.disabled = false; return; }
  }
  btn.disabled = false;
  msg.textContent = 'Saved.';
  await loadReport(true);
}

function renderMoney(f) {
  const row = (label, amount, opts = {}) => `<tr${opts.total ? ' class="mr-total"' : ''}>
      <td${opts.indent ? ' style="padding-left:22px;"' : ''}>${label}</td>
      <td class="num${opts.cls ? ' ' + opts.cls : ''}">${amount == null ? '' : formatMoney(amount, true)}</td></tr>`;
  const expCats = new Map();
  report.expenses.filter(inBranch).forEach((e) => expCats.set(e.category, (expCats.get(e.category) || 0) + (Number(e.amount) || 0)));
  const topCats = [...expCats.entries()].sort((a, b) => b[1] - a[1]);
  const shown = topCats.slice(0, 5);
  const rest = topCats.slice(5).reduce((s, [, v]) => s + v, 0);
  const net = f.moneyIn - f.moneyOut;
  const netOps = f.moneyIn - f.expenses - f.payroll;

  document.getElementById('moneyRows').innerHTML = [
    '<tr><th colspan="2">Money in</th></tr>',
    row('Sales', f.sales, { indent: true }),
    f.advanceCopies ? row('Less: advance orders already counted when paid', -f.advanceCopies, { indent: true }) : '',
    row('Advance-order payments collected', f.advanceCollected, { indent: true }),
    row('Total money in', f.moneyIn, { total: true }),
    '<tr><th colspan="2" style="padding-top:14px;">Money out</th></tr>',
    row('Stock purchases (received POs)', f.purchases, { indent: true }),
    row('Expenses &amp; bills', f.expenses, { indent: true }),
    ...shown.map(([cat, v]) => row(`<span class="muted">· ${escapeHtml(cat)}</span>`, v, { indent: true, cls: 'muted' })),
    rest ? row('<span class="muted">· other categories</span>', rest, { indent: true, cls: 'muted' }) : '',
    selectedBranch()
      ? `<tr><td style="padding-left:22px;" class="muted">Payroll</td><td class="num muted">company-wide only (${formatMoney(f.payrollAll, true)})</td></tr>`
      : row('Payroll (net pay + cash advances)', f.payroll, { indent: true }),
    row('Total money out', f.moneyOut, { total: true }),
    row('<strong>Net (in - out)</strong>', net, { total: true, cls: net >= 0 ? 'mr-good' : 'mr-bad' }),
    row('Net without stock purchases', netOps, { cls: netOps >= 0 ? 'mr-good' : 'mr-bad' })
  ].join('');
}

function renderMargin() {
  const rows = report.margin.filter(inBranch);
  const costed = sumOf(rows, 'costed_revenue');
  const cogs = sumOf(rows, 'cogs');
  const uncosted = sumOf(rows, 'uncosted_revenue');
  const suspect = sumOf(rows, 'suspect_revenue');
  const total = costed + uncosted + suspect;
  const gp = costed - cogs;
  document.getElementById('marginBox').innerHTML = costed > 0 ? `
    <div class="stat-value ${gp >= 0 ? 'mr-good' : 'mr-bad'}">${pct(gp, costed)}%</div>
    <p style="margin:4px 0;">${formatMoney(costed, true)} sales - ${formatMoney(cogs, true)} cost = <strong>${formatMoney(gp, true)}</strong> gross profit</p>
    <p class="muted" style="font-size:13px;">Only ${pct(costed, total)}% of this month's item sales have a cost on record, so this is a sample, not the full picture.
      ${formatMoney(uncosted, true)} of sales (custom builds, sets and items with no cost) can't be measured yet${suspect ? `, and ${formatMoney(suspect, true)} has a cost that looks wrong (see "Sold below cost")` : ''}.
      Add costs in Item Setup to make this more complete.</p>`
    : '<p class="muted">No sold items with a cost this month.</p>';
}

function renderInventoryCards(f, inv) {
  const card = (icon, label, value, sub, cls) => `
    <div class="stat-card"><div class="stat-label"><span class="stat-icon">${icon}</span> ${label}</div>
      <div class="stat-value ${cls || ''}">${value}</div><div class="muted" style="font-size:12px;">${sub}</div></div>`;
  const transfers = branchTransfers().filter((g) => g.shipped > g.received);
  document.getElementById('invCards').innerHTML = [
    card('🏬', 'Stock on hand (cost)', formatMoney(inv.stockValue, true),
      `${inv.stockItems} items in stock${inv.stockUncosted ? ` · ${inv.stockUncosted} have no cost (not counted)` : ''}`),
    card('📥', 'In vs sold (units)', `${formatQty(inv.inQty)} / ${formatQty(inv.soldQty)}`, 'Bought or made this month / sold this month'),
    card('❓', 'Missing in counts', formatMoney(inv.missingValue, true),
      `${formatQty(inv.missingQty)} units${inv.foundValue ? ` · found ${formatMoney(inv.foundValue, true)} extra` : ''}`, inv.missingQty > 0 ? 'mr-bad' : 'mr-good'),
    card('🗑️', 'Written off', formatMoney(inv.writtenOffValue, true), `${formatQty(inv.writtenOffQty)} units adjusted out`, inv.writtenOffQty > 0 ? 'mr-bad' : ''),
    card('🧽', 'Used in store', formatMoney(inv.usedValue, true), `${formatQty(inv.usedQty)} units expensed on the POS`),
    card('💵', 'Cash counts', f.cashShort < 0 ? formatMoney(f.cashShort, true) : 'Balanced',
      `short ${formatMoney(-f.cashShort, true)} · over ${formatMoney(f.cashOver, true)}`, f.cashShort < 0 ? 'mr-bad' : 'mr-good'),
    card('⛔', 'Negative stock', String(inv.negative.length), 'Items the system shows below zero - a sale or transfer with no stock on record', inv.negative.length ? 'mr-bad' : ''),
    card('🚚', 'Transfers in transit', String(transfers.length), `${formatQty(transfers.reduce((s, g) => s + g.shipped - g.received, 0))} units shipped, not received yet`)
  ].join('');
}

function renderLosses(items) {
  const rows = items.filter((x) => x.missing > 0 || x.adj_minus > 0)
    .map((x) => ({ ...x, value: (x.missing + x.adj_minus) * (Number(x.cost) || 0) }))
    .sort((a, b) => b.value - a.value || (b.missing + b.adj_minus) - (a.missing + a.adj_minus));
  document.getElementById('lossRows').innerHTML = rows.length
    ? rows.map((x) => `<tr><td>${escapeHtml(x.name)} <span class="muted">${escapeHtml(x.code)}</span></td><td>${escapeHtml(x.warehouse)}</td>
        <td class="num">${x.missing ? formatQty(x.missing) : ''}</td><td class="num">${x.adj_minus ? formatQty(x.adj_minus) : ''}</td>
        <td class="num">${x.cost ? formatMoney(x.value, true) : '<span class="muted">no cost</span>'}</td></tr>`).join('')
    : '<tr><td colspan="5" class="muted">Nothing missing or written off this month.</td></tr>';
}

function renderTransfers() {
  const rows = branchTransfers();
  document.getElementById('transferRows').innerHTML = rows.length
    ? rows.map((g) => {
      const age = daysAgo(g.shipped_date);
      const cls = g.received > g.shipped ? 'mr-bad' : age > 3 ? 'mr-bad' : '';
      const note = g.received > g.shipped ? 'received more than shipped' : g.received > 0 ? 'part received' : (g.status || 'not received');
      return `<tr><td><a href="transfer-orders.html" target="_blank" rel="noopener">${escapeHtml(g.doc)}</a><br><span class="muted" style="font-size:12px;">${escapeHtml(note)}</span></td>
        <td>${escapeHtml(g.from || '?')} &rarr; ${escapeHtml(g.to || '?')}</td>
        <td class="num">${formatQty(g.shipped)}</td><td class="num">${formatQty(g.received)}</td>
        <td class="${cls}">${shortDate(g.shipped_date)} (${age}d)</td></tr>`;
    }).join('')
    : '<tr><td colspan="5" class="muted">All transfers fully received.</td></tr>';
}

function renderBelowCost() {
  const rows = selectedBranch() ? report.below_cost.filter(inBranch) : report.below_cost;
  document.getElementById('belowCostRows').innerHTML = rows.length
    ? rows.map((b) => `<tr><td>${escapeHtml(b.name)} <span class="muted">${escapeHtml(b.code)}</span></td><td>${escapeHtml(b.warehouse)}</td>
        <td class="num">${formatQty(b.qty)}</td><td class="num">${formatMoney(b.revenue / b.qty)} ea</td><td class="num">${formatMoney(b.unit_cost)} ea</td>
        <td>${b.suspect ? '<span class="badge badge-warning">Check cost</span>' : '<span class="badge badge-danger">Loss</span>'}</td></tr>`).join('')
    : '<tr><td colspan="6" class="muted">Nothing sold below cost (among items with a cost).</td></tr>';
}

function renderTopItems() {
  const map = new Map();
  report.top_items.filter(inBranch).forEach((t) => {
    const e = map.get(t.code) || { name: t.name, code: t.code, qty: 0, revenue: 0 };
    e.qty += Number(t.qty) || 0;
    e.revenue += Number(t.revenue) || 0;
    map.set(t.code, e);
  });
  const rows = [...map.values()].sort((a, b) => b.revenue - a.revenue).slice(0, 10);
  document.getElementById('topRows').innerHTML = rows.length
    ? rows.map((t) => `<tr><td>${escapeHtml(t.name)}</td><td class="num">${formatQty(t.qty)}</td><td class="num">${formatMoney(t.revenue, true)}</td></tr>`).join('')
    : '<tr><td colspan="3" class="muted">No sales yet.</td></tr>';
}

function filteredItems() {
  const view = document.getElementById('itemView').value;
  const q = document.getElementById('itemSearch').value.trim().toLowerCase();
  return itemRows().filter((x) => {
    if (q && !`${x.code} ${x.name}`.toLowerCase().includes(q)) return false;
    const moved = x.purchased || x.produced || x.transfer_in || x.transfer_out || x.sold || x.used || x.found || x.missing || x.adj_plus || x.adj_minus;
    if (view === 'problems') return x.missing > 0 || x.adj_minus > 0 || x.closing < 0;
    if (view === 'moved') return !!moved;
    return x.closing !== 0 || moved;
  }).sort((a, b) => {
    const pa = (a.missing + a.adj_minus) * (Number(a.cost) || 1) + (a.closing < 0 ? 1e6 : 0);
    const pb = (b.missing + b.adj_minus) * (Number(b.cost) || 1) + (b.closing < 0 ? 1e6 : 0);
    return pb - pa || b.sold - a.sold || a.name.localeCompare(b.name);
  });
}

function renderItems() {
  const rows = filteredItems();
  const n = (v) => (v ? formatQty(v) : '<span class="muted">·</span>');
  document.getElementById('itemCount').textContent = `${rows.length.toLocaleString()} item${rows.length === 1 ? '' : 's'}`;
  document.getElementById('itemRows').innerHTML = rows.length
    ? rows.slice(0, itemLimit).map((x) => {
      const adj = x.adj_plus - x.adj_minus;
      return `<tr>
        <td>${escapeHtml(x.name)}<br><span class="muted" style="font-size:12px;">${escapeHtml(x.code)}${x.category ? ' · ' + escapeHtml(x.category) : ''}</span></td>
        <td>${escapeHtml(x.warehouse)}</td>
        <td class="num">${formatQty(x.opening)}</td><td class="num">${n(x.purchased + x.produced)}</td>
        <td class="num">${n(x.transfer_in)}</td><td class="num">${n(x.transfer_out)}</td>
        <td class="num">${n(x.sold)}</td><td class="num">${n(x.used)}</td>
        <td class="num">${n(x.found)}</td><td class="num${x.missing ? ' mr-bad' : ''}">${n(x.missing)}</td>
        <td class="num${adj < 0 ? ' mr-bad' : ''}">${adj ? (adj > 0 ? '+' : '') + formatQty(adj) : '<span class="muted">·</span>'}</td>
        <td class="num${x.closing < 0 ? ' mr-bad' : ''}"><strong>${formatQty(x.closing)}</strong></td>
        <td class="num">${x.cost ? formatMoney(Math.max(x.closing, 0) * x.cost, true) : '<span class="muted">no cost</span>'}</td>
      </tr>`;
    }).join('')
    : '<tr><td colspan="13" class="muted">No items match.</td></tr>';
  document.getElementById('moreItemsBtn').classList.toggle('hidden', rows.length <= itemLimit);
}

function exportCsv() {
  if (!report) return;
  const head = ['Item Code', 'Item Name', 'Category', 'Branch', 'Unit Cost', 'Opening', 'Purchased', 'Produced', 'Transfer In', 'Transfer Out',
    'Sold', 'Used In Store', 'Found', 'Missing', 'Adjusted +', 'Adjusted -', 'Closing', 'Closing Value'];
  const q = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const lines = [head.map(q).join(',')];
  filteredItems().forEach((x) => {
    lines.push([x.code, x.name, x.category, x.warehouse, x.cost ?? '', x.opening, x.purchased, x.produced, x.transfer_in, x.transfer_out,
      x.sold, x.used, x.found, x.missing, x.adj_plus, x.adj_minus, x.closing, x.cost ? (Math.max(x.closing, 0) * x.cost).toFixed(2) : ''].map(q).join(','));
  });
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `manager-report-items-${selectedMonthKey()}${selectedBranch() ? '-' + selectedBranch().replace(/\s+/g, '-') : ''}.csv`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------------------------------------- load

async function loadReport(keepOpen) {
  const loadingEl = document.getElementById('mrLoading');
  const errorEl = document.getElementById('mrError');
  const resultsEl = document.getElementById('mrResults');
  const editorOpen = document.getElementById('targetEditor').open;
  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  const key = selectedMonthKey();
  document.getElementById('nextMonthBtn').disabled = key >= manilaMonthKey();
  syncUrl();

  const { data, error } = await supabaseClient.rpc('admin_get_manager_report', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_month: `${key}-01`
  });
  loadingEl.classList.add('hidden');
  if (key !== selectedMonthKey()) return; // a newer month was picked while this loaded
  if (error) {
    errorEl.textContent = /admin_get_manager_report/.test(error.message) ? 'Run supabase_manager_report.sql in Supabase first.' : error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }
  report = data;

  const select = document.getElementById('warehouseSelect');
  const wanted = select.value || new URL(window.location.href).searchParams.get('branch') || '';
  select.innerHTML = '<option value="">All branches</option>' +
    report.warehouses.map((w) => `<option value="${escapeHtml(w)}">${escapeHtml(w)}</option>`).join('');
  select.value = report.warehouses.includes(wanted) ? wanted : '';

  itemLimit = 100;
  resultsEl.classList.remove('hidden');
  render();
  document.getElementById('targetEditor').open = keepOpen ? editorOpen : document.getElementById('targetEditor').open;
}

function setMonth(key) {
  document.getElementById('mrMonth').value = key > manilaMonthKey() ? manilaMonthKey() : key;
  loadReport();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav("Manager's Report");

  if (!session.isSuperUser) {
    document.getElementById('mrLoading').classList.add('hidden');
    const errorEl = document.getElementById('mrError');
    errorEl.textContent = 'Only a Super User can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  const fromUrl = new URL(window.location.href).searchParams.get('month');
  const monthInput = document.getElementById('mrMonth');
  monthInput.max = manilaMonthKey();
  monthInput.value = /^\d{4}-\d{2}$/.test(fromUrl || '') && fromUrl <= manilaMonthKey() ? fromUrl : manilaMonthKey();

  monthInput.addEventListener('change', () => loadReport());
  document.getElementById('prevMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), -1)));
  document.getElementById('nextMonthBtn').addEventListener('click', () => setMonth(shiftMonthKey(selectedMonthKey(), 1)));
  document.getElementById('thisMonthBtn').addEventListener('click', () => setMonth(manilaMonthKey()));
  document.getElementById('warehouseSelect').addEventListener('change', () => { syncUrl(); itemLimit = 100; render(); });
  document.getElementById('itemSearch').addEventListener('input', () => { itemLimit = 100; renderItems(); });
  document.getElementById('itemView').addEventListener('change', () => { itemLimit = 100; renderItems(); });
  document.getElementById('moreItemsBtn').addEventListener('click', () => { itemLimit += 100; renderItems(); });
  document.getElementById('saveTargetsBtn').addEventListener('click', saveTargets);
  document.getElementById('copyTargetsBtn').addEventListener('click', () => {
    document.querySelectorAll('.mr-target-input').forEach((inp) => { if (inp.dataset.prev) inp.value = inp.dataset.prev; });
    document.getElementById('targetMsg').textContent = 'Copied - press Save targets to keep them.';
  });
  document.getElementById('exportBtn').addEventListener('click', exportCsv);
  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadReport();
})();
