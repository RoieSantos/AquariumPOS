// Serial Inventory Journal - the Physical Inventory Journal (physicalInventoryJournal.js) for
// serial-tracked items, where Post adjusts the serials AND the Item Ledger to the count. See
// supabase_serial_inventory_journal.sql for the model:
//   new serials = counted - serials in stock + missing - found   (never negative)
//   ledger adj. = counted - ledger balance
// Calculate / New Line / counts / Missing-Found marks only touch the worksheet; Post
// (admin_post_serial_inventory_journal) is the only call that moves serials or the ledger.
let currentSession = null;
let currentBatch = 'DEFAULT';
let journalRows = []; // the whole batch, as last loaded - filtered client-side by the search box
let selectedLineId = null;
let sortKey = null;
let sortDir = 1;
let serialsLineId = null; // line whose Serial Nos. dialog is open
let serialsRows = [];

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

function formatSigned(value) {
  if (value === null || value === undefined) return '';
  const n = Number(value);
  return n > 0 ? `+${formatQuantity(n)}` : formatQuantity(n);
}

function todayIso() {
  const d = new Date();
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

function isCounted(r) { return r.qty_counted !== null && r.qty_counted !== undefined; }

function fitJournalGrid() {
  const el = document.getElementById('journalGridWrap');
  if (!el) return;
  const available = window.innerHeight - el.getBoundingClientRect().top - 16;
  el.style.maxHeight = Math.max(240, available) + 'px';
}

function showDialog(id) { document.getElementById(id).classList.remove('hidden'); }
function hideDialog(id) { document.getElementById(id).classList.add('hidden'); }
function closeAllDialogs() { document.querySelectorAll('.bc-dialog-backdrop').forEach((d) => d.classList.add('hidden')); }
function anyDialogOpen() { return !!document.querySelector('.bc-dialog-backdrop:not(.hidden)'); }

function itemLabel(row) {
  const name = row.item_name && row.item_name !== row.item_code ? ` - ${row.item_name}` : '';
  const variant = row.variant_name ? ` (${row.variant_name})` : '';
  return `${row.item_code}${name}${variant}`;
}

function rpcArgs(extra) {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password, ...extra };
}

// ---------------------------------------------------------------- warehouses / categories / batches

async function loadWarehouses() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', rpcArgs({ p_search: null, p_limit: 100 }));
  if (error) { console.error('staff_search_warehouses failed:', error); return; }
  const options = (data || []).map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
  document.getElementById('calcWarehouseSelect').innerHTML = '<option value="">Select a location...</option>' + options;
  document.getElementById('newLineWarehouseSelect').innerHTML = '<option value="">Select a location...</option>' + options;
}

async function loadCategories() {
  const { data, error } = await supabaseClient.rpc('staff_list_categories', rpcArgs({}));
  if (error) { console.error('staff_list_categories failed:', error); return; }
  const options = (data || []).map((c) => `<option value="${escapeHtml(c.code)}">${escapeHtml(c.description || c.code)}</option>`).join('');
  document.getElementById('calcCategorySelect').innerHTML = '<option value="">(all)</option>' + options;
}

async function loadBatches(preferMostRecent) {
  const { data, error } = await supabaseClient.rpc('admin_list_serial_journal_batches', rpcArgs({}));
  if (error) { console.error('admin_list_serial_journal_batches failed:', error); return; }
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
  const counted = journalRows.filter(isCounted).length;
  document.getElementById('batchProgress').innerHTML = total === 0
    ? 'No lines yet - use Calculate Inventory or New Line to start.'
    : `<strong>${counted}</strong> of <strong>${total}</strong> line(s) counted`;
}

// ---------------------------------------------------------------- lines grid

function selectedLine() {
  return journalRows.find((r) => r.line_id === selectedLineId) || null;
}

const NUMERIC_SORT_KEYS = new Set(['qty_serials', 'qty_ledger', 'qty_counted', 'new_count', 'ledger_quantity']);

function filteredRows() {
  const q = document.getElementById('lineSearchInput').value.trim().toLowerCase();
  const rows = !q ? journalRows : journalRows.filter((r) =>
    ['item_code', 'item_name', 'variant_name', 'sku', 'warehouse_name'].some((k) => (r[k] || '').toLowerCase().includes(q))
  );
  if (!sortKey) return rows;
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
  if (sortKey === key) sortDir = -sortDir; else { sortKey = key; sortDir = 1; }
  document.querySelectorAll('#journalHeaderRow th.sortable').forEach((th) => {
    const arrow = th.querySelector('.sort-arrow');
    if (arrow) arrow.textContent = th.dataset.sortKey === sortKey ? (sortDir > 0 ? '▲' : '▼') : '';
  });
  renderGrid();
}

