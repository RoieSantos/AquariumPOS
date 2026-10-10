// User Setup page logic (super users only) - Business Central list page + User Card.
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js). Every admin RPC call still re-sends it and the database re-verifies on each call.
//
// The whole staff list is loaded once (it's small) so Search, the view tabs, the filter pane and
// column sorting all run client-side, the way a BC list reacts instantly.
let currentSession = null;
let allUsers = [];
let warehouseOptions = []; // [{ id, name }] loaded from admin_list_warehouses
let selectedUsername = null;
let activeView = 'active';
let sortKey = 'username';
let sortDir = 1;
let cardMode = 'new'; // 'new' | 'edit'
let filterPaneOpen = true;

const ROLE_LABELS = { StandMaker: 'Stand Maker', TankMaker: 'Tank Maker', Dispatcher: 'Dispatcher', Cashier: 'Cashier', ProductionManager: 'Production Manager', AllBranchFabrication: 'All-Branch Fabrication' };

// Portal access flags: [list field, RPC param, card checkbox id, short label, description].
const ACCESS_FLAGS = [
  ['is_super_user', 'p_is_super_user', 'cardSuperUser', 'Super User', 'Can access User Setup and every page'],
  ['is_sales_user', 'p_is_sales_user', 'cardSalesUser', 'Sales User', 'Counts toward sales targets'],
  ['is_serial_admin', 'p_is_serial_admin', 'cardSerialAdmin', 'Serial Admin', 'Can edit serial locations in Serial Tracker'],
  ['is_delivery_team', 'p_is_delivery_team', 'cardDeliveryTeam', 'Delivery Team', 'Locked to the Delivery calendar only'],
  ['is_online_order_staff', 'p_is_online_order_staff', 'cardOnlineOrderStaff', 'Online Order Staff', 'Locked to Online Orders - Printed orders only, can mark To Ship and photo-notify customers'],
  ['is_production_member', 'p_is_production_member', 'cardProductionMember', 'Production Member', 'Can be assigned custom orders to build in Online Orders'],
  ['is_payroll_officer', 'p_is_payroll_officer', 'cardPayrollOfficer', 'Payroll Officer', 'Can access Payroll / Payroll Setup / Payroll Ledger'],
  ['is_store_manager', 'p_is_store_manager', 'cardStoreManager', 'Store Manager', 'Locked to Delivery, Payslips, Serial Tracker, Inventory Summary, Stock On Hand, Transfer Orders, Calculators, Online Orders'],
  ['is_conversations_staff', 'p_is_conversations_staff', 'cardConversationsStaff', 'Conversations Access', 'Can access Conversations']
];

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function formatMoney(amount) {
  const value = Number(amount) || 0;
  return value > 0 ? '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : '';
}

function formatCycleLabel(cycle) {
  return cycle === 'SemiMonthly' ? 'Semi-Monthly' : cycle === 'Weekly' ? 'Weekly' : '';
}

function roleLabels(u) {
  return (u.staff_roles || []).map((r) => ROLE_LABELS[r] || r);
}

function accessLabels(u) {
  return ACCESS_FLAGS.filter(([field]) => u[field]).map(([, , , label]) => label);
}

function fitGridToViewport() {
  const el = document.getElementById('userGridWrap');
  if (!el || el.offsetParent === null) return;
  const available = window.innerHeight - el.getBoundingClientRect().top - 56; // leaves room for the count strip
  el.style.maxHeight = Math.max(240, available) + 'px';
}

// ---------------------------------------------------------------- warehouses

async function loadWarehouseOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  warehouseOptions = error ? [] : (data || []).filter((w) => w.name).map((w) => ({ id: w.id, name: w.name }));

  const fp = document.getElementById('fpWarehouse');
  fp.innerHTML = '<option value="">(all)</option><option value="__all">(All warehouses)</option>' +
    warehouseOptions.map((w) => `<option value="${esc(w.name)}">${esc(w.name)}</option>`).join('');
}

