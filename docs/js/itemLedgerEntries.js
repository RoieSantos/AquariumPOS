// Item Ledger Entries page - the ledger view, the per-warehouse stock balance computed from it,
// and the manual adjustment form. See supabase_item_ledger_entries.sql for the model.
//
// Nothing here edits or deletes a ledger row: the only writes are posting a new adjustment and
// reversing a transaction (which posts the opposite entry), both through RPCs that re-check the
// caller is a super user.
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
  document.getElementById('ileWarehouseFilter').innerHTML = '<option value="">All warehouses</option>' + options;
  document.getElementById('adjWarehouseSelect').innerHTML = '<option value="">Select a warehouse...</option>' + options;
}

// ---------------------------------------------------------------- ledger

async function loadEntries() {
  const body = document.getElementById('ileTableBody');
  const errorBox = document.getElementById('ileError');
  errorBox.classList.add('hidden');
  body.innerHTML = '<tr><td colspan="10" class="muted">Loading...</td></tr>';

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

  if (error) {
    body.innerHTML = `<tr><td colspan="10" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="10" class="muted">No ledger entries for this filter.</td></tr>';
    document.getElementById('ileTotalQuantity').textContent = '0';
    renderPaginationBar(document.getElementById('ilePaginationBar'), { page: ledgerPage, pageSize: ledgerPageSize, totalCount: 0 }, {});
    return;
  }

  body.innerHTML = rows.map((r) => {
    const qty = Number(r.quantity || 0);
    const qtyColor = qty < 0 ? 'color:var(--danger);' : '';
    // A reversed entry (and the reversal that cancels it) stays on the ledger - that is the point -
    // but is dimmed so it's clear the pair nets to nothing.
    const dim = r.is_reversed || r.is_reversal ? 'opacity:0.55;' : '';
    const status = r.is_reversed ? ' <span class="muted">(reversed)</span>' : (r.is_reversal ? ' <span class="muted">(reversal)</span>' : '');
    const action = !r.is_reversed && !r.is_reversal
      ? `<button class="btn btn-secondary" type="button" data-reverse-entry="${r.entry_no}">Reverse</button>`
      : '';
    return `
      <tr style="${dim}">
        <td>${r.entry_no}</td>
        <td>${formatDate(r.posting_date)}</td>
        <td>${escapeHtml(r.entry_type)}${status}</td>
        <td title="${escapeHtml(itemLabel(r))}">${escapeHtml(itemLabel(r))}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td>${escapeHtml(r.document_type || '')} ${escapeHtml(r.document_no || '')}</td>
        <td class="doc-cell-text" title="${escapeHtml(r.description || '')}">${escapeHtml(r.description || '')}</td>
        <td class="doc-num" style="${qtyColor}">${formatSignedQuantity(qty)}</td>
        <td>${escapeHtml(r.posted_by || '')}</td>
        <td>${action}</td>
      </tr>`;
  }).join('');

  // Window total over the entire filtered set, not just this page - describes the filter rather
  // than the pagination.
  document.getElementById('ileTotalQuantity').textContent = formatSignedQuantity(rows[0].total_quantity);

  renderPaginationBar(
    document.getElementById('ilePaginationBar'),
    { page: ledgerPage, pageSize: ledgerPageSize, totalCount: rows[0].total_count || 0 },
    {
      onPageChange: (newPage) => { ledgerPage = newPage; loadEntries(); },
      onPageSizeChange: (newSize) => { ledgerPageSize = newSize; ledgerPage = 1; loadEntries(); }
    }
  );
}

async function reverseTransaction(entryNo) {
  const reason = window.prompt(
    `Reverse the transaction that entry ${entryNo} belongs to?\n\n` +
    'This posts an opposite entry dated today - the original stays on the ledger. ' +
    'Enter a reason:'
  );
  if (reason === null) return;
  if (!reason.trim()) {
    window.alert('A reason is required to reverse a ledger entry.');
    return;
  }

  const { error } = await supabaseClient.rpc('admin_reverse_item_ledger_transaction', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: entryNo,
    p_reason: reason.trim()
  });

  if (error) {
    window.alert('Reversal failed: ' + error.message);
    return;
  }

  await refreshAll();
}

// ---------------------------------------------------------------- stock balance

async function loadBalances() {
  const body = document.getElementById('balTableBody');
  const errorBox = document.getElementById('balError');
  errorBox.classList.add('hidden');
  body.innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';

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

  if (error) {
    body.innerHTML = `<tr><td colspan="5" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="5" class="muted">No stock has been posted for this filter.</td></tr>';
    document.getElementById('balTotal').textContent = '0';
    renderPaginationBar(document.getElementById('balPaginationBar'), { page: balancePage, pageSize: balancePageSize, totalCount: 0 }, {});
    return;
  }

  body.innerHTML = rows.map((r) => {
    const balance = Number(r.balance || 0);
    const balanceColor = balance < 0 ? 'color:var(--danger);' : '';
    return `
      <tr>
        <td title="${escapeHtml(itemLabel(r))}">${escapeHtml(itemLabel(r))}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td class="doc-num">${formatQuantity(r.qty_in)}</td>
        <td class="doc-num">${formatQuantity(r.qty_out)}</td>
        <td class="doc-num" style="font-weight:600; ${balanceColor}">${formatQuantity(balance)}</td>
      </tr>`;
  }).join('');

  document.getElementById('balTotal').textContent = formatQuantity(rows[0].total_balance);

  renderPaginationBar(
    document.getElementById('balPaginationBar'),
    { page: balancePage, pageSize: balancePageSize, totalCount: rows[0].total_count || 0 },
    {
      onPageChange: (newPage) => { balancePage = newPage; loadBalances(); },
      onPageSizeChange: (newSize) => { balancePageSize = newSize; balancePage = 1; loadBalances(); }
    }
  );
}

