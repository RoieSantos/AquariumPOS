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

function renderUserRows(users) {
  currentUsers = users || [];
  const tbody = document.getElementById('userTableBody');

  if (!users || users.length === 0) {
    tbody.innerHTML = '<tr><td colspan="11" class="muted">No staff logins found.</td></tr>';
    return;
  }

  tbody.innerHTML = users
    .map((u) => `
      <tr>
        <td>${u.username || ''}</td>
        <td>${u.display_name || ''}</td>
        <td>${u.warehouse_name || '<span class="muted">All</span>'}</td>
        <td><span class="badge ${u.is_super_user ? 'badge-success' : 'badge-neutral'}">${u.is_super_user ? 'Yes' : 'No'}</span></td>
        <td><span class="badge ${u.is_sales_user ? 'badge-success' : 'badge-neutral'}">${u.is_sales_user ? 'Yes' : 'No'}</span></td>
        <td>${formatMonthlyTarget(u.monthly_sales_target)}</td>
        <td><span class="badge ${u.must_change_password ? 'badge-warning' : 'badge-neutral'}">${u.must_change_password ? 'Required' : 'No'}</span></td>
        <td><span class="badge ${u.is_active ? 'badge-success' : 'badge-danger'}">${u.is_active ? 'Active' : 'Inactive'}</span></td>
        <td>${u.created_at_utc ? new Date(u.created_at_utc).toLocaleDateString() : ''}</td>
        <td>${u.last_login_at_utc ? new Date(u.last_login_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
        <td><button class="btn btn-secondary btn-sm" data-edit-username="${u.username}" type="button">Edit</button></td>
      </tr>
    `)
    .join('');
}

async function loadUsers() {
  const tbody = document.getElementById('userTableBody');
  tbody.innerHTML = '<tr><td colspan="11" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_staff_users', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="11" class="error-text">${error.message}</td></tr>`;
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
  document.getElementById('newUserMonthlyTarget').value = 0;
  document.getElementById('newUserMustChangePassword').checked = false;
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
  document.getElementById('editUserMonthlyTarget').value = Number(user.monthly_sales_target) || 0;
  document.getElementById('editUserMustChangePassword').checked = !!user.must_change_password;
  document.getElementById('editUserActive').checked = !!user.is_active;
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
  const monthlyTarget = Number(document.getElementById('editUserMonthlyTarget').value) || 0;
  const mustChangePassword = document.getElementById('editUserMustChangePassword').checked;
  const isActive = document.getElementById('editUserActive').checked;

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
    p_must_change_password: mustChangePassword
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
  const monthlyTarget = Number(document.getElementById('newUserMonthlyTarget').value) || 0;
  const mustChangePassword = document.getElementById('newUserMustChangePassword').checked;

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
    p_must_change_password: mustChangePassword
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
