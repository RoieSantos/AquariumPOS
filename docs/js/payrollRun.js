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

  // Xendit lines are paid from the Xendit sales balance after Finalize - shown, never a Finalize block.
  const xenditRequired = Number(req.xendit_required) || 0;
  document.getElementById('xenditFundingRow').classList.toggle('hidden', xenditRequired <= 0);
  if (xenditRequired > 0) {
    document.getElementById('xenditRequiredDisplay').textContent = formatCurrency(xenditRequired);
    const balance = currentSession.isSuperUser ? await callPayoutFunction({ action: 'balance' }).catch(() => null) : null;
    const onHand = balance && typeof balance.balance === 'number' ? balance.balance : null;
    document.getElementById('xenditOnHandRunDisplay').textContent = onHand == null ? '-' : formatCurrency(onHand);
    document.getElementById('xenditStatusDisplay').innerHTML = onHand == null
      ? '<span class="muted">Checked when sending</span>'
      : onHand >= xenditRequired ? '<span class="badge badge-success">OK</span>'
        : '<span class="badge badge-warning">Short now</span> <span class="muted">- wait for sales to settle or top up before sending</span>';
  }
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
        <td class="num">${formatCurrency(e.amount)}</td>
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
    tbody.innerHTML = '<tr><td colspan="8" class="cell-msg">No employees on this run.</td></tr>';
    document.getElementById('lineTableFoot').innerHTML = '';
    selectedLineId = null;
    updateLineActionState();
    return;
  }

  const hasDaysWorked = (l) => l.days_worked !== null && l.days_worked !== undefined;
  const unitLabel = (l) => l.pay_type === 'Hourly' ? 'hr' : 'day';
  // payment_method is already defaulted to Cash server-side, same rule as the funding requirement.
  const methodBadge = (m) => `<span class="badge ${m === 'Xendit' ? 'badge-purple' : m === 'Digital' ? 'badge-primary' : 'badge-success'}">${m || 'Cash'}</span>`;
  // Finalized Xendit lines: the payout's status under the badge (sql/supabase_xendit_payroll_payouts.sql).
  const payoutNote = (l) => {
    if (l.payment_method !== 'Xendit' || !isRunFinalized()) return '';
    const p = currentPayouts.find((x) => x.line_id === l.line_id);
    return p ? `<div style="font-size:11.5px;">${payoutStatusHtml(p)}</div>` : '';
  };
  // Draft runs get a dropdown to change the method for this run only - see saveLineMethod().
  const methodCell = (l) => isRunFinalized() ? methodBadge(l.payment_method) + payoutNote(l) : `
    <select data-method-line-id="${l.line_id}" aria-label="Pay method for ${l.display_name || l.username}">
      <option value="Cash"${l.payment_method === 'Digital' ? '' : ' selected'}>Cash</option>
      <option value="Digital"${l.payment_method === 'Digital' ? ' selected' : ''}>Digital</option>
      <option value="Xendit"${l.payment_method === 'Xendit' ? ' selected' : ''}>Xendit</option>
    </select>`;

  tbody.innerHTML = lines
    .map((l) => `
      <tr data-line-row="${l.line_id}" class="${l.line_id === selectedLineId ? 'selected' : ''}">
        <td><a href="#" class="bc-link" data-line-id="${l.line_id}" title="Open this payroll line">${l.display_name || l.username}</a></td>
        <td>${methodCell(l)}</td>
        <td class="num">${formatCurrency(l.base_pay)}</td>
        <td class="num">${hasDaysWorked(l) ? `${formatCurrency(l.daily_rate)}/${unitLabel(l)}` : '<span class="muted">-</span>'}</td>
        <td class="num">${hasDaysWorked(l) ? `${formatDays(l.days_worked)} ${unitLabel(l)}${l.pay_type === 'Hourly' ? 's' : '(s)'}` : '<span class="muted">-</span>'}</td>
        <td class="num">${formatCurrency(l.additions_total)}</td>
        <td class="num">${formatCurrency(l.deductions_total)}</td>
        <td class="num"><strong>${formatCurrency(l.net_pay)}</strong></td>
      </tr>
    `)
    .join('');

  const sum = (field) => lines.reduce((s, l) => s + (Number(l[field]) || 0), 0);
  document.getElementById('lineTableFoot').innerHTML = `<tr>
    <td>Total (${lines.length} employee${lines.length === 1 ? '' : 's'})</td><td></td>
    <td class="num">${formatCurrency(sum('base_pay'))}</td><td></td><td></td>
    <td class="num">${formatCurrency(sum('additions_total'))}</td>
    <td class="num">${formatCurrency(sum('deductions_total'))}</td>
    <td class="num">${formatCurrency(sum('net_pay'))}</td></tr>`;

  if (!lines.some((l) => l.line_id === selectedLineId)) selectedLineId = null;
  updateLineActionState();
  updatePayXenditButton();
}

