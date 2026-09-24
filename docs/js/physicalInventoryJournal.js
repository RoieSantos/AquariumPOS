// Physical Inventory Journal - a Business Central-style worksheet for doing a physical count.
// Laid out like the Item Ledger Entries page (css/bc-list.css): title bar + search, action bar, a
// batch-name strip (BC keeps the journal's Batch Name as a plain field, not a list filter), the
// lines grid with an inline-editable "Qty. (Phys. Inventory)" cell, and a FactBox with the selected
// line's details + current availability. See supabase_item_ledger_phys_inventory_journal.sql for
// the model and, in particular, why "Quantity" always diffs against the LIVE ledger balance rather
// than the frozen "Qty. (Calculated)" the way literal BC does.
//
// Nothing here writes to the ledger directly except Post (admin_post_phys_inventory_journal), which
// re-checks the caller is a super user. Everything else (Calculate, New Line, editing a count,
// Delete Line) only touches the worksheet table, which isn't the ledger itself.
let currentSession = null;
let currentBatch = 'DEFAULT';
let journalRows = []; // the whole batch, as last loaded - filtered client-side by the search box
let selectedLineId = null;
let factBoxToken = 0;
let sortKey = null; // null = natural order (item_name, variant_name, warehouse_name - same as the server's own ORDER BY)
let sortDir = 1; // 1 = ascending, -1 = descending

let newLineItemSearchResults = [];
let newLineSelectedItemCode = null;
let newLineSelectedItemHasVariants = false;
let newLineItemSearchDebounce = null;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatQuantity(value) {
  if (value === null || value === undefined || value === '') return '';
  const n = Number(value);
  if (Number.isNaN(n)) return '';
  return Number.isInteger(n) ? String(n) : String(parseFloat(n.toFixed(4)));
}

function todayIso() {
  const d = new Date();
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

// Makes the grid fill the rest of the viewport instead of stopping at a guessed height and leaving
// a slab of empty page below it (or, on a short screen, clipping) - the .bc-grid-wrap CSS max-height
// is only a pre-JS fallback. Re-measures from the element's actual position, so it's correct no
// matter what's above it or how tall the window is.
function fitGridToViewport(el, minPx) {
  if (!el) return;
  const top = el.getBoundingClientRect().top;
  const available = window.innerHeight - top - 16; // small breathing room at the bottom edge
  el.style.maxHeight = Math.max(minPx || 240, available) + 'px';
}

function fitJournalGrid() {
  fitGridToViewport(document.getElementById('journalGridWrap'));
}

function showDialog(id) { document.getElementById(id).classList.remove('hidden'); }
function hideDialog(id) { document.getElementById(id).classList.add('hidden'); }
function closeAllDialogs() { document.querySelectorAll('.bc-dialog-backdrop').forEach((d) => d.classList.add('hidden')); }
function anyDialogOpen() { return !!document.querySelector('.bc-dialog-backdrop:not(.hidden)'); }

function itemLabel(row) {
  const name = row.item_name && row.item_name !== row.item_code ? ` - ${row.item_name}` : '';
  const variant = row.variant_name ? ` (${row.variant_name})` : (row.variant_id ? ` (${row.variant_id})` : '');
  return `${row.item_code}${name}${variant}`;
}

// ---------------------------------------------------------------- warehouses / categories

async function loadWarehouses() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error) { console.error('staff_search_warehouses failed:', error); return; }

  const options = (data || []).map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
  document.getElementById('calcWarehouseSelect').innerHTML = '<option value="">Select a location...</option>' + options;
  document.getElementById('newLineWarehouseSelect').innerHTML = '<option value="">Select a location...</option>' + options;
}

async function loadCategories() {
  const { data, error } = await supabaseClient.rpc('staff_list_stock_sync_categories', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) { console.error('staff_list_stock_sync_categories failed:', error); return; }

  const options = (data || []).map((c) => `<option value="${escapeHtml(c.code)}">${escapeHtml(c.description || c.code)}</option>`).join('');
  document.getElementById('calcCategorySelect').innerHTML = '<option value="">(all)</option>' + options;
}

// ---------------------------------------------------------------- batches

async function loadBatches(preferMostRecent) {
  const { data, error } = await supabaseClient.rpc('admin_list_phys_journal_batches', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) { console.error('admin_list_phys_journal_batches failed:', error); return; }

  const batches = data || [];
  document.getElementById('batchNameList').innerHTML = batches
    .map((b) => `<option value="${escapeHtml(b.batch_name)}"></option>`).join('');

  if (preferMostRecent && batches.length > 0) {
    currentBatch = batches[0].batch_name;
    document.getElementById('batchNameInput').value = currentBatch;
  }
}

