// Production Orders (docs/production-orders.html, sql/supabase_production_orders.sql) - restock builds of
// aquariums, sumps and stands. A Super User / Production Manager creates an order, assigns the Tank /
// Stand Maker, Releases it (it then shows on the makers' My Assignments), and posts Output as units
// are finished - into the Item Ledger at the order's warehouse, with new IN_STOCK serials for
// serial-tracked items. A maker opening this page only sees their own Released orders, read-only,
// with a Production Done button for their part.
//
// production-orders.html?view=finished is the Finished Production Orders list (managers only) - the
// same card, but the list is Finished orders only. The main list defaults to Active (Open + Released),
// so Finished orders drop off it (supabase_production_finished_orders_view.sql).
const FINISHED_VIEW = new URLSearchParams(window.location.search).get('view') === 'finished';
let currentSession = null;
let isManager = false;
let currentSearch = '';
let currentStatus = FINISHED_VIEW ? 'Finished' : 'Active';
let currentPage = 1;
let currentPageSize = 50;
let searchDebounceHandle = null;

let warehouses = [];
let makers = [];
let openOrder = null; // list row of the order on the card, null for a new one
let cardDirty = false;

const PROD_MAXIMIZED_KEY = 'prod-card-maximized';
const PART_LABEL = { tank: 'Tank', stand: 'Stand' };

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
}

function describeSupabaseError(err, fallback) {
  console.error(fallback, err);
  const parts = [err?.message, err?.details, err?.hint].filter(Boolean);
  return parts.length ? parts.join(' - ') : fallback;
}

function formatDate(value) {
  if (!value) return '';
  const [y, m, d] = String(value).slice(0, 10).split('-').map(Number);
  if (!y) return value;
  return new Date(y, m - 1, d).toLocaleDateString();
}

// A timestamp (created_at) as local date + time.
function formatCreatedAt(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d) ? String(value) : d.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
}

function formatQty(value) {
  return Number(value || 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
}

// Same "Stand / Top Cover goes to the Stand Maker" split the server applies (_production_line_part) -
// shown live while a line is typed; the server's value is what's saved.
function linePart(description, itemCode) {
  return /(stand(?!ard)|top[\s_-]*cover)/i.test(`${description || ''} ${itemCode || ''}`) ? 'stand' : 'tank';
}

function readStoredFlag(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value === null ? fallback : value === '1';
  } catch (err) {
    return fallback;
  }
}

function writeStoredFlag(key, value) {
  try { localStorage.setItem(key, value ? '1' : '0'); } catch (err) { /* not persisted */ }
}

function statusBadgeHtml(status) {
  const cls = status === 'Finished' ? 'badge-success' : status === 'Released' ? 'badge-warning' : 'badge-neutral';
  return `<span class="badge ${cls}">${escapeHtml(status)}</span>`;
}

function outputBadgeHtml(o) {
  const total = Number(o.total_quantity || 0);
  const done = Number(o.total_output || 0);
  if (done <= 0) return '<span class="muted">None</span>';
  if (done >= total) return '<span class="badge badge-success">All output</span>';
  return `<span class="badge badge-warning">${formatQty(done)} / ${formatQty(total)}</span>`;
}

function makerCellHtml(needed, name, doneAt) {
  if (!needed) return '<span class="muted">-</span>';
  if (!name) return '<span class="muted">Not assigned</span>';
  return `${escapeHtml(name)}${doneAt ? ' <span class="badge badge-success" title="Production Done">&#10003; Done</span>' : ''}`;
}

// ---------------------------------------------------------------- List

let lastRows = [];

async function loadProductionOrders() {
  const tbody = document.getElementById('prodTableBody');
  tbody.innerHTML = '<tr><td colspan="11" class="cell-msg">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_production_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    // Makers only ever get their Released orders (server-side), so no status filter for them.
    p_status: isManager ? (currentStatus || null) : null,
    p_assigned_to_me: !isManager,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="11" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  lastRows = data || [];
  tbody.innerHTML = lastRows.length === 0
    ? `<tr><td colspan="11" class="cell-msg">${!isManager ? 'No production orders are assigned to you right now.'
      : FINISHED_VIEW ? 'No finished production orders yet.'
      : currentStatus === 'Active' && !currentSearch ? 'No open or released production orders - create one with New. Finished ones are under Finished Production Orders.'
      : 'No production orders match.'}</td></tr>`
    : lastRows.map((o) => `
      <tr class="clickable-row" data-order-no="${escapeHtml(o.order_no)}">
        <td><span class="bc-doc-no">${escapeHtml(o.order_no)}</span></td>
        <td>${escapeHtml(o.description || '')}</td>
        <td>${escapeHtml(o.warehouse_name || o.warehouse_id || '')}</td>
        <td>${statusBadgeHtml(o.status)}</td>
        <td>${escapeHtml(formatDate(o.due_date))}</td>
        <td class="num">${o.line_count ?? 0}</td>
        <td>${outputBadgeHtml(o)}</td>
        <td>${makerCellHtml(o.needs_tank, o.tank_maker_name, o.tank_done_at)}</td>
        <td>${makerCellHtml(o.needs_stand, o.stand_maker_name, o.stand_done_at)}</td>
        <td>${escapeHtml(o.created_by || '')}</td>
        <td>${escapeHtml(formatCreatedAt(o.created_at))}</td>
      </tr>`).join('');

  renderPaginationBar(
    document.getElementById('prodPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: lastRows[0]?.total_count || 0 },
    {
      onPageChange: (p) => { currentPage = p; loadProductionOrders(); },
      onPageSizeChange: (s) => { currentPageSize = s; currentPage = 1; loadProductionOrders(); }
    }
  );
  fitGridToViewport();
}

function fitGridToViewport() {
  const el = document.getElementById('prodGridWrap');
  if (!el || el.offsetParent === null) return;
  el.style.maxHeight = Math.max(240, window.innerHeight - el.getBoundingClientRect().top - 64) + 'px';
}

// Fetches one order's list row directly (the card needs it even when it's not on the current page,
// e.g. opened from My Assignments with ?no=).
async function fetchOrderRow(orderNo) {
  const { data, error } = await supabaseClient.rpc('staff_list_production_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: orderNo,
    p_status: null,
    p_assigned_to_me: !isManager,
    p_page: 1,
    p_page_size: 50
  });
  if (error) throw error;
  return (data || []).find((o) => o.order_no === orderNo) || null;
}

// ---------------------------------------------------------------- Lookups

async function loadWarehouses() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (!error) warehouses = data || [];
}

