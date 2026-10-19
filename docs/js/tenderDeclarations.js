// Tender Declarations page (super users only, read-only). Data comes from the POS:
// TenderDeclarationForm -> OnlinefunctionsEvents.SyncTenderDeclarationToSupabaseAsync
// (supabase_tender_declaration_tables.sql). Variance = Declared - Expected: negative = Short.
let currentSession = null;
let searchDebounceHandle = null;
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;
let currentRows = [];

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function varianceBadge(variance) {
  const v = Number(variance || 0);
  if (v < 0) return `<span class="badge badge-danger">Short ${formatMoney(-v)}</span>`;
  if (v > 0) return `<span class="badge badge-warning">Over ${formatMoney(v)}</span>`;
  return '<span class="badge badge-success">Balanced</span>';
}

function currentFilters() {
  return {
    p_search: document.getElementById('searchInput').value.trim() || null,
    p_from: document.getElementById('fromInput').value || null,
    p_to: document.getElementById('toInput').value || null,
    p_result: document.getElementById('resultSelect').value || null
  };
}

function renderRows(rows) {
  const tbody = document.getElementById('declTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No tender declarations found.</td></tr>';
    return;
  }

  tbody.innerHTML = rows.map((r, i) => `
    <tr>
      <td>${escapeHtml(r.decl_date)}</td>
      <td>${escapeHtml(r.decl_time)}</td>
      <td>${escapeHtml(r.eod_id)}</td>
      <td>${escapeHtml(r.warehouse)}</td>
      <td>${escapeHtml(r.user_id)}</td>
      <td>${formatMoney(r.expected_cash)}</td>
      <td>${formatMoney(r.declared_cash)}</td>
      <td>${varianceBadge(r.variance)}</td>
      <td><a href="#" data-row="${i}" class="view-link">View</a></td>
    </tr>
  `).join('');

  tbody.querySelectorAll('.view-link').forEach((a) => {
    a.addEventListener('click', (e) => {
      e.preventDefault();
      openDetail(currentRows[Number(a.dataset.row)]);
    });
  });
}

async function loadDeclarations() {
  const tbody = document.getElementById('declTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';
  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_tender_declarations', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    ...currentFilters(),
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return;

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  currentRows = data || [];
  const first = currentRows[0];
  document.getElementById('statCount').textContent = first ? Number(first.total_count).toLocaleString() : '0';
  document.getElementById('statShort').textContent = formatMoney(first ? first.total_short : 0);
  document.getElementById('statOver').textContent = formatMoney(first ? first.total_over : 0);

  renderRows(currentRows);

  renderPaginationBar(
    document.getElementById('declPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: first?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadDeclarations(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadDeclarations(); }
    }
  );
}

async function openDetail(row) {
  if (!row) return;
  document.getElementById('detailTitle').textContent = `Tender Declaration ${row.eod_id}`;
  document.getElementById('detailMeta').innerHTML =
    `${escapeHtml(row.warehouse)} &middot; ${escapeHtml(row.decl_date)} ${escapeHtml(row.decl_time || '')} &middot; Cashier: ${escapeHtml(row.user_id || '-')}` +
    ` &middot; Receipt: ${escapeHtml(row.receipt_no || '-')}` +
    (row.from_history_upload ? ' &middot; <span class="badge badge-neutral" title="Uploaded from the POS history - Short/Over recomputed with the current formula">History upload</span>' : '');

  const summaryRows = [
    ['Float', row.float_amount],
    ['+ Cash Sales', row.cash_sales],
    ['+ Cash Income', row.cash_income],
    ['&minus; Cash Expenses', row.cash_expense],
    ['<strong>= Expected Cash</strong>', row.expected_cash, true],
    ['<strong>Declared Cash</strong>', row.declared_cash, true]
  ];
  document.getElementById('detailSummaryBody').innerHTML =
    summaryRows.map(([label, value, bold]) =>
      `<tr><td>${label}</td><td style="text-align:right;">${bold ? '<strong>' : ''}${formatMoney(value)}${bold ? '</strong>' : ''}</td></tr>`).join('') +
    `<tr><td><strong>Result</strong></td><td style="text-align:right;">${varianceBadge(row.variance)}</td></tr>`;

  const tenders = Object.entries(row.sales_by_tender || {});
  document.getElementById('detailTenderBody').innerHTML = (tenders.length
    ? tenders.map(([tender, amount]) => `<tr><td>${escapeHtml(tender)}</td><td style="text-align:right;">${formatMoney(amount)}</td></tr>`).join('')
    : '<tr><td class="muted">No customer payments.</td></tr>') +
    `<tr><td>Advance order collections (included above)</td><td style="text-align:right;">${formatMoney(row.advance_collections)}</td></tr>`;

  const linesBody = document.getElementById('detailLinesBody');
  linesBody.innerHTML = '<tr><td colspan="3" class="muted">Loading...</td></tr>';
  document.getElementById('detailModal').classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('admin_list_tender_declaration_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse: row.warehouse,
    p_eod_id: row.eod_id
  });

  if (error) {
    linesBody.innerHTML = `<tr><td colspan="3" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  if (!data || data.length === 0) {
    linesBody.innerHTML = '<tr><td colspan="3" class="muted">No denominations recorded.</td></tr>';
    return;
  }
  const total = data.reduce((sum, l) => sum + Number(l.total_amount || 0), 0);
  linesBody.innerHTML = data.map((l) => `
    <tr><td>${formatMoney(l.denomination)}</td><td>${escapeHtml(l.qty)}</td><td>${formatMoney(l.total_amount)}</td></tr>
  `).join('') + `<tr><td colspan="2"><strong>Total</strong></td><td><strong>${formatMoney(total)}</strong></td></tr>`;
}

function closeDetail() {
  document.getElementById('detailModal').classList.add('hidden');
}

function wireFilters() {
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => { currentPage = 1; loadDeclarations(); }, 300);
  });
  ['fromInput', 'toInput', 'resultSelect'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => { currentPage = 1; loadDeclarations(); });
  });
  document.getElementById('detailCloseBtn').addEventListener('click', closeDetail);
  document.getElementById('detailModal').addEventListener('click', (e) => {
    if (e.target.id === 'detailModal') closeDetail();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDetail(); });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Tender Declarations');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Tender Declarations.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  wireFilters();
  await loadDeclarations();
})();