function populateWarehouseSelect(selectEl, selectedName) {
  selectEl.innerHTML = '<option value="">(All warehouses)</option>' +
    warehouseOptions.map((w) => `<option value="${esc(w.name)}">${esc(w.name)}</option>`).join('');
  // Keep a warehouse that's no longer in the list visible rather than silently blanking it on save.
  if (selectedName && !warehouseOptions.some((w) => w.name === selectedName)) {
    selectEl.insertAdjacentHTML('beforeend', `<option value="${esc(selectedName)}">${esc(selectedName)}</option>`);
  }
  selectEl.value = selectedName || '';
}

// ---------------------------------------------------------------- list

async function loadUsers() {
  const errorEl = document.getElementById('userListError');
  errorEl.classList.add('hidden');
  document.getElementById('userTableBody').innerHTML = '<tr><td colspan="10" class="cell-msg">Loading...</td></tr>';

  // admin_list_staff_users caps a page at 200 - keep paging until everything is in.
  const rows = [];
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await supabaseClient.rpc('admin_list_staff_users', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_page: page,
      p_page_size: 200
    });
    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      document.getElementById('userTableBody').innerHTML = '';
      return;
    }
    rows.push(...(data || []));
    if (!data || data.length < 200 || rows.length >= (data[0]?.total_count || 0)) break;
  }

  allUsers = rows;
  if (selectedUsername && !allUsers.some((u) => u.username === selectedUsername)) selectedUsername = null;
  renderList();
}