async function loadMakers() {
  const { data, error } = await supabaseClient.rpc('staff_list_order_makers', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (!error) makers = data || [];
}

// Default for a new order: the user's own warehouse if it's a production warehouse, otherwise the
// first production warehouse, otherwise nothing picked.
function defaultWarehouseId() {
  const mine = (currentSession.warehouseName || '').trim().toLowerCase();
  const own = warehouses.find((w) => w.is_production_warehouse && (w.name || '').trim().toLowerCase() === mine);
  return (own || warehouses.find((w) => w.is_production_warehouse))?.id || '';
}

function fillWarehouseSelect(selectedId) {
  const select = document.getElementById('prodWarehouse');
  const sorted = [...warehouses].sort((a, b) => Number(b.is_production_warehouse) - Number(a.is_production_warehouse) || (a.name || '').localeCompare(b.name || ''));
  select.innerHTML = '<option value="">Select a warehouse...</option>' + sorted
    .map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}${w.is_production_warehouse ? ' (production)' : ''}</option>`)
    .join('');
  select.value = selectedId || '';
}

function fillMakerSelect(selectId, role, selected, selectedName) {
  const select = document.getElementById(selectId);
  const list = makers.filter((m) => (m.staff_roles || []).includes(role));
  // Keep a maker who has since lost the role visible rather than silently blanking the field.
  if (selected && !list.some((m) => m.username === selected)) list.push({ username: selected, display_name: selectedName || selected });
  select.innerHTML = '<option value="">Not assigned</option>' +
    list.map((m) => `<option value="${escapeHtml(m.username)}">${escapeHtml(m.display_name)}</option>`).join('');
  select.value = selected || '';
}

// ---------------------------------------------------------------- Card

function cardEditable() {
  return isManager && (!openOrder || openOrder.status !== 'Finished');
}

function showCardError(message) {
  const el = document.getElementById('prodCardError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function showCardNotice(message) {
  const el = document.getElementById('prodCardNotice');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function applyMaximized(maximized) {
  const modal = document.getElementById('prodCardModal');
  modal.classList.toggle('modal-maximized', maximized);
  modal.querySelector('.modal-panel').classList.toggle('modal-maximized', maximized);
  document.getElementById('prodCardMaximizeBtn').textContent = maximized ? 'Restore' : 'Maximize';
}

function refreshGeneralSummary() {
  const wh = document.getElementById('prodWarehouse');
  document.getElementById('prodCardGeneralSummary').textContent = [
    document.getElementById('prodDescription').value.trim(),
    wh.value ? wh.selectedOptions[0].textContent : '',
    document.getElementById('prodDueDate').value ? `Due ${formatDate(document.getElementById('prodDueDate').value)}` : ''
  ].filter(Boolean).join(' · ');
}

function renderCardHeader() {
  const o = openOrder;
  const status = o ? o.status : 'Open';
  document.getElementById('prodCardTitle').textContent = o ? `${o.order_no}${o.description ? ' · ' + o.description : ''}` : 'New Production Order';
  const badge = document.getElementById('prodCardStatusBadge');
  badge.className = `badge ${status === 'Finished' ? 'badge-success' : status === 'Released' ? 'badge-warning' : 'badge-neutral'}`;
  badge.textContent = status;
  badge.classList.toggle('hidden', !o);
  document.getElementById('prodNo').textContent = o ? o.order_no : '(assigned on Save)';
  document.getElementById('prodStatus').textContent = status;
  document.getElementById('prodCreated').textContent = o?.created_at
    ? `${formatCreatedAt(o.created_at)}${o.created_by ? ' by ' + o.created_by : ''}`
    : '(set on Save)';

  const editable = cardEditable();
  ['prodDescription', 'prodWarehouse', 'prodDueDate', 'prodNotes', 'prodTankMaker', 'prodStandMaker']
    .forEach((id) => { document.getElementById(id).disabled = !editable; });
  // The warehouse output went into can't move afterwards (server enforces it too).
  if (o && Number(o.total_output) > 0) document.getElementById('prodWarehouse').disabled = true;

  document.getElementById('prodManagerActions').classList.toggle('hidden', !isManager);
  document.getElementById('prodSaveBtn').classList.toggle('hidden', !editable);
  document.getElementById('prodReleaseBtn').classList.toggle('hidden', !o || status !== 'Open');
  document.getElementById('prodReopenBtn').classList.toggle('hidden', !o || status !== 'Released' || Number(o.total_output) > 0);
  document.getElementById('prodPostOutputBtn').classList.toggle('hidden', !o || status !== 'Released');
  document.getElementById('prodPrintSerialsBtn').classList.toggle('hidden', !o || Number(o.total_output) <= 0);
  document.getElementById('prodPrintOrderBtn').classList.toggle('hidden', !o);
  document.getElementById('prodDeleteBtn').classList.toggle('hidden', !o || Number(o.total_output) > 0);
  document.getElementById('prodAddLineBtn').classList.toggle('hidden', !editable);

  renderPartDoneButtons();
  refreshGeneralSummary();

  document.getElementById('prodLinesHint').textContent = !isManager
    ? 'What to build. Mark your part Production Done when it is all finished.'
    : status === 'Released'
      ? 'Enter Qty to Output for what was finished, then Post Output - it goes into stock at the warehouse above, with a new serial per aquarium / stand / sump. Partial is fine; the order finishes once everything is output.'
      : status === 'Finished'
        ? 'Everything on this order has been output.'
        : 'Add what to build, assign the makers, Save, then Release to hand it to them.';
}

function renderPartDoneButtons() {
  const box = document.getElementById('prodPartDoneActions');
  const o = openOrder;
  if (!o || o.status !== 'Released') { box.innerHTML = ''; return; }
  const me = currentSession.username;
  box.innerHTML = ['tank', 'stand'].filter((part) => o[`needs_${part}`]).map((part) => {
    const maker = o[`${part}_maker`];
    if (!isManager && maker !== me) return '';
    const done = !!o[`${part}_done_at`];
    const who = maker === me ? 'My part' : `${PART_LABEL[part]} (${escapeHtml(o[`${part}_maker_name`] || 'not assigned')})`;
    return `<button class="bc-cmd${done ? '' : ' bc-cmd-accent'}" type="button" data-part-done="${part}" data-done="${done ? '0' : '1'}"
      title="${done ? 'Undo Production Done' : 'Mark this part Production Done'}">
      ${done ? '&#8634; Undo' : '&#10003;'} ${PART_LABEL[part]} Production Done${isManager ? ` - ${who}` : ''}</button>`;
  }).join('');
}

// ---- Lines grid

// Black / Clear for a line - the server's colour (supabase_production_variant_colour.sql), else read
// from the variant / description the same way (black|BLK, clear|CLR).
function lineColour(l) {
  if (l.colour) return l.colour;
  for (const t of [l.variant_name, l.description]) {
    if (/black|\bblk\b/i.test(t || '')) return 'Black';
    if (/clear|\bclr\b/i.test(t || '')) return 'Clear';
  }
  return null;
}

function colourTagHtml(colour) {
  if (!colour) return '';
  const dot = colour === 'Black' ? 'background:#1b1b1b' : 'background:#fff;border:1.5px solid #7aa7d9;box-sizing:border-box';
  return ` <span class="prod-colour-tag" title="${escapeHtml(colour)}" style="display:inline-flex;align-items:center;gap:4px;padding:0 7px;border:1px solid #c9d3e0;border-radius:999px;font-size:11px;font-weight:700;white-space:nowrap;"><i style="width:9px;height:9px;border-radius:50%;display:inline-block;${dot}"></i>${escapeHtml(colour)}</span>`;
}

function lineRowHtml(l, index) {
  const editable = cardEditable();
  const hasOutput = Number(l.qty_output) > 0;
  const lockItem = !editable || hasOutput;
  const remaining = Math.max(0, Number(l.quantity || 0) - Number(l.qty_output || 0));
  const released = openOrder?.status === 'Released' && isManager;
  const part = l.part || linePart(l.description, l.item_code);
  return `
    <tr data-line-no="${l.line_no ?? ''}" data-part="${part}" data-item-code="${escapeHtml(l.item_code || '')}" data-item-name="${escapeHtml(l.item_name || '')}"
        data-variant-id="${escapeHtml(l.variant_id || '')}" data-qty-output="${Number(l.qty_output || 0)}">
      <td class="doc-num">${index + 1}</td>
      <td>
        ${lockItem ? `<b>${escapeHtml(l.item_code || '')}</b><div class="muted" style="font-size:11px;">${escapeHtml(l.item_name || '')}</div>`
          : `<div class="item-search-cell" style="position:relative;">
              <input type="text" class="prod-item-input" value="${escapeHtml(l.item_code || '')}" placeholder="Search item..." autocomplete="off" />
              <div class="item-suggest-dropdown hidden"></div>
            </div>`}
      </td>
      <td>
        ${lockItem ? (escapeHtml(l.variant_name || (l.variant_id ? l.variant_id : '')) || '<span class="muted">-</span>') + colourTagHtml(lineColour(l))
          : `<div class="item-search-cell" style="position:relative;">
              <input type="text" class="prod-variant-input" value="${escapeHtml(l.variant_name || '')}" placeholder="${l.item_code ? 'Variant (if any)' : 'Pick an item first'}" autocomplete="off" />
              <div class="variant-suggest-dropdown hidden"></div>
            </div>${colourTagHtml(lineColour(l))}`}
      </td>
      <td>${editable ? `<input type="text" class="prod-desc-input" value="${escapeHtml(l.description || '')}" maxlength="500" style="width:100%; box-sizing:border-box;" />`
        : escapeHtml(l.description || '')}${l.needs_serial ? ' <span class="badge badge-neutral" title="A serial is created per unit on output">Serial</span>' : ''}</td>
      <td class="prod-part-cell-wrap">${partBadgeHtml(part)}</td>
      <td class="doc-num">${editable ? `<input type="number" class="prod-qty-input" min="${Number(l.qty_output || 0) || 1}" step="1" value="${l.quantity ?? 1}" style="width:70px; text-align:right;" />` : formatQty(l.quantity)}</td>
      <td class="doc-num">${l.line_no ? formatQty(l.qty_output) : ''}</td>
      <td class="doc-num">${l.line_no ? formatQty(remaining) : ''}</td>
      <td class="doc-num prod-output-col">${released && l.line_no && remaining > 0
        ? `<input type="number" class="prod-output-input" min="0" max="${remaining}" step="1" placeholder="0" style="width:70px; text-align:right;" />` : ''}</td>
      <td>${editable && !hasOutput ? '<button class="bc-row-action bc-row-action-danger" type="button" data-remove-line title="Remove line">&times;</button>' : ''}</td>
    </tr>`;
}

function renderLines(lines) {
  const body = document.getElementById('prodLinesBody');
  body.innerHTML = lines.length
    ? lines.map(lineRowHtml).join('')
    : '<tr><td colspan="10" class="cell-msg">No lines yet.</td></tr>';
  const showOutput = openOrder?.status === 'Released' && isManager;
  document.querySelectorAll('.prod-output-col').forEach((el) => el.classList.toggle('hidden', !showOutput));
  refreshMakerAvailability();
}

function renumberLines() {
  document.querySelectorAll('#prodLinesBody tr[data-item-code]').forEach((row, i) => {
    row.cells[0].textContent = i + 1;
  });
}

function addLine() {
  const body = document.getElementById('prodLinesBody');
  if (!body.querySelector('tr[data-item-code]')) body.innerHTML = '';
  const count = body.querySelectorAll('tr[data-item-code]').length;
  body.insertAdjacentHTML('beforeend', lineRowHtml({ quantity: 1 }, count));
  const showOutput = openOrder?.status === 'Released' && isManager;
  body.lastElementChild.querySelectorAll('.prod-output-col').forEach((el) => el.classList.toggle('hidden', !showOutput));
  body.lastElementChild.querySelector('.prod-item-input')?.focus();
  cardDirty = true;
}

function refreshRowPart(row) {
  const desc = row.querySelector('.prod-desc-input')?.value || '';
  row.querySelector('.prod-part-cell-wrap').innerHTML = partBadgeHtml(linePart(desc, row.dataset.itemCode));
  refreshMakerAvailability();
}

// The line's Part as a solid, crisp badge (Tank blue / Stand amber). Its own opaque background and
// stacking so nothing from the neighbouring Description input can show through it.
function partBadgeHtml(part) {
  const style = part === 'stand' ? 'background:#fff3d6;color:#8a5a00;border-color:#e8c46a' : 'background:#e5eefb;color:#1d4f8f;border-color:#a9c2e8';
  return `<span class="prod-part-cell" style="position:relative;z-index:1;display:inline-block;padding:1px 8px;border:1px solid;border-radius:999px;font-size:12px;font-weight:600;line-height:18px;text-shadow:none;filter:none;opacity:1;${style}">${PART_LABEL[part]}</span>`;
}

// Per "not allow a maker if their specific category is not present in the production order": the
// Tank Maker picker only works while there's a Tank line, the Stand Maker only while there's a Stand
// line - otherwise it's cleared and disabled (the server refuses it too,
// supabase_production_order_maker_parts.sql). Runs after the lines render, so never on the
// "Loading..." placeholder.
function refreshMakerAvailability() {
  const present = new Set(Array.from(document.querySelectorAll('#prodLinesBody tr[data-item-code]'))
    .filter((row) => row.dataset.itemCode)
    .map((row) => row.querySelector('.prod-part-cell')?.textContent));
  [['prodTankMaker', 'tank'], ['prodStandMaker', 'stand']].forEach(([id, part]) => {
    const select = document.getElementById(id);
    const has = present.has(PART_LABEL[part]);
    if (!has && select.value) select.value = '';
    select.disabled = !cardEditable() || !has;
    select.title = has ? (part === 'tank' ? 'Builds the aquarium / sump lines' : 'Builds the stand / top cover lines')
      : `No ${PART_LABEL[part].toLowerCase()} lines on this order - add one to assign a ${PART_LABEL[part]} Maker`;
  });
}

// The lines grid scrolls inside .doc-lines-wrap, which clips an absolutely positioned suggestion
// list (with one line there is no room below it at all). Pin the list to the viewport under its
// input instead - or above it when the space below is short.
function placeDropdown(dropdown) {
  const input = dropdown.parentElement.querySelector('input');
  if (!input) return;
  const rect = input.getBoundingClientRect();
  const width = Math.max(rect.width, 320);
  const spaceBelow = window.innerHeight - rect.bottom - 8;
  const spaceAbove = rect.top - 8;
  const openUp = spaceBelow < 180 && spaceAbove > spaceBelow;
  const maxHeight = Math.min(260, Math.max(120, openUp ? spaceAbove : spaceBelow));
  Object.assign(dropdown.style, {
    position: 'fixed',
    left: `${Math.min(rect.left, window.innerWidth - width - 8)}px`,
    width: `${width}px`,
    right: 'auto',
    maxHeight: `${maxHeight}px`,
    top: openUp ? 'auto' : `${rect.bottom + 2}px`,
    bottom: openUp ? `${window.innerHeight - rect.top + 2}px` : 'auto',
    marginTop: '0',
    zIndex: '2000'
  });
}

function showDropdown(dropdown) {
  dropdown.classList.remove('hidden');
  placeDropdown(dropdown);
}

async function searchItemsForRow(row, text) {
  const dropdown = row.querySelector('.item-suggest-dropdown');
  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: text || null,
    p_limit: 20
  });
  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${escapeHtml(error.message)}</div>`;
  } else if (!data?.length) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No items found.</div>';
  } else {
    dropdown.innerHTML = data.map((it) => `
      <div class="item-suggest-option" data-code="${escapeHtml(it.code)}" data-name="${escapeHtml(it.name || '')}" data-description="${escapeHtml(it.description || it.name || '')}">
        <span class="item-suggest-code">${escapeHtml(it.code)}</span><span class="item-suggest-name">${escapeHtml(it.name || '')}</span>
      </div>`).join('');
  }
  showDropdown(dropdown);
}

