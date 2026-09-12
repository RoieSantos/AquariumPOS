// Expense Journal page (super users only) - lets a super user add a manual portal expense
// (Category/Description/Amount) and browse/delete what's been logged so far. See
// sql/supabase_expense_journal_tables.sql. Mirrors js/expenseEntries.js for the list/search/
// pagination/period-deep-link plumbing, plus an add form and a delete action on top.
let currentSession = null;
let entrySearchDebounceHandle = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;

// Deep-link filter from a Dashboard finance card (?period=month|today), same convention as
// expense-entries.html.
let currentPeriod = null;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function formatDateTime(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleString();
}

async function loadWarehouseOptions() {
  const select = document.getElementById('entryWarehouseInput');
  const { data, error } = await supabaseClient.rpc('admin_list_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    console.error('admin_list_warehouses failed:', error);
    select.innerHTML = '<option value="">(Failed to load warehouses)</option>';
    return;
  }

  const names = (data || []).map((w) => w.name).filter(Boolean);
  select.innerHTML = '<option value="">Select warehouse...</option>' + names
    .map((name) => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`)
    .join('');

  // Pre-fill from the logged-in account's own assigned warehouse when it has one - still editable,
  // and left unselected (forcing an explicit choice) when it doesn't, rather than silently saving
  // the entry with no warehouse - see the Dashboard "Expense Today" mismatch this was added to fix.
  if (currentSession.warehouseName && names.includes(currentSession.warehouseName)) {
    select.value = currentSession.warehouseName;
  }
}

async function loadCategoryOptions() {
  const { data, error } = await supabaseClient.rpc('admin_list_expense_journal_categories', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    console.error('admin_list_expense_journal_categories failed:', error);
    return;
  }

  document.getElementById('entryCategoryOptions').innerHTML = (data || [])
    .map((row) => `<option value="${escapeHtml(row.category)}"></option>`)
    .join('');
}

function renderEntryRows(entries) {
  const tbody = document.getElementById('entryTableBody');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No expense journal entries found.</td></tr>';
    return;
  }

  tbody.innerHTML = entries
    .map((e) => `
      <tr>
        <td>${escapeHtml(e.receipt_no || '')}</td>
        <td>${e.entry_date || ''}</td>
        <td>${escapeHtml(e.expense_category)}</td>
        <td>${escapeHtml(e.description || '')}</td>
        <td>${escapeHtml(e.warehouse || '')}</td>
        <td>${formatMoney(e.amount)}</td>
        <td>${escapeHtml(e.created_by || '')}</td>
        <td>${formatDateTime(e.created_at_utc)}</td>
        <td><button class="btn btn-secondary btn-sm" type="button" data-delete-id="${e.entry_id}">Delete</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('[data-delete-id]').forEach((btn) => {
    btn.addEventListener('click', () => deleteEntry(btn.getAttribute('data-delete-id')));
  });
}

async function loadEntries() {
  const tbody = document.getElementById('entryTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_expense_journal_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_period: currentPeriod,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return; // a newer search/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  renderEntryRows(data);

  renderPaginationBar(
    document.getElementById('entryPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadEntries(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadEntries(); }
    }
  );
}

async function deleteEntry(entryId) {
  if (!window.confirm('Delete this expense journal entry? This cannot be undone.')) return;

  const { data, error } = await supabaseClient.rpc('admin_delete_expense_journal_entry', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_id: entryId
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result?.success) {
    window.alert('Delete failed: ' + (error?.message || result?.message || 'Unknown error'));
    return;
  }

  await loadEntries();
}

async function submitAddEntry(e) {
  e.preventDefault();

  const errorBox = document.getElementById('addEntryError');
  errorBox.classList.add('hidden');

  const category = document.getElementById('entryCategoryInput').value.trim();
  const description = document.getElementById('entryDescriptionInput').value.trim();
  const amount = Number(document.getElementById('entryAmountInput').value);
  const date = document.getElementById('entryDateInput').value || null;
  const warehouse = document.getElementById('entryWarehouseInput').value;

  if (!category) {
    errorBox.textContent = 'Category is required.';
    errorBox.classList.remove('hidden');
    return;
  }
  if (!amount || amount <= 0) {
    errorBox.textContent = 'Amount must be greater than zero.';
    errorBox.classList.remove('hidden');
    return;
  }
  if (!warehouse) {
    errorBox.textContent = 'Warehouse is required.';
    errorBox.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('addEntryBtn');
  btn.disabled = true;
  btn.textContent = 'Adding...';

  const { error } = await supabaseClient.rpc('admin_add_expense_journal_entry', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_expense_category: category,
    p_description: description || null,
    p_amount: amount,
    p_entry_date: date,
    p_warehouse: warehouse
  });

  btn.disabled = false;
  btn.textContent = 'Add Expense';

  if (error) {
    errorBox.textContent = error.message;
    errorBox.classList.remove('hidden');
    return;
  }

  document.getElementById('addEntryForm').reset();
  // form.reset() reverts the Warehouse select to its first <option> (no HTML "selected" attribute
  // was set since the default came from JS) - re-apply the same account-based default afterward.
  const warehouseSelect = document.getElementById('entryWarehouseInput');
  if (currentSession.warehouseName && [...warehouseSelect.options].some((o) => o.value === currentSession.warehouseName)) {
    warehouseSelect.value = currentSession.warehouseName;
  }
  currentPage = 1;
  await Promise.all([loadCategoryOptions(), loadEntries()]);
}

function renderCategoryRows(categories) {
  const tbody = document.getElementById('categoryTableBody');

  if (!categories || categories.length === 0) {
    tbody.innerHTML = '<tr><td colspan="3" class="muted">No managed categories yet - categories typed directly on a real expense still work as suggestions.</td></tr>';
    return;
  }

  tbody.innerHTML = categories
    .map((c) => `
      <tr>
        <td>${escapeHtml(c.code)}</td>
        <td>${escapeHtml(c.description)}</td>
        <td><button class="btn btn-secondary btn-sm" type="button" data-delete-code="${escapeHtml(c.code)}">Delete</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('[data-delete-code]').forEach((btn) => {
    btn.addEventListener('click', () => deleteCategory(btn.getAttribute('data-delete-code')));
  });
}

async function loadCategorySetup() {
  const tbody = document.getElementById('categoryTableBody');
  tbody.innerHTML = '<tr><td colspan="3" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_expense_journal_category_setup', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="3" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  renderCategoryRows(data);
}

async function deleteCategory(code) {
  if (!window.confirm(`Delete category "${code}"? Past entries already using it are unaffected.`)) return;

  const { data, error } = await supabaseClient.rpc('admin_delete_expense_journal_category', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_code: code
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result?.success) {
    window.alert('Delete failed: ' + (error?.message || result?.message || 'Unknown error'));
    return;
  }

  await Promise.all([loadCategorySetup(), loadCategoryOptions()]);
}

async function submitAddCategory(e) {
  e.preventDefault();

  const errorBox = document.getElementById('addCategoryError');
  errorBox.classList.add('hidden');

  const code = document.getElementById('categoryCodeInput').value.trim();
  const description = document.getElementById('categoryDescriptionInput').value.trim();

  if (!code || !description) {
    errorBox.textContent = 'Both code and description are required.';
    errorBox.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('addCategoryBtn');
  btn.disabled = true;
  btn.textContent = 'Adding...';

  const { error } = await supabaseClient.rpc('admin_add_expense_journal_category', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_code: code,
    p_description: description
  });

  btn.disabled = false;
  btn.textContent = 'Add Category';

  if (error) {
    errorBox.textContent = error.message;
    errorBox.classList.remove('hidden');
    return;
  }

  document.getElementById('addCategoryForm').reset();
  await Promise.all([loadCategorySetup(), loadCategoryOptions()]);
}

function wireManageCategoriesToggle() {
  const panel = document.getElementById('manageCategoriesPanel');
  const btn = document.getElementById('toggleManageCategoriesBtn');
  let loaded = false;

  btn.addEventListener('click', async () => {
    const showing = !panel.classList.contains('hidden');
    if (showing) {
      panel.classList.add('hidden');
      btn.textContent = 'Show';
      return;
    }

    panel.classList.remove('hidden');
    btn.textContent = 'Hide';
    if (!loaded) {
      loaded = true;
      await loadCategorySetup();
    }
  });

  document.getElementById('addCategoryForm').addEventListener('submit', submitAddCategory);
}

function wireEntrySearch() {
  document.getElementById('entrySearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(entrySearchDebounceHandle);
    entrySearchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadEntries();
    }, 300);
  });
}

function showActiveFilterNote() {
  if (!currentPeriod) return;

  const periodLabel = currentPeriod === 'month'
    ? 'for ' + new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' })
    : 'for today (' + new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) + ')';
  const activeFilterNote = document.getElementById('activeFilterNote');
  activeFilterNote.innerHTML = `Showing journal entries ${periodLabel}. <a href="expense-journal.html">Clear filters</a>`;
  activeFilterNote.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Expense Journal');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Expense Journal.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  // Supports deep-linking from the Dashboard's "Expense This Month"/"Expense Today" cards,
  // e.g. expense-journal.html?period=month
  const periodParam = new URLSearchParams(window.location.search).get('period') || '';
  currentPeriod = periodParam === 'month' || periodParam === 'today' ? periodParam : null;

  document.getElementById('setupContent').classList.remove('hidden');
  showActiveFilterNote();
  wireEntrySearch();
  wireManageCategoriesToggle();
  document.getElementById('addEntryForm').addEventListener('submit', submitAddEntry);
  await Promise.all([loadWarehouseOptions(), loadCategoryOptions(), loadEntries()]);
})();
