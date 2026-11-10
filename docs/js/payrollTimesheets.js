// Employee Timesheets (super users + payroll officers). Officer/supervisor enters daily hours
// worked per employee - not employee self-service clock-in, and a plain hours number per day
// (not clock in/out times) - see supabase_payroll_timesheets.sql. admin_create_payroll_run reads
// these to auto-post an Overtime Addition / Undertime Deduction per employee when a run is
// created, using the standard hours/day, work days/month, and overtime multiplier configured in
// Payroll Setup's Overtime Settings.
let currentSession = null;
let employeeOptions = []; // [{ username, display_name }] from admin_list_payroll_employees
let currentEntries = [];
let currentPage = 1;
let currentPageSize = 50;
let weekStart = null; // Date - Monday of the week currently shown in the grid
let cutoffSettings = null; // loaded once from admin_get_payroll_cutoff_settings, used by autofillDates()
// Xendit cash advances (sql/supabase_xendit_cash_advance_payouts.sql): who can be paid by Xendit, and this week's
// Xendit advances + their payouts (admin_list_cash_advance_payouts). Both empty until that SQL is run.
let payoutFlags = {}; // username -> { pay_via_xendit, has_account }
let advancePayouts = [];
let advancePayoutBusy = false;
let advanceBalanceInfo = null;

const WEEKDAY_LABELS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function formatDate(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString();
}

function toDateInputValue(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function getMondayOf(date) {
  const d = new Date(date);
  const day = d.getDay(); // 0 = Sunday
  const diff = day === 0 ? -6 : 1 - day; // shift back to Monday
  d.setDate(d.getDate() + diff);
  return d;
}

function weekDates(monday) {
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(monday);
    d.setDate(d.getDate() + i);
    return d;
  });
}

async function loadEmployeeOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_payroll_employees', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    employeeOptions = [];
    return;
  }

  // Only active employees actually enrolled in a pay cycle ever go through a payroll run, so
  // there's no point logging timesheets for anyone inactive or "Not enrolled" (pay_cycle null).
  employeeOptions = (data || []).filter((e) => e.is_active && e.pay_cycle);

  const filterSelect = document.getElementById('filterUsername');
  const entrySelect = document.getElementById('entryUsername');
  const optionsHtml = employeeOptions
    .map((e) => `<option value="${e.username}">${e.display_name || e.username}</option>`)
    .join('');

  filterSelect.innerHTML = '<option value="">All employees</option>' + optionsHtml;
  entrySelect.innerHTML = optionsHtml;
}

// Weekly grid: one row per active employee, one column per day (Mon-Sun) of the selected week,
// plus one Cash Advance column (one amount per employee for the whole week, not per day - see
// supabase_payroll_cash_advances_bulk_entry.sql). Each hours cell is pre-filled from any existing
// timesheet entry; the Cash Advance cell is pre-filled from any Outstanding advance already dated
// somewhere inside this week.
function renderWeekGrid(dates, existingByKey, advanceByUsername) {
  const thead = document.getElementById('bulkEntryTableHead');
  const tbody = document.getElementById('bulkEntryTableBody');

  const headerCells = dates
    .map((d, i) => `<th class="num">${WEEKDAY_LABELS[i]} <span class="muted" style="font-weight:normal;">${d.getMonth() + 1}/${d.getDate()}</span></th>`)
    .join('');
  thead.innerHTML = `<tr><th>Employee</th>${headerCells}<th class="num">Total</th><th class="num" title="Weekly-cycle employees only: gross pay for this week assuming perfect attendance (standard hours every day, no overtime, plus paid rest day), before the cash advance is deducted">Weekly Pay</th><th class="num">Cash Advance</th><th>Method</th></tr>`;

  document.getElementById('bulkEntryTableFoot').innerHTML = employeeOptions.length === 0 ? '' : `
    <tr style="font-weight:600;">
      <td colspan="${dates.length + 3}" class="num">Total Cash Advance for the week</td>
      <td id="caTotalCell" class="num">0.00</td>
      <td id="caTotalByMethodCell" class="muted" style="font-weight:normal; white-space:nowrap;"></td>
    </tr>`;

  if (employeeOptions.length === 0) {
    tbody.innerHTML = `<tr><td colspan="${dates.length + 5}" class="cell-msg">No active employees found.</td></tr>`;
    return;
  }

  tbody.innerHTML = employeeOptions
    .map((e) => {
      const cells = dates
        .map((d) => {
          const key = `${e.username}|${toDateInputValue(d)}`;
          const existing = existingByKey[key];
          const value = existing ? existing.hours_worked : '';
          const locked = !!existing;
          return `<td class="qty-cell-wrap num"><input type="number" class="bulk-hours bc-qty-cell" data-date="${toDateInputValue(d)}" min="0" max="24" step="0.5" value="${value}" style="width:64px;" ${locked ? 'disabled title="Saved - correct it in All Entries below"' : ''} /></td>`;
        })
        .join('');
      const advance = advanceByUsername[e.username];
      const flags = payoutFlags[e.username] || {};
      const caValue = advance ? advance.amount : '';
      // A new advance starts as Xendit for a "Pay salary via Xendit" employee with a payout account.
      const caMethod = advance ? advance.method : (flags.pay_via_xendit && flags.has_account ? 'Xendit' : 'Cash');
      const caLocked = !!advance;
      const payout = advance ? advancePayouts.find((p) => p.advance_id === advance.id) : null;
      // Applied (already deducted), or sent / paid through Xendit for real: stays locked even after Unlock Editing.
      const caApplied = advance?.status === 'Applied' ? 'data-applied="1" title="Already deducted in a payroll run"'
        : advancePayoutLocked(payout) ? 'data-applied="1" title="Already sent through Xendit"' : '';
      const showXendit = flags.has_account || caMethod === 'Xendit';
      return `
        <tr data-username="${e.username}">
          <td>${e.display_name || e.username}</td>
          ${cells}
          <td class="row-total num" style="font-weight:600;">0.00</td>
          <td class="row-weekly-pay num">${e.pay_cycle === 'Weekly'
            ? perfectAttendanceWeeklyPay(e, dates).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
            : '<span class="muted">-</span>'}</td>
          <td class="qty-cell-wrap num"><input type="number" class="bulk-ca bc-qty-cell" min="0" step="0.01" value="${caValue}" style="width:90px;" placeholder="0.00" ${caLocked ? 'disabled' : ''} ${caApplied} /></td>
          <td class="qty-cell-wrap">
            <select class="bulk-ca-method bc-cell-select" ${caLocked ? 'disabled' : ''} ${caApplied}>
              <option value="Cash" ${caMethod === 'Cash' ? 'selected' : ''}>Cash</option>
              <option value="Digital" ${caMethod === 'Digital' ? 'selected' : ''}>Digital (GCash)</option>
              ${showXendit ? `<option value="Xendit" ${caMethod === 'Xendit' ? 'selected' : ''}>Xendit</option>` : ''}
            </select>
            ${advance && advance.method === 'Xendit' ? `<div style="font-size:11px; margin-top:2px;">${advanceStatusHtml(payout || {})}</div>` : ''}
          </td>
        </tr>
      `;
    })
    .join('');

  updateRowTotals();
  updateCashAdvanceTotal();
}

