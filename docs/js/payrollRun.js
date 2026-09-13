// Payroll run detail page (super users only). Shows one PayrollRuns row's lines (one per
// employee), lets the payroll officer override a line's base pay and attach addition/deduction
// line items (admin_add_payroll_line_item / admin_delete_payroll_line_item), and finalize/delete
// the run. All edit RPCs reject once the run's Status is 'Finalized' - the UI mirrors that by
// disabling the relevant controls once loadRun() sees a Finalized status.
let currentSession = null;
let currentRunId = null;
let currentRun = null;
let currentLines = [];
let currentLineItems = [];
let activeLineId = null;
let activeLine = null;

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

function isRunFinalized() {
  return currentRun?.status === 'Finalized';
}

function renderRunHeader() {
  document.getElementById('runTitle').textContent = `Payroll Run - ${formatDate(currentRun.period_start)} to ${formatDate(currentRun.period_end)}`;
  document.getElementById('runSubtitle').textContent = `${formatCycleLabel(currentRun.pay_cycle)} | Pay Date: ${formatDate(currentRun.pay_date) || 'Not set'} | Created by ${currentRun.created_by || 'unknown'}`;
  document.getElementById('runStatusBadge').innerHTML =
    `<span class="badge ${isRunFinalized() ? 'badge-success' : 'badge-warning'}">${currentRun.status}</span>`;

  document.getElementById('finalizeRunBtn').classList.toggle('hidden', isRunFinalized());
  document.getElementById('deleteRunBtn').classList.toggle('hidden', isRunFinalized());

  document.getElementById('ledgerSection').classList.toggle('hidden', !isRunFinalized());
  if (isRunFinalized()) loadLedger();

  document.getElementById('fundingRequirementBox').classList.toggle('hidden', isRunFinalized());
  if (!isRunFinalized()) loadFundingRequirement();
}

// Preview of admin_finalize_payroll_run's hard-block check (supabase_payroll_funding_ledger.sql) -
// shows the shortfall, if any, before Finalize is even clicked.
async function loadFundingRequirement() {
  const { data, error } = await supabaseClient.rpc('admin_get_payroll_run_funding_requirement', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  const req = Array.isArray(data) ? data[0] : data;
  if (error || !req) return;

  const cashShort = Number(req.cash_required) > Number(req.cash_balance);
  const digitalShort = Number(req.digital_required) > Number(req.digital_balance);

  document.getElementById('cashRequiredDisplay').textContent = formatCurrency(req.cash_required);
  document.getElementById('cashOnHandRunDisplay').textContent = formatCurrency(req.cash_balance);
  document.getElementById('cashStatusDisplay').innerHTML =
    cashShort ? '<span class="badge badge-danger">Short</span>' : '<span class="badge badge-success">OK</span>';

  document.getElementById('digitalRequiredDisplay').textContent = formatCurrency(req.digital_required);
  document.getElementById('digitalOnHandRunDisplay').textContent = formatCurrency(req.digital_balance);
  document.getElementById('digitalStatusDisplay').innerHTML =
    digitalShort ? '<span class="badge badge-danger">Short</span>' : '<span class="badge badge-success">OK</span>';
}

function renderLedgerRows(entries) {
  const tbody = document.getElementById('ledgerTableBody');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">No ledger entries for this run.</td></tr>';
    return;
  }

  // 'Payroll' rows are the run's aggregate Cash/Digital payout, posted once per method at
  // Finalize (see admin_finalize_payroll_run) - not tied to any one employee, hence the fallback.
  const entryTypeBadge = { BasePay: 'badge-neutral', Addition: 'badge-success', Deduction: 'badge-danger', NetPay: 'badge-primary', Payroll: 'badge-danger' };

  tbody.innerHTML = entries
    .map((e) => `
      <tr>
        <td>${e.display_name || e.username || '<span class="muted">-</span>'}</td>
        <td><span class="badge ${entryTypeBadge[e.entry_type] || 'badge-neutral'}">${e.entry_type}</span></td>
        <td>${e.label}${e.method ? ` (${e.method})` : ''}</td>
        <td style="text-align:right;">${formatCurrency(e.amount)}</td>
      </tr>
    `)
    .join('');
}

async function loadLedger() {
  const tbody = document.getElementById('ledgerTableBody');
  tbody.innerHTML = '<tr><td colspan="4" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_ledger_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="4" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderLedgerRows(data);
}

