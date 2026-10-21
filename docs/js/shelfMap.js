// Shelf Map - a drawn shelf layout (rows of cells) where each cell is linked to an Item and shows
// that item's live Item Ledger quantity at the shelf's warehouse (supabase_shelf_maps.sql).
// Nothing about stock is stored on the map - it only ever reads the ledger, so it can't drift.
let currentSession = null;
let shelves = [];
let currentShelfId = null;
// While editing, `draft` is a working copy: { id, name, warehouse_id, rows: [[cell, ...], ...] }.
// Nothing is written until Save.
let draft = null;
let modalCell = null; // { rowIdx, colIdx } of the cell open in the modal
let warehousesLoaded = false;

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatQty(value) {
  return value === null || value === undefined ? '-' : Number(value).toLocaleString();
}

function showError(message) {
  const el = document.getElementById('shelfError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function cellsToRows(cells) {
  const rows = [];
  (cells || []).forEach((c) => {
    if (!rows[c.row_no]) rows[c.row_no] = [];
    rows[c.row_no].push(c);
  });
  // Drop gaps in row numbering, keep column order.
  return rows.filter(Boolean).map((row) => row.sort((a, b) => a.col_no - b.col_no));
}

function currentShelf() {
  return shelves.find((s) => s.id === currentShelfId) || null;
}

// Colour compares what is counted on the shelves (summed over every spot of this location holding
// the item) against the ledger's on-hand for that location. Orange = the ledger has dropped to half
// of the shelf quantity or less, i.e. time to restock the shelf; green = more than half is still in
// the ledger (including more than the shelf holds); red = nothing left anywhere.
// onHand is the display value for the big "Stock on hand" number (null = nothing to show).
function cellStatus(cell) {
  if (!cell.item_code) return { cls: 'unlinked', onHand: null, sub: '' };
  if (cell.on_hand === null || cell.on_hand === undefined) return { cls: 'unlinked', onHand: null, sub: 'pick a location' };
  const onHand = Number(cell.on_hand);
  const shelfTotal = Number(cell.shelf_total || 0);
  let cls = 'ok';
  if (onHand <= 0 && shelfTotal === 0) cls = 'empty';
  else if (onHand <= shelfTotal / 2) cls = 'diff';
  const shared = cell.item_cells > 1 ? `Shelf total ${formatQty(shelfTotal)} across ${cell.item_cells} spots` : '';
  return { cls, onHand: formatQty(onHand), sub: shared };
}

// ---------------------------------------------------------------- replenishment transfer order

const REPLENISH_FROM_WAREHOUSE_NAME = 'Warehouse';
const REPLENISH_DESCRIPTION_PREFIX = 'Shelf replenishment - ';

// Every linked item on the shelf whose ledger has dropped to half of the shelf qty or less (the
// orange spots), topped back up to the shelf qty: shelf_total - on_hand. An item drawn in several
// spots appears once, since shelf_total/on_hand already cover all of its spots.
function replenishmentNeeds(shelf) {
  const byItem = new Map();
  (shelf.cells || []).forEach((cell) => {
    if (!cell.item_code || byItem.has(cell.item_code)) return;
    if (cell.on_hand === null || cell.on_hand === undefined) return;
    const onHand = Number(cell.on_hand);
    const shelfTotal = Number(cell.shelf_total || 0);
    const qty = Math.ceil(shelfTotal - onHand);
    if (shelfTotal > 0 && onHand <= shelfTotal / 2 && qty > 0) {
      byItem.set(cell.item_code, { itemCode: cell.item_code, itemName: cell.item_name || '', qty, onHand, shelfTotal });
    }
  });
  return Array.from(byItem.values());
}

async function findWarehouse(name) {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: name,
    p_limit: 100
  });
  if (error || !data) return null;
  return data.find((w) => (w.name || '').toLowerCase() === name.toLowerCase()) || null;
}

// Creates a Requested transfer order from the "Warehouse" location to this shelf's location, the
// same document the Transfer Orders page's New Transfer Order saves (Transfer_Header + Transfer_Line).
async function createReplenishmentTransfer() {
  const shelf = currentShelf();
  if (!shelf) return;
  if (!shelf.warehouse_id) {
    window.alert('This shelf has no location set. Edit Layout and pick one first.');
    return;
  }

  const btn = document.getElementById('replenishBtn');
  btn.disabled = true;
  try {
    const [fromWarehouse, toWarehouse] = await Promise.all([
      findWarehouse(REPLENISH_FROM_WAREHOUSE_NAME),
      findWarehouse(shelf.warehouse_name || '')
    ]);
    if (!fromWarehouse) {
      window.alert(`Could not find a location named "${REPLENISH_FROM_WAREHOUSE_NAME}".`);
      return;
    }
    const toId = toWarehouse ? toWarehouse.id : shelf.warehouse_id;
    const toName = toWarehouse ? toWarehouse.name : (shelf.warehouse_name || shelf.warehouse_id);
    if (fromWarehouse.id === toId) {
      window.alert(`This shelf is already at "${fromWarehouse.name}" - nothing to replenish from.`);
      return;
    }

    const needs = replenishmentNeeds(shelf);
    if (needs.length === 0) {
      window.alert('Nothing to replenish - no item on this shelf is at half of its shelf qty or less.');
      return;
    }

    // A transfer line must name a variant when the item has any (see saveNewTransfer in
    // transferOrders.js). An item with exactly one variant - the usual case, every Pancake product
    // has one - just uses it, same as picking it by hand. Only items with SEVERAL variants are left
    // off and listed, since which one to send is a choice.
    const lines = [];
    const needsVariant = [];
    for (const need of needs) {
      const { data } = await supabaseClient.rpc('staff_search_variants', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_item_code: need.itemCode,
        p_page: 1
      });
      const variants = data || [];
      if (variants.length === 0) {
        lines.push(need);
      } else if (variants.length === 1 && Number(variants[0].total_count || 1) <= 1) {
        const v = variants[0];
        lines.push({ ...need, variantId: v.variation_id, variantName: v.sku || v.variant_name || v.variation_id });
      } else {
        needsVariant.push(need.itemCode);
      }
    }
    if (lines.length === 0) {
      window.alert('Every item that needs replenishing has several variants, so pick them on the Transfer Orders page: ' + needsVariant.join(', '));
      return;
    }

    // Request cap (sql/supabase_transfer_request_cap.sql): the shelf qty minus on hand doesn't know
    // about orders already on the way, and the database refuses a line over the store's limit - so
    // trim each line to its Max and leave out items that are already covered by an open order.
    const { data: capRows, error: capError } = await supabaseClient.rpc('staff_check_transfer_request_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_doc_no: '',
      p_to_warehouse_id: toId,
      p_lines: lines.map((l) => ({ item_no: l.itemCode, variant_id: l.variantId || null, qty: 0, order_id: null }))
    });
    if (capError) throw capError;
    const capByIdx = new Map((capRows || []).map((r) => [r.idx, r]));
    const covered = [];
    const capped = [];
    lines.forEach((l, i) => {
      const r = capByIdx.get(i);
      if (!r || !r.rule) { capped.push(l); return; }
      const qty = Math.min(l.qty, Math.floor(Number(r.allowed) || 0));
      if (qty > 0) capped.push({ ...l, qty });
      else covered.push(`${l.itemCode}${r.open_docs ? ` (on ${r.open_docs})` : ''}`);
    });
    lines.length = 0;
    lines.push(...capped);
    if (lines.length === 0) {
      window.alert('Nothing to replenish - everything low on this shelf is already on the way: ' + covered.join(', '));
      return;
    }

    const summary = lines.map((l) => `  ${l.itemCode} ${l.itemName} - ${formatQty(l.qty)}`).join('\n');
    const skipped = (needsVariant.length ? `\n\nLeft off (they have several variants - add them on the Transfer Orders page): ${needsVariant.join(', ')}` : '')
      + (covered.length ? `\n\nLeft off (already on the way): ${covered.join(', ')}` : '');
    if (!window.confirm(`Create a transfer order from ${fromWarehouse.name} to ${toName} for ${lines.length} item${lines.length === 1 ? '' : 's'}?\n\n${summary}${skipped}`)) return;

    const { data: docNo, error: noError } = await supabaseClient.rpc('staff_next_transfer_no', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_warehouse_name: toName
    });
    if (noError || !docNo) throw noError || new Error('Could not get a Document No.');

    const who = currentSession.displayName || currentSession.username || null;
    const today = new Date();
    const requestedDate = new Date(today.getTime() - today.getTimezoneOffset() * 60000).toISOString().slice(0, 10);

    await upsertRow('Transfer_Header', { 'No.': docNo }, {
      'Description': `${REPLENISH_DESCRIPTION_PREFIX}${shelf.name}`,
      'Status': 'Requested',
      'Requested Date': requestedDate,
      'From Warehouse ID': fromWarehouse.id,
      'From Warehouse': fromWarehouse.name,
      'To Warehouse ID': toId,
      'To Warehouse': toName,
      'Use Production Category': false,
      'Requested By': who,
      'Is Locked': true,
      'Locked At': new Date().toISOString(),
      'Locked By': who
    });
    try {
      for (let i = 0; i < lines.length; i += 1) {
        await upsertRow('Transfer_Line', { 'Document No.': docNo, 'Line No.': (i + 1) * 10000 }, {
          'Item No.': lines[i].itemCode,
          'Variant ID': lines[i].variantId || null,
          'Variant Name': lines[i].variantName || null,
          'Description': lines[i].itemName || null,
          'Qty To Transfer': lines[i].qty
        });
      }
    } catch (lineErr) {
      // A line was refused by the request cap - don't leave a half-saved order behind.
      await supabaseClient.from('Transfer_Line').delete().eq('"Document No."', docNo);
      await supabaseClient.from('Transfer_Header').delete().eq('"No."', docNo);
      throw lineErr;
    }

    delete pendingByWarehouse[toId];
    renderShelf();
    loadLastReplenishment(currentShelf());
    if (window.confirm(`Transfer order ${docNo} created (${lines.length} line${lines.length === 1 ? '' : 's'}). Open it now?`)) {
      window.location.href = 'transfer-orders.html?doc=' + encodeURIComponent(docNo);
    }
  } catch (err) {
    window.alert('Failed to create the transfer order: ' + (err.message || err));
  } finally {
    btn.disabled = false;
  }
}