function setBatchProgress() {
  const total = journalRows.length;
  const counted = journalRows.filter((r) => r.qty_counted !== null && r.qty_counted !== undefined).length;
  document.getElementById('batchProgress').innerHTML = total === 0
    ? 'No lines yet - use Calculate Inventory or New Line to start.'
    : `<strong>${counted}</strong> of <strong>${total}</strong> line(s) counted`;
}

// ---------------------------------------------------------------- lines grid

function selectedLine() {
  return journalRows.find((r) => r.line_id === selectedLineId) || null;
}

const NUMERIC_SORT_KEYS = new Set(['qty_calculated', 'qty_counted', 'quantity']);

function filteredRows() {
  const q = document.getElementById('lineSearchInput').value.trim().toLowerCase();
  const rows = !q ? journalRows : journalRows.filter((r) =>
    (r.item_code || '').toLowerCase().includes(q) ||
    (r.item_name || '').toLowerCase().includes(q) ||
    (r.variant_name || '').toLowerCase().includes(q) ||
    (r.sku || '').toLowerCase().includes(q) ||
    (r.warehouse_name || '').toLowerCase().includes(q)
  );
  return sortKey ? sortRows(rows) : rows;
}

// Keeps the Search box's clear (x) button and live "N of M" result count in sync with what's
// currently typed - matching_count is filteredRows().length, passed in so renderGrid() (which
// already computed it) doesn't need to filter twice.
function updateSearchUI(matchingCount) {
  const input = document.getElementById('lineSearchInput');
  const hasQuery = input.value.trim() !== '';
  document.getElementById('lineSearchClearBtn').classList.toggle('hidden', !hasQuery);
  document.getElementById('lineSearchCount').textContent =
    hasQuery && journalRows.length > 0 ? `${matchingCount} of ${journalRows.length}` : '';
}

function clearLineSearch() {
  const input = document.getElementById('lineSearchInput');
  if (input.value === '') return;
  input.value = '';
  renderGrid();
}

// Click a column header to sort by it (BC-style); click the same header again to reverse. Blank/
// null always sorts to the bottom regardless of direction, so an empty "Qty. (Phys. Inventory)"
// column doesn't scatter counted rows to the top on descending.
function sortRows(rows) {
  const numeric = NUMERIC_SORT_KEYS.has(sortKey);
  return [...rows].sort((a, b) => {
    const av = a[sortKey];
    const bv = b[sortKey];
    const aBlank = av === null || av === undefined || av === '';
    const bBlank = bv === null || bv === undefined || bv === '';
    if (aBlank && bBlank) return 0;
    if (aBlank) return 1;
    if (bBlank) return -1;
    const cmp = numeric ? Number(av) - Number(bv) : String(av).localeCompare(String(bv), undefined, { sensitivity: 'base' });
    return cmp * sortDir;
  });
}

function setSort(key) {
  if (sortKey === key) {
    sortDir = -sortDir;
  } else {
    sortKey = key;
    sortDir = 1;
  }
  updateSortHeaders();
  renderGrid();
}

function updateSortHeaders() {
  document.querySelectorAll('#journalHeaderRow th.sortable').forEach((th) => {
    th.classList.remove('sort-asc', 'sort-desc');
    const arrow = th.querySelector('.sort-arrow');
    if (th.dataset.sortKey === sortKey) {
      th.classList.add(sortDir > 0 ? 'sort-asc' : 'sort-desc');
      if (arrow) arrow.textContent = sortDir > 0 ? '▲' : '▼';
    } else if (arrow) {
      arrow.textContent = '';
    }
  });
}

function updateActionState() {
  document.getElementById('deleteLineBtn').disabled = !selectedLineId;
  document.getElementById('clearAllBtn').disabled = journalRows.length === 0;
  document.getElementById('printBtn').disabled = journalRows.length === 0;
  document.getElementById('postBtn').disabled = journalRows.every((r) => r.qty_counted === null || r.qty_counted === undefined);
}