// BC document: Edit Line / Print Payslip act on the selected line (click a row to select it).
let selectedLineId = null;

function updateLineActionState() {
  const btn = document.getElementById('editLineBtn');
  btn.disabled = !selectedLineId;
  btn.lastChild.textContent = isRunFinalized() ? 'View Line' : 'Edit Line';
  document.getElementById('printLineBtn').disabled = !selectedLineId;
}

function selectLine(lineId) {
  selectedLineId = lineId;
  document.querySelectorAll('#lineTableBody tr[data-line-row]').forEach((tr) => {
    tr.classList.toggle('selected', tr.dataset.lineRow === lineId);
  });
  updateLineActionState();
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
  if (isRunFinalized()) await loadPayouts();
  const tbody = document.getElementById('lineTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="cell-msg">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_payroll_run_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="cell-msg error-text">${error.message}</td></tr>`;
    return;
  }

  renderLineRows(data);
}

// Per "sometimes they are paying digital instead of cash" - changes this run's line only, never the
// employee's default in Payroll Setup (supabase_payroll_run_line_method_override.sql).
async function saveLineMethod(lineId, method) {
  const errorEl = document.getElementById('runError');
  errorEl.classList.add('hidden');

  const { data, error } = await supabaseClient.rpc('admin_set_payroll_run_line_method', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: lineId,
    p_method: method
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to update pay method.';
    errorEl.classList.remove('hidden');
  }

  await loadLines();
  await loadFundingRequirement();
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
        <td>${isRunFinalized() ? '' : `<button class="bc-link" data-delete-item-id="${i.item_id}" type="button">Remove</button>`}</td>
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
  document.getElementById('newItemFields').classList.toggle('hidden', isRunFinalized());
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

// ---------------------------------------------------------------- Pay via Xendit
// sql/supabase_xendit_payroll_payouts.sql + Edge Function xendit-payroll-payout. Sending is super users only (the
// function re-checks); payroll officers see the statuses and can Refresh Status.
let currentPayouts = [];
let payoutBusy = false;
let payoutBalanceInfo = null;

const PAYOUT_DONE = ['SUCCEEDED'];
const PAYOUT_GOING = ['Creating', 'ACCEPTED', 'REQUESTED'];

async function callPayoutFunction(payload) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/xendit-payroll-payout`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`, 'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY },
    body: JSON.stringify({ ...payload, username: currentSession.username, password: currentSession.password })
  });
  const data = await response.json().catch(() => null);
  if (response.status === 404) throw new Error('The xendit-payroll-payout Edge Function isn\'t deployed yet.');
  if (!response.ok) throw new Error(data?.error || `HTTP ${response.status}`);
  return data;
}

async function loadPayouts() {
  const { data, error } = await supabaseClient.rpc('admin_list_payroll_run_payouts', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_run_id: currentRunId
  });
  currentPayouts = error ? [] : (data || []);
  return !error;
}

