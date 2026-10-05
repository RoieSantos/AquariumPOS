// Payroll Spending report - per "can you create me a new report for my payroll.. i want to see how
// much im spending".
//
// admin_get_payroll_spending_report (supabase_payroll_spending_report.sql) returns the Payroll
// Ledger rows for the date range - finalized runs' BasePay / Addition / Deduction / NetPay per
// employee, plus CashAdvance rows on their release date. Everything else - the branch filter,
// grouping, shares and drilling into one group - happens here, so none of it re-queries.
//
//   Payroll Cost  = Base Pay + Additions - Deductions (excluding cash-advance repayments, which
//                   just recover money already paid out as the advance)
//   Cash Paid Out = Net Pay + Cash Advances released in the period
let currentSession = null;
let period = 'year'; // 'month' | 'prevmonth' | '90d' | 'year' | 'custom'
let reportRows = [];
let selected = null; // { group, key, name } being drilled into, else null

const COLOR = { base: 'var(--pm-s1)', additions: 'var(--pm-s3)', deductions: 'var(--pm-s8)', advances: 'var(--pm-s4)' };

const GROUP_LABEL = { employee: 'Employee', branch: 'Branch', month: 'Month', run: 'Pay Run', component: 'Pay Component' };

function toDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function formatMoney(value) {
  const amount = Number(value) || 0;
  return (amount < 0 ? '-' : '') + '₱' + Math.abs(amount).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatPercent(fraction) {
  const pct = (fraction || 0) * 100;
  return (pct > 0 && pct < 0.1 ? '<0.1' : pct.toFixed(1)) + '%';
}

function formatDate(key) {
  if (!key) return '';
  return new Date(key + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Asia/Manila "today", so the periods match the Dashboard's Payroll This Month card.
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
  if (period === 'month') {
    const from = new Date(today.getFullYear(), today.getMonth(), 1);
    const to = new Date(today.getFullYear(), today.getMonth() + 1, 0); // whole month - a pay date can be later this month
    return { from, to, label: from.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }) };
  }
  if (period === 'custom') {
    const fromVal = document.getElementById('dateFrom').value;
    const toVal = document.getElementById('dateTo').value;
    const from = fromVal ? new Date(fromVal + 'T00:00:00') : today;
    const to = toVal ? new Date(toVal + 'T00:00:00') : today;
    return { from, to, label: `${from.toLocaleDateString('en-US', fmt)} - ${to.toLocaleDateString('en-US', fmt)}` };
  }
  const from = new Date(today.getFullYear(), 0, 1);
  const to = new Date(today.getFullYear(), 11, 31);
  return { from, to, label: `${today.getFullYear()}` };
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

// ---------------------------------------------------------------- totals

// Cash advance repayments are posted as Deductions labelled "Cash Advance (...)".
function isAdvanceRepayment(r) {
  return r.entry_type === 'Deduction' && /^cash advance/i.test(String(r.label || '').trim());
}

function totalsOf(rows) {
  const t = { base: 0, additions: 0, deductions: 0, repaid: 0, net: 0, advances: 0, advanceCount: 0, employees: new Set(), runs: new Set() };
  rows.forEach((r) => {
    const amount = Number(r.amount) || 0;
    if (r.entry_type === 'BasePay') t.base += amount;
    else if (r.entry_type === 'Addition') t.additions += amount;
    else if (r.entry_type === 'Deduction') { if (isAdvanceRepayment(r)) t.repaid += amount; else t.deductions += amount; }
    else if (r.entry_type === 'NetPay') t.net += amount;
    else if (r.entry_type === 'CashAdvance') { t.advances += amount; t.advanceCount += 1; }
    if (r.username && r.entry_type !== 'CashAdvance') t.employees.add(r.username);
    if (r.run_id) t.runs.add(r.run_id);
  });
  t.cost = t.base + t.additions - t.deductions;
  t.cashOut = t.net + t.advances;
  return t;
}

function branchRows() {
  const branch = document.getElementById('branchSelect').value;
  return reportRows.filter((r) => !branch || (r.branch || '(No branch)') === branch);
}

// ---------------------------------------------------------------- grouping

// "Overtime (3.5 hrs)" / "Cash Advance (Oct 2)" -> one component per name.
function componentName(r) {
  if (isAdvanceRepayment(r)) return 'Cash Advance repayment';
  if (r.entry_type === 'BasePay') return 'Base Pay';
  if (r.entry_type === 'CashAdvance') return 'Cash Advance released';
  return String(r.label || r.entry_type).replace(/\s*\([^)]*\)\s*$/, '').trim() || r.entry_type;
}