async function loadLines() {
  const body = document.getElementById('journalTableBody');
  const errorBox = document.getElementById('journalError');
  // Reset fully, not just hide - a stale success/error style must not silently carry over and
  // colour the next notice this box is used for.
  errorBox.classList.add('hidden');
  errorBox.classList.remove('success-text', 'error-text');
  errorBox.textContent = '';
  body.innerHTML = '<tr><td colspan="8" class="cell-msg">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_get_phys_journal_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_batch_name: currentBatch
  });

  if (error) {
    journalRows = [];
    body.innerHTML = `<tr><td colspan="8" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    updateSearchUI(0);
    setBatchProgress();
    updateActionState();
    renderFactBox();
    fitJournalGrid();
    return;
  }

  journalRows = data || [];
  if (!journalRows.some((r) => r.line_id === selectedLineId)) selectedLineId = null;
  renderGrid();
  setBatchProgress();
  updateActionState();
  renderFactBox();
  fitJournalGrid();
}

function renderGrid() {
  const body = document.getElementById('journalTableBody');
  const rows = filteredRows();
  updateSearchUI(rows.length);

  if (journalRows.length === 0) {
    body.innerHTML = '<tr><td colspan="8" class="cell-msg">Choose or type a batch name, then Calculate Inventory to begin.</td></tr>';
    return;
  }
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="8" class="cell-msg">No lines match this search.</td></tr>';
    return;
  }

  body.innerHTML = rows.map((r) => {
    const qty = r.quantity;
    const qtyText = qty === null || qty === undefined ? '' : formatQuantity(qty);
    const qtyNeg = qty !== null && qty !== undefined && Number(qty) < 0;
    const counted = r.qty_counted === null || r.qty_counted === undefined ? '' : formatQuantity(r.qty_counted);
    return `
      <tr class="${r.line_id === selectedLineId ? 'selected' : ''}" data-line-id="${r.line_id}">
        <td>${escapeHtml(r.item_code)}</td>
        <td class="cell-text" title="${escapeHtml(r.item_name || '')}">${escapeHtml(r.item_name || '')}</td>
        <td class="cell-text" title="${escapeHtml(r.variant_name || '')}">${escapeHtml(r.variant_name || '')}</td>
        <td>${escapeHtml(r.sku || '')}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td class="num calc-only">${formatQuantity(r.qty_calculated)}</td>
        <td class="num qty-cell-wrap">
          <input type="number" class="bc-qty-cell" min="0" step="any" data-qty-line-id="${r.line_id}" value="${escapeHtml(counted)}" placeholder="-" />
        </td>
        <td class="num calc-only ${qtyNeg ? 'neg' : ''}">${qtyText}</td>
      </tr>`;
  }).join('');
}

function selectLine(lineId) {
  selectedLineId = lineId;
  document.querySelectorAll('#journalTableBody tr[data-line-id]').forEach((tr) => {
    tr.classList.toggle('selected', Number(tr.dataset.lineId) === lineId);
  });
  updateActionState();
  renderFactBox();
}

function moveSelection(step) {
  const rows = filteredRows();
  if (rows.length === 0) return;
  const idx = rows.findIndex((r) => r.line_id === selectedLineId);
  const next = idx < 0 ? (step > 0 ? 0 : rows.length - 1) : Math.min(Math.max(idx + step, 0), rows.length - 1);
  selectLine(rows[next].line_id);
  document.querySelector(`#journalTableBody tr[data-line-id="${rows[next].line_id}"]`)?.scrollIntoView({ block: 'nearest' });
}

// The inline "type a count into the cell" edit. moveToNext focuses the next visible row's qty cell
// afterwards (Enter, like tabbing down a BC datasheet).
async function saveQtyCell(lineId, rawValue, moveToNext) {
  const row = journalRows.find((r) => r.line_id === lineId);
  const input = document.querySelector(`input[data-qty-line-id="${lineId}"]`);
  const text = String(rawValue ?? '').trim();
  const value = text === '' ? null : Number(text);

  if (value !== null && (Number.isNaN(value) || value < 0)) {
    window.alert('Enter a count of 0 or more, or leave it blank.');
    if (input) input.value = row && row.qty_counted !== null && row.qty_counted !== undefined ? formatQuantity(row.qty_counted) : '';
    return;
  }

  const { error } = await supabaseClient.rpc('admin_set_phys_journal_qty', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: lineId,
    p_qty_counted: value
  });

  if (error) {
    window.alert('Could not save that count: ' + error.message);
    if (input) input.value = row && row.qty_counted !== null && row.qty_counted !== undefined ? formatQuantity(row.qty_counted) : '';
    return;
  }

  if (row) {
    row.qty_counted = value;
    row.quantity = value === null ? null : value - Number(row.qty_current || 0);
  }
  renderGrid();
  setBatchProgress();
  updateActionState();
  if (selectedLineId === lineId) renderFactBox();

  if (moveToNext) {
    const rows = filteredRows();
    const idx = rows.findIndex((r) => r.line_id === lineId);
    const next = rows[idx + 1];
    if (next) {
      selectLine(next.line_id);
      const nextInput = document.querySelector(`input[data-qty-line-id="${next.line_id}"]`);
      nextInput?.focus();
      nextInput?.select();
    }
  }
}