function renderLineRows(lines) {
  currentLines = lines || [];
  const tbody = document.getElementById('lineTableBody');

  if (!lines || lines.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No employees on this run.</td></tr>';
    return;
  }

  const hasDaysWorked = (l) => l.days_worked !== null && l.days_worked !== undefined;
  const unitLabel = (l) => l.pay_type === 'Hourly' ? 'hr' : 'day';

  tbody.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.display_name || l.username}</td>
        <td>${formatCurrency(l.base_pay)}</td>
        <td>${hasDaysWorked(l) ? `${formatCurrency(l.daily_rate)}/${unitLabel(l)}` : '<span class="muted">-</span>'}</td>
        <td>${hasDaysWorked(l) ? `${formatDays(l.days_worked)} ${unitLabel(l)}${l.pay_type === 'Hourly' ? 's' : '(s)'}` : '<span class="muted">-</span>'}</td>
        <td>${formatCurrency(l.additions_total)}</td>
        <td>${formatCurrency(l.deductions_total)}</td>
        <td><strong>${formatCurrency(l.net_pay)}</strong></td>
        <td>
          <button class="btn btn-secondary btn-sm" data-line-id="${l.line_id}" type="button">${isRunFinalized() ? 'View' : 'Edit'}</button>
          <a class="btn btn-secondary btn-sm" href="payroll-print.html?line=${l.line_id}">Print</a>
        </td>
      </tr>
    `)
    .join('');
}

async function loadRun() {
  const { data, error } = await supabaseClient.rpc('admin_get_payroll_run', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  if (error || !data || data.length === 0) {
    document.getElementById('runError').textContent = error?.message || 'Payroll run not found.';
    document.getElementById('runError').classList.remove('hidden');
    return false;
  }

  currentRun = data[0];
  renderRunHeader();
  return true;
}

async function loadLines() {
  const tbody = document.getElementById('lineTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_run_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderLineRows(data);
}

function renderLineItemRows(items) {
  const tbody = document.getElementById('lineItemTableBody');

  if (!items || items.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">No line items yet.</td></tr>';
    return;
  }

  tbody.innerHTML = items
    .map((i) => `
      <tr>
        <td><span class="badge ${i.item_type === 'Addition' ? 'badge-success' : 'badge-danger'}">${i.item_type}</span></td>
        <td>${i.label}</td>
        <td style="text-align:right;">${formatCurrency(i.amount)}</td>
        <td>${isRunFinalized() ? '' : `<button class="btn btn-secondary btn-sm" data-delete-item-id="${i.item_id}" type="button">Remove</button>`}</td>
      </tr>
    `)
    .join('');
}

// Base Pay is only ever partial pay for actual attendance once the auto "Overtime (...)"/
// "Undertime/Absence (...)" items (posted by admin_create_payroll_run) are factored in - split
// those out from any manually-added items so Gross Pay reflects hours actually worked, and Other
// Additions/Deductions are whatever the officer layered on top by hand.
function classifyLineItems(items) {
  const sum = (arr) => arr.reduce((s, i) => s + (Number(i.amount) || 0), 0);
  const overtime = (items || []).filter((i) => i.item_type === 'Addition' && /^Overtime/i.test(i.label || ''));
  const absent = (items || []).filter((i) => i.item_type === 'Deduction' && /^Undertime/i.test(i.label || ''));
  const otherAdditions = (items || []).filter((i) => i.item_type === 'Addition' && !/^Overtime/i.test(i.label || ''));
  const otherDeductions = (items || []).filter((i) => i.item_type === 'Deduction' && !/^Undertime/i.test(i.label || ''));
  return {
    overtime: sum(overtime),
    absent: sum(absent),
    otherAdditions: sum(otherAdditions),
    otherDeductions: sum(otherDeductions)
  };
}

function formatDays(days) {
  return (Number(days) || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// line is null when the Base Pay field was just hand-overridden via Save Base Pay - at that point
// the stored day-rate x days-worked breakdown no longer matches the officer's typed-in number, so
// fall back to a plain figure instead of showing a stale formula.
function renderLineSummary(basePay, items, line) {
  const c = classifyLineItems(items);
  const grossPay = basePay - c.absent + c.overtime;
  const netPay = grossPay + c.otherAdditions - c.otherDeductions;

  const hasDaysWorked = line && line.days_worked !== null && line.days_worked !== undefined;
  // Hourly's "days worked" is really hours worked - same DaysWorked/DailyRate columns, just a
  // different unit for display (see supabase_payroll_hourly_days_worked_display.sql).
  const unitLabel = line && line.pay_type === 'Hourly' ? 'hrs' : 'day(s)';
  // More than one entry means the period crossed a calendar month boundary (Weekly only) and was
  // priced with two different daily rates - break those out instead of showing one blended number.
  const breakdown = hasDaysWorked && Array.isArray(line.daily_rate_breakdown) ? line.daily_rate_breakdown : [];
  const isBlended = breakdown.length > 1;

  document.getElementById('summaryDaysWorkedRow').classList.toggle('hidden', !hasDaysWorked);
  document.getElementById('summaryBreakdownRow').classList.toggle('hidden', !isBlended);
  if (hasDaysWorked) {
    document.getElementById('summaryBasePay').textContent = isBlended
      ? `${formatCurrency(basePay)} (blended - see below)`
      : `${formatCurrency(line.daily_rate)} x ${formatDays(line.days_worked)} ${unitLabel} = ${formatCurrency(basePay)}`;
    document.getElementById('summaryDaysWorked').textContent = `${formatDays(line.days_worked)} ${unitLabel}`;
    if (isBlended) {
      document.getElementById('summaryBreakdownContent').innerHTML = breakdown
        .map((b) => `${b.month}: ${formatDays(b.days_worked)} day(s) x ${formatCurrency(b.daily_rate)} = ${formatCurrency(b.subtotal)}`)
        .join('<br>');
    }
  } else {
    document.getElementById('summaryBasePay').textContent = formatCurrency(basePay);
  }
  document.getElementById('summaryOvertime').textContent = formatCurrency(c.overtime);
  document.getElementById('summaryAbsent').textContent = c.absent > 0 ? `-${formatCurrency(c.absent)}` : formatCurrency(0);
  document.getElementById('summaryGrossPay').textContent = formatCurrency(grossPay);
  document.getElementById('summaryOtherAdditions').textContent = formatCurrency(c.otherAdditions);
  document.getElementById('summaryOtherDeductions').textContent = c.otherDeductions > 0 ? `-${formatCurrency(c.otherDeductions)}` : formatCurrency(0);
  document.getElementById('summaryNetPay').textContent = formatCurrency(netPay);
}

async function loadLineItems(lineId) {
  const tbody = document.getElementById('lineItemTableBody');
  tbody.innerHTML = '<tr><td colspan="4" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_run_line_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: lineId
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="4" class="error-text">${error.message}</td></tr>`;
    return;
  }

  currentLineItems = data || [];
  renderLineItemRows(currentLineItems);
  renderLineSummary(Number(document.getElementById('lineBasePay').value) || 0, currentLineItems, activeLine);
}

