// Payroll Setup page logic (super users only). Assigns each StaffUsers row a PayCycle +
// MonthlySalary via admin_update_payroll_profile - these two columns live on StaffUsers itself
// ("Employees are the one on the usersetup") but are only ever written from here, never from
// User Setup's own edit modal.
let currentSession = null;
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

function renderEmployeeRows(employees) {
  currentEmployees = employees || [];
  const tbody = document.getElementById('employeeTableBody');

  if (!employees || employees.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No staff logins found.</td></tr>';
    return;
  }

  tbody.innerHTML = employees
    .map((e) => `
      <tr>
        <td>${e.username || ''}</td>
        <td>${e.display_name || ''}</td>
        <td><span class="badge ${e.is_active ? 'badge-success' : 'badge-danger'}">${e.is_active ? 'Active' : 'Inactive'}</span></td>
        <td>${formatCycle(e.pay_cycle)}</td>
        <td>${formatCurrency(e.monthly_salary)}</td>
        <td><button class="btn btn-secondary btn-sm" data-edit-username="${e.username}" type="button">Edit</button></td>
      </tr>
    `)
    .join('');
}

async function loadEmployees() {
  const tbody = document.getElementById('employeeTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_employees', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderEmployeeRows(data);
}

function openEditProfileModal(username) {
  const employee = currentEmployees.find((e) => e.username === username);
  if (!employee) return;

  document.getElementById('editProfileUsername').value = employee.username || '';
  document.getElementById('editProfilePayCycle').value = employee.pay_cycle || '';
  document.getElementById('editProfileMonthlySalary').value = Number(employee.monthly_salary) || 0;
  document.getElementById('editProfileError').classList.add('hidden');
  document.getElementById('editProfileModal').classList.remove('hidden');
}

async function saveProfile() {
  const errorEl = document.getElementById('editProfileError');
  errorEl.classList.add('hidden');

  const username = document.getElementById('editProfileUsername').value.trim();
  const payCycle = document.getElementById('editProfilePayCycle').value || null;
  const monthlySalary = Number(document.getElementById('editProfileMonthlySalary').value) || 0;

  const saveBtn = document.getElementById('saveProfileBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_update_payroll_profile', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_username: username,
    p_pay_cycle: payCycle,
    p_monthly_salary: monthlySalary
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
    p_cutoff_b_pay_day_is_last_day_of_month: document.getElementById('cutoffBPayLastDay').checked
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

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  document.getElementById('payrollSetupContent').classList.remove('hidden');
  await loadEmployees();
  await loadCutoffSettings();

  document.getElementById('employeeTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-edit-username]');
    if (btn) openEditProfileModal(btn.getAttribute('data-edit-username'));
  });
  document.getElementById('closeEditProfileBtn').addEventListener('click', () =>
    document.getElementById('editProfileModal').classList.add('hidden')
  );
  document.getElementById('saveProfileBtn').addEventListener('click', saveProfile);

  document.getElementById('cutoffAPayLastDay').addEventListener('change', () => togglePayDayInput('cutoffAPayDay', 'cutoffAPayLastDay'));
  document.getElementById('cutoffBPayLastDay').addEventListener('change', () => togglePayDayInput('cutoffBPayDay', 'cutoffBPayLastDay'));
  document.getElementById('saveCutoffSettingsBtn').addEventListener('click', saveCutoffSettings);
})();
