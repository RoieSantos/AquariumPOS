// Bills & Dues page (super users only) - the business's recurring must-pay bills (rent, utilities,
// BIR, SSS/PhilHealth/Pag-IBIG, permits...), per "create me a new feature showing all the business
// mandatory bills to pay". See sql/supabase_business_bills.sql. Three views on one page: the bill
// list (each with its next unpaid due date + status), a month-by-month schedule, and payment
// history. Paying can also log an Expense Journal entry (EXP- receipt) in the same RPC call.
let currentSession = null;
let currentBills = [];
let scheduleMonth = null;      // 'YYYY-MM'
let paymentFilterBillId = null;
let editingBillId = null;
let payingBill = null;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatMoney(value) {
  if (value === null || value === undefined || value === '') return '-';
  const amount = Number(value) || 0;
  return '₱' + amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value + 'T00:00:00');
  return isNaN(d.getTime()) ? value : d.toLocaleDateString('en-PH', { month: 'short', day: 'numeric', year: 'numeric' });
}

// Manila "today" as YYYY-MM-DD, same store-timezone boundary the RPCs use.
function todayManila() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Manila' }).format(new Date());
}

function monthRange(ym) {
  const [y, m] = ym.split('-').map(Number);
  const last = new Date(y, m, 0).getDate();
  return { from: `${ym}-01`, to: `${ym}-${String(last).padStart(2, '0')}` };
}