// ---------------------------------------------------------------- FactBox

function renderFactBox() {
  const details = document.getElementById('factDetails');
  const availBox = document.getElementById('factAvailBox');
  const r = selectedLine();
  const token = ++factBoxToken;

  if (!r) {
    details.innerHTML = '<p class="bc-fact-empty">Select a line to see its details.</p>';
    availBox.classList.add('hidden');
    return;
  }

  const facts = [
    ['Item No.', r.item_code],
    ['Description', r.item_name && r.item_name !== r.item_code ? r.item_name : ''],
    ['Variant', r.variant_name || r.variant_id || ''],
    ['SKU', r.sku || ''],
    ['Location Code', r.warehouse_name],
    ...(currentSession.isSuperUser ? [
      ['Qty. (Calculated)', formatQuantity(r.qty_calculated)],
      ['Qty. (Current)', formatQuantity(r.qty_current)]
    ] : []),
    ['Qty. (Phys. Inventory)', r.qty_counted === null || r.qty_counted === undefined ? 'Not counted yet' : formatQuantity(r.qty_counted)],
    ...(currentSession.isSuperUser ? [['Quantity to post', r.quantity === null || r.quantity === undefined ? '' : formatQuantity(r.quantity)]] : []),
    ['Last Updated', r.updated_at_utc ? new Date(r.updated_at_utc).toLocaleString() : ''],
    ['Updated By', r.updated_by]
  ].filter(([, v]) => v !== '' && v !== null && v !== undefined);

  details.innerHTML = '<dl class="bc-facts">' +
    facts.map(([k, v]) => `<dt>${escapeHtml(k)}</dt><dd>${escapeHtml(v)}</dd>`).join('') +
    '</dl>';

  loadItemAvailability(r.item_code, token);
}

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

  if (token !== factBoxToken) return;
  if (error) { body.innerHTML = `<p class="bc-fact-empty">${escapeHtml(error.message)}</p>`; return; }

  const rows = (data || []).filter((r) => r.item_code === itemCode);
  if (rows.length === 0) { body.innerHTML = '<p class="bc-fact-empty">Nothing on hand.</p>'; return; }

  const total = rows.reduce((sum, r) => sum + Number(r.balance || 0), 0);
  body.innerHTML = '<table class="bc-avail">' +
    rows.map((r) => {
      const bal = Number(r.balance || 0);
      return `<tr><td>${escapeHtml(r.warehouse_name || '')}</td><td class="${bal < 0 ? 'neg' : ''}">${formatQuantity(bal)}</td></tr>`;
    }).join('') +
    `<tr class="total"><td>Inventory</td><td>${formatQuantity(total)}</td></tr>` +
    '</table>';
}

// ---------------------------------------------------------------- Print (count sheet)

// Builds a printable count sheet from the currently loaded/filtered/sorted rows (i.e. exactly
// what's on screen) and prints it - a plain browser print rather than a PDF/report, so it uses
// whatever printer the browser already has configured. Qty. (Calculated) is the frozen reference
// figure from the last Calculate Inventory; a blank handwritten line is included next to it so this
// also works as a paper count sheet to walk the shop with, the same way BC's own printed physical
// inventory journal report does.
function printJournal() {
  const rows = filteredRows();
  if (rows.length === 0) return;

  const warehouseNames = [...new Set(rows.map((r) => r.warehouse_name).filter(Boolean))];
  const printedAt = new Date().toLocaleString();

  const rowsHtml = rows.map((r) => `
    <tr>
      <td>${escapeHtml(r.item_code)}</td>
      <td>${escapeHtml(r.item_name || '')}</td>
      <td>${escapeHtml(r.variant_name || '')}</td>
      <td>${escapeHtml(r.sku || '')}</td>
      <td>${escapeHtml(r.warehouse_name || '')}</td>
      ${currentSession.isSuperUser ? `<td class="num">${formatQuantity(r.qty_calculated)}</td>` : ''}
      <td class="blank-cell"></td>
    </tr>`).join('');

  document.getElementById('printArea').innerHTML = `
    <h1>Physical Inventory Journal - Count Sheet</h1>
    <table class="print-meta">
      <tr><td>Batch Name</td><td>${escapeHtml(currentBatch)}</td></tr>
      <tr><td>Location(s)</td><td>${escapeHtml(warehouseNames.join(', ') || '-')}</td></tr>
      <tr><td>Line Count</td><td>${rows.length}</td></tr>
      <tr><td>Printed</td><td>${escapeHtml(printedAt)}</td></tr>
    </table>
    <table class="print-lines">
      <thead>
        <tr>
          <th>Item No.</th><th>Description</th><th>Variant</th><th>SKU</th><th>Location</th>
          ${currentSession.isSuperUser ? '<th class="num">Qty. (Calculated)</th>' : ''}<th>Qty. (Phys. Inventory)</th>
        </tr>
      </thead>
      <tbody>${rowsHtml}</tbody>
    </table>
    <p class="print-sign">Counted By: ________________________&nbsp;&nbsp;&nbsp;&nbsp;Date: ________________</p>`;

  window.print();
}

