// User Setup page logic (super users only).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js). Every admin RPC call still re-sends it and the database re-verifies on each call.
let currentSession = null;
let currentUsers = [];
let warehouseOptions = []; // [{ id, name }] loaded from admin_list_warehouses, shared by both modals
let currentPage = 1;
let currentPageSize = 50;

function populateWarehouseSelect(selectEl, selectedName) {
  const blankOption = '<option value="">(All warehouses)</option>';
  const options = warehouseOptions
    .map((w) => `<option value="${w.name}">${w.name}</option>`)
    .join('');
  selectEl.innerHTML = blankOption + options;
  selectEl.value = selectedName || '';
}

async function loadWarehouseOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    warehouseOptions = [];
    return;
  }

  warehouseOptions = (data || [])
    .filter((w) => w.name)
    .map((w) => ({ id: w.id, name: w.name }));
}

function formatMonthlyTarget(amount) {
  const value = Number(amount) || 0;
  return value > 0 ? '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : '<span class="muted">-</span>';
}

function formatCycleLabel(cycle) {
  return cycle === 'SemiMonthly' ? 'Semi-Monthly' : cycle === 'Weekly' ? 'Weekly' : '';
}

// Salary shows Monthly Salary; Hourly shows Daily Rate instead - only one is ever relevant.
function togglePayTypeRows(prefix) {
  const isHourly = document.getElementById(`${prefix}PayType`).value === 'Hourly';
  document.getElementById(`${prefix}MonthlySalaryRow`).classList.toggle('hidden', isHourly);
  document.getElementById(`${prefix}DailyRateRow`).classList.toggle('hidden', !isHourly);
}

function renderUserRows(users) {
  currentUsers = users || [];
  const tbody = document.getElementById('userTableBody');

  if (!users || users.length === 0) {
    tbody.innerHTML = '<tr><td colspan="19" class="muted">No staff logins found.</td></tr>';
    return;
  }

  tbody.innerHTML = users
    .map((u) => `
      <tr>
        <td>${u.username || ''}</td>
        <td>${u.employee_no || ''}</td>
        <td>${u.display_name || ''}</td>
        <td>${u.warehouse_name || '<span class="muted">All</span>'}</td>
        <td><span class="badge ${u.is_super_user ? 'badge-success' : 'badge-neutral'}">${u.is_super_user ? 'Yes' : 'No'}</span></td>
        <td><span class="badge ${u.is_sales_user ? 'badge-success' : 'badge-neutral'}">${u.is_sales_user ? 'Yes' : 'No'}</span></td>
        <td><span class="badge ${u.is_serial_admin ? 'badge-success' : 'badge-neutral'}">${u.is_serial_admin ? 'Yes' : 'No'}</span></td>
        <td><span class="badge ${u.is_delivery_team ? 'badge-success' : 'badge-neutral'}">${u.is_delivery_team ? 'Yes' : 'No'}</span></td>
        <td><span class="badge ${u.is_online_order_staff ? 'badge-success' : 'badge-neutral'}">${u.is_online_order_staff ? 'Yes' : 'No'}</span></td>
        <td><span class="badge ${u.is_payroll_officer ? 'badge-success' : 'badge-neutral'}">${u.is_payroll_officer ? 'Yes' : 'No'}</span></td>
        <td>${formatMonthlyTarget(u.monthly_sales_target)}</td>
        <td><span class="badge ${u.must_change_password ? 'badge-warning' : 'badge-neutral'}">${u.must_change_password ? 'Required' : 'No'}</span></td>
        <td><span class="badge ${u.is_active ? 'badge-success' : 'badge-danger'}">${u.is_active ? 'Active' : 'Inactive'}</span></td>
        <td>${u.created_at_utc ? new Date(u.created_at_utc).toLocaleDateString() : ''}</td>
        <td>${u.last_login_at_utc ? new Date(u.last_login_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
        <td>${u.job_position || ''}</td>
        <td>${formatCycleLabel(u.pay_cycle) || '<span class="muted">-</span>'}</td>
        <td>${formatMonthlyTarget(u.monthly_salary)}</td>
        <td><button class="btn btn-secondary btn-sm" data-edit-username="${u.username}" type="button">Edit</button></td>
      </tr>
    `)
    .join('');
}

