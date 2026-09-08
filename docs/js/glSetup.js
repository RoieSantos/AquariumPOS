// G/L Setup - chart of accounts, the posting-account mapping, and expense category -> account
// mapping. See supabase_general_ledger.sql.
//
// Super users only, same as every other Setup page (the RPCs re-check with is_admin_authorized).
let currentSession = null;
let glAccounts = [];

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function showError(message) {
  const el = document.getElementById('glSetupError');
  if (!message) {
    el.classList.add('hidden');
    return;
  }
  el.textContent = message;
  el.classList.remove('hidden');
}

function accountOptionsHtml(selectedNo, includeBlank) {
  return (includeBlank ? '<option value="">(use default)</option>' : '') + glAccounts
    .map((a) => `<option value="${escapeHtml(a.account_no)}" ${a.account_no === selectedNo ? 'selected' : ''}>${escapeHtml(a.account_no)} - ${escapeHtml(a.name)}</option>`)
    .join('');
}

async function loadAccounts() {
  const { data, error } = await supabaseClient.rpc('admin_list_gl_accounts', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_include_inactive: true
  });

  if (error) {
    showError(error.message);
    return;
  }

  glAccounts = data || [];

  document.getElementById('accountsBody').innerHTML = glAccounts.length === 0
    ? '<tr><td colspan="6" class="muted">No accounts yet.</td></tr>'
    : glAccounts.map((a) => `
        <tr>
          <td>${escapeHtml(a.account_no)}</td>
          <td>${escapeHtml(a.name)}</td>
          <td>${escapeHtml(a.account_type)}</td>
          <td>${a.direct_posting ? 'Yes' : '<span class="muted">No - documents only</span>'}</td>
          <td>${a.is_active ? 'Yes' : '<span class="muted">No</span>'}</td>
          <td class="doc-num">${Number(a.balance || 0).toFixed(2)}</td>
        </tr>
      `).join('');
}

async function loadSetup() {
  const { data, error } = await supabaseClient.rpc('admin_get_gl_setup', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    showError(error.message);
    return;
  }

  const setup = (Array.isArray(data) ? data[0] : data) || {};
  const fields = [
    ['setupInventory', setup.inventory_account_no],
    ['setupPayable', setup.payable_account_no],
    ['setupCash', setup.cash_account_no],
    ['setupDigital', setup.digital_account_no],
    ['setupDefaultExpense', setup.default_expense_account_no]
  ];

  fields.forEach(([id, value]) => {
    document.getElementById(id).innerHTML = accountOptionsHtml(value, false);
    if (value) document.getElementById(id).value = value;
  });
}

async function saveSetup() {
  const btn = document.getElementById('saveSetupBtn');
  const saved = document.getElementById('setupSaved');
  saved.classList.add('hidden');
  btn.disabled = true;

  const { error } = await supabaseClient.rpc('admin_set_gl_setup', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_inventory_account_no: document.getElementById('setupInventory').value || null,
    p_payable_account_no: document.getElementById('setupPayable').value || null,
    p_cash_account_no: document.getElementById('setupCash').value || null,
    p_digital_account_no: document.getElementById('setupDigital').value || null,
    p_default_expense_account_no: document.getElementById('setupDefaultExpense').value || null
  });

  btn.disabled = false;

  if (error) {
    showError(error.message);
    return;
  }

  showError('');
  saved.classList.remove('hidden');
}

async function loadCategoryMap() {
  const body = document.getElementById('categoryMapBody');
  const { data, error } = await supabaseClient.rpc('admin_list_gl_expense_category_map', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    body.innerHTML = `<tr><td colspan="3" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="3" class="muted">No expense categories have synced yet.</td></tr>';
    return;
  }

  // Unmapped categories sort first (the RPC orders by is_mapped), so what still needs attention is
  // at the top rather than buried among the categories already dealt with.
  body.innerHTML = rows.map((r) => `
    <tr>
      <td>${escapeHtml(r.expense_category)}</td>
      <td>
        <select class="category-account-select" data-category="${escapeHtml(r.expense_category)}">
          ${accountOptionsHtml(r.account_no, true)}
        </select>
      </td>
      <td>${r.is_mapped
        ? '<span class="badge badge-success">Mapped</span>'
        : '<span class="badge badge-warning" title="Posts to the Default Expense account">Default</span>'}</td>
    </tr>
  `).join('');
}

async function saveCategoryAccount(select) {
  select.disabled = true;
  const { error } = await supabaseClient.rpc('admin_set_gl_expense_category_account', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_expense_category: select.dataset.category,
    p_account_no: select.value || null
  });
  select.disabled = false;

  if (error) {
    showError(error.message);
    return;
  }

  showError('');
  await loadCategoryMap();
}

async function addAccount() {
  const accountNo = document.getElementById('newAccountNo').value.trim();
  const name = document.getElementById('newAccountName').value.trim();
  const accountType = document.getElementById('newAccountType').value;

  if (!accountNo || !name) {
    window.alert('Enter both an Account No. and an Account Name.');
    return;
  }

  const existing = glAccounts.find((a) => a.account_no === accountNo);
  if (existing && !window.confirm(
    `Account ${accountNo} already exists ("${existing.name}"). Update it to "${name}" (${accountType})?`
  )) return;

  const { error } = await supabaseClient.rpc('admin_upsert_gl_account', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_account_no: accountNo,
    p_name: name,
    p_account_type: accountType,
    p_direct_posting: true,
    p_is_active: true
  });

  if (error) {
    showError(error.message);
    return;
  }

  showError('');
  document.getElementById('newAccountNo').value = '';
  document.getElementById('newAccountName').value = '';

  // The account lists on this page are all built from glAccounts, so everything is reloaded - a
  // new account has to appear in the posting-account and category dropdowns too, not just the
  // chart below.
  await loadAccounts();
  await loadSetup();
  await loadCategoryMap();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('G/L Setup');

  document.getElementById('saveSetupBtn').addEventListener('click', saveSetup);
  document.getElementById('addAccountBtn').addEventListener('click', addAccount);

  document.getElementById('categoryMapBody').addEventListener('change', (e) => {
    const select = e.target.closest('select.category-account-select');
    if (select) saveCategoryAccount(select);
  });

  // Accounts first - the posting-account and category dropdowns are built from that list.
  await loadAccounts();
  await Promise.all([loadSetup(), loadCategoryMap()]);
})();
