// Item Ledger Entries page - laid out like a Business Central list page (title bar + search, action
// bar, message bar, view tabs, filter pane, grid, FactBox; css/bc-list.css). Two views over the same
// filters: the ledger itself and the per-location stock balance computed from it. Posting an
// adjustment, loading a stock count and reversing a transaction are dialogs off the action bar.
// See supabase_item_ledger_entries.sql for the model.
//
// Nothing here edits or deletes a ledger row: the only writes are posting a new adjustment / stock
// count and reversing a transaction (which posts the opposite entry), all through RPCs that
// re-check the caller is a super user.
let currentSession = null;
let ledgerPage = 1;
let ledgerPageSize = 50;
let balancePage = 1;
let balancePageSize = 50;
let searchDebounceHandle = null;
let itemSearchDebounceHandle = null;
let itemSearchResults = []; // [{code, name}] backing the adjustment form's item datalist
let selectedItemCode = null; // set once the typed value matches a real item code exactly
let selectedItemHasVariants = false;

let activeView = 'ledger'; // 'ledger' | 'balance'
const viewDirty = { ledger: true, balance: true }; // a view reloads when shown if the filters/data moved under it
let ledgerRows = []; // rows on the current ledger page - the FactBox and Reverse read the selected one from here
let selectedEntryNo = null;
let factBoxToken = 0; // guards the FactBox's availability lookup against a slower, stale response

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatQuantity(value) {
  // Up to 4dp because the ledger stores 4dp, but trimmed so a whole number reads "12", not "12.0000".
  const n = Number(value || 0);
  return Number.isInteger(n) ? String(n) : String(parseFloat(n.toFixed(4)));
}

function formatSignedQuantity(value) {
  const n = Number(value || 0);
  return (n > 0 ? '+' : '') + formatQuantity(n);
}

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value + (String(value).length === 10 ? 'T00:00:00' : ''));
  return isNaN(d.getTime()) ? value : d.toLocaleDateString();
}

function todayIso() {
  const d = new Date();
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

function filterValues() {
  return {
    from: document.getElementById('ileFromDate').value || null,
    to: document.getElementById('ileToDate').value || null,
    warehouseId: document.getElementById('ileWarehouseFilter').value || null,
    entryType: document.getElementById('ileTypeFilter').value || null,
    search: document.getElementById('ileSearchInput').value.trim() || null
  };
}

// Makes the active grid fill the rest of the viewport instead of stopping at a guessed height and
// leaving a slab of empty page below it (or, on a short screen, clipping) - the .bc-grid-wrap CSS
// max-height is only a pre-JS fallback. Re-measures from the element's actual position, so it's
// correct no matter what's above it (filter chips, the sales-posting bar) or how tall the window is.
function fitGridToViewport(el, minPx) {
  if (!el) return;
  const top = el.getBoundingClientRect().top;
  const available = window.innerHeight - top - 16; // small breathing room at the bottom edge
  el.style.maxHeight = Math.max(minPx || 240, available) + 'px';
}

function fitActiveGrid() {
  fitGridToViewport(document.getElementById(activeView === 'ledger' ? 'ledgerGridWrap' : 'balanceGridWrap'));
}

function itemLabel(row) {
  const name = row.item_name && row.item_name !== row.item_code ? ` - ${row.item_name}` : '';
  const variant = row.variant_name ? ` (${row.variant_name})` : (row.variant_id ? ` (${row.variant_id})` : '');
  return `${row.item_code}${name}${variant}`;
}

// ---------------------------------------------------------------- warehouses (filter + form)

async function loadWarehouses() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });

  if (error) {
    console.error('staff_search_warehouses failed:', error);
    return;
  }

  const options = (data || []).map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
  document.getElementById('ileWarehouseFilter').innerHTML = '<option value="">(all)</option>' + options;
  document.getElementById('adjWarehouseSelect').innerHTML = '<option value="">Select a location...</option>' + options;
}

// ---------------------------------------------------------------- views, dialogs, layout

// BC opens a list page with the filter pane collapsed (the funnel toggles it); only a really wide
// screen has room for it beside the grid and the FactBox. Whatever is filtered still shows as chips.
let filterPaneOpen = window.innerWidth >= 1700;

// The applied filters as removable chips under the tabs, so a collapsed filter pane never hides
// why some entries are missing (the default is "this month"). The search box shows its own text.
function renderFilterChips() {
  const f = filterValues();
  const chips = [];
  if (f.from || f.to) {
    chips.push({ key: 'date', label: 'Posting Date: ' + (f.from ? formatDate(f.from) : '...') + '..' + (f.to ? formatDate(f.to) : '...') });
  }
  if (f.entryType) chips.push({ key: 'type', label: 'Entry Type: ' + f.entryType });
  if (f.warehouseId) {
    const sel = document.getElementById('ileWarehouseFilter');
    const opt = sel.options[sel.selectedIndex];
    chips.push({ key: 'warehouse', label: 'Location Code: ' + (opt ? opt.textContent : f.warehouseId) });
  }

  const box = document.getElementById('filterChips');
  box.classList.toggle('hidden', chips.length === 0);
  box.innerHTML = chips.length === 0 ? '' :
    '<span class="muted">Filtered by:</span>' +
    chips.map((c) => `<span class="bc-chip">${escapeHtml(c.label)}<button type="button" data-clear-filter="${c.key}" aria-label="Remove this filter">&times;</button></span>`).join('');
}

function clearOneFilter(key) {
  if (key === 'date') {
    document.getElementById('ileFromDate').value = '';
    document.getElementById('ileToDate').value = '';
  } else if (key === 'type') {
    document.getElementById('ileTypeFilter').value = '';
  } else if (key === 'warehouse') {
    document.getElementById('ileWarehouseFilter').value = '';
  }
  selectedEntryNo = null;
  ledgerPage = 1;
  balancePage = 1;
  refreshAll();
}

