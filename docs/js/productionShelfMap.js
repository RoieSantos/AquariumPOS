// Production Shelf Map (production-shelf-map.html) - a drawn layout of the production floor's racks
// (sql/supabase_production_shelf_map.sql, supabase_production_shelf_floor_plan.sql,
// supabase_production_shelf_size_tags.sql, supabase_production_shelf_serial_counts.sql).
//
// COUNT MODE - per "i dont need to place.. i just want to see the count per serial": nothing is put
// on a rack. A rack linked to an aquarium (e.g. B4 = 75g) shows how many serials of that aquarium are
// IN_STOCK at the shelf's location, and tapping it lists them. Stock by size sums it up, plus what's
// in stock that no rack is linked to.
//
// Two layouts per shelf:
//   grid  - rows of equal spots
//   floor - a floor plan: each spot drawn at its own position and size (pos_x/pos_y/width/height in
//           plan units, scaled to the screen). Edit Layout lets you drag, resize and rotate spots.
let currentSession = null;
let canEditLayout = false;
let shelves = [];
let currentShelfId = null;
let currentLocation = null;
let locationSerials = []; // every IN_STOCK serial at currentLocation
let findTerm = '';
// While editing, a working copy - nothing is written until Save:
//   grid:  { id, name, warehouse_id, layout: 'grid', rows: [[spot, ...], ...] }
//   floor: { id, name, warehouse_id, layout: 'floor', spots: [spot, ...] }
let draft = null;
let modalCell = null; // grid: { r, c } / floor: { i } - the spot open in the layout modal
let floorScale = 1; // screen px per plan unit for the floor plan on screen

const FLOOR_MIN_WIDTH = 820; // plan units - the sketch's own width
const FLOOR_PAD = 20;
const NEW_SPOT = { width: 140, height: 55 };

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function rpc(name, args) {
  return supabaseClient.rpc(name, {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    ...args
  });
}