// ---------------------------------------------------------------- Calculate Inventory dialog

function openCalcDialog() {
  document.getElementById('calcMessage').classList.add('hidden');
  showDialog('calcDialog');
}

async function confirmCalculate() {
  const warehouseId = document.getElementById('calcWarehouseSelect').value;
  const msg = document.getElementById('calcMessage');
  msg.classList.remove('error-text');
  msg.classList.add('muted');

  if (!currentBatch) { msg.textContent = 'Type a batch name first.'; msg.classList.add('error-text'); msg.classList.remove('hidden'); return; }
  if (!warehouseId) { msg.textContent = 'Pick a location.'; msg.classList.add('error-text'); msg.classList.remove('hidden'); return; }

  const btn = document.getElementById('calcConfirmBtn');
  btn.disabled = true;
  btn.textContent = 'Calculating...';

  const fromPancake = document.getElementById('calcFromPancakeInput').checked;

  const { data, error } = await supabaseClient.rpc('admin_calculate_phys_inventory', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_batch_name: currentBatch,
    p_warehouse_id: warehouseId,
    p_category_code: document.getElementById('calcCategorySelect').value || null,
    p_search: document.getElementById('calcSearchInput').value.trim() || null,
    p_only_stock_sync_categories: document.getElementById('calcStockSyncOnlyInput').checked
  });

  if (error) {
    btn.disabled = false;
    btn.textContent = 'Calculate';
    msg.textContent = 'Calculate failed: ' + error.message;
    msg.classList.add('error-text');
    msg.classList.remove('hidden');
    return;
  }

  msg.textContent = `${data ?? 0} line(s) added or refreshed. You can calculate again (e.g. another category or location) into the same batch.`;
  msg.classList.remove('error-text', 'hidden');
  await Promise.all([loadLines(), loadBatches(false)]);

  if (fromPancake) {
    await refreshCalculatedQtyFromPancake(warehouseId, msg);
  }

  btn.disabled = false;
  btn.textContent = 'Calculate';
}

// Reads live Pancake stock for the just-calculated location and overwrites Qty. (Calculated) with
// it, one Pancake PRODUCT per RPC call (not one big loop inside a single call - that's what caused
// the statement timeout; see supabase_phys_journal_calculate_from_pancake_fix.sql). Only touches
// lines that still have no count yet, same "frozen once counted" rule Calculate Inventory itself
// follows. Best-effort: a product Pancake doesn't answer for just keeps its ledger-based figure.
async function refreshCalculatedQtyFromPancake(warehouseId, msg) {
  const candidates = journalRows.filter((r) =>
    r.warehouse_id === warehouseId &&
    (r.qty_counted === null || r.qty_counted === undefined) &&
    r.product_id
  );
  const productIds = [...new Set(candidates.map((r) => r.product_id))];
  if (productIds.length === 0) return;

  let done = 0;
  let updatedTotal = 0;
  let pendingUpdates = [];

  const flush = async () => {
    if (pendingUpdates.length === 0) return;
    const { error } = await supabaseClient.rpc('admin_apply_phys_journal_calculated_qty', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_batch_name: currentBatch,
      p_updates: pendingUpdates
    });
    if (!error) updatedTotal += pendingUpdates.length;
    pendingUpdates = [];
  };

  for (const productId of productIds) {
    msg.textContent = `Fetching live Pancake stock... ${done}/${productIds.length} product(s)`;
    msg.classList.remove('error-text', 'hidden');

    const { data: stockRows, error: stockError } = await supabaseClient.rpc('admin_get_pancake_stock_for_product', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_product_id: productId
    });
    done++;

    if (!stockError && stockRows) {
      for (const line of candidates.filter((r) => r.product_id === productId)) {
        const match = stockRows.find((s) =>
          s.warehouse_id === warehouseId &&
          (s.variation_id === line.pancake_variation_id || (!s.variation_id && !line.pancake_variation_id))
        );
        if (match && match.remain_quantity !== null && match.remain_quantity !== undefined) {
          pendingUpdates.push({ line_id: line.line_id, qty: match.remain_quantity });
        }
      }
    }

    if (pendingUpdates.length >= 20) await flush();
  }
  await flush();

  msg.textContent = `${updatedTotal} line(s) updated with live Pancake stock (of ${productIds.length} product(s) checked). ` +
    'You can calculate again (e.g. another category or location) into the same batch.';
  msg.classList.remove('error-text', 'hidden');
  await loadLines();
}