function shiftMonth(ym, delta) {
  const [y, m] = ym.split('-').map(Number);
  const d = new Date(y, m - 1 + delta, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function daysBetween(fromIso, toIso) {
  return Math.round((new Date(toIso + 'T00:00:00') - new Date(fromIso + 'T00:00:00')) / 86400000);
}

function statusBadge(bill) {
  if (!bill.is_active) return '<span class="badge badge-neutral">Inactive</span>';
  switch (bill.status) {
    case 'Overdue': {
      const extra = bill.overdue_count > 1 ? ` (${bill.overdue_count} periods)` : '';
      return `<span class="badge badge-danger">Overdue${extra}</span>`;
    }
    case 'Due Soon': return '<span class="badge badge-warning">Due Soon</span>';
    case 'Paid': return '<span class="badge badge-success">Paid</span>';
    default: return '<span class="badge badge-primary">Upcoming</span>';
  }
}

function dueHint(dueIso) {
  if (!dueIso) return '';
  const diff = daysBetween(todayManila(), dueIso);
  if (diff === 0) return 'today';
  if (diff === 1) return 'tomorrow';
  if (diff > 0) return `in ${diff} days`;
  return `${-diff} day${diff === -1 ? '' : 's'} late`;
}

async function rpc(name, params) {
  return supabaseClient.rpc(name, {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    ...params
  });
}

// ---------------------------------------------------------------------------
// Bill list + stat cards

async function loadBills() {
  const tbody = document.getElementById('billTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await rpc('admin_list_business_bills', {
    p_include_inactive: document.getElementById('showInactiveInput').checked
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  currentBills = data || [];
  renderStatsFromBills();

  if (currentBills.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No bills yet - click "+ New Bill" to add rent, utilities, taxes, etc.</td></tr>';
    return;
  }

  tbody.innerHTML = currentBills.map((b) => `
    <tr>
      <td>${statusBadge(b)}</td>
      <td>
        <strong>${escapeHtml(b.name)}</strong>
        ${b.payee || b.account_no ? `<div class="muted" style="font-size:12px;">${escapeHtml([b.payee, b.account_no].filter(Boolean).join(' · '))}</div>` : ''}
      </td>
      <td>${escapeHtml(b.category || '')}</td>
      <td>${escapeHtml(b.warehouse || 'Company-wide')}</td>
      <td>${escapeHtml(b.frequency)}</td>
      <td>${b.next_due_date ? `${formatDate(b.next_due_date)}<div class="muted" style="font-size:12px;">${dueHint(b.next_due_date)}</div>` : '-'}</td>
      <td style="text-align:right;">${formatMoney(b.expected_amount)}</td>
      <td>${b.last_paid_date ? `${formatDate(b.last_paid_date)}<div class="muted" style="font-size:12px;">${formatMoney(b.last_paid_amount)}</div>` : '<span class="muted">Never</span>'}</td>
      <td style="white-space:nowrap;">
        ${b.next_due_date && b.is_active ? `<button class="btn btn-success btn-sm" data-pay-bill="${b.bill_id}" type="button">Pay</button>` : ''}
        <button class="btn btn-secondary btn-sm" data-edit-bill="${b.bill_id}" type="button">Edit</button>
        <button class="btn btn-secondary btn-sm" data-history-bill="${b.bill_id}" type="button">History</button>
      </td>
    </tr>
  `).join('');
}

function renderStatsFromBills() {
  const active = currentBills.filter((b) => b.is_active);
  const overdue = active.filter((b) => b.status === 'Overdue');
  const dueSoon = active.filter((b) => b.status === 'Due Soon');
  // Overdue amount counts every missed period, not just the oldest one.
  const overdueAmt = overdue.reduce((sum, b) => sum + (Number(b.expected_amount) || 0) * Math.max(b.overdue_count, 1), 0);
  const dueSoonAmt = dueSoon.reduce((sum, b) => sum + (Number(b.expected_amount) || 0), 0);

  document.getElementById('statOverdue').textContent = overdue.length;
  document.getElementById('statOverdueAmt').textContent = overdue.length ? `≈ ${formatMoney(overdueAmt)}` : 'All caught up';
  document.getElementById('statDueSoon').textContent = dueSoon.length;
  document.getElementById('statDueSoonAmt').textContent = dueSoon.length ? `≈ ${formatMoney(dueSoonAmt)}` : 'Nothing due soon';
}

// "Still to pay / paid this month" always reflect the CURRENT month, whatever month the schedule shows.
async function loadMonthStats() {
  const { from, to } = monthRange(todayManila().slice(0, 7));
  const { data, error } = await rpc('admin_list_business_bill_schedule', { p_from: from, p_to: to });
  if (error) return;

  const rows = data || [];
  const unpaid = rows.filter((r) => !r.is_paid);
  const paid = rows.filter((r) => r.is_paid);
  document.getElementById('statMonthLeft').textContent = formatMoney(unpaid.reduce((s, r) => s + (Number(r.expected_amount) || 0), 0));
  document.getElementById('statMonthLeftCount').textContent = `${unpaid.length} bill${unpaid.length === 1 ? '' : 's'} left`;
  document.getElementById('statMonthPaid').textContent = formatMoney(paid.reduce((s, r) => s + (Number(r.paid_amount) || 0), 0));
  document.getElementById('statMonthPaidCount').textContent = `${paid.length} of ${rows.length} paid`;
}

// ---------------------------------------------------------------------------
// Monthly schedule

async function loadSchedule() {
  const tbody = document.getElementById('scheduleTableBody');
  const tfoot = document.getElementById('scheduleTableFoot');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';
  tfoot.innerHTML = '';

  const { from, to } = monthRange(scheduleMonth);
  const { data, error } = await rpc('admin_list_business_bill_schedule', { p_from: from, p_to: to });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">Nothing due this month.</td></tr>';
    return;
  }

  const today = todayManila();
  tbody.innerHTML = rows.map((r) => {
    let badge;
    if (r.is_paid) badge = `<span class="badge badge-success">Paid ${formatDate(r.paid_date)}</span>`;
    else if (r.due_date < today) badge = '<span class="badge badge-danger">Overdue</span>';
    else badge = '<span class="badge badge-neutral">Unpaid</span>';

    return `
      <tr>
        <td>${formatDate(r.due_date)}</td>
        <td>${escapeHtml(r.name)}</td>
        <td>${escapeHtml(r.category || '')}</td>
        <td>${escapeHtml(r.warehouse || 'Company-wide')}</td>
        <td style="text-align:right;">${formatMoney(r.expected_amount)}</td>
        <td style="text-align:right;">${r.is_paid ? formatMoney(r.paid_amount) : '-'}</td>
        <td>${badge}</td>
        <td>${r.is_paid ? '' : `<button class="btn btn-success btn-sm" data-pay-bill="${r.bill_id}" data-pay-due="${r.due_date}" type="button">Pay</button>`}</td>
      </tr>
    `;
  }).join('');

  const totalExpected = rows.reduce((s, r) => s + (Number(r.expected_amount) || 0), 0);
  const totalPaid = rows.reduce((s, r) => s + (Number(r.paid_amount) || 0), 0);
  tfoot.innerHTML = `
    <tr>
      <td colspan="4" style="text-align:right;"><strong>Total</strong></td>
      <td style="text-align:right;"><strong>${formatMoney(totalExpected)}</strong></td>
      <td style="text-align:right;"><strong>${formatMoney(totalPaid)}</strong></td>
      <td colspan="2"></td>
    </tr>
  `;
}

// ---------------------------------------------------------------------------
// Payment history

async function loadPayments() {
  const tbody = document.getElementById('paymentTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const bill = paymentFilterBillId ? currentBills.find((b) => b.bill_id === paymentFilterBillId) : null;
  document.getElementById('paymentsTitle').textContent = bill ? `Payments - ${bill.name}` : 'Recent Payments';
  document.getElementById('clearPaymentFilterBtn').classList.toggle('hidden', !paymentFilterBillId);

  const { data, error } = await rpc('admin_list_business_bill_payments', {
    p_bill_id: paymentFilterBillId,
    p_limit: 200
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No payments recorded yet.</td></tr>';
    return;
  }

  tbody.innerHTML = rows.map((p) => `
    <tr${p.is_void ? ' style="opacity:0.55;"' : ''}>
      <td>${formatDate(p.paid_date)}</td>
      <td>${escapeHtml(p.bill_name)}</td>
      <td>${formatDate(p.due_date)}</td>
      <td style="text-align:right;">${p.is_void ? `<s>${formatMoney(p.amount)}</s>` : formatMoney(p.amount)}</td>
      <td>${escapeHtml(p.method || '')}</td>
      <td>${escapeHtml(p.reference_no || '')}${p.notes ? `<div class="muted" style="font-size:12px;">${escapeHtml(p.notes)}</div>` : ''}</td>
      <td>${p.expense_receipt_no ? escapeHtml(p.expense_receipt_no) : '<span class="muted">-</span>'}</td>
      <td>${escapeHtml(p.created_by || '')}</td>
      <td>${p.is_void ? '<span class="badge badge-neutral">Void</span>' : `<button class="btn btn-danger btn-sm" data-void-payment="${p.payment_id}" type="button">Void</button>`}</td>
    </tr>
  `).join('');
}

async function voidPayment(paymentId) {
  if (!window.confirm('Void this payment? The due date goes back to unpaid, and its Expense Journal entry (if any) is deleted.')) return;
  const { error } = await rpc('admin_void_business_bill_payment', { p_payment_id: paymentId });
  if (error) {
    window.alert(error.message);
    return;
  }
  await refreshAll();
}

// ---------------------------------------------------------------------------
// Bill modal

function openBillModal(bill) {
  editingBillId = bill ? bill.bill_id : null;
  document.getElementById('billModalTitle').textContent = bill ? `Edit - ${bill.name}` : 'New Bill';
  document.getElementById('billName').value = bill?.name || '';
  document.getElementById('billCategory').value = bill?.category || '';
  document.getElementById('billPayee').value = bill?.payee || '';
  document.getElementById('billAccountNo').value = bill?.account_no || '';
  document.getElementById('billWarehouse').value = bill?.warehouse || '';
  document.getElementById('billFrequency').value = bill?.frequency || 'Monthly';
  document.getElementById('billFirstDueDate').value = bill?.first_due_date || '';
  document.getElementById('billExpectedAmount').value = bill?.expected_amount ?? '';
  document.getElementById('billRemindDays').value = bill?.remind_days_before ?? 7;
  document.getElementById('billExpenseCategory').value = bill?.expense_category || '';
  document.getElementById('billNotes').value = bill?.notes || '';
  document.getElementById('billActive').checked = bill ? !!bill.is_active : true;
  document.getElementById('billError').classList.add('hidden');
  document.getElementById('billModal').classList.remove('hidden');
  document.getElementById('billName').focus();
}

async function saveBill() {
  const errorEl = document.getElementById('billError');
  errorEl.classList.add('hidden');

  const name = document.getElementById('billName').value.trim();
  const firstDue = document.getElementById('billFirstDueDate').value;
  const amountRaw = document.getElementById('billExpectedAmount').value;
  if (!name || !firstDue) {
    errorEl.textContent = 'Bill Name and First Due Date are required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('saveBillBtn');
  btn.disabled = true;
  const { error } = await rpc('admin_save_business_bill', {
    p_bill_id: editingBillId,
    p_name: name,
    p_category: document.getElementById('billCategory').value.trim() || null,
    p_payee: document.getElementById('billPayee').value.trim() || null,
    p_account_no: document.getElementById('billAccountNo').value.trim() || null,
    p_warehouse: document.getElementById('billWarehouse').value || null,
    p_frequency: document.getElementById('billFrequency').value,
    p_first_due_date: firstDue,
    p_expected_amount: amountRaw === '' ? null : Number(amountRaw),
    p_remind_days_before: Number(document.getElementById('billRemindDays').value) || 0,
    p_expense_category: document.getElementById('billExpenseCategory').value.trim() || null,
    p_notes: document.getElementById('billNotes').value.trim() || null,
    p_is_active: document.getElementById('billActive').checked
  });
  btn.disabled = false;

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('billModal').classList.add('hidden');
  await refreshAll();
}

// ---------------------------------------------------------------------------
// Pay modal

function openPayModal(billId, dueDate) {
  const bill = currentBills.find((b) => b.bill_id === billId);
  if (!bill) return;
  payingBill = bill;

  document.getElementById('payModalTitle').textContent = `Pay - ${bill.name}`;
  document.getElementById('payDueDate').value = dueDate || bill.next_due_date || todayManila();
  document.getElementById('payPaidDate').value = todayManila();
  document.getElementById('payAmount').value = bill.expected_amount ?? '';
  document.getElementById('payMethod').value = '';
  document.getElementById('payReference').value = '';
  document.getElementById('payNotes').value = '';
  document.getElementById('payLogExpense').checked = !!bill.expense_category;
  document.getElementById('payExpenseCategory').value = bill.expense_category || '';
  syncExpenseCategoryRow();
  document.getElementById('payError').classList.add('hidden');
  document.getElementById('payModal').classList.remove('hidden');
  document.getElementById('payAmount').focus();
}

function syncExpenseCategoryRow() {
  document.getElementById('payExpenseCategoryRow').classList.toggle('hidden', !document.getElementById('payLogExpense').checked);
}

async function savePayment() {
  const errorEl = document.getElementById('payError');
  errorEl.classList.add('hidden');

  const amount = Number(document.getElementById('payAmount').value);
  const dueDate = document.getElementById('payDueDate').value;
  const logExpense = document.getElementById('payLogExpense').checked;
  const expenseCategory = document.getElementById('payExpenseCategory').value.trim();

  if (!dueDate || !(amount > 0)) {
    errorEl.textContent = 'Due Date and an Amount greater than zero are required.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (logExpense && !expenseCategory) {
    errorEl.textContent = 'Pick an Expense Category, or untick "Also log to Expense Journal".';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('savePayBtn');
  btn.disabled = true;
  const { error } = await rpc('admin_pay_business_bill', {
    p_bill_id: payingBill.bill_id,
    p_due_date: dueDate,
    p_paid_date: document.getElementById('payPaidDate').value || null,
    p_amount: amount,
    p_method: document.getElementById('payMethod').value.trim() || null,
    p_reference_no: document.getElementById('payReference').value.trim() || null,
    p_notes: document.getElementById('payNotes').value.trim() || null,
    p_expense_category: logExpense ? expenseCategory : null
  });
  btn.disabled = false;

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('payModal').classList.add('hidden');
  await refreshAll();
}

// ---------------------------------------------------------------------------
// Lookups (branches, expense categories, payment methods)

async function loadLookups() {
  const [wh, cats, methods] = await Promise.all([
    rpc('admin_list_warehouses', { p_page: 1, p_page_size: 200 }),
    rpc('admin_list_expense_journal_categories', {}),
    rpc('admin_list_payment_methods', {})
  ]);

  const names = (wh.data || []).filter((w) => w.is_active !== false).map((w) => w.name).filter(Boolean);
  document.getElementById('billWarehouse').innerHTML = '<option value="">Company-wide</option>' +
    names.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');

  document.getElementById('expenseCategoryOptions').innerHTML = (cats.data || [])
    .map((c) => `<option value="${escapeHtml(c.category)}"></option>`).join('');

  const methodNames = (methods.data || [])
    .filter((m) => m.is_active !== false)
    .map((m) => m.name || m.pancake_name)
    .filter(Boolean);
  document.getElementById('payMethodOptions').innerHTML = [...new Set(['Cash', 'Bank Transfer', 'GCash', 'Check', ...methodNames])]
    .map((n) => `<option value="${escapeHtml(n)}"></option>`).join('');
}

async function refreshAll() {
  await loadBills();
  await Promise.all([loadMonthStats(), loadSchedule(), loadPayments()]);
}

// ---------------------------------------------------------------------------

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Bills & Dues');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Bills & Dues.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('billsContent').classList.remove('hidden');

  scheduleMonth = todayManila().slice(0, 7);
  const monthInput = document.getElementById('scheduleMonthInput');
  monthInput.value = scheduleMonth;
  monthInput.addEventListener('change', () => {
    if (!monthInput.value) return;
    scheduleMonth = monthInput.value;
    loadSchedule();
  });
  document.getElementById('prevMonthBtn').addEventListener('click', () => {
    scheduleMonth = shiftMonth(scheduleMonth, -1);
    monthInput.value = scheduleMonth;
    loadSchedule();
  });
  document.getElementById('nextMonthBtn').addEventListener('click', () => {
    scheduleMonth = shiftMonth(scheduleMonth, 1);
    monthInput.value = scheduleMonth;
    loadSchedule();
  });

  document.getElementById('showInactiveInput').addEventListener('change', loadBills);
  document.getElementById('newBillBtn').addEventListener('click', () => openBillModal(null));
  document.getElementById('closeBillModalBtn').addEventListener('click', () =>
    document.getElementById('billModal').classList.add('hidden'));
  document.getElementById('saveBillBtn').addEventListener('click', saveBill);

  document.getElementById('closePayModalBtn').addEventListener('click', () =>
    document.getElementById('payModal').classList.add('hidden'));
  document.getElementById('savePayBtn').addEventListener('click', savePayment);
  document.getElementById('payLogExpense').addEventListener('change', syncExpenseCategoryRow);

  document.getElementById('clearPaymentFilterBtn').addEventListener('click', () => {
    paymentFilterBillId = null;
    loadPayments();
  });

  // Pay buttons live in both the bill list and the schedule; one delegated handler for the page.
  document.getElementById('billsContent').addEventListener('click', (e) => {
    const payBtn = e.target.closest('[data-pay-bill]');
    if (payBtn) return openPayModal(payBtn.dataset.payBill, payBtn.dataset.payDue || null);

    const editBtn = e.target.closest('[data-edit-bill]');
    if (editBtn) return openBillModal(currentBills.find((b) => b.bill_id === editBtn.dataset.editBill));

    const historyBtn = e.target.closest('[data-history-bill]');
    if (historyBtn) {
      paymentFilterBillId = historyBtn.dataset.historyBill;
      loadPayments().then(() =>
        document.getElementById('paymentsTitle').scrollIntoView({ behavior: 'smooth', block: 'start' }));
      return;
    }

    const voidBtn = e.target.closest('[data-void-payment]');
    if (voidBtn) voidPayment(voidBtn.dataset.voidPayment);
  });

  await loadLookups();
  await refreshAll();
})();