// ---------------------------------------------------------------- pending transfer orders
// Per location: what open transfer orders INTO it still have to be received, per item -
// Qty To Transfer minus the running Qty Received, over every TO that isn't Received/Cancelled
// (same "open" rule as transferOrders.js). Cached per warehouse; Refresh clears it.
// pendingByWarehouse[warehouseId] = Map(itemCode -> { qty, inTransit, docs: [{ no, status, qty }] })
let pendingByWarehouse = {};
const pendingLoading = new Set();

async function loadPendingTransfers(warehouseId) {
  if (!warehouseId || pendingByWarehouse[warehouseId] || pendingLoading.has(warehouseId)) return;
  pendingLoading.add(warehouseId);
  try {
    const { data: headers, error } = await supabaseClient.from('Transfer_Header')
      .select('"No.", "Status"')
      .eq('"To Warehouse ID"', warehouseId)
      .not('"Status"', 'in', '("Received","Cancelled")');
    if (error) throw error;
    const byItem = new Map();
    const statusByDoc = new Map((headers || []).map((h) => [h['No.'], h['Status'] || 'Requested']));
    if (statusByDoc.size > 0) {
      const { data: lines, error: lineError } = await supabaseClient.from('Transfer_Line')
        .select('"Document No.", "Item No.", "Qty To Transfer", "Qty Shipped", "Qty Received"')
        .in('"Document No."', Array.from(statusByDoc.keys()));
      if (lineError) throw lineError;
      (lines || []).forEach((l) => {
        const code = l['Item No.'];
        const received = Number(l['Qty Received']) || 0;
        const qty = Math.max(0, (Number(l['Qty To Transfer']) || 0) - received);
        if (!code || qty <= 0) return;
        const entry = byItem.get(code) || { qty: 0, inTransit: 0, docs: [] };
        entry.qty += qty;
        entry.inTransit += Math.max(0, (Number(l['Qty Shipped']) || 0) - received);
        entry.docs.push({ no: l['Document No.'], status: statusByDoc.get(l['Document No.']), qty });
        byItem.set(code, entry);
      });
    }
    pendingByWarehouse[warehouseId] = byItem;
    // Only redraw if the user is still looking at this location (and not laying out a shelf).
    const shelf = currentShelf();
    if (!draft && shelf && shelf.warehouse_id === warehouseId) renderShelf();
  } catch (err) {
    console.error('Loading pending transfer orders failed:', err);
  } finally {
    pendingLoading.delete(warehouseId);
  }
}

function pendingHtml(cell, warehouseId) {
  if (!cell.item_code || !warehouseId) return '';
  const p = (pendingByWarehouse[warehouseId] || new Map()).get(cell.item_code);
  if (!p) return '';
  const title = p.docs.map((d) => `${d.no} (${d.status}): ${formatQty(d.qty)}`).join('\n');
  const href = 'transfer-orders.html?doc=' + encodeURIComponent(p.docs[0].no);
  return `<div class="cell-stat cell-stat-pending">
    <span class="cell-stat-label">Pending TO</span>
    <a class="cell-pending" href="${href}" title="${escapeHtml(title)}" onclick="event.stopPropagation()">${escapeHtml(formatQty(p.qty))}</a>
    ${p.inTransit > 0 ? `<span class="cell-stat-label">${escapeHtml(formatQty(p.inTransit))} in transit</span>` : ''}
  </div>`;
}

function countedLabel(cell) {
  if (!cell.counted_at) return '';
  return 'Counted ' + new Date(cell.counted_at).toLocaleDateString() + (cell.counted_by ? ' by ' + cell.counted_by : '');
}