async function searchVariantsForRow(row, text) {
  const dropdown = row.querySelector('.variant-suggest-dropdown');
  if (!row.dataset.itemCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">Pick an item first.</div>';
    showDropdown(dropdown);
    return;
  }
  const { data, error } = await supabaseClient.rpc('staff_search_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: row.dataset.itemCode,
    p_search: text || null,
    p_limit: 30
  });
  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${escapeHtml(error.message)}</div>`;
  } else if (!data?.length) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">This item has no variants.</div>';
  } else {
    dropdown.innerHTML = data.map((v) => {
      const label = [v.sku, v.variant_name].filter(Boolean).join(' - ') || v.variation_id;
      return `<div class="item-suggest-option" data-variation-id="${escapeHtml(v.variation_id)}" data-label="${escapeHtml(v.variant_name || label)}">
        <span class="item-suggest-code">${escapeHtml(v.sku || v.variation_id)}</span><span class="item-suggest-name">${escapeHtml(v.variant_name || '')}</span></div>`;
    }).join('');
  }
  showDropdown(dropdown);
}

function collectLines() {
  return Array.from(document.querySelectorAll('#prodLinesBody tr[data-item-code]')).map((row) => ({
    line_no: row.dataset.lineNo ? Number(row.dataset.lineNo) : null,
    item_code: row.dataset.itemCode || null,
    variant_id: row.dataset.variantId || null,
    description: row.querySelector('.prod-desc-input')?.value.trim() || null,
    quantity: Number(row.querySelector('.prod-qty-input')?.value || 0)
  }));
}

// ---- Open / load

async function loadCardLines() {
  if (!openOrder) { renderLines([]); return; }
  const { data, error } = await supabaseClient.rpc('staff_list_production_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no
  });
  if (error) { showCardError(describeSupabaseError(error, 'Could not load lines.')); return; }
  renderLines(data || []);
  loadCardGlass(data || []);
  await loadCardRework();
  if (!isManager) renderMakerView(data || []);
}

// Rework log for the open order (supabase_production_order_rework.sql). Quietly empty until that file
// is run. Managers get a history table on the card; makers see the open entry for their part in the
// maker view.
let cardRework = [];

async function loadCardRework() {
  cardRework = [];
  const part = document.getElementById('prodReworkPart');
  if (!openOrder) { part.classList.add('hidden'); return; }
  const { data, error } = await supabaseClient.rpc('staff_list_production_order_rework', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no
  });
  cardRework = error ? [] : (data || []);
  if (!isManager || !cardRework.length) { part.classList.add('hidden'); return; }
  const fmt = (t) => (t ? new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');
  document.getElementById('prodReworkBody').innerHTML = cardRework.map((r) => `
    <tr>
      <td>${escapeHtml(fmt(r.sent_back_at))}<div class="muted" style="font-size:11px;">by ${escapeHtml(r.sent_back_by_name || '')}</div></td>
      <td>${escapeHtml(PART_LABEL[r.part] || r.part)}</td>
      <td>${escapeHtml(r.maker_name || 'Not assigned')}<div class="muted" style="font-size:11px;">${r.prev_done_at ? 'done ' + escapeHtml(fmt(r.prev_done_at)) : ''}</div></td>
      <td style="white-space:normal;">${escapeHtml(r.reason || '')}</td>
      <td>${r.fixed_at
        ? `<span class="badge badge-success">&#10003; Fixed</span><div class="muted" style="font-size:11px;">${escapeHtml(r.fixed_by_name || '')} · ${escapeHtml(fmt(r.fixed_at))}</div>`
        : '<span class="badge badge-warning">&#8634; Rework</span>'}</td>
    </tr>`).join('');
  part.classList.remove('hidden');
}

// Per "in the mobile, i want the maker's view more Mobile friendly - just the Description / color of
// variant / quantity and the button Production done": a maker opening their order gets only their
// own part's lines as big rows and a full-width Production Done (the General tab, lines grid and
// toolbar are hidden by #prodCardModal.maker-view in production-orders.html).
function renderMakerView(lines) {
  const box = document.getElementById('prodMakerView');
  const o = openOrder;
  if (!o) { box.innerHTML = ''; return; }
  const me = currentSession.username;
  const myParts = ['tank', 'stand'].filter((part) => o[`needs_${part}`] && o[`${part}_maker`] === me);

  const sections = myParts.map((part) => {
    const rows = lines.filter((l) => l.part === part);
    const left = (l) => Math.max(0, Number(l.quantity || 0) - Number(l.qty_output || 0));
    const total = rows.reduce((n, l) => n + left(l), 0);
    const rework = cardRework.find((r) => r.part === part && !r.fixed_at);
    return `
      ${myParts.length > 1 ? `<div class="pm-part-title">${PART_LABEL[part]}</div>` : ''}
      ${rework ? `<div class="pm-rework"><b>&#8634; Rework</b>${escapeHtml(rework.reason || '')}<small>Sent back by ${escapeHtml(rework.sent_back_by_name || '')} · ${escapeHtml(new Date(rework.sent_back_at).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }))}</small></div>` : ''}
      <div class="pm-lines">
        ${rows.map((l) => {
          const colour = lineColour(l);
          const built = left(l) === 0;
          return `<div class="pm-line${built ? ' built' : ''}">
            <div class="pm-desc">${escapeHtml(printDescription(l))}</div>
            ${colour
              ? `<span class="pm-colour ${colour.toLowerCase()}"><i></i>${escapeHtml(colour)}</span>`
              : `<span class="pm-colour none">${escapeHtml(l.variant_name && !l.variant_name.startsWith(l.item_code) ? l.variant_name : 'No colour')}</span>`}
            <div class="pm-qty">${formatQty(left(l))}<small>${built ? 'built' : 'to build'}</small></div>
          </div>`;
        }).join('') || '<p class="muted">Nothing on this order for you.</p>'}
      </div>
      ${rows.length > 1 ? `<div class="pm-total"><span>Total</span><span>${formatQty(total)}</span></div>` : ''}`;
  }).join('');

  const actions = o.status !== 'Released' ? '' : myParts.map((part) => {
    const done = !!o[`${part}_done_at`];
    const label = myParts.length > 1 ? `${PART_LABEL[part]} ` : '';
    return done
      ? `<div class="pm-done">&#10003; ${label}Production Done</div>
         <button type="button" class="pm-btn undo" data-part-done="${part}" data-done="0">Undo ${label}Production Done</button>`
      : `<button type="button" class="pm-btn" data-part-done="${part}" data-done="1">&#10003; ${label}Production Done</button>`;
  }).join('');

  box.innerHTML = `
    <div class="pm-meta">
      <span>Due <b>${escapeHtml(o.due_date ? formatDate(o.due_date) : 'not set')}</b></span>
      <span>${escapeHtml(o.warehouse_name || '')}</span>
    </div>
    ${o.notes ? `<div class="pm-note">${escapeHtml(o.notes)}</div>` : ''}
    ${sections || '<p class="muted">You are not a maker on this order.</p>'}
    ${actions ? `<div class="pm-actions">${actions}</div>` : ''}`;
}