// Footer: total Cash Advance for the week (saved + typed-but-unsaved cells), split by method so the
// officer knows how much cash and GCash to have on hand.
function updateCashAdvanceTotal() {
  const totalCell = document.getElementById('caTotalCell');
  if (!totalCell) return;

  let cash = 0;
  let digital = 0;
  let xendit = 0;
  document.querySelectorAll('#bulkEntryTableBody tr[data-username]').forEach((row) => {
    const amount = Number(row.querySelector('.bulk-ca')?.value) || 0;
    const method = row.querySelector('.bulk-ca-method')?.value;
    if (method === 'Digital') digital += amount;
    else if (method === 'Xendit') xendit += amount;
    else cash += amount;
  });

  const fmt = (n) => n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  totalCell.textContent = fmt(cash + digital + xendit);
  document.getElementById('caTotalByMethodCell').textContent = `Cash ${fmt(cash)} / GCash ${fmt(digital)}${xendit ? ` / Xendit ${fmt(xendit)}` : ''}`;
}

function updateRowTotals() {
  document.querySelectorAll('#bulkEntryTableBody tr[data-username]').forEach((row) => {
    let total = 0;
    row.querySelectorAll('.bulk-hours').forEach((input) => {
      total += Number(input.value) || 0;
    });
    const totalCell = row.querySelector('.row-total');
    if (totalCell) totalCell.textContent = total.toFixed(2);
  });
}

// Weekly-cycle employee's gross pay for the week shown, assuming perfect attendance (standard
// hours every day, no overtime) - before Cash Advance and any other deductions. A client-side copy
// of admin_create_payroll_run's Weekly branches (supabase_payroll_semimonthly_absent_deduction.sql),
// so keep the two in sync:
//   Hourly: min(hours, std) x DailyRate/std per day, + overtime past std at x OT multiplier.
//   Salary: each calendar day is priced at MonthlySalary / days in THAT month, scaled by
//           min(hours, std)/std, + overtime the same way; blended across a month boundary.
//   Paid Rest Day adds one more day (DailyRate for Hourly, the effective day rate for Salary).
function perfectAttendanceWeeklyPay(employee, dates) {
  const stdHours = Number(cutoffSettings?.standard_hours_per_day) || 8;
  const hoursByDate = {};
  dates.forEach((d) => { hoursByDate[toDateInputValue(d)] = stdHours; });
  return estimateWeeklyPay(employee, hoursByDate);
}

function estimateWeeklyPay(employee, hoursByDate) {
  const dates = Object.keys(hoursByDate);
  const stdHours = Number(cutoffSettings?.standard_hours_per_day) || 8;
  const otMultiplier = Number(cutoffSettings?.overtime_multiplier) || 1.25;
  let base = 0;
  let overtime = 0;
  let dayRate = 0;

  if (employee.pay_type === 'Hourly') {
    const hourlyRate = (Number(employee.daily_rate) || 0) / stdHours;
    dates.forEach((d) => {
      const hours = hoursByDate[d];
      base += Math.min(hours, stdHours) * hourlyRate;
      overtime += Math.max(hours - stdHours, 0) * hourlyRate * otMultiplier;
    });
    dayRate = Number(employee.daily_rate) || 0;
  } else {
    const monthly = Number(employee.monthly_salary) || 0;
    let daysWorked = 0;
    dates.forEach((d) => {
      const date = new Date(d + 'T00:00:00');
      const dailyRate = monthly / new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate();
      const hours = hoursByDate[d];
      base += Math.min(hours, stdHours) / stdHours * dailyRate;
      overtime += Math.max(hours - stdHours, 0) * (dailyRate / stdHours) * otMultiplier;
      daysWorked += Math.min(hours, stdHours) / stdHours;
    });
    dayRate = daysWorked > 0 ? Math.round(base / daysWorked * 100) / 100 : 0;
  }

  const paidRestDay = employee.has_paid_rest_day && dayRate > 0 ? dayRate : 0;
  return Math.round(base * 100) / 100 + Math.round(overtime * 100) / 100 + paidRestDay;
}

function renderWeekRangeLabel(dates) {
  const start = dates[0];
  const end = dates[6];
  document.getElementById('weekRangeLabel').textContent =
    `${start.toLocaleDateString()} - ${end.toLocaleDateString()}`;
}

// ---------------------------------------------------------------- Xendit cash advances
// sql/supabase_xendit_cash_advance_payouts.sql + Edge Function xendit-payroll-payout (send_advances /
// refresh_advances). A Xendit advance is saved 'Pending'; once Xendit confirms the payout it turns 'Outstanding' and
// the next payroll run deducts it. Sending is super users only (the function re-checks).
const ADVANCE_PAYOUT_GOING = ['Creating', 'ACCEPTED', 'REQUESTED'];

async function loadPayoutFlagsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_payroll_payout_flags', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  payoutFlags = {};
  if (error) return; // SQL not run yet - the grid just offers Cash / Digital
  (data || []).forEach((f) => { payoutFlags[f.username] = { pay_via_xendit: !!f.pay_via_xendit, has_account: !!f.has_account }; });
}

