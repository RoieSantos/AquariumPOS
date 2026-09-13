// Self-service printable payslip, linked from my-payslips.html's "View / Print" action. Same
// rendering as js/payrollPrint.js (the Payroll Officer/admin version), but sources the row from
// my_get_payslip (supabase_payroll_self_service_payslips.sql) using the viewer's OWN session
// credentials - the RPC hard-scopes to that username and Finalized runs only, so there's no
// p_admin_username/p_admin_password authorization check to satisfy here.
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

// Same split as payrollRun.js's classifyLineItems: the auto "Overtime (...)"/"Undertime/Absence
// (...)" items (posted by admin_create_payroll_run) net against Base Pay to show pay for hours
// actually worked (Gross Pay); anything manually added is an "Other" item on top of that.
function classifyLineItems(items) {
  const isOvertime = (i) => i.item_type === 'Addition' && /^Overtime/i.test(i.label || '');
  const isAbsent = (i) => i.item_type === 'Deduction' && /^Undertime/i.test(i.label || '');
  return {
    overtimeItems: (items || []).filter(isOvertime),
    absentItems: (items || []).filter(isAbsent),
    otherItems: (items || []).filter((i) => !isOvertime(i) && !isAbsent(i))
  };
}

function itemRow(i) {
  return `
    <tr>
      <td>${i.item_type}</td>
      <td>${i.label}</td>
      <td style="text-align:right;">${i.item_type === 'Deduction' ? '-' : ''}${formatCurrency(i.amount)}</td>
    </tr>
  `;
}

function renderRows(payslip) {
  const tbody = document.getElementById('printTableBody');
  const { overtimeItems, absentItems, otherItems } = classifyLineItems(payslip.items || []);

  const sum = (arr) => arr.reduce((s, i) => s + (Number(i.amount) || 0), 0);
  const grossPay = Number(payslip.base_pay) - sum(absentItems) + sum(overtimeItems);

  const formatDays = (days) => (Number(days) || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const hasDaysWorked = payslip.days_worked !== null && payslip.days_worked !== undefined;
  // Hourly's "days worked" is really hours worked - same DaysWorked/DailyRate columns, just a
  // different unit for display (see supabase_payroll_hourly_days_worked_display.sql).
  const unitLabel = payslip.pay_type === 'Hourly' ? 'hrs' : 'day(s)';
  // More than one entry means the period crossed a calendar month boundary (Weekly only) and was
  // priced with two different daily rates - break those out on their own rows instead of showing
  // one blended number next to Base Pay.
  const breakdown = hasDaysWorked && Array.isArray(payslip.daily_rate_breakdown) ? payslip.daily_rate_breakdown : [];
  const isBlended = breakdown.length > 1;
  const daysWorkedLabel = hasDaysWorked && !isBlended
    ? `${formatDays(payslip.days_worked)} ${unitLabel} x ${formatCurrency(payslip.daily_rate)}`
    : '';

  tbody.innerHTML = `
    <tr>
      <td>Base Pay</td>
      <td>${daysWorkedLabel}</td>
      <td style="text-align:right;">${formatCurrency(payslip.base_pay)}</td>
    </tr>
    ${breakdown.map((b) => `
      <tr>
        <td></td>
        <td>${b.month}: ${formatDays(b.days_worked)} day(s) x ${formatCurrency(b.daily_rate)}</td>
        <td style="text-align:right;">${formatCurrency(b.subtotal)}</td>
      </tr>
    `).join('')}
    ${overtimeItems.map(itemRow).join('')}
    ${absentItems.map(itemRow).join('')}
    <tr>
      <td colspan="2"><strong>Gross Pay</strong></td>
      <td style="text-align:right;"><strong>${formatCurrency(grossPay)}</strong></td>
    </tr>
    ${otherItems.map(itemRow).join('')}
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
  renderTopNav('My Payslips');
  await renderCompanyLetterhead('companyLetterhead');

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const params = new URLSearchParams(window.location.search);
  const lineId = params.get('line');
  if (!lineId) {
    document.getElementById('printTableBody').innerHTML = '<tr><td class="error-text">No payslip specified.</td></tr>';
    return;
  }

  const { data, error } = await supabaseClient.rpc('my_get_payslip', {
    p_username: currentSession.username,
    p_password: currentSession.password,
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