// ---- Glass Cut
// Per "in the production orders can you also add the glass cut there": the Online Order card's Glass
// Cut section (renderOrderCardGlassCut in js/onlineOrders.js) for a production order's Tank lines.
// The tank size comes from the item name / description / variant ("BETTA-CUBE (4x4x4in, 3MM GLASS)"),
// same parse as glass-cut-list.html; the cut is for the line's full Quantity.
const PROD_GLASS_OPTIONS = ['3mm', '5mm', '6mm', '8mm', '10mm', '12mm', '15mm', '19mm'];
const PROD_GLASS_SHEET_KEY = 'onlineOrders.glassSheetSize'; // shared with the Online Order card - same supplier sheet
const PROD_SEALANT_TUBE_KEY = 'productionOrders.sealantTubeMl';
let cardGlassTanks = [];

function lineGlassSpec(l) {
  for (const text of [l.item_name, l.description, `${l.variant_name || ''} ${l.item_code || ''}`]) {
    const spec = GlassCutList.parseAquariumLineSpec(text || '');
    if (spec) return spec;
  }
  return null;
}

function loadCardGlass(lines) {
  const o = openOrder;
  const canSee = o && (isManager || o.tank_maker === currentSession.username);
  cardGlassTanks = !canSee ? [] : lines
    .filter((l) => (l.part || linePart(l.description, l.item_code)) === 'tank' && Number(l.quantity) > 0)
    .map((line) => {
      const spec = lineGlassSpec(line);
      return { line, spec, glass: String((spec && spec.glass) || '10mm').toLowerCase().replace(/\s+/g, '') };
    });
  renderCardGlassCut();
}

function prodGlassSheetSize() {
  return {
    sheetWidth: Number(document.getElementById('prodGlassSheetW').value) || 0,
    sheetHeight: Number(document.getElementById('prodGlassSheetH').value) || 0
  };
}

function prodSealantTubeMl() {
  return Number(document.getElementById('prodSealantTubeMl').value) || GlassCutList.DEFAULT_SEALANT_TUBE_ML;
}

function prodGlassTankOptions(tank) {
  return {
    length: tank.spec.length,
    width: tank.spec.width,
    height: tank.spec.height,
    glass: tank.glass,
    quantity: Number(tank.line.quantity) || 1,
    ...prodGlassSheetSize()
  };
}

function renderCardGlassCut() {
  const tab = document.getElementById('prodCardGlassTab');
  tab.classList.toggle('hidden', cardGlassTanks.length === 0);
  if (cardGlassTanks.length === 0) return;

  const f = GlassCutList.formatInches;
  const canPo = isManager && (typeof canOpenPortalPage !== 'function' || canOpenPortalPage(currentSession, 'purchase-orders.html'));
  document.getElementById('prodGlassPoBtn').classList.toggle('hidden', !canPo);

  let totalSheets = 0;
  let blocked = false;
  // Estimated consumption for the whole order: stock sheets / panels per glass thickness, sealant per color.
  const byGlass = new Map();
  const sealantByColor = new Map();
  let unreadable = 0;
  let oversizedAny = false;
  document.getElementById('prodGlassTanks').innerHTML = cardGlassTanks.map((tank, i) => {
    const title = escapeHtml(printDescription(tank.line) || `Line ${i + 1}`);
    if (!tank.spec) {
      blocked = true;
      unreadable += 1;
      return `<div class="oc-glass-tank"><div class="oc-glass-tank-head"><strong>${title}</strong></div>
        <p class="muted" style="margin:0;">Couldn't read the tank size from this line's item name or description (e.g. "24x12x12in").</p></div>`;
    }

    const glassOptions = PROD_GLASS_OPTIONS.includes(tank.glass) ? PROD_GLASS_OPTIONS : [tank.glass, ...PROD_GLASS_OPTIONS];
    const opts = prodGlassTankOptions(tank);
    const result = GlassCutList.buildCutList(opts);
    totalSheets += result.sheets.length;
    const g = byGlass.get(opts.glass) || { sheets: 0, sheetSqFt: 0, panels: 0, panelSqFt: 0 };
    g.sheets += result.sheets.length;
    g.sheetSqFt += result.sheets.length * opts.sheetWidth * opts.sheetHeight / 144;
    result.panels.forEach((p) => { g.panels += p.qty; g.panelSqFt += p.width * p.height * p.qty / 144; });
    byGlass.set(opts.glass, g);
    if (result.oversized.length > 0) oversizedAny = true;
    const sealant = GlassCutList.estimateSealant(opts);
    const color = GlassCutList.parseSealantColor(`${tank.line.item_name || ''} ${tank.line.description || ''} ${tank.line.variant_name || ''}`) || 'Unspecified';
    sealantByColor.set(color, (sealantByColor.get(color) || 0) + sealant.ml);
    const sealantNote = `<p class="muted" style="margin:0 0 8px;">Sealant (${escapeHtml(color.toLowerCase())}): ~${Math.round(sealant.ml)} ml for ${(sealant.seamInches / 12).toFixed(1)} ft of seams</p>`;
    const qtyNote = opts.quantity > 1 ? ` &middot; ${opts.quantity} tanks` : '';
    const head = `<div class="oc-glass-tank-head">
        <strong>${title}</strong>
        <span class="muted">Tank ${f(opts.length)}" x ${f(opts.width)}" x ${f(opts.height)}"${qtyNote}</span>
        <select class="oc-glass-thickness" data-tank-index="${i}" title="Glass thickness">
          ${glassOptions.map((g) => `<option value="${escapeHtml(g)}"${g === tank.glass ? ' selected' : ''}>${escapeHtml(g)}</option>`).join('')}
        </select>
      </div>`;
    const panels = `<table class="oc-glass-panels"><thead><tr><th>Panel</th><th>Cut size</th><th>Qty</th></tr></thead><tbody>
        ${result.panels.map((p) => `<tr><td>${escapeHtml(p.name)}</td><td><strong>${f(p.width)}" x ${f(p.height)}"</strong></td><td>${p.qty}</td></tr>`).join('')}
      </tbody></table>${sealantNote}`;

    if (result.oversized.length > 0) {
      blocked = true;
      return `<div class="oc-glass-tank">${head}${panels}<p class="error-text" style="margin:0;">These panels don't fit a ${f(opts.sheetWidth)}" x ${f(opts.sheetHeight)}" sheet even rotated: ${escapeHtml(result.oversized.map((p) => p.label).join(', '))}. Use a bigger stock sheet size above.</p></div>`;
    }

    const sheets = result.sheets.map((sheet, s) =>
      GlassCutList.renderSheetSvg(sheet, { caption: `Sheet ${s + 1} of ${result.sheets.length} - ${opts.glass}` })
    ).join('');
    return `<div class="oc-glass-tank">${head}${panels}<div class="oc-glass-sheets">${sheets}</div></div>`;
  }).join('');

  const poBtn = document.getElementById('prodGlassPoBtn');
  poBtn.disabled = blocked;
  poBtn.title = blocked ? 'Fix the tank(s) above first - one has no readable size or doesn\'t fit the stock sheet.' : 'Open a New Purchase Order with every cut size above in its Notes';
  const tubeMl = prodSealantTubeMl();
  const tubeCount = (ml) => Math.ceil(ml / tubeMl);
  const totalTubes = [...sealantByColor.values()].reduce((sum, ml) => sum + tubeCount(ml), 0);
  const notes = [
    'Sealant is an estimate: bottom perimeter + 4 corners per tank, an inside bead as wide as the glass (min 6mm), +20% for cleanup.',
    unreadable ? `Leaves out ${unreadable} line(s) with no readable size.` : '',
    oversizedAny ? "Sheet count leaves out panels that don't fit the stock sheet." : ''
  ].filter(Boolean).join(' ');
  document.getElementById('prodGlassEstimate').innerHTML = byGlass.size === 0 ? '' : `
    <h4>Estimated consumption</h4>
    <table class="oc-glass-panels"><thead><tr><th>Glass</th><th>Stock sheets</th><th>Panels</th><th>Panel area</th><th>Sheet area</th></tr></thead><tbody>
      ${[...byGlass.entries()].map(([glass, g]) => `<tr><td>${escapeHtml(glass)}</td><td><strong>${g.sheets}</strong></td><td>${g.panels}</td><td>${g.panelSqFt.toFixed(2)} sq ft</td><td>${g.sheetSqFt.toFixed(2)} sq ft</td></tr>`).join('')}
    </tbody></table>
    <table class="oc-glass-panels"><thead><tr><th>Sealant</th><th>Est. ml</th><th>Tubes (${tubeMl} ml)</th></tr></thead><tbody>
      ${[...sealantByColor.entries()].map(([color, ml]) => `<tr><td>${escapeHtml(color)}</td><td>${Math.round(ml)}</td><td><strong>${tubeCount(ml)}</strong></td></tr>`).join('')}
    </tbody></table>
    <p class="muted">${escapeHtml(notes)}</p>`;
  document.getElementById('prodCardGlassSummary').textContent =
    `${cardGlassTanks.length} tank line(s) · ${totalSheets} stock sheet(s)${totalTubes > 0 ? ` · ~${totalTubes} sealant tube(s)` : ''}`;
}

