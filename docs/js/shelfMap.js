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
// the item) against the ledger's on-hand for that location.
function cellStatus(cell) {
  const drawing = cell.drawn_qty != null ? `Drawing: ${formatQty(cell.drawn_qty)}` : '';
  if (!cell.item_code) return { cls: 'unlinked', sub: drawing };
  if (cell.on_hand === null || cell.on_hand === undefined) return { cls: 'unlinked', sub: [drawing, 'pick a location'].filter(Boolean).join(' - ') };
  const onHand = Number(cell.on_hand);
  const shelfTotal = Number(cell.shelf_total || 0);
  let cls = 'diff';
  if (onHand <= 0 && shelfTotal === 0) cls = 'empty';
  else if (shelfTotal === onHand) cls = 'ok';
  const shared = cell.item_cells > 1 ? ` (shelf total ${formatQty(shelfTotal)}, ${cell.item_cells} spots)` : '';
  return { cls, sub: `Ledger: ${formatQty(onHand)}${shared}${drawing ? ' | ' + drawing : ''}` };
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
        ${countHtml}
        <span class="cell-sub">${escapeHtml(st.sub)}</span>
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

function setEditing(on) {
  document.getElementById('editBar').classList.toggle('hidden', !on);
  // Layout editing is Super User only; Store Managers (and everyone else) view + update counts.
  const canEditLayout = !!currentSession.isSuperUser;
  document.getElementById('editBtn').classList.toggle('hidden', on || !canEditLayout);
  document.getElementById('newShelfBtn').classList.toggle('hidden', on || !canEditLayout);
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
  });
  // Live count entry in view mode - saved the moment the number is committed (blur/Enter), then
  // the map reloads so every spot's colour/shelf total is recomputed against the ledger.
  document.getElementById('shelfBody').addEventListener('change', async (e) => {
    if (!e.target.classList.contains('cell-count')) return;
    const raw = e.target.value;
    e.target.disabled = true;
    const { error } = await supabaseClient.rpc('staff_set_shelf_cell_count', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_cell_id: Number(e.target.dataset.cellid),
      p_qty: raw === '' ? null : Number(raw)
    });
    if (error) {
      e.target.disabled = false;
      window.alert('Failed to save count: ' + error.message);
      return;
    }
    await loadShelves(currentShelfId);
  });
  document.getElementById('refreshBtn').addEventListener('click', () => loadShelves());
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

  await loadShelves();
})();
