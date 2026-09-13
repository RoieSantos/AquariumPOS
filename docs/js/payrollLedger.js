// Payroll Ledger report page (super users only) - a filterable view across every
// PayrollLedgerEntries row (see supabase_payroll_ledger.sql), the detailed trail posted
// automatically whenever a payroll run is finalized. Unlike the per-run ledger section on
// payroll-run.html (which is always scoped to one run), this page can span every run ever
// finalized, so it defaults to the current month on load rather than pulling everything at once -
// the Employee/Period filters narrow it further from there.
let currentSession = null;
let currentPage = 1;
let currentPageSize = 50;
let searchDebounceHandle = null;
let loadGeneration = 0;

function formatCurrency(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatDate(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString();
}

function formatDateTime(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleString();
}

function toDateInputValue(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

async function loadEmployeeFilterOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_payroll_employees', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error || !data) return;

  const select = document.getElementById('filterEmployee');
  data.forEach((emp) => {
    const opt = document.createElement('option');
    opt.value = emp.username;
    opt.textContent = emp.display_name || emp.username;
    select.appendChild(opt);
  });
}

function renderLedgerRows(entries) {
  const tbody = document.getElementById('ledgerTableBody');
  const summaryEl = document.getElementById('ledgerSummary');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No ledger entries match these filters.</td></tr>';
    summaryEl.textContent = '';
    return;
  }

  const entryTypeBadge = { BasePay: 'badge-neutral', Addition: 'badge-success', Deduction: 'badge-danger', NetPay: 'badge-primary', CashAdvance: 'badge-warning', Funding: 'badge-success', Payroll: 'badge-danger' };
  const entryTypeLabel = { CashAdvance: 'Cash Advance' };
  const methodBadge = { Cash: 'badge-neutral', Digital: 'badge-primary' };

  tbody.innerHTML = entries
    .map((e) => `
      <tr>
        <td>${e.period_start === e.period_end ? formatDate(e.period_start) : `${formatDate(e.period_start)} - ${formatDate(e.period_end)}`}</td>
        <td>${e.employee_no || ''}</td>
        <td>${e.display_name || e.username || '<span class="muted">-</span>'}</td>
        <td><span class="badge ${entryTypeBadge[e.entry_type] || 'badge-neutral'}">${entryTypeLabel[e.entry_type] || e.entry_type}</span></td>
        <td>${e.label}${e.notes ? ` <span class="muted">(${e.notes})</span>` : ''}</td>
        <td style="text-align:right;">${formatCurrency(e.amount)}</td>
        <td>${e.method ? `<span class="badge ${methodBadge[e.method] || 'badge-neutral'}">${e.method === 'Digital' ? 'Digital (GCash)' : e.method}</span>` : ''}</td>
        <td>${e.posted_by || ''}</td>
        <td>${formatDateTime(e.posted_at_utc)}</td>
      </tr>
    `)
    .join('');

  // Net Pay rows are the one entry type that never double-counts across an employee's other rows
  // on the same line (Base Pay + Additions - Deductions = Net Pay already), so summing just those
  // gives the true total actually paid out across everything the filters matched. total_count/
  // total_net_pay come from the RPC's window functions over the whole filtered set, not just the
  // current page, so the summary stays accurate once pagination is slicing the rows shown below.
  const totalCount = Number(entries[0]?.total_count || 0);
  const totalNetPay = Number(entries[0]?.total_net_pay || 0);
  summaryEl.textContent = `${totalCount} ledger entr${totalCount === 1 ? 'y' : 'ies'} - Total Net Pay: ${formatCurrency(totalNetPay)}`;
}

async function loadLedger() {
  const tbody = document.getElementById('ledgerTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const username = document.getElementById('filterEmployee').value || null;
  const entryType = document.getElementById('filterEntryType').value || null;
  const method = document.getElementById('filterMethod').value || null;
  const periodStart = document.getElementById('filterPeriodStart').value || null;
  const periodEnd = document.getElementById('filterPeriodEnd').value || null;
  const search = document.getElementById('filterSearch').value.trim() || null;

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_ledger_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_username: username,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_search: search,
    p_entry_type: entryType,
    p_method: method,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return; // a newer filter/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    document.getElementById('ledgerSummary').textContent = '';
    return;
  }

  renderLedgerRows(data);

  renderPaginationBar(
    document.getElementById('ledgerPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadLedger(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadLedger(); }
    }
  );
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payroll Ledger');

  if (!session.isSuperUser && !session.isPayrollOfficer) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  document.getElementById('ledgerContent').classList.remove('hidden');

  // Deep-link from the Cash on Hand/Digital on Hand balance links (Payroll Setup, Payroll Runs
  // page), e.g. payroll-ledger.html?method=Cash - shows every Funding/Payroll/Cash Advance entry
  // for that method with no period restriction, since the point is to see everything that adds up
  // to the current running balance, not just this month.
  const methodParam = new URLSearchParams(window.location.search).get('method');
  if (methodParam === 'Cash' || methodParam === 'Digital') {
    document.getElementById('filterMethod').value = methodParam;
  } else {
    // Default the visible range to the current month so a first-time load doesn't try to pull
    // every ledger entry ever posted - Apply Filters/clearing the dates widens it from there.
    const now = new Date();
    document.getElementById('filterPeriodStart').value = toDateInputValue(new Date(now.getFullYear(), now.getMonth(), 1));
    document.getElementById('filterPeriodEnd').value = toDateInputValue(new Date(now.getFullYear(), now.getMonth() + 1, 0));
  }

  await loadEmployeeFilterOnce();
  await loadLedger();

  document.getElementById('applyFiltersBtn').addEventListener('click', () => { currentPage = 1; loadLedger(); });
  document.getElementById('filterEntryType').addEventListener('change', () => { currentPage = 1; loadLedger(); });
  document.getElementById('filterMethod').addEventListener('change', () => { currentPage = 1; loadLedger(); });
  document.getElementById('filterSearch').addEventListener('input', (e) => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => { currentPage = 1; loadLedger(); }, 300);
  });
})();