// ---------------------------------------------------------------- New Line dialog

function openNewLineDialog() {
  document.getElementById('newLineItemInput').value = '';
  document.getElementById('newLineVariantRow').classList.add('hidden');
  document.getElementById('newLineVariantSelect').innerHTML = '';
  document.getElementById('newLineMessage').classList.add('hidden');
  newLineSelectedItemCode = null;
  newLineSelectedItemHasVariants = false;
  showDialog('newLineDialog');
  document.getElementById('newLineItemInput').focus();
}

async function searchItemsForNewLine() {
  const text = document.getElementById('newLineItemInput').value.trim();
  if (!text) {
    newLineItemSearchResults = [];
    document.getElementById('newLineItemList').innerHTML = '';
    return;
  }

  const { data, error } = await supabaseClient.rpc('admin_list_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: text,
    p_page: 1,
    p_page_size: 20
  });
  if (error) { console.error('admin_list_items failed:', error); return; }

  newLineItemSearchResults = (data || []).map((i) => ({ code: i.code, name: i.name || i.description || i.code }));
  document.getElementById('newLineItemList').innerHTML = newLineItemSearchResults
    .map((i) => `<option value="${escapeHtml(i.code)}">${escapeHtml(i.name)}</option>`).join('');
}

async function resolveNewLineItem() {
  const typed = document.getElementById('newLineItemInput').value.trim();
  const match = newLineItemSearchResults.find((i) => i.code === typed);
  const variantRow = document.getElementById('newLineVariantRow');
  const variantSelect = document.getElementById('newLineVariantSelect');

  newLineSelectedItemCode = match ? match.code : null;
  newLineSelectedItemHasVariants = false;
  variantRow.classList.add('hidden');
  variantSelect.innerHTML = '';
  if (!newLineSelectedItemCode) return;

  const { data, error } = await supabaseClient.rpc('admin_list_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_main_item_code: newLineSelectedItemCode,
    p_page: 1,
    p_page_size: 200
  });
  if (error) { console.error('admin_list_variants failed:', error); return; }
  if (newLineSelectedItemCode !== match.code) return;

  const variants = data || [];
  if (variants.length === 0) return;

  newLineSelectedItemHasVariants = true;
  variantSelect.innerHTML = '<option value="">Select a variant...</option>' + variants
    .map((v) => `<option value="${escapeHtml(v.variation_id)}">${escapeHtml(v.variant_name || v.sku || v.variation_id)}</option>`).join('');
  variantRow.classList.remove('hidden');
}

async function confirmNewLine() {
  const warehouseId = document.getElementById('newLineWarehouseSelect').value;
  const variantId = document.getElementById('newLineVariantSelect').value;
  const msg = document.getElementById('newLineMessage');
  msg.classList.add('hidden');

  if (!currentBatch) return showNewLineError('Type a batch name first.');
  if (!newLineSelectedItemCode) return showNewLineError('Pick an item from the suggestions first.');
  if (newLineSelectedItemHasVariants && !variantId) return showNewLineError('This item has variants - pick which one.');
  if (!warehouseId) return showNewLineError('Pick a location.');

  const btn = document.getElementById('newLineConfirmBtn');
  btn.disabled = true;
  btn.textContent = 'Adding...';

  const { data, error } = await supabaseClient.rpc('admin_add_phys_journal_line', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_batch_name: currentBatch,
    p_item_code: newLineSelectedItemCode,
    p_variant_id: variantId || null,
    p_warehouse_id: warehouseId
  });

  btn.disabled = false;
  btn.textContent = 'Add';

  if (error) return showNewLineError('Could not add that line: ' + error.message);

  const result = Array.isArray(data) ? data[0] : data;
  hideDialog('newLineDialog');
  await Promise.all([loadLines(), loadBatches(false)]);
  if (result?.line_id) selectLine(result.line_id);
}

function showNewLineError(text) {
  const msg = document.getElementById('newLineMessage');
  msg.textContent = text;
  msg.classList.remove('hidden');
}