function showError(message) {
  const el = document.getElementById('shelfError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function currentShelf() {
  return shelves.find((s) => s.id === currentShelfId) || null;
}

function currentLayout() {
  return draft ? draft.layout : (currentShelf()?.layout || 'grid');
}

function allSpots() {
  return shelves.flatMap((s) => (s.spots || []).map((sp) => ({ ...sp, shelf: s })));
}

function findSpot(id) {
  return allSpots().find((sp) => sp.id === id) || null;
}

function spotName(spot, fallback) {
  return spot.label || fallback || 'Spot';
}

function spotsToRows(spots) {
  const rows = [];
  (spots || []).forEach((s) => {
    if (!rows[s.row_no]) rows[s.row_no] = [];
    rows[s.row_no].push(s);
  });
  return rows.filter(Boolean).map((row) => row.sort((a, b) => a.col_no - b.col_no));
}

// A spot on a floor plan with no size yet (e.g. a grid shelf switched to floor) gets laid out in a
// simple grid so nothing lands on top of anything else.
function withFloorGeometry(spots) {
  return spots.map((s, i) => (s.width && s.height ? { ...s } : {
    ...s,
    pos_x: FLOOR_PAD + (i % 5) * (NEW_SPOT.width + 15),
    pos_y: FLOOR_PAD + Math.floor(i / 5) * (NEW_SPOT.height + 15),
    width: NEW_SPOT.width,
    height: NEW_SPOT.height
  }));
}

// Floor -> grid: rows by vertical position (spots whose tops are within ~60 units share a row).
function floorToRows(spots) {
  const sorted = [...spots].sort((a, b) => (a.pos_y || 0) - (b.pos_y || 0) || (a.pos_x || 0) - (b.pos_x || 0));
  const rows = [];
  sorted.forEach((s) => {
    const row = rows.find((r) => Math.abs((r[0].pos_y || 0) - (s.pos_y || 0)) < 60);
    if (row) row.push(s); else rows.push([s]);
  });
  return rows.map((r) => r.sort((a, b) => (a.pos_x || 0) - (b.pos_x || 0)));
}

// ---------------------------------------------------------------- Counting

function serialMatches(s, term) {
  const t = term.toLowerCase();
  return [s.serial_no, s.item_code, s.item_description, s.variant_name].some((v) => (v || '').toLowerCase().includes(t));
}

// Whether a serial is the aquarium a spot is linked to: the variant when the link names one,
// otherwise the item. null = the spot has no aquarium linked.
function unitFitsSpot(unit, spot) {
  if (!spot || !spot.item_code) return null;
  if (spot.variant_id) return unit.variant_code === spot.variant_id;
  return unit.item_code === spot.item_code;
}

function spotTagText(spot) {
  if (spot.size_tag) return spot.size_tag;
  if (spot.item_code) return spot.variant_name || spot.item_name || spot.item_code;
  return '';
}

// Short size for the rack face - the typed size tag, else the gallons pulled out of the aquarium's
// name ("STANDARD-50G (36×18×18in, 6MM GLASS)" -> "50G"), else the item code. The full name is in
// the tooltip, the rack popup and Stock by size.
function spotShortTag(spot) {
  if (spot.size_tag) return spot.size_tag;
  if (!spot.item_code) return '';
  const gallons = `${spot.variant_name || ''} ${spot.item_name || ''}`.match(/(\d+(?:\.\d+)?)\s*(?:g|gal|gallons?)\b/i);
  return gallons ? `${gallons[1]}G` : spot.item_code;
}

// Floor plan zoom on top of fit-to-width, remembered per browser.
const ZOOM_STEPS = [1, 1.25, 1.5, 1.75, 2, 2.5];
let floorZoom = 1.5;
try {
  const saved = Number(localStorage.getItem('prod-shelf-zoom'));
  if (ZOOM_STEPS.includes(saved)) floorZoom = saved;
} catch (err) { /* default zoom */ }

function setZoom(step) {
  const i = Math.max(0, Math.min(ZOOM_STEPS.length - 1, ZOOM_STEPS.indexOf(floorZoom) + step));
  floorZoom = ZOOM_STEPS[i];
  try { localStorage.setItem('prod-shelf-zoom', String(floorZoom)); } catch (err) { /* not remembered */ }
  renderShelf();
}

// In-stock serials of the spot's aquarium at the location on screen (null = no aquarium linked).
function spotSerials(spot) {
  if (!spot?.item_code) return null;
  return locationSerials.filter((s) => unitFitsSpot(s, spot));
}

// Other racks at this location linked to the same aquarium - they share the same count, since serials
// aren't placed on a particular rack.
function sharedWith(spot) {
  if (!spot?.item_code) return [];
  const key = `${spot.item_code}|${spot.variant_id || ''}`;
  return shelves.filter((sh) => sh.warehouse_id === currentLocation)
    .flatMap((sh) => sh.spots || [])
    .filter((sp) => sp.id !== spot.id && `${sp.item_code}|${sp.variant_id || ''}` === key)
    .map((sp) => spotName(sp));
}

// Find matches a rack by its tag / aquarium, or by a serial of its aquarium ("RS-AQ-..." highlights
// the rack for that size).
function spotMatches(spot, term) {
  if (!term) return false;
  const t = term.toLowerCase();
  if ([spot.size_tag, spot.item_code, spot.item_name, spot.variant_name, spot.label].some((v) => (v || '').toLowerCase().includes(t))) return true;
  return (spotSerials(spot) || []).some((s) => (s.serial_no || '').toLowerCase().includes(t));
}

// ---------------------------------------------------------------- Rendering

// One rack - shared by the grid and the floor plan. `compact` (a small floor-plan rack) keeps just
// label, tag and count; the rest is in the tooltip and the rack's popup.
function spotHtml(spot, fallbackName, { attrs = '', style = '', compact = false, editing = false, resizable = false } = {}) {
  const serials = editing ? null : spotSerials(spot);
  const count = serials ? serials.length : null;
  const full = count !== null && spot.capacity && count >= spot.capacity;
  const match = !editing && findTerm && spotMatches(spot, findTerm);
  const tag = spotTagText(spot);
  const shared = editing ? [] : sharedWith(spot);
  const cls = [
    'pspot',
    !spot.item_code ? 'unlinked' : '',
    count === 0 ? 'empty' : '',
    full ? 'full' : '',
    match ? 'match' : '',
    !editing && findTerm && !match ? 'dim' : '',
    compact ? 'compact' : ''
  ].filter(Boolean).join(' ');
  const tooltip = [
    spotName(spot, fallbackName) + (tag ? ` - ${tag}` : ''),
    spot.item_code ? `${spot.item_code}${spot.variant_name ? ' · ' + spot.variant_name : ''}` : 'No aquarium linked',
    count !== null ? `${count} in stock${spot.capacity ? ` (fits ${spot.capacity})` : ''}` : '',
    shared.length ? `Same aquarium as ${shared.join(', ')} - count is shared` : '',
    spot.notes || ''
  ].filter(Boolean).join('\n');
  const countHtml = count === null
    ? (editing ? '' : '<span class="pspot-count muted" title="Link an aquarium in Edit Layout to count it">–</span>')
    : `<span class="pspot-count">${count}${spot.capacity ? `<small> / ${spot.capacity}</small>` : ''}</span>`;
  const shortTag = spotShortTag(spot);
  return `<div class="${cls}" ${attrs} ${spot.id ? `data-spot-id="${spot.id}"` : ''} style="${style}" title="${escapeHtml(tooltip)}" role="button" tabindex="0">
    <div class="pspot-head">
      <span class="pspot-label">${escapeHtml(spotName(spot, fallbackName))}</span>
      ${countHtml}
    </div>
    ${shortTag ? `<span class="pspot-tag">${escapeHtml(shortTag)}</span>` : ''}
    ${!compact && spot.item_code ? `<span class="pspot-sub pspot-clamp">${escapeHtml(spot.item_code)}${spot.variant_name ? ' · ' + escapeHtml(spot.variant_name) : ''}</span>` : ''}
    ${!compact && shared.length ? `<span class="pspot-sub">shared with ${escapeHtml(shared.join(', '))}</span>` : ''}
    ${!compact && !editing && !spot.item_code ? '<span class="pspot-sub">No aquarium linked</span>' : ''}
    ${!compact && spot.notes ? `<span class="pspot-sub">${escapeHtml(spot.notes)}</span>` : ''}
    ${resizable ? '<span class="pspot-resize" data-resize title="Drag to resize"></span>' : ''}
  </div>`;
}

// "Stock by size" under the map: in-stock serial count per linked aquarium at the location on screen,
// then everything in stock there that no rack is linked to (by item/variant).
function renderSizeSummary() {
  const box = document.getElementById('sizeSummary');
  if (draft || !currentLocation) { box.classList.add('hidden'); return; }
  const groups = new Map();
  shelves.filter((sh) => sh.warehouse_id === currentLocation).forEach((sh) => {
    (sh.spots || []).forEach((sp) => {
      if (!sp.item_code) return;
      const key = `${sp.item_code}|${sp.variant_id || ''}`;
      const g = groups.get(key) || { spot: sp, tags: new Set(), racks: [] };
      if (spotTagText(sp)) g.tags.add(spotTagText(sp));
      g.racks.push(spotName(sp));
      groups.set(key, g);
    });
  });

  const linkedRows = Array.from(groups.values())
    .map((g) => ({ g, count: spotSerials(g.spot).length }))
    .sort((a, b) => Array.from(a.g.tags).join().localeCompare(Array.from(b.g.tags).join(), undefined, { numeric: true }));

  const linkedSpots = Array.from(groups.values()).map((g) => g.spot);
  const other = new Map();
  locationSerials.filter((s) => !linkedSpots.some((sp) => unitFitsSpot(s, sp))).forEach((s) => {
    const key = `${s.item_code}|${s.variant_code || ''}`;
    const o = other.get(key) || { item_code: s.item_code, variant_name: s.variant_name, description: s.item_description, count: 0 };
    o.count += 1;
    other.set(key, o);
  });
  const otherRows = Array.from(other.values()).sort((a, b) => a.item_code.localeCompare(b.item_code, undefined, { numeric: true }));

  if (!linkedRows.length && !otherRows.length) {
    box.innerHTML = '<h3>Stock by size</h3><p class="muted" style="margin:0;">No serials in stock at this location.</p>';
    box.classList.remove('hidden');
    return;
  }
  const total = locationSerials.length;
  box.innerHTML = `
    <h3>Stock by size <span class="muted" style="font-size:12px; font-weight:400;">${total} serial(s) in stock at this location</span></h3>
    <table class="size-summary">
      <thead><tr><th>Size</th><th>Aquarium</th><th>Racks</th><th class="num">In stock</th></tr></thead>
      <tbody>
        ${linkedRows.map(({ g, count }) => `
          <tr data-find="${escapeHtml(Array.from(g.tags)[0] || g.spot.item_code)}" title="Highlight these racks">
            <td><span class="pspot-tag">${escapeHtml(Array.from(g.tags).join(', ') || '-')}</span></td>
            <td>${escapeHtml(g.spot.item_code)}${g.spot.variant_name ? ' · ' + escapeHtml(g.spot.variant_name) : ''}<div class="muted" style="font-size:11px;">${escapeHtml(g.spot.item_name || '')}</div></td>
            <td>${escapeHtml(g.racks.join(', '))}</td>
            <td class="num"><b>${count}</b></td>
          </tr>`).join('')}
        ${otherRows.length ? `<tr class="size-summary-sep"><td colspan="4">Not linked to any rack</td></tr>` : ''}
        ${otherRows.map((o) => `
          <tr class="unlinked-row" data-serials-item="${escapeHtml(o.item_code)}">
            <td><span class="muted">-</span></td>
            <td>${escapeHtml(o.item_code)}${o.variant_name ? ' · ' + escapeHtml(o.variant_name) : ''}<div class="muted" style="font-size:11px;">${escapeHtml(o.description || '')}</div></td>
            <td class="muted">-</td>
            <td class="num"><b>${o.count}</b></td>
          </tr>`).join('')}
      </tbody>
    </table>`;
  box.classList.remove('hidden');
}

function renderShelf() {
  renderSizeSummary();
  const body = document.getElementById('shelfBody');
  if (!draft && !currentShelf()) {
    body.innerHTML = `<p class="muted">No production shelves yet.${canEditLayout ? ' Use "New Shelf" to draw one.' : ''}</p>`;
    renderFindResult(0);
    return;
  }
  document.getElementById('zoomControls').classList.toggle('hidden', currentLayout() !== 'floor');
  if (currentLayout() === 'floor') renderFloor(body);
  else renderGrid(body);
}

function renderGrid(body) {
  const editing = !!draft;
  const rows = editing ? draft.rows : spotsToRows((currentShelf() || {}).spots);
  body.classList.remove('floor-mode');
  if (rows.length === 0) {
    body.innerHTML = '<p class="muted">This shelf has no spots yet.' + (editing ? ' Use "+ Row" to add one.' : '') + '</p>';
    renderFindResult(0);
    return;
  }
  let matchCount = 0;
  body.innerHTML = rows.map((row, r) => {
    const cellsHtml = row.map((spot, c) => {
      if (!editing && spotMatches(spot, findTerm)) matchCount += 1;
      return spotHtml(spot, `Row ${r + 1} · Spot ${c + 1}`, { attrs: `data-r="${r}" data-c="${c}"`, editing });
    }).join('');
    const addBtn = editing
      ? `<button type="button" class="btn btn-secondary btn-sm shelf-add-cell" data-addcell="${r}">+ Spot</button>
         <button type="button" class="btn btn-secondary btn-sm shelf-add-cell" data-delrow="${r}">Delete Row</button>`
      : '';
    return `<div class="shelf-row">${cellsHtml}${addBtn}</div>`;
  }).join('');
  renderFindResult(matchCount);
}

function renderFloor(body) {
  const editing = !!draft;
  const spots = editing ? draft.spots : withFloorGeometry((currentShelf() || {}).spots || []);
  body.classList.add('floor-mode');
  if (spots.length === 0) {
    body.innerHTML = '<p class="muted">This floor plan has no spots yet.' + (editing ? ' Use "+ Spot" to add one, then drag it into place.' : '') + '</p>';
    renderFindResult(0);
    return;
  }
  const planW = Math.max(FLOOR_MIN_WIDTH, ...spots.map((s) => Number(s.pos_x) + Number(s.width))) + FLOOR_PAD;
  const planH = Math.max(...spots.map((s) => Number(s.pos_y) + Number(s.height))) + FLOOR_PAD + (editing ? 120 : 0);
  // Fit the plan to the page width, then apply the zoom (A-/A+); anything wider scrolls sideways.
  const available = Math.max(320, body.clientWidth - 4);
  floorScale = Math.max(0.75, Math.min(1.6, available / planW)) * floorZoom;
  document.getElementById('zoomLabel').textContent = `${Math.round(floorZoom * 100)}%`;

  let matchCount = 0;
  const spotsHtml = spots.map((spot, i) => {
    if (!editing && spotMatches(spot, findTerm)) matchCount += 1;
    const w = spot.width * floorScale;
    const h = spot.height * floorScale;
    const style = `left:${spot.pos_x * floorScale}px; top:${spot.pos_y * floorScale}px; width:${w}px; height:${h}px;`;
    return spotHtml(spot, `Spot ${i + 1}`, {
      attrs: `data-i="${i}"`,
      style,
      compact: w < 130 || h < 70,
      editing,
      resizable: editing
    });
  }).join('');
  body.innerHTML = `<div class="floor-plan${editing ? ' editing' : ''}" id="floorPlan" style="width:${planW * floorScale}px; height:${planH * floorScale}px;">${spotsHtml}</div>`;
  renderFindResult(matchCount);
}

// Racks on OTHER shelves of the location are named too, and a serial whose aquarium no rack is
// linked to is reported as such rather than as a miss.
function renderFindResult(matchCountHere) {
  const el = document.getElementById('findResult');
  if (!findTerm || draft) { el.textContent = ''; return; }
  const elsewhere = shelves
    .filter((s) => s.id !== currentShelfId && (s.warehouse_id || '') === currentLocation)
    .filter((s) => (s.spots || []).some((sp) => spotMatches(sp, findTerm)))
    .map((s) => s.name);
  const serialHits = locationSerials.filter((s) => serialMatches(s, findTerm));
  const linkedSpots = shelves.filter((sh) => sh.warehouse_id === currentLocation).flatMap((sh) => sh.spots || []).filter((sp) => sp.item_code);
  const noRack = serialHits.filter((s) => !linkedSpots.some((sp) => unitFitsSpot(s, sp))).length;
  const parts = [matchCountHere ? `${matchCountHere} rack(s) here` : 'Not on this shelf'];
  if (elsewhere.length) parts.push(`also on: ${elsewhere.join(', ')}`);
  if (noRack) parts.push(`${noRack} in stock with no rack linked`);
  el.textContent = parts.join(' · ');
}

function renderShelfSelect() {
  const shelf = currentShelf();
  if (shelf) currentLocation = shelf.warehouse_id || '';
  const locations = [];
  shelves.forEach((s) => {
    if (!locations.some((l) => l.key === s.warehouse_id)) locations.push({ key: s.warehouse_id, name: s.warehouse_name || s.warehouse_id });
  });
  const locSelect = document.getElementById('locationSelect');
  locSelect.innerHTML = locations.map((l) => `<option value="${escapeHtml(l.key)}">${escapeHtml(l.name)}</option>`).join('');
  if (currentLocation !== null) locSelect.value = currentLocation;
  locSelect.disabled = !!draft;

  const select = document.getElementById('shelfSelect');
  select.innerHTML = shelves.filter((s) => s.warehouse_id === currentLocation)
    .map((s) => `<option value="${s.id}">${escapeHtml(s.name)}</option>`).join('');
  if (currentShelfId) select.value = String(currentShelfId);
  select.disabled = !!draft;
}

// ---------------------------------------------------------------- Loading

async function loadLocationSerials() {
  if (!currentLocation) { locationSerials = []; return; }
  const { data, error } = await rpc('staff_list_production_location_serials', { p_warehouse_id: currentLocation });
  locationSerials = error ? [] : (data || []);
  if (error) showError(error.message);
}

async function loadShelves(keepId) {
  document.getElementById('shelfLoading').classList.remove('hidden');
  showError('');
  const { data, error } = await rpc('staff_get_production_shelves', {});
  if (error) {
    document.getElementById('shelfLoading').classList.add('hidden');
    showError(error.message);
    return;
  }
  shelves = data || [];
  currentShelfId = shelves.some((s) => s.id === keepId) ? keepId
    : (shelves.some((s) => s.id === currentShelfId) ? currentShelfId : (shelves[0] ? shelves[0].id : null));
  if (!currentShelf()) currentLocation = null;
  renderShelfSelect();
  await loadLocationSerials();
  document.getElementById('shelfLoading').classList.add('hidden');
  renderShelf();
}

async function loadWarehouseOptions() {
  const select = document.getElementById('shelfWarehouseSelect');
  if (select.options.length > 1) return;
  const { data } = await rpc('staff_search_warehouses', { p_search: null, p_limit: 100 });
  (data || []).sort((a, b) => Number(b.is_production_warehouse) - Number(a.is_production_warehouse) || (a.name || '').localeCompare(b.name || ''))
    .forEach((w) => {
      const option = document.createElement('option');
      option.value = w.id;
      option.textContent = w.name + (w.is_production_warehouse ? ' (production)' : '');
      select.appendChild(option);
    });
}

// ---------------------------------------------------------------- Rack popup (read only)

function openSpotModal(spotId) {
  const spot = findSpot(spotId);
  if (!spot) return;
  const tag = spotTagText(spot);
  const serials = spotSerials(spot);
  const shared = sharedWith(spot);
  document.getElementById('spotModalTitle').textContent = `${spot.shelf.name} › ${spotName(spot)}${tag ? ` - ${tag}` : ''}`;
  document.getElementById('spotModalSub').textContent = [
    spot.item_code ? `${spot.item_code}${spot.variant_name ? ' · ' + spot.variant_name : ''}${spot.item_name ? ' - ' + spot.item_name : ''}` : '',
    spot.shelf.warehouse_name || '',
    spot.capacity ? `fits ${spot.capacity}` : '',
    spot.notes || ''
  ].filter(Boolean).join(' · ');
  const stockEl = document.getElementById('spotModalStock');
  stockEl.innerHTML = serials
    ? `<b>${serials.length}</b> serial(s) in stock at ${escapeHtml(spot.shelf.warehouse_name || 'this location')}${shared.length ? ` - same aquarium as ${escapeHtml(shared.join(', '))}, so the count is shared` : ''}.`
    : `No aquarium is linked to this rack${canEditLayout ? ' - Edit Layout, tap the rack and pick one under "Item for this spot" to count it' : ''}.`;
  document.getElementById('spotSerials').innerHTML = !serials ? ''
    : serials.length
      ? serials.map((s) => `
        <div class="spot-serial-row">
          <div class="grow">
            <b>${escapeHtml(s.serial_no)}</b>
            <div class="muted" style="font-size:12px;">${escapeHtml(s.item_code)}${s.variant_name ? ' · ' + escapeHtml(s.variant_name) : ''} - ${escapeHtml(s.item_description || '')}</div>
            <div class="muted" style="font-size:11px;">${s.source_document_no ? escapeHtml(s.source_document_no) + ' · ' : ''}${s.created_at ? 'created ' + escapeHtml(new Date(s.created_at).toLocaleDateString()) : ''}</div>
          </div>
        </div>`).join('')
      : '<p class="muted">None in stock.</p>';
  document.getElementById('spotModal').classList.remove('hidden');
}

function closeSpotModal() {
  document.getElementById('spotModal').classList.add('hidden');
}

// ---------------------------------------------------------------- Layout editing

function setEditing(on) {
  document.getElementById('editBar').classList.toggle('hidden', !on);
  document.getElementById('editBtn').classList.toggle('hidden', on || !canEditLayout || !currentShelf());
  document.getElementById('newShelfBtn').classList.toggle('hidden', on || !canEditLayout);
  document.getElementById('findInput').disabled = on;
  if (on) refreshEditBar();
}

function refreshEditBar() {
  const floor = draft?.layout === 'floor';
  document.getElementById('shelfLayoutSelect').value = draft?.layout || 'grid';
  document.getElementById('addRowBtn').textContent = floor ? '+ Spot' : '+ Row';
  document.getElementById('floorEditHint').classList.toggle('hidden', !floor);
}

function startEdit(newShelf) {
  const shelf = currentShelf();
  if (newShelf) {
    draft = { id: null, name: '', warehouse_id: currentLocation || '', layout: 'floor', spots: [] };
  } else if (shelf.layout === 'floor') {
    draft = { id: shelf.id, name: shelf.name, warehouse_id: shelf.warehouse_id, layout: 'floor', spots: withFloorGeometry((shelf.spots || []).map((s) => ({ ...s }))) };
  } else {
    draft = { id: shelf.id, name: shelf.name, warehouse_id: shelf.warehouse_id, layout: 'grid', rows: spotsToRows(shelf.spots).map((row) => row.map((s) => ({ ...s }))) };
  }
  document.getElementById('shelfNameInput').value = draft.name;
  document.getElementById('deleteShelfBtn').classList.toggle('hidden', !draft.id);
  loadWarehouseOptions().then(() => { document.getElementById('shelfWarehouseSelect').value = draft.warehouse_id || ''; });
  setEditing(true);
  renderShelfSelect();
  renderShelf();
}

function switchDraftLayout(layout) {
  if (!draft || draft.layout === layout) return;
  if (layout === 'floor') {
    draft.spots = withFloorGeometry(draft.rows.flat().map((s) => ({ ...s, width: null, height: null })));
    delete draft.rows;
  } else {
    draft.rows = floorToRows(draft.spots);
    if (!draft.rows.length) draft.rows = [[]];
    delete draft.spots;
  }
  draft.layout = layout;
  refreshEditBar();
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
  if (!draft.name) { window.alert('Give the shelf a name first.'); return; }
  if (!draft.warehouse_id) { window.alert('Pick the warehouse this shelf is in first.'); return; }
  const round = (v) => (v === null || v === undefined || v === '' ? null : Math.round(Number(v)));
  const base = (s) => ({
    id: s.id || null, label: s.label || '', capacity: s.capacity ? Number(s.capacity) : null, notes: s.notes || null,
    size_tag: s.size_tag || null, item_code: s.item_code || null, variant_id: s.item_code ? (s.variant_id || null) : null
  });
  const spots = draft.layout === 'floor'
    ? draft.spots.map((s, i) => ({ ...base(s), row_no: 0, col_no: i, pos_x: round(s.pos_x), pos_y: round(s.pos_y), width: round(s.width), height: round(s.height) }))
    : draft.rows.flatMap((row, r) => row.map((s, c) => ({ ...base(s), row_no: r, col_no: c, pos_x: null, pos_y: null, width: null, height: null })));

  const btn = document.getElementById('saveBtn');
  btn.disabled = true;
  const { data, error } = await rpc('admin_save_production_shelf', {
    p_id: draft.id, p_name: draft.name, p_warehouse_id: draft.warehouse_id, p_spots: spots, p_layout: draft.layout
  });
  btn.disabled = false;
  if (error) { window.alert('Failed to save: ' + error.message); return; }
  draft = null;
  setEditing(false);
  await loadShelves(data);
  setEditing(false);
}

function addFloorSpot() {
  const bottom = draft.spots.length ? Math.max(...draft.spots.map((s) => Number(s.pos_y) + Number(s.height))) : 0;
  draft.spots.push({ label: '', capacity: null, notes: '', pos_x: FLOOR_PAD, pos_y: bottom + 15, ...NEW_SPOT });
  renderShelf();
  openCellModal({ i: draft.spots.length - 1 });
}

function modalSpot() {
  if (!modalCell) return null;
  return modalCell.i !== undefined ? draft.spots[modalCell.i] : draft.rows[modalCell.r][modalCell.c];
}

// The item/variant being picked in the spot modal - applied to the spot on OK.
let cellItem = null; // { item_code, item_name, variant_id, variant_name } or null

function renderCellItem() {
  document.getElementById('cellItemLabel').textContent = cellItem
    ? `${cellItem.item_code}${cellItem.item_name ? ' - ' + cellItem.item_name : ''}` : 'none';
  document.getElementById('cellUnlinkBtn').classList.toggle('hidden', !cellItem);
  document.getElementById('cellVariantRow').classList.toggle('hidden', !cellItem);
}

async function loadCellVariants() {
  const select = document.getElementById('cellVariant');
  select.innerHTML = '<option value="">Any variant</option>';
  if (!cellItem) return;
  const { data } = await rpc('staff_search_variants', { p_item_code: cellItem.item_code, p_search: null, p_limit: 100 });
  (data || []).forEach((v) => {
    const option = document.createElement('option');
    option.value = v.variation_id;
    option.textContent = [v.sku, v.variant_name].filter(Boolean).join(' - ') || v.variation_id;
    option.dataset.name = v.variant_name || v.sku || v.variation_id;
    select.appendChild(option);
  });
  select.value = cellItem.variant_id || '';
  document.getElementById('cellVariantRow').classList.toggle('hidden', !(data || []).length);
}

let cellItemTimer = null;
function onCellItemSearch() {
  clearTimeout(cellItemTimer);
  const term = document.getElementById('cellItemSearch').value.trim();
  const hitsEl = document.getElementById('cellItemHits');
  if (!term) { hitsEl.innerHTML = ''; return; }
  cellItemTimer = setTimeout(async () => {
    const { data } = await rpc('staff_search_items', { p_search: term, p_limit: 10 });
    hitsEl.innerHTML = (data || []).length
      ? data.map((h) => `<div class="item-hit" data-code="${escapeHtml(h.code)}" data-name="${escapeHtml(h.name || '')}">${escapeHtml(h.code)} - ${escapeHtml(h.name || '')}</div>`).join('')
      : '<div class="muted" style="padding:6px;">No items found.</div>';
  }, 250);
}

function openCellModal(ref) {
  modalCell = ref;
  const spot = modalSpot();
  const floor = ref.i !== undefined;
  document.getElementById('cellSizeTag').value = spot.size_tag || '';
  cellItem = spot.item_code
    ? { item_code: spot.item_code, item_name: spot.item_name || '', variant_id: spot.variant_id || null, variant_name: spot.variant_name || '' }
    : null;
  document.getElementById('cellItemSearch').value = '';
  document.getElementById('cellItemHits').innerHTML = '';
  renderCellItem();
  loadCellVariants();
  document.getElementById('cellLabel').value = spot.label || '';
  document.getElementById('cellCapacity').value = spot.capacity || '';
  document.getElementById('cellNotes').value = spot.notes || '';
  document.getElementById('cellLeftBtn').classList.toggle('hidden', floor);
  document.getElementById('cellRightBtn').classList.toggle('hidden', floor);
  document.getElementById('cellRotateBtn').classList.toggle('hidden', !floor);
  document.getElementById('cellModal').classList.remove('hidden');
  document.getElementById('cellLabel').focus();
}

function closeCellModal() {
  document.getElementById('cellModal').classList.add('hidden');
  modalCell = null;
}

function applyCellModal() {
  const spot = modalSpot();
  spot.label = document.getElementById('cellLabel').value.trim();
  const cap = document.getElementById('cellCapacity').value;
  spot.capacity = cap === '' ? null : Math.max(1, Math.round(Number(cap)));
  spot.notes = document.getElementById('cellNotes').value.trim();
  spot.size_tag = document.getElementById('cellSizeTag').value.trim();
  const variantSelect = document.getElementById('cellVariant');
  spot.item_code = cellItem ? cellItem.item_code : null;
  spot.item_name = cellItem ? cellItem.item_name : null;
  // The variant list loads async - if OK comes first, keep what the spot already had.
  const variantsLoaded = variantSelect.options.length > 1;
  spot.variant_id = !cellItem ? null : variantsLoaded ? (variantSelect.value || null) : (cellItem.variant_id || null);
  spot.variant_name = !spot.variant_id ? null
    : variantsLoaded ? (variantSelect.selectedOptions[0]?.dataset.name || '') : (cellItem.variant_name || '');
  closeCellModal();
  renderShelf();
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

// Upright <-> lengthwise, turning about the spot's centre.
function rotateCell() {
  const spot = modalSpot();
  const cx = Number(spot.pos_x) + Number(spot.width) / 2;
  const cy = Number(spot.pos_y) + Number(spot.height) / 2;
  [spot.width, spot.height] = [spot.height, spot.width];
  spot.pos_x = Math.max(0, cx - spot.width / 2);
  spot.pos_y = Math.max(0, cy - spot.height / 2);
  applyCellModal();
}

// Floor-plan editing: drag a spot to move it, drag its corner to resize, tap it (no drag) to open its
// settings. Positions are kept in plan units; the element is moved directly while dragging and the
// plan re-rendered on release.
function wireFloorDrag() {
  const body = document.getElementById('shelfBody');
  let drag = null;

  body.addEventListener('pointerdown', (e) => {
    if (!draft || draft.layout !== 'floor') return;
    const el = e.target.closest('.pspot[data-i]');
    if (!el) return;
    const spot = draft.spots[Number(el.dataset.i)];
    drag = {
      el, spot, index: Number(el.dataset.i),
      mode: e.target.closest('[data-resize]') ? 'resize' : 'move',
      startX: e.clientX, startY: e.clientY,
      orig: { x: Number(spot.pos_x), y: Number(spot.pos_y), w: Number(spot.width), h: Number(spot.height) },
      moved: false
    };
    el.setPointerCapture(e.pointerId);
    e.preventDefault();
  });

  body.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const dx = (e.clientX - drag.startX) / floorScale;
    const dy = (e.clientY - drag.startY) / floorScale;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4 / floorScale) return;
    drag.moved = true;
    const { spot, orig, el } = drag;
    if (drag.mode === 'move') {
      spot.pos_x = Math.max(0, Math.round(orig.x + dx));
      spot.pos_y = Math.max(0, Math.round(orig.y + dy));
      el.style.left = `${spot.pos_x * floorScale}px`;
      el.style.top = `${spot.pos_y * floorScale}px`;
    } else {
      spot.width = Math.max(30, Math.round(orig.w + dx));
      spot.height = Math.max(30, Math.round(orig.h + dy));
      el.style.width = `${spot.width * floorScale}px`;
      el.style.height = `${spot.height * floorScale}px`;
    }
  });

  const end = () => {
    if (!drag) return;
    const { moved, index } = drag;
    drag = null;
    if (moved) renderShelf();
    else openCellModal({ i: index });
  };
  body.addEventListener('pointerup', end);
  body.addEventListener('pointercancel', () => { drag = null; renderShelf(); });
}