function selectedEntry() {
  return ledgerRows.find((r) => r.entry_no === selectedEntryNo) || null;
}

function showDialog(id) {
  document.getElementById(id).classList.remove('hidden');
}

function hideDialog(id) {
  document.getElementById(id).classList.add('hidden');
}

function closeAllDialogs() {
  document.querySelectorAll('.bc-dialog-backdrop').forEach((d) => d.classList.add('hidden'));
}

function anyDialogOpen() {
  return !!document.querySelector('.bc-dialog-backdrop:not(.hidden)');
}

// The filter pane is BC's "Filter list by" column and the FactBox is its right-hand details column.
// The FactBox describes a ledger line, so it only exists on the Ledger Entries view.
function updateBodyLayout() {
  const factBoxOn = activeView === 'ledger';
  document.getElementById('bcBody').classList.toggle('no-filterpane', !filterPaneOpen);
  document.getElementById('bcBody').classList.toggle('no-factbox', !factBoxOn);
  document.getElementById('filterPane').classList.toggle('hidden', !filterPaneOpen);
  document.getElementById('factBox').classList.toggle('hidden', !factBoxOn);
  document.getElementById('filterPaneBtn').setAttribute('aria-pressed', filterPaneOpen ? 'true' : 'false');
  fitActiveGrid();
}

// Reverse acts on the selected line, and only one that has not already been reversed / is not
// itself the correction. (The server still refuses what cannot be reversed by hand, e.g. Sales and
// Transfers, and says why.)
function updateActionState() {
  const e = selectedEntry();
  document.getElementById('reverseBtn').disabled = !(activeView === 'ledger' && e && !e.is_reversed && !e.is_reversal);
  document.getElementById('showDocBtn').disabled = !(activeView === 'ledger' && e && linkedDocumentKind(e));
}

// "Show Document" (as in Business Central): opens the document an entry was posted from, in a new
// tab. A reversal ("Purchase Receipt Reversal") points at the same document as the original.
// Adjustments, stock counts, physical inventory and opening balances have no document page.
// A purchase order / transfer order that is still open goes to its normal page, and one that has
// since been posted goes to the Posted Purchase Orders / Posted Transfer Orders page.
function linkedDocumentKind(e) {
  const docNo = String(e.document_no || '').trim();
  if (!docNo) return null;
  const type = String(e.document_type || '').replace(/ Reversal$/, '');
  if (type === 'Sales Order') return { kind: 'sales', docNo };
  if (type === 'Defect') return { kind: 'defect', docNo };
  if (type === 'Purchase Receipt') return { kind: 'purchase', docNo };
  if (type === 'Transfer Shipment' || type === 'Transfer Receipt') return { kind: 'transfer', docNo };
  return null;
}

// Which page holds the document right now: the open one if it still exists, otherwise the posted one.
async function resolveLinkedDocumentUrl({ kind, docNo }) {
  const enc = encodeURIComponent(docNo);
  if (kind === 'sales') return 'online-order-lines.html?order=' + enc;
  if (kind === 'defect') return 'defect-items.html?search=' + enc;

  if (kind === 'purchase') {
    const { data } = await supabaseClient.rpc('staff_get_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: docNo
    });
    return (data && data.length > 0 ? 'purchase-orders.html?search=' : 'posted-purchase-orders.html?search=') + enc;
  }

  const { data } = await supabaseClient.from('Transfer_Header').select('*').eq('"No."', docNo).limit(1);
  return (data && data.length > 0 ? 'transfer-orders.html?doc=' : 'posted-transfer-orders.html?doc=') + enc;
}

async function showLinkedDocument() {
  const e = selectedEntry();
  const doc = e && linkedDocumentKind(e);
  if (!doc) return;

  // Opened up front so the browser's pop-up blocker treats it as part of the click, then pointed
  // at the right page once we know whether the document is still open or already posted.
  const tab = window.open('', '_blank');
  try {
    const url = await resolveLinkedDocumentUrl(doc);
    if (tab) tab.location.href = url; else window.location.href = url;
  } catch (err) {
    if (tab) tab.close();
    console.error('Show Document failed:', err);
    window.alert('Could not open the document: ' + (err.message || err));
  }
}

function loadActiveViewIfDirty() {
  renderFilterChips();
  if (!viewDirty[activeView]) return Promise.resolve();
  return activeView === 'ledger' ? loadEntries() : loadBalances();
}