async function loadUsers() {
  const tbody = document.getElementById('userTableBody');
  tbody.innerHTML = '<tr><td colspan="19" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_staff_users', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="19" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderUserRows(data);

  renderPaginationBar(
    document.getElementById('userPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadUsers(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadUsers(); }
    }
  );
}

function openNewUserModal() {
  document.getElementById('newUsername').value = '';
  document.getElementById('newUserPassword').value = '';
  document.getElementById('newDisplayName').value = '';
  populateWarehouseSelect(document.getElementById('newUserWarehouse'), '');
  document.getElementById('newUserSuperUser').checked = false;
  document.getElementById('newUserSalesUser').checked = false;
  document.getElementById('newUserSerialAdmin').checked = false;
  document.getElementById('newUserDeliveryTeam').checked = false;
  document.getElementById('newUserOnlineOrderStaff').checked = false;
  document.getElementById('newUserProductionMember').checked = false;
  document.getElementById('newUserPayrollOfficer').checked = false;
  document.getElementById('newUserMonthlyTarget').value = 0;
  document.getElementById('newUserMustChangePassword').checked = false;
  document.getElementById('newUserEmployeeNo').value = '';
  document.getElementById('newUserPosition').value = '';
  document.getElementById('newUserHireDate').value = '';
  document.getElementById('newUserBirthdate').value = '';
  document.getElementById('newUserPhoneNumber').value = '';
  document.getElementById('newUserHomeAddress').value = '';
  document.getElementById('newUserPaymentMethod').value = '';
  document.getElementById('newUserPayCycle').value = '';
  document.getElementById('newUserMonthlySalary').value = 0;
  document.getElementById('newUserPayType').value = 'Salary';
  document.getElementById('newUserDailyRate').value = 0;
  document.getElementById('newUserPaidRestDay').value = '';
  togglePayTypeRows('newUser');
  document.getElementById('newUserError').classList.add('hidden');
  document.getElementById('newUserModal').classList.remove('hidden');
}

function openEditUserModal(username) {
  const user = currentUsers.find((u) => u.username === username);
  if (!user) return;

  document.getElementById('editUsername').value = user.username || '';
  document.getElementById('editDisplayName').value = user.display_name || '';
  populateWarehouseSelect(document.getElementById('editUserWarehouse'), user.warehouse_name || '');
  document.getElementById('editUserPassword').value = '';
  document.getElementById('editUserSuperUser').checked = !!user.is_super_user;
  document.getElementById('editUserSalesUser').checked = !!user.is_sales_user;
  document.getElementById('editUserSerialAdmin').checked = !!user.is_serial_admin;
  document.getElementById('editUserDeliveryTeam').checked = !!user.is_delivery_team;
  document.getElementById('editUserOnlineOrderStaff').checked = !!user.is_online_order_staff;
  document.getElementById('editUserProductionMember').checked = !!user.is_production_member;
  document.getElementById('editUserPayrollOfficer').checked = !!user.is_payroll_officer;
  document.getElementById('editUserMonthlyTarget').value = Number(user.monthly_sales_target) || 0;
  document.getElementById('editUserMustChangePassword').checked = !!user.must_change_password;
  document.getElementById('editUserActive').checked = !!user.is_active;
  document.getElementById('editUserEmployeeNo').value = user.employee_no || '';
  document.getElementById('editUserPosition').value = user.job_position || '';
  document.getElementById('editUserHireDate').value = user.hire_date || '';
  document.getElementById('editUserBirthdate').value = user.birthdate || '';
  document.getElementById('editUserPhoneNumber').value = user.phone_number || '';
  document.getElementById('editUserHomeAddress').value = user.home_address || '';
  document.getElementById('editUserPaymentMethod').value = user.payment_method || '';
  document.getElementById('editUserPayCycle').value = user.pay_cycle || '';
  document.getElementById('editUserMonthlySalary').value = Number(user.monthly_salary) || 0;
  document.getElementById('editUserPayType').value = user.pay_type || 'Salary';
  document.getElementById('editUserDailyRate').value = Number(user.daily_rate) || 0;
  document.getElementById('editUserPaidRestDay').value = user.paid_rest_day === null || user.paid_rest_day === undefined ? '' : String(user.paid_rest_day);
  togglePayTypeRows('editUser');
  document.getElementById('editUserError').classList.add('hidden');
  document.getElementById('editUserModal').classList.remove('hidden');
}