function updateSearchUI(matchingCount) {
  const input = document.getElementById('lineSearchInput');
  const hasQuery = input.value.trim() !== '';
  document.getElementById('lineSearchClearBtn').classList.toggle('hidden', !hasQuery);
  document.getElementById('lineSearchCount').textContent =
    hasQuery && journalRows.length > 0 ? `${matchingCount} of ${journalRows.length}` : '';
}

function updateActionState() {
  document.getElementById('deleteLineBtn').disabled = !selectedLineId;
  document.getElementById('serialsBtn').disabled = !selectedLineId;
  document.getElementById('clearAllBtn').disabled = journalRows.length === 0;
  document.getElementById('printBtn').disabled = journalRows.length === 0;
  document.getElementById('postBtn').disabled = !journalRows.some(isCounted);
}

function showNotice(text, isError) {
  const box = document.getElementById('journalError');
  box.textContent = text;
  box.classList.toggle('error-text', !!isError);
  box.classList.toggle('success-text', !isError);
  box.classList.remove('hidden');
}

async function loadLines() {
  const body = document.getElementById('journalTableBody');
  const errorBox = document.getElementById('journalError');
  errorBox.classList.add('hidden');
  errorBox.classList.remove('success-text', 'error-text');
  errorBox.textContent = '';
  body.innerHTML = '<tr><td colspan="10" class="cell-msg">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_get_serial_journal_lines', rpcArgs({ p_batch_name: currentBatch }));
  if (error) {
    journalRows = [];
    body.innerHTML = `<tr><td colspan="10" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
  } else {
    journalRows = data || [];
    if (!journalRows.some((r) => r.line_id === selectedLineId)) selectedLineId = null;
    renderGrid();
  }
  setBatchProgress();
  updateActionState();
  renderFactBox();
  fitJournalGrid();
}

function marksText(r) {
  const parts = [];
  if (r.missing_count) parts.push(`${r.missing_count} missing`);
  if (r.found_count) parts.push(`${r.found_count} found`);
  return parts.join(', ');
}

function renderGrid() {
  const body = document.getElementById('journalTableBody');
  const rows = filteredRows();
  updateSearchUI(rows.length);

  if (journalRows.length === 0) {
    body.innerHTML = '<tr><td colspan="10" class="cell-msg">Choose or type a batch name, then Calculate Inventory to begin.</td></tr>';
    return;
  }
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="10" class="cell-msg">No lines match this search.</td></tr>';
    return;
  }

  body.innerHTML = rows.map((r) => {
    const counted = isCounted(r) ? formatQuantity(r.qty_counted) : '';
    const newNeg = isCounted(r) && Number(r.new_count) < 0;
    const ledgerNeg = isCounted(r) && Number(r.ledger_quantity) < 0;
    return `
      <tr class="${r.line_id === selectedLineId ? 'selected' : ''}" data-line-id="${r.line_id}">
        <td>${escapeHtml(r.item_code)}</td>
        <td class="cell-text" title="${escapeHtml(r.item_name || '')}">${escapeHtml(r.item_name || '')}</td>
        <td class="cell-text" title="${escapeHtml(r.variant_name || '')}">${escapeHtml(r.variant_name || '')}</td>
        <td>${escapeHtml(r.sku || '')}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td class="num calc-only">${formatQuantity(r.qty_serials)}</td>
        <td class="num qty-cell-wrap">
          <input type="number" class="bc-qty-cell" min="0" step="1" data-qty-line-id="${r.line_id}" value="${escapeHtml(counted)}" placeholder="-" />
        </td>
        <td class="sij-marks"><button class="bc-row-action" type="button" data-serials-line-id="${r.line_id}">Serial Nos.</button> <span class="muted">${escapeHtml(marksText(r))}</span></td>
        <td class="num calc-only ${newNeg ? 'neg' : ''}" title="${newNeg ? 'Tick more serials as Missing on Serial Nos.' : ''}">${isCounted(r) ? formatQuantity(r.new_count) : ''}</td>
        <td class="num calc-only ${ledgerNeg ? 'neg' : ''}">${isCounted(r) ? formatSigned(r.ledger_quantity) : ''}</td>
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

// Re-reads one line's live figures after a count / mark change (new_count etc. are worked out
// server-side) - simplest is the whole batch, it's small.
async function refreshKeepingFocus(lineIdToFocus) {
  await loadLines();
  if (lineIdToFocus) {
    selectLine(lineIdToFocus);
    const input = document.querySelector(`input[data-qty-line-id="${lineIdToFocus}"]`);
    input?.focus();
    input?.select();
  }
}

async function saveQtyCell(lineId, rawValue, moveToNext) {
  const row = journalRows.find((r) => r.line_id === lineId);
  const input = document.querySelector(`input[data-qty-line-id="${lineId}"]`);
  const text = String(rawValue ?? '').trim();
  const value = text === '' ? null : Number(text);
  const restore = () => { if (input) input.value = row && isCounted(row) ? formatQuantity(row.qty_counted) : ''; };

  if (value !== null && (Number.isNaN(value) || value < 0 || !Number.isInteger(value))) {
    window.alert('Enter a whole-number count of 0 or more, or leave it blank.');
    restore();
    return;
  }
  if (row && (isCounted(row) ? Number(row.qty_counted) : null) === value && !moveToNext) return;

  const { error } = await supabaseClient.rpc('admin_set_serial_journal_qty', rpcArgs({ p_line_id: lineId, p_qty_counted: value }));
  if (error) {
    window.alert('Could not save that count: ' + error.message);
    restore();
    return;
  }

  let focusId = null;
  if (moveToNext) {
    const rows = filteredRows();
    const idx = rows.findIndex((r) => r.line_id === lineId);
    focusId = rows[idx + 1]?.line_id || null;
  }
  await refreshKeepingFocus(focusId);
  if (!focusId) selectLine(lineId);
}

// ---------------------------------------------------------------- FactBox

function renderFactBox() {
  const details = document.getElementById('factDetails');
  const r = selectedLine();
  if (!r) {
    details.innerHTML = '<p class="bc-fact-empty">Select a line to see its details.</p>';
    return;
  }
  const su = currentSession.isSuperUser;
  const facts = [
    ['Item No.', r.item_code],
    ['Description', r.item_name && r.item_name !== r.item_code ? r.item_name : ''],
    ['Variant', r.variant_name || ''],
    ['SKU', r.sku || ''],
    ['Location Code', r.warehouse_name],
    ...(su ? [
      ['Qty. (Serials) at Calculate', formatQuantity(r.qty_calculated)],
      ['Serials in stock now', formatQuantity(r.qty_serials)],
      ['Ledger balance now', formatQuantity(r.qty_ledger)]
    ] : []),
    ['Qty. (Phys. Inventory)', isCounted(r) ? formatQuantity(r.qty_counted) : 'Not counted yet'],
    ['Serials ticked Missing', formatQuantity(r.missing_count)],
    ['Serials Found', formatQuantity(r.found_count)],
    ...(su && isCounted(r) ? [
      ['New serials on Post', formatQuantity(r.new_count)],
      ['Ledger adjustment on Post', formatSigned(r.ledger_quantity)]
    ] : []),
    ['Last Updated', r.updated_at_utc ? new Date(r.updated_at_utc).toLocaleString() : ''],
    ['Updated By', r.updated_by]
  ].filter(([, v]) => v !== '' && v !== null && v !== undefined);

  details.innerHTML = '<dl class="bc-facts">' +
    facts.map(([k, v]) => `<dt>${escapeHtml(k)}</dt><dd>${escapeHtml(v)}</dd>`).join('') +
    '</dl>';
}

// ---------------------------------------------------------------- Serial Nos. dialog

async function openSerialsDialog(lineId) {
  const r = journalRows.find((x) => x.line_id === lineId);
  if (!r) return;
  serialsLineId = lineId;
  selectLine(lineId);
  document.getElementById('serialsDialogTitle').textContent = `Serial Nos. - ${itemLabel(r)}`;
  document.getElementById('serialsLede').textContent =
    `Serials in stock at ${r.warehouse_name}. Tick the ones you could NOT find on the shelf. ` +
    'A labelled unit that is not on this list (sold, in transit or at another location in the system): add it as Found. ' +
    'Units with no label at all just go in the count - Post gives them new serials.';
  document.getElementById('foundSerialInput').value = '';
  document.getElementById('serialsMessage').classList.add('hidden');
  showDialog('serialsDialog');
  await loadSerials();
  document.getElementById('foundSerialInput').focus();
}

async function loadSerials() {
  const body = document.getElementById('serialsTableBody');
  body.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';
  const { data, error } = await supabaseClient.rpc('admin_get_serial_journal_line_serials', rpcArgs({ p_line_id: serialsLineId }));
  if (error) {
    body.innerHTML = `<tr><td colspan="7" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  serialsRows = data || [];
  renderSerials();
}

function renderSerials() {
  const body = document.getElementById('serialsTableBody');
  if (serialsRows.length === 0) {
    body.innerHTML = '<tr><td colspan="7" class="muted">No serials in stock here for this item.</td></tr>';
  } else {
    body.innerHTML = serialsRows.map((s) => {
      const found = s.mark === 'FOUND';
      const missing = s.mark === 'MISSING';
      return `
        <tr class="${missing ? 'is-missing' : ''}">
          <td>${found ? '<span class="badge badge-success">Found</span>'
            : `<input type="checkbox" data-missing-serial="${s.running_serial_no}" ${missing ? 'checked' : ''} ${s.in_stock_here || missing ? '' : 'disabled'} />`}</td>
          <td><strong>${escapeHtml(s.serial_no)}</strong></td>
          <td>${escapeHtml(s.variant_sku || '')}</td>
          <td>${escapeHtml(s.status || '')}</td>
          <td>${escapeHtml(s.location || '')}</td>
          <td>${escapeHtml(s.source_document_no || '')}</td>
          <td>${found ? `<button class="bc-row-action bc-row-action-danger" type="button" data-unfound-serial="${s.running_serial_no}">Remove</button>` : ''}</td>
        </tr>`;
    }).join('');
  }

  const r = journalRows.find((x) => x.line_id === serialsLineId);
  const inStock = serialsRows.filter((s) => s.in_stock_here).length;
  const missing = serialsRows.filter((s) => s.mark === 'MISSING' && s.in_stock_here).length;
  const found = serialsRows.filter((s) => s.mark === 'FOUND' && !s.in_stock_here).length;
  const labelled = inStock - missing + found;
  let tally = `<strong>${labelled}</strong> labelled unit(s) accounted for (${inStock} in stock - ${missing} missing + ${found} found).`;
  if (r && isCounted(r)) {
    const diff = Number(r.qty_counted) - labelled;
    tally += ` Counted <strong>${formatQuantity(r.qty_counted)}</strong>: ` + (diff > 0
      ? `Post creates <strong>${diff}</strong> new serial(s) for the unlabelled unit(s).`
      : diff < 0 ? `<span class="error-text">tick ${-diff} more as Missing, or correct the count.</span>`
        : 'matches - no new serials.');
  } else {
    tally += ' Enter the count on the line too.';
  }
  document.getElementById('serialsTally').innerHTML = tally;
}

function showSerialsError(text) {
  const msg = document.getElementById('serialsMessage');
  msg.textContent = text;
  msg.classList.toggle('hidden', !text);
}

async function setMissing(runningSerialNo, missing) {
  showSerialsError('');
  const { error } = await supabaseClient.rpc('admin_set_serial_journal_mark', rpcArgs({
    p_line_id: serialsLineId, p_running_serial_no: runningSerialNo, p_mark: missing ? 'MISSING' : null
  }));
  if (error) showSerialsError(error.message);
  await Promise.all([loadSerials(), loadLines()]);
}

async function addFound() {
  const input = document.getElementById('foundSerialInput');
  const serialNo = input.value.trim();
  if (!serialNo) return;
  showSerialsError('');
  const { error } = await supabaseClient.rpc('admin_add_serial_journal_found', rpcArgs({ p_line_id: serialsLineId, p_serial_no: serialNo }));
  if (error) { showSerialsError(error.message); input.select(); return; }
  input.value = '';
  await Promise.all([loadSerials(), loadLines()]);
  input.focus();
}

// ---------------------------------------------------------------- Print (count sheet)

function printJournal() {
  const rows = filteredRows();
  if (rows.length === 0) return;
  const warehouseNames = [...new Set(rows.map((r) => r.warehouse_name).filter(Boolean))];
  const rowsHtml = rows.map((r) => `
    <tr>
      <td>${escapeHtml(r.variant_name || r.item_name || r.item_code)}</td>
      <td>${escapeHtml(r.sku || '')}</td>
      <td class="blank-cell"></td>
    </tr>`).join('');

  document.getElementById('printArea').innerHTML = `
    <h1>Serial Inventory Journal - Count Sheet</h1>
    <table class="print-meta">
      <tr><td>Batch Name</td><td>${escapeHtml(currentBatch)}</td></tr>
      <tr><td>Location(s)</td><td>${escapeHtml(warehouseNames.join(', ') || '-')}</td></tr>
      <tr><td>Line Count</td><td>${rows.length}</td></tr>
      <tr><td>Printed</td><td>${escapeHtml(new Date().toLocaleString())}</td></tr>
    </table>
    <table class="print-lines">
      <thead>
        <tr>
          <th>Variant</th><th>SKU</th><th>Qty. (Phys. Inventory)</th>
        </tr>
      </thead>
      <tbody>${rowsHtml}</tbody>
    </table>
    <p class="print-sign">Counted By: ________________________&nbsp;&nbsp;&nbsp;&nbsp;Date: ________________</p>`;
  window.print();
}

// ---------------------------------------------------------------- Calculate Inventory

async function confirmCalculate() {
  const warehouseId = document.getElementById('calcWarehouseSelect').value;
  const msg = document.getElementById('calcMessage');
  const fail = (text) => { msg.textContent = text; msg.classList.add('error-text'); msg.classList.remove('hidden', 'muted'); };
  msg.classList.remove('error-text');
  msg.classList.add('muted');
  if (!currentBatch) return fail('Type a batch name first.');
  if (!warehouseId) return fail('Pick a location.');

  const btn = document.getElementById('calcConfirmBtn');
  btn.disabled = true;
  btn.textContent = 'Calculating...';
  const { data, error } = await supabaseClient.rpc('admin_calculate_serial_inventory', rpcArgs({
    p_batch_name: currentBatch,
    p_warehouse_id: warehouseId,
    p_category_code: document.getElementById('calcCategorySelect').value || null,
    p_search: document.getElementById('calcSearchInput').value.trim() || null,
    p_only_with_stock: document.getElementById('calcOnlyStockInput').checked
  }));
  btn.disabled = false;
  btn.textContent = 'Calculate';
  if (error) return fail('Calculate failed: ' + error.message);

  msg.textContent = `${data ?? 0} line(s) added or refreshed. You can calculate again (e.g. another category or location) into the same batch.`;
  msg.classList.remove('error-text', 'hidden');
  await Promise.all([loadLines(), loadBatches(false)]);
}

// ---------------------------------------------------------------- New Line

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
  const { data, error } = await supabaseClient.rpc('admin_list_items', rpcArgs({ p_search: text, p_page: 1, p_page_size: 20 }));
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

  const { data, error } = await supabaseClient.rpc('admin_list_variants', rpcArgs({
    p_search: null, p_main_item_code: newLineSelectedItemCode, p_page: 1, p_page_size: 200
  }));
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
  const fail = (text) => {
    const msg = document.getElementById('newLineMessage');
    msg.textContent = text;
    msg.classList.remove('hidden');
  };
  document.getElementById('newLineMessage').classList.add('hidden');

  if (!currentBatch) return fail('Type a batch name first.');
  if (!newLineSelectedItemCode) return fail('Pick an item from the suggestions first.');
  if (newLineSelectedItemHasVariants && !variantId) return fail('This item has variants - pick which one.');
  if (!warehouseId) return fail('Pick a location.');

  const btn = document.getElementById('newLineConfirmBtn');
  btn.disabled = true;
  btn.textContent = 'Adding...';
  const { data, error } = await supabaseClient.rpc('admin_add_serial_journal_line', rpcArgs({
    p_batch_name: currentBatch, p_item_code: newLineSelectedItemCode, p_variant_id: variantId || null, p_warehouse_id: warehouseId
  }));
  btn.disabled = false;
  btn.textContent = 'Add';
  if (error) return fail('Could not add that line: ' + error.message);

  const result = Array.isArray(data) ? data[0] : data;
  hideDialog('newLineDialog');
  await Promise.all([loadLines(), loadBatches(false)]);
  if (result?.line_id) selectLine(result.line_id);
}

// ---------------------------------------------------------------- Delete

async function deleteSelectedLine() {
  const r = selectedLine();
  if (!r) return;
  if (!window.confirm(`Remove ${itemLabel(r)} at ${r.warehouse_name || ''} from this worksheet? This only removes it from the count - serials and the ledger are untouched.`)) return;
  const { error } = await supabaseClient.rpc('admin_delete_serial_journal_line', rpcArgs({ p_line_id: r.line_id }));
  if (error) { window.alert('Could not delete that line: ' + error.message); return; }
  selectedLineId = null;
  await Promise.all([loadLines(), loadBatches(false)]);
}

async function deleteAllLines() {
  if (journalRows.length === 0) return;
  const counted = journalRows.filter(isCounted).length;
  const warn = counted > 0 ? ` This includes ${counted} line(s) that already have a count - those counts and their Missing/Found marks will be lost.` : '';
  if (!window.confirm(`Remove all ${journalRows.length} line(s) from batch "${currentBatch}"?${warn} Serials and the ledger are untouched.`)) return;
  const { error } = await supabaseClient.rpc('admin_clear_serial_journal_batch', rpcArgs({ p_batch_name: currentBatch }));
  if (error) { window.alert('Could not clear the worksheet: ' + error.message); return; }
  selectedLineId = null;
  await Promise.all([loadLines(), loadBatches(false)]);
}

// ---------------------------------------------------------------- Post

async function openPostDialog() {
  document.getElementById('postDateInput').value = todayIso();
  document.getElementById('postReasonInput').value = '';
  document.getElementById('postMessage').classList.add('hidden');
  document.getElementById('postConfirmBtn').disabled = true;
  document.getElementById('postSummary').textContent = 'Checking...';
  showDialog('postDialog');

  const { data, error } = await supabaseClient.rpc('admin_post_serial_inventory_journal', rpcArgs({
    p_batch_name: currentBatch, p_posting_date: todayIso(), p_reason: null, p_dry_run: true
  }));
  if (error) { document.getElementById('postSummary').textContent = error.message; return; }

  const rows = data || [];
  const problems = rows.filter((r) => r.problem);
  const sum = (key) => rows.reduce((s, r) => s + Number(r[key] || 0), 0);
  const ledgerIn = rows.reduce((s, r) => s + Math.max(0, Number(r.ledger_quantity || 0)), 0);
  const ledgerOut = rows.reduce((s, r) => s + Math.min(0, Number(r.ledger_quantity || 0)), 0);

  let html = `<strong>${rows.length}</strong> counted line(s) will post and be cleared from the worksheet; uncounted lines stay.<br>` +
    `Serials: <strong>${sum('missing_count')}</strong> written off as Missing, <strong>${sum('found_count')}</strong> Found brought back into stock, ` +
    `<strong>${Math.max(0, rows.reduce((s, r) => s + Math.max(0, Number(r.new_count || 0)), 0))}</strong> new serial(s) created (labels print after posting).`;
  if (currentSession.isSuperUser) {
    html += `<br>Ledger: <strong>+${formatQuantity(ledgerIn)}</strong> / <strong>${formatQuantity(ledgerOut)}</strong> adjusted.`;
  }
  if (problems.length > 0) {
    html += '<br><br><span class="error-text"><strong>Fix these first:</strong></span><ul>' +
      problems.map((r) => `<li>${escapeHtml(itemLabel(r))} at ${escapeHtml(r.warehouse_name || '')}: ${escapeHtml(r.problem)}</li>`).join('') +
      '</ul>';
  }
  document.getElementById('postSummary').innerHTML = html;
  document.getElementById('postConfirmBtn').disabled = problems.length > 0;
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
  const { data, error } = await supabaseClient.rpc('admin_post_serial_inventory_journal', rpcArgs({
    p_batch_name: currentBatch,
    p_posting_date: document.getElementById('postDateInput').value || todayIso(),
    p_reason: reason,
    p_dry_run: false
  }));
  btn.disabled = false;
  btn.textContent = 'Post';
  if (error) {
    msg.textContent = 'Posting failed: ' + error.message;
    msg.classList.remove('hidden');
    return;
  }

  hideDialog('postDialog');
  selectedLineId = null;
  await Promise.all([loadLines(), loadBatches(false)]);

  const rows = data || [];
  const docNo = rows[0]?.document_no || '';
  const labels = rows.flatMap((r) => (r.new_serial_nos || []).map((serialNo) => ({
    serialNo, itemCode: r.item_code, description: r.variant_name ? `${r.item_name} - ${r.variant_name}` : (r.item_name || '')
  })));
  let labelNote = '';
  if (labels.length > 0) {
    // New serials' labels go straight to the barcode printer, same as Production Orders' Post Output.
    const result = await LabelPrinter.printSerialLabels(labels);
    labelNote = ` ${labels.length} new serial(s): ${labels.map((l) => l.serialNo).join(', ')}. ${result?.message || ''}`;
  }
  showNotice(`Posted ${docNo}: ${rows.length} line(s).${labelNote}`, false);
}

// ---------------------------------------------------------------- init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  document.body.classList.toggle('hide-calc', !session.isSuperUser);
  renderTopNav('Serial Inventory Journal');
  LabelPrinter.init(session);

  document.getElementById('calcBtn').addEventListener('click', () => {
    document.getElementById('calcMessage').classList.add('hidden');
    showDialog('calcDialog');
  });
  document.getElementById('calcConfirmBtn').addEventListener('click', confirmCalculate);
  document.getElementById('newLineBtn').addEventListener('click', openNewLineDialog);
  document.getElementById('newLineConfirmBtn').addEventListener('click', confirmNewLine);
  document.getElementById('serialsBtn').addEventListener('click', () => { if (selectedLineId) openSerialsDialog(selectedLineId); });
  document.getElementById('deleteLineBtn').addEventListener('click', deleteSelectedLine);
  document.getElementById('clearAllBtn').addEventListener('click', deleteAllLines);
  document.getElementById('postBtn').addEventListener('click', openPostDialog);
  document.getElementById('postConfirmBtn').addEventListener('click', confirmPost);
  document.getElementById('journalRefreshBtn').addEventListener('click', () => loadLines());
  document.getElementById('printBtn').addEventListener('click', printJournal);

  document.getElementById('serialsTableBody').addEventListener('change', (event) => {
    const box = event.target.closest('input[data-missing-serial]');
    if (box) setMissing(Number(box.dataset.missingSerial), box.checked);
  });
  document.getElementById('serialsTableBody').addEventListener('click', (event) => {
    const btn = event.target.closest('button[data-unfound-serial]');
    if (btn) setMissing(Number(btn.dataset.unfoundSerial), false);
  });
  document.getElementById('foundSerialAddBtn').addEventListener('click', addFound);
  document.getElementById('foundSerialInput').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); addFound(); }
  });

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

  const searchInput = document.getElementById('lineSearchInput');
  searchInput.addEventListener('input', renderGrid);
  searchInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      const rows = filteredRows();
      if (rows.length > 0) selectLine(rows[0].line_id);
    } else if (event.key === 'Escape' && searchInput.value !== '') {
      event.preventDefault();
      event.stopPropagation();
      searchInput.value = '';
      renderGrid();
    }
  });
  document.getElementById('lineSearchClearBtn').addEventListener('click', () => {
    searchInput.value = '';
    renderGrid();
    searchInput.focus();
  });

  document.getElementById('journalHeaderRow').addEventListener('click', (event) => {
    const th = event.target.closest('th.sortable');
    if (th) setSort(th.dataset.sortKey);
  });

  const tbody = document.getElementById('journalTableBody');
  tbody.addEventListener('click', (event) => {
    const serialsBtn = event.target.closest('button[data-serials-line-id]');
    if (serialsBtn) { openSerialsDialog(Number(serialsBtn.dataset.serialsLineId)); return; }
    if (event.target.closest('input')) return;
    const row = event.target.closest('tr[data-line-id]');
    if (row) selectLine(Number(row.dataset.lineId));
  });
  tbody.addEventListener('focusin', (event) => {
    const input = event.target.closest('input[data-qty-line-id]');
    if (input && selectedLineId !== Number(input.dataset.qtyLineId)) selectLine(Number(input.dataset.qtyLineId));
  });
  tbody.addEventListener('change', (event) => {
    const input = event.target.closest('input[data-qty-line-id]');
    if (input) saveQtyCell(Number(input.dataset.qtyLineId), input.value, false);
  });
  tbody.addEventListener('keydown', (event) => {
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
