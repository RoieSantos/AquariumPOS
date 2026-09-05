// Printable single payslip for one PayrollRunLines row, linked from payroll-run.html's "Print"
// button per employee. Modeled directly on stockOnHandPrint.js - same letterhead/toolbar/print
// pattern, single admin_get_payroll_payslip round trip (line + run period + line items).
let currentSession = null;

function formatCurrency(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatDate(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString();
}

function formatCycleLabel(cycle) {
  return cycle === 'SemiMonthly' ? 'Semi-Monthly' : cycle === 'Weekly' ? 'Weekly' : cycle || '';
}

function renderSummary(payslip) {
  document.getElementById('payslipSummary').innerHTML = `
    <div class="form-row"><label>Employee</label><span>${payslip.display_name || payslip.username}</span></div>
    <div class="form-row"><label>Pay Cycle</label><span>${formatCycleLabel(payslip.pay_cycle)}</span></div>
    <div class="form-row"><label>Period</label><span>${formatDate(payslip.period_start)} - ${formatDate(payslip.period_end)}</span></div>
    <div class="form-row"><label>Pay Date</label><span>${formatDate(payslip.pay_date) || '-'}</span></div>
  `;
}

function renderRows(payslip) {
  const tbody = document.getElementById('printTableBody');
  const items = payslip.items || [];

  const itemRows = items
    .map((i) => `
      <tr>
        <td>${i.item_type}</td>
        <td>${i.label}</td>
        <td style="text-align:right;">${i.item_type === 'Deduction' ? '-' : ''}${formatCurrency(i.amount)}</td>
      </tr>
    `)
    .join('');

  tbody.innerHTML = `
    <tr>
      <td>Base Pay</td>
      <td></td>
      <td style="text-align:right;">${formatCurrency(payslip.base_pay)}</td>
    </tr>
    ${itemRows}
    <tr>
      <td colspan="2"><strong>Net Pay</strong></td>
      <td style="text-align:right;"><strong>${formatCurrency(payslip.net_pay)}</strong></td>
    </tr>
  `;
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payroll');
  await renderCompanyLetterhead('companyLetterhead');

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const params = new URLSearchParams(window.location.search);
  const lineId = params.get('line');
  if (!lineId) {
    document.getElementById('printTableBody').innerHTML = '<tr><td class="error-text">No payslip specified.</td></tr>';
    return;
  }

  const { data, error } = await supabaseClient.rpc('admin_get_payroll_payslip', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: lineId
  });

  const payslip = Array.isArray(data) ? data[0] : data;
  if (error || !payslip) {
    document.getElementById('printTableBody').innerHTML = `<tr><td class="error-text">${error?.message || 'Payslip not found.'}</td></tr>`;
    return;
  }

  document.getElementById('printTitle').textContent = `Payslip - ${payslip.display_name || payslip.username}`;
  document.getElementById('printSubtitle').textContent = `Printed: ${new Date().toLocaleString()}`;
  renderSummary(payslip);
  renderRows(payslip);
})();