// Same sessionStorage handoff as the Online Order card - purchase-orders.html opens the New PO with
// the cut sizes in Notes.
function handleCardGlassPo() {
  const tanks = cardGlassTanks.filter((t) => t.spec).map((tank) => {
    const options = prodGlassTankOptions(tank);
    return { options, result: GlassCutList.buildCutList(options) };
  });
  if (tanks.length === 0 || !openOrder) return;
  if (cardDirty && !confirm('This order has unsaved changes - the cut list is from the last saved lines. Continue?')) return;
  sessionStorage.setItem('pendingGlassPoNotes', GlassCutList.buildPoNotes(openOrder.order_no, tanks, 'Production Order'));
  window.location.href = 'purchase-orders.html';
}

function wireCardGlassCut() {
  try {
    const saved = JSON.parse(localStorage.getItem(PROD_GLASS_SHEET_KEY) || 'null');
    if (saved && saved.w > 0 && saved.h > 0) {
      document.getElementById('prodGlassSheetW').value = saved.w;
      document.getElementById('prodGlassSheetH').value = saved.h;
    }
  } catch (e) { /* storage unavailable - keep the defaults */ }
  try {
    const savedMl = Number(localStorage.getItem(PROD_SEALANT_TUBE_KEY));
    if (savedMl > 0) document.getElementById('prodSealantTubeMl').value = savedMl;
  } catch (e) { /* storage unavailable - keep the default */ }
  document.getElementById('prodSealantTubeMl').addEventListener('input', () => {
    try { localStorage.setItem(PROD_SEALANT_TUBE_KEY, String(prodSealantTubeMl())); } catch (e) { /* ignore */ }
    renderCardGlassCut();
  });

  ['prodGlassSheetW', 'prodGlassSheetH'].forEach((id) => document.getElementById(id).addEventListener('input', () => {
    const { sheetWidth, sheetHeight } = prodGlassSheetSize();
    try { localStorage.setItem(PROD_GLASS_SHEET_KEY, JSON.stringify({ w: sheetWidth, h: sheetHeight })); } catch (e) { /* ignore */ }
    renderCardGlassCut();
  }));
  document.getElementById('prodGlassTanks').addEventListener('change', (event) => {
    const select = event.target.closest('.oc-glass-thickness');
    if (!select) return;
    cardGlassTanks[Number(select.dataset.tankIndex)].glass = select.value;
    renderCardGlassCut();
  });
  document.getElementById('prodGlassPoBtn').addEventListener('click', handleCardGlassPo);
}

async function loadCardSerials() {
  const part = document.getElementById('prodSerialsPart');
  if (!openOrder || !isManager || Number(openOrder.total_output) <= 0) { part.classList.add('hidden'); return []; }
  const { data, error } = await supabaseClient.rpc('staff_list_production_order_serials', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no
  });
  if (error || !data?.length) { part.classList.add('hidden'); return []; }
  document.getElementById('prodSerialsBody').innerHTML = data.map((s) => `
    <tr>
      <td><b>${escapeHtml(s.serial_no)}</b></td>
      <td>${escapeHtml(s.item_code)}</td>
      <td>${escapeHtml(s.item_description || '')}</td>
      <td>${escapeHtml(s.location || '')}</td>
      <td>${s.status === 'IN_STOCK' ? '<span class="badge badge-success">In Stock</span>' : `<span class="badge badge-neutral">${escapeHtml(s.status)}</span>`}</td>
      <td>${escapeHtml(s.posted_at ? new Date(s.posted_at).toLocaleString() : '')}</td>
    </tr>`).join('');
  part.classList.remove('hidden');
  return data;
}

// ---- Materials Used (supabase_production_order_consumption.sql) - per "can we log how many sealant /
// rubber matting and glass material that we spend?": the manager adds the materials the order used, in
// pcs, and posts them as Consumption out of the order's warehouse. Posted lines are read-only (reverse
// on Item Ledger Entries); new lines are editable rows with the same item / variant search as Lines.

function materialsAllowed() {
  return isManager && !!openOrder?.order_no && ['Released', 'Finished'].includes(openOrder.status);
}

function defaultMaterialPart() {
  return openOrder?.needs_tank === false && openOrder?.needs_stand ? 'stand' : 'tank';
}

function newMaterialRowHtml() {
  const part = defaultMaterialPart();
  return `
    <tr class="mat-new" data-item-code="" data-item-name="" data-variant-id="">
      <td><div class="item-search-cell" style="position:relative;">
        <input type="text" class="prod-item-input" placeholder="Search material..." autocomplete="off" />
        <div class="item-suggest-dropdown hidden"></div>
      </div></td>
      <td><div class="item-search-cell" style="position:relative;">
        <input type="text" class="prod-variant-input" placeholder="Pick an item first" autocomplete="off" />
        <div class="variant-suggest-dropdown hidden"></div>
      </div></td>
      <td class="mat-desc muted"></td>
      <td><select class="mat-part-input">
        <option value="tank"${part === 'tank' ? ' selected' : ''}>Tank</option>
        <option value="stand"${part === 'stand' ? ' selected' : ''}>Stand</option>
      </select></td>
      <td class="doc-num"><input type="number" class="mat-qty-input" min="1" step="1" placeholder="0" style="width:70px; text-align:right;" /></td>
      <td class="muted">not posted</td>
      <td><button class="bc-row-action bc-row-action-danger" type="button" data-remove-material title="Remove">&times;</button></td>
    </tr>`;
}

async function loadCardMaterials() {
  const partEl = document.getElementById('prodMaterialsPart');
  if (!materialsAllowed()) { partEl.classList.add('hidden'); return; }
  const { data, error } = await supabaseClient.rpc('staff_list_production_order_consumption', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no
  });
  // Quietly hidden until supabase_production_order_consumption.sql has been run.
  if (error) { console.warn('staff_list_production_order_consumption:', error.message); partEl.classList.add('hidden'); return; }
  const rows = data || [];
  const fmt = (t) => (t ? new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');
  document.getElementById('prodMaterialsBody').innerHTML = rows.map((m) => `
    <tr class="mat-posted${m.reversed ? ' muted' : ''}">
      <td><b>${escapeHtml(m.item_code)}</b></td>
      <td>${escapeHtml(m.variant_name || '') || '<span class="muted">-</span>'}</td>
      <td>${escapeHtml(m.item_name || '')}</td>
      <td>${partBadgeHtml(m.part)}</td>
      <td class="doc-num">${m.reversed ? `<s>${formatQty(m.quantity)}</s>` : `<b>${formatQty(m.quantity)}</b>`}</td>
      <td>${escapeHtml(fmt(m.posted_at))}<div class="muted" style="font-size:11px;">by ${escapeHtml(m.posted_by_name || '')}</div></td>
      <td>${m.reversed ? '<span class="badge badge-neutral" title="Reversed on Item Ledger Entries">Reversed</span>' : ''}</td>
    </tr>`).join('') || '<tr class="mat-empty"><td colspan="7" class="cell-msg">No materials logged yet - click Add Material.</td></tr>';

  // Totals per item (reversed lines left out), e.g. "SEAL-BLK 6 · GLASS-6MM 4".
  const totals = new Map();
  rows.filter((m) => !m.reversed).forEach((m) => {
    const key = [m.item_code, m.variant_name].filter(Boolean).join(' ');
    totals.set(key, (totals.get(key) || 0) + Number(m.quantity || 0));
  });
  document.getElementById('prodMaterialsTotals').textContent = totals.size
    ? 'Total: ' + [...totals].map(([k, q]) => `${k} ${formatQty(q)}`).join(' · ') : '';
  partEl.classList.remove('hidden');
}

function addMaterialRow() {
  const body = document.getElementById('prodMaterialsBody');
  body.querySelector('.mat-empty')?.remove();
  body.insertAdjacentHTML('beforeend', newMaterialRowHtml());
  body.lastElementChild.querySelector('.prod-item-input').focus();
}

async function postMaterials() {
  showCardError('');
  showCardNotice('');
  const rows = [...document.querySelectorAll('#prodMaterialsBody tr.mat-new')];
  const lines = [];
  for (const row of rows) {
    const qty = Number(row.querySelector('.mat-qty-input').value || 0);
    if (!row.dataset.itemCode && !qty) continue;
    if (!row.dataset.itemCode) { showCardError('Pick an item from the list on every material line.'); return; }
    if (!(qty > 0) || !Number.isInteger(qty)) { showCardError(`${row.dataset.itemCode}: enter the pcs used as a whole number.`); return; }
    lines.push({ item_code: row.dataset.itemCode, variant_id: row.dataset.variantId || null, quantity: qty,
      part: row.querySelector('.mat-part-input').value, label: row.querySelector('.prod-variant-input').value });
  }
  if (!lines.length) { showCardError('Add a material with the pcs used first.'); return; }

  const warehouse = openOrder.warehouse_name || openOrder.warehouse_id;
  const summary = lines.map((l) => `  ${formatQty(l.quantity)} x ${l.item_code}${l.label ? ' - ' + l.label : ''} (${PART_LABEL[l.part]})`).join('\n');
  if (!confirm(`Post materials used on ${openOrder.order_no}?\n\n${summary}\n\nThey come out of stock at ${warehouse}.`)) return;

  const btn = document.getElementById('prodPostMaterialsBtn');
  btn.disabled = true;
  const { error } = await supabaseClient.rpc('staff_post_production_consumption', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no,
    p_lines: lines.map(({ item_code, variant_id, quantity, part }) => ({ item_code, variant_id, quantity, part })),
    p_posting_date: null
  });
  btn.disabled = false;
  if (error) { showCardError(describeSupabaseError(error, 'Could not post the materials.')); return; }
  showCardNotice(`Posted ${lines.length} material line(s) - taken out of stock at ${warehouse}.`);
  await loadCardMaterials();
}

