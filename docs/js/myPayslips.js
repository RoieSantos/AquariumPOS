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

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('My Payslips');

  const { data, error } = await supabaseClient.rpc('my_list_payslips', {
    p_username: currentSession.username,
    p_password: currentSession.password
  });

  if (error) {
    document.getElementById('payslipsError').textContent = error.message;
    document.getElementById('payslipsError').classList.remove('hidden');
    document.getElementById('payslipTableBody').innerHTML = '<tr><td colspan="8" class="muted">-</td></tr>';
    return;
  }

  renderRows(data || []);
})();