function renderShelf() {
  const body = document.getElementById('shelfBody');
  const editing = !!draft;
  const rows = editing ? draft.rows : cellsToRows((currentShelf() || {}).cells);

  if (rows.length === 0) {
    body.innerHTML = '<p class="muted">This shelf has no spots yet.' + (editing ? ' Use "+ Row" to add one.' : '') + '</p>';
    return;
  }

  const warehouseId = editing ? null : (currentShelf() || {}).warehouse_id;
  if (warehouseId) loadPendingTransfers(warehouseId);

  body.innerHTML = rows.map((row, r) => {
    const cellsHtml = row.map((cell, c) => {
      const st = cellStatus(cell);
      // View mode: the count is an input staff type into directly (saved on change). Edit mode
      // shows it read-only - the spot's modal is where it's changed while laying out.
      const countHtml = editing
        ? `<span class="cell-qty">${cell.current_qty != null ? formatQty(cell.current_qty) : '-'}</span>`
        : `<input type="number" class="cell-count" min="0" inputmode="numeric" data-cellid="${cell.id}" value="${cell.current_qty != null ? escapeHtml(cell.current_qty) : ''}" placeholder="count" />`;
      const itemLink = cell.item_code
        ? `<a href="item-ledger-entries.html?search=${encodeURIComponent(cell.item_code)}${(editing ? draft.warehouse_id : (currentShelf() || {}).warehouse_id) ? '&warehouse=' + encodeURIComponent(editing ? draft.warehouse_id : currentShelf().warehouse_id) : ''}" class="cell-sub" onclick="event.stopPropagation()">${escapeHtml(cell.item_code)}</a>`
        : '';
      return `<div class="shelf-cell ${st.cls}${editing ? ' editable' : ''}" data-r="${r}" data-c="${c}">
        <span class="cell-label">${escapeHtml(cell.label)}</span>
        <span class="cell-code">${escapeHtml(cell.model_code || '')}</span>
        <div class="cell-stats">
          <div class="cell-stat">
            <span class="cell-stat-label">Min. Shelf Count</span>
            ${countHtml}
          </div>
          ${st.onHand !== null ? `<div class="cell-stat cell-stat-onhand">
            <span class="cell-stat-label">Stock on hand</span>
            <span class="cell-onhand">${escapeHtml(st.onHand)}</span>
          </div>` : ''}
          ${pendingHtml(cell, warehouseId)}
        </div>
        ${st.sub ? `<span class="cell-sub">${escapeHtml(st.sub)}</span>` : ''}
        ${itemLink}
        ${!editing && countedLabel(cell) ? `<span class="cell-sub">${escapeHtml(countedLabel(cell))}</span>` : ''}
        ${cell.notes ? `<span class="cell-sub">${escapeHtml(cell.notes)}</span>` : ''}
      </div>`;
    }).join('');
    const addBtn = editing
      ? `<button type="button" class="btn btn-secondary btn-sm shelf-add-cell" data-addcell="${r}">+ Spot</button>
         <button type="button" class="btn btn-secondary btn-sm shelf-add-cell" data-delrow="${r}">Delete Row</button>`
      : '';
    return `<div class="shelf-row">${cellsHtml}${addBtn}</div>`;
  }).join('');
}

// Shelves are grouped per location (warehouse). Location key '' = shelves with no location set yet.
let currentLocation = null;

function locationKey(shelf) {
  return shelf.warehouse_id || '';
}

function renderShelfSelect() {
  const shelf = currentShelf();
  if (shelf) currentLocation = locationKey(shelf);

  const locations = [];
  shelves.forEach((s) => {
    if (!locations.some((l) => l.key === locationKey(s))) {
      locations.push({ key: locationKey(s), name: s.warehouse_name || s.warehouse_id || 'No location set' });
    }
  });
  const locSelect = document.getElementById('locationSelect');
  locSelect.innerHTML = locations.map((l) => `<option value="${escapeHtml(l.key)}">${escapeHtml(l.name)}</option>`).join('');
  if (currentLocation !== null) locSelect.value = currentLocation;
  locSelect.disabled = !!draft;

  const select = document.getElementById('shelfSelect');
  select.innerHTML = shelves.filter((s) => locationKey(s) === currentLocation)
    .map((s) => `<option value="${s.id}">${escapeHtml(s.name)}</option>`).join('');
  if (currentShelfId) select.value = String(currentShelfId);
  select.disabled = !!draft;

  document.getElementById('warehouseLabel').textContent = shelf && !shelf.warehouse_id
    ? 'No location set on this shelf - Edit Layout and pick one to see ledger quantities.'
    : '';

  loadLastReplenishment(shelf);
}

// The most recent replenishment transfer order made from this shelf's button (createReplenishmentTransfer
// below), found by its description "Shelf replenishment - <shelf name>". An open order is preferred;
// if none is open, the latest one already posted/archived is shown instead.
let lastReplenishmentToken = 0;

async function loadLastReplenishment(shelf) {
  const el = document.getElementById('lastReplenishment');
  const token = ++lastReplenishmentToken;
  el.innerHTML = '';
  if (!shelf) return;

  const description = `${REPLENISH_DESCRIPTION_PREFIX}${shelf.name}`;
  const columns = '"No.", "Status", "Requested Date", "Requested By", "To Warehouse"';

  let posted = false;
  let { data } = await supabaseClient.from('Transfer_Header').select(columns)
    .eq('"Description"', description)
    .order('"Locked At"', { ascending: false, nullsFirst: false })
    .order('"No."', { ascending: false })
    .limit(1);
  if (!data || data.length === 0) {
    const archived = await supabaseClient.from('Posted_Transfer_Header').select(columns)
      .eq('"Description"', description)
      .order('"Requested Date"', { ascending: false })
      .order('"No."', { ascending: false })
      .limit(1);
    data = archived.data;
    posted = true;
  }
  if (token !== lastReplenishmentToken) return; // another shelf was picked meanwhile

  if (!data || data.length === 0) {
    el.textContent = 'No replenishment transfer order yet.';
    return;
  }
  const t = data[0];
  const page = posted ? 'posted-transfer-orders.html' : 'transfer-orders.html';
  const date = t['Requested Date'] ? new Date(t['Requested Date']).toLocaleDateString() : '';
  el.innerHTML = `Last replenishment TO: <a href="${page}?doc=${encodeURIComponent(t['No.'])}">${escapeHtml(t['No.'])}</a>` +
    ` - ${escapeHtml(t['Status'] || (posted ? 'Posted' : ''))}${date ? ', requested ' + escapeHtml(date) : ''}` +
    `${t['Requested By'] ? ' by ' + escapeHtml(t['Requested By']) : ''}`;
}

async function loadWarehouseOptions() {
  if (warehousesLoaded) return;
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;
  const select = document.getElementById('shelfWarehouseSelect');
  data.forEach((w) => {
    const option = document.createElement('option');
    option.value = w.id;
    option.textContent = w.name;
    select.appendChild(option);
  });
  warehousesLoaded = true;
}

