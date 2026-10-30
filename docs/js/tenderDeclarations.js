// Tender Declarations page. Data comes from the POS:
// TenderDeclarationForm -> OnlinefunctionsEvents.SyncTenderDeclarationToSupabaseAsync
// (supabase_tender_declaration_tables.sql). Variance = Declared - Expected: negative = Short.
// Super Users see every store; Store Managers only their own. Both can attach bank deposit receipts
// (photo + amount/date/ref) to a declaration - supabase_tender_deposit_receipts.sql.
let currentSession = null;
let searchDebounceHandle = null;
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;
let currentRows = [];
let detailRow = null;
let depositPhotoBlob = null;
let slipReadGeneration = 0;
// Set once tender-deposit-read-slip has stored the current photo; saving needs it.
let currentSlipReadId = null;
let slipReadRunning = false;

function creds() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

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

// Deposits vs Declared Cash.
function depositBadge(row) {
  const count = Number(row.deposit_count || 0);
  // An earlier re-declared count: the day's deposit goes on the latest declaration instead.
  if (count === 0 && row.is_counted === false) return '<span class="muted" style="font-size:12px;">On latest declaration</span>';
  if (count === 0) return '<span class="badge badge-neutral">No deposit</span>';
  const diff = Number(row.deposit_total || 0) - Number(row.declared_cash || 0);
  const amount = `<div>${formatMoney(row.deposit_total)}</div>`;
  const unread = Number(row.deposit_unread_count || 0) > 0 ? slipNotReadBadge() : '';
  if (Math.abs(diff) < 0.005) return amount + '<span class="badge badge-success">Matches</span>' + unread;
  return amount + (diff < 0
    ? `<span class="badge badge-danger">${formatMoney(-diff)} less</span>`
    : `<span class="badge badge-warning">${formatMoney(diff)} more</span>`) + unread;
}

// The slip's ID couldn't be read, so the duplicate check only covers the exact same photo file.
function slipNotReadBadge() {
  return '<div><span class="badge badge-warning" title="The slip could not be read, so check this photo by hand">Slip not read</span></div>';
}

function todayManila() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

function currentFilters() {
  return {
    p_search: document.getElementById('searchInput').value.trim() || null,
    p_warehouse: document.getElementById('warehouseSelect').value || null,
    p_from: document.getElementById('fromInput').value || null,
    p_to: document.getElementById('toInput').value || null,
    p_result: document.getElementById('resultSelect').value || null,
    p_deposit: document.getElementById('depositSelect').value || null
  };
}