function setView(view) {
  activeView = view;
  document.querySelectorAll('.bc-tab').forEach((tab) => {
    const on = tab.dataset.view === view;
    tab.classList.toggle('active', on);
    tab.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  document.getElementById('ledgerView').classList.toggle('hidden', view !== 'ledger');
  document.getElementById('balanceView').classList.toggle('hidden', view !== 'balance');
  updateBodyLayout();
  updateActionState();
  return loadActiveViewIfDirty();
}

// Anything that changes the filters or the data marks both views stale; only the visible one is
// fetched now, the other when its tab is opened.
function refreshAll() {
  viewDirty.ledger = true;
  viewDirty.balance = true;
  return loadActiveViewIfDirty();
}

// BC's Item No. drill-down: jump to that item's whole history on the ledger.
function drillToLedger(itemCode) {
  document.getElementById('ileSearchInput').value = itemCode;
  document.getElementById('ileFromDate').value = '';
  selectedEntryNo = null;
  ledgerPage = 1;
  balancePage = 1;
  viewDirty.ledger = true;
  viewDirty.balance = true;
  return setView('ledger');
}

function clearFilters() {
  document.getElementById('ileSearchInput').value = '';
  document.getElementById('ileFromDate').value = '';
  document.getElementById('ileToDate').value = '';
  document.getElementById('ileTypeFilter').value = '';
  document.getElementById('ileWarehouseFilter').value = '';
  selectedEntryNo = null;
  ledgerPage = 1;
  balancePage = 1;
  refreshAll();
}

// ---------------------------------------------------------------- ledger

let ledgerRequestId = 0;

async function loadEntries() {
  const requestId = ++ledgerRequestId;
  viewDirty.ledger = false;

  const body = document.getElementById('ileTableBody');
  const errorBox = document.getElementById('ileError');
  errorBox.classList.add('hidden');
  body.innerHTML = '<tr><td colspan="13" class="cell-msg">Loading...</td></tr>';

  const f = filterValues();
  const { data, error } = await supabaseClient.rpc('admin_list_item_ledger_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_from_date: f.from,
    p_to_date: f.to,
    p_search: f.search,
    p_warehouse_id: f.warehouseId,
    p_entry_type: f.entryType,
    p_page: ledgerPage,
    p_page_size: ledgerPageSize
  });

  if (requestId !== ledgerRequestId) return; // a newer filter change is already loading

  if (error) {
    ledgerRows = [];
    selectedEntryNo = null;
    body.innerHTML = `<tr><td colspan="13" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    updateActionState();
    renderFactBox();
    fitActiveGrid();
    return;
  }

  const rows = data || [];
  ledgerRows = rows;

  if (rows.length === 0) {
    selectedEntryNo = null;
    body.innerHTML = '<tr><td colspan="13" class="cell-msg">There is nothing to show for these filters.</td></tr>';
    document.getElementById('ileTotalQuantity').textContent = '0';
    renderPaginationBar(document.getElementById('ilePaginationBar'), { page: ledgerPage, pageSize: ledgerPageSize, totalCount: 0 }, {});
    updateActionState();
    renderFactBox();
    fitActiveGrid();
    return;
  }

  // Keep the selection across a reload (a reversal, a refresh) if that line is still on this page.
  if (!rows.some((r) => r.entry_no === selectedEntryNo)) selectedEntryNo = null;

  body.innerHTML = rows.map((r) => {
    const qty = Number(r.quantity || 0);
    // A reversed entry (and the correction that cancels it) stays on the ledger - that is the
    // point - but is dimmed so it is clear the pair nets to nothing.
    const classes = [
      r.is_reversed || r.is_reversal ? 'dim' : '',
      r.entry_no === selectedEntryNo ? 'selected' : ''
    ].filter(Boolean).join(' ');
    const showName = r.item_name && r.item_name !== r.item_code ? r.item_name : '';
    const variant = r.variant_name || r.variant_id || '';
    return `
      <tr class="${classes}" data-entry-no="${r.entry_no}">
        <td>${escapeHtml(formatDate(r.posting_date))}</td>
        <td>${escapeHtml(r.posted_at_utc ? new Date(r.posted_at_utc).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '')}</td>
        <td>${escapeHtml(r.posted_by || '')}</td>
        <td>${escapeHtml(r.entry_type)}${r.is_reversed ? ' <span class="muted">(reversed)</span>' : ''}</td>
        <td>${escapeHtml(r.document_type || '')}</td>
        <td>${escapeHtml(r.document_no || '')}</td>
        <td><button type="button" class="bc-link" data-drill-item="${escapeHtml(r.item_code)}" title="Show only this item's entries">${escapeHtml(r.item_code)}</button></td>
        <td class="cell-text" title="${escapeHtml(showName)}">${escapeHtml(showName)}</td>
        <td class="cell-text" title="${escapeHtml(variant)}">${escapeHtml(variant)}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td class="num" title="${escapeHtml(r.description || '')}">${formatQuantity(qty)}</td>
        <td class="cell-center">${r.is_reversal ? '<span class="bc-tick" title="Correction entry">&#10003;</span>' : ''}</td>
        <td class="num">${r.entry_no}</td>
      </tr>`;
  }).join('');

  // Window total over the entire filtered set, not just this page - describes the filter rather
  // than the pagination.
  document.getElementById('ileTotalQuantity').textContent = formatQuantity(rows[0].total_quantity);

  renderPaginationBar(
    document.getElementById('ilePaginationBar'),
    { page: ledgerPage, pageSize: ledgerPageSize, totalCount: rows[0].total_count || 0 },
    {
      onPageChange: (newPage) => { ledgerPage = newPage; viewDirty.ledger = true; loadEntries(); },
      onPageSizeChange: (newSize) => { ledgerPageSize = newSize; ledgerPage = 1; viewDirty.ledger = true; loadEntries(); }
    }
  );

  updateActionState();
  renderFactBox();
  fitActiveGrid();
}

function selectEntry(entryNo) {
  selectedEntryNo = entryNo;
  document.querySelectorAll('#ileTableBody tr[data-entry-no]').forEach((tr) => {
    tr.classList.toggle('selected', Number(tr.dataset.entryNo) === entryNo);
  });
  updateActionState();
  renderFactBox();
}

// Up / Down move the current row, as in BC. Ignored while typing in a field or with a dialog open.
function moveSelection(step) {
  if (ledgerRows.length === 0) return;
  const idx = ledgerRows.findIndex((r) => r.entry_no === selectedEntryNo);
  const next = idx < 0 ? (step > 0 ? 0 : ledgerRows.length - 1) : Math.min(Math.max(idx + step, 0), ledgerRows.length - 1);
  selectEntry(ledgerRows[next].entry_no);
  const tr = document.querySelector(`#ileTableBody tr[data-entry-no="${ledgerRows[next].entry_no}"]`);
  if (tr) tr.scrollIntoView({ block: 'nearest' });
}

// ---------------------------------------------------------------- FactBox (details of the selected line)

function renderFactBox() {
  const details = document.getElementById('factDetails');
  const availBox = document.getElementById('factAvailBox');
  const e = selectedEntry();
  const token = ++factBoxToken;

  if (!e) {
    details.innerHTML = '<p class="bc-fact-empty">Select an entry to see its details.</p>';
    availBox.classList.add('hidden');
    return;
  }

  const status = e.is_reversed
    ? 'Reversed - a later entry cancels it'
    : (e.is_reversal ? 'Correction - reverses an earlier entry' : 'Active');
  const facts = [
    ['Entry No.', e.entry_no],
    ['Transaction No.', e.transaction_no],
    ['Posting Date', formatDate(e.posting_date)],
    ['Entry Type', e.entry_type],
    ['Document', [e.document_type, e.document_no].filter(Boolean).join(' ')],
    ['Item No.', e.item_code],
    ['Description', e.item_name && e.item_name !== e.item_code ? e.item_name : ''],
    ['Variant', e.variant_name || e.variant_id || ''],
    ['Location Code', e.warehouse_name],
    ['Quantity', formatQuantity(e.quantity)],
    ['Reason', e.description],
    ['Posted By', e.posted_by],
    ['Posted At', e.posted_at_utc ? new Date(e.posted_at_utc).toLocaleString() : ''],
    ['Status', status]
  ].filter(([, v]) => v !== '' && v !== null && v !== undefined);

  details.innerHTML = '<dl class="bc-facts">' +
    facts.map(([k, v]) => `<dt>${escapeHtml(k)}</dt><dd>${escapeHtml(v)}</dd>`).join('') +
    '</dl>';

  loadItemAvailability(e.item_code, token);
}

// "Item Availability by Location" - what the ledger says is on hand for the selected line's item,
// per location (variants rolled up, like BC's Item Card).
async function loadItemAvailability(itemCode, token) {
  const availBox = document.getElementById('factAvailBox');
  const body = document.getElementById('factAvail');
  availBox.classList.remove('hidden');
  body.innerHTML = '<p class="bc-fact-empty">Loading...</p>';

  const { data, error } = await supabaseClient.rpc('admin_get_item_ledger_balances', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_as_of_date: null,
    p_search: itemCode,
    p_warehouse_id: null,
    p_combine_variants: true,
    p_page: 1,
    p_page_size: 200
  });

  if (token !== factBoxToken) return; // another line was selected meanwhile

  if (error) {
    body.innerHTML = `<p class="bc-fact-empty">${escapeHtml(error.message)}</p>`;
    return;
  }

  // The search also matches names, so keep only this exact item.
  const rows = (data || []).filter((r) => r.item_code === itemCode);
  if (rows.length === 0) {
    body.innerHTML = '<p class="bc-fact-empty">Nothing on hand.</p>';
    return;
  }

  const total = rows.reduce((sum, r) => sum + Number(r.balance || 0), 0);
  body.innerHTML = '<table class="bc-avail">' +
    rows.map((r) => {
      const bal = Number(r.balance || 0);
      return `<tr><td>${escapeHtml(r.warehouse_name || '')}</td><td class="${bal < 0 ? 'neg' : ''}" style="${bal < 0 ? 'color:var(--danger);' : ''}">${formatQuantity(bal)}</td></tr>`;
    }).join('') +
    `<tr class="total"><td>Inventory</td><td>${formatQuantity(total)}</td></tr>` +
    '</table>';
}

// ---------------------------------------------------------------- reverse transaction

let reverseTarget = null;

function openReverseDialog() {
  const e = selectedEntry();
  if (!e || e.is_reversed || e.is_reversal) return;

  reverseTarget = e;
  document.getElementById('reverseSummary').innerHTML =
    `Entry <strong>${escapeHtml(e.entry_no)}</strong> - ${escapeHtml(e.entry_type)}, ` +
    `${escapeHtml(itemLabel(e))}, <strong>${escapeHtml(formatQuantity(e.quantity))}</strong> at ${escapeHtml(e.warehouse_name || '')}.` +
    '<br />Every entry in the same transaction is reversed together.';
  document.getElementById('reverseReasonInput').value = '';
  document.getElementById('reverseMessage').classList.add('hidden');
  showDialog('reverseDialog');
  document.getElementById('reverseReasonInput').focus();
}

async function confirmReverse() {
  if (!reverseTarget) return;
  const msg = document.getElementById('reverseMessage');
  const reason = document.getElementById('reverseReasonInput').value.trim();
  if (!reason) {
    msg.textContent = 'A reason is required to reverse a ledger entry.';
    msg.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('reverseConfirmBtn');
  btn.disabled = true;
  btn.textContent = 'Reversing...';

  const { error } = await supabaseClient.rpc('admin_reverse_item_ledger_transaction', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: reverseTarget.entry_no,
    p_reason: reason
  });

  btn.disabled = false;
  btn.textContent = 'Reverse';

  if (error) {
    msg.textContent = 'Reversal failed: ' + error.message;
    msg.classList.remove('hidden');
    return;
  }

  reverseTarget = null;
  hideDialog('reverseDialog');
  await refreshAll();
}

// ---------------------------------------------------------------- stock by location

let balanceRequestId = 0;

async function loadBalances() {
  const requestId = ++balanceRequestId;
  viewDirty.balance = false;

  const body = document.getElementById('balTableBody');
  const errorBox = document.getElementById('balError');
  errorBox.classList.add('hidden');
  body.innerHTML = '<tr><td colspan="7" class="cell-msg">Loading...</td></tr>';

  const f = filterValues();
  const { data, error } = await supabaseClient.rpc('admin_get_item_ledger_balances', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_as_of_date: f.to,
    p_search: f.search,
    p_warehouse_id: f.warehouseId,
    p_combine_variants: document.getElementById('balCombineVariants').checked,
    p_page: balancePage,
    p_page_size: balancePageSize
  });

  if (requestId !== balanceRequestId) return;

  if (error) {
    body.innerHTML = `<tr><td colspan="7" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    fitActiveGrid();
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="7" class="cell-msg">No stock has been posted for these filters.</td></tr>';
    document.getElementById('balTotal').textContent = '0';
    renderPaginationBar(document.getElementById('balPaginationBar'), { page: balancePage, pageSize: balancePageSize, totalCount: 0 }, {});
    fitActiveGrid();
    return;
  }

  body.innerHTML = rows.map((r) => {
    const balance = Number(r.balance || 0);
    const showName = r.item_name && r.item_name !== r.item_code ? r.item_name : '';
    const variant = r.variant_name || r.variant_id || '';
    return `
      <tr>
        <td><button type="button" class="bc-link" data-drill-item="${escapeHtml(r.item_code)}" title="Show this item's ledger entries">${escapeHtml(r.item_code)}</button></td>
        <td class="cell-text" title="${escapeHtml(showName)}">${escapeHtml(showName)}</td>
        <td class="cell-text" title="${escapeHtml(variant)}">${escapeHtml(variant)}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td class="num">${formatQuantity(r.qty_in)}</td>
        <td class="num">${formatQuantity(r.qty_out)}</td>
        <td class="num ${balance < 0 ? 'neg' : ''}" style="font-weight:600;">${formatQuantity(balance)}</td>
      </tr>`;
  }).join('');

  document.getElementById('balTotal').textContent = formatQuantity(rows[0].total_balance);

  renderPaginationBar(
    document.getElementById('balPaginationBar'),
    { page: balancePage, pageSize: balancePageSize, totalCount: rows[0].total_count || 0 },
    {
      onPageChange: (newPage) => { balancePage = newPage; viewDirty.balance = true; loadBalances(); },
      onPageSizeChange: (newSize) => { balancePageSize = newSize; balancePage = 1; viewDirty.balance = true; loadBalances(); }
    }
  );
  fitActiveGrid();
}

// ---------------------------------------------------------------- adjustment form

async function searchItemsForAdjustment() {
  const text = document.getElementById('adjItemInput').value.trim();
  if (!text) {
    itemSearchResults = [];
    document.getElementById('adjItemList').innerHTML = '';
    return;
  }

  // admin_list_items (super users only, no category exclusions) rather than staff_search_items,
  // which hides categories flagged ExcludeInTransferOrders - a stock adjustment must be able to
  // reach every item.
  const { data, error } = await supabaseClient.rpc('admin_list_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: text,
    p_page: 1,
    p_page_size: 20
  });

  if (error) {
    console.error('admin_list_items failed:', error);
    return;
  }

  itemSearchResults = (data || []).map((i) => ({ code: i.code, name: i.name || i.description || i.code }));
  document.getElementById('adjItemList').innerHTML = itemSearchResults
    .map((i) => `<option value="${escapeHtml(i.code)}">${escapeHtml(i.name)}</option>`)
    .join('');
}

// Runs when the typed/picked value settles: if it exactly matches an item code, look up that item's
// variants. An item that has variants must be adjusted per variant (stock is tracked per variant),
// so the Variant field appears and becomes required; an item without any leaves it hidden.
async function resolveSelectedItem() {
  const typed = document.getElementById('adjItemInput').value.trim();
  const match = itemSearchResults.find((i) => i.code === typed);
  const variantRow = document.getElementById('adjVariantRow');
  const variantSelect = document.getElementById('adjVariantSelect');

  selectedItemCode = match ? match.code : null;
  selectedItemHasVariants = false;
  variantRow.classList.add('hidden');
  variantSelect.innerHTML = '';

  if (!selectedItemCode) return;

  const { data, error } = await supabaseClient.rpc('admin_list_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_main_item_code: selectedItemCode,
    p_page: 1,
    p_page_size: 200
  });

  if (error) {
    console.error('admin_list_variants failed:', error);
    return;
  }

  // Guard against a slower response landing after the user already picked a different item.
  if (selectedItemCode !== match.code) return;

  const variants = data || [];
  if (variants.length === 0) return;

  selectedItemHasVariants = true;
  variantSelect.innerHTML = '<option value="">Select a variant...</option>' + variants
    .map((v) => `<option value="${escapeHtml(v.variation_id)}">${escapeHtml(v.variant_name || v.sku || v.variation_id)}</option>`)
    .join('');
  variantRow.classList.remove('hidden');
}

function showAdjustmentMessage(text, isError) {
  const box = document.getElementById('adjMessage');
  box.textContent = text;
  box.classList.remove('hidden');
  box.classList.toggle('error-text', !!isError);
  box.classList.toggle('muted', !isError);
}

async function postAdjustment() {
  const warehouseId = document.getElementById('adjWarehouseSelect').value;
  const variantId = document.getElementById('adjVariantSelect').value;
  const direction = Number(document.getElementById('adjDirectionSelect').value);
  const quantity = Number(document.getElementById('adjQuantityInput').value);
  const postingDate = document.getElementById('adjDateInput').value || todayIso();
  const reason = document.getElementById('adjReasonInput').value.trim();

  if (!selectedItemCode) return showAdjustmentMessage('Pick an item from the suggestions first.', true);
  if (selectedItemHasVariants && !variantId) return showAdjustmentMessage('This item has variants - pick which one.', true);
  if (!warehouseId) return showAdjustmentMessage('Select a location.', true);
  if (!(quantity > 0)) return showAdjustmentMessage('Enter a quantity greater than zero.', true);
  if (!reason) return showAdjustmentMessage('A reason is required.', true);

  const btn = document.getElementById('postAdjustmentBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';

  const { data, error } = await supabaseClient.rpc('admin_post_item_adjustments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_posting_date: postingDate,
    p_description: reason,
    p_lines: [{
      item_code: selectedItemCode,
      variant_id: variantId || null,
      warehouse_id: warehouseId,
      quantity: direction * quantity
    }]
  });

  btn.disabled = false;
  btn.textContent = 'Post';

  if (error) {
    return showAdjustmentMessage('Posting failed: ' + error.message, true);
  }

  const result = Array.isArray(data) ? data[0] : data;
  showAdjustmentMessage(`Posted ${result?.document_no || 'adjustment'}.`, false);

  // Keep the item/warehouse/date/reason in place - opening balances are usually loaded as a run of
  // similar lines - and just clear what changes every time.
  document.getElementById('adjItemInput').value = '';
  document.getElementById('adjQuantityInput').value = '';
  await resolveSelectedItem();
  await refreshAll();
}

// ---------------------------------------------------------------- stock count (CSV)

// Rows the last successful Preview parsed - Post re-sends exactly these, so what was previewed is
// what gets applied (the server re-validates and recomputes the differences again anyway).
let previewedCountRows = null;

// Column headers people actually have in a spreadsheet, normalised (lower-case, letters/digits only).
const COUNT_COLUMN_ALIASES = {
  item: ['item', 'itemcode', 'itemno', 'code', 'sku', 'itemsku', 'productcode', 'product'],
  variant: ['variant', 'variantname', 'variantsku', 'variationid', 'variation', 'variantid', 'variantcode'],
  warehouse: ['warehouse', 'warehousename', 'warehouseid', 'location', 'store'],
  quantity: ['quantity', 'qty', 'count', 'counted', 'countedqty', 'onhand', 'quantityonhand', 'stock', 'remainquantity']
};

// Small RFC-4180-style parser: quoted fields, doubled quotes, commas or tabs or semicolons as the
// delimiter (Excel writes whichever the locale uses), CRLF or LF.
function parseCsv(text) {
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
  const firstLine = text.split(/\r?\n/, 1)[0] || '';
  const count = (ch) => firstLine.split(ch).length - 1;
  const delimiter = count('\t') > Math.max(count(','), count(';')) ? '\t' : (count(';') > count(',') ? ';' : ',');

  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === delimiter) {
      row.push(field); field = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(field); rows.push(row); row = []; field = '';
    } else {
      field += ch;
    }
  }
  if (field !== '' || row.length > 0) { row.push(field); rows.push(row); }
  return rows;
}

function buildCountRows(csvRows) {
  if (csvRows.length < 2) throw new Error('The file needs a header row and at least one data row.');

  const headers = csvRows[0].map((h) => String(h).toLowerCase().replace(/[^a-z0-9]/g, ''));
  const indexOf = (aliases) => headers.findIndex((h) => aliases.includes(h));
  const cols = {
    item: indexOf(COUNT_COLUMN_ALIASES.item),
    variant: indexOf(COUNT_COLUMN_ALIASES.variant),
    warehouse: indexOf(COUNT_COLUMN_ALIASES.warehouse),
    quantity: indexOf(COUNT_COLUMN_ALIASES.quantity)
  };

  const missing = ['item', 'warehouse', 'quantity'].filter((k) => cols[k] < 0);
  if (missing.length > 0) {
    throw new Error('Could not find a ' + missing.join(' / ') + ' column in the header row. Use Item, Variant (optional), Warehouse, Quantity.');
  }

  const rows = [];
  csvRows.slice(1).forEach((cells, i) => {
    if (cells.every((c) => String(c).trim() === '')) return; // blank line
    const cell = (idx) => (idx >= 0 ? String(cells[idx] ?? '').trim() : '');
    rows.push({
      row: i + 2, // 1-based, header is row 1 - matches the line number in a spreadsheet
      item: cell(cols.item),
      variant: cell(cols.variant),
      warehouse: cell(cols.warehouse),
      quantity: cell(cols.quantity).replace(/,/g, '') // "1,250" -> 1250
    });
  });

  if (rows.length === 0) throw new Error('The file has no data rows.');
  return rows;
}

function setCountSummary(text, isError) {
  const el = document.getElementById('countSummary');
  el.textContent = text;
  el.classList.toggle('error-text', !!isError);
  el.classList.toggle('muted', !isError);
}

async function previewStockCount() {
  const file = document.getElementById('countFileInput').files[0];
  previewedCountRows = null;
  document.getElementById('countPostBtn').disabled = true;
  document.getElementById('countPreviewWrap').classList.add('hidden');

  if (!file) return setCountSummary('Choose a CSV file first.', true);

  let rows;
  try {
    rows = buildCountRows(parseCsv(await file.text()));
  } catch (err) {
    return setCountSummary(err.message, true);
  }

  setCountSummary('Checking ' + rows.length + ' row(s)...', false);
  const { data, error } = await supabaseClient.rpc('admin_apply_item_stock_count', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_rows: rows,
    p_posting_date: document.getElementById('countDateInput').value || todayIso(),
    p_reason: document.getElementById('countReasonInput').value.trim() || null,
    p_dry_run: true
  });

  if (error) return setCountSummary('Preview failed: ' + error.message, true);

  const results = data || [];
  const errors = results.filter((r) => r.error);
  const changes = results.filter((r) => !r.error && Number(r.difference) !== 0);
  const unchanged = results.length - errors.length - changes.length;

  // Errors first (they are what needs attention), then the rows that will change, then the rest.
  const ordered = [...errors, ...changes, ...results.filter((r) => !r.error && Number(r.difference) === 0)];
  const shown = ordered.slice(0, 1000);

  document.getElementById('countPreviewBody').innerHTML = shown.map((r) => {
    const diff = Number(r.difference || 0);
    const label = r.item_code
      ? escapeHtml(r.item_code) + (r.item_name && r.item_name !== r.item_code ? ' - ' + escapeHtml(r.item_name) : '') +
        (r.variant_name ? ' (' + escapeHtml(r.variant_name) + ')' : (r.variant_id ? ' (' + escapeHtml(r.variant_id) + ')' : ''))
      : escapeHtml(r.item_input || '') + (r.variant_input ? ' / ' + escapeHtml(r.variant_input) : '');
    const status = r.error
      ? '<span class="error-text">' + escapeHtml(r.error) + '</span>'
      : (diff === 0 ? '<span class="muted">No change</span>' : (diff > 0 ? 'Add' : 'Remove'));
    return '<tr>' +
      '<td>' + escapeHtml(String(r.row_no)) + '</td>' +
      '<td>' + label + '</td>' +
      '<td>' + escapeHtml(r.warehouse_name || r.warehouse_input || '') + '</td>' +
      '<td class="num">' + (r.counted_qty === null ? '' : formatQuantity(r.counted_qty)) + '</td>' +
      '<td class="num">' + (r.current_qty === null ? '' : formatQuantity(r.current_qty)) + '</td>' +
      '<td class="num" style="' + (diff < 0 ? 'color:var(--danger);' : '') + '">' + (r.error ? '' : formatSignedQuantity(diff)) + '</td>' +
      '<td>' + status + '</td>' +
    '</tr>';
  }).join('');
  document.getElementById('countPreviewWrap').classList.remove('hidden');

  const truncated = ordered.length > shown.length ? ' (showing the first ' + shown.length + ')' : '';
  if (errors.length > 0) {
    setCountSummary(errors.length + ' row(s) have errors - fix the file and preview again. Nothing can be posted until every row is valid.' + truncated, true);
    return;
  }

  previewedCountRows = rows;
  setCountSummary(
    results.length + ' row(s) OK: ' + changes.length + ' will change the ledger, ' + unchanged + ' already match.' + truncated,
    false
  );
  document.getElementById('countPostBtn').disabled = changes.length === 0;
}

async function postStockCount() {
  if (!previewedCountRows) return;
  const reason = document.getElementById('countReasonInput').value.trim();
  if (!reason) return setCountSummary('A reason is required.', true);

  if (!window.confirm('Post this stock count? The ledger will be adjusted to match the file. Entries are permanent (a mistake is corrected by reversing them).')) return;

  const btn = document.getElementById('countPostBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';

  const { error } = await supabaseClient.rpc('admin_apply_item_stock_count', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_rows: previewedCountRows,
    p_posting_date: document.getElementById('countDateInput').value || todayIso(),
    p_reason: reason,
    p_dry_run: false
  });

  btn.textContent = 'Post Count';

  if (error) {
    btn.disabled = false;
    return setCountSummary('Posting failed: ' + error.message, true);
  }

  previewedCountRows = null;
  document.getElementById('countPreviewWrap').classList.add('hidden');
  setCountSummary('Stock count posted.', false);
  await Promise.all([refreshAll(), loadSalesPostingStatus()]);
}

function downloadCountTemplate(event) {
  event.preventDefault();
  const csv = 'Item,Variant,Warehouse,Quantity\r\nITEM-CODE,,Main Warehouse,10\r\nITEM-WITH-VARIANTS,Blue,Main Warehouse,5\r\n';
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = 'stock-count-template.csv';
  a.click();
  URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------- sales posting switch

// Shown as BC's message bar under the action bar: an amber warning while sales are not yet reducing
// stock (the one thing that needs doing), a quiet blue info line once they are.
async function loadSalesPostingStatus() {
  const bar = document.getElementById('salesPostingBar');
  const statusEl = document.getElementById('salesPostingStatus');
  const btn = document.getElementById('startSalesPostingBtn');

  const { data, error } = await supabaseClient.rpc('admin_get_item_ledger_setup', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  bar.classList.remove('hidden');

  if (error) {
    bar.classList.add('bc-infobar-warn');
    statusEl.textContent = 'Could not load the sales posting status: ' + error.message;
    btn.classList.add('hidden');
    return;
  }

  const setup = Array.isArray(data) ? data[0] : data;
  if (setup?.sales_posting_start_utc) {
    bar.classList.remove('bc-infobar-warn');
    statusEl.textContent = 'Sales posting is on since ' + new Date(setup.sales_posting_start_utc).toLocaleString() +
      ' - every order confirmed from then on takes its stock out of the ledger automatically.';
    btn.classList.add('hidden');
  } else {
    bar.classList.add('bc-infobar-warn');
    statusEl.textContent = 'Sales are not reducing stock yet. Load your stock with a count first, then start posting sales: ' +
      'orders confirmed from that moment on take their stock out of the ledger (earlier orders are assumed to be in the stock you counted).';
    btn.classList.remove('hidden');
  }
}

async function startSalesPosting() {
  if (!window.confirm('Start posting sales from now? Orders confirmed from this moment take their stock out of the ledger. This can only be started once.')) return;

  const { error } = await supabaseClient.rpc('admin_start_item_ledger_sales_posting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    window.alert('Could not start: ' + error.message);
    return;
  }

  await loadSalesPostingStatus();
}

// ---------------------------------------------------------------- init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Item Ledger Entries');

  document.getElementById('adjDateInput').value = todayIso();
  document.getElementById('countDateInput').value = todayIso();
  document.getElementById('countPreviewBtn').addEventListener('click', previewStockCount);
  document.getElementById('countPostBtn').addEventListener('click', postStockCount);
  document.getElementById('countTemplateLink').addEventListener('click', downloadCountTemplate);
  document.getElementById('startSalesPostingBtn').addEventListener('click', startSalesPosting);
  // A different file invalidates whatever was previewed.
  document.getElementById('countFileInput').addEventListener('change', () => {
    previewedCountRows = null;
    document.getElementById('countPostBtn').disabled = true;
    document.getElementById('countPreviewWrap').classList.add('hidden');
    setCountSummary('', false);
  });

  // Default the ledger to the current month, which is what anyone opening it almost always wants.
  // The balance section reads its as-of date from the To field, so leaving To at today also keeps
  // it showing current stock.
  const today = new Date();
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
  document.getElementById('ileFromDate').value = new Date(monthStart.getTime() - monthStart.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  document.getElementById('ileToDate').value = todayIso();

  document.getElementById('ileRefreshBtn').addEventListener('click', () => {
    refreshAll();
  });

  // Every filter-pane field applies as soon as it changes, like BC's filter pane.
  for (const id of ['ileFromDate', 'ileToDate', 'ileWarehouseFilter', 'ileTypeFilter']) {
    document.getElementById(id).addEventListener('change', () => {
      ledgerPage = 1;
      balancePage = 1;
      refreshAll();
    });
  }

  document.querySelectorAll('.bc-tab').forEach((tab) => {
    tab.addEventListener('click', () => setView(tab.dataset.view));
  });

  document.getElementById('filterPaneBtn').addEventListener('click', () => {
    filterPaneOpen = !filterPaneOpen;
    updateBodyLayout();
  });
  document.getElementById('clearFiltersBtn').addEventListener('click', clearFilters);
  document.getElementById('filterChips').addEventListener('click', (event) => {
    const btn = event.target.closest('[data-clear-filter]');
    if (btn) clearOneFilter(btn.dataset.clearFilter);
  });
  document.getElementById('clearFiltersLink').addEventListener('click', clearFilters);

  // Action bar -> dialogs.
  document.getElementById('newAdjBtn').addEventListener('click', () => {
    document.getElementById('adjMessage').classList.add('hidden');
    showDialog('adjDialog');
    document.getElementById('adjItemInput').focus();
  });
  document.getElementById('countBtn').addEventListener('click', () => showDialog('countDialog'));
  document.getElementById('reverseBtn').addEventListener('click', openReverseDialog);
  document.getElementById('showDocBtn').addEventListener('click', showLinkedDocument);
  document.getElementById('reverseConfirmBtn').addEventListener('click', confirmReverse);
  document.getElementById('reverseReasonInput').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') confirmReverse();
  });

  document.querySelectorAll('[data-close-dialog]').forEach((el) => {
    el.addEventListener('click', () => el.closest('.bc-dialog-backdrop').classList.add('hidden'));
  });
  document.querySelectorAll('.bc-dialog-backdrop').forEach((backdrop) => {
    // A click on the dimmed area (not the dialog itself) closes it - except the stock count, where a
    // stray click would throw away a previewed file.
    backdrop.addEventListener('mousedown', (event) => {
      if (event.target === backdrop && backdrop.id !== 'countDialog') backdrop.classList.add('hidden');
    });
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && anyDialogOpen()) {
      closeAllDialogs();
      return;
    }
    if (anyDialogOpen() || activeView !== 'ledger') return;
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    if (event.target && event.target.closest && event.target.closest('input, select, textarea, button')) return;
    event.preventDefault();
    moveSelection(event.key === 'ArrowDown' ? 1 : -1);
  });

  document.getElementById('ileSearchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => {
      ledgerPage = 1;
      balancePage = 1;
      refreshAll();
    }, 300);
  });

  document.getElementById('ileTableBody').addEventListener('click', (event) => {
    const drill = event.target.closest('[data-drill-item]');
    if (drill) {
      drillToLedger(drill.dataset.drillItem);
      return;
    }
    const row = event.target.closest('tr[data-entry-no]');
    if (row) selectEntry(Number(row.dataset.entryNo));
  });
  document.getElementById('balTableBody').addEventListener('click', (event) => {
    const drill = event.target.closest('[data-drill-item]');
    if (drill) drillToLedger(drill.dataset.drillItem);
  });

  document.getElementById('balCombineVariants').addEventListener('change', () => {
    balancePage = 1;
    loadBalances();
  });

  updateBodyLayout();
  updateActionState();

  // ?search=ITEM-CODE deep link (e.g. from an item's page): opens the ledger already filtered to
  // that item, across all time rather than just this month, since the point of arriving this way
  // is to see that item's whole history.
  const linkedSearch = new URLSearchParams(window.location.search).get('search');
  if (linkedSearch) {
    document.getElementById('ileSearchInput').value = linkedSearch;
    document.getElementById('ileFromDate').value = '';
  }

  document.getElementById('adjItemInput').addEventListener('input', () => {
    // Typing invalidates any earlier selection until it matches a code again.
    selectedItemCode = null;
    clearTimeout(itemSearchDebounceHandle);
    itemSearchDebounceHandle = setTimeout(async () => {
      await searchItemsForAdjustment();
      await resolveSelectedItem();
    }, 250);
  });
  document.getElementById('adjItemInput').addEventListener('change', resolveSelectedItem);
  document.getElementById('postAdjustmentBtn').addEventListener('click', postAdjustment);

  let resizeDebounce = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeDebounce);
    resizeDebounce = setTimeout(fitActiveGrid, 100);
  });

  await loadWarehouses();
  // ?warehouse=ID deep link (Item Setup's Stock by Location numbers) - pairs with ?search= above.
  const linkedWarehouse = new URLSearchParams(window.location.search).get('warehouse');
  if (linkedWarehouse) document.getElementById('ileWarehouseFilter').value = linkedWarehouse;
  await Promise.all([refreshAll(), loadSalesPostingStatus()]);
})();
