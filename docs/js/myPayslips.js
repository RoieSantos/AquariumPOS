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

// Xendit payout receipts (my_list_payout_receipts, sql/supabase_xendit_payout_receipts.sql) - a Receipt button on
// each salary paid via Xendit, plus the cash advances sent via Xendit in their own list. Empty if that SQL isn't run.
function receiptButton(payoutId) {
  return `<a class="btn btn-secondary btn-sm" href="payout-receipt.html?id=${encodeURIComponent(payoutId)}">Receipt</a>`;
}

function renderAdvanceReceipts(receipts) {
  const advances = receipts.filter((p) => p.kind === 'Advance');
  document.getElementById('advanceReceiptsSection').classList.toggle('hidden', advances.length === 0);
  document.getElementById('advanceReceiptsBody').innerHTML = advances.map((p) => `
    <tr>
      <td>${formatDate(p.advance_date)}</td>
      <td>${p.paid_at ? new Date(p.paid_at).toLocaleDateString() : '-'}</td>
      <td>${p.channel_name || ''} ${p.account_masked || ''}</td>
      <td style="text-align:right;"><strong>${formatCurrency(p.amount)}</strong></td>
      <td>${receiptButton(p.payout_id)}</td>
    </tr>
  `).join('');
}

function renderRows(rows, receipts) {
  const tbody = document.getElementById('payslipTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No finalized payslips yet.</td></tr>';
    return;
  }

  const salaryReceipt = new Map((receipts || []).filter((p) => p.kind === 'Salary' && p.line_id).map((p) => [p.line_id, p.payout_id]));
  tbody.innerHTML = rows.map((r) => `
    <tr>
      <td>${formatCycleLabel(r.pay_cycle)}</td>
      <td>${formatDate(r.period_start)} - ${formatDate(r.period_end)}</td>
      <td>${formatDate(r.pay_date)}</td>
      <td style="text-align:right;">${formatCurrency(r.base_pay)}</td>
      <td style="text-align:right;">${formatCurrency(r.additions_total)}</td>
      <td style="text-align:right;">${formatCurrency(r.deductions_total)}</td>
      <td style="text-align:right;"><strong>${formatCurrency(r.net_pay)}</strong></td>
      <td style="white-space:nowrap;"><a class="btn btn-secondary btn-sm" href="my-payslip-print.html?line=${r.line_id}">View / Print</a>${salaryReceipt.has(r.line_id) ? ' ' + receiptButton(salaryReceipt.get(r.line_id)) : ''}</td>
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

  // Receipts load alongside; a failure there (e.g. SQL not run yet) just means no Receipt buttons.
  const receiptsPromise = supabaseClient.rpc('my_list_payout_receipts', {
    p_username: currentSession.username,
    p_password: currentSession.password,
    p_unseen_only: false
  }).then(({ data: rows, error: err }) => (err ? [] : rows || [])).catch(() => []);

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

  const receipts = await receiptsPromise;
  renderRows(data || [], receipts);
  renderAdvanceReceipts(receipts);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('My Payslips');
  await loadPayslips();
})();