function escapeHtmlText(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function formatPeso(n) {
  return '₱' + (Number(n) || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// A LIVE payout on its way or paid - the advance can't be changed any more.
function advancePayoutLocked(p) {
  return !!(p && p.status && !p.is_test && (p.status === 'SUCCEEDED' || ADVANCE_PAYOUT_GOING.includes(p.status)));
}

function advancePayoutStatusHtml(p) {
  const test = p.is_test ? ' <strong style="color:#b45309;">TEST</strong>' : '';
  if (!p.status) return '<span class="muted">Not sent</span>';
  if (p.status === 'SUCCEEDED') {
    return `<span style="color:var(--success);">Paid</span>${p.paid_at ? ` <span class="muted">${new Date(p.paid_at).toLocaleDateString()}</span>` : ''}${test}`;
  }
  if (ADVANCE_PAYOUT_GOING.includes(p.status)) return `<span style="color:#a6720a;">Sending...</span>${test}`;
  const label = p.status === 'Error' ? 'Not sent' : p.status.charAt(0) + p.status.slice(1).toLowerCase();
  return `<span style="color:var(--danger);">${escapeHtmlText(label)}</span>${test}`
    + (p.failure ? ` <span class="muted" title="${escapeHtmlText(p.failure)}">- ${escapeHtmlText(p.failure)}</span>` : '');
}

// Still to pay for real: Pending, has an account, and no live payout going / paid.
function advancePayoutPending(p) {
  return p.advance_status === 'Pending' && p.has_account && Number(p.amount) > 0 && !advancePayoutLocked(p);
}

// Approval: a payroll officer submits, a super user sends only submitted ones.
function advanceNeedsSubmit(p) {
  return advancePayoutPending(p) && !p.submitted_at;
}

function advanceReadyToSend(p) {
  return advancePayoutPending(p) && !!p.submitted_at;
}

// Approval step + payout status, for the grid and the dialog.
function advanceStatusHtml(p) {
  if (!advancePayoutPending(p)) return advancePayoutStatusHtml(p);
  const step = p.submitted_at
    ? `<span style="color:#a6720a;" title="Submitted by ${escapeHtmlText(p.submitted_by || '')}">Waiting for approval</span>`
    : '<span class="muted">Not submitted</span>';
  // A failed / refused earlier try is still worth seeing.
  return p.status ? `${step} · ${advancePayoutStatusHtml(p)}` : step;
}

function updateSendAdvancesButton() {
  const show = advancePayouts.length > 0;
  const waiting = advancePayouts.filter(advanceReadyToSend).length;
  const btn = document.getElementById('sendAdvancesBtn');
  btn.classList.toggle('hidden', !show);
  document.getElementById('sendAdvancesSep').classList.toggle('hidden', !show);
  btn.lastChild.textContent = currentSession.isSuperUser && waiting
    ? `Xendit Advances (${waiting} to approve)` : 'Xendit Advances';
}

async function callPayoutFunction(payload) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/xendit-payroll-payout`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`, 'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY },
    body: JSON.stringify({ ...payload, username: currentSession.username, password: currentSession.password })
  });
  const data = await response.json().catch(() => null);
  if (response.status === 404) throw new Error('The xendit-payroll-payout Edge Function isn\'t deployed yet.');
  if (!response.ok) throw new Error(data?.error || `HTTP ${response.status}`);
  return data;
}

// Xendit available balance - one shared read (force = re-read), shown in the bar above the grid and in the
// Xendit Advances dialog. Payroll officers can see it too; only super users send.
let xenditBalancePromise = null;

function getXenditBalance(force) {
  if (force || !xenditBalancePromise) {
    xenditBalancePromise = callPayoutFunction({ action: 'balance' }).catch((err) => ({ error: err.message }));
  }
  return xenditBalancePromise;
}

async function loadXenditBalanceBar(force) {
  const bar = document.getElementById('xenditBalanceBar');
  const info = await getXenditBalance(force);
  const has = typeof info?.balance === 'number';
  bar.innerHTML = `<span class="bc-infobar-text">Xendit available balance: <strong>${has ? formatPeso(info.balance) : '-'}</strong>`
    + (has && info.isTest ? ' <strong style="color:#b45309;">TEST mode</strong>' : '')
    + (has && !info.isTest ? ' <span class="muted">Live - sales still settling aren\'t counted yet</span>' : '')
    + (!has && info?.error ? ` <span class="muted">${escapeHtmlText(info.error)}</span>` : '')
    + '</span><button class="bc-link" type="button" data-refresh-xendit-balance>Refresh</button>';
  bar.classList.remove('hidden');
}

async function reloadAdvancePayouts() {
  const dates = weekDates(weekStart);
  const { data, error } = await supabaseClient.rpc('admin_list_cash_advance_payouts', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_week_start: toDateInputValue(dates[0]),
    p_week_end: toDateInputValue(dates[6])
  });
  if (!error) advancePayouts = data || [];
  return error;
}

function showAdvancePayoutMessage(text, isError) {
  const el = document.getElementById('advancePayoutMessage');
  el.textContent = text || '';
  el.className = `bc-dialog-msg ${isError ? 'error-text' : 'muted'}`;
  el.classList.toggle('hidden', !text);
}

function renderAdvancePayoutDialog() {
  const tbody = document.getElementById('advancePayoutBody');
  if (!advancePayouts.length) {
    tbody.innerHTML = '<tr><td colspan="6" class="cell-msg">No Xendit cash advances this week. Pick Xendit as the Method in the grid and click Save All.</td></tr>';
  } else {
    tbody.innerHTML = advancePayouts.map((p) => {
      const payTo = p.payout_channel && !advancePayoutPending(p) ? `${escapeHtmlText(p.payout_channel)} ${escapeHtmlText(p.payout_account_masked || '')}`
        : p.has_account ? `${escapeHtmlText(p.channel_name)} ${escapeHtmlText(p.account_masked || '')}`
          : '<span class="error-text">No payout account - add it in Payroll Setup</span>';
      const deducted = p.advance_status === 'Applied' ? ' <span class="muted">(deducted)</span>' : '';
      return `<tr>
        <td>${escapeHtmlText(p.display_name || p.username)}</td>
        <td>${escapeHtmlText(formatDate(p.advance_date))}</td>
        <td>${payTo}</td>
        <td>${escapeHtmlText(p.account_name || '')}</td>
        <td class="num">${formatPeso(p.amount)}</td>
        <td>${advanceStatusHtml(p)}${deducted}</td>
      </tr>`;
    }).join('');
  }

  const toSubmit = advancePayouts.filter(advanceNeedsSubmit);
  const submitTotal = toSubmit.reduce((s, p) => s + (Number(p.amount) || 0), 0);
  const pending = advancePayouts.filter(advanceReadyToSend);
  const toSend = pending.reduce((s, p) => s + (Number(p.amount) || 0), 0);
  const info = advanceBalanceInfo;
  const balance = info && typeof info.balance === 'number' ? info.balance : null;
  const mode = !info || info.error ? ''
    : info.isTest ? '<strong style="color:#b45309;">TEST mode</strong> - no real money moves, and the advances stay unpaid.' : '<strong>LIVE</strong> - real money.';
  document.getElementById('advancePayoutSummary').innerHTML = `
    ${mode ? `<div>${mode}</div>` : ''}
    ${toSubmit.length ? `<div>Not submitted yet: <strong>${formatPeso(submitTotal)}</strong> for ${toSubmit.length} employee${toSubmit.length === 1 ? '' : 's'}</div>` : ''}
    <div>Waiting for approval: <strong>${formatPeso(toSend)}</strong> for ${pending.length} employee${pending.length === 1 ? '' : 's'}</div>
    <div>Xendit available balance: <strong>${balance == null ? '-' : formatPeso(balance)}</strong>${balance != null && balance < toSend ? ' <span class="error-text">- not enough; wait for sales to settle or top up Xendit</span>' : ''}</div>`;

  const submitBtn = document.getElementById('submitAdvancesBtn');
  submitBtn.classList.toggle('hidden', toSubmit.length === 0);
  submitBtn.disabled = advancePayoutBusy;
  submitBtn.textContent = `Submit for Approval (${formatPeso(submitTotal)})`;
  submitBtn.dataset.ids = JSON.stringify(toSubmit.map((p) => p.advance_id));

  const sendBtn = document.getElementById('sendAdvancePayoutsBtn');
  sendBtn.classList.toggle('hidden', !currentSession.isSuperUser);
  sendBtn.disabled = advancePayoutBusy || pending.length === 0;
  sendBtn.textContent = pending.length ? `Approve & Send ${formatPeso(toSend)}` : 'Nothing to approve';
  sendBtn.dataset.total = String(toSend);
  sendBtn.dataset.ids = JSON.stringify(pending.map((p) => p.advance_id));
}

