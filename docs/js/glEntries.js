// General Ledger page - the ledger view plus a trial balance, and the manual "Post Expenses to
// G/L" run. See supabase_general_ledger.sql for the posting model and
// supabase_gl_posting_integration.sql for which documents post here.
//
// Read-only apart from the expense posting button: purchases, bills and payments reach the ledger
// as a side effect of posting those documents, never by being keyed in here.
let currentSession = null;
let currentPage = 1;
let currentPageSize = 50;
let searchDebounceHandle = null;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatAmount(value) {
  const n = Number(value || 0);
  // A zero debit on a credit line (and vice versa) is noise on a ledger - blank reads far better
  // than a column of 0.00 down one side of every transaction.
  return n === 0 ? '' : n.toFixed(2);
}

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleDateString();
}

function filterValues() {
  return {
    from: document.getElementById('glFromDate').value || null,
    to: document.getElementById('glToDate').value || null,
    accountNo: document.getElementById('glAccountFilter').value || null,
    search: document.getElementById('glSearchInput').value.trim() || null
  };
}

async function loadAccountFilter() {
  const { data, error } = await supabaseClient.rpc('admin_list_gl_accounts', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_include_inactive: false
  });

  if (error) {
    console.error('admin_list_gl_accounts failed:', error);
    return;
  }

  const select = document.getElementById('glAccountFilter');
  select.innerHTML = '<option value="">All accounts</option>' + (data || [])
    .map((a) => `<option value="${escapeHtml(a.account_no)}">${escapeHtml(a.account_no)} - ${escapeHtml(a.name)}</option>`)
    .join('');
}

async function loadEntries() {
  const body = document.getElementById('glTableBody');
  body.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';

  const f = filterValues();
  const { data, error } = await supabaseClient.rpc('admin_list_gl_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_from_date: f.from,
    p_to_date: f.to,
    p_account_no: f.accountNo,
    p_search: f.search,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    body.innerHTML = `<tr><td colspan="8" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="8" class="muted">No ledger entries for this filter.</td></tr>';
    document.getElementById('glTotalDebit').textContent = '0.00';
    document.getElementById('glTotalCredit').textContent = '0.00';
    renderPaginationBar(document.getElementById('glPaginationBar'), { page: currentPage, pageSize: currentPageSize, totalCount: 0 }, {});
    return;
  }

  body.innerHTML = rows.map((r) => `
    <tr>
      <td>${formatDate(r.posting_date)}</td>
      <td title="${escapeHtml(r.account_name || '')}">${escapeHtml(r.account_no)} - ${escapeHtml(r.account_name || '')}</td>
      <td class="doc-cell-text" title="${escapeHtml(r.description || '')}">${escapeHtml(r.description || '')}</td>
      <td>${escapeHtml(r.document_type || '')} ${escapeHtml(r.document_no || '')}</td>
      <td>${escapeHtml(r.source_no || '')}</td>
      <td class="doc-num">${formatAmount(r.debit_amount)}</td>
      <td class="doc-num">${formatAmount(r.credit_amount)}</td>
      <td>${escapeHtml(r.posted_by || '')}</td>
    </tr>
  `).join('');

  // These come from the RPC as window totals over the entire filtered set, not just this page, so
  // the figures describe the filter rather than the pagination.
  document.getElementById('glTotalDebit').textContent = Number(rows[0].total_debit || 0).toFixed(2);
  document.getElementById('glTotalCredit').textContent = Number(rows[0].total_credit || 0).toFixed(2);

  renderPaginationBar(
    document.getElementById('glPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: rows[0].total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadEntries(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadEntries(); }
    }
  );
}

async function loadTrialBalance() {
  const body = document.getElementById('trialBalanceBody');
  const f = filterValues();

  const { data, error } = await supabaseClient.rpc('admin_get_gl_trial_balance', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_from_date: f.from,
    p_to_date: f.to
  });

  if (error) {
    body.innerHTML = `<tr><td colspan="6" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="6" class="muted">Nothing posted in this range.</td></tr>';
    document.getElementById('tbTotalDebit').textContent = '0.00';
    document.getElementById('tbTotalCredit').textContent = '0.00';
    document.getElementById('tbBalanceCheck').textContent = '';
    return;
  }

  body.innerHTML = rows.map((r) => `
    <tr>
      <td>${escapeHtml(r.account_no)}</td>
      <td>${escapeHtml(r.name)}</td>
      <td>${escapeHtml(r.account_type)}</td>
      <td class="doc-num">${Number(r.debit_total || 0).toFixed(2)}</td>
      <td class="doc-num">${Number(r.credit_total || 0).toFixed(2)}</td>
      <td class="doc-num">${Number(r.balance || 0).toFixed(2)}</td>
    </tr>
  `).join('');

  const totalDebit = rows.reduce((s, r) => s + Number(r.debit_total || 0), 0);
  const totalCredit = rows.reduce((s, r) => s + Number(r.credit_total || 0), 0);
  document.getElementById('tbTotalDebit').textContent = totalDebit.toFixed(2);
  document.getElementById('tbTotalCredit').textContent = totalCredit.toFixed(2);

  // The whole point of double entry: if these ever differ the books are broken, and that must be
  // shouted about rather than left for someone to spot by comparing two columns.
  const check = document.getElementById('tbBalanceCheck');
  const difference = Math.round((totalDebit - totalCredit) * 100) / 100;
  if (difference === 0) {
    check.textContent = 'Balanced';
    check.style.color = '';
  } else {
    check.textContent = `OUT BY ${difference.toFixed(2)}`;
    check.style.color = 'var(--danger)';
  }
}