function componentKind(r) {
  if (r.entry_type === 'BasePay') return 'Base Pay';
  if (r.entry_type === 'CashAdvance') return 'Cash Advance';
  return r.entry_type;
}

function groupOf(r, group) {
  switch (group) {
    case 'branch': {
      const name = r.branch || '(No branch)';
      return { key: name, name, sort: name };
    }
    case 'month': {
      const key = String(r.pay_date || '').slice(0, 7);
      const name = key ? new Date(key + '-01T00:00:00').toLocaleDateString('en-US', { month: 'long', year: 'numeric' }) : '(No date)';
      return { key, name, sort: key };
    }
    case 'run': {
      if (!r.run_id) return { key: 'advances', name: 'Cash advances (released between pay runs)', sort: '0' };
      const cycle = r.pay_cycle === 'SemiMonthly' ? 'Semi-Monthly' : (r.pay_cycle || '');
      return {
        key: r.run_id,
        name: `${cycle} ${formatDate(r.period_start)} - ${formatDate(r.period_end)}`.trim(),
        sub: `Paid ${formatDate(r.pay_date)}`,
        sort: String(r.pay_date || '')
      };
    }
    case 'component': {
      const name = componentName(r);
      return { key: `${componentKind(r)}|${name.toLowerCase()}`, name, sub: componentKind(r), sort: name };
    }
    default: {
      const name = r.display_name || r.username || '(Unknown)';
      return { key: r.username || name, name, sub: r.employee_no ? `#${r.employee_no}` : '', sort: name };
    }
  }
}

function groupRows(rows, group) {
  const byKey = new Map();
  rows.forEach((r) => {
    if (group === 'component' && r.entry_type === 'NetPay') return; // Net Pay is a result, not a component
    const g = groupOf(r, group);
    let entry = byKey.get(g.key);
    if (!entry) {
      entry = { ...g, rows: [] };
      byKey.set(g.key, entry);
    }
    entry.rows.push(r);
  });
  return [...byKey.values()];
}

// Which grouping a drill-down shows: one employee -> their pay runs, anything else -> employees.
function drillGroup(group) {
  return group === 'employee' ? 'run' : 'employee';
}

// ---------------------------------------------------------------- rendering

function shareCell(value, top, total, color) {
  return `
    <div class="pm-share">
      <div class="pm-share-track"><div class="pm-share-fill" style="width:${top > 0 ? Math.max(0, value / top) * 100 : 0}%; background:${color};"></div></div>
      <span class="pm-share-pct">${formatPercent(total > 0 ? value / total : 0)}</span>
    </div>`;
}

function renderSplit(t) {
  const bar = document.getElementById('splitBar');
  const legend = document.getElementById('splitLegend');
  const gross = t.base + t.additions;
  const parts = [['base', 'Base Pay', t.base], ['additions', 'Additions (overtime, bonuses...)', t.additions]];
  bar.innerHTML = gross > 0
    ? parts.filter((p) => p[2] > 0)
        .map(([key, label, amount]) => `<div class="ss-split-seg" style="flex-grow:${amount}; background:${COLOR[key]};" title="${label}: ${formatMoney(amount)} (${formatPercent(amount / gross)})"></div>`)
        .join('')
    : '<div class="ss-split-empty"></div>';
  const row = (key, label, amount, note) => `
    <div class="ss-split-legend-row">
      <span class="pm-swatch" style="background:${COLOR[key]};"></span><strong>${label}</strong>
      <span>${formatMoney(amount)}</span>
      <span class="muted">${note}</span>
    </div>`;
  legend.innerHTML =
    row('base', 'Base Pay', t.base, `${formatPercent(gross > 0 ? t.base / gross : 0)} of gross`) +
    row('additions', 'Additions', t.additions, `${formatPercent(gross > 0 ? t.additions / gross : 0)} of gross`) +
    row('deductions', 'Deductions', -t.deductions, 'absences, undertime...') +
    row('advances', 'Cash advances repaid', -t.repaid, 'taken off net pay');
}