async function openAdvancePayoutDialog() {
  document.getElementById('advancePayoutModal').classList.remove('hidden');
  showAdvancePayoutMessage('');
  document.getElementById('advancePayoutBody').innerHTML = '<tr><td colspan="6" class="cell-msg">Loading...</td></tr>';
  const [balanceInfo, listError] = await Promise.all([
    getXenditBalance(true),
    reloadAdvancePayouts()
  ]);
  advanceBalanceInfo = balanceInfo;
  renderAdvancePayoutDialog();
  if (listError) showAdvancePayoutMessage(listError.message, true);
  else if (balanceInfo?.error) showAdvancePayoutMessage(balanceInfo.error, true);
}

async function closeAdvancePayoutDialog() {
  document.getElementById('advancePayoutModal').classList.add('hidden');
  await loadWeekGrid();
}

async function sendAdvancePayouts() {
  const btn = document.getElementById('sendAdvancePayoutsBtn');
  const ids = JSON.parse(btn.dataset.ids || '[]');
  const total = Number(btn.dataset.total) || 0;
  if (!ids.length || advancePayoutBusy) return;
  const mode = advanceBalanceInfo?.isTest ? 'TEST (no real money)' : 'LIVE - real money';
  if (!confirm(`Approve and send ${formatPeso(total)} in cash advances to ${ids.length} employee${ids.length === 1 ? '' : 's'} through Xendit?\n\nMode: ${mode}\n\nThis can't be undone.`)) return;
  advancePayoutBusy = true;
  btn.disabled = true;
  btn.textContent = 'Sending...';
  showAdvancePayoutMessage('Sending - keep this window open...');
  try {
    const result = await callPayoutFunction({ action: 'send_advances', advanceIds: ids });
    const failed = result.failed || [];
    showAdvancePayoutMessage(
      result.note || (`${result.sent} sent.`
        + (failed.length ? ` ${failed.length} not sent: ${failed.map((f) => `${f.name} (${f.error})`).join('; ')}` : ' Xendit confirms each one shortly - press Refresh Status.')),
      failed.length > 0
    );
  } catch (err) {
    showAdvancePayoutMessage(err.message, true);
  } finally {
    advancePayoutBusy = false;
    await reloadAdvancePayouts();
    advanceBalanceInfo = await getXenditBalance(true);
    renderAdvancePayoutDialog();
    loadXenditBalanceBar();
  }
}

async function submitAdvances() {
  const btn = document.getElementById('submitAdvancesBtn');
  const ids = JSON.parse(btn.dataset.ids || '[]');
  if (!ids.length || advancePayoutBusy) return;
  if (!confirm(`Submit ${ids.length} Xendit cash advance${ids.length === 1 ? '' : 's'} for a super user to approve?\n\nChanging an amount afterwards takes it out of approval until it's submitted again.`)) return;
  advancePayoutBusy = true;
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_submit_cash_advances', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_advance_ids: ids
  });
  const result = Array.isArray(data) ? data[0] : data;
  showAdvancePayoutMessage(error?.message || result?.message || 'Could not submit.', !!error || !result?.success);
  advancePayoutBusy = false;
  await reloadAdvancePayouts();
  renderAdvancePayoutDialog();
}

async function refreshAdvancePayouts() {
  const btn = document.getElementById('refreshAdvancePayoutsBtn');
  btn.disabled = true;
  showAdvancePayoutMessage('Checking with Xendit...');
  try {
    const result = await callPayoutFunction({ action: 'refresh_advances' });
    showAdvancePayoutMessage(result.checked ? `Checked ${result.checked} payout${result.checked === 1 ? '' : 's'} with Xendit.` : 'Nothing waiting on Xendit.');
  } catch (err) {
    showAdvancePayoutMessage(err.message, true);
  } finally {
    btn.disabled = false;
    await reloadAdvancePayouts();
    renderAdvancePayoutDialog();
  }
}