function escapeHtmlText(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function payoutStatusHtml(p) {
  const test = p.is_test ? ' <strong style="color:#b45309;">TEST</strong>' : '';
  if (!p.status) return '<span class="muted">Not sent</span>';
  if (p.status === 'SUCCEEDED') {
    return `<span style="color:var(--success);">Paid</span>${p.paid_at ? ` <span class="muted">${new Date(p.paid_at).toLocaleDateString()}</span>` : ''}${test}`;
  }
  if (PAYOUT_GOING.includes(p.status)) return `<span style="color:#a6720a;">Sending...</span>${test}`;
  const label = p.status === 'Error' ? 'Not sent' : p.status.charAt(0) + p.status.slice(1).toLowerCase();
  return `<span style="color:var(--danger);">${escapeHtmlText(label)}</span>${test}`
    + (p.failure ? ` <span class="muted" title="${escapeHtmlText(p.failure)}">- ${escapeHtmlText(p.failure)}</span>` : '');
}

// Lines still to pay for real: never sent, only sent in test, or the last try failed / was refused.
function payoutPending(p) {
  if (!p.has_account || Number(p.net_pay) <= 0) return false;
  if (!p.status || p.is_test) return true;
  return !(PAYOUT_DONE.includes(p.status) || PAYOUT_GOING.includes(p.status));
}

function updatePayXenditButton() {
  const show = isRunFinalized() && currentLines.some((l) => l.payment_method === 'Xendit');
  document.getElementById('payXenditBtn').classList.toggle('hidden', !show);
  document.getElementById('payXenditSep').classList.toggle('hidden', !show);
}

function renderPayoutDialog(balanceInfo) {
  const tbody = document.getElementById('payoutTableBody');
  if (!currentPayouts.length) {
    tbody.innerHTML = '<tr><td colspan="5" class="cell-msg">No Xendit lines on this run.</td></tr>';
  } else {
    tbody.innerHTML = currentPayouts.map((p) => {
      // Where it went (the payout's own copy) once sent / on its way; a line still to send (incl. a failed one)
      // shows the account saved now, since that's where the next send goes.
      const payTo = p.payout_channel && !payoutPending(p) ?`${escapeHtmlText(p.payout_channel)} ${escapeHtmlText(p.payout_account_masked || '')}`
        : p.has_account ? `${escapeHtmlText(p.channel_name)} ${escapeHtmlText(p.account_masked || '')}`
          : '<span class="error-text">No payout account - add it in Payroll Setup</span>';
      return `<tr>
        <td>${escapeHtmlText(p.display_name || p.username)}</td>
        <td>${payTo}</td>
        <td>${escapeHtmlText(p.account_name || '')}</td>
        <td class="num">${formatCurrency(p.net_pay)}</td>
        <td>${payoutStatusHtml(p)}</td>
      </tr>`;
    }).join('');
  }

  const pending = currentPayouts.filter(payoutPending);
  const toSend = pending.reduce((s, p) => s + (Number(p.net_pay) || 0), 0);
  const paid = currentPayouts.filter((p) => p.status === 'SUCCEEDED' && !p.is_test).reduce((s, p) => s + (Number(p.net_pay) || 0), 0);
  const balance = balanceInfo && typeof balanceInfo.balance === 'number' ? balanceInfo.balance : null;
  const mode = !balanceInfo || balanceInfo.error ? ''
    : balanceInfo.isTest ? '<strong style="color:#b45309;">TEST mode</strong> - no real money moves.' : '<strong>LIVE</strong> - real money.';
  document.getElementById('payoutSummaryBox').innerHTML = `
    ${mode ? `<div>${mode}</div>` : ''}
    <div>To send now: <strong>${formatCurrency(toSend)}</strong> to ${pending.length} employee${pending.length === 1 ? '' : 's'}${paid ? ` · Already paid: ${formatCurrency(paid)}` : ''}</div>
    <div>Xendit available balance: <strong>${balance == null ? '-' : formatCurrency(balance)}</strong>${balance != null && balance < toSend ? ' <span class="error-text">- not enough; wait for sales to settle or top up Xendit</span>' : ''}</div>`;

  const sendBtn = document.getElementById('sendPayoutsBtn');
  sendBtn.classList.toggle('hidden', !currentSession.isSuperUser);
  sendBtn.disabled = payoutBusy || pending.length === 0;
  sendBtn.textContent = pending.length ? `Send ${formatCurrency(toSend)}` : 'Nothing to send';
  sendBtn.dataset.total = String(toSend);
  sendBtn.dataset.count = String(pending.length);
}

function showPayoutMessage(text, isError) {
  const el = document.getElementById('payoutMessage');
  el.textContent = text || '';
  el.className = `bc-dialog-msg ${isError ? 'error-text' : 'muted'}`;
  el.classList.toggle('hidden', !text);
}

async function openPayoutDialog() {
  document.getElementById('payoutModal').classList.remove('hidden');
  showPayoutMessage('');
  document.getElementById('payoutTableBody').innerHTML = '<tr><td colspan="5" class="cell-msg">Loading...</td></tr>';
  const [balanceInfo] = await Promise.all([
    currentSession.isSuperUser ? callPayoutFunction({ action: 'balance' }).catch((err) => ({ error: err.message })) : Promise.resolve(null),
    loadPayouts()
  ]);
  payoutBalanceInfo = balanceInfo;
  renderPayoutDialog(balanceInfo);
  if (balanceInfo?.error) showPayoutMessage(balanceInfo.error, true);
}

async function sendPayouts() {
  const btn = document.getElementById('sendPayoutsBtn');
  const total = Number(btn.dataset.total) || 0;
  const count = Number(btn.dataset.count) || 0;
  if (!count || payoutBusy) return;
  const mode = payoutBalanceInfo?.isTest ? 'TEST (no real money)' : 'LIVE - real money';
  if (!confirm(`Send ${formatCurrency(total)} to ${count} employee${count === 1 ? '' : 's'} through Xendit?\n\nMode: ${mode}\n\nThis can't be undone.`)) return;
  payoutBusy = true;
  btn.disabled = true;
  btn.textContent = 'Sending...';
  showPayoutMessage('Sending - keep this window open...');
  try {
    const result = await callPayoutFunction({ action: 'send', runId: currentRunId });
    const failed = result.failed || [];
    showPayoutMessage(
      result.note || (`${result.sent} sent.`
        + (failed.length ? ` ${failed.length} not sent: ${failed.map((f) => `${f.name} (${f.error})`).join('; ')}` : ' Xendit confirms each one shortly - press Refresh Status.')),
      failed.length > 0
    );
  } catch (err) {
    showPayoutMessage(err.message, true);
  } finally {
    payoutBusy = false;
    await loadPayouts();
    renderPayoutDialog(payoutBalanceInfo);
    await loadLines();
  }
}

async function refreshPayouts() {
  const btn = document.getElementById('refreshPayoutsBtn');
  btn.disabled = true;
  showPayoutMessage('Checking with Xendit...');
  try {
    const result = await callPayoutFunction({ action: 'refresh', runId: currentRunId });
    showPayoutMessage(result.checked ? `Checked ${result.checked} payout${result.checked === 1 ? '' : 's'} with Xendit.` : 'Nothing waiting on Xendit.');
  } catch (err) {
    showPayoutMessage(err.message, true);
  } finally {
    btn.disabled = false;
    await loadPayouts();
    renderPayoutDialog(payoutBalanceInfo);
    await loadLines();
  }
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
    // Per "if a user dont have permission just show them payslips by default" - see payroll.js.
    window.location.href = 'my-payslips.html';
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

  const lineBody = document.getElementById('lineTableBody');
  lineBody.addEventListener('click', (e) => {
    const link = e.target.closest('[data-line-id]');
    if (link) {
      e.preventDefault();
      selectLine(link.getAttribute('data-line-id'));
      openLineModal(link.getAttribute('data-line-id'));
      return;
    }
    const tr = e.target.closest('tr[data-line-row]');
    if (tr) selectLine(tr.dataset.lineRow);
  });
  lineBody.addEventListener('change', (e) => {
    const select = e.target.closest('[data-method-line-id]');
    if (select) saveLineMethod(select.getAttribute('data-method-line-id'), select.value);
  });
  lineBody.addEventListener('dblclick', (e) => {
    if (e.target.closest('[data-method-line-id]')) return;
    const tr = e.target.closest('tr[data-line-row]');
    if (tr) openLineModal(tr.dataset.lineRow);
  });
  document.getElementById('editLineBtn').addEventListener('click', () => selectedLineId && openLineModal(selectedLineId));
  document.getElementById('printLineBtn').addEventListener('click', () => {
    if (selectedLineId) window.location.href = `payroll-print.html?line=${selectedLineId}`;
  });
  const closeLineModal = () => document.getElementById('lineModal').classList.add('hidden');
  document.getElementById('closeLineModalBtn').addEventListener('click', closeLineModal);
  document.getElementById('doneLineModalBtn').addEventListener('click', closeLineModal);
  document.getElementById('saveBasePayBtn').addEventListener('click', saveBasePay);
  document.getElementById('addLineItemBtn').addEventListener('click', addLineItem);
  wireLineItemAutoSave();
  document.getElementById('lineItemTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-delete-item-id]');
    if (btn) deleteLineItem(btn.getAttribute('data-delete-item-id'));
  });
  document.getElementById('finalizeRunBtn').addEventListener('click', finalizeRun);
  document.getElementById('payXenditBtn').addEventListener('click', openPayoutDialog);
  document.getElementById('sendPayoutsBtn').addEventListener('click', sendPayouts);
  document.getElementById('refreshPayoutsBtn').addEventListener('click', refreshPayouts);
  document.querySelectorAll('[data-close-payout]').forEach((el) => el.addEventListener('click', () => {
    if (!payoutBusy) document.getElementById('payoutModal').classList.add('hidden');
  }));
  document.getElementById('deleteRunBtn').addEventListener('click', deleteRun);
})();
