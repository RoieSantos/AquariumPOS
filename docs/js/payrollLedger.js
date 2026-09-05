// Payroll Ledger report page (super users only) - a filterable view across every
// PayrollLedgerEntries row (see supabase_payroll_ledger.sql), the detailed trail posted
// automatically whenever a payroll run is finalized. Unlike the per-run ledger section on
// payroll-run.html (which is always scoped to one run), this page can span every run ever
// finalized, so it defaults to the current month on load rather than pulling everything at once -
// the Employee/Period filters narrow it further from there.
let currentSession = null;

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
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No ledger entries match these filters.</td></tr>';
    summaryEl.textContent = '';
    return;
  }

  const entryTypeBadge = { BasePay: 'badge-neutral', Addition: 'badge-success', Deduction: 'badge-danger', NetPay: 'badge-primary' };

  tbody.innerHTML = entries
    .map((e) => `
      <tr>
        <td>${formatDate(e.period_start)} - ${formatDate(e.period_end)}</td>
        <td>${e.display_name || e.username}</td>
        <td><span class="badge ${entryTypeBadge[e.entry_type] || 'badge-neutral'}">${e.entry_type}</span></td>
        <td>${e.label}</td>
        <td style="text-align:right;">${formatCurrency(e.amount)}</td>
        <td>${e.posted_by || ''}</td>
        <td>${formatDateTime(e.posted_at_utc)}</td>
      </tr>
    `)
    .join('');

  // Net Pay rows are the one entry type that never double-counts across an employee's other rows
  // on the same line (Base Pay + Additions - Deductions = Net Pay already), so summing just those
  // gives the true total actually paid out across everything the filters matched.
  const totalNetPay = entries.filter((e) => e.entry_type === 'NetPay').reduce((sum, e) => sum + Number(e.amount || 0), 0);
  summaryEl.textContent = `${entries.length} ledger entr${entries.length === 1 ? 'y' : 'ies'} - Total Net Pay: ${formatCurrency(totalNetPay)}`;
}

async function loadLedger() {
  const tbody = document.getElementById('ledgerTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const username = document.getElementById('filterEmployee').value || null;
  const periodStart = document.getElementById('filterPeriodStart').value || null;
  const periodEnd = document.getElementById('filterPeriodEnd').value || null;

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_ledger_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_username: username,
    p_period_start: periodStart,
    p_period_end: periodEnd
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    document.getElementById('ledgerSummary').textContent = '';
    return;
  }

  renderLedgerRows(data);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payroll Ledger');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  document.getElementById('ledgerContent').classList.remove('hidden');

  // Default the visible range to the current month so a first-time load doesn't try to pull
  // every ledger entry ever posted - Apply Filters/clearing the dates widens it from there.
  const now = new Date();
  document.getElementById('filterPeriodStart').value = toDateInputValue(new Date(now.getFullYear(), now.getMonth(), 1));
  document.getElementById('filterPeriodEnd').value = toDateInputValue(new Date(now.getFullYear(), now.getMonth() + 1, 0));

  await loadEmployeeFilterOnce();
  await loadLedger();

  document.getElementById('applyFiltersBtn').addEventListener('click', loadLedger);
})();