async function loadWeekGrid() {
  const errorEl = document.getElementById('bulkEntryError');
  errorEl.classList.add('hidden');

  const dates = weekDates(weekStart);
  renderWeekRangeLabel(dates);

  const [{ data, error }, { data: advanceData, error: advanceError }, payoutResult] = await Promise.all([
    supabaseClient.rpc('admin_list_timesheet_entries', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_username: null,
      p_date_start: toDateInputValue(dates[0]),
      p_date_end: toDateInputValue(dates[6]),
      p_page: 1,
      p_page_size: 500
    }),
    supabaseClient.rpc('admin_list_cash_advances', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_username: null,
      p_status: null, // Outstanding AND Applied - a run being created must not blank the column
      p_date_start: toDateInputValue(dates[0]),
      p_date_end: toDateInputValue(dates[6]),
      p_page: 1,
      p_page_size: 500
    }),
    supabaseClient.rpc('admin_list_cash_advance_payouts', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_week_start: toDateInputValue(dates[0]),
      p_week_end: toDateInputValue(dates[6])
    })
  ]);
  advancePayouts = payoutResult?.error ? [] : (payoutResult?.data || []);
  updateSendAdvancesButton();

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }
  if (advanceError) {
    errorEl.textContent = advanceError.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const existingByKey = {};
  (data || []).forEach((t) => { existingByKey[`${t.username}|${t.work_date}`] = t; });

  const advanceByUsername = {};
  // Applied advances (already deducted in a payroll run) still show, but stay locked even after
  // Unlock Editing - admin_upsert_cash_advances_bulk only updates Outstanding / Pending ones, so re-saving an
  // Applied amount would create a duplicate advance. An Outstanding / Pending (Xendit, not paid yet) one wins if a
  // week has both.
  const editable = (s) => s === 'Outstanding' || s === 'Pending';
  (advanceData || []).forEach((a) => {
    if (!editable(a.status) && a.status !== 'Applied') return;
    if (editable(advanceByUsername[a.username]?.status)) return;
    advanceByUsername[a.username] = { id: a.advance_id, amount: a.amount, method: a.method, status: a.status };
  });

  renderWeekGrid(dates, existingByKey, advanceByUsername);
  refreshWeeklyProjectedFunding();
}

// Super User only - client-side re-enable of every locked cell in the grid as currently shown, so
// a mistake can be corrected and re-saved without going through the All Entries list / Payroll
// Setup's Cash Advances journal. Nothing is changed in the database until Save All is clicked again.
function unlockEditing() {
  document.querySelectorAll('#bulkEntryTableBody .bulk-hours:disabled, #bulkEntryTableBody .bulk-ca:disabled:not([data-applied]), #bulkEntryTableBody .bulk-ca-method:disabled:not([data-applied])').forEach((input) => {
    input.disabled = false;
    input.style.background = '';
    input.style.color = '';
  });
}

async function saveBulkEntry() {
  const errorEl = document.getElementById('bulkEntryError');
  errorEl.classList.add('hidden');

  const entries = [];
  const caEntries = [];
  document.querySelectorAll('#bulkEntryTableBody tr[data-username]').forEach((row) => {
    const username = row.getAttribute('data-username');
    row.querySelectorAll('.bulk-hours:not(:disabled)').forEach((input) => {
      const hours = Number(input.value);
      if (!input.value || !(hours > 0)) return;
      entries.push({ username, work_date: input.getAttribute('data-date'), hours_worked: hours });
    });
    const caInput = row.querySelector('.bulk-ca:not(:disabled)');
    const caMethodInput = row.querySelector('.bulk-ca-method:not(:disabled)');
    if (caInput) caEntries.push({ username, amount: Number(caInput.value) || 0, method: caMethodInput ? caMethodInput.value : 'Cash' });
  });

  if (entries.length === 0 && caEntries.every((c) => !(c.amount > 0))) {
    errorEl.textContent = 'Nothing entered - fill in at least one hours or cash advance cell.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Cells with data lock (gray out) once saved - see renderWeekGrid - so this is the one chance to
  // change what's about to be submitted.
  if (!confirm('Once saved this entry cannot be modified, continue saving?')) return;

  const saveBtn = document.getElementById('saveBulkEntryBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  if (entries.length > 0) {
    const { data, error } = await supabaseClient.rpc('admin_upsert_timesheet_entries_bulk', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_entries: entries
    });

    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result || !result.success) {
      saveBtn.disabled = false;
      saveBtn.textContent = 'Save All';
      errorEl.textContent = error?.message || result?.message || 'Failed to save timesheet entries.';
      errorEl.classList.remove('hidden');
      return;
    }
  }

  // Cash Advance is a per-week amount, not per-day - a Thursday release date is assigned to any
  // brand-new advance; an existing Outstanding advance already dated inside this week is updated
  // (or removed, if its cell was cleared back to blank/0) instead of creating a duplicate.
  const dates = weekDates(weekStart);
  const { data: caData, error: caError } = await supabaseClient.rpc('admin_upsert_cash_advances_bulk', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_advance_date: toDateInputValue(dates[3]),
    p_week_start: toDateInputValue(dates[0]),
    p_week_end: toDateInputValue(dates[6]),
    p_entries: caEntries
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save All';

  const caResult = Array.isArray(caData) ? caData[0] : caData;
  if (caError || !caResult || !caResult.success) {
    errorEl.textContent = caError?.message || caResult?.message || 'Failed to save cash advances.';
    errorEl.classList.remove('hidden');
    return;
  }

  await loadWeekGrid();
  await loadEntries();
}

function renderEntryRows(entries) {
  currentEntries = entries || [];
  const tbody = document.getElementById('timesheetTableBody');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="cell-msg">No timesheet entries found.</td></tr>';
    selectedEntryId = null;
    updateEntryActionState();
    return;
  }

  tbody.innerHTML = entries
    .map((t) => `
      <tr data-entry-id="${t.timesheet_id}" class="${String(t.timesheet_id) === String(selectedEntryId) ? 'selected' : ''}">
        <td>${t.display_name || t.username || ''}</td>
        <td>${formatDate(t.work_date)}</td>
        <td class="num">${Number(t.hours_worked).toFixed(2)}</td>
        <td>${t.notes || ''}</td>
      </tr>
    `)
    .join('');
  if (!entries.some((x) => String(x.timesheet_id) === String(selectedEntryId))) selectedEntryId = null;
  updateEntryActionState();
}

// BC list: Edit / Delete on the All Entries toolbar act on the selected entry (double-click edits).
let selectedEntryId = null;

function updateEntryActionState() {
  document.getElementById('editEntryBtn').disabled = !selectedEntryId;
  document.getElementById('deleteEntryBtn').disabled = !selectedEntryId;
}