function wireMaterialsGrid() {
  const body = document.getElementById('prodMaterialsBody');
  const debounce = new WeakMap();
  body.addEventListener('input', (e) => {
    const row = e.target.closest('tr.mat-new');
    if (!row) return;
    if (e.target.classList.contains('prod-item-input')) {
      row.dataset.itemCode = '';
      row.dataset.variantId = '';
      row.querySelector('.prod-variant-input').value = '';
      row.querySelector('.mat-desc').textContent = '';
      clearTimeout(debounce.get(e.target));
      debounce.set(e.target, setTimeout(() => searchItemsForRow(row, e.target.value.trim()), 250));
    } else if (e.target.classList.contains('prod-variant-input')) {
      row.dataset.variantId = '';
      clearTimeout(debounce.get(e.target));
      debounce.set(e.target, setTimeout(() => searchVariantsForRow(row, e.target.value.trim()), 250));
    }
  });
  body.addEventListener('focusin', (e) => {
    const row = e.target.closest('tr.mat-new');
    if (!row) return;
    if (e.target.classList.contains('prod-item-input')) searchItemsForRow(row, e.target.value.trim());
    if (e.target.classList.contains('prod-variant-input')) searchVariantsForRow(row, e.target.value.trim());
  });
  body.addEventListener('focusout', (e) => {
    const dropdown = e.target.parentElement?.querySelector('.item-suggest-dropdown, .variant-suggest-dropdown');
    if (dropdown) setTimeout(() => dropdown.classList.add('hidden'), 150);
  });
  body.addEventListener('mousedown', (e) => {
    const opt = e.target.closest('.item-suggest-option');
    if (!opt) return;
    e.preventDefault();
    const row = opt.closest('tr.mat-new');
    if (opt.dataset.code !== undefined) {
      row.dataset.itemCode = opt.dataset.code;
      row.dataset.itemName = opt.dataset.name;
      row.dataset.variantId = '';
      row.querySelector('.prod-item-input').value = opt.dataset.code;
      const variantInput = row.querySelector('.prod-variant-input');
      variantInput.value = '';
      variantInput.placeholder = 'Variant (if any)';
      row.querySelector('.mat-desc').textContent = opt.dataset.name || '';
    } else {
      row.dataset.variantId = opt.dataset.variationId;
      row.querySelector('.prod-variant-input').value = opt.dataset.label;
    }
    opt.parentElement.classList.add('hidden');
  });
  body.addEventListener('click', (e) => {
    if (!e.target.closest('[data-remove-material]')) return;
    e.target.closest('tr').remove();
    if (!body.querySelector('tr')) loadCardMaterials();
  });
  // Fixed-position suggestion lists would stay put while the card scrolls - close them instead.
  document.querySelector('#prodCardModal .bc-doc-body').addEventListener('scroll', () => body
    .querySelectorAll('.item-suggest-dropdown, .variant-suggest-dropdown').forEach((d) => d.classList.add('hidden')));
  document.getElementById('prodAddMaterialBtn').addEventListener('click', addMaterialRow);
  document.getElementById('prodPostMaterialsBtn').addEventListener('click', postMaterials);
}

function fillHeaderFields() {
  const o = openOrder;
  document.getElementById('prodDescription').value = o?.description || '';
  fillWarehouseSelect(o ? o.warehouse_id : defaultWarehouseId());
  document.getElementById('prodDueDate').value = o?.due_date ? String(o.due_date).slice(0, 10) : '';
  document.getElementById('prodNotes').value = o?.notes || '';
  fillMakerSelect('prodTankMaker', 'TankMaker', o?.tank_maker, o?.tank_maker_name);
  fillMakerSelect('prodStandMaker', 'StandMaker', o?.stand_maker, o?.stand_maker_name);
}

async function openCard(orderRow) {
  openOrder = orderRow;
  cardDirty = false;
  showCardError('');
  showCardNotice('');
  fillHeaderFields();
  renderCardHeader();
  document.getElementById('prodSerialsPart').classList.add('hidden');
  document.getElementById('prodReworkPart').classList.add('hidden');
  document.getElementById('prodMaterialsPart').classList.add('hidden');
  document.getElementById('prodCardGlassTab').classList.add('hidden');
  document.getElementById('prodLinesBody').innerHTML = '<tr><td colspan="10" class="cell-msg">Loading...</td></tr>';
  const makerView = !isManager && !!orderRow;
  document.getElementById('prodCardModal').classList.toggle('maker-view', makerView);
  document.getElementById('prodMakerView').classList.toggle('hidden', !makerView);
  document.getElementById('prodMakerView').innerHTML = makerView ? '<p class="muted">Loading...</p>' : '';
  applyMaximized(readStoredFlag(PROD_MAXIMIZED_KEY, false));
  // Browser Back closes the card; the ?no= keeps it reopenable when coming Back from another page (js/nav.js).
  if (orderRow?.order_no) document.getElementById('prodCardModal').dataset.historyUrl = `?no=${encodeURIComponent(orderRow.order_no)}`;
  else delete document.getElementById('prodCardModal').dataset.historyUrl;
  document.getElementById('prodCardModal').classList.remove('hidden');
  if (!orderRow) {
    renderLines([]);
    addLine();
    cardDirty = false;
    return;
  }
  await loadCardLines();
  await loadCardSerials();
  await loadCardMaterials();
}

// Re-reads the open order after an action (status, output totals, maker done) and redraws the card.
async function reloadCard() {
  if (!openOrder) return;
  try {
    const fresh = await fetchOrderRow(openOrder.order_no);
    if (!fresh) { closeCard(); loadProductionOrders(); return; }
    openOrder = fresh;
  } catch (err) {
    showCardError(describeSupabaseError(err, 'Could not reload the order.'));
    return;
  }
  cardDirty = false;
  fillHeaderFields();
  renderCardHeader();
  await loadCardLines();
  await loadCardSerials();
  await loadCardMaterials();
}

function closeCard() {
  if (cardDirty && isManager && !confirm('You have unsaved changes on this order. Close without saving?')) return;
  document.getElementById('prodCardModal').classList.add('hidden');
  openOrder = null;
  cardDirty = false;
  if (new URLSearchParams(window.location.search).has('no')) history.replaceState(null, '', 'production-orders.html');
}

// ---- Actions

async function saveOrder() {
  showCardError('');
  showCardNotice('');
  const lines = collectLines();
  if (lines.some((l) => !l.item_code)) { showCardError('Pick an item on every line (or remove the empty line).'); return false; }
  if (lines.some((l) => !(l.quantity > 0))) { showCardError('Every line needs a quantity above zero.'); return false; }

  const btn = document.getElementById('prodSaveBtn');
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('staff_save_production_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder?.order_no || null,
    p_description: document.getElementById('prodDescription').value,
    p_warehouse_id: document.getElementById('prodWarehouse').value || null,
    p_due_date: document.getElementById('prodDueDate').value || null,
    p_notes: document.getElementById('prodNotes').value,
    p_tank_maker: document.getElementById('prodTankMaker').value || null,
    p_stand_maker: document.getElementById('prodStandMaker').value || null,
    p_lines: lines
  });
  btn.disabled = false;
  if (error) { showCardError(describeSupabaseError(error, 'Could not save the order.')); return false; }

  openOrder = { order_no: data };
  await reloadCard();
  showCardNotice(`Saved ${data}.`);
  loadProductionOrders();
  return true;
}

async function setReleased(released) {
  showCardError('');
  if (cardDirty && !(await saveOrder())) return;
  const { error } = await supabaseClient.rpc('staff_set_production_order_released', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no,
    p_released: released
  });
  if (error) { showCardError(describeSupabaseError(error, 'Could not change the status.')); return; }
  await reloadCard();
  showCardNotice(released ? 'Released - the makers can now see it on their My Assignments.' : 'Back to Open.');
  loadProductionOrders();
}

async function postOutput() {
  showCardError('');
  showCardNotice('');
  if (cardDirty) { showCardError('Save your changes to the lines first, then post output.'); return; }

  const requests = [];
  for (const row of document.querySelectorAll('#prodLinesBody tr[data-line-no]')) {
    const input = row.querySelector('.prod-output-input');
    const qty = Number(input?.value || 0);
    if (!qty) continue;
    if (qty < 0 || qty > Number(input.max)) {
      showCardError(`${row.dataset.itemCode}: Qty to Output must be between 0 and ${input.max}.`);
      return;
    }
    requests.push({ line_no: Number(row.dataset.lineNo), quantity: qty, item_code: row.dataset.itemCode, part: row.dataset.part || 'tank' });
  }
  if (!requests.length) { showCardError('Enter a Qty to Output on at least one line.'); return; }

  // Per "dont allow to post output if the maker is not finished production done" - the server refuses
  // too (supabase_production_output_requires_done.sql); this just says so before the confirm box.
  const notDone = [...new Set(requests.map((r) => r.part))].filter((p) => !openOrder[`${p}_done_at`]);
  if (notDone.length) {
    showCardError(notDone.map((p) => {
      const maker = openOrder[`${p}_maker_name`];
      return `${PART_LABEL[p]} Maker${maker ? ` (${maker})` : ''} hasn't marked Production Done yet`;
    }).join(' · ') + ' - output can be posted once they have.');
    return;
  }

  const summary = requests.map((r) => `  ${formatQty(r.quantity)} x ${r.item_code}`).join('\n');
  const warehouse = openOrder.warehouse_name || openOrder.warehouse_id;
  if (!confirm(`Post output for ${openOrder.order_no} into ${warehouse}?\n\n${summary}\n\nThis adds the stock and creates serials for serial-tracked items.`)) return;

  const btn = document.getElementById('prodPostOutputBtn');
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('staff_post_production_output', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no,
    p_lines: requests.map(({ line_no, quantity }) => ({ line_no, quantity })),
    p_posting_date: null
  });
  btn.disabled = false;
  if (error) { showCardError(describeSupabaseError(error, 'Could not post output.')); return; }

  const rows = (data || []).filter((r) => r.line_no !== null);
  const serialCount = rows.reduce((n, r) => n + (r.serial_nos?.length || 0), 0);
  const finalStatus = (data || []).find((r) => r.order_status)?.order_status;
  await reloadCard();
  let labelNote = '';
  if (serialCount) {
    // Per "i have a barcode printer.. so everytime we print a barcode it will print on the barcode
    // printer": the new serials' labels go straight out (js/labelPrinter.js - QZ Tray to General
    // Setup's Barcode Printer, else the print dialog).
    const created = new Set(rows.flatMap((r) => r.serial_nos || []));
    const serials = (await loadCardSerials()).filter((s) => created.has(s.serial_no));
    const result = await LabelPrinter.printSerialLabels(serials.map(serialToLabel));
    labelNote = ` ${result.message}`;
  }
  showCardNotice(`Output posted: ${rows.length} line(s)${serialCount ? `, ${serialCount} serial(s) created` : ''}.${finalStatus === 'Finished' ? ' The order is now Finished.' : ''}${labelNote}`);
  loadProductionOrders();
}