async function loadShelves(keepId) {
  document.getElementById('shelfLoading').classList.remove('hidden');
  showError('');
  const { data, error } = await supabaseClient.rpc('staff_get_shelf_maps', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  document.getElementById('shelfLoading').classList.add('hidden');
  if (error) {
    showError(error.message);
    return;
  }
  shelves = data || [];
  currentShelfId = shelves.some((s) => s.id === keepId) ? keepId
    : (shelves.some((s) => s.id === currentShelfId) ? currentShelfId : (shelves[0] ? shelves[0].id : null));
  renderShelfSelect();
  renderShelf();
}

// Mirrors staff_set_shelf_cell_count + staff_get_shelf_maps' shelf_total (sum of CurrentQty for
// the item across every shelf at the same warehouse) after a count is saved.
function applyLocalCount(cellId, qty) {
  let target = null;
  let warehouseId = null;
  shelves.forEach((s) => (s.cells || []).forEach((c) => {
    if (c.id === cellId) { target = c; warehouseId = s.warehouse_id; }
  }));
  if (!target) return;
  target.current_qty = qty;
  target.counted_at = new Date().toISOString();
  target.counted_by = currentSession.username;
  if (!target.item_code) return;

  const sameItem = shelves.filter((s) => (s.warehouse_id ?? null) === (warehouseId ?? null))
    .flatMap((s) => s.cells || [])
    .filter((c) => c.item_code === target.item_code);
  const counted = sameItem.filter((c) => c.current_qty != null);
  const total = counted.length ? counted.reduce((n, c) => n + Number(c.current_qty), 0) : null;
  sameItem.forEach((c) => { c.shelf_total = total; });
}

function setEditing(on) {
  document.getElementById('editBar').classList.toggle('hidden', !on);
  // Layout editing: Super User or Store Manager; everyone else views + updates counts.
  const canEditLayout = !!(currentSession.isSuperUser || currentSession.isStoreManager);
  document.getElementById('editBtn').classList.toggle('hidden', on || !canEditLayout);
  document.getElementById('newShelfBtn').classList.toggle('hidden', on || !canEditLayout);
  document.getElementById('replenishBtn').classList.toggle('hidden', on);
  document.getElementById('legend').classList.toggle('hidden', false);
  document.getElementById('shelfSelect').disabled = on;
}

function startEdit(newShelf) {
  const shelf = currentShelf();
  draft = newShelf
    ? { id: null, name: '', warehouse_id: currentLocation || '', rows: [[]] }
    : {
        id: shelf.id,
        name: shelf.name,
        warehouse_id: shelf.warehouse_id || '',
        rows: cellsToRows(shelf.cells).map((row) => row.map((c) => ({ ...c })))
      };
  document.getElementById('shelfNameInput').value = draft.name;
  document.getElementById('deleteShelfBtn').classList.toggle('hidden', !draft.id);
  loadWarehouseOptions().then(() => {
    document.getElementById('shelfWarehouseSelect').value = draft.warehouse_id || '';
  });
  setEditing(true);
  renderShelf();
}

function cancelEdit() {
  draft = null;
  setEditing(false);
  renderShelfSelect();
  renderShelf();
}

async function saveDraft() {
  draft.name = document.getElementById('shelfNameInput').value.trim();
  draft.warehouse_id = document.getElementById('shelfWarehouseSelect').value;
  if (!draft.name) {
    window.alert('Give the shelf a name first.');
    return;
  }
  if (!draft.warehouse_id) {
    window.alert('Pick the location (warehouse) this shelf is in first.');
    return;
  }
  const cells = [];
  draft.rows.forEach((row, r) => row.forEach((c, i) => cells.push({
    row_no: r, col_no: i, label: c.label || '', model_code: c.model_code || null,
    item_code: c.item_code || null, drawn_qty: c.drawn_qty == null || c.drawn_qty === '' ? null : Number(c.drawn_qty),
    notes: c.notes || null,
    current_qty: c.current_qty == null || c.current_qty === '' ? null : Number(c.current_qty),
    counted_at: c.counted_at || null, counted_by: c.counted_by || null
  })));

  const btn = document.getElementById('saveBtn');
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_save_shelf_map', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_id: draft.id,
    p_name: draft.name,
    p_warehouse_id: draft.warehouse_id || null,
    p_cells: cells
  });
  btn.disabled = false;
  if (error) {
    window.alert('Failed to save: ' + error.message);
    return;
  }
  draft = null;
  setEditing(false);
  await loadShelves(data);
}

async function searchItems(term, limit) {
  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: term,
    p_limit: limit
  });
  return error ? [] : (data || []);
}

// Links every unlinked spot whose model code matches exactly ONE item - ambiguous or unmatched
// spots are left for a person to pick, never guessed.
async function autoLinkItems() {
  const btn = document.getElementById('autoLinkBtn');
  btn.disabled = true;
  btn.textContent = 'Linking...';
  let linked = 0;
  let pending = 0;
  for (const row of draft.rows) {
    for (const cell of row) {
      if (cell.item_code || !cell.model_code) continue;
      pending++;
      const hits = await searchItems(cell.model_code, 5);
      if (hits.length === 1) {
        cell.item_code = hits[0].code;
        cell.item_name = hits[0].name;
        linked++;
      }
    }
  }
  btn.disabled = false;
  btn.textContent = 'Auto-link items';
  renderShelf();
  window.alert(`Linked ${linked} of ${pending} unlinked spots that have a model code. The rest matched none or several items - click them to pick the item by hand. Remember to Save.`);
}

// ---- cell modal ----
function openCellModal(r, c) {
  modalCell = { r, c };
  const cell = draft.rows[r][c];
  document.getElementById('cellLabel').value = cell.label || '';
  document.getElementById('cellModel').value = cell.model_code || '';
  document.getElementById('cellDrawn').value = cell.drawn_qty == null ? '' : cell.drawn_qty;
  document.getElementById('cellCurrent').value = cell.current_qty == null ? '' : cell.current_qty;
  document.getElementById('cellNotes').value = cell.notes || '';
  document.getElementById('cellItemSearch').value = '';
  document.getElementById('cellItemHits').innerHTML = '';
  document.getElementById('cellItemLabel').textContent = cell.item_code ? `${cell.item_code}${cell.item_name ? ' - ' + cell.item_name : ''}` : 'none';
  document.getElementById('cellModal').classList.remove('hidden');
}

function closeCellModal() {
  document.getElementById('cellModal').classList.add('hidden');
  modalCell = null;
}

function applyCellModal() {
  const cell = draft.rows[modalCell.r][modalCell.c];
  cell.label = document.getElementById('cellLabel').value.trim();
  cell.model_code = document.getElementById('cellModel').value.trim();
  const drawn = document.getElementById('cellDrawn').value;
  cell.drawn_qty = drawn === '' ? null : Number(drawn);
  const current = document.getElementById('cellCurrent').value;
  const newCurrent = current === '' ? null : Number(current);
  if (newCurrent !== (cell.current_qty == null ? null : Number(cell.current_qty))) {
    cell.current_qty = newCurrent;
    cell.counted_at = new Date().toISOString();
    cell.counted_by = currentSession.username;
  }
  cell.notes = document.getElementById('cellNotes').value.trim();
  closeCellModal();
  renderShelf();
}

let itemSearchTimer = null;
function onItemSearchInput() {
  clearTimeout(itemSearchTimer);
  const term = document.getElementById('cellItemSearch').value.trim();
  const hitsEl = document.getElementById('cellItemHits');
  if (!term) { hitsEl.innerHTML = ''; return; }
  itemSearchTimer = setTimeout(async () => {
    const hits = await searchItems(term, 10);
    hitsEl.innerHTML = hits.length
      ? hits.map((h) => `<div class="item-hit" data-code="${escapeHtml(h.code)}" data-name="${escapeHtml(h.name)}">${escapeHtml(h.code)} - ${escapeHtml(h.name)}</div>`).join('')
      : '<div class="muted" style="padding:6px;">No items found.</div>';
  }, 250);
}

function moveCell(delta) {
  const { r, c } = modalCell;
  const row = draft.rows[r];
  const to = c + delta;
  if (to < 0 || to >= row.length) return;
  applyCellModal();
  [row[c], row[to]] = [row[to], row[c]];
  renderShelf();
}

// ---------------------------------------------------------------- Stock List view
// Every item linked on any shelf at the selected location, one row per item (all its spots/shelves
// together), with sales, vendor and what's already on the way (staff_get_shelf_stock_list,
// sql/supabase_shelf_map_stock_list.sql). Super users tick rows and turn them into Purchase Orders,
// one per vendor, through the same staff_create_purchase_order the Purchase Orders page uses.
let currentView = 'map';
let stockRows = [];
let stockRowsKey = '';           // "<warehouseId>|<days>" the rows were loaded for
let stockLoadToken = 0;
let slSort = { key: 'status', dir: 1 };
// Per item, survives re-renders/filters: { checked, vendor, qty } - qty null = use the suggestion.
const slEdits = new Map();
let slPoGroups = [];