// ---------------------------------------------------------------- Delete Line

async function deleteSelectedLine() {
  const r = selectedLine();
  if (!r) return;
  if (!window.confirm(`Remove ${itemLabel(r)} at ${r.warehouse_name || ''} from this worksheet? This only removes it from the count - it does not touch the ledger.`)) return;

  const { error } = await supabaseClient.rpc('admin_delete_phys_journal_line', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_line_id: r.line_id
  });
  if (error) { window.alert('Could not delete that line: ' + error.message); return; }

  selectedLineId = null;
  await Promise.all([loadLines(), loadBatches(false)]);
}

// Clears the whole batch in one go - e.g. Calculate Inventory was run with too wide a filter and
// the worksheet needs a redo. Never touches the ledger; only unposted lines exist here in the first
// place, so nothing this deletes has ever moved stock.
async function deleteAllLines() {
  if (journalRows.length === 0) return;

  const counted = journalRows.filter((r) => r.qty_counted !== null && r.qty_counted !== undefined).length;
  const warn = counted > 0 ? ` This includes ${counted} line(s) that already have a count entered - those counts will be lost.` : '';
  if (!window.confirm(`Remove all ${journalRows.length} line(s) from batch "${currentBatch}"?${warn} This only clears the worksheet - it does not touch the ledger.`)) return;

  const btn = document.getElementById('clearAllBtn');
  btn.disabled = true;

  const { error } = await supabaseClient.rpc('admin_clear_phys_journal_batch', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_batch_name: currentBatch
  });

  if (error) {
    btn.disabled = journalRows.length === 0;
    window.alert('Could not clear the worksheet: ' + error.message);
    return;
  }

  selectedLineId = null;
  await Promise.all([loadLines(), loadBatches(false)]);
}

// ---------------------------------------------------------------- Post dialog

async function openPostDialog() {
  document.getElementById('postDateInput').value = todayIso();
  document.getElementById('postReasonInput').value = '';
  document.getElementById('postMessage').classList.add('hidden');
  document.getElementById('postConfirmBtn').disabled = true;
  document.getElementById('postSummary').textContent = 'Checking...';
  showDialog('postDialog');

  const { data, error } = await supabaseClient.rpc('admin_post_phys_inventory_journal', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_batch_name: currentBatch,
    p_posting_date: document.getElementById('postDateInput').value,
    p_reason: null,
    p_dry_run: true
  });

  if (error) {
    document.getElementById('postSummary').textContent = error.message;
    return;
  }

  const rows = data || [];
  const toPost = rows.filter((r) => Number(r.quantity) !== 0);
  const matching = rows.length - toPost.length;
  document.getElementById('postSummary').innerHTML =
    `<strong>${toPost.length}</strong> line(s) will post a stock difference. ` +
    `<strong>${matching}</strong> line(s) already match and will just be cleared from the worksheet. ` +
    `Both kinds are removed from this worksheet once posted; anything not yet counted stays.`;
  document.getElementById('postConfirmBtn').disabled = false;
}

