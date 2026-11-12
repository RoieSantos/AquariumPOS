// Payout receipt for one salary / cash advance payout sent through Xendit (payout-receipt.html?id=<PayoutID>).
// my_get_payout_receipt (sql/supabase_xendit_payout_receipts.sql) checks the viewer server-side: the employee
// gets their own live payouts only, payroll officers / super users get any. Opening your own paid receipt also
// clears its portal notice (js/nav.js mountPayoutNotice).

function prEscape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function prPeso(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function prDate(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('en-PH', { year: 'numeric', month: 'short', day: 'numeric' });
}

// Always Philippine time, so it reads the same as the GCash / bank app's "Date & Time".
function prDateTime(ts) {
  if (!ts) return '';
  return new Date(ts).toLocaleString('en-PH', {
    timeZone: 'Asia/Manila', year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
  });
}

function prCycle(cycle) {
  return cycle === 'SemiMonthly' ? 'Semi-Monthly' : cycle || '';
}

function showReceiptError(message) {
  const el = document.getElementById('receiptError');
  el.textContent = message;
  el.classList.remove('hidden');
}

function renderReceipt(r) {
  const isSalary = r.kind === 'Salary';
  const paid = r.status === 'SUCCEEDED';
  document.getElementById('printTitle').textContent = isSalary ? 'Salary Payout Receipt' : 'Cash Advance Payout Receipt';

  const banners = [];
  if (r.is_test) banners.push('<div class="pr-test">TEST payout - no real money was sent.</div>');
  if (!paid) {
    const label = ['Creating', 'ACCEPTED', 'REQUESTED'].includes(r.status) ? 'still being sent - not confirmed by Xendit yet'
      : `not paid (${String(r.status || '').toLowerCase()}${r.failure ? ': ' + r.failure : ''})`;
    banners.push(`<div class="pr-unpaid">This payout is ${prEscape(label)}.</div>`);
  }
  document.getElementById('receiptBanner').innerHTML = banners.join('');

  document.getElementById('receiptAmount').textContent = prPeso(r.amount);
  document.getElementById('receiptAmountLabel').textContent = paid ? `Paid ${prDateTime(r.paid_at)}` : 'Amount';

  const forText = isSalary
    ? `Salary - ${prCycle(r.pay_cycle)} ${prDate(r.period_start)} to ${prDate(r.period_end)}${r.pay_date ? ` (pay date ${prDate(r.pay_date)})` : ''}`
    : `Cash advance of ${prDate(r.advance_date) || prDate((r.sent_at || '').slice(0, 10))}${r.advance_notes ? ` - ${r.advance_notes}` : ''}`;

  const rows = [
    ['Employee', r.display_name || r.username],
    ['For', forText],
    ['Paid to', `${r.channel_name || ''} ${r.account_masked || ''}`.trim()],
    ['Account name', r.account_name],
    ['Sent by', `${r.sent_by || ''}${r.sent_at ? ', ' + prDateTime(r.sent_at) : ''}`]
  ];
  if (!isSalary) rows.push(['Note', 'Deducted from your next payroll run.']);
  document.getElementById('receiptGrid').innerHTML = rows
    .map(([k, v]) => `<dt>${prEscape(k)}</dt><dd>${prEscape(v)}</dd>`).join('');

  // GCash / the bank never gets our reference or Xendit's ID - it prints its own Ref No. (checked on a real GCash
  // payout: "Received GCash from Union Bank of the Philippines", same amount, same minute - but Xendit doesn't
  // promise that partner bank, so it's only an example; amount + time is the real match). So tell the employee
  // what to look for, and keep our two numbers as the ones to quote to RS Pet Stop / Xendit support.
  document.getElementById('receiptMatch').innerHTML = paid ? `
    <h3 style="margin:18px 0 6px;font-size:15px;">How to find it in ${prEscape(r.channel_name || 'your account')}</h3>
    <p style="margin:0 0 6px;">Look for money received with this amount and time. It comes through Xendit's partner
      bank, so the sender may show as a bank (e.g. <strong>Union Bank of the Philippines</strong>), not RS Pet Stop.</p>
    <dl class="pr-grid" style="margin-top:4px;">
      <dt>Amount</dt><dd>${prEscape(prPeso(r.amount))}</dd>
      <dt>Date &amp; time</dt><dd>${prEscape(prDateTime(r.paid_at))} <span class="muted" style="font-weight:400;">(give or take a few minutes)</span></dd>
    </dl>
    <p class="muted" style="margin:6px 0 0;font-size:12px;">${prEscape(r.channel_name || 'GCash')} shows its own Reference Number - it
      won't match the numbers below.</p>` : '';

  document.getElementById('receiptRefs').innerHTML = `
    <h3 style="margin:18px 0 6px;font-size:15px;">For RS Pet Stop / Xendit support</h3>
    <dl class="pr-grid" style="margin-top:4px;">
      ${r.payout_description ? `<dt>Description sent</dt><dd>${prEscape(r.payout_description)}</dd>` : ''}
      <dt>Reference no.</dt><dd>${prEscape(r.reference_id)}</dd>
      <dt>Xendit payout ID</dt><dd>${prEscape(r.xendit_payout_id || '-')}</dd>
    </dl>`;

  if (isSalary && r.is_mine && r.line_id) {
    const footnote = document.querySelector('.pr-footnote');
    const link = document.createElement('a');
    link.href = `my-payslip-print.html?line=${encodeURIComponent(r.line_id)}`;
    link.className = 'no-print';
    link.textContent = 'View the payslip for this pay';
    footnote.append(' ', link);
  }

  document.getElementById('printContent').classList.remove('hidden');
  document.getElementById('printBtn').classList.toggle('hidden', !paid && !r.is_test);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('My Payslips');

  // A payroll officer opening this from Payroll Run / Timesheets came from there - Back goes there.
  if (document.referrer && /payroll-(run|timesheets)\.html/.test(document.referrer)) {
    const back = document.getElementById('backBtn');
    back.href = document.referrer;
    back.textContent = 'Back';
  }
  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const payoutId = new URLSearchParams(window.location.search).get('id');
  if (!payoutId) {
    showReceiptError('No receipt specified.');
    return;
  }

  const [, result] = await Promise.all([
    renderCompanyLetterhead('companyLetterhead').catch(() => null),
    supabaseClient.rpc('my_get_payout_receipt', {
      p_username: session.username,
      p_password: session.password,
      p_payout_id: payoutId
    })
  ]);

  const { data, error } = result;
  const receipt = Array.isArray(data) ? data[0] : data;
  if (error || !receipt) {
    showReceiptError(error?.message || 'Receipt not found.');
    return;
  }

  // The notice banner is cached per tab - opening the receipt cleared it server-side, so drop the cache.
  try { sessionStorage.removeItem('payoutNoticeCache'); } catch (e) { /* storage blocked */ }
  renderReceipt(receipt);
})();