async function loadEntries() {
  const tbody = document.getElementById('timesheetTableBody');
  tbody.innerHTML = '<tr><td colspan="4" class="cell-msg">Loading...</td></tr>';

  const username = document.getElementById('filterUsername').value || null;
  const dateStart = document.getElementById('filterDateStart').value || null;
  const dateEnd = document.getElementById('filterDateEnd').value || null;

  const { data, error } = await supabaseClient.rpc('admin_list_timesheet_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_username: username,
    p_date_start: dateStart,
    p_date_end: dateEnd,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="4" class="cell-msg error-text">${error.message}</td></tr>`;
    return;
  }

  renderEntryRows(data);

  renderPaginationBar(
    document.getElementById('timesheetPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadEntries(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadEntries(); }
    }
  );
}

function openNewEntryModal() {
  document.getElementById('entryModalTitle').textContent = 'Add Timesheet Entry';
  document.getElementById('entryUsername').disabled = false;
  document.getElementById('entryUsername').value = employeeOptions[0]?.username || '';
  document.getElementById('entryWorkDate').value = '';
  document.getElementById('entryHoursWorked').value = 8;
  document.getElementById('entryNotes').value = '';
  document.getElementById('saveEntryBtn').dataset.editId = '';
  document.getElementById('entryError').classList.add('hidden');
  document.getElementById('entryModal').classList.remove('hidden');
}

function openEditEntryModal(timesheetId) {
  const entry = currentEntries.find((t) => t.timesheet_id === timesheetId);
  if (!entry) return;

  document.getElementById('entryModalTitle').textContent = 'Edit Timesheet Entry';
  document.getElementById('entryUsername').value = entry.username;
  document.getElementById('entryUsername').disabled = true;
  document.getElementById('entryWorkDate').value = entry.work_date;
  document.getElementById('entryHoursWorked').value = entry.hours_worked;
  document.getElementById('entryNotes').value = entry.notes || '';
  document.getElementById('saveEntryBtn').dataset.editId = timesheetId;
  document.getElementById('entryError').classList.add('hidden');
  document.getElementById('entryModal').classList.remove('hidden');
}

async function saveEntry() {
  const errorEl = document.getElementById('entryError');
  errorEl.classList.add('hidden');

  const editId = document.getElementById('saveEntryBtn').dataset.editId;
  const username = document.getElementById('entryUsername').value;
  const workDate = document.getElementById('entryWorkDate').value;
  const hoursWorked = Number(document.getElementById('entryHoursWorked').value);
  const notes = document.getElementById('entryNotes').value.trim();

  if (!username || !workDate || !(hoursWorked > 0)) {
    errorEl.textContent = 'Employee, work date, and hours worked (greater than zero) are all required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveEntryBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = editId
    ? await supabaseClient.rpc('admin_update_timesheet_entry', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_timesheet_id: editId,
        p_work_date: workDate,
        p_hours_worked: hoursWorked,
        p_notes: notes || null
      })
    : await supabaseClient.rpc('admin_add_timesheet_entry', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_username: username,
        p_work_date: workDate,
        p_hours_worked: hoursWorked,
        p_notes: notes || null
      });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Entry';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to save timesheet entry.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('entryModal').classList.add('hidden');
  await loadWeekGrid();
  await loadEntries();
}

async function deleteEntry(timesheetId) {
  if (!confirm('Delete this timesheet entry?')) return;

  const { data, error } = await supabaseClient.rpc('admin_delete_timesheet_entry', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_timesheet_id: timesheetId
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    alert(error?.message || result?.message || 'Failed to delete timesheet entry.');
    return;
  }

  await loadWeekGrid();
  await loadEntries();
}

// New Payroll Run modal (same flow as payroll.html/payroll.js's "+ New Payroll Run") - lets the
// officer go straight from a filled-in week grid to creating the run that will read those hours.
async function loadCutoffSettingsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_get_payroll_cutoff_settings', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    cutoffSettings = null;
    return;
  }
  cutoffSettings = Array.isArray(data) ? data[0] : data;
}

function computeCutoffDates(cutoffLetter, targetMonthValue) {
  if (!cutoffSettings || !targetMonthValue) return null;

  const [yearStr, monthStr] = targetMonthValue.split('-');
  const year = Number(yearStr);
  const month = Number(monthStr); // 1-12

  const startDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_start_day : cutoffSettings.cutoff_b_start_day;
  const endDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_end_day : cutoffSettings.cutoff_b_end_day;
  const payDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_pay_day : cutoffSettings.cutoff_b_pay_day;
  const payIsLastDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_pay_day_is_last_day_of_month : cutoffSettings.cutoff_b_pay_day_is_last_day_of_month;

  const periodEnd = new Date(year, month - 1, endDay);
  const periodStart = startDay > endDay ? new Date(year, month - 2, startDay) : new Date(year, month - 1, startDay);
  const payDate = payIsLastDay ? new Date(year, month, 0) : new Date(year, month - 1, payDay);

  return { periodStart, periodEnd, payDate };
}

function autofillDates() {
  const cutoffLetter = document.getElementById('newRunCutoff').value;
  const targetMonth = document.getElementById('newRunTargetMonth').value;
  const errorEl = document.getElementById('newRunError');

  const dates = computeCutoffDates(cutoffLetter, targetMonth);
  if (!dates) {
    errorEl.textContent = 'Pick a month, and make sure Cutoff Settings are configured in Payroll Setup.';
    errorEl.classList.remove('hidden');
    return;
  }
  errorEl.classList.add('hidden');

  document.getElementById('newRunPeriodStart').value = toDateInputValue(dates.periodStart);
  document.getElementById('newRunPeriodEnd').value = toDateInputValue(dates.periodEnd);
  document.getElementById('newRunPayDate').value = toDateInputValue(dates.payDate);
  refreshProjectedFunding();
}

function autofillWeeklyDates() {
  const payDateValue = document.getElementById('newRunWeeklyPayDate').value;
  const errorEl = document.getElementById('newRunError');

  if (!payDateValue) {
    errorEl.textContent = 'Pick a pay date first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const payDate = new Date(payDateValue + 'T00:00:00');
  if (payDate.getDay() !== 0) {
    errorEl.textContent = 'Weekly pay date should be a Sunday.';
    errorEl.classList.remove('hidden');
    return;
  }
  errorEl.classList.add('hidden');

  const periodStart = new Date(payDate);
  periodStart.setDate(periodStart.getDate() - 6);

  document.getElementById('newRunPeriodStart').value = toDateInputValue(periodStart);
  document.getElementById('newRunPeriodEnd').value = toDateInputValue(payDate);
  document.getElementById('newRunPayDate').value = toDateInputValue(payDate);
  refreshProjectedFunding();
}

// Shows "this run will need PxK Cash / PyK Digital, you have PaK / PbK on hand" in the New Payroll
// Run modal, computed by actually running admin_create_payroll_run's real math and rolling it back
// (supabase_payroll_projected_run_requirement.sql) - so the officer knows how much to prepare
// before committing, without a second hand-written copy of the pay calculation drifting out of
// sync with the real one.
async function refreshProjectedFunding() {
  const box = document.getElementById('projectedFundingBox');
  const noteEl = document.getElementById('projectedFundingNote');

  const payCycle = document.getElementById('newRunPayCycle').value;
  const periodStart = document.getElementById('newRunPeriodStart').value || null;
  const periodEnd = document.getElementById('newRunPeriodEnd').value || null;
  const payDate = document.getElementById('newRunPayDate').value || null;

  if (!periodStart || !periodEnd) {
    box.classList.add('hidden');
    noteEl.classList.add('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('admin_get_projected_payroll_run_requirement', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_pay_cycle: payCycle,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_pay_date: payDate
  });

  if (error) {
    box.classList.add('hidden');
    noteEl.textContent = error.message || 'Could not compute projected funding for this period yet.';
    noteEl.classList.remove('hidden');
    return;
  }

  noteEl.classList.add('hidden');
  const result = Array.isArray(data) ? data[0] : data;
  document.getElementById('projectedCashLine').innerHTML = formatProjectedFundingLine(Number(result?.cash_required || 0), Number(result?.cash_balance || 0));
  document.getElementById('projectedDigitalLine').innerHTML = formatProjectedFundingLine(Number(result?.digital_required || 0), Number(result?.digital_balance || 0));
  box.classList.remove('hidden');
}

function formatProjectedFundingLine(required, balance) {
  const shortfall = required - balance;
  const statusHtml = shortfall > 0
    ? `<span style="color:var(--danger);">short by ₱${shortfall.toFixed(2)}</span>`
    : `<span style="color:var(--success);">covered</span>`;
  return `<strong>₱${required.toFixed(2)}</strong> needed - ₱${balance.toFixed(2)} on hand, ${statusHtml}`;
}

// Always-visible quick-glance version on the main Timesheets page itself (not just inside the New
// Payroll Run modal) - mirrors exactly what "Create Payroll Run from This Week" defaults to
// (Weekly pay cycle, period = the week currently shown) so the officer sees it without having to
// open the modal first. If the week has SemiMonthly employees too, use the modal (pick SemiMonthly
// + the real cutoff dates there) for an accurate projection of their run instead.
async function refreshWeeklyProjectedFunding() {
  const box = document.getElementById('weeklyProjectedFundingBox');
  const noteEl = document.getElementById('weeklyProjectedFundingNote');
  const dates = weekDates(weekStart);

  document.getElementById('weeklyProjectedFundingLabel').textContent =
    `Projected funding needed if a Weekly payroll run is created for this week (${dates[0].getMonth() + 1}/${dates[0].getDate()} - ${dates[6].getMonth() + 1}/${dates[6].getDate()})`;

  const { data, error } = await supabaseClient.rpc('admin_get_projected_payroll_run_requirement', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_pay_cycle: 'Weekly',
    p_period_start: toDateInputValue(dates[0]),
    p_period_end: toDateInputValue(dates[6]),
    p_pay_date: toDateInputValue(dates[6])
  });

  if (error) {
    box.classList.add('hidden');
    noteEl.textContent = error.message || 'Could not compute projected funding for this week yet.';
    noteEl.classList.remove('hidden');
    return;
  }

  noteEl.classList.add('hidden');
  const result = Array.isArray(data) ? data[0] : data;
  document.getElementById('weeklyProjectedCashLine').innerHTML = formatProjectedFundingLine(Number(result?.cash_required || 0), Number(result?.cash_balance || 0));
  document.getElementById('weeklyProjectedDigitalLine').innerHTML = formatProjectedFundingLine(Number(result?.digital_required || 0), Number(result?.digital_balance || 0));
  box.classList.remove('hidden');
}

function updateCutoffRowVisibility() {
  const payCycle = document.getElementById('newRunPayCycle').value;
  document.getElementById('cutoffAutofillRow').classList.toggle('hidden', payCycle !== 'SemiMonthly');
  document.getElementById('weeklyAutofillRow').classList.toggle('hidden', payCycle !== 'Weekly');
}

// Runs whichever autofill matches the currently selected Pay Cycle - wired to every field that
// feeds that computation (Pay Cycle/Cutoff/Month, or the Weekly pay date) so Period Start/End/Pay
// Date are always kept in sync automatically, per "add validation on all fields that it will
// automatically autofill dates - this will avoid manual clicking of Autofill Dates". The buttons
// stay in the markup as a harmless manual re-trigger, but nothing depends on clicking them anymore.
function autofillForCurrentCycle() {
  const payCycle = document.getElementById('newRunPayCycle').value;
  if (payCycle === 'Weekly') {
    autofillWeeklyDates();
  } else {
    autofillDates();
  }
}

function handlePayCycleChange() {
  updateCutoffRowVisibility();
  autofillForCurrentCycle();
}

// Defaults to the week currently shown in the grid, since that's almost always the week whose
// hours the officer just finished entering.
// Per "cannot do create payroll run if there are timesheets pending to save" - typed-but-unsaved
// grid cells are only ever sitting in this page's own <input> elements (locked/disabled cells are
// already-saved data, so they're excluded), never in the run itself - a run created right now would
// simply miss whatever hasn't been clicked "Save All" yet, which reads as data silently dropped.
function hasPendingTimesheetChanges() {
  const hoursPending = Array.from(document.querySelectorAll('#bulkEntryTableBody .bulk-hours:not(:disabled)'))
    .some((input) => input.value !== '' && Number(input.value) > 0);
  const caPending = Array.from(document.querySelectorAll('#bulkEntryTableBody .bulk-ca:not(:disabled)'))
    .some((input) => Number(input.value) > 0);
  return hoursPending || caPending;
}

function openNewRunModal() {
  const dates = weekDates(weekStart);
  const sunday = dates[6];

  document.getElementById('newRunPayCycle').value = 'Weekly';
  document.getElementById('newRunCutoff').value = 'A';
  document.getElementById('newRunTargetMonth').value = `${weekStart.getFullYear()}-${String(weekStart.getMonth() + 1).padStart(2, '0')}`;
  document.getElementById('newRunWeeklyPayDate').value = toDateInputValue(sunday);
  document.getElementById('newRunError').classList.add('hidden');
  updateCutoffRowVisibility();
  document.getElementById('newRunModal').classList.remove('hidden');
  autofillWeeklyDates();
}

async function saveNewRun() {
  const errorEl = document.getElementById('newRunError');
  errorEl.classList.add('hidden');

  const payCycle = document.getElementById('newRunPayCycle').value;
  const periodStart = document.getElementById('newRunPeriodStart').value || null;
  const periodEnd = document.getElementById('newRunPeriodEnd').value || null;
  const payDate = document.getElementById('newRunPayDate').value || null;

  if (!periodStart || !periodEnd) {
    errorEl.textContent = 'Period start and end are required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveRunBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Creating...';

  const { data, error } = await supabaseClient.rpc('admin_create_payroll_run', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_pay_cycle: payCycle,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_pay_date: payDate
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Create Run';

  if (error || !data) {
    errorEl.textContent = error?.message || 'Failed to create payroll run.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('newRunModal').classList.add('hidden');
  window.location.href = `payroll-run.html?run=${data}`;
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Timesheets');

  if (!session.isSuperUser && !session.isPayrollOfficer) {
    // Per "if a user dont have permission just show them payslips by default" - see payroll.js.
    window.location.href = 'my-payslips.html';
    return;
  }

  document.getElementById('timesheetsContent').classList.remove('hidden');
  document.getElementById('unlockEditingBtn').classList.toggle('hidden', !session.isSuperUser);
  loadXenditBalanceBar();
  document.getElementById('xenditBalanceBar').addEventListener('click', (e) => {
    if (e.target.closest('[data-refresh-xendit-balance]')) loadXenditBalanceBar(true);
  });
  await Promise.all([loadEmployeeOptionsOnce(), loadPayoutFlagsOnce()]);
  await loadEntries();
  await loadCutoffSettingsOnce();

  weekStart = getMondayOf(new Date());
  await loadWeekGrid();

  document.getElementById('prevWeekBtn').addEventListener('click', () => {
    weekStart.setDate(weekStart.getDate() - 7);
    loadWeekGrid();
  });
  document.getElementById('nextWeekBtn').addEventListener('click', () => {
    weekStart.setDate(weekStart.getDate() + 7);
    loadWeekGrid();
  });

  document.getElementById('createRunFromTimesheetsBtn').addEventListener('click', () => {
    const errorEl = document.getElementById('bulkEntryError');
    if (hasPendingTimesheetChanges()) {
      errorEl.textContent = 'You have unsaved hours or cash advance entries in the grid below - click Save All first before creating a payroll run.';
      errorEl.classList.remove('hidden');
      errorEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return;
    }
    errorEl.classList.add('hidden');
    openNewRunModal();
  });
  const closeNewRun = () => document.getElementById('newRunModal').classList.add('hidden');
  document.getElementById('closeNewRunBtn').addEventListener('click', closeNewRun);
  document.getElementById('cancelNewRunBtn').addEventListener('click', closeNewRun);
  document.getElementById('saveRunBtn').addEventListener('click', saveNewRun);
  document.getElementById('newRunPayCycle').addEventListener('change', handlePayCycleChange);
  document.getElementById('newRunCutoff').addEventListener('change', autofillDates);
  document.getElementById('newRunTargetMonth').addEventListener('change', autofillDates);
  document.getElementById('newRunWeeklyPayDate').addEventListener('change', autofillWeeklyDates);
  document.getElementById('autofillDatesBtn').addEventListener('click', autofillDates);
  document.getElementById('autofillWeeklyDatesBtn').addEventListener('click', autofillWeeklyDates);
  document.getElementById('newRunPeriodStart').addEventListener('change', refreshProjectedFunding);
  document.getElementById('newRunPeriodEnd').addEventListener('change', refreshProjectedFunding);
  document.getElementById('newRunPayDate').addEventListener('change', refreshProjectedFunding);
  document.getElementById('bulkEntryTableBody').addEventListener('input', (e) => {
    if (e.target.classList.contains('bulk-hours')) updateRowTotals();
    if (e.target.classList.contains('bulk-ca')) updateCashAdvanceTotal();
  });
  document.getElementById('bulkEntryTableBody').addEventListener('change', (e) => {
    if (e.target.classList.contains('bulk-ca-method')) updateCashAdvanceTotal();
  });
  document.getElementById('saveBulkEntryBtn').addEventListener('click', saveBulkEntry);
  document.getElementById('sendAdvancesBtn').addEventListener('click', openAdvancePayoutDialog);
  document.getElementById('sendAdvancePayoutsBtn').addEventListener('click', sendAdvancePayouts);
  document.getElementById('submitAdvancesBtn').addEventListener('click', submitAdvances);
  document.getElementById('refreshAdvancePayoutsBtn').addEventListener('click', refreshAdvancePayouts);
  document.querySelectorAll('[data-close-advance-payout]').forEach((btn) => btn.addEventListener('click', closeAdvancePayoutDialog));
  document.getElementById('unlockEditingBtn').addEventListener('click', unlockEditing);

  document.getElementById('toggleAllEntriesBtn').addEventListener('click', (e) => {
    const section = document.getElementById('allEntriesSection');
    const willBecomeVisible = section.classList.contains('hidden');
    section.classList.toggle('hidden', !willBecomeVisible);
    e.target.textContent = willBecomeVisible ? 'Hide All Entries' : 'Show All Entries';
  });

  document.getElementById('applyFiltersBtn').addEventListener('click', () => { currentPage = 1; loadEntries(); });
  document.getElementById('newEntryBtn').addEventListener('click', openNewEntryModal);
  const closeEntryModal = () => document.getElementById('entryModal').classList.add('hidden');
  document.getElementById('closeEntryModalBtn').addEventListener('click', closeEntryModal);
  document.getElementById('cancelEntryModalBtn').addEventListener('click', closeEntryModal);
  document.getElementById('saveEntryBtn').addEventListener('click', saveEntry);

  const entryBody = document.getElementById('timesheetTableBody');
  entryBody.addEventListener('click', (e) => {
    const tr = e.target.closest('tr[data-entry-id]');
    if (!tr) return;
    selectedEntryId = tr.dataset.entryId;
    entryBody.querySelectorAll('tr[data-entry-id]').forEach((row) => row.classList.toggle('selected', row === tr));
    updateEntryActionState();
  });
  entryBody.addEventListener('dblclick', (e) => {
    const tr = e.target.closest('tr[data-entry-id]');
    if (tr) openEditEntryModal(tr.dataset.entryId);
  });
  document.getElementById('editEntryBtn').addEventListener('click', () => selectedEntryId && openEditEntryModal(selectedEntryId));
  document.getElementById('deleteEntryBtn').addEventListener('click', () => selectedEntryId && deleteEntry(selectedEntryId));
})();