function setStats(t) {
  document.getElementById('statCost').textContent = formatMoney(t.cost);
  document.getElementById('statCostSub').textContent = `Gross ${formatMoney(t.base + t.additions)} - deductions ${formatMoney(t.deductions)}`;
  document.getElementById('statCash').textContent = formatMoney(t.cashOut);
  document.getElementById('statCashSub').textContent = `Net pay ${formatMoney(t.net)} + advances ${formatMoney(t.advances)}`;
  document.getElementById('statAdvance').textContent = formatMoney(t.advances);
  document.getElementById('statAdvanceSub').textContent = `${t.advanceCount} advance${t.advanceCount === 1 ? '' : 's'} - ${formatMoney(t.repaid)} repaid through payroll`;
  document.getElementById('statEmployees').textContent = String(t.employees.size);
  document.getElementById('statEmployeesSub').textContent = t.employees.size
    ? `avg ${formatMoney(t.cost / t.employees.size)} each - ${t.runs.size} pay run${t.runs.size === 1 ? '' : 's'}`
    : 'No finalized pay runs in this period';
}

function nameCell(g, clickable) {
  const sub = g.sub ? `<div class="muted" style="font-size:12px;">${escapeHtml(g.sub)}</div>` : '';
  return `<td>${clickable ? `<a href="#" class="cs-link">${escapeHtml(g.name)}</a>` : escapeHtml(g.name)}${sub}</td>`;
}

function sortGroups(groups, group, valueOf) {
  if (group === 'month' || group === 'run') return groups.sort((a, b) => String(b.sort).localeCompare(String(a.sort)));
  return groups.sort((a, b) => valueOf(b) - valueOf(a));
}