// Declarations are keyed by the POS's warehouse NAME, so the filter matches on name.
// A Store Manager only ever sees their own store (the RPC enforces it), so the dropdown is fixed.
async function loadWarehouseOptions() {
  const select = document.getElementById('warehouseSelect');
  if (!currentSession.isSuperUser) {
    const own = currentSession.warehouseName || '';
    select.innerHTML = `<option value="">${escapeHtml(own || 'My store')}</option>`;
    select.disabled = true;
    return;
  }
  const { data, error } = await supabaseClient.rpc('admin_list_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) {
    console.error('admin_list_warehouses failed:', error);
    return;
  }
  const names = [...new Set((data || []).map((w) => w.name).filter(Boolean))].sort();
  select.innerHTML = '<option value="">All warehouses</option>' + names
    .map((name) => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`)
    .join('');
}

function renderRows(rows) {
  const tbody = document.getElementById('declTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="10" class="muted">No tender declarations found.</td></tr>';
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
      <td>${formatMoney(r.declared_cash)}${r.is_counted === false
        ? '<div><span class="badge badge-neutral" title="A later declaration was made at this warehouse the same day - only that one is added to Total Declared Cash">Not counted</span></div>'
        : ''}</td>
      <td>${varianceBadge(r.variance)}${r.variance_reason
        ? `<div class="muted" style="font-size:12px; max-width:260px;">${escapeHtml(r.variance_reason)}</div>`
        : (Number(r.variance || 0) !== 0 ? '<div class="muted" style="font-size:12px;">No reason given</div>' : '')}</td>
      <td>${depositBadge(r)}</td>
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
  tbody.innerHTML = '<tr><td colspan="10" class="muted">Loading...</td></tr>';
  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_tender_declarations', {
    ...creds(),
    ...currentFilters(),
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return;

  if (error) {
    tbody.innerHTML = `<tr><td colspan="10" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  currentRows = data || [];
  const first = currentRows[0];
  document.getElementById('statCount').textContent = first ? Number(first.total_count).toLocaleString() : '0';
  document.getElementById('statDeclared').textContent = formatMoney(first ? first.total_declared : 0);
  document.getElementById('statDeposited').textContent = formatMoney(first ? first.total_deposited : 0);
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
  detailRow = row;
  hideDepositForm();
  loadDeposits();
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
    `<tr><td><strong>Result</strong></td><td style="text-align:right;">${varianceBadge(row.variance)}</td></tr>` +
    (Number(row.variance || 0) !== 0
      ? `<tr><td><strong>Cashier's reason</strong></td><td>${row.variance_reason ? escapeHtml(row.variance_reason) : '<span class="muted">No reason given</span>'}</td></tr>`
      : '');

  const tenders = Object.entries(row.sales_by_tender || {});
  document.getElementById('detailTenderBody').innerHTML = (tenders.length
    ? tenders.map(([tender, amount]) => `<tr><td>${escapeHtml(tender)}</td><td style="text-align:right;">${formatMoney(amount)}</td></tr>`).join('')
    : '<tr><td class="muted">No customer payments.</td></tr>') +
    `<tr><td>Advance order collections (included above)</td><td style="text-align:right;">${formatMoney(row.advance_collections)}</td></tr>`;

  const linesBody = document.getElementById('detailLinesBody');
  linesBody.innerHTML = '<tr><td colspan="3" class="muted">Loading...</td></tr>';
  document.getElementById('detailModal').classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('admin_list_tender_declaration_lines', {
    ...creds(),
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
  detailRow = null;
}

// ---------------------------------------------------------------- bank deposits

async function loadDeposits() {
  const row = detailRow;
  const body = document.getElementById('depositsBody');
  const summary = document.getElementById('depositSummary');
  body.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';
  summary.textContent = '';

  const { data, error } = await supabaseClient.rpc('staff_list_tender_deposits', {
    ...creds(),
    p_warehouse: row.warehouse,
    p_eod_id: row.eod_id
  });
  if (row !== detailRow) return;
  if (error) {
    body.innerHTML = `<tr><td colspan="6" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const deposits = data || [];
  if (deposits.length === 0) {
    body.innerHTML = '<tr><td colspan="6" class="muted">No deposit receipt attached yet.</td></tr>';
  } else {
    body.innerHTML = deposits.map((d) => `
      <tr>
        <td>${d.photo_url
          ? `<a href="${escapeHtml(d.photo_url)}" target="_blank" rel="noopener"><img class="deposit-thumb" src="${escapeHtml(d.photo_url)}" alt="Deposit receipt" loading="lazy" /></a>`
          : '<span class="muted">Photo unavailable</span>'}</td>
        <td>${escapeHtml(d.deposit_date)}</td>
        <td style="text-align:right;">${formatMoney(d.deposit_amount)}${d.slip_not_read ? slipNotReadBadge() : ''}${d.duplicate_allowed_by
          ? `<div><span class="badge badge-warning">Duplicate allowed by ${escapeHtml(d.duplicate_allowed_by)}</span></div>` : ''}</td>
        <td>${escapeHtml(d.reference_no || '')}${d.note ? `<div class="muted" style="font-size:12px;">${escapeHtml(d.note)}</div>` : ''}</td>
        <td>${escapeHtml(d.uploaded_by)}<div class="muted" style="font-size:12px;">${escapeHtml(new Date(d.uploaded_at_utc).toLocaleString('en-PH'))}</div></td>
        <td>${d.can_delete ? `<button class="btn btn-sm" type="button" data-deposit-id="${d.id}">Remove</button>` : ''}</td>
      </tr>
    `).join('');
    body.querySelectorAll('[data-deposit-id]').forEach((btn) => {
      btn.addEventListener('click', () => deleteDeposit(Number(btn.dataset.depositId)));
    });
  }

  if (row.is_counted === false && deposits.length === 0) {
    summary.textContent = 'This count was re-declared later the same day - attach the deposit to the latest declaration for this day.';
    return;
  }

  const total = deposits.reduce((sum, d) => sum + Number(d.deposit_amount || 0), 0);
  const diff = total - Number(row.declared_cash || 0);
  summary.innerHTML = `Deposited <strong>${formatMoney(total)}</strong> of Declared Cash <strong>${formatMoney(row.declared_cash)}</strong>` +
    (deposits.length === 0 ? '' : Math.abs(diff) < 0.005 ? ' &middot; matches'
      : ` &middot; ${diff < 0 ? formatMoney(-diff) + ' still to deposit' : formatMoney(diff) + ' more than declared'}`);
}

function showDepositFormError(message) {
  const el = document.getElementById('depositFormError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function hideDepositForm() {
  document.getElementById('depositFormBox').classList.add('hidden');
  slipReadGeneration++; // a read still running must not fill in a closed form
  slipReadRunning = false;
  currentSlipReadId = null;
  setSlipReadStatus('');
  // Re-declared earlier that day: the deposit goes on the latest declaration (the server refuses too).
  document.getElementById('showDepositFormBtn').classList.toggle('hidden', detailRow?.is_counted === false);
  showDepositFormError('');
}

function showDepositForm() {
  depositPhotoBlob = null;
  slipReadGeneration++;
  slipReadRunning = false;
  currentSlipReadId = null;
  setSlipReadStatus('');
  // Left blank until the photo is added, so the slip's own figures fill them (readDepositSlip).
  document.getElementById('depositAmountInput').value = '';
  document.getElementById('depositDateInput').value = '';
  document.getElementById('depositDateInput').max = todayManila();
  document.getElementById('depositRefInput').value = '';
  document.getElementById('depositNoteInput').value = '';
  document.getElementById('depositPhotoInput').value = '';
  document.getElementById('depositPhotoPreview').classList.add('hidden');
  showDepositFormError('');
  document.getElementById('depositFormBox').classList.remove('hidden');
  document.getElementById('showDepositFormBtn').classList.add('hidden');
}

// Phone photos are several MB; shrunk to at most 1600px on the long side and re-encoded as JPEG -
// still sharp enough to read the slip's printed amount and reference.
function compressImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 1600 / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not process the photo.'))), 'image/jpeg', 0.85);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('That file is not a readable image.')); };
    img.src = url;
  });
}

async function onDepositPhotoChosen(event) {
  const file = event.target.files && event.target.files[0];
  const preview = document.getElementById('depositPhotoPreview');
  depositPhotoBlob = null;
  slipReadGeneration++;
  slipReadRunning = false;
  currentSlipReadId = null;
  setSlipReadStatus('');
  preview.classList.add('hidden');
  if (!file) return;
  try {
    depositPhotoBlob = await compressImage(file);
    preview.src = URL.createObjectURL(depositPhotoBlob);
    preview.classList.remove('hidden');
  } catch (err) {
    showDepositFormError(err.message);
    return;
  }
  readDepositSlip(depositPhotoBlob);
}

function setSlipReadStatus(message) {
  const el = document.getElementById('depositReadStatus');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = () => reject(new Error('Could not read the photo.'));
    reader.readAsDataURL(blob);
  });
}

// Stores and reads the slip (Edge Function tender-deposit-read-slip) and fills in what it finds, for
// the manager to check. If the slip can't be read the photo is still stored, so they type the details
// and the deposit is flagged "Slip not read". A field typed in while the read was running is left alone.
async function readDepositSlip(blob) {
  const thisRead = ++slipReadGeneration;
  const row = detailRow;
  slipReadRunning = true;
  const amountInput = document.getElementById('depositAmountInput');
  const dateInput = document.getElementById('depositDateInput');
  const refInput = document.getElementById('depositRefInput');
  const before = { amount: amountInput.value, date: dateInput.value, ref: refInput.value };
  setSlipReadStatus('Reading the slip...');

  let slip;
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/tender-deposit-read-slip`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        warehouse: row.warehouse,
        eod_id: row.eod_id,
        image_base64: await blobToBase64(blob)
      })
    });
    slip = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(slip.error || `HTTP ${response.status}`);
  } catch (err) {
    console.warn('Slip read failed:', err instanceof Error ? err.message : err);
    if (thisRead === slipReadGeneration) {
      slipReadRunning = false;
      setSlipReadStatus(`Could not store this photo (${err instanceof Error ? err.message : 'unknown error'}) - choose it again to retry.`);
    }
    return;
  }
  if (thisRead !== slipReadGeneration) return;
  slipReadRunning = false;
  currentSlipReadId = slip.read_id;
  if (!slip.readable) {
    setSlipReadStatus('Could not read the amount on this slip - please type it, or retake the photo.');
    return;
  }

  if (amountInput.value === before.amount) amountInput.value = Number(slip.amount).toFixed(2);
  // Not in the future: the Deposit Date field and staff_add_tender_deposit refuse that anyway.
  if (slip.deposit_date && slip.deposit_date <= todayManila() && dateInput.value === before.date) dateInput.value = slip.deposit_date;
  if (slip.reference_no && refInput.value === before.ref && !refInput.value) refInput.value = slip.reference_no;
  setSlipReadStatus('Filled in from the slip - please check the amount and date before saving.');
}