async function confirmPost() {
  const reason = document.getElementById('postReasonInput').value.trim();
  const msg = document.getElementById('postMessage');
  if (!reason) {
    msg.textContent = 'A reason is required.';
    msg.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('postConfirmBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';

  const { error } = await supabaseClient.rpc('admin_post_phys_inventory_journal', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_batch_name: currentBatch,
    p_posting_date: document.getElementById('postDateInput').value || todayIso(),
    p_reason: reason,
    p_dry_run: false
  });

  btn.disabled = false;
  btn.textContent = 'Post';

  if (error) {
    msg.textContent = 'Posting failed: ' + error.message;
    msg.classList.remove('hidden');
    return;
  }

  hideDialog('postDialog');
  selectedLineId = null;
  // Shown only after the reload below - loadLines() resets this box at the start of every call, so
  // setting it before that call would just have it immediately hidden again.
  await Promise.all([loadLines(), loadBatches(false)]);
  const notice = document.getElementById('journalError');
  notice.textContent = 'Posted. The counted lines have been cleared from this worksheet.';
  notice.classList.remove('error-text', 'hidden');
  notice.classList.add('success-text');
}

// ---------------------------------------------------------------- init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  // Blind count for everyone but a Super User (CSS hides every .calc-only column).
  document.body.classList.toggle('hide-calc', !session.isSuperUser);
  renderTopNav('Physical Inventory Journal');

  document.getElementById('calcBtn').addEventListener('click', openCalcDialog);
  document.getElementById('calcConfirmBtn').addEventListener('click', confirmCalculate);
  document.getElementById('newLineBtn').addEventListener('click', openNewLineDialog);
  document.getElementById('newLineConfirmBtn').addEventListener('click', confirmNewLine);
  document.getElementById('deleteLineBtn').addEventListener('click', deleteSelectedLine);
  document.getElementById('clearAllBtn').addEventListener('click', deleteAllLines);
  document.getElementById('postBtn').addEventListener('click', openPostDialog);
  document.getElementById('postConfirmBtn').addEventListener('click', confirmPost);
  document.getElementById('journalRefreshBtn').addEventListener('click', () => loadLines());
  document.getElementById('printBtn').addEventListener('click', printJournal);

  document.getElementById('newLineItemInput').addEventListener('input', () => {
    newLineSelectedItemCode = null;
    clearTimeout(newLineItemSearchDebounce);
    newLineItemSearchDebounce = setTimeout(async () => {
      await searchItemsForNewLine();
      await resolveNewLineItem();
    }, 250);
  });
  document.getElementById('newLineItemInput').addEventListener('change', resolveNewLineItem);

  document.querySelectorAll('[data-close-dialog]').forEach((el) => {
    el.addEventListener('click', () => el.closest('.bc-dialog-backdrop').classList.add('hidden'));
  });
  document.querySelectorAll('.bc-dialog-backdrop').forEach((backdrop) => {
    backdrop.addEventListener('mousedown', (event) => {
      if (event.target === backdrop) backdrop.classList.add('hidden');
    });
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && anyDialogOpen()) { closeAllDialogs(); return; }
    if (anyDialogOpen()) return;
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    if (event.target && event.target.closest && event.target.closest('input, select, textarea, button')) return;
    event.preventDefault();
    moveSelection(event.key === 'ArrowDown' ? 1 : -1);
  });

  document.getElementById('batchNameInput').addEventListener('change', () => {
    const v = document.getElementById('batchNameInput').value.trim() || 'DEFAULT';
    document.getElementById('batchNameInput').value = v;
    currentBatch = v;
    selectedLineId = null;
    loadLines();
  });

  document.getElementById('lineSearchInput').addEventListener('input', () => {
    renderGrid();
  });
  document.getElementById('lineSearchInput').addEventListener('keydown', (event) => {
    // Enter jumps to (and selects) the first matching line, like BC's quick filter does when you
    // press Enter in the Search box instead of clicking a row.
    if (event.key === 'Enter') {
      event.preventDefault();
      const rows = filteredRows();
      if (rows.length > 0) {
        selectLine(rows[0].line_id);
        document.querySelector(`#journalTableBody tr[data-line-id="${rows[0].line_id}"]`)?.scrollIntoView({ block: 'nearest' });
      }
      return;
    }
    if (event.key === 'Escape' && document.getElementById('lineSearchInput').value !== '') {
      event.preventDefault();
      event.stopPropagation();
      clearLineSearch();
    }
  });
  document.getElementById('lineSearchClearBtn').addEventListener('click', () => {
    clearLineSearch();
    document.getElementById('lineSearchInput').focus();
  });

  document.getElementById('journalHeaderRow').addEventListener('click', (event) => {
    const th = event.target.closest('th.sortable');
    if (th) setSort(th.dataset.sortKey);
  });

  document.getElementById('journalTableBody').addEventListener('click', (event) => {
    if (event.target.closest('input')) return; // selection happens on focus for the qty cell itself
    const row = event.target.closest('tr[data-line-id]');
    if (row) selectLine(Number(row.dataset.lineId));
  });
  document.getElementById('journalTableBody').addEventListener('focusin', (event) => {
    const input = event.target.closest('input[data-qty-line-id]');
    if (input) selectLine(Number(input.dataset.qtyLineId));
  });
  document.getElementById('journalTableBody').addEventListener('change', (event) => {
    const input = event.target.closest('input[data-qty-line-id]');
    if (input) saveQtyCell(Number(input.dataset.qtyLineId), input.value, false);
  });
  document.getElementById('journalTableBody').addEventListener('keydown', (event) => {
    const input = event.target.closest('input[data-qty-line-id]');
    if (!input || event.key !== 'Enter') return;
    event.preventDefault();
    saveQtyCell(Number(input.dataset.qtyLineId), input.value, true);
  });

  let resizeDebounce = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeDebounce);
    resizeDebounce = setTimeout(fitJournalGrid, 100);
  });

  await Promise.all([loadWarehouses(), loadCategories()]);
  await loadBatches(true);
  currentBatch = document.getElementById('batchNameInput').value.trim() || 'DEFAULT';
  await loadLines();
})();
