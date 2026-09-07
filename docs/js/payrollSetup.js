// Payroll Setup page logic (super users only). Assigns each StaffUsers row a PayCycle +
// MonthlySalary via admin_update_payroll_profile - these two columns live on StaffUsers itself
// ("Employees are the one on the usersetup") but are only ever written from here, never from
// User Setup's own edit modal.
let currentSession = null;
let allEmployees = [];
let currentEmployees = [];

function formatCycle(cycle) {
  if (cycle === 'SemiMonthly') return '<span class="badge badge-primary">Semi-Monthly</span>';
  if (cycle === 'Weekly') return '<span class="badge badge-primary">Weekly</span>';
  return '<span class="badge badge-neutral">Not enrolled</span>';
}

function formatCurrency(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatPaymentMethod(method) {
  if (method === 'Cash') return '<span class="badge badge-neutral">Cash</span>';
  if (method === 'Digital') return '<span class="badge badge-primary">Digital (GCash)</span>';
  return '<span class="muted">Not set (Cash)</span>';
}

function formatPayType(payType) {
  return payType === 'Hourly' ? '<span class="badge badge-primary">Hourly</span>' : '<span class="badge badge-neutral">Salary</span>';
}

const WEEKDAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

// Null means every blank day in a period counts as Absent (supabase_payroll_absent_day_deduction.sql);
// a weekday here is excused from that entirely (supabase_payroll_paid_rest_day.sql).
function formatPaidRestDay(paidRestDay) {
  if (paidRestDay === null || paidRestDay === undefined) return '<span class="muted">None</span>';
  return `<span class="badge badge-neutral">${WEEKDAY_NAMES[paidRestDay] || paidRestDay}</span>`;
}

// Salary shows Monthly Salary; Hourly shows Base Pay is computed from Timesheets (Daily Rate / 8 x
// hours worked) instead - the "Rate" column reflects whichever actually applies to that employee.
function formatRate(e) {
  return e.pay_type === 'Hourly'
    ? formatCurrency(e.daily_rate) + '<span class="muted">/day</span>'
    : formatCurrency(e.monthly_salary) + '<span class="muted">/mo</span>';
}

function renderEmployeeRows(employees) {
  currentEmployees = employees || [];
  const tbody = document.getElementById('employeeTableBody');

  if (!employees || employees.length === 0) {
    const message = allEmployees.length === 0
      ? 'No staff logins found.'
      : 'No employees match the current filters.';
    tbody.innerHTML = `<tr><td colspan="9" class="muted">${message}</td></tr>`;
    return;
  }

  tbody.innerHTML = employees
    .map((e) => `
      <tr>
        <td>${e.username || ''}</td>
        <td>${e.display_name || ''}</td>
        <td><span class="badge ${e.is_active ? 'badge-success' : 'badge-danger'}">${e.is_active ? 'Active' : 'Inactive'}</span></td>
        <td>${formatCycle(e.pay_cycle)}</td>
        <td>${formatPayType(e.pay_type)}</td>
        <td>${formatRate(e)}</td>
        <td>${formatPaymentMethod(e.payment_method)}</td>
        <td>${formatPaidRestDay(e.paid_rest_day)}</td>
        <td><button class="btn btn-secondary btn-sm" data-edit-username="${e.username}" type="button">Edit</button></td>
      </tr>
    `)
    .join('');
}

async function loadEmployees() {
  const tbody = document.getElementById('employeeTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_employees', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    return;
  }

  allEmployees = data || [];
  applyFilters();
}

// Business Central-style per-field filters. Text columns use a "contains" match, or a "*"
// wildcard for an exact/anchored pattern; prefix with "<>" to exclude a match. Monthly Salary
// accepts BC's numeric filter syntax: a bare number for exact match, ">"/">="/"<"/"<="/"<>"
// prefixes, or "min..max" ranges (either side may be left blank, e.g. "5000..").
function textMatches(fieldValue, filterText) {
  const value = (fieldValue || '').toString().toLowerCase();
  let filter = (filterText || '').trim();
  if (!filter) return true;

  let negate = false;
  if (filter.startsWith('<>')) {
    negate = true;
    filter = filter.slice(2).trim();
  }

  const isWildcard = filter.includes('*');
  let matched;
  if (isWildcard) {
    const pattern = filter
      .toLowerCase()
      .split('*')
      .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
      .join('.*');
    matched = new RegExp('^' + pattern + '$').test(value);
  } else {
    matched = value.includes(filter.toLowerCase());
  }
  return negate ? !matched : matched;
}

function numericMatches(fieldValue, filterText) {
  const value = Number(fieldValue) || 0;
  const filter = (filterText || '').trim();
  if (!filter) return true;

  if (filter.includes('..')) {
    const [rawMin, rawMax] = filter.split('..');
    const min = rawMin.trim() === '' ? -Infinity : Number(rawMin);
    const max = rawMax.trim() === '' ? Infinity : Number(rawMax);
    if (Number.isNaN(min) || Number.isNaN(max)) return true;
    return value >= min && value <= max;
  }

  const match = filter.match(/^(<>|>=|<=|>|<|=)?\s*(-?\d+(\.\d+)?)$/);
  if (!match) return true;
  const [, op, numStr] = match;
  const num = Number(numStr);
  switch (op) {
    case '>': return value > num;
    case '>=': return value >= num;
    case '<': return value < num;
    case '<=': return value <= num;
    case '<>': return value !== num;
    default: return value === num;
  }
}

function applyFilters() {
  const usernameFilter = document.getElementById('filterUsername').value;
  const displayNameFilter = document.getElementById('filterDisplayName').value;
  const activeFilter = document.getElementById('filterActive').value;
  const payCycleFilter = document.getElementById('filterPayCycle').value;
  const salaryFilter = document.getElementById('filterMonthlySalary').value;
  const paymentMethodFilter = document.getElementById('filterPaymentMethod').value;
  const payTypeFilter = document.getElementById('filterPayType').value;
  const paidRestDayFilter = document.getElementById('filterPaidRestDay').value;

  const filtered = allEmployees.filter((e) => {
    if (!textMatches(e.username, usernameFilter)) return false;
    if (!textMatches(e.display_name, displayNameFilter)) return false;
    if (activeFilter === 'active' && !e.is_active) return false;
    if (activeFilter === 'inactive' && e.is_active) return false;
    if (payCycleFilter === 'none' && e.pay_cycle) return false;
    if (payCycleFilter && payCycleFilter !== 'none' && e.pay_cycle !== payCycleFilter) return false;
    if (payTypeFilter && (e.pay_type || 'Salary') !== payTypeFilter) return false;
    if (!numericMatches(e.pay_type === 'Hourly' ? e.daily_rate : e.monthly_salary, salaryFilter)) return false;
    if (paymentMethodFilter === 'none' && e.payment_method) return false;
    if (paymentMethodFilter && paymentMethodFilter !== 'none' && e.payment_method !== paymentMethodFilter) return false;
    if (paidRestDayFilter === 'none' && (e.paid_rest_day !== null && e.paid_rest_day !== undefined)) return false;
    if (paidRestDayFilter && paidRestDayFilter !== 'none' && String(e.paid_rest_day) !== paidRestDayFilter) return false;
    return true;
  });

  renderEmployeeRows(filtered);
}

// Salary shows Monthly Salary; Hourly shows Daily Rate instead - only one is ever relevant.
function togglePayTypeRows(prefix) {
  const isHourly = document.getElementById(`${prefix}PayType`).value === 'Hourly';
  document.getElementById(`${prefix}MonthlySalaryRow`).classList.toggle('hidden', isHourly);
  document.getElementById(`${prefix}DailyRateRow`).classList.toggle('hidden', !isHourly);
}

function openEditProfileModal(username) {
  const employee = currentEmployees.find((e) => e.username === username);
  if (!employee) return;

  document.getElementById('editProfileUsername').value = employee.username || '';
  document.getElementById('editProfilePayCycle').value = employee.pay_cycle || '';
  document.getElementById('editProfileMonthlySalary').value = Number(employee.monthly_salary) || 0;
  document.getElementById('editProfilePayType').value = employee.pay_type || 'Salary';
  document.getElementById('editProfileDailyRate').value = Number(employee.daily_rate) || 0;
  document.getElementById('editProfilePaidRestDay').value = employee.paid_rest_day === null || employee.paid_rest_day === undefined ? '' : String(employee.paid_rest_day);
  togglePayTypeRows('editProfile');
  document.getElementById('editProfilePaymentMethod').value = employee.payment_method || '';
  document.getElementById('editProfileActive').checked = employee.is_active !== false;
  document.getElementById('editProfileError').classList.add('hidden');
  document.getElementById('editProfileModal').classList.remove('hidden');
}

async function saveProfile() {
  const errorEl = document.getElementById('editProfileError');
  errorEl.classList.add('hidden');

  const username = document.getElementById('editProfileUsername').value.trim();
  const payCycle = document.getElementById('editProfilePayCycle').value || null;
  const monthlySalary = Number(document.getElementById('editProfileMonthlySalary').value) || 0;
  const isActive = document.getElementById('editProfileActive').checked;
  const paymentMethod = document.getElementById('editProfilePaymentMethod').value || null;
  const payType = document.getElementById('editProfilePayType').value || 'Salary';
  const dailyRate = Number(document.getElementById('editProfileDailyRate').value) || 0;
  const paidRestDayRaw = document.getElementById('editProfilePaidRestDay').value;
  const paidRestDay = paidRestDayRaw === '' ? null : Number(paidRestDayRaw);

  const saveBtn = document.getElementById('saveProfileBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_update_payroll_profile', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_username: username,
    p_pay_cycle: payCycle,
    p_monthly_salary: monthlySalary,
    p_is_active: isActive,
    p_payment_method: paymentMethod,
    p_pay_type: payType,
    p_daily_rate: dailyRate,
    p_paid_rest_day: paidRestDay
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Changes';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to update payroll profile.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('editProfileModal').classList.add('hidden');
  await loadEmployees();
}

function openNewEmployeeModal() {
  document.getElementById('newEmployeeUsername').value = '';
  document.getElementById('newEmployeePassword').value = '123456';
  document.getElementById('newEmployeeDisplayName').value = '';
  document.getElementById('newEmployeePosition').value = '';
  document.getElementById('newEmployeeHireDate').value = '';
  document.getElementById('newEmployeeBirthdate').value = '';
  document.getElementById('newEmployeePhoneNumber').value = '';
  document.getElementById('newEmployeeHomeAddress').value = '';
  document.getElementById('newEmployeePaymentMethod').value = '';
  document.getElementById('newEmployeePayCycle').value = '';
  document.getElementById('newEmployeeMonthlySalary').value = 0;
  document.getElementById('newEmployeePayType').value = 'Salary';
  document.getElementById('newEmployeeDailyRate').value = 0;
  document.getElementById('newEmployeePaidRestDay').value = '';
  togglePayTypeRows('newEmployee');
  document.getElementById('newEmployeeError').classList.add('hidden');
  document.getElementById('newEmployeeModal').classList.remove('hidden');
}

async function saveNewEmployee() {
  const errorEl = document.getElementById('newEmployeeError');
  errorEl.classList.add('hidden');

  const username = document.getElementById('newEmployeeUsername').value.trim();
  const password = document.getElementById('newEmployeePassword').value;
  const displayName = document.getElementById('newEmployeeDisplayName').value.trim();
  const position = document.getElementById('newEmployeePosition').value.trim();
  const hireDate = document.getElementById('newEmployeeHireDate').value || null;
  const birthdate = document.getElementById('newEmployeeBirthdate').value || null;
  const phoneNumber = document.getElementById('newEmployeePhoneNumber').value.trim();
  const homeAddress = document.getElementById('newEmployeeHomeAddress').value.trim();
  const paymentMethod = document.getElementById('newEmployeePaymentMethod').value || null;
  const payCycle = document.getElementById('newEmployeePayCycle').value || null;
  const monthlySalary = Number(document.getElementById('newEmployeeMonthlySalary').value) || 0;
  const payType = document.getElementById('newEmployeePayType').value || 'Salary';
  const dailyRate = Number(document.getElementById('newEmployeeDailyRate').value) || 0;
  const paidRestDayRaw = document.getElementById('newEmployeePaidRestDay').value;
  const paidRestDay = paidRestDayRaw === '' ? null : Number(paidRestDayRaw);

  if (!username) {
    errorEl.textContent = 'Username is required.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (!password || password.length < 6) {
    errorEl.textContent = 'Password must be at least 6 characters.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveNewEmployeeBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Creating...';

  const { data, error } = await supabaseClient.rpc('admin_create_payroll_employee', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_new_username: username,
    p_new_password: password,
    p_display_name: displayName || null,
    p_position: position || null,
    p_home_address: homeAddress || null,
    p_birthdate: birthdate,
    p_phone_number: phoneNumber || null,
    p_payment_method: paymentMethod,
    p_hire_date: hireDate,
    p_pay_cycle: payCycle,
    p_monthly_salary: monthlySalary,
    p_pay_type: payType,
    p_daily_rate: dailyRate,
    p_paid_rest_day: paidRestDay
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Create Employee';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to create employee.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('newEmployeeModal').classList.add('hidden');
  await loadEmployees();
}

async function loadFundBalances() {
  const { data, error } = await supabaseClient.rpc('admin_get_payroll_fund_balances', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  const balances = Array.isArray(data) ? data[0] : data;
  if (error || !balances) return;

  document.getElementById('cashOnHandDisplay').textContent = formatCurrency(balances.cash_balance);
  document.getElementById('digitalOnHandDisplay').textContent = formatCurrency(balances.digital_balance);
}

function renderFundingRows(entries) {
  const tbody = document.getElementById('fundingTableBody');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No funding entries yet.</td></tr>';
    return;
  }

  tbody.innerHTML = entries
    .map((f) => `
      <tr>
        <td>${f.posted_at_utc ? new Date(f.posted_at_utc).toLocaleString() : ''}</td>
        <td><span class="badge ${f.entry_type === 'Funding' ? 'badge-success' : 'badge-neutral'}">${f.entry_type === 'Funding' ? 'Funding' : 'Payout'}</span></td>
        <td>${f.method || ''}</td>
        <td>${f.entry_type === 'Payout' ? '-' : ''}${formatCurrency(f.amount)}</td>
        <td>${f.notes || ''}</td>
        <td>${f.posted_by || ''}</td>
      </tr>
    `)
    .join('');
}

async function loadFundingJournal() {
  const tbody = document.getElementById('fundingTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_funding_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: 1,
    p_page_size: 50
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderFundingRows(data);
}

async function logFunding() {
  const errorEl = document.getElementById('fundingError');
  errorEl.classList.add('hidden');

  const method = document.getElementById('fundingMethod').value;
  const amount = Number(document.getElementById('fundingAmount').value) || 0;
  const notes = document.getElementById('fundingNotes').value.trim();

  if (amount <= 0) {
    errorEl.textContent = 'Amount must be greater than zero.';
    errorEl.classList.remove('hidden');
    return;
  }

  const logBtn = document.getElementById('logFundingBtn');
  logBtn.disabled = true;
  logBtn.textContent = 'Logging...';

  const { data, error } = await supabaseClient.rpc('admin_add_payroll_funding_entry', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_method: method,
    p_amount: amount,
    p_notes: notes || null
  });

  logBtn.disabled = false;
  logBtn.textContent = 'Log Funding Entry';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to log funding entry.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('fundingAmount').value = '';
  document.getElementById('fundingNotes').value = '';
  await loadFundBalances();
  await loadFundingJournal();
}

function togglePayDayInput(payDayInputId, lastDayCheckboxId) {
  const checkbox = document.getElementById(lastDayCheckboxId);
  const input = document.getElementById(payDayInputId);
  input.disabled = checkbox.checked;
}

async function loadCutoffSettings() {
  const { data, error } = await supabaseClient.rpc('admin_get_payroll_cutoff_settings', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  const settings = Array.isArray(data) ? data[0] : data;
  if (error || !settings) return;

  document.getElementById('cutoffAStartDay').value = settings.cutoff_a_start_day;
  document.getElementById('cutoffAEndDay').value = settings.cutoff_a_end_day;
  document.getElementById('cutoffAPayDay').value = settings.cutoff_a_pay_day || '';
  document.getElementById('cutoffAPayLastDay').checked = !!settings.cutoff_a_pay_day_is_last_day_of_month;
  document.getElementById('cutoffBStartDay').value = settings.cutoff_b_start_day;
  document.getElementById('cutoffBEndDay').value = settings.cutoff_b_end_day;
  document.getElementById('cutoffBPayDay').value = settings.cutoff_b_pay_day || '';
  document.getElementById('cutoffBPayLastDay').checked = !!settings.cutoff_b_pay_day_is_last_day_of_month;
  document.getElementById('standardHoursPerDay').value = settings.standard_hours_per_day || 8;
  document.getElementById('standardWorkDaysPerMonth').value = settings.standard_work_days_per_month || 26;
  document.getElementById('overtimeMultiplier').value = settings.overtime_multiplier || 1.25;

  togglePayDayInput('cutoffAPayDay', 'cutoffAPayLastDay');
  togglePayDayInput('cutoffBPayDay', 'cutoffBPayLastDay');
}

async function saveCutoffSettings() {
  const errorEl = document.getElementById('cutoffSettingsError');
  errorEl.classList.add('hidden');

  const saveBtn = document.getElementById('saveCutoffSettingsBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_upsert_payroll_cutoff_settings', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_cutoff_a_start_day: Number(document.getElementById('cutoffAStartDay').value),
    p_cutoff_a_end_day: Number(document.getElementById('cutoffAEndDay').value),
    p_cutoff_a_pay_day: document.getElementById('cutoffAPayDay').value ? Number(document.getElementById('cutoffAPayDay').value) : null,
    p_cutoff_a_pay_day_is_last_day_of_month: document.getElementById('cutoffAPayLastDay').checked,
    p_cutoff_b_start_day: Number(document.getElementById('cutoffBStartDay').value),
    p_cutoff_b_end_day: Number(document.getElementById('cutoffBEndDay').value),
    p_cutoff_b_pay_day: document.getElementById('cutoffBPayDay').value ? Number(document.getElementById('cutoffBPayDay').value) : null,
    p_cutoff_b_pay_day_is_last_day_of_month: document.getElementById('cutoffBPayLastDay').checked,
    p_standard_hours_per_day: Number(document.getElementById('standardHoursPerDay').value) || 8,
    p_standard_work_days_per_month: Number(document.getElementById('standardWorkDaysPerMonth').value) || 26,
    p_overtime_multiplier: Number(document.getElementById('overtimeMultiplier').value) || 1.25
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Cutoff Settings';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to save cutoff settings.';
    errorEl.classList.remove('hidden');
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payroll Setup');

  if (!session.isSuperUser && !session.isPayrollOfficer) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  document.getElementById('payrollSetupContent').classList.remove('hidden');
  await loadEmployees();
  await loadCutoffSettings();
  await loadFundBalances();
  await loadFundingJournal();

  document.getElementById('employeeTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-edit-username]');
    if (btn) openEditProfileModal(btn.getAttribute('data-edit-username'));
  });
  document.getElementById('closeEditProfileBtn').addEventListener('click', () =>
    document.getElementById('editProfileModal').classList.add('hidden')
  );
  document.getElementById('saveProfileBtn').addEventListener('click', saveProfile);
  document.getElementById('editProfilePayType').addEventListener('change', () => togglePayTypeRows('editProfile'));

  document.getElementById('newEmployeePayType').addEventListener('change', () => togglePayTypeRows('newEmployee'));
  document.getElementById('newEmployeeBtn').addEventListener('click', openNewEmployeeModal);
  document.getElementById('closeNewEmployeeBtn').addEventListener('click', () =>
    document.getElementById('newEmployeeModal').classList.add('hidden')
  );
  document.getElementById('saveNewEmployeeBtn').addEventListener('click', saveNewEmployee);

  document.getElementById('logFundingBtn').addEventListener('click', logFunding);

  ['filterUsername', 'filterDisplayName', 'filterMonthlySalary'].forEach((id) => {
    document.getElementById(id).addEventListener('input', applyFilters);
  });
  ['filterActive', 'filterPayCycle', 'filterPaymentMethod', 'filterPayType', 'filterPaidRestDay'].forEach((id) => {
    document.getElementById(id).addEventListener('change', applyFilters);
  });
  document.getElementById('clearFiltersBtn').addEventListener('click', () => {
    document.getElementById('filterUsername').value = '';
    document.getElementById('filterDisplayName').value = '';
    document.getElementById('filterActive').value = '';
    document.getElementById('filterPayCycle').value = '';
    document.getElementById('filterMonthlySalary').value = '';
    document.getElementById('filterPaymentMethod').value = '';
    document.getElementById('filterPayType').value = '';
    document.getElementById('filterPaidRestDay').value = '';
    applyFilters();
  });

  document.getElementById('cutoffAPayLastDay').addEventListener('change', () => togglePayDayInput('cutoffAPayDay', 'cutoffAPayLastDay'));
  document.getElementById('cutoffBPayLastDay').addEventListener('change', () => togglePayDayInput('cutoffBPayDay', 'cutoffBPayLastDay'));
  document.getElementById('saveCutoffSettingsBtn').addEventListener('click', saveCutoffSettings);
})();
