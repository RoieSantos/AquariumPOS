// Self-service "My Payslips" list - every logged-in staff member's own Finalized payroll lines,
// via my_list_payslips (supabase_payroll_self_service_payslips.sql), which scopes rows to the
// caller's own username server-side (not just a client-side filter). No Payroll Officer / Super
// User gate here on purpose - any active login can see their own pay.

let currentSession = null;

function formatCurrency(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatDate(dateStr) {
  if (!dateStr) return '-';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString();
}

function formatCycleLabel(cycle) {
  return cycle === 'SemiMonthly' ? 'Semi-Monthly' : cycle === 'Weekly' ? 'Weekly' : cycle || '';
}

function renderRows(rows) {
  const tbody = document.getElementById('payslipTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No finalized payslips yet.</td></tr>';
    return;
  }

  tbody.innerHTML = rows.map((r) => `
    <tr>
      <td>${formatCycleLabel(r.pay_cycle)}</td>
      <td>${formatDate(r.period_start)} - ${formatDate(r.period_end)}</td>
      <td>${formatDate(r.pay_date)}</td>
      <td style="text-align:right;">${formatCurrency(r.base_pay)}</td>
      <td style="text-align:right;">${formatCurrency(r.additions_total)}</td>
      <td style="text-align:right;">${formatCurrency(r.deductions_total)}</td>
      <td style="text-align:right;"><strong>${formatCurrency(r.net_pay)}</strong></td>
      <td><a class="btn btn-secondary btn-sm" href="my-payslip-print.html?line=${r.line_id}">View / Print</a></td>
    </tr>
  `).join('');
}

// "TypeError: Load failed" (iPhone Safari) / "Failed to fetch" (Chrome) = the request never got an
// answer - a mobile-data / Wi-Fi blip or the app resuming from the background, not a server error.
// This page only reads, so it's safe to retry a couple of times before showing anything.
function isNetworkError(error) {
  return /load failed|failed to fetch|network/i.test(error?.message || '');
}

async function loadPayslips() {
  const errorEl = document.getElementById('payslipsError');
  errorEl.classList.add('hidden');
  const tbody = document.getElementById('payslipTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';

  let data = null;
  let error = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    ({ data, error } = await supabaseClient.rpc('my_list_payslips', {
      p_username: currentSession.username,
      p_password: currentSession.password
    }));
    if (!error || !isNetworkError(error)) break;
    await new Promise((resolve) => setTimeout(resolve, attempt * 1000));
  }

  if (error) {
    errorEl.innerHTML = '';
    errorEl.append(isNetworkError(error)
      ? "Couldn't reach the server - check your internet connection. "
      : error.message + ' ');
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.className = 'btn btn-secondary btn-sm';
    retry.textContent = 'Retry';
    retry.addEventListener('click', loadPayslips);
    errorEl.append(retry);
    errorEl.classList.remove('hidden');
    tbody.innerHTML = '<tr><td colspan="8" class="muted">-</td></tr>';
    return;
  }

  renderRows(data || []);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('My Payslips');
  await loadPayslips();
})();