function getFilteredUsers() {
  const q = document.getElementById('userSearchInput').value.trim().toLowerCase();
  const wh = document.getElementById('fpWarehouse').value;
  const role = document.getElementById('fpRole').value;
  const access = document.getElementById('fpAccess').value;
  const cycle = document.getElementById('fpPayCycle').value;

  return allUsers.filter((u) => {
    if (activeView === 'active' && !u.is_active) return false;
    if (activeView === 'inactive' && u.is_active) return false;
    if (wh === '__all' ? !!u.warehouse_name : wh && u.warehouse_name !== wh) return false;
    if (role === '__none' ? (u.staff_roles || []).length > 0 : role && !(u.staff_roles || []).includes(role)) return false;
    if (access && !u[access]) return false;
    if (cycle === '__none' ? !!u.pay_cycle : cycle && u.pay_cycle !== cycle) return false;
    if (q) {
      const hay = [u.username, u.employee_no, u.display_name, u.warehouse_name, u.job_position, u.phone_number,
        ...roleLabels(u), ...accessLabels(u)].join(' ').toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
}

function sortUsers(users) {
  return users.slice().sort((a, b) => {
    let x = a[sortKey];
    let y = b[sortKey];
    if (typeof x === 'boolean' || typeof y === 'boolean') { x = x ? 1 : 0; y = y ? 1 : 0; }
    if (x == null || x === '') return 1;
    if (y == null || y === '') return -1;
    return String(x).localeCompare(String(y), undefined, { numeric: true, sensitivity: 'base' }) * sortDir;
  });
}

function renderList() {
  const tbody = document.getElementById('userTableBody');
  const users = sortUsers(getFilteredUsers());

  document.querySelectorAll('.bc-grid thead th.sortable').forEach((th) => {
    const on = th.dataset.sort === sortKey;
    th.classList.toggle('sort-asc', on && sortDir === 1);
    th.classList.toggle('sort-desc', on && sortDir === -1);
    th.querySelector('.sort-arrow').textContent = on ? (sortDir === 1 ? '▲' : '▼') : '▲';
  });

  document.getElementById('userCount').textContent = `${users.length} of ${allUsers.length} users`;

  if (!users.length) {
    tbody.innerHTML = '<tr><td colspan="10" class="cell-msg">There is nothing to show in this view.</td></tr>';
  } else {
    tbody.innerHTML = users.map((u) => {
      const roles = roleLabels(u).join(', ');
      const access = accessLabels(u).join(', ');
      return `
        <tr data-username="${esc(u.username)}" class="${u.username === selectedUsername ? 'selected' : ''}">
          <td><button class="bc-link" type="button" data-open="${esc(u.username)}">${esc(u.username)}</button></td>
          <td>${esc(u.employee_no)}</td>
          <td class="cell-text" title="${esc(u.display_name)}">${esc(u.display_name)}</td>
          <td>${u.warehouse_name ? esc(u.warehouse_name) : '<span class="muted">All</span>'}</td>
          <td class="cell-text" title="${esc(u.job_position)}">${esc(u.job_position)}</td>
          <td class="cell-text" title="${esc(roles)}">${esc(roles)}</td>
          <td class="cell-text" title="${esc(access)}">${esc(access)}</td>
          <td>${esc(formatCycleLabel(u.pay_cycle))}</td>
          <td>${u.is_active ? 'Enabled' : '<span class="neg">Disabled</span>'}</td>
          <td>${u.last_login_at_utc ? new Date(u.last_login_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
        </tr>`;
    }).join('');
  }

  renderFactbox();
  fitGridToViewport();
}

function selectUser(username) {
  selectedUsername = username;
  document.querySelectorAll('#userTableBody tr[data-username]').forEach((tr) => {
    tr.classList.toggle('selected', tr.dataset.username === username);
  });
  renderFactbox();
}

function factList(pairs) {
  return `<dl class="bc-facts">${pairs.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v || '<span class="muted">-</span>'}</dd>`).join('')}</dl>`;
}

function renderFactbox() {
  const u = allUsers.find((x) => x.username === selectedUsername);
  document.getElementById('editUserBtn').disabled = !u;

  if (!u) {
    document.getElementById('factUser').innerHTML = '<p class="bc-fact-empty">Select a user to see details.</p>';
    document.getElementById('factAccess').innerHTML = '<p class="bc-fact-empty">-</p>';
    document.getElementById('factPayroll').innerHTML = '<p class="bc-fact-empty">-</p>';
    return;
  }

  document.getElementById('factUser').innerHTML = factList([
    ['User Name', esc(u.username)],
    ['Full Name', esc(u.display_name)],
    ['Employee No.', esc(u.employee_no)],
    ['Position', esc(u.job_position)],
    ['Roles', esc(roleLabels(u).join(', '))],
    ['Phone No.', esc(u.phone_number)],
    ['Hire Date', u.hire_date ? esc(new Date(u.hire_date + 'T00:00:00').toLocaleDateString()) : ''],
    ['Created', u.created_at_utc ? esc(new Date(u.created_at_utc).toLocaleDateString()) : ''],
    ['Change PW', u.must_change_password ? 'Required at next login' : '']
  ]);

  const access = ACCESS_FLAGS.filter(([field]) => u[field]);
  document.getElementById('factAccess').innerHTML = access.length
    ? `<dl class="bc-facts">${access.map(([, , , label]) => `<dt>${esc(label)}</dt><dd><span class="bc-tick">&#10003;</span></dd>`).join('')}${
      u.monthly_sales_target > 0 ? `<dt>Sales Target</dt><dd>${formatMoney(u.monthly_sales_target)}</dd>` : ''}</dl>`
    : '<p class="bc-fact-empty">Standard portal access.</p>';

  const hourly = u.pay_type === 'Hourly';
  document.getElementById('factPayroll').innerHTML = u.pay_cycle
    ? factList([
      ['Pay Cycle', esc(formatCycleLabel(u.pay_cycle))],
      ['Pay Type', esc(u.pay_type || 'Salary')],
      [hourly ? 'Daily Rate' : 'Monthly Salary', formatMoney(hourly ? u.daily_rate : u.monthly_salary)],
      ['Payment', esc(u.payment_method === 'Digital' ? 'Digital (GCash)' : u.payment_method)],
      ['Paid Rest Day', u.has_paid_rest_day ? 'Yes' : 'No']
    ])
    : '<p class="bc-fact-empty">Not enrolled in Payroll.</p>';
}

// ---------------------------------------------------------------- User Card

function buildAccessList() {
  document.getElementById('cardAccessList').innerHTML = ACCESS_FLAGS.map(([, , id, label, desc]) => `
    <div class="bc-field">
      <label for="${id}" title="${esc(desc)}">${esc(label)}<span class="bc-field-hint">${esc(desc)}</span></label>
      <input type="checkbox" class="bc-switch" id="${id}" />
    </div>`).join('');

  const fp = document.getElementById('fpAccess');
  fp.innerHTML = '<option value="">(all)</option>' +
    ACCESS_FLAGS.map(([field, , , label]) => `<option value="${field}">${esc(label)}</option>`).join('');
}

function togglePayTypeRows() {
  const isHourly = document.getElementById('cardPayType').value === 'Hourly';
  document.getElementById('cardMonthlySalaryRow').classList.toggle('hidden', isHourly);
  document.getElementById('cardDailyRateRow').classList.toggle('hidden', !isHourly);
}

function getCheckedRoles() {
  return Array.from(document.querySelectorAll('#cardRoles input[type="checkbox"]:checked')).map((cb) => cb.value);
}

// FastTab collapsed summaries - BC shows the key values on a closed FastTab's header.
function updateTabSummaries() {
  const v = (id) => document.getElementById(id).value.trim();
  const checked = (id) => document.getElementById(id).checked;

  document.getElementById('tabGeneralSummary').textContent =
    [v('cardUsername'), v('cardDisplayName'), document.getElementById('cardWarehouse').value || 'All warehouses'].filter(Boolean).join(' · ');
  document.getElementById('tabAccessSummary').textContent =
    ACCESS_FLAGS.filter(([, , id]) => checked(id)).map(([, , , label]) => label).join(', ') || 'Standard';
  document.getElementById('tabEmployeeSummary').textContent =
    [v('cardEmployeeNo'), v('cardPosition'), getCheckedRoles().map((r) => ROLE_LABELS[r]).join(', ')].filter(Boolean).join(' · ');
  const cycle = document.getElementById('cardPayCycle').value;
  document.getElementById('tabPayrollSummary').textContent = cycle
    ? `${formatCycleLabel(cycle)} · ${document.getElementById('cardPayType').value}`
    : 'Not enrolled';
}

function openUserCard(username) {
  const u = username ? allUsers.find((x) => x.username === username) : null;
  if (username && !u) return;
  cardMode = u ? 'edit' : 'new';

  const set = (id, value) => { document.getElementById(id).value = value ?? ''; };
  const check = (id, value) => { document.getElementById(id).checked = !!value; };

  document.getElementById('userCardTitle').textContent = u ? `${u.username}${u.display_name ? ' · ' + u.display_name : ''}` : 'New User';
  document.getElementById('userCardCaption').textContent = u ? 'USER CARD' : 'USER CARD - NEW';

  set('cardUsername', u?.username);
  document.getElementById('cardUsername').disabled = !!u;
  set('cardPassword', '');
  document.getElementById('cardPasswordLabel').textContent = u ? 'New Password' : 'Password';
  document.getElementById('cardPassword').placeholder = u ? 'Leave blank to keep current' : 'At least 6 characters';
  set('cardDisplayName', u?.display_name);
  populateWarehouseSelect(document.getElementById('cardWarehouse'), u?.warehouse_name || '');
  check('cardMustChangePassword', u?.must_change_password);
  check('cardActive', u ? u.is_active : true);
  document.getElementById('cardActiveRow').classList.toggle('hidden', !u);

  ACCESS_FLAGS.forEach(([field, , id]) => check(id, u?.[field]));
  set('cardMonthlyTarget', Number(u?.monthly_sales_target) || 0);

  set('cardEmployeeNo', u?.employee_no);
  set('cardPosition', u?.job_position);
  const roles = new Set(u?.staff_roles || []);
  document.querySelectorAll('#cardRoles input[type="checkbox"]').forEach((cb) => { cb.checked = roles.has(cb.value); });
  set('cardHireDate', u?.hire_date);
  set('cardBirthdate', u?.birthdate);
  set('cardPhoneNumber', u?.phone_number);
  set('cardHomeAddress', u?.home_address);

  set('cardPayCycle', u?.pay_cycle || '');
  set('cardPayType', u?.pay_type || 'Salary');
  set('cardMonthlySalary', Number(u?.monthly_salary) || 0);
  set('cardDailyRate', Number(u?.daily_rate) || 0);
  set('cardPaymentMethod', u?.payment_method || '');
  check('cardPaidRestDay', u?.has_paid_rest_day);
  togglePayTypeRows();

  // Every FastTab starts expanded; collapsing one still shows its key values on the header.
  ['tabGeneral', 'tabAccess', 'tabEmployee', 'tabPayroll'].forEach((id) => { document.getElementById(id).open = true; });

  updateTabSummaries();
  document.getElementById('userCardError').classList.add('hidden');
  document.getElementById('userCardModal').classList.remove('hidden');
  (u ? document.getElementById('cardDisplayName') : document.getElementById('cardUsername')).focus();
}

function closeUserCard() {
  document.getElementById('userCardModal').classList.add('hidden');
}

function showCardError(message) {
  const errorEl = document.getElementById('userCardError');
  errorEl.textContent = message;
  errorEl.classList.remove('hidden');
}

// Roles are saved by their own RPC (see sql/supabase_staff_users_staff_roles.sql), right after the create/update.
async function saveUserRoles(username, roles) {
  const { data, error } = await supabaseClient.rpc('admin_set_staff_user_roles', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_target_username: username,
    p_roles: roles
  });
  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) return error?.message || result?.message || 'Failed to save roles.';
  return null;
}

async function saveUserCard() {
  document.getElementById('userCardError').classList.add('hidden');

  const val = (id) => document.getElementById(id).value.trim();
  const isNew = cardMode === 'new';
  const username = val('cardUsername');
  const password = document.getElementById('cardPassword').value;

  if (isNew && !username) return showCardError('User Name is required.');
  if (isNew && password.length < 6) return showCardError('Password must be at least 6 characters.');
  if (!isNew && password && password.length < 6) return showCardError('New password must be at least 6 characters.');

  const params = {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_display_name: val('cardDisplayName') || null,
    p_warehouse_name: document.getElementById('cardWarehouse').value || null,
    p_monthly_sales_target: Number(document.getElementById('cardMonthlyTarget').value) || 0,
    p_must_change_password: document.getElementById('cardMustChangePassword').checked,
    p_position: val('cardPosition') || null,
    p_home_address: val('cardHomeAddress') || null,
    p_birthdate: document.getElementById('cardBirthdate').value || null,
    p_phone_number: val('cardPhoneNumber') || null,
    p_payment_method: document.getElementById('cardPaymentMethod').value || null,
    p_hire_date: document.getElementById('cardHireDate').value || null,
    p_pay_cycle: document.getElementById('cardPayCycle').value || null,
    p_monthly_salary: Number(document.getElementById('cardMonthlySalary').value) || 0,
    p_pay_type: document.getElementById('cardPayType').value || 'Salary',
    p_daily_rate: Number(document.getElementById('cardDailyRate').value) || 0,
    p_has_paid_rest_day: document.getElementById('cardPaidRestDay').checked,
    p_employee_no: val('cardEmployeeNo') || null
  };
  ACCESS_FLAGS.forEach(([, param, id]) => { params[param] = document.getElementById(id).checked; });

  if (isNew) {
    params.p_new_username = username;
    params.p_new_password = password;
  } else {
    params.p_target_username = username;
    params.p_is_active = document.getElementById('cardActive').checked;
    params.p_new_password = password || null;
  }

  const saveBtn = document.getElementById('saveUserCardBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc(isNew ? 'admin_create_staff_user' : 'admin_update_staff_user', params);
  const result = Array.isArray(data) ? data[0] : data;

  if (error || !result || !result.success) {
    saveBtn.disabled = false;
    saveBtn.textContent = 'OK';
    return showCardError(error?.message || result?.message || (isNew ? 'Failed to create login.' : 'Failed to update login.'));
  }

  const roles = getCheckedRoles();
  const rolesError = isNew && !roles.length ? null : await saveUserRoles(username, roles);

  saveBtn.disabled = false;
  saveBtn.textContent = 'OK';
  selectedUsername = username;

  if (rolesError) {
    // The login itself is saved - switch to edit mode so OK just retries the roles with the rest.
    cardMode = 'edit';
    document.getElementById('cardUsername').disabled = true;
    await loadUsers();
    return showCardError(`${isNew ? 'Login created' : 'Login saved'}, but roles failed: ${rolesError}`);
  }

  closeUserCard();
  await loadUsers();
}

// ---------------------------------------------------------------- init

function setView(view) {
  activeView = view;
  document.querySelectorAll('.bc-tab').forEach((t) => {
    const on = t.dataset.view === view;
    t.classList.toggle('active', on);
    t.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  renderList();
}

function clearFilters() {
  document.getElementById('userSearchInput').value = '';
  ['fpWarehouse', 'fpRole', 'fpAccess', 'fpPayCycle'].forEach((id) => { document.getElementById(id).value = ''; });
  renderList();
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
  buildAccessList();
  await Promise.all([loadUsers(), loadWarehouseOptionsOnce()]);

  // List
  document.getElementById('userSearchInput').addEventListener('input', renderList);
  ['fpWarehouse', 'fpRole', 'fpAccess', 'fpPayCycle'].forEach((id) => document.getElementById(id).addEventListener('change', renderList));
  document.getElementById('clearFiltersBtn').addEventListener('click', clearFilters);
  document.getElementById('clearFiltersLink').addEventListener('click', clearFilters);
  document.getElementById('filterPaneBtn').addEventListener('click', () => {
    filterPaneOpen = !filterPaneOpen;
    document.getElementById('filterPane').classList.toggle('hidden', !filterPaneOpen);
    document.getElementById('bcBody').classList.toggle('no-filterpane', !filterPaneOpen);
    document.getElementById('filterPaneBtn').setAttribute('aria-pressed', filterPaneOpen ? 'true' : 'false');
  });
  document.querySelectorAll('.bc-tab').forEach((t) => t.addEventListener('click', () => setView(t.dataset.view)));
  document.querySelectorAll('.bc-grid thead th.sortable').forEach((th) => th.addEventListener('click', () => {
    if (sortKey === th.dataset.sort) sortDir = -sortDir; else { sortKey = th.dataset.sort; sortDir = 1; }
    renderList();
  }));

  const tbody = document.getElementById('userTableBody');
  tbody.addEventListener('click', (e) => {
    const link = e.target.closest('[data-open]');
    if (link) { selectUser(link.dataset.open); openUserCard(link.dataset.open); return; }
    const tr = e.target.closest('tr[data-username]');
    if (tr) selectUser(tr.dataset.username);
  });
  tbody.addEventListener('dblclick', (e) => {
    const tr = e.target.closest('tr[data-username]');
    if (tr) openUserCard(tr.dataset.username);
  });

  document.getElementById('newUserBtn').addEventListener('click', () => openUserCard(null));
  document.getElementById('editUserBtn').addEventListener('click', () => selectedUsername && openUserCard(selectedUsername));
  document.getElementById('refreshBtn').addEventListener('click', loadUsers);
  window.addEventListener('resize', fitGridToViewport);

  // Card
  document.getElementById('cardPayType').addEventListener('change', togglePayTypeRows);
  document.getElementById('userCardModal').addEventListener('input', updateTabSummaries);
  document.getElementById('userCardModal').addEventListener('change', updateTabSummaries);
  document.getElementById('saveUserCardBtn').addEventListener('click', saveUserCard);
  document.getElementById('cancelUserCardBtn').addEventListener('click', closeUserCard);
  document.getElementById('closeUserCardBtn').addEventListener('click', closeUserCard);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !document.getElementById('userCardModal').classList.contains('hidden')) closeUserCard();
  });
})();