async function postExpensesToGl() {
  const f = filterValues();
  if (!f.from || !f.to) {
    window.alert('Set both a From and a To date first - that range is what gets posted.');
    return;
  }

  if (!window.confirm(
    `Post all unposted expenses dated ${f.from} to ${f.to} into the General Ledger?\n\n` +
    'Ledger entries are permanent - correcting one afterwards means posting a reversing entry. ' +
    'Expenses already posted are skipped.'
  )) return;

  const btn = document.getElementById('postExpensesBtn');
  const original = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Posting...';

  const { data, error } = await supabaseClient.rpc('admin_post_expenses_to_gl', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_from_date: f.from,
    p_to_date: f.to
  });

  btn.disabled = false;
  btn.textContent = original;

  if (error) {
    window.alert('Posting failed: ' + error.message);
    return;
  }

  const result = Array.isArray(data) ? data[0] : data;
  const skippedNote = result?.messages?.length ? `\n\nSkipped:\n${result.messages.join('\n')}` : '';
  window.alert(
    `Posted: ${result?.posted_count ?? 0}\n` +
    `Skipped (already posted or zero amount): ${result?.skipped_count ?? 0}\n` +
    `Total posted: ${Number(result?.total_amount || 0).toFixed(2)}${skippedNote}`
  );

  await refreshAll();
}

async function refreshAll() {
  await Promise.all([loadEntries(), loadTrialBalance()]);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('General Ledger');

  // Default to the current month, which is what anyone opening a ledger almost always wants, and
  // it also gives the expense posting run a sensible pre-filled range.
  const today = new Date();
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
  document.getElementById('glFromDate').value = monthStart.toISOString().slice(0, 10);
  document.getElementById('glToDate').value = today.toISOString().slice(0, 10);

  document.getElementById('glRefreshBtn').addEventListener('click', () => {
    currentPage = 1;
    refreshAll();
  });

  document.getElementById('glAccountFilter').addEventListener('change', () => {
    currentPage = 1;
    loadEntries();
  });

  document.getElementById('glSearchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => {
      currentPage = 1;
      loadEntries();
    }, 300);
  });

  document.getElementById('postExpensesBtn').addEventListener('click', postExpensesToGl);

  await loadAccountFilter();
  await refreshAll();
})();
