// Payroll Runs list page logic (super users only). Creating a run (admin_create_payroll_run)
// auto-generates one line per active employee enrolled in that pay cycle (see payrollSetup.js
// for enrolling employees) - this page only lists/creates runs; editing a run's lines/line items
// happens in payroll-run.html.
let currentSession = null;
let currentPage = 1;
let currentPageSize = 25;
let cutoffSettings = null; // loaded once from admin_get_payroll_cutoff_settings, used by autofillDates()

function toDateInputValue(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

// Computes Period Start/End/Pay Date for a given cutoff ('A'/'B') and target month ("YYYY-MM"),
// per the fixed day-of-month rules in PayrollCutoffSettings. StartDay > EndDay means the period
// starts in the month BEFORE the target month (e.g. 26 -> 10 spans two months); PayDayIsLastDay
// resolves to the target month's actual last calendar day (new Date(y, m, 0) trick).
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
}

function formatCurrency(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatDate(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString();
}

function formatCycleLabel(cycle) {
  return cycle === 'SemiMonthly' ? 'Semi-Monthly' : cycle === 'Weekly' ? 'Weekly' : cycle || '';
}

function renderRunRows(runs) {
  const tbody = document.getElementById('runTableBody');

  if (!runs || runs.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No payroll runs found.</td></tr>';
    return;
  }

  tbody.innerHTML = runs
    .map((r) => `
      <tr>
        <td>${formatDate(r.period_start)} - ${formatDate(r.period_end)}</td>
        <td>${formatCycleLabel(r.pay_cycle)}</td>
        <td>${formatDate(r.pay_date)}</td>
        <td><span class="badge ${r.status === 'Finalized' ? 'badge-success' : 'badge-warning'}">${r.status}</span></td>
        <td>${r.employee_count}</td>
        <td>${formatCurrency(r.total_net_pay)}</td>
        <td>${r.created_by || ''}</td>
        <td><a class="btn btn-secondary btn-sm" href="payroll-run.html?run=${r.run_id}">Open</a></td>
      </tr>
    `)
    .join('');
}

async function loadRuns() {
  const tbody = document.getElementById('runTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_runs', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderRunRows(data);

  renderPaginationBar(
    document.getElementById('runPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadRuns(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadRuns(); }
    }
  );
}

function updateCutoffRowVisibility() {
  const isSemiMonthly = document.getElementById('newRunPayCycle').value === 'SemiMonthly';
  document.getElementById('cutoffAutofillRow').classList.toggle('hidden', !isSemiMonthly);
}

function openNewRunModal() {
  document.getElementById('newRunPayCycle').value = 'SemiMonthly';
  document.getElementById('newRunCutoff').value = 'A';
  const now = new Date();
  document.getElementById('newRunTargetMonth').value = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  document.getElementById('newRunPeriodStart').value = '';
  document.getElementById('newRunPeriodEnd').value = '';
  document.getElementById('newRunPayDate').value = '';
  document.getElementById('newRunError').classList.add('hidden');
  updateCutoffRowVisibility();
  document.getElementById('newRunModal').classList.remove('hidden');
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
  renderTopNav('Payroll');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  document.getElementById('payrollContent').classList.remove('hidden');
  await loadRuns();
  await loadCutoffSettingsOnce();

  document.getElementById('newRunBtn').addEventListener('click', openNewRunModal);
  document.getElementById('closeNewRunBtn').addEventListener('click', () =>
    document.getElementById('newRunModal').classList.add('hidden')
  );
  document.getElementById('saveRunBtn').addEventListener('click', saveNewRun);
  document.getElementById('newRunPayCycle').addEventListener('change', updateCutoffRowVisibility);
  document.getElementById('autofillDatesBtn').addEventListener('click', autofillDates);
})();