function serialToLabel(s) {
  return { serialNo: s.serial_no, itemCode: s.item_code, description: s.item_description || '' };
}

// Undo = rework for the maker (supabase_production_order_rework.sql): p_reason is logged and shown to
// them until they mark the part done again. Only sent on an undo, so marking done still works before
// that file is run (an undo needs it).
async function setPartDone(part, done, reason) {
  showCardError('');
  const args = {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no,
    p_part: part,
    p_done: done
  };
  if (!done) args.p_reason = reason || null;
  const { error } = await supabaseClient.rpc('staff_set_production_order_part_done', args);
  if (error) { showCardError(describeSupabaseError(error, 'Could not update Production Done.')); return; }
  if (!isManager && done) {
    // Done work drops off a maker's list, same as Online Orders' My Assignments.
    cardDirty = false;
    closeCard();
    loadProductionOrders();
    return;
  }
  await reloadCard();
  showCardNotice(done ? `${PART_LABEL[part]} marked Production Done.` : `${PART_LABEL[part]} Production Done undone - logged as rework for the maker.`);
  loadProductionOrders();
}

async function deleteOrder() {
  if (!openOrder || !confirm(`Delete production order ${openOrder.order_no}? This can't be undone.`)) return;
  const { error } = await supabaseClient.rpc('staff_delete_production_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: openOrder.order_no
  });
  if (error) { showCardError(describeSupabaseError(error, 'Could not delete the order.')); return; }
  cardDirty = false;
  closeCard();
  loadProductionOrders();
}

// The item's plain name for the printout: "BETTA-CUBE (4x4x4in, 3MM GLASS)" instead of the generated
// "BETTA-CUBE (...) - Black - AQ-013 - BETTA-CUBE (...)". A description someone typed that doesn't start
// with the item name is kept as written.
function printDescription(l) {
  const desc = (l.description || '').trim();
  const name = (l.item_name || '').trim();
  if (name && (!desc || desc.toLowerCase().startsWith(name.toLowerCase()))) return name;
  return desc || l.item_code || '';
}

// Per "can you put a printout for the order": the order as a work sheet for the shop floor - header,
// then the lines grouped by part (Tank Maker / Stand Maker), each with a tick box and sign-off.
async function printOrder() {
  showCardError('');
  if (cardDirty && isManager && !confirm('This order has unsaved changes - the printout shows the last saved version. Print anyway?')) return;
  const o = openOrder;
  const { data, error } = await supabaseClient.rpc('staff_list_production_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: o.order_no
  });
  if (error) { showCardError(describeSupabaseError(error, 'Could not load the lines to print.')); return; }
  const lines = data || [];
  const win = window.open('', '_blank');
  if (!win) { showCardError('Allow pop-ups to print the order.'); return; }

  const makerName = { tank: o.tank_maker_name, stand: o.stand_maker_name };
  const doneAt = { tank: o.tank_done_at, stand: o.stand_done_at };
  const sections = ['tank', 'stand'].map((part) => {
    const rows = lines.filter((l) => l.part === part);
    if (!rows.length) return '';
    const total = rows.reduce((n, l) => n + Number(l.quantity || 0), 0);
    const built = rows.reduce((n, l) => n + Number(l.qty_output || 0), 0);
    // Per "i just want to show Description, Variant Color, Qty to Build, Quantity Build": the item's
    // plain name (not the long "name - colour - variant" line description), the colour on its own, and
    // a Quantity Built column left blank to write in until output is posted.
    return `
      <h2>${PART_LABEL[part]} <span>Maker: ${escapeHtml(makerName[part] || '________________')}${doneAt[part] ? ` · Done ${escapeHtml(new Date(doneAt[part]).toLocaleDateString())}` : ''}</span></h2>
      <table>
        <thead><tr><th>Description</th><th class="c">Variant Color</th><th class="n">Qty to Build</th><th class="n">Quantity Built</th></tr></thead>
        <tbody>
          ${rows.map((l) => {
            const colour = lineColour(l);
            return `<tr>
            <td class="desc">${escapeHtml(printDescription(l))}</td>
            <td class="c">${colour ? `<span class="col col-${colour.toLowerCase()}">${escapeHtml(colour.toUpperCase())}</span>` : escapeHtml(l.variant_name && l.variant_name !== l.item_code ? l.variant_name : '-')}</td>
            <td class="n big">${formatQty(l.quantity)}</td>
            <td class="n big">${Number(l.qty_output) ? formatQty(l.qty_output) : ''}</td>
          </tr>`;
          }).join('')}
        </tbody>
        <tfoot><tr><td colspan="2">Total</td><td class="n big">${formatQty(total)}</td><td class="n big">${built ? formatQty(built) : ''}</td></tr></tfoot>
      </table>
      <div class="sign"><div>Built by</div><div>Checked by</div><div>Date finished</div></div>`;
  }).join('');

  win.document.write(`<!DOCTYPE html><html><head><meta charset="UTF-8"><title>${escapeHtml(o.order_no)}</title>
    <style>
      body{font-family:Arial,sans-serif;margin:18px;color:#111;font-size:13px}
      h1{font-size:20px;margin:0}.sub{color:#555;margin:2px 0 12px}
      .meta{display:grid;grid-template-columns:repeat(3,1fr);gap:4px 16px;border:1px solid #bbb;padding:8px 10px;margin-bottom:12px}
      .meta div span{display:block;font-size:10px;color:#666;text-transform:uppercase}
      .notes{border:1px solid #bbb;padding:6px 10px;margin-bottom:12px;white-space:pre-wrap}
      h2{font-size:15px;margin:16px 0 6px;border-bottom:2px solid #111;padding-bottom:3px}h2 span{font-size:12px;font-weight:400;color:#444;margin-left:8px}
      table{width:100%;border-collapse:collapse}th,td{border:1px solid #bbb;padding:5px 6px;text-align:left;vertical-align:top}
      th{background:#eee;font-size:12px}.n{text-align:right;width:110px}.c{text-align:center;width:120px}.big{font-size:17px;font-weight:700}
      td{padding:9px 8px;vertical-align:middle}td.desc{font-size:14px}
      tbody tr:nth-child(even){background:#f7f7f7}
      tfoot td{font-weight:700;background:#eee}
      .col{display:inline-block;min-width:56px;border:1.5px solid #111;border-radius:3px;padding:2px 6px;font-size:12px;font-weight:700}
      .col-black{background:#111;color:#fff}
      @media print{tbody tr:nth-child(even){background:#f7f7f7;-webkit-print-color-adjust:exact;print-color-adjust:exact}.col-black{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
      .box{display:inline-block;width:14px;height:14px;border:1.5px solid #333}
      .sign{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;margin-top:28px}.sign div{border-top:1px solid #333;padding-top:3px;font-size:11px;color:#444}
      section{break-inside:avoid}@media print{body{margin:10mm}}
    </style></head><body>
    <h1>Production Order ${escapeHtml(o.order_no)}</h1>
    <div class="sub">${escapeHtml(o.description || '')}</div>
    <div class="meta">
      <div><span>Status</span>${escapeHtml(o.status)}</div>
      <div><span>Warehouse</span>${escapeHtml(o.warehouse_name || o.warehouse_id || '')}</div>
      <div><span>Due date</span>${escapeHtml(formatDate(o.due_date) || '-')}</div>
      <div><span>Created</span>${escapeHtml(o.created_at ? new Date(o.created_at).toLocaleDateString() : '')}${o.created_by ? ' by ' + escapeHtml(o.created_by) : ''}</div>
      <div><span>Released</span>${escapeHtml(o.released_at ? new Date(o.released_at).toLocaleDateString() : '-')}</div>
      <div><span>Printed</span>${escapeHtml(new Date().toLocaleString())}</div>
    </div>
    ${o.notes ? `<div class="notes"><b>Notes:</b> ${escapeHtml(o.notes)}</div>` : ''}
    ${sections || '<p>No lines on this order.</p>'}
    <script>window.onload=function(){window.print();}<\/script></body></html>`);
  win.document.close();
}