// Cost table: one row per group with the pay breakdown.
function renderCostTable(rows, group, clickable) {
  const groups = groupRows(rows, group).map((g) => ({ ...g, t: totalsOf(g.rows) }));
  sortGroups(groups, group, (g) => g.t.cost);
  const total = totalsOf(rows).cost;
  const top = Math.max(0, ...groups.map((g) => g.t.cost));

  document.getElementById('psTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>${GROUP_LABEL[group]}</th>
      <th style="text-align:right;">Base Pay</th>
      <th style="text-align:right;">Additions</th>
      <th style="text-align:right;">Deductions</th>
      <th style="text-align:right;">Payroll Cost</th>
      <th style="min-width:160px;">% of Cost</th>
      <th style="text-align:right;">Cash Advances</th>
      <th style="text-align:right;">Net Pay</th>
    </tr>`;
  const tbody = document.getElementById('psTableBody');
  if (groups.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No finalized payroll or cash advances in this period.</td></tr>';
    return groups;
  }
  tbody.innerHTML = groups
    .map((g, i) => `
      <tr${clickable ? ` class="cs-row-link" data-key="${escapeHtml(g.key)}" tabindex="0" title="See what is inside ${escapeHtml(g.name)}"` : ''}>
        <td>${i + 1}</td>
        ${nameCell(g, clickable)}
        <td style="text-align:right;">${formatMoney(g.t.base)}</td>
        <td style="text-align:right;">${formatMoney(g.t.additions)}</td>
        <td style="text-align:right;">${g.t.deductions ? formatMoney(-g.t.deductions) : formatMoney(0)}</td>
        <td style="text-align:right;"><strong>${formatMoney(g.t.cost)}</strong></td>
        <td>${shareCell(g.t.cost, top, total, COLOR.base)}</td>
        <td style="text-align:right;">${formatMoney(g.t.advances)}</td>
        <td style="text-align:right;">${formatMoney(g.t.net)}</td>
      </tr>`)
    .join('');
  return groups;
}

// Component table: Base Pay / each addition / each deduction / cash advances, as amounts.
function renderComponentTable(rows, clickable) {
  const groups = groupRows(rows, 'component').map((g) => ({
    ...g,
    amount: g.rows.reduce((s, r) => s + (Number(r.amount) || 0), 0),
    employees: new Set(g.rows.map((r) => r.username).filter(Boolean)).size
  }));
  const order = { 'Base Pay': 0, Addition: 1, Deduction: 2, 'Cash Advance': 3 };
  groups.sort((a, b) => (order[a.sub] - order[b.sub]) || (b.amount - a.amount));
  const cost = totalsOf(rows).cost;
  const top = Math.max(0, ...groups.map((g) => g.amount));

  document.getElementById('psTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Pay Component</th>
      <th style="text-align:right;">Amount</th>
      <th style="min-width:160px;">vs Payroll Cost</th>
      <th style="text-align:right;">Employees</th>
    </tr>`;
  const tbody = document.getElementById('psTableBody');
  if (groups.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No finalized payroll or cash advances in this period.</td></tr>';
    return groups;
  }
  const colorOf = (g) => (g.sub === 'Deduction' ? COLOR.deductions : g.sub === 'Addition' ? COLOR.additions : g.sub === 'Cash Advance' ? COLOR.advances : COLOR.base);
  tbody.innerHTML = groups
    .map((g, i) => `
      <tr${clickable ? ` class="cs-row-link" data-key="${escapeHtml(g.key)}" tabindex="0" title="See who got ${escapeHtml(g.name)}"` : ''}>
        <td>${i + 1}</td>
        ${nameCell(g, clickable)}
        <td style="text-align:right;">${formatMoney(g.sub === 'Deduction' ? -g.amount : g.amount)}</td>
        <td>${shareCell(g.amount, top, cost, colorOf(g))}</td>
        <td style="text-align:right;">${g.employees}</td>
      </tr>`)
    .join('');
  return groups;
}

// Inside one component: who got it, and how much.
function renderComponentDrill(rows) {
  const groups = groupRows(rows, 'employee').map((g) => ({ ...g, amount: g.rows.reduce((s, r) => s + (Number(r.amount) || 0), 0), count: g.rows.length }));
  groups.sort((a, b) => b.amount - a.amount);
  const total = groups.reduce((s, g) => s + g.amount, 0);
  const top = Math.max(0, ...groups.map((g) => g.amount));
  document.getElementById('psTableHead').innerHTML = `
    <tr>
      <th style="width:40px;">#</th>
      <th>Employee</th>
      <th style="text-align:right;">Amount</th>
      <th style="min-width:160px;">% of This Component</th>
      <th style="text-align:right;">Entries</th>
    </tr>`;
  document.getElementById('psTableBody').innerHTML = groups
    .map((g, i) => `
      <tr>
        <td>${i + 1}</td>
        ${nameCell(g, false)}
        <td style="text-align:right;">${formatMoney(g.amount)}</td>
        <td>${shareCell(g.amount, top, total, COLOR.base)}</td>
        <td style="text-align:right;">${g.count}</td>
      </tr>`)
    .join('');
}

function wireRowClicks(group, groups) {
  document.querySelectorAll('#psTableBody .cs-row-link').forEach((tr) => {
    const open = (e) => {
      e.preventDefault();
      const g = groups.find((x) => String(x.key) === tr.dataset.key);
      if (!g) return;
      selected = { group, key: g.key, name: g.name };
      render();
    };
    tr.addEventListener('click', open);
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') open(e); });
  });
}

function render() {
  const rows = branchRows();
  const t = totalsOf(rows);
  setStats(t);
  renderSplit(t);

  const group = document.getElementById('groupSelect').value;
  if (selected && selected.group !== group) selected = null;
  const inGroup = selected ? rows.filter((r) => String(groupOf(r, selected.group).key) === String(selected.key)) : [];
  if (selected && inGroup.length === 0) selected = null; // filtered away - back to the overview

  document.getElementById('backBtn').classList.toggle('hidden', !selected);
  document.getElementById('groupByWrap').querySelectorAll('select, span').forEach((el) => el.classList.toggle('hidden', !!selected));

  if (selected) {
    if (selected.group === 'component') {
      document.getElementById('tableTitle').textContent = `${selected.name} - by employee`;
      renderComponentDrill(inGroup.filter((r) => r.entry_type !== 'NetPay'));
    } else {
      const sub = drillGroup(selected.group);
      document.getElementById('tableTitle').textContent = `${selected.name} - by ${GROUP_LABEL[sub].toLowerCase()}`;
      renderCostTable(inGroup, sub, false);
    }
    return;
  }

  document.getElementById('tableTitle').textContent = `Payroll cost by ${GROUP_LABEL[group].toLowerCase()}`;
  const groups = group === 'component' ? renderComponentTable(rows, true) : renderCostTable(rows, group, true);
  wireRowClicks(group, groups);
}

// The table on screen, as CSV (Excel opens it directly).
function exportCsv() {
  const csv = (v) => {
    const s = String(v ?? '').replace(/\s+/g, ' ').trim();
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  const lines = [...document.querySelectorAll('#psTableHead tr, #psTableBody tr')]
    .map((tr) => [...tr.children].map((cell) => csv(cell.textContent)).join(','));
  const blob = new Blob(['﻿' + [document.getElementById('periodLabel').textContent, ...lines].join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `payroll-spending-${toDateKey(manilaToday())}.csv`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

async function loadReport() {
  const loadingEl = document.getElementById('psLoading');
  const errorEl = document.getElementById('psError');
  const resultsEl = document.getElementById('psResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');

  const range = computeRange();
  document.getElementById('periodLabel').textContent = range.label;

  const { data, error } = await supabaseClient.rpc('admin_get_payroll_spending_report', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_date_from: toDateKey(range.from),
    p_date_to: toDateKey(range.to)
  });

  loadingEl.classList.add('hidden');
  if (error) {
    errorEl.textContent = error.code === 'PGRST202'
      ? 'This report needs sql/supabase_payroll_spending_report.sql to be run first.'
      : error.message;
    errorEl.classList.remove('hidden');
    resultsEl.classList.add('hidden');
    return;
  }

  reportRows = data || [];
  const select = document.getElementById('branchSelect');
  const current = select.value;
  const branches = [...new Set(reportRows.map((r) => r.branch || '(No branch)'))].sort();
  select.innerHTML = '<option value="">All branches</option>' +
    branches.map((b) => `<option value="${escapeHtml(b)}">${escapeHtml(b)}</option>`).join('');
  select.value = branches.includes(current) ? current : '';

  render();
  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payroll Spending Report');

  if (!session.isSuperUser && !session.isPayrollOfficer) {
    document.getElementById('psLoading').classList.add('hidden');
    const errorEl = document.getElementById('psError');
    errorEl.textContent = 'Only a Super User or Payroll Officer can view this report.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.querySelectorAll('[data-period]').forEach((btn) => {
    btn.addEventListener('click', () => setPeriod(btn.dataset.period));
  });
  document.getElementById('applyRangeBtn').addEventListener('click', loadReport);
  document.getElementById('backBtn').addEventListener('click', () => { selected = null; render(); });
  document.getElementById('branchSelect').addEventListener('change', render);
  document.getElementById('groupSelect').addEventListener('change', () => { selected = null; render(); });
  document.getElementById('exportBtn').addEventListener('click', exportCsv);

  await loadReport();
})();