async function openLineModal(lineId) {
  const line = currentLines.find((l) => l.line_id === lineId);
  if (!line) return;

  activeLineId = lineId;
  activeLine = line;
  document.getElementById('lineModalTitle').textContent = `Payroll Line - ${line.display_name || line.username}`;
  document.getElementById('lineBasePay').value = Number(line.base_pay) || 0;
  document.getElementById('lineBasePay').disabled = isRunFinalized();
  document.getElementById('saveBasePayBtn').classList.toggle('hidden', isRunFinalized());
  document.getElementById('addLineItemBtn').classList.toggle('hidden', isRunFinalized());
  document.getElementById('newItemType').closest('.form-grid').classList.toggle('hidden', isRunFinalized());
  document.getElementById('newItemLabel').value = '';
  document.getElementById('newItemAmount').value = '';
  document.getElementById('lineItemError').classList.add('hidden');
  document.getElementById('printPayslipLink').href = `payroll-print.html?line=${lineId}`;

  document.getElementById('lineModal').classList.remove('hidden');
  await loadLineItems(lineId);
}

async function saveBasePay() {
  const basePay = Number(document.getElementById('lineBasePay').value) || 0;

  const { data, error } = await supabaseClient.rpc('admin_update_payroll_run_line_base_pay', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: activeLineId,
    p_base_pay: basePay
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    const errorEl = document.getElementById('lineItemError');
    errorEl.textContent = error?.message || result?.message || 'Failed to update base pay.';
    errorEl.classList.remove('hidden');
    return;
  }

  renderLineSummary(basePay, currentLineItems, null);
  await loadLines();
  await loadFundingRequirement();
}

