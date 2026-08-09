// Expenses page logic (super users only, read-only view).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders (reuses the password captured at login, session.password, see auth.js).
let currentSession = null;
let entrySearchDebounceHandle = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;

// Deep-link filter from a Dashboard finance card (?period=month|today) - set once in init()
// from the URL, applied on every load for the rest of this page view. See the "Expense This
// Month"/"Expense Today" card hrefs in dashboard.html.
let currentPeriod = null;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function renderEntryRows(entries) {
  const tbody = document.getElementById('entryTableBody');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No expense entries found.</td></tr>';
    return;
  }

  tbody.innerHTML = entries
    .map((e) => `
      <tr>
        <td>${e.receipt_no || ''}</td>
        <td>${e.warehouse || ''}</td>
        <td>${e.expense_category || ''}</td>
        <td>${e.description || ''}</td>
        <td>${e.user_id || ''}</td>
        <td>${e.entry_date || ''}</td>
        <td>${e.entry_time || ''}</td>
        <td>${formatMoney(e.net_amount)}</td>
        <td><a href="expense-entry-lines.html?receipt=${encodeURIComponent(e.receipt_no)}">View</a></td>
      </tr>
    `)
    .join('');
}

async function loadEntries() {
  const tbody = document.getElementById('entryTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_expense_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_period: currentPeriod,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return; // a newer search/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
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
  activeFilterNote.innerHTML = `Showing expenses ${periodLabel}. <a href="expense-entries.html">Clear filters</a>`;
  activeFilterNote.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Expenses');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Expenses.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  // Supports deep-linking from the Dashboard's "Expense This Month"/"Expense Today" cards,
  // e.g. expense-entries.html?period=month
  const periodParam = new URLSearchParams(window.location.search).get('period') || '';
  currentPeriod = periodParam === 'month' || periodParam === 'today' ? periodParam : null;

  document.getElementById('setupContent').classList.remove('hidden');
  showActiveFilterNote();
  wireEntrySearch();
  await loadEntries();
})();