async function saveEditUser() {
  const errorEl = document.getElementById('editUserError');
  errorEl.classList.add('hidden');

  const username = document.getElementById('editUsername').value.trim();
  const displayName = document.getElementById('editDisplayName').value.trim();
  const warehouseName = document.getElementById('editUserWarehouse').value.trim();
  const newPassword = document.getElementById('editUserPassword').value;
  const isSuperUser = document.getElementById('editUserSuperUser').checked;
  const isSalesUser = document.getElementById('editUserSalesUser').checked;
  const isSerialAdmin = document.getElementById('editUserSerialAdmin').checked;
  const isDeliveryTeam = document.getElementById('editUserDeliveryTeam').checked;
  const isOnlineOrderStaff = document.getElementById('editUserOnlineOrderStaff').checked;
  const isProductionMember = document.getElementById('editUserProductionMember').checked;
  const isPayrollOfficer = document.getElementById('editUserPayrollOfficer').checked;
  const monthlyTarget = Number(document.getElementById('editUserMonthlyTarget').value) || 0;
  const mustChangePassword = document.getElementById('editUserMustChangePassword').checked;
  const isActive = document.getElementById('editUserActive').checked;
  const employeeNo = document.getElementById('editUserEmployeeNo').value.trim();
  const position = document.getElementById('editUserPosition').value.trim();
  const hireDate = document.getElementById('editUserHireDate').value || null;
  const birthdate = document.getElementById('editUserBirthdate').value || null;
  const phoneNumber = document.getElementById('editUserPhoneNumber').value.trim();
  const homeAddress = document.getElementById('editUserHomeAddress').value.trim();
  const paymentMethod = document.getElementById('editUserPaymentMethod').value || null;
  const payCycle = document.getElementById('editUserPayCycle').value || null;
  const monthlySalary = Number(document.getElementById('editUserMonthlySalary').value) || 0;
  const payType = document.getElementById('editUserPayType').value || 'Salary';
  const dailyRate = Number(document.getElementById('editUserDailyRate').value) || 0;
  const paidRestDayRaw = document.getElementById('editUserPaidRestDay').value;
  const paidRestDay = paidRestDayRaw === '' ? null : Number(paidRestDayRaw);

  if (newPassword && newPassword.length < 6) {
    errorEl.textContent = 'New password must be at least 6 characters.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveEditUserBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_update_staff_user', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_target_username: username,
    p_display_name: displayName || null,
    p_warehouse_name: warehouseName || null,
    p_is_super_user: isSuperUser,
    p_is_active: isActive,
    p_new_password: newPassword || null,
    p_is_sales_user: isSalesUser,
    p_monthly_sales_target: monthlyTarget,
    p_must_change_password: mustChangePassword,
    p_is_serial_admin: isSerialAdmin,
    p_is_delivery_team: isDeliveryTeam,
    p_is_online_order_staff: isOnlineOrderStaff,
    p_is_production_member: isProductionMember,
    p_position: position || null,
    p_home_address: homeAddress || null,
    p_birthdate: birthdate,
    p_phone_number: phoneNumber || null,
    p_payment_method: paymentMethod,
    p_hire_date: hireDate,
    p_pay_cycle: payCycle,
    p_monthly_salary: monthlySalary,
    p_is_payroll_officer: isPayrollOfficer,
    p_pay_type: payType,
    p_daily_rate: dailyRate,
    p_paid_rest_day: paidRestDay,
    p_employee_no: employeeNo || null
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Changes';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to update login.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('editUserModal').classList.add('hidden');
  await loadUsers();
}

async function saveNewUser() {
  const errorEl = document.getElementById('newUserError');
  errorEl.classList.add('hidden');

  const username = document.getElementById('newUsername').value.trim();
  const password = document.getElementById('newUserPassword').value;
  const displayName = document.getElementById('newDisplayName').value.trim();
  const warehouseName = document.getElementById('newUserWarehouse').value;
  const isSuperUser = document.getElementById('newUserSuperUser').checked;
  const isSalesUser = document.getElementById('newUserSalesUser').checked;
  const isSerialAdmin = document.getElementById('newUserSerialAdmin').checked;
  const isDeliveryTeam = document.getElementById('newUserDeliveryTeam').checked;
  const isOnlineOrderStaff = document.getElementById('newUserOnlineOrderStaff').checked;
  const isProductionMember = document.getElementById('newUserProductionMember').checked;
  const isPayrollOfficer = document.getElementById('newUserPayrollOfficer').checked;
  const monthlyTarget = Number(document.getElementById('newUserMonthlyTarget').value) || 0;
  const mustChangePassword = document.getElementById('newUserMustChangePassword').checked;
  const employeeNo = document.getElementById('newUserEmployeeNo').value.trim();
  const position = document.getElementById('newUserPosition').value.trim();
  const hireDate = document.getElementById('newUserHireDate').value || null;
  const birthdate = document.getElementById('newUserBirthdate').value || null;
  const phoneNumber = document.getElementById('newUserPhoneNumber').value.trim();
  const homeAddress = document.getElementById('newUserHomeAddress').value.trim();
  const paymentMethod = document.getElementById('newUserPaymentMethod').value || null;
  const payCycle = document.getElementById('newUserPayCycle').value || null;
  const monthlySalary = Number(document.getElementById('newUserMonthlySalary').value) || 0;
  const payType = document.getElementById('newUserPayType').value || 'Salary';
  const dailyRate = Number(document.getElementById('newUserDailyRate').value) || 0;
  const paidRestDayRaw = document.getElementById('newUserPaidRestDay').value;
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

  const saveBtn = document.getElementById('saveUserBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_create_staff_user', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_new_username: username,
    p_new_password: password,
    p_display_name: displayName || null,
    p_warehouse_name: warehouseName || null,
    p_is_super_user: isSuperUser,
    p_is_sales_user: isSalesUser,
    p_monthly_sales_target: monthlyTarget,
    p_must_change_password: mustChangePassword,
    p_is_serial_admin: isSerialAdmin,
    p_is_delivery_team: isDeliveryTeam,
    p_is_online_order_staff: isOnlineOrderStaff,
    p_is_production_member: isProductionMember,
    p_position: position || null,
    p_home_address: homeAddress || null,
    p_birthdate: birthdate,
    p_phone_number: phoneNumber || null,
    p_payment_method: paymentMethod,
    p_hire_date: hireDate,
    p_pay_cycle: payCycle,
    p_monthly_salary: monthlySalary,
    p_is_payroll_officer: isPayrollOfficer,
    p_pay_type: payType,
    p_daily_rate: dailyRate,
    p_paid_rest_day: paidRestDay,
    p_employee_no: employeeNo || null
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Create Login';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to create login.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('newUserModal').classList.add('hidden');
  await loadUsers();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('User Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view User Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('userSetupContent').classList.remove('hidden');
  await loadUsers();
  await loadWarehouseOptionsOnce();

  document.getElementById('newUserPayType').addEventListener('change', () => togglePayTypeRows('newUser'));
  document.getElementById('editUserPayType').addEventListener('change', () => togglePayTypeRows('editUser'));

  document.getElementById('newUserBtn').addEventListener('click', openNewUserModal);
  document.getElementById('closeNewUserBtn').addEventListener('click', () =>
    document.getElementById('newUserModal').classList.add('hidden')
  );
  document.getElementById('saveUserBtn').addEventListener('click', saveNewUser);

  document.getElementById('userTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-edit-username]');
    if (btn) openEditUserModal(btn.getAttribute('data-edit-username'));
  });
  document.getElementById('closeEditUserBtn').addEventListener('click', () =>
    document.getElementById('editUserModal').classList.add('hidden')
  );
  document.getElementById('saveEditUserBtn').addEventListener('click', saveEditUser);
})();