// Guards against the auto-save triggers below (blur + Enter can both fire for the same entry)
// double-submitting the same line item while the first save is still in flight.
let isAddingLineItem = false;

async function addLineItem() {
  if (isAddingLineItem) return;

  const errorEl = document.getElementById('lineItemError');
  errorEl.classList.add('hidden');

  const itemType = document.getElementById('newItemType').value;
  const label = document.getElementById('newItemLabel').value.trim();
  const amount = Number(document.getElementById('newItemAmount').value);

  if (!label || !amount || amount <= 0) return;

  isAddingLineItem = true;
  const addBtn = document.getElementById('addLineItemBtn');
  addBtn.disabled = true;

  const { data, error } = await supabaseClient.rpc('admin_add_payroll_line_item', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: activeLineId,
    p_item_type: itemType,
    p_label: label,
    p_amount: amount
  });

  addBtn.disabled = false;
  isAddingLineItem = false;

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to add line item.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('newItemLabel').value = '';
  document.getElementById('newItemAmount').value = '';
  await loadLineItems(activeLineId);
  await loadLines();
  await loadFundingRequirement();
}

// Auto-save the Addition/Deduction being typed - per "once the user add a addition and deduction
// manually can you auto save it" - so leaving the Amount field (tab/click away) or pressing Enter
// in either field commits it immediately, without needing a separate click on "+ Add Line Item".
// addLineItem() itself already no-ops until both Label and a positive Amount are present, so this
// is safe to call opportunistically on every blur.
function wireLineItemAutoSave() {
  const labelInput = document.getElementById('newItemLabel');
  const amountInput = document.getElementById('newItemAmount');

  amountInput.addEventListener('blur', addLineItem);
  amountInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      addLineItem();
    }
  });
  labelInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      if (amountInput.value) {
        addLineItem();
      } else {
        amountInput.focus();
      }
    }
  });
}

async function deleteLineItem(itemId) {
  const { data, error } = await supabaseClient.rpc('admin_delete_payroll_line_item', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_id: itemId
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    const errorEl = document.getElementById('lineItemError');
    errorEl.textContent = error?.message || result?.message || 'Failed to remove line item.';
    errorEl.classList.remove('hidden');
    return;
  }

  await loadLineItems(activeLineId);
  await loadLines();
  await loadFundingRequirement();
}

async function finalizeRun() {
  if (!confirm('Finalize this payroll run? Base pay and line items can no longer be edited afterward.')) return;

  const { data, error } = await supabaseClient.rpc('admin_finalize_payroll_run', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    document.getElementById('runError').textContent = error?.message || result?.message || 'Failed to finalize run.';
    document.getElementById('runError').classList.remove('hidden');
    return;
  }

  await loadRun();
  await loadLines();
}

async function deleteRun() {
  if (!confirm('Delete this payroll run? This cannot be undone.')) return;

  const { data, error } = await supabaseClient.rpc('admin_delete_payroll_run', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    document.getElementById('runError').textContent = error?.message || result?.message || 'Failed to delete run.';
    document.getElementById('runError').classList.remove('hidden');
    return;
  }

  window.location.href = 'payroll.html';
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payroll');

  if (!session.isSuperUser && !session.isPayrollOfficer) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  const params = new URLSearchParams(window.location.search);
  currentRunId = params.get('run');
  if (!currentRunId) {
    window.location.href = 'payroll.html';
    return;
  }

  document.getElementById('runContent').classList.remove('hidden');
  const loaded = await loadRun();
  if (loaded) await loadLines();

  document.getElementById('lineTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-line-id]');
    if (btn) openLineModal(btn.getAttribute('data-line-id'));
  });
  document.getElementById('closeLineModalBtn').addEventListener('click', () =>
    document.getElementById('lineModal').classList.add('hidden')
  );
  document.getElementById('saveBasePayBtn').addEventListener('click', saveBasePay);
  document.getElementById('addLineItemBtn').addEventListener('click', addLineItem);
  wireLineItemAutoSave();
  document.getElementById('lineItemTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-delete-item-id]');
    if (btn) deleteLineItem(btn.getAttribute('data-delete-item-id'));
  });
  document.getElementById('finalizeRunBtn').addEventListener('click', finalizeRun);
  document.getElementById('deleteRunBtn').addEventListener('click', deleteRun);
})();