// Reprint the order's in-stock serials as barcode labels (100x30mm, Code128) - to the barcode printer
// through js/labelPrinter.js, same as right after Post Output.
async function printSerials() {
  showCardError('');
  const serials = (await loadCardSerials()).filter((s) => s.status === 'IN_STOCK');
  if (!serials.length) { showCardError('No in-stock serials on this order to print.'); return; }
  if (!confirm(`Print ${serials.length} serial label(s) for ${openOrder.order_no}?`)) return;
  const result = await LabelPrinter.printSerialLabels(serials.map(serialToLabel));
  showCardNotice(result.message);
}

// ---------------------------------------------------------------- Wiring

function wireLinesGrid() {
  const body = document.getElementById('prodLinesBody');
  const debounce = new WeakMap();

  body.addEventListener('input', (e) => {
    const row = e.target.closest('tr[data-item-code]');
    if (!row) return;
    if (!e.target.classList.contains('prod-output-input')) cardDirty = true;

    if (e.target.classList.contains('prod-item-input')) {
      row.dataset.itemCode = '';
      row.dataset.variantId = '';
      const variantInput = row.querySelector('.prod-variant-input');
      if (variantInput) variantInput.value = '';
      clearTimeout(debounce.get(e.target));
      debounce.set(e.target, setTimeout(() => searchItemsForRow(row, e.target.value.trim()), 250));
    } else if (e.target.classList.contains('prod-variant-input')) {
      row.dataset.variantId = '';
      clearTimeout(debounce.get(e.target));
      debounce.set(e.target, setTimeout(() => searchVariantsForRow(row, e.target.value.trim()), 250));
    } else if (e.target.classList.contains('prod-desc-input')) {
      refreshRowPart(row);
    }
  });

  body.addEventListener('focusin', (e) => {
    const row = e.target.closest('tr[data-item-code]');
    if (!row) return;
    if (e.target.classList.contains('prod-item-input')) searchItemsForRow(row, e.target.value.trim());
    if (e.target.classList.contains('prod-variant-input')) searchVariantsForRow(row, e.target.value.trim());
  });

  body.addEventListener('focusout', (e) => {
    const dropdown = e.target.parentElement?.querySelector('.item-suggest-dropdown, .variant-suggest-dropdown');
    if (dropdown) setTimeout(() => dropdown.classList.add('hidden'), 150);
  });

  body.addEventListener('mousedown', (e) => {
    const opt = e.target.closest('.item-suggest-option');
    if (!opt) return;
    e.preventDefault();
    const row = opt.closest('tr[data-item-code]');
    if (opt.dataset.code !== undefined) {
      row.dataset.itemCode = opt.dataset.code;
      row.dataset.itemName = opt.dataset.name;
      row.dataset.variantId = '';
      row.querySelector('.prod-item-input').value = opt.dataset.code;
      const variantInput = row.querySelector('.prod-variant-input');
      variantInput.value = '';
      variantInput.placeholder = 'Variant (if any)';
      const desc = row.querySelector('.prod-desc-input');
      if (desc) desc.value = opt.dataset.description || opt.dataset.name || '';
      refreshRowPart(row);
    } else {
      row.dataset.variantId = opt.dataset.variationId;
      row.querySelector('.prod-variant-input').value = opt.dataset.label;
      const desc = row.querySelector('.prod-desc-input');
      if (desc && !desc.value.includes(opt.dataset.label)) desc.value = `${row.dataset.itemName || desc.value} - ${opt.dataset.label}`.trim();
      refreshRowPart(row);
    }
    cardDirty = true;
    opt.parentElement.classList.add('hidden');
  });

  // A fixed-position list would stay put while its input scrolls away - close it instead.
  const hideOpenDropdowns = () => body.querySelectorAll('.item-suggest-dropdown, .variant-suggest-dropdown')
    .forEach((d) => d.classList.add('hidden'));
  document.querySelector('#prodCardModal .doc-lines-wrap').addEventListener('scroll', hideOpenDropdowns);
  document.querySelector('#prodCardModal .bc-doc-body').addEventListener('scroll', hideOpenDropdowns);
  window.addEventListener('resize', hideOpenDropdowns);

  body.addEventListener('click', (e) => {
    if (!e.target.closest('[data-remove-line]')) return;
    e.target.closest('tr').remove();
    renumberLines();
    refreshMakerAvailability();
    cardDirty = true;
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  LabelPrinter.init(session);
  renderTopNav(FINISHED_VIEW ? 'Finished Production Orders' : 'Production Orders');

  isManager = !!(session.isSuperUser || session.isProductionManager);
  if (FINISHED_VIEW) {
    document.title = 'Finished Production Orders - RS Pet Stop Portal';
    document.querySelector('.bc-title').textContent = 'Finished Production Orders';
    document.getElementById('prodSubtitle').textContent = 'Production orders where everything has been output into stock. Open one to see its lines, output serials, materials used and rework history.';
    document.getElementById('newProdBtn').classList.add('hidden');
    document.getElementById('prodStatusFilter').closest('label').classList.add('hidden');
  }
  if (FINISHED_VIEW && !isManager) {
    document.getElementById('prodPageError').textContent = 'Finished Production Orders are for Production Managers only.';
    document.getElementById('prodPageError').classList.remove('hidden');
    document.querySelector('.bc-cmdbar').classList.add('hidden');
    document.getElementById('prodGridWrap').classList.add('hidden');
    return;
  }
  if (!isManager && !session.isOrderMaker) {
    document.getElementById('prodPageError').textContent = 'Production Orders are for Production Managers and makers (Tank / Stand Maker) only.';
    document.getElementById('prodPageError').classList.remove('hidden');
    document.querySelector('.bc-cmdbar').classList.add('hidden');
    document.getElementById('prodGridWrap').classList.add('hidden');
    return;
  }
  // Makers: ask to turn on "production order released to you" notifications.
  maybeShowPushLoginPrompt(session);
  if (!isManager) {
    document.getElementById('newProdBtn').classList.add('hidden');
    document.getElementById('prodStatusFilter').closest('label').classList.add('hidden');
    document.getElementById('prodSubtitle').textContent = 'Restock builds assigned to you. Open one to see what to build and mark your part Production Done.';
  }

  document.getElementById('prodSearchInput').addEventListener('input', (e) => {
    clearTimeout(searchDebounceHandle);
    const value = e.target.value.trim();
    searchDebounceHandle = setTimeout(() => { currentSearch = value; currentPage = 1; loadProductionOrders(); }, 300);
  });
  document.getElementById('prodStatusFilter').addEventListener('change', (e) => {
    currentStatus = e.target.value;
    currentPage = 1;
    loadProductionOrders();
  });
  document.getElementById('prodRefreshBtn').addEventListener('click', loadProductionOrders);
  window.addEventListener('resize', fitGridToViewport);

  document.getElementById('prodTableBody').addEventListener('click', (e) => {
    const row = e.target.closest('tr[data-order-no]');
    if (!row) return;
    const order = lastRows.find((o) => o.order_no === row.dataset.orderNo);
    if (order) openCard(order);
  });

  document.getElementById('newProdBtn').addEventListener('click', () => openCard(null));
  document.getElementById('prodCardCloseBtn').addEventListener('click', closeCard);
  document.getElementById('prodCardMaximizeBtn').addEventListener('click', () => {
    const next = !document.getElementById('prodCardModal').classList.contains('modal-maximized');
    applyMaximized(next);
    writeStoredFlag(PROD_MAXIMIZED_KEY, next);
  });
  document.getElementById('prodSaveBtn').addEventListener('click', saveOrder);
  document.getElementById('prodReleaseBtn').addEventListener('click', () => setReleased(true));
  document.getElementById('prodReopenBtn').addEventListener('click', () => setReleased(false));
  document.getElementById('prodPostOutputBtn').addEventListener('click', postOutput);
  document.getElementById('prodPrintSerialsBtn').addEventListener('click', printSerials);
  document.getElementById('prodPrintOrderBtn').addEventListener('click', printOrder);
  document.getElementById('prodDeleteBtn').addEventListener('click', deleteOrder);
  document.getElementById('prodAddLineBtn').addEventListener('click', addLine);
  const onPartDoneClick = (e) => {
    const btn = e.target.closest('[data-part-done]');
    if (!btn) return;
    const done = btn.dataset.done === '1';
    const part = btn.dataset.partDone;
    if (done) {
      if (!confirm(`Is the ${PART_LABEL[part]} part of ${openOrder.order_no} completely finished?`)) return;
      setPartDone(part, true);
      return;
    }
    // Undo goes back to the maker as rework - ask what needs fixing (Cancel keeps it done).
    const reason = prompt(`Undo ${PART_LABEL[part]} Production Done on ${openOrder.order_no}?\n\nIt goes back to the ${PART_LABEL[part]} Maker as REWORK. What needs to be fixed?`, '');
    if (reason === null) return;
    setPartDone(part, false, reason.trim());
  };
  document.getElementById('prodPartDoneActions').addEventListener('click', onPartDoneClick);
  document.getElementById('prodMakerView').addEventListener('click', onPartDoneClick);
  ['prodDescription', 'prodWarehouse', 'prodDueDate', 'prodNotes', 'prodTankMaker', 'prodStandMaker'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => { cardDirty = true; refreshGeneralSummary(); });
  });
  wireLinesGrid();
  wireMaterialsGrid();
  wireCardGlassCut();

  await Promise.all([loadWarehouses(), isManager ? loadMakers() : Promise.resolve(), loadProductionOrders()]);

  // Opened from a My Assignments card (online-orders.html) - go straight to the order.
  const directNo = new URLSearchParams(window.location.search).get('no');
  if (directNo) {
    try {
      const row = lastRows.find((o) => o.order_no === directNo) || await fetchOrderRow(directNo);
      if (row) openCard(row);
    } catch (err) {
      console.error('Could not open production order', directNo, err);
    }
  }
})();