const VIEW_STORAGE_KEY = 'shelfMap.view';

function isPoUser() {
  return !!(currentSession && currentSession.isSuperUser);
}

function slDays() {
  return Number(document.getElementById('slDays').value) || 30;
}

// Same colours as the map: red = nothing on hand, orange = half of the Min. Shelf Count or less.
function stockStatus(r) {
  const onHand = Number(r.on_hand) || 0;
  const min = Number(r.min_qty) || 0;
  if (onHand <= 0) return 'empty';
  if (min > 0 && onHand <= min / 2) return 'low';
  return 'ok';
}

// Suggested buy = target - (on hand + in transit + unshipped TO from other stores + Warehouse stock
// + open PO). A TO not shipped yet FROM the Warehouse adds nothing on its own: its qty is still inside
// the Warehouse on hand, and if the Warehouse has none the TO can't ship - counting it would hide the
// buy (L-024: min 5, on hand 0, TO 15 waiting on an empty Warehouse used to show "-").
// Target is the Min. Shelf Count, or the units sold in the period when "Buy up to" says so and that's higher.
// Returns { qty, why } - why is the hover breakdown on the Suggested cell.
function stockSuggestion(r) {
  const min = Number(r.min_qty) || 0;
  const sold = Number(r.sold_here) || 0;
  const bySales = document.getElementById('slTarget').value === 'sales' && sold > min;
  const target = bySales ? sold : min;
  const parts = [
    ['on hand', Math.max(0, Number(r.on_hand) || 0)],
    ['in transit (TO shipped)', Number(r.pending_in_transit) || 0],
    ['TO from another store, not shipped', Number(r.pending_unshipped_other) || 0],
    ['Warehouse stock', Math.max(0, Number(r.warehouse_on_hand) || 0)],
    ['on PO', Number(r.on_po) || 0]
  ];
  const covered = parts.reduce((n, p) => n + p[1], 0);
  const qty = Math.max(0, Math.ceil(target - covered));
  let why = `Target ${formatQty(target)} (${bySales ? `sold ${slDays()}d` : 'Min. Shelf Count'})`
    + parts.filter((p) => p[1] > 0).map((p) => ` - ${p[0]} ${formatQty(p[1])}`).join('')
    + ` = ${formatQty(target - covered)}`;
  if (target <= 0) why = 'No Min. Shelf Count set (and no sales target) - nothing to top up to.';
  else if (qty <= 0 && (Number(r.warehouse_on_hand) || 0) > 0) why += ' - the Warehouse has it: transfer instead of buying.';
  return { qty, why };
}

function stockSuggested(r) {
  return stockSuggestion(r).qty;
}

function stockDaysLeft(r) {
  const sold = Number(r.sold_here) || 0;
  if (sold <= 0) return null;
  return Math.max(0, Number(r.on_hand) || 0) / (sold / slDays());
}

function slEdit(itemCode) {
  if (!slEdits.has(itemCode)) slEdits.set(itemCode, { checked: false, vendor: null, qty: null });
  return slEdits.get(itemCode);
}

function slOrderQty(r) {
  const e = slEdits.get(r.item_code);
  return e && e.qty != null ? e.qty : stockSuggested(r);
}

function slVendor(r) {
  const e = slEdits.get(r.item_code);
  return (e && e.vendor) || r.vendor_code || ((r.vendors || [])[0] || {}).code || '';
}

async function loadStockList(force) {
  const body = document.getElementById('stockListBody');
  const warehouseId = currentLocation;
  if (!warehouseId) {
    stockRows = [];
    body.innerHTML = '<p class="muted">Pick a location - shelves with no location set have no stock to list.</p>';
    return;
  }
  const key = `${warehouseId}|${slDays()}`;
  if (!force && key === stockRowsKey) { renderStockList(); return; }
  const token = ++stockLoadToken;
  body.innerHTML = '<p class="muted">Loading...</p>';
  const { data, error } = await supabaseClient.rpc('staff_get_shelf_stock_list', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_id: warehouseId,
    p_days: slDays()
  });
  if (token !== stockLoadToken) return;
  if (error) {
    body.innerHTML = `<p class="error-text">Could not load the stock list: ${escapeHtml(error.message)} (has supabase_shelf_map_stock_list.sql been run?)</p>`;
    return;
  }
  stockRows = data || [];
  stockRowsKey = key;
  renderStockList();
}

function visibleStockRows() {
  const filter = document.getElementById('slFilter').value;
  const term = document.getElementById('slSearch').value.trim().toLowerCase();
  const statusRank = { empty: 0, low: 1, ok: 2 };
  const rows = stockRows.filter((r) => {
    const st = stockStatus(r);
    if (filter === 'low' && st === 'ok') return false;
    if (filter === 'empty' && st !== 'empty') return false;
    if (filter === 'buy' && stockSuggested(r) <= 0) return false;
    if (term) {
      const hay = `${r.item_code} ${r.item_name} ${r.vendor_name || ''} ${r.vendor_code || ''} ${r.shelves || ''}`.toLowerCase();
      if (!hay.includes(term)) return false;
    }
    return true;
  });
  const val = (r) => {
    switch (slSort.key) {
      case 'item': return (r.item_name || r.item_code || '').toLowerCase();
      case 'vendor': return (r.vendor_name || r.vendor_code || '~').toLowerCase();
      case 'min': return Number(r.min_qty) || 0;
      case 'onhand': return Number(r.on_hand) || 0;
      case 'sold': return -(Number(r.sold_here) || 0);
      case 'soldall': return -(Number(r.sold_all) || 0);
      case 'daysleft': { const d = stockDaysLeft(r); return d == null ? Infinity : d; }
      case 'suggested': return -stockSuggested(r);
      default: return statusRank[stockStatus(r)] * 1e9 - (Number(r.sold_here) || 0);
    }
  };
  return rows.sort((a, b) => {
    const x = val(a); const y = val(b);
    return (x < y ? -1 : x > y ? 1 : 0) * slSort.dir;
  });
}

function updateSlPoButton() {
  const ticked = stockRows.filter((r) => slEdits.get(r.item_code)?.checked).length;
  document.getElementById('slCreatePoBtn').textContent = `Create Purchase Order(s)${ticked ? ` - ${ticked} item${ticked === 1 ? '' : 's'}` : ''}`;
}

function fmtDate(d) {
  return d ? new Date(d + 'T00:00:00').toLocaleDateString() : '-';
}

