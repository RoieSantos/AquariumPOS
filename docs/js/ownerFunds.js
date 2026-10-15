// Owner Funds page (super users only) - money moving between the owner and the business, per "how
// can I input my income funds to the business.. e.g. I used my own funds to pay for a bill how can
// we track it?". See sql/supabase_owner_funds.sql. Capital In / Owner Loan / Loan Repayment /
// Drawing, each posted to the G/L; "Paid Directly" = the owner paid a business expense personally,
// which also logs the Expense Journal entry. Bills & Dues "Paid by: Owner" lands here too.
let currentSession = null;
let currentEntries = [];

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

function todayManila() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Manila' }).format(new Date());
}

async function rpc(name, params) {
  return supabaseClient.rpc(name, {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    ...params
  });
}

const TYPE_BADGE = {
  'Capital In': 'badge-success',
  'Owner Loan': 'badge-primary',
  'Loan Repayment': 'badge-warning',
  'Drawing': 'badge-danger'
};

// Money in (Capital In / Owner Loan) adds to the owner's side; Loan Repayment / Drawing take away.
function signedAmount(e) {
  return e.entry_type === 'Capital In' || e.entry_type === 'Owner Loan' ? Number(e.amount) : -Number(e.amount);
}

// ---------------------------------------------------------------------------

async function loadSummary() {
  const { data, error } = await rpc('admin_get_owner_funds_summary', {});
  if (error) {
    document.getElementById('statCapitalNote').textContent = error.message;
    return;
  }
  const s = (Array.isArray(data) ? data[0] : data) || {};
  document.getElementById('statCapital').textContent = formatMoney(s.capital_in || 0);
  document.getElementById('statCapitalNote').textContent = Number(s.paid_directly) > 0
    ? `incl. ${formatMoney(s.paid_directly)} of bills / expenses you paid directly` : '';
  document.getElementById('statDrawings').textContent = formatMoney(s.drawings || 0);
  document.getElementById('statNet').textContent = formatMoney(s.net_invested || 0);
  document.getElementById('statLoan').textContent = formatMoney(s.loan_outstanding || 0);
  document.getElementById('statLoanNote').textContent =
    `Lent ${formatMoney(s.loans_in || 0)} · repaid ${formatMoney(s.loans_repaid || 0)}`;
}