async function saveDeposit() {
  showDepositFormError('');
  const row = detailRow;
  const amount = Number(document.getElementById('depositAmountInput').value);
  const depositDate = document.getElementById('depositDateInput').value;
  if (!(amount > 0)) return showDepositFormError('Enter the Deposit Amount.');
  if (!depositDate) return showDepositFormError('Enter the Deposit Date.');
  if (slipReadRunning) return showDepositFormError('Still reading the slip - wait a moment.');
  if (!depositPhotoBlob || !currentSlipReadId) return showDepositFormError('Attach a photo of the deposit receipt.');

  const btn = document.getElementById('saveDepositBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';
  try {
    const addDeposit = (allowDuplicate) => supabaseClient.rpc('staff_add_tender_deposit', {
      ...creds(),
      p_warehouse: row.warehouse,
      p_eod_id: row.eod_id,
      p_amount: amount,
      p_deposit_date: depositDate,
      p_reference_no: document.getElementById('depositRefInput').value.trim() || null,
      p_note: document.getElementById('depositNoteInput').value.trim() || null,
      p_read_id: currentSlipReadId,
      p_allow_duplicate: allowDuplicate
    });

    let { error } = await addDeposit(false);
    // A misread can look like a duplicate, so a super user can save it anyway (recorded on the deposit).
    if (error?.code === 'RSDUP' && currentSession.isSuperUser
        && confirm(`${error.message}\n\nAllow it anyway? Your name is recorded on the deposit.`)) {
      ({ error } = await addDeposit(true));
    }
    if (error) throw new Error(error.message);

    hideDepositForm();
    if (row === detailRow) await loadDeposits();
    loadDeclarations();
  } catch (err) {
    showDepositFormError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Save deposit';
  }
}

async function deleteDeposit(depositId) {
  if (!confirm('Remove this deposit receipt? The photo is deleted too.')) return;
  const { error } = await supabaseClient.rpc('staff_delete_tender_deposit', { ...creds(), p_deposit_id: depositId });
  if (error) {
    alert(error.message);
    return;
  }
  await loadDeposits();
  loadDeclarations();
}

function wireFilters() {
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => { currentPage = 1; loadDeclarations(); }, 300);
  });
  ['warehouseSelect', 'fromInput', 'toInput', 'resultSelect', 'depositSelect'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => { currentPage = 1; loadDeclarations(); });
  });
  document.getElementById('detailCloseBtn').addEventListener('click', closeDetail);
  document.getElementById('detailModal').addEventListener('click', (e) => {
    if (e.target.id === 'detailModal') closeDetail();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDetail(); });
  document.getElementById('showDepositFormBtn').addEventListener('click', showDepositForm);
  document.getElementById('cancelDepositBtn').addEventListener('click', hideDepositForm);
  document.getElementById('saveDepositBtn').addEventListener('click', saveDeposit);
  document.getElementById('depositPhotoInput').addEventListener('change', onDepositPhotoChosen);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Tender Declarations');

  if (!session.isSuperUser && !session.isStoreManager) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }
  if (!session.isSuperUser) {
    document.getElementById('pageIntro').textContent =
      "Your store's end-of-day cash counts from the POS. Open one with View to attach the bank deposit receipt.";
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Tender Declarations.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  wireFilters();
  await Promise.all([loadWarehouseOptions(), loadDeclarations()]);
})();