function renderStockList() {
  const body = document.getElementById('stockListBody');
  if (!currentLocation) return;
  const rows = visibleStockRows();
  const poUser = isPoUser();
  const days = slDays();

  const counts = { empty: 0, low: 0, buy: 0 };
  stockRows.forEach((r) => {
    const st = stockStatus(r);
    if (st === 'empty') counts.empty += 1;
    if (st === 'low') counts.low += 1;
    if (stockSuggested(r) > 0) counts.buy += 1;
  });
  updateSlPoButton();

  const th = (key, label, cls) => `<th class="sortable ${cls || ''}" data-sort="${key}">${label}${slSort.key === key ? (slSort.dir > 0 ? ' &#9650;' : ' &#9660;') : ''}</th>`;
  const head = `<tr>
    ${poUser ? '<th><input type="checkbox" id="slCheckAll" title="Tick every item shown with a quantity to order" /></th>' : ''}
    ${th('item', 'Item')}
    ${th('vendor', 'Vendor')}
    ${th('min', 'Min. Shelf', 'num')}
    ${th('onhand', 'On hand', 'num')}
    <th class="num">Pending TO</th>
    <th class="num" title="Item Ledger at the Warehouse location">Warehouse</th>
    <th class="num" title="Open purchase orders, any location">On PO</th>
    ${th('sold', `Sold ${days}d`, 'num')}
    ${th('soldall', 'Sold all loc.', 'num')}
    ${th('daysleft', 'Days left', 'num')}
    <th>Last sold</th>
    ${th('suggested', 'Suggested', 'num')}
    ${poUser ? '<th class="num">Order qty</th>' : ''}
  </tr>`;

  const bodyRows = rows.map((r) => {
    const st = stockStatus(r);
    const e = slEdits.get(r.item_code) || {};
    const vendors = r.vendors || [];
    const vendorCode = slVendor(r);
    const vendorCell = poUser && vendors.length > 1
      ? `<select class="sl-vendor" data-item="${escapeHtml(r.item_code)}">${vendors.map((v) =>
          `<option value="${escapeHtml(v.code)}"${v.code === vendorCode ? ' selected' : ''}>${escapeHtml(v.name)}${v.primary ? ' (primary)' : ''}${v.cost != null ? ' - ' + Number(v.cost).toLocaleString() : ''}</option>`).join('')}</select>`
      : (r.vendor_name || r.vendor_code
        ? `${escapeHtml(r.vendor_name || r.vendor_code)}${vendors.length > 1 ? `<span class="sl-sub">+${vendors.length - 1} other vendor(s)</span>` : ''}`
        : '<span class="badge badge-danger">No vendor</span>');
    const daysLeft = stockDaysLeft(r);
    const ledgerHref = `item-ledger-entries.html?search=${encodeURIComponent(r.item_code)}&warehouse=${encodeURIComponent(currentLocation)}`;
    const pending = Number(r.pending_to) || 0;
    const pendingCell = pending > 0 && r.pending_docs
      ? `<a href="transfer-orders.html?doc=${encodeURIComponent(r.pending_docs.split(', ')[0])}" title="${escapeHtml(r.pending_docs)}">${formatQty(pending)}</a>`
      : formatQty(pending);
    const onPo = Number(r.on_po) || 0;
    const poCell = onPo > 0 && r.open_pos
      ? `<a href="purchase-orders.html?search=${encodeURIComponent(r.open_pos.split(', ')[0])}" title="${escapeHtml(r.open_pos)}">${formatQty(onPo)}</a>`
      : formatQty(onPo);
    const { qty: suggested, why } = stockSuggestion(r);
    return `<tr class="st-${st}">
      ${poUser ? `<td><input type="checkbox" class="sl-check" data-item="${escapeHtml(r.item_code)}"${e.checked ? ' checked' : ''} /></td>` : ''}
      <td><a href="${ledgerHref}">${escapeHtml(r.item_code)}</a> ${escapeHtml(r.item_name && r.item_name !== r.item_code ? r.item_name : '')}
        <span class="sl-sub">${escapeHtml(r.shelves || '')}${r.spots > 1 ? ` - ${r.spots} spots` : ''}${r.variant_count > 1 ? ` - ${r.variant_count} variants` : ''}</span></td>
      <td>${vendorCell}</td>
      <td class="num">${formatQty(r.min_qty)}</td>
      <td class="num st-onhand">${formatQty(r.on_hand)}</td>
      <td class="num">${pendingCell}</td>
      <td class="num">${r.warehouse_on_hand == null ? '-' : formatQty(r.warehouse_on_hand)}</td>
      <td class="num">${poCell}</td>
      <td class="num"><strong>${formatQty(r.sold_here)}</strong></td>
      <td class="num">${formatQty(r.sold_all)}</td>
      <td class="num" title="On hand / average daily sales at this location over the period">${daysLeft == null ? '-' : Math.round(daysLeft).toLocaleString()}</td>
      <td title="Last received on a purchase: ${escapeHtml(fmtDate(r.last_purchased))}">${escapeHtml(fmtDate(r.last_sold))}</td>
      <td class="num" title="${escapeHtml(why)}" style="cursor:help;">${suggested > 0 ? `<strong>${formatQty(suggested)}</strong>` : '-'}</td>
      ${poUser ? `<td class="num"><input type="number" class="sl-qty" min="0" step="1" data-item="${escapeHtml(r.item_code)}" value="${escapeHtml(slOrderQty(r))}" /></td>` : ''}
    </tr>`;
  }).join('');

  body.innerHTML = `
    <div class="stock-summary">
      <span><strong>${stockRows.length}</strong> item(s) on this location's shelves</span>
      <span style="color:#d64545;"><strong>${counts.empty}</strong> out of stock</span>
      <span style="color:#d98a00;"><strong>${counts.low}</strong> low (half or less)</span>
      <span><strong>${counts.buy}</strong> suggested to buy</span>
      <span class="muted">Suggested = Buy up to - (on hand + TO in transit + Warehouse stock + on PO). A TO not shipped yet from the Warehouse doesn't count by itself. Hover a Suggested number for the breakdown.</span>
    </div>
    ${rows.length === 0
      ? '<p class="muted">Nothing to show for this filter.</p>'
      : `<div class="table-wrap"><table class="stock-table"><thead>${head}</thead><tbody>${bodyRows}</tbody></table></div>`}`;
}

function setView(view) {
  if (draft) return; // finish the layout edit first
  currentView = view === 'list' ? 'list' : 'map';
  try { localStorage.setItem(VIEW_STORAGE_KEY, currentView); } catch (_) { /* storage blocked */ }
  const list = currentView === 'list';
  document.getElementById('viewMapBtn').classList.toggle('active', !list);
  document.getElementById('viewListBtn').classList.toggle('active', list);
  document.querySelectorAll('.map-only').forEach((el) => el.classList.toggle('hidden', list));
  document.getElementById('legend').classList.toggle('hidden', list);
  document.getElementById('shelfBody').classList.toggle('hidden', list);
  document.getElementById('stockListBar').classList.toggle('hidden', !list);
  document.getElementById('stockListBody').classList.toggle('hidden', !list);
  document.getElementById('slCreatePoBtn').classList.toggle('hidden', !list || !isPoUser());
  if (list) {
    ['editBtn', 'newShelfBtn', 'replenishBtn'].forEach((id) => document.getElementById(id).classList.add('hidden'));
    loadStockList(false);
  } else {
    setEditing(false);
  }
}