async function loadEntries() {
  const tbody = document.getElementById('entryTableBody');
  tbody.innerHTML = '<tr><td colspan="10" class="muted">Loading...</td></tr>';

  const { data, error } = await rpc('admin_list_owner_fund_entries', { p_limit: 500 });
  if (error) {
    tbody.innerHTML = `<tr><td colspan="10" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  currentEntries = data || [];
  const showVoid = document.getElementById('showVoidInput').checked;
  const rows = currentEntries.filter((e) => showVoid || !e.is_void);
  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="10" class="muted">No entries yet - click "+ New Entry" when you put money in or take it out.</td></tr>';
    return;
  }

  tbody.innerHTML = rows.map((e) => {
    const amt = signedAmount(e);
    const amtText = `${amt < 0 ? '−' : '+'}${formatMoney(Math.abs(amt))}`;
    const desc = [e.description, e.bill_name ? `Bill: ${e.bill_name}` : ''].filter(Boolean).join(' · ');
    const action = e.is_void
      ? '<span class="badge badge-neutral">Void</span>'
      : e.bill_name
        ? '<span class="muted" style="font-size:12px;">Void on Bills &amp; Dues</span>'
        : `<button class="btn btn-danger btn-sm" data-void-entry="${e.entry_id}" type="button">Void</button>`;
    return `
      <tr${e.is_void ? ' style="opacity:0.55;"' : ''}>
        <td>${formatDate(e.entry_date)}</td>
        <td>${escapeHtml(e.entry_no)}</td>
        <td><span class="badge ${TYPE_BADGE[e.entry_type] || 'badge-neutral'}">${escapeHtml(e.entry_type)}</span></td>
        <td>${escapeHtml(e.method)}</td>
        <td>${escapeHtml(desc)}</td>
        <td>${escapeHtml(e.warehouse || '')}</td>
        <td style="text-align:right; white-space:nowrap;">${e.is_void ? `<s>${amtText}</s>` : amtText}</td>
        <td>${e.expense_receipt_no ? `${escapeHtml(e.expense_receipt_no)}<div class="muted" style="font-size:12px;">${escapeHtml(e.expense_category || '')}</div>` : '<span class="muted">-</span>'}</td>
        <td>${escapeHtml(e.created_by || '')}</td>
        <td>${action}</td>
      </tr>`;
  }).join('');
}

async function voidEntry(entryId) {
  if (!window.confirm('Void this entry? A reversing G/L entry is posted, and if it was an expense you paid directly, that Expense Journal entry is deleted.')) return;
  const { error } = await rpc('admin_void_owner_fund_entry', { p_entry_id: entryId });
  if (error) {
    window.alert(error.message);
    return;
  }
  await refreshAll();
}

// ---------------------------------------------------------------------------
// New entry modal

// Paid Directly only makes sense for money coming in (owner paid an expense for the business).
function syncEntryForm() {
  const type = document.getElementById('entryType').value;
  const methodSel = document.getElementById('entryMethod');
  const prev = methodSel.value;
  const moneyIn = type === 'Capital In' || type === 'Owner Loan';
  const methods = moneyIn
    ? [['Cash', 'Cash - into the business cash'], ['Digital', 'Digital - into the business bank / GCash'], ['Paid Directly', 'Paid Directly - I paid a business expense myself']]
    : [['Cash', 'Cash - from the business cash'], ['Digital', 'Digital - from the business bank / GCash']];
  methodSel.innerHTML = methods.map(([v, l]) => `<option value="${v}">${escapeHtml(l)}</option>`).join('');
  if (methods.some(([v]) => v === prev)) methodSel.value = prev;

  const direct = methodSel.value === 'Paid Directly';
  document.getElementById('entryExpenseCategoryRow').classList.toggle('hidden', !direct);

  const hints = {
    'Capital In': 'Your own money invested in the business for good. Posts Dr Cash/Digital, Cr Owner\'s Equity.',
    'Owner Loan': 'Your own money the business will pay back. Posts Dr Cash/Digital, Cr Due to Owner.',
    'Loan Repayment': 'The business paying back your loan. Posts Dr Due to Owner, Cr Cash/Digital.',
    'Drawing': 'Money you take out for personal use - not an expense or salary. Posts Dr Owner\'s Drawings, Cr Cash/Digital.'
  };
  document.getElementById('entryHint').textContent = direct
    ? 'You paid a business expense from your own pocket: it is logged in the Expense Journal too, and posts Dr <expense>, Cr ' +
      (type === 'Owner Loan' ? 'Due to Owner.' : 'Owner\'s Equity.') + ' Business cash is not touched.'
    : hints[type];
}

function openEntryModal() {
  document.getElementById('entryType').value = 'Capital In';
  document.getElementById('entryMethod').innerHTML = '';
  syncEntryForm();
  document.getElementById('entryDate').value = todayManila();
  document.getElementById('entryAmount').value = '';
  document.getElementById('entryWarehouse').value = '';
  document.getElementById('entryExpenseCategory').value = '';
  document.getElementById('entryDescription').value = '';
  document.getElementById('entryError').classList.add('hidden');
  document.getElementById('entryModal').classList.remove('hidden');
  document.getElementById('entryAmount').focus();
}

async function saveEntry() {
  const errorEl = document.getElementById('entryError');
  errorEl.classList.add('hidden');

  const method = document.getElementById('entryMethod').value;
  const amount = Number(document.getElementById('entryAmount').value);
  const category = document.getElementById('entryExpenseCategory').value.trim();
  if (!(amount > 0)) {
    errorEl.textContent = 'Enter an amount greater than zero.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (method === 'Paid Directly' && !category) {
    errorEl.textContent = 'Pick the Expense Category of what you paid for.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('saveEntryBtn');
  btn.disabled = true;
  const { error } = await rpc('admin_add_owner_fund_entry', {
    p_entry_type: document.getElementById('entryType').value,
    p_entry_date: document.getElementById('entryDate').value || null,
    p_amount: amount,
    p_method: method,
    p_description: document.getElementById('entryDescription').value.trim() || null,
    p_warehouse: document.getElementById('entryWarehouse').value || null,
    p_expense_category: method === 'Paid Directly' ? category : null
  });
  btn.disabled = false;

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('entryModal').classList.add('hidden');
  await refreshAll();
}

async function loadLookups() {
  const [wh, cats] = await Promise.all([
    rpc('admin_list_warehouses', { p_page: 1, p_page_size: 200 }),
    rpc('admin_list_expense_journal_categories', {})
  ]);

  const names = (wh.data || []).filter((w) => w.is_active !== false).map((w) => w.name).filter(Boolean);
  document.getElementById('entryWarehouse').innerHTML = '<option value="">Company-wide</option>' +
    names.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');

  document.getElementById('expenseCategoryOptions').innerHTML = (cats.data || [])
    .map((c) => `<option value="${escapeHtml(c.category)}"></option>`).join('');
}

async function refreshAll() {
  await Promise.all([loadSummary(), loadEntries()]);
}

// ---------------------------------------------------------------------------

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Owner Funds');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Owner Funds.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('ownerContent').classList.remove('hidden');

  document.getElementById('newEntryBtn').addEventListener('click', openEntryModal);
  document.getElementById('closeEntryModalBtn').addEventListener('click', () =>
    document.getElementById('entryModal').classList.add('hidden'));
  document.getElementById('saveEntryBtn').addEventListener('click', saveEntry);
  document.getElementById('entryType').addEventListener('change', syncEntryForm);
  document.getElementById('entryMethod').addEventListener('change', syncEntryForm);
  document.getElementById('showVoidInput').addEventListener('change', loadEntries);

  document.getElementById('entryTableBody').addEventListener('click', (e) => {
    const voidBtn = e.target.closest('[data-void-entry]');
    if (voidBtn) voidEntry(voidBtn.dataset.voidEntry);
  });

  await loadLookups();
  await refreshAll();
})();