async function refreshAll() {
  await Promise.all([loadEntries(), loadBalances(), loadFailures()]);
}

// ---------------------------------------------------------------- posting failures

// Movements that were saved by their own workflow (a PO receipt, a transfer) but could not be
// written to the ledger - see _ile_post_safe in supabase_item_ledger_hooks.sql. Hidden entirely
// when there are none, so the normal page stays uncluttered.
async function loadFailures() {
  const card = document.getElementById('failuresCard');
  const { data, error } = await supabaseClient.rpc('admin_list_item_ledger_posting_failures', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    // Most likely the hooks migration has not been run yet - the rest of the page still works.
    console.error('admin_list_item_ledger_posting_failures failed:', error);
    card.classList.add('hidden');
    return;
  }

  const rows = data || [];
  card.classList.toggle('hidden', rows.length === 0);
  document.getElementById('failuresBody').innerHTML = rows.map((r) => `
    <tr>
      <td>${escapeHtml(new Date(r.created_at_utc).toLocaleString())}</td>
      <td>${escapeHtml(r.document_type || '')} ${escapeHtml(r.document_no || '')}</td>
      <td>${escapeHtml(r.item_code || '')}${r.variant_id ? ` (${escapeHtml(r.variant_id)})` : ''}</td>
      <td>${escapeHtml(r.warehouse_name || '')}</td>
      <td class="doc-num">${formatSignedQuantity(r.quantity)}</td>
      <td class="doc-cell-text" title="${escapeHtml(r.error_message)}">${escapeHtml(r.error_message)}</td>
      <td><button class="btn btn-secondary" type="button" data-dismiss-failure="${r.id}">Dismiss</button></td>
    </tr>
  `).join('');
}

async function dismissFailure(id) {
  if (!window.confirm('Dismiss this failure? Only do this once the missing quantity has been posted as an adjustment.')) return;

  const { error } = await supabaseClient.rpc('admin_dismiss_item_ledger_posting_failure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_id: id
  });

  if (error) {
    window.alert('Could not dismiss: ' + error.message);
    return;
  }

  await loadFailures();
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
  if (!warehouseId) return showAdjustmentMessage('Select a warehouse.', true);
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
  btn.textContent = 'Post Adjustment';

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

// ---------------------------------------------------------------- init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Item Ledger Entries');

  document.getElementById('adjDateInput').value = todayIso();

  // Default the ledger to the current month, which is what anyone opening it almost always wants.
  // The balance section reads its as-of date from the To field, so leaving To at today also keeps
  // it showing current stock.
  const today = new Date();
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
  document.getElementById('ileFromDate').value = new Date(monthStart.getTime() - monthStart.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  document.getElementById('ileToDate').value = todayIso();

  document.getElementById('ileRefreshBtn').addEventListener('click', () => {
    ledgerPage = 1;
    balancePage = 1;
    refreshAll();
  });

  for (const id of ['ileWarehouseFilter', 'ileTypeFilter']) {
    document.getElementById(id).addEventListener('change', () => {
      ledgerPage = 1;
      balancePage = 1;
      refreshAll();
    });
  }

  document.getElementById('ileSearchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => {
      ledgerPage = 1;
      balancePage = 1;
      refreshAll();
    }, 300);
  });

  document.getElementById('ileTableBody').addEventListener('click', (event) => {
    const btn = event.target.closest('[data-reverse-entry]');
    if (btn) reverseTransaction(Number(btn.dataset.reverseEntry));
  });

  document.getElementById('failuresBody').addEventListener('click', (event) => {
    const btn = event.target.closest('[data-dismiss-failure]');
    if (btn) dismissFailure(Number(btn.dataset.dismissFailure));
  });

  document.getElementById('balCombineVariants').addEventListener('change', () => {
    balancePage = 1;
    loadBalances();
  });

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

  await loadWarehouses();
  await refreshAll();
})();