// ---- Create Purchase Order(s) from the ticked rows, one per vendor ----
async function openSlPoModal() {
  const ticked = stockRows.filter((r) => slEdits.get(r.item_code)?.checked);
  if (ticked.length === 0) {
    window.alert('Tick the items to order first (the box at the start of each row).');
    return;
  }
  const byVendor = new Map();
  const noVendor = [];
  const zeroQty = [];
  ticked.forEach((r) => {
    const qty = Number(slOrderQty(r)) || 0;
    if (qty <= 0) { zeroQty.push(r.item_code); return; }
    const code = slVendor(r);
    if (!code) { noVendor.push(r.item_code); return; }
    const v = (r.vendors || []).find((x) => x.code === code) || { code, name: r.vendor_name || code, cost: r.unit_cost };
    if (!byVendor.has(code)) byVendor.set(code, { vendorCode: code, vendorName: v.name || code, lines: [] });
    byVendor.get(code).lines.push({ row: r, qty, cost: v.cost == null ? null : Number(v.cost) });
  });
  slPoGroups = Array.from(byVendor.values()).sort((a, b) => a.vendorName.localeCompare(b.vendorName));

  const select = document.getElementById('slPoWarehouse');
  if (!select.options.length) {
    const { data } = await supabaseClient.rpc('staff_search_warehouses', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_search: null,
      p_limit: 100
    });
    select.innerHTML = (data || []).map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
    const main = (data || []).find((w) => (w.name || '').toLowerCase() === REPLENISH_FROM_WAREHOUSE_NAME.toLowerCase());
    if (main) select.value = main.id;
  }
  const locationName = (shelves.find((s) => locationKey(s) === currentLocation) || {}).warehouse_name || currentLocation;
  document.getElementById('slPoNotes').value = `From Shelf Map stock list - ${locationName}`;
  document.getElementById('slPoIntro').textContent =
    `${ticked.length} ticked item(s). One Purchase Order per vendor. Adjust quantities or untick a vendor to skip it. Unit cost blank = the item's catalog cost.`;

  const groupsHtml = slPoGroups.map((g, gi) => `
    <div style="margin-bottom:14px;">
      <label style="display:flex; gap:8px; align-items:center; font-weight:600; margin-bottom:4px;">
        <input type="checkbox" class="sl-po-vendor-check" data-group="${gi}" checked /> ${escapeHtml(g.vendorName)} <span class="muted" style="font-weight:400;">(${escapeHtml(g.vendorCode)})</span>
      </label>
      <div class="table-wrap"><table class="stock-table">
        <thead><tr><th>Item</th><th class="num">On hand</th><th class="num">Sold ${slDays()}d</th><th class="num">Qty</th><th class="num">Unit cost</th></tr></thead>
        <tbody>${g.lines.map((l, li) => `
          <tr>
            <td>${escapeHtml(l.row.item_code)} ${escapeHtml(l.row.item_name || '')}
              ${l.row.variant_count > 1 ? '<span class="sl-sub">Several variants - pick the variant when receiving.</span>' : ''}</td>
            <td class="num">${formatQty(l.row.on_hand)}</td>
            <td class="num">${formatQty(l.row.sold_here)}</td>
            <td class="num"><input type="number" class="sl-qty sl-po-qty" data-group="${gi}" data-line="${li}" min="0" step="1" value="${l.qty}" /></td>
            <td class="num"><input type="number" class="sl-qty sl-po-cost" data-group="${gi}" data-line="${li}" min="0" step="0.01" value="${l.cost == null ? '' : l.cost}" style="width:96px;" /></td>
          </tr>`).join('')}
        </tbody>
      </table></div>
    </div>`).join('');
  const notes = (noVendor.length ? `<div class="error-text" style="margin-bottom:8px;">No vendor set on: ${noVendor.map(escapeHtml).join(', ')} - set the Vendor No. in Item Setup. Not included.</div>` : '')
    + (zeroQty.length ? `<div class="muted" style="margin-bottom:8px;">Order qty is 0 for: ${zeroQty.map(escapeHtml).join(', ')} - not included.</div>` : '');
  document.getElementById('slPoBody').innerHTML = notes + (groupsHtml || '<p class="muted">Nothing to order.</p>');
  document.getElementById('slPoError').classList.add('hidden');
  document.getElementById('slPoResult').innerHTML = '';
  document.getElementById('slPoConfirmBtn').classList.toggle('hidden', slPoGroups.length === 0);
  document.getElementById('slPoConfirmBtn').disabled = false;
  document.getElementById('slPoModal').classList.remove('hidden');
}

async function confirmSlPo() {
  const errorEl = document.getElementById('slPoError');
  errorEl.classList.add('hidden');
  const select = document.getElementById('slPoWarehouse');
  const warehouseId = select.value;
  const warehouseName = select.selectedOptions[0] ? select.selectedOptions[0].textContent : null;
  if (!warehouseId) {
    errorEl.textContent = 'Pick the location to receive into.';
    errorEl.classList.remove('hidden');
    return;
  }
  const btn = document.getElementById('slPoConfirmBtn');
  btn.disabled = true;
  const results = [];
  const failures = [];

  for (let gi = 0; gi < slPoGroups.length; gi++) {
    const group = slPoGroups[gi];
    const check = document.querySelector(`.sl-po-vendor-check[data-group="${gi}"]`);
    if (!check?.checked) continue;
    const lines = group.lines.map((l, li) => {
      const qty = Number(document.querySelector(`.sl-po-qty[data-group="${gi}"][data-line="${li}"]`)?.value) || 0;
      const rawCost = (document.querySelector(`.sl-po-cost[data-group="${gi}"][data-line="${li}"]`)?.value || '').trim();
      return {
        item_code: l.row.item_code,
        item_name: l.row.item_name || l.row.item_code,
        quantity: qty,
        // Exactly one variant -> use it (same rule as the Replenishment TO); several -> picked on receipt.
        variant_code: l.row.variant_id || null,
        variant_name: l.row.variant_name || null,
        warehouse_id: warehouseId,
        warehouse_name: warehouseName,
        unit_cost: rawCost === '' ? null : rawCost
      };
    }).filter((l) => l.quantity > 0);
    if (lines.length === 0) continue;

    const { data, error } = await supabaseClient.rpc('staff_create_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendor_code: group.vendorCode,
      p_notes: document.getElementById('slPoNotes').value.trim() || null,
      p_lines: lines,
      p_warehouse_id: warehouseId,
      p_warehouse_name: warehouseName
    });
    if (error) {
      failures.push(`${group.vendorName}: ${error.message || error}`);
    } else {
      results.push({ vendor: group.vendorName, poNo: data });
      // Done - stop it being created twice by a second click.
      check.checked = false;
      check.disabled = true;
      group.lines.forEach((l) => slEdits.delete(l.row.item_code));
    }
  }

  btn.disabled = false;
  if (failures.length) {
    errorEl.textContent = 'Some Purchase Orders could not be created - ' + failures.join('; ');
    errorEl.classList.remove('hidden');
  }
  if (results.length) {
    document.getElementById('slPoResult').innerHTML = '<p><strong>Created:</strong></p><ul>' + results.map((r) =>
      `<li>${escapeHtml(r.vendor)}: <a href="purchase-order-print.html?po=${encodeURIComponent(r.poNo)}">${escapeHtml(r.poNo)}</a></li>`).join('') + '</ul>';
    loadStockList(true); // On PO / Suggested now include the new orders
  } else if (!failures.length) {
    errorEl.textContent = 'Nothing to create - tick a vendor and enter a quantity above 0.';
    errorEl.classList.remove('hidden');
  }
}