// ---------------------------------------------------------------- Init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Production Shelf Map');
  canEditLayout = !!(session.isSuperUser || session.isProductionManager);
  setEditing(false);

  document.getElementById('locationSelect').addEventListener('change', async (e) => {
    const first = shelves.find((s) => s.warehouse_id === e.target.value);
    currentShelfId = first ? first.id : null;
    currentLocation = e.target.value;
    renderShelfSelect();
    await loadLocationSerials();
    renderShelf();
  });
  document.getElementById('shelfSelect').addEventListener('change', (e) => {
    currentShelfId = Number(e.target.value);
    renderShelfSelect();
    renderShelf();
  });

  let findTimer = null;
  document.getElementById('findInput').addEventListener('input', (e) => {
    clearTimeout(findTimer);
    findTimer = setTimeout(() => {
      findTerm = e.target.value.trim();
      // Jump to the shelf with a matching rack when it isn't the one showing.
      if (findTerm) {
        const here = (currentShelf()?.spots || []).some((sp) => spotMatches(sp, findTerm));
        const other = !here && shelves.find((sh) => sh.warehouse_id === currentLocation
          && (sh.spots || []).some((sp) => spotMatches(sp, findTerm)));
        if (other) { currentShelfId = other.id; renderShelfSelect(); }
      }
      renderShelf();
    }, 200);
  });

  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { if (currentLayout() === 'floor') renderShelf(); }, 150);
  });

  document.getElementById('refreshBtn').addEventListener('click', () => loadShelves(currentShelfId));
  document.getElementById('zoomOutBtn').addEventListener('click', () => setZoom(-1));
  document.getElementById('zoomInBtn').addEventListener('click', () => setZoom(1));
  document.getElementById('editBtn').addEventListener('click', () => { if (currentShelf()) startEdit(false); });
  document.getElementById('newShelfBtn').addEventListener('click', () => startEdit(true));
  document.getElementById('cancelBtn').addEventListener('click', cancelEdit);
  document.getElementById('saveBtn').addEventListener('click', saveDraft);
  document.getElementById('shelfLayoutSelect').addEventListener('change', (e) => switchDraftLayout(e.target.value));
  document.getElementById('addRowBtn').addEventListener('click', () => {
    if (draft.layout === 'floor') { addFloorSpot(); return; }
    draft.rows.push([]);
    renderShelf();
  });
  document.getElementById('deleteShelfBtn').addEventListener('click', async () => {
    if (!draft.id || !window.confirm(`Delete shelf "${draft.name}"? Stock and serials are not affected.`)) return;
    const { error } = await rpc('admin_delete_production_shelf', { p_id: draft.id });
    if (error) { window.alert('Failed to delete: ' + error.message); return; }
    draft = null;
    currentShelfId = null;
    setEditing(false);
    await loadShelves();
    setEditing(false);
  });

  // Rack taps: view mode lists its aquarium's serials; grid layout editing opens the spot's settings;
  // floor-plan editing is handled by wireFloorDrag.
  const onSpot = (target) => {
    const spotEl = target.closest('.pspot');
    if (!spotEl) return;
    if (draft) {
      if (draft.layout === 'grid') openCellModal({ r: Number(spotEl.dataset.r), c: Number(spotEl.dataset.c) });
      return;
    }
    const spotId = Number(spotEl.dataset.spotId);
    if (spotId) openSpotModal(spotId);
  };
  document.getElementById('shelfBody').addEventListener('click', (e) => {
    const addCell = e.target.closest('[data-addcell]');
    const delRow = e.target.closest('[data-delrow]');
    if (draft && addCell) {
      const r = Number(addCell.dataset.addcell);
      draft.rows[r].push({ label: '', capacity: null, notes: '' });
      renderShelf();
      openCellModal({ r, c: draft.rows[r].length - 1 });
      return;
    }
    if (draft && delRow) {
      const r = Number(delRow.dataset.delrow);
      if (draft.rows[r].length && !window.confirm('Delete this row and every spot in it?')) return;
      draft.rows.splice(r, 1);
      renderShelf();
      return;
    }
    onSpot(e.target);
  });
  document.getElementById('shelfBody').addEventListener('keydown', (e) => {
    if ((e.key === 'Enter' || e.key === ' ') && e.target.classList.contains('pspot')) {
      e.preventDefault();
      if (draft && draft.layout === 'floor') openCellModal({ i: Number(e.target.dataset.i) });
      else onSpot(e.target);
    }
  });
  wireFloorDrag();

  // Clicking a Stock by size row finds its racks on the map.
  document.getElementById('sizeSummary').addEventListener('click', (e) => {
    const row = e.target.closest('tr[data-find]');
    if (!row) return;
    const input = document.getElementById('findInput');
    input.value = row.dataset.find;
    input.dispatchEvent(new Event('input'));
    document.getElementById('shelfBody').scrollIntoView({ behavior: 'smooth', block: 'start' });
  });

  document.getElementById('spotCloseBtn').addEventListener('click', closeSpotModal);

  document.getElementById('cellOkBtn').addEventListener('click', applyCellModal);
  document.getElementById('cellCancelBtn').addEventListener('click', closeCellModal);
  document.getElementById('cellLeftBtn').addEventListener('click', () => moveCell(-1));
  document.getElementById('cellRightBtn').addEventListener('click', () => moveCell(1));
  document.getElementById('cellRotateBtn').addEventListener('click', rotateCell);
  document.getElementById('cellItemSearch').addEventListener('input', onCellItemSearch);
  document.getElementById('cellItemHits').addEventListener('click', (e) => {
    const hit = e.target.closest('.item-hit');
    if (!hit) return;
    cellItem = { item_code: hit.dataset.code, item_name: hit.dataset.name, variant_id: null, variant_name: null };
    document.getElementById('cellItemSearch').value = '';
    document.getElementById('cellItemHits').innerHTML = '';
    renderCellItem();
    loadCellVariants();
  });
  document.getElementById('cellUnlinkBtn').addEventListener('click', () => {
    cellItem = null;
    renderCellItem();
  });
  document.getElementById('cellDeleteBtn').addEventListener('click', () => {
    if (modalCell.i !== undefined) draft.spots.splice(modalCell.i, 1);
    else draft.rows[modalCell.r].splice(modalCell.c, 1);
    closeCellModal();
    renderShelf();
  });

  const findParam = new URLSearchParams(window.location.search).get('find');
  if (findParam) {
    findTerm = findParam.trim();
    document.getElementById('findInput').value = findTerm;
  }

  await loadShelves();
  setEditing(false);
})();