function wireStockList() {
  document.getElementById('viewMapBtn').addEventListener('click', () => setView('map'));
  document.getElementById('viewListBtn').addEventListener('click', () => setView('list'));
  ['slFilter', 'slTarget'].forEach((id) => document.getElementById(id).addEventListener('change', renderStockList));
  document.getElementById('slDays').addEventListener('change', () => loadStockList(false));
  let searchTimer = null;
  document.getElementById('slSearch').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(renderStockList, 200);
  });

  const listBody = document.getElementById('stockListBody');
  listBody.addEventListener('click', (e) => {
    const sortTh = e.target.closest('th[data-sort]');
    if (!sortTh) return;
    const key = sortTh.dataset.sort;
    slSort = { key, dir: slSort.key === key ? -slSort.dir : 1 };
    renderStockList();
  });
  listBody.addEventListener('change', (e) => {
    const t = e.target;
    if (t.id === 'slCheckAll') {
      visibleStockRows().forEach((r) => {
        if (!t.checked) slEdit(r.item_code).checked = false;
        else if ((Number(slOrderQty(r)) || 0) > 0) slEdit(r.item_code).checked = true;
      });
      renderStockList();
      return;
    }
    // Updated in place (no re-render) so tabbing between the qty boxes keeps the cursor.
    const item = t.dataset.item;
    if (!item) return;
    if (t.classList.contains('sl-check')) slEdit(item).checked = t.checked;
    else if (t.classList.contains('sl-vendor')) slEdit(item).vendor = t.value;
    else if (t.classList.contains('sl-qty')) {
      slEdit(item).qty = t.value === '' ? null : Math.max(0, Number(t.value) || 0);
      if (slEdit(item).qty > 0) {
        slEdit(item).checked = true; // typing a qty means "order this"
        const box = t.closest('tr')?.querySelector('.sl-check');
        if (box) box.checked = true;
      }
    }
    updateSlPoButton();
  });

  document.getElementById('slCreatePoBtn').addEventListener('click', openSlPoModal);
  document.getElementById('slPoConfirmBtn').addEventListener('click', confirmSlPo);
  document.getElementById('slPoCloseBtn').addEventListener('click', () => document.getElementById('slPoModal').classList.add('hidden'));
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Shelf Map');
  setEditing(false);

  document.getElementById('shelfSelect').addEventListener('change', (e) => {
    currentShelfId = Number(e.target.value);
    renderShelfSelect();
    renderShelf();
  });
  document.getElementById('locationSelect').addEventListener('change', (e) => {
    const first = shelves.find((s) => locationKey(s) === e.target.value);
    currentShelfId = first ? first.id : null;
    currentLocation = e.target.value;
    renderShelfSelect();
    renderShelf();
    if (currentView === 'list') loadStockList(false);
  });
  // Live count entry in view mode - saved the moment the number is committed (blur/Enter). The
  // count only changes this cell and its item's shelf_total, both recomputed here from the shelves
  // already loaded, rather than re-fetching every shelf after each entry (an extra round trip per
  // count on a phone). Refresh still pulls the server's figures.
  document.getElementById('shelfBody').addEventListener('change', async (e) => {
    if (!e.target.classList.contains('cell-count')) return;
    const raw = e.target.value;
    const cellId = Number(e.target.dataset.cellid);
    const qty = raw === '' ? null : Number(raw);
    e.target.disabled = true;
    const { error } = await supabaseClient.rpc('staff_set_shelf_cell_count', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_cell_id: cellId,
      p_qty: qty
    });
    if (error) {
      e.target.disabled = false;
      window.alert('Failed to save count: ' + error.message);
      return;
    }
    applyLocalCount(cellId, qty);
    // Keep the cursor in whichever count box was tapped next - the re-render replaces the inputs.
    const nextId = document.activeElement?.classList.contains('cell-count') ? document.activeElement.dataset.cellid : null;
    renderShelf();
    if (nextId) document.querySelector(`.cell-count[data-cellid="${nextId}"]`)?.focus();
  });
  document.getElementById('refreshBtn').addEventListener('click', async () => {
    pendingByWarehouse = {};
    await loadShelves();
    if (currentView === 'list') loadStockList(true);
  });
  document.getElementById('replenishBtn').addEventListener('click', createReplenishmentTransfer);
  document.getElementById('editBtn').addEventListener('click', () => { if (currentShelf()) startEdit(false); });
  document.getElementById('newShelfBtn').addEventListener('click', () => startEdit(true));
  document.getElementById('cancelBtn').addEventListener('click', cancelEdit);
  document.getElementById('saveBtn').addEventListener('click', saveDraft);
  document.getElementById('addRowBtn').addEventListener('click', () => { draft.rows.push([]); renderShelf(); });
  document.getElementById('autoLinkBtn').addEventListener('click', autoLinkItems);
  document.getElementById('shelfWarehouseSelect').addEventListener('change', (e) => { draft.warehouse_id = e.target.value; });
  document.getElementById('deleteShelfBtn').addEventListener('click', async () => {
    if (!draft.id || !window.confirm(`Delete shelf "${draft.name}" and its layout? Stock in the ledger is not affected.`)) return;
    const { error } = await supabaseClient.rpc('admin_delete_shelf_map', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_id: draft.id
    });
    if (error) { window.alert('Failed to delete: ' + error.message); return; }
    draft = null;
    currentShelfId = null;
    setEditing(false);
    await loadShelves();
  });

  document.getElementById('shelfBody').addEventListener('click', (e) => {
    if (!draft) return;
    const addCell = e.target.closest('[data-addcell]');
    const delRow = e.target.closest('[data-delrow]');
    const cellEl = e.target.closest('.shelf-cell');
    if (addCell) {
      const r = Number(addCell.dataset.addcell);
      draft.rows[r].push({ label: '', model_code: '', item_code: null, drawn_qty: null, notes: '' });
      renderShelf();
      openCellModal(r, draft.rows[r].length - 1);
    } else if (delRow) {
      const r = Number(delRow.dataset.delrow);
      if (draft.rows[r].length && !window.confirm('Delete this row and every spot in it?')) return;
      draft.rows.splice(r, 1);
      renderShelf();
    } else if (cellEl) {
      openCellModal(Number(cellEl.dataset.r), Number(cellEl.dataset.c));
    }
  });

  document.getElementById('cellOkBtn').addEventListener('click', applyCellModal);
  document.getElementById('cellCancelBtn').addEventListener('click', closeCellModal);
  document.getElementById('cellLeftBtn').addEventListener('click', () => moveCell(-1));
  document.getElementById('cellRightBtn').addEventListener('click', () => moveCell(1));
  document.getElementById('cellDeleteBtn').addEventListener('click', () => {
    draft.rows[modalCell.r].splice(modalCell.c, 1);
    closeCellModal();
    renderShelf();
  });
  document.getElementById('cellUnlinkBtn').addEventListener('click', () => {
    const cell = draft.rows[modalCell.r][modalCell.c];
    cell.item_code = null;
    cell.item_name = null;
    document.getElementById('cellItemLabel').textContent = 'none';
  });
  document.getElementById('cellItemSearch').addEventListener('input', onItemSearchInput);
  document.getElementById('cellItemHits').addEventListener('click', (e) => {
    const hit = e.target.closest('.item-hit');
    if (!hit) return;
    const cell = draft.rows[modalCell.r][modalCell.c];
    cell.item_code = hit.dataset.code;
    cell.item_name = hit.dataset.name;
    document.getElementById('cellItemLabel').textContent = `${cell.item_code} - ${cell.item_name}`;
    document.getElementById('cellItemHits').innerHTML = '';
  });

  wireStockList();
  await loadShelves();
  // ?view=list deep link, else whichever view this browser used last.
  let startView = new URLSearchParams(window.location.search).get('view');
  if (!startView) { try { startView = localStorage.getItem(VIEW_STORAGE_KEY); } catch (_) { startView = null; } }
  if (startView === 'list') setView('list');
})();
