// Purchase Orders list page (any active staff, same access level as Stock On Hand - see
// supabase_purchase_orders.sql's header comment for why this is staff-gated, not admin-gated).
let currentSession = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let searchDebounceHandle = null;

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleDateString();
}

// Supabase/PostgREST errors often have an empty .message with the actual detail sitting in
// .details/.hint instead (e.g. check-constraint failures) - same helper as transferOrders.js'
// describeSupabaseError, copied locally since this page doesn't load that script.
function describeSupabaseError(err, fallback) {
  console.error(fallback, err);
  const parts = [err?.message, err?.details, err?.hint].filter(Boolean);
  if (parts.length > 0) return parts.join(' - ');
  if (err?.code) return `${fallback} (code: ${err.code})`;
  return fallback;
}

// Pancake's own error text (surfaced in the Pancake Sync panel below) is external content, so it
// gets escaped before going into innerHTML - same care transferOrders.js's own Pancake Sync panel
// takes with its escapeHtml helper.
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
}

// Receiving progress badge - purely a client-side read of total_quantity vs
// total_received_quantity (see staff_list_purchase_orders), no separate status column to keep
// in sync.
function receivedBadgeHtml(po) {
  const total = Number(po.total_quantity || 0);
  const received = Number(po.total_received_quantity || 0);
  if (received <= 0) return '<span class="badge badge-neutral">Not Received</span>';
  if (received >= total) return '<span class="badge badge-success">Fully Received</span>';
  return `<span class="badge badge-warning">${received.toLocaleString()} / ${total.toLocaleString()}</span>`;
}

function poRowsHtml(rows) {
  return rows
    .map((po) => `
      <tr class="clickable-row" data-po-no="${encodeURIComponent(po.po_no)}">
        <td>${po.po_no}</td>
        <td>${po.vendor_name || po.vendor_code || ''}</td>
        <td>${escapeHtml(po.warehouse_name || '')}</td>
        <td>${formatDate(po.order_date)}</td>
        <td style="text-align:right;">${po.line_count ?? 0}</td>
        <td style="text-align:right;">${Number(po.total_quantity || 0).toLocaleString()}</td>
        <td>${receivedBadgeHtml(po)}</td>
        <td>${po.created_by || ''}</td>
        <td>
          <a href="purchase-order-print.html?po=${encodeURIComponent(po.po_no)}" class="btn btn-secondary btn-sm" onclick="event.stopPropagation();">Print</a>
          <button class="btn btn-secondary btn-sm" data-delete-po="${encodeURIComponent(po.po_no)}" data-received-qty="${Number(po.total_received_quantity || 0)}" type="button" onclick="event.stopPropagation();">Delete</button>
        </td>
      </tr>
    `)
    .join('');
}

async function loadPurchaseOrders() {
  const tbody = document.getElementById('poTableBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_purchase_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="9" class="muted">No Purchase Orders yet - create one from Stock On Hand.</td></tr>'
    : poRowsHtml(rows);

  tbody.querySelectorAll('tr[data-po-no]').forEach((row) => {
    row.addEventListener('click', () => openReceiveModal(decodeURIComponent(row.dataset.poNo)));
  });

  renderPaginationBar(
    document.getElementById('poPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: rows[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadPurchaseOrders(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadPurchaseOrders(); }
    }
  );
}

async function deletePurchaseOrder(poNo, receivedQty) {
  // Receiving already pushed a real stock-in to Pancake (see staff_receive_purchase_order_lines) -
  // deleting the portal record does NOT reverse that, so make sure staff know before they delete
  // what looks like just a local document.
  const message = receivedQty > 0
    ? `Purchase Order ${poNo} has already received ${receivedQty} unit(s), which were pushed to Pancake as stock. Deleting this record will NOT reverse that Pancake stock-in - only the portal's own PO record is removed. Delete anyway?`
    : `Delete Purchase Order ${poNo}? This cannot be undone.`;
  if (!window.confirm(message)) return;

  const { error } = await supabaseClient.rpc('staff_delete_purchase_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_po_no: poNo
  });

  if (error) {
    window.alert(error.message);
    return;
  }

  await loadPurchaseOrders();
}

// Receive Purchase Order modal - view a PO's lines and receive stock against them (running
// cumulative QtyReceived, capped at each line's ordered Quantity - see
// staff_receive_purchase_order_lines in supabase_purchase_order_receiving.sql), then post the
// whole order into Posted Purchase Orders once done receiving.
let currentReceivePoNo = null;

function receiveLineRemaining(l) {
  return Math.max(0, (Number(l.quantity) || 0) - (Number(l.qty_received) || 0));
}

// Adding/removing lines on an existing PO is super-user only, per direct instruction - see
// staff_add_purchase_order_line/staff_remove_purchase_order_line in
// supabase_purchase_order_edit_lines.sql, which enforce the same gate server-side (this client
// check is just what shows the controls, not the actual security boundary).
// Business Central-style document view state (maximize + General FastTab), remembered per browser
// so the layout someone settles on survives a reload rather than resetting on every open.
//
// localStorage is wrapped because it throws outright in some privacy modes rather than just
// returning null - a stored preference must never be able to stop the PO modal from opening.
const PO_MAXIMIZED_KEY = 'po-receive-modal-maximized';
const PO_GENERAL_TAB_KEY = 'po-receive-general-tab-open';
// The New Purchase Order document gets the same treatment but its OWN keys - entering an order
// and receiving one are different jobs, so the layout each is left in is remembered separately.
const PO_NEW_MAXIMIZED_KEY = 'po-new-modal-maximized';
const PO_NEW_GENERAL_TAB_KEY = 'po-new-general-tab-open';

function readStoredFlag(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value === null ? fallback : value === '1';
  } catch (err) {
    return fallback;
  }
}

function writeStoredFlag(key, value) {
  try {
    localStorage.setItem(key, value ? '1' : '0');
  } catch (err) {
    /* Preference simply won't persist - not worth surfacing. */
  }
}

function applyReceiveMaximized(maximized) {
  document.getElementById('receiveModal').classList.toggle('modal-maximized', maximized);
  document.getElementById('receiveModal').querySelector('.modal-panel')
    .classList.toggle('modal-maximized', maximized);

  const btn = document.getElementById('receiveMaximizeBtn');
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized
    ? 'Restore this document to a window'
    : 'Maximize this document to fill the window';
}

// Same as applyReceiveMaximized, for the New Purchase Order document. Both classes are needed:
// the backdrop drops its centring padding, the panel becomes the full-viewport flex column whose
// only scrolling part is the lines grid.
function applyNewPoMaximized(maximized) {
  document.getElementById('newPoModal').classList.toggle('modal-maximized', maximized);
  document.getElementById('newPoModal').querySelector('.modal-panel')
    .classList.toggle('modal-maximized', maximized);

  const btn = document.getElementById('newPoMaximizeBtn');
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized
    ? 'Restore this document to a window'
    : 'Maximize this document to fill the window';
}

// What the General FastTab shows on itself once collapsed - the vendor is the one header field
// you cannot afford to lose sight of while entering lines (it also scopes the item picker).
function refreshNewPoGeneralSummary() {
  const select = document.getElementById('newPoVendor');
  const vendorLabel = select.value ? select.selectedOptions[0].textContent : 'No vendor selected';
  const warehouseLabel = newPoHeaderWarehouseName();
  const notes = document.getElementById('newPoNotes').value.trim();

  document.getElementById('newPoGeneralSummary').textContent =
    [vendorLabel, warehouseLabel, notes].filter(Boolean).join(' · ');
}

// Item Code, Item Name, Variant, Description, Warehouse, Qty Ordered, UoM, Qty Received,
// Unit Cost, Line Cost, plus the super-user-only Remove column.
function receiveLinesColspan() {
  return currentSession?.isSuperUser ? 11 : 10;
}

// An uncosted line shows a dash, not 0.00 - "nobody has costed this yet" needs to stay visible,
// especially since it is also why the PO total below may look lower than expected.
function formatCost(value) {
  if (value === null || value === undefined) return '<span class="muted">-</span>';
  return Number(value).toFixed(2);
}

// Unit Cost is editable in place for a super user, but only until something is received against
// the line - past that the stock was already taken in at this cost, so changing it would rewrite
// history (staff_set_purchase_order_line_cost enforces the same rule server-side). Everyone else,
// and every already-received line, sees plain text.
// Shown and edited PER THE LINE'S ORDERING UNIT (unit_cost_uom, derived in
// supabase_purchase_order_line_uom_edit.sql), so a line reading "5 BOX" costs out as 5 x the box
// price. The stored figure stays per base unit - what costing and the GL consume - so the input
// carries its conversion and divides on the way back out.
function unitCostCell(l) {
  const editable = currentSession?.isSuperUser && Number(l.qty_received || 0) === 0;
  const qtyPer = Number(l.qty_per_uom || 1);
  // Falls back to the stored base cost when unit_cost_uom is not there - which is the case on any
  // database that has not run supabase_purchase_order_line_uom_edit.sql yet. Reading only the
  // derived column made this cell render empty on those, so a cost typed into it vanished on the
  // reload that follows the save. Same fallback the print and posted views already use.
  const rawPerUom = l.unit_cost_uom ?? l.unit_cost;
  const perUom = rawPerUom === null || rawPerUom === undefined ? null : Number(rawPerUom);

  // The Qty Ordered column beside this leads with the BASE quantity (what a receiver counts), so a
  // box price on its own would read as "60 x 480". Both are shown, the way that column shows both:
  // the per-unit price is the one you type, the base one is what gets stored and costed.
  const baseNote = qtyPer !== 1 && l.unit_cost !== null && l.unit_cost !== undefined
    ? `<div class="muted" style="font-size:11px;">${Number(l.unit_cost).toFixed(2)} / base</div>`
    : '';

  if (!editable) return `${formatCost(perUom)}${baseNote}`;

  const value = perUom === null ? '' : perUom;
  // data-original lets the blur handler tell a real edit from a plain tab-through.
  return `<input type="number" class="line-cost-input" min="0" step="0.01" value="${value}" placeholder="-" style="width:95px; text-align:right;" data-entry-no="${l.entry_no}" data-original="${value}" data-qty-per="${qtyPer}" title="Unit cost per ${escapeHtml(l.uom_code || 'unit')} - saved when you leave the field" />${baseNote}`;
}

// A line's variant, per "on the PO the item has variant.. can we pull out the variant field while
// modifying the PO". Picking one re-points the line at that variant's own item code and renames it
// "Item - Variant", all resolved server-side (staff_set_purchase_order_line_variant,
// supabase_purchase_order_line_variant.sql) so it lands exactly as a newly created line would.
//
// staff_search_variants matches on ItemCode OR MainItemCode, so the line's own item code finds the
// right family whether the line sits on the parent item or on a variant's resolved code.
const variantsByItemCode = new Map();

// How a variant is written wherever one is shown or stored, per "for variant can you show the SKU
// i think that is much detailed description". The SKU leads because it is the fuller identifier
// ("A-029-6MM-BLK") next to a bare VariantName ("Black"), but neither is dropped: whichever of the
// two the catalog actually fills in is what a row ends up reading.
//
// Mirrored server-side by public._po_variant_display_name (supabase_purchase_order_line_variant.sql)
// so a variant picked here and a variant set on an existing line produce the same text.
function variantDisplayName(sku, variantName) {
  const s = (sku || '').trim();
  const n = (variantName || '').trim();

  if (!s) return n;
  if (!n) return s;
  // One already spells the other out - Pancake often repeats the variant name inside the SKU -
  // so the longer of the two says everything the pair would.
  if (s.toLowerCase().includes(n.toLowerCase())) return s;
  if (n.toLowerCase().includes(s.toLowerCase())) return n;
  return `${s} - ${n}`;
}

async function ensureVariantsLoaded(itemCodes) {
  const missing = [...new Set(itemCodes)].filter((code) => code && !variantsByItemCode.has(code));

  await Promise.all(missing.map(async (code) => {
    const { data, error } = await supabaseClient.rpc('staff_search_variants', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_item_code: code,
      p_search: null,
      p_limit: 100
    });
    variantsByItemCode.set(code, error ? [] : (data || []));
  }));
}

// A picker while the line is untouched, plain text once it has been received against - the same
// gate the UoM cell uses, and the same one the RPC enforces. An item with no variants at all reads
// as a dash.
function variantCell(l) {
  const variants = variantsByItemCode.get(l.item_code) || [];
  const editable = currentSession?.isSuperUser && Number(l.qty_received || 0) === 0 && variants.length > 0;

  if (!editable) {
    // The stored VariantName is already the SKU-led label for anything picked since that became
    // the rule, but a line saved before it carries the bare variant name - resolving against the
    // loaded catalog first means an old line reads the same as a new one.
    const matched = variants.find((v) => v.variation_id === l.variant_code);
    const shown = matched ? variantDisplayName(matched.sku, matched.variant_name) : (l.variant_name || '');
    return shown ? escapeHtml(shown) : '<span class="muted">-</span>';
  }

  const current = l.variant_code || '';
  return `<select class="line-variant-select" data-entry-no="${l.entry_no}" data-original="${escapeHtml(current)}" title="Which variant of this item is being ordered">
    <option value=""${current ? '' : ' selected'}>(No variant)</option>
    ${variants.map((v) => {
      const label = variantDisplayName(v.sku, v.variant_name) || v.variation_id;
      return `<option value="${escapeHtml(v.variation_id)}"${v.variation_id === current ? ' selected' : ''}>${escapeHtml(label)}</option>`;
    }).join('')}
  </select>`;
}

async function savePurchaseOrderLineVariant(select) {
  const value = select.value;
  if (value === (select.dataset.original || '')) return;

  select.disabled = true;
  const { error } = await supabaseClient.rpc('staff_set_purchase_order_line_variant', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: Number(select.dataset.entryNo),
    p_variation_id: value || null
  });
  select.disabled = false;

  if (error) {
    window.alert(describeSupabaseError(error, 'Failed to change the variant.'));
    select.value = select.dataset.original || '';
    return;
  }

  // The line's item code and name both moved, so the document is reloaded rather than patched.
  await openReceiveModal(currentReceivePoNo);
}

// The item's units of measure, fetched once per item code and kept for the session - a PO's lines
// repeat the same items often enough, and re-opening the document should not re-ask.
const itemUnitsByItemCode = new Map();

async function ensureItemUnitsLoaded(itemCodes) {
  const missing = [...new Set(itemCodes)].filter((code) => code && !itemUnitsByItemCode.has(code));

  await Promise.all(missing.map(async (code) => {
    const { data, error } = await supabaseClient.rpc('staff_list_item_units_of_measure', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_item_code: code
    });
    // An item whose units could not be read is cached as "none", which renders as plain text -
    // better than a picker that cannot resolve what it is offering.
    itemUnitsByItemCode.set(code, error ? [] : (data || []));
  }));
}

// Per "on editing the PO can we change the UOM?" - a picker while the line is still untouched,
// plain text once it has been received against (staff_set_purchase_order_line_uom blocks the
// change server-side at the same point, because that quantity is already stock in Pancake).
// An item with only its base unit has nothing to switch to, so it reads as text too.
function uomCell(l) {
  const units = itemUnitsByItemCode.get(l.item_code) || [];
  const current = l.uom_code || units.find((u) => u.is_base)?.unit_of_measure_code || '';
  const editable = currentSession?.isSuperUser && Number(l.qty_received || 0) === 0 && units.length > 1;

  if (!editable) return escapeHtml(current);

  return `<select class="line-uom-select" data-entry-no="${l.entry_no}" data-original="${escapeHtml(current)}" title="Changing this keeps the quantity as typed and restates the base quantity">
    ${units.map((u) => `<option value="${escapeHtml(u.unit_of_measure_code)}"${u.unit_of_measure_code === current ? ' selected' : ''}>${escapeHtml(u.unit_of_measure_code)}</option>`).join('')}
  </select>`;
}

async function savePurchaseOrderLineUom(select) {
  const value = select.value;
  if (value === (select.dataset.original || '')) return;

  select.disabled = true;
  const { error } = await supabaseClient.rpc('staff_set_purchase_order_line_uom', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: Number(select.dataset.entryNo),
    p_unit_of_measure_code: value
  });
  select.disabled = false;

  if (error) {
    window.alert(describeSupabaseError(error, 'Failed to change the unit of measure.'));
    select.value = select.dataset.original || '';
    return;
  }

  // The base quantity and the line cost both moved, so the document is reloaded rather than
  // patched - same as a cost change.
  await openReceiveModal(currentReceivePoNo);
}

// Free-text note per line, typed straight into the grid and carried onto the printed PO. Unlike
// Unit Cost this stays editable after receiving - a description is a note for whoever handles the
// goods, and it is often only once a delivery arrives that there is something worth writing.
//
// Available to any staff on an open PO (see staff_set_purchase_order_line_description); a posted
// PO has no editable lines at all, so nothing is rendered for one.
function descriptionCell(l) {
  const value = escapeHtml(l.description || '');
  return `<input type="text" class="line-description-input" maxlength="500" value="${value}" placeholder="Add a note..." style="width:100%; min-width:170px;" data-entry-no="${l.entry_no}" data-original="${value}" title="Free text - printed on the Purchase Order" />`;
}

async function savePurchaseOrderLineDescription(input) {
  const value = input.value.trim();
  if (value === (input.dataset.original || '')) return;

  input.disabled = true;
  const { error } = await supabaseClient.rpc('staff_set_purchase_order_line_description', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: Number(input.dataset.entryNo),
    p_description: value || null
  });
  input.disabled = false;

  if (error) {
    window.alert(describeSupabaseError(error, 'Failed to update the description.'));
    // Put the stored value back, so the grid never shows text that was not actually saved.
    input.value = input.dataset.original || '';
    return;
  }

  // Cheap enough to patch in place - unlike cost, a description feeds no total, so there is
  // nothing for the server to recompute and no reason to reload the whole modal mid-typing.
  input.dataset.original = value;
}

// Saves on blur rather than per keystroke, so a half-typed number never reaches the server.
async function savePurchaseOrderLineCost(input) {
  const raw = input.value.trim();

  // Merely tabbing through a line must not fire an RPC and reload the modal underneath the user.
  if (raw === (input.dataset.original || '')) return;

  const unitCost = raw === '' ? null : Number(raw);

  if (unitCost !== null && (!Number.isFinite(unitCost) || unitCost < 0)) {
    window.alert('Enter a unit cost of 0 or more, or leave it blank if the item is not costed.');
    return;
  }

  input.disabled = true;
  const { error } = await supabaseClient.rpc('staff_set_purchase_order_line_cost', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: Number(input.dataset.entryNo),
    // Typed per the line's ordering unit, stored per base unit - the same division the New
    // Purchase Order grid does on the way in.
    p_unit_cost: unitCost === null ? null : unitCost / (Number(input.dataset.qtyPer) || 1)
  });
  input.disabled = false;

  if (error) {
    window.alert(describeSupabaseError(error, 'Failed to update the line cost.'));
    return;
  }

  // Reload the lines so the line cost and the PO total are recomputed by the server rather than
  // being patched in two places here.
  await openReceiveModal(currentReceivePoNo);
}

// Qty Ordered, in the line's own ordering unit with the base quantity underneath - the same
// pairing the Unit Cost cell uses, so a row reads "5 BOX x 480.00" straight across and the base
// figures sit beneath as the secondary. Editable for a super user on an open PO, per "in the PO
// can we modify the Qty Ordered too?" (staff_set_purchase_order_line_quantity,
// supabase_purchase_order_line_quantity_edit.sql).
//
// A quantity is entered in the ordering unit; the conversion to base happens server-side.
function qtyOrderedCell(l) {
  const qtyPer = Number(l.qty_per_uom || 1);
  // A line raised before units existed carries no QuantityUom - its Quantity was already the
  // typed number, at a conversion of 1.
  const qtyUom = l.quantity_uom === null || l.quantity_uom === undefined
    ? Number(l.quantity || 0)
    : Number(l.quantity_uom);

  const unitLabel = qtyPer !== 1 && l.uom_code ? ` ${escapeHtml(l.uom_code)}` : '';
  const baseNote = qtyPer !== 1
    ? `<div class="muted" style="font-size:11px;">${Number(l.quantity || 0).toLocaleString()} base</div>`
    : '';

  if (!currentSession?.isSuperUser) {
    return `${qtyUom.toLocaleString()}${unitLabel}${baseNote}`;
  }

  // data-original lets the blur handler tell a real edit from a plain tab-through, same as the
  // cost and description inputs.
  return `<input type="number" class="line-qty-input" min="0" step="0.01" value="${qtyUom}" style="width:90px; text-align:right;" data-entry-no="${l.entry_no}" data-original="${qtyUom}" title="Quantity ordered${unitLabel ? ', in' + unitLabel : ''} - saved when you leave the field" />${baseNote}`;
}

async function savePurchaseOrderLineQuantity(input) {
  const raw = input.value.trim();

  // Merely tabbing through a line must not fire an RPC and reload the modal underneath the user.
  if (raw === (input.dataset.original || '')) return;

  const quantity = raw === '' ? null : Number(raw);

  if (quantity === null || !Number.isFinite(quantity) || quantity <= 0) {
    window.alert('Enter a quantity greater than 0. To take the item off the order, use Remove.');
    input.value = input.dataset.original || '';
    return;
  }

  input.disabled = true;
  const { error } = await supabaseClient.rpc('staff_set_purchase_order_line_quantity', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: Number(input.dataset.entryNo),
    p_quantity_uom: quantity
  });
  input.disabled = false;

  if (error) {
    window.alert(describeSupabaseError(error, 'Failed to update the quantity.'));
    input.value = input.dataset.original || '';
    return;
  }

  // The base quantity, what is left to receive and the line cost all moved - reloaded rather than
  // patched, same as a cost or unit change.
  await openReceiveModal(currentReceivePoNo);
}

async function renderReceiveLines(lines) {
  const body = document.getElementById('receiveLinesBody');

  // The UoM and Variant pickers both need their item's own options before the rows are built.
  const itemCodes = (lines || []).map((l) => l.item_code);
  await Promise.all([ensureItemUnitsLoaded(itemCodes), ensureVariantsLoaded(itemCodes)]);
  document.getElementById('receiveLinesActionsHeader').classList.toggle('hidden', !currentSession?.isSuperUser);
  document.getElementById('receiveTotalActionsCell').classList.toggle('hidden', !currentSession?.isSuperUser);

  const totalEl = document.getElementById('receiveTotalCost');

  if (!lines || lines.length === 0) {
    body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="muted">No line items.</td></tr>`;
    if (totalEl) totalEl.textContent = '0.00';
    return;
  }

  // line_cost comes from staff_list_purchase_order_lines rather than being recomputed here, so
  // the total is derived one way only (see supabase_item_cost_and_po_line_cost.sql).
  if (totalEl) {
    totalEl.textContent = lines
      .reduce((sum, l) => sum + (Number(l.line_cost) || 0), 0)
      .toFixed(2);
  }

  body.innerHTML = lines
    .map((l) => {
      // Qty Received is where staff type what physically arrived, and that number is what gets
      // added to inventory - per "once the actual stocks has arrived the user will fill in the Qty
      // received so the system knows how many will be added on inventory".
      //
      // It is the amount arriving NOW, not a new running total, so a second delivery is entered as
      // the quantity in that delivery rather than making anyone do the arithmetic. Prefilled with
      // everything still outstanding, since a single complete delivery is the normal case.
      //
      // Kept as .receive-qty-input so it still flows through staff_receive_purchase_order_lines
      // and the Pancake stock-in - see the class comment above. Nothing here writes QtyReceived
      // directly; the running total only ever moves when Pancake confirms.
      const remaining = receiveLineRemaining(l);
      const alreadyReceived = Number(l.qty_received || 0);
      // What arrived is counted in BASE units - that is what goes to Pancake as stock, and what a
      // receiver counts on the pallet - while Qty Ordered beside it reads in the ordering unit. On
      // a line where those differ, the column says so rather than leaving it to be inferred.
      const receiveUnitNote = Number(l.qty_per_uom || 1) !== 1
        ? '<div class="muted" style="font-size:11px;">in base units</div>'
        : '';
      const receivedNote = (alreadyReceived > 0
        ? `<div class="muted" style="font-size:11px;">${alreadyReceived.toLocaleString()} received so far</div>`
        : '') + receiveUnitNote;
      const receiveInput = remaining > 0
        ? `<input type="number" class="receive-qty-input" min="0" max="${remaining}" step="0.01" value="${remaining}" style="width:90px; text-align:right;" title="How many arrived - this is what gets added to inventory" />${receivedNote}`
        : `<span class="muted" title="Fully received">&mdash;</span>${receivedNote}`;
      // A line with anything already received can't be removed (see
      // staff_remove_purchase_order_line's own server-side check) - shown disabled rather than
      // simply hidden, so it's clear removal was considered and blocked, not just unavailable.
      const removeCell = !currentSession?.isSuperUser
        ? ''
        : alreadyReceived > 0
          ? `<td><button type="button" class="btn btn-danger btn-sm" disabled title="Already received against - cannot be removed">Remove</button></td>`
          : `<td><button type="button" class="btn btn-danger btn-sm" data-remove-entry-no="${l.entry_no}" data-remove-item-code="${escapeHtml(l.item_code)}">Remove</button></td>`;
      return `
        <tr data-entry-no="${l.entry_no}">
          <td>${l.item_code || ''}</td>
          <td class="doc-cell-text" title="${escapeHtml(l.item_name || '')}">${escapeHtml(l.item_name || '')}</td>
          <td>${variantCell(l)}</td>
          <td>${descriptionCell(l)}</td>
          <td>${l.warehouse_name || ''}</td>
          <td class="doc-num">${qtyOrderedCell(l)}</td>
          <td>${uomCell(l)}</td>
          <td class="doc-num">${receiveInput}</td>
          <td class="doc-num">${unitCostCell(l)}</td>
          <td class="doc-num">${l.unit_cost === null || l.unit_cost === undefined ? '<span class="muted">-</span>' : Number(l.line_cost || 0).toFixed(2)}</td>
          ${removeCell}
        </tr>
      `;
    })
    .join('');
}

let currentReceiveVendorCode = null;
// This PO header's warehouse - what the Add Item toolbar defaults to, so a line added later lands
// in the same place as the rest of the order.
let currentReceiveWarehouseId = '';

async function openReceiveModal(poNo) {
  currentReceivePoNo = poNo;
  currentReceiveVendorCode = null;
  currentReceiveWarehouseId = '';
  document.getElementById('receiveModalTitle').textContent = `Purchase Order ${poNo}`;
  document.getElementById('receiveModalError').classList.add('hidden');
  document.getElementById('receivePrintLink').href = `purchase-order-print.html?po=${encodeURIComponent(poNo)}`;
  const body = document.getElementById('receiveLinesBody');
  body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="muted">Loading...</td></tr>`;
  document.getElementById('receiveModal').classList.remove('hidden');

  // Restore the layout this browser last used, before the panel is seen.
  applyReceiveMaximized(readStoredFlag(PO_MAXIMIZED_KEY, false));
  document.getElementById('receiveGeneralTab').open = readStoredFlag(PO_GENERAL_TAB_KEY, true);

  document.getElementById('poEditSection').classList.toggle('hidden', !currentSession?.isSuperUser);
  resetPoAddItemFields();

  const [{ data: headerRows, error: headerError }, { data: lineRows, error: lineError }] = await Promise.all([
    supabaseClient.rpc('staff_get_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    }),
    supabaseClient.rpc('staff_list_purchase_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    })
  ]);

  if (headerError || !headerRows || headerRows.length === 0) {
    body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="error-text">${headerError?.message || 'Purchase Order not found.'}</td></tr>`;
    return;
  }

  const header = headerRows[0];
  currentReceiveVendorCode = header.vendor_code || null;
  currentReceiveWarehouseId = header.warehouse_id || '';
  const vendorLabel = header.vendor_name || header.vendor_code || '';
  document.getElementById('receiveVendor').textContent = vendorLabel;
  // Blank on orders raised before the header carried one, and on any whose lines span several -
  // the Warehouse column on the lines below still says where each item goes.
  document.getElementById('receiveWarehouse').textContent = header.warehouse_name || '-';
  document.getElementById('receiveOrderDate').textContent = formatDate(header.order_date);
  document.getElementById('receiveNotes').textContent = header.notes || '-';

  // An item added to this order belongs to the same warehouse as the order itself unless someone
  // says otherwise - the toolbar was reset before the header arrived, so the default is applied
  // here rather than in resetPoAddItemFields.
  applyPoAddDefaultWarehouse();

  // Shown on the General tab only while it is collapsed, so folding the tab away never costs you
  // the fields you most need while working the lines.
  document.getElementById('receiveGeneralSummary').textContent =
    [vendorLabel, header.warehouse_name, formatDate(header.order_date)].filter(Boolean).join(' · ');

  if (lineError) {
    body.innerHTML = `<tr><td colspan="${receiveLinesColspan()}" class="error-text">${lineError.message}</td></tr>`;
    return;
  }

  await renderReceiveLines(lineRows || []);
  await loadPancakeSyncStatus(poNo);
}

// Pancake Sync panel - one row per Receive action's Pancake purchase attempt (grouped by
// Warehouse - see staff_receive_purchase_order_lines in supabase_purchase_order_pancake_sync.sql).
// Hidden entirely if this PO has never been received against.
function pancakeSyncBadgeClass(status) {
  switch (status) {
    case 'Synced': return 'badge-success';
    case 'Failed': return 'badge-danger';
    case 'Rejected': return 'badge-danger';
    default: return 'badge-neutral';
  }
}

async function loadPancakeSyncStatus(poNo) {
  const section = document.getElementById('pancakeSyncSection');
  const body = document.getElementById('pancakeSyncBody');

  const { data, error } = await supabaseClient.rpc('staff_list_purchase_order_pancake_purchases', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_po_no: poNo
  });

  if (error || !data || data.length === 0) {
    section.classList.add('hidden');
    return;
  }

  section.classList.remove('hidden');
  body.innerHTML = data
    .map((row) => `
      <tr>
        <td>${row.received_at_utc ? new Date(row.received_at_utc).toLocaleString() : ''}</td>
        <td>${row.warehouse_name || row.warehouse_id || ''}</td>
        <td>${escapeHtml(row.pancake_purchase_id) || '-'}</td>
        <td><span class="badge ${pancakeSyncBadgeClass(row.sync_status)}">${escapeHtml(row.sync_status)}</span></td>
        <td class="muted" title="${escapeHtml(row.sync_error)}">${escapeHtml(row.sync_error)}</td>
      </tr>
    `)
    .join('');
}

async function receivePurchaseOrderQuantities() {
  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const rows = Array.from(document.getElementById('receiveLinesBody').querySelectorAll('tr[data-entry-no]'));
  const lines = rows
    .map((row) => {
      const input = row.querySelector('.receive-qty-input');
      const quantity = input ? parseFloat(input.value) || 0 : 0;
      return { entry_no: Number(row.dataset.entryNo), quantity };
    })
    .filter((l) => l.quantity > 0);

  if (lines.length === 0) {
    errorEl.textContent = 'Enter a Qty Received for at least one line first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('receiveQtyBtn');
  btn.disabled = true;
  try {
    // Each call syncs to Pancake per warehouse before updating anything locally - a row here can
    // come back 'Failed'/'Rejected' without the overall RPC call itself erroring, so a successful
    // call must still be checked for per-warehouse failures (see
    // staff_receive_purchase_order_lines's header comment for why those aren't auto-retried).
    const { data, error } = await supabaseClient.rpc('staff_receive_purchase_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: currentReceivePoNo,
      p_lines: lines
    });
    if (error) throw error;

    const failed = (data || []).filter((r) => r.sync_status !== 'Synced');
    if (failed.length > 0) {
      const details = failed
        .map((r) => `${r.warehouse_name || r.warehouse_id} - ${r.sync_error || r.sync_status}`)
        .join('; ');
      errorEl.textContent = `Some warehouse(s) failed to sync to Pancake and were NOT received: ${details}`;
      errorEl.classList.remove('hidden');
    }

    await openReceiveModal(currentReceivePoNo);
    await loadPurchaseOrders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to receive Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

async function postPurchaseOrder() {
  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const rows = Array.from(document.getElementById('receiveLinesBody').querySelectorAll('tr[data-entry-no]'));
  const anyUnreceived = rows.some((row) => {
    const input = row.querySelector('.receive-qty-input');
    return !!input; // an input only renders while a line still has a remaining balance
  });

  const confirmMessage = anyUnreceived
    ? `Purchase Order ${currentReceivePoNo} still has unreceived quantity. Post it to Posted Purchase Orders anyway?`
    : `Post Purchase Order ${currentReceivePoNo} to Posted Purchase Orders? This cannot be undone.`;
  if (!window.confirm(confirmMessage)) return;

  const btn = document.getElementById('postPoBtn');
  btn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('staff_post_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: currentReceivePoNo
    });
    if (error) throw error;

    document.getElementById('receiveModal').classList.add('hidden');
    await loadPurchaseOrders();
    window.alert(`Purchase Order ${currentReceivePoNo} has been posted.`);
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to post Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

// Add/remove lines on an existing Purchase Order - super users only (currentSession.isSuperUser
// gates the UI; staff_add_purchase_order_line/staff_remove_purchase_order_line re-check server-
// side, see supabase_purchase_order_edit_lines.sql). Item search reuses the same vendor-scoped
// staff_search_items pattern as the New Purchase Order modal, scoped to the PO's own vendor
// (currentReceiveVendorCode, set in openReceiveModal) rather than a picker of its own.
let poAddItemSelectedCode = '';
let poAddItemSelectedName = '';
let poAddVariantSelectedCode = '';
let poAddVariantSelectedName = '';
// Catalog description of the picked item, and the picked variant's own name - the two halves
// composeLineDescription needs so this toolbar prefills its Description exactly the way a New
// Purchase Order line does. poAddDescriptionAuto tracks whether the box is still following the
// catalog or has been typed over.
let poAddItemSelectedDescription = '';
let poAddVariantSelectedDescription = '';
let poAddVariantSelectedId = '';
let poAddDescriptionAuto = true;

// The conversion in force on the Add Item toolbar, mirroring a New PO row's row.dataset.qtyPer.
let poAddQtyPer = 1;

// Fills the toolbar's unit picker from the item just chosen and restates the prefilled cost in
// that unit - the same defaulting a New Purchase Order line does, so a line added to an existing
// order is entered the same way as one it was created with.
async function loadPoAddItemUnits(itemCode) {
  const select = document.getElementById('poAddItemUom');
  if (!select) return;

  const { data, error } = await supabaseClient.rpc('staff_list_item_units_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: itemCode
  });

  // The toolbar may have moved on to another item while this was in flight.
  if (poAddItemSelectedCode !== itemCode) return;

  if (error) {
    console.error('staff_list_item_units_of_measure failed:', error);
    return;
  }

  const units = data || [];
  select.innerHTML = units
    .map((u) => `<option value="${escapeHtml(u.unit_of_measure_code)}" data-qty-per="${Number(u.qty_per_unit_of_measure)}">${escapeHtml(u.unit_of_measure_code)}</option>`)
    .join('');

  const preferred = units.find((u) => u.is_purch) || units.find((u) => u.is_base) || units[0];
  if (preferred) {
    select.value = preferred.unit_of_measure_code;
    setPoAddQtyPer(Number(preferred.qty_per_unit_of_measure) || 1);
  }
}

// Same cost carry-across as setNewPoLineQtyPer - the displayed price is per unit, so it moves with
// the unit rather than staying a piece price labelled as a box price.
function setPoAddQtyPer(nextQtyPer) {
  const costInput = document.getElementById('poAddItemCost');
  const raw = costInput ? costInput.value.trim() : '';
  const previous = poAddQtyPer || 1;

  poAddQtyPer = nextQtyPer;

  if (costInput && raw !== '') {
    costInput.value = Number(((Number(raw) / previous) * nextQtyPer).toFixed(4));
  }
}

// What the Description WOULD be from the catalog for the current item/variant selection.
function poAddCatalogDescription() {
  return composeLineDescription(poAddItemSelectedDescription, poAddItemSelectedName, poAddVariantSelectedDescription);
}

function refreshPoAddDescription() {
  if (!poAddDescriptionAuto) return;
  const input = document.getElementById('poAddDescriptionInput');
  if (input) input.value = poAddCatalogDescription();
}

// The PO's own warehouse first, then the user's designated one for an older order that has none -
// either way the toolbar opens on a sensible warehouse instead of "No warehouse".
function applyPoAddDefaultWarehouse() {
  const select = document.getElementById('poAddItemWarehouse');
  if (!select) return;
  select.value = currentReceiveWarehouseId || sessionDefaultWarehouseId(select);
}

function resetPoAddItemFields() {
  poAddItemSelectedCode = '';
  poAddItemSelectedName = '';
  poAddVariantSelectedCode = '';
  poAddVariantSelectedName = '';
  poAddItemSelectedDescription = '';
  poAddVariantSelectedDescription = '';
  poAddVariantSelectedId = '';
  poAddDescriptionAuto = true;
  const input = document.getElementById('poAddItemInput');
  if (input) input.value = '';
  const dropdown = document.getElementById('poAddItemDropdown');
  if (dropdown) { dropdown.classList.add('hidden'); dropdown.innerHTML = ''; }
  const variantInput = document.getElementById('poAddVariantInput');
  if (variantInput) variantInput.value = '';
  const variantDropdown = document.getElementById('poAddVariantDropdown');
  if (variantDropdown) { variantDropdown.classList.add('hidden'); variantDropdown.innerHTML = ''; }
  const descriptionInput = document.getElementById('poAddDescriptionInput');
  if (descriptionInput) descriptionInput.value = '';
  const warehouseSelect = document.getElementById('poAddItemWarehouse');
  if (warehouseSelect) {
    warehouseSelect.innerHTML = newPoWarehouseOptionsHtml;
    applyPoAddDefaultWarehouse();
  }
  const qtyInput = document.getElementById('poAddItemQty');
  if (qtyInput) qtyInput.value = '1';
  // No item picked yet, so there is nothing to convert - the unit picker fills on selection.
  poAddQtyPer = 1;
  const uomSelect = document.getElementById('poAddItemUom');
  if (uomSelect) uomSelect.innerHTML = '';
  // Cleared, not defaulted - blank means "fall back to the item's catalog cost".
  const costInput = document.getElementById('poAddItemCost');
  if (costInput) costInput.value = '';
}

async function searchItemsForAddToPo(searchText) {
  const dropdown = document.getElementById('poAddItemDropdown');

  if (!currentReceiveVendorCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">This Purchase Order has no vendor set.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: searchText || null,
    p_limit: 20,
    p_vendor_code: currentReceiveVendorCode
  });

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${describeSupabaseError(error, 'Search failed.')}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const items = data || [];
  if (items.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No items found for this vendor.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = items
    .map((it) => `
      <div class="item-suggest-option" data-code="${encodeURIComponent(it.code)}" data-name="${encodeURIComponent(it.name || '')}" data-cost="${it.cost === null || it.cost === undefined ? '' : it.cost}" data-description="${encodeURIComponent(it.description || '')}">
        <span class="item-suggest-code">${escapeHtml(it.code)}</span><span class="item-suggest-name">${escapeHtml(it.name || '')}</span>
      </div>
    `)
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      poAddItemSelectedCode = decodeURIComponent(opt.dataset.code);
      poAddItemSelectedName = decodeURIComponent(opt.dataset.name);
      poAddItemSelectedDescription = decodeURIComponent(opt.dataset.description || '');
      document.getElementById('poAddItemInput').value = poAddItemSelectedCode;

      // Same catalog-cost prefill the New PO rows get; blank stays blank for an uncosted item.
      // It arrives as a BASE unit cost, so the toolbar goes back to a 1:1 conversion before
      // loadPoAddItemUnits restates it in whatever unit this item is bought in.
      poAddQtyPer = 1;
      const costInput = document.getElementById('poAddItemCost');
      if (costInput) costInput.value = opt.dataset.cost || '';
      loadPoAddItemUnits(poAddItemSelectedCode);
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';

      // A different item invalidates any variant already picked for the previous item.
      poAddVariantSelectedCode = '';
      poAddVariantSelectedName = '';
      poAddVariantSelectedDescription = '';
      poAddVariantSelectedId = '';
      const variantInput = document.getElementById('poAddVariantInput');
      if (variantInput) variantInput.value = '';

      refreshPoAddDescription();
    });
  });
}

async function searchVariantsForAddToPo(searchText) {
  const dropdown = document.getElementById('poAddVariantDropdown');

  if (!poAddItemSelectedCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">Select an Item first.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: poAddItemSelectedCode,
    p_search: searchText || null,
    p_limit: 20
  });

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${describeSupabaseError(error, 'Search failed.')}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const variants = data || [];
  if (variants.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">This item has no variants.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = variants
    .map((v) => {
      const code = v.item_code || v.main_item_code || '';
      const label = variantDisplayName(v.sku, v.variant_name) || v.variation_id;
      const combinedName = `${poAddItemSelectedName || v.item_name || ''} - ${label}`;
      // The variant's own descriptive text, kept apart from data-name ("Item - Variant") for the
      // same reason as in the New PO grid - see the note there.
      const variantDescription = label;
      return `
        <div class="item-suggest-option" data-code="${encodeURIComponent(code)}" data-name="${encodeURIComponent(combinedName)}" data-label="${encodeURIComponent(label)}" data-variant-name="${encodeURIComponent(variantDescription)}" data-variation-id="${encodeURIComponent(v.variation_id || '')}">
          <span class="item-suggest-code">${escapeHtml(v.sku || v.variation_id || '')}</span><span class="item-suggest-name">${escapeHtml(v.variant_name || '')}</span>
        </div>
      `;
    })
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      poAddVariantSelectedCode = decodeURIComponent(opt.dataset.code);
      poAddVariantSelectedName = decodeURIComponent(opt.dataset.name);
      poAddVariantSelectedDescription = decodeURIComponent(opt.dataset.variantName || '');
      // The variation id itself - stored on the line so the Variant column can show and change it.
      poAddVariantSelectedId = decodeURIComponent(opt.dataset.variationId || '');
      document.getElementById('poAddVariantInput').value = decodeURIComponent(opt.dataset.label);
      refreshPoAddDescription();
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
}

async function addItemToExistingPurchaseOrder() {
  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  // Typed in the line's own unit; the server multiplies by p_qty_per_uom for the base quantity.
  const quantity = parseFloat(document.getElementById('poAddItemQty').value) || 0;
  if (!poAddItemSelectedCode || quantity <= 0) {
    errorEl.textContent = 'Pick an item (from the suggestions) and a Quantity greater than 0 first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const warehouseSelect = document.getElementById('poAddItemWarehouse');
  const warehouseOption = warehouseSelect.selectedOptions[0];

  const btn = document.getElementById('poAddItemBtn');
  btn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('staff_add_purchase_order_line', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: currentReceivePoNo,
      p_item_code: poAddVariantSelectedCode || poAddItemSelectedCode,
      p_item_name: poAddVariantSelectedName || poAddItemSelectedName,
      p_warehouse_id: warehouseSelect.value || null,
      p_warehouse_name: warehouseSelect.value ? warehouseOption.dataset.name : null,
      p_quantity: quantity * poAddQtyPer,
      p_quantity_uom: quantity,
      p_qty_per_uom: poAddQtyPer,
      p_uom_code: document.getElementById('poAddItemUom').value || null,
      p_variant_code: poAddVariantSelectedId || null,
      p_variant_name: poAddVariantSelectedDescription || null,
      // Blank falls back to the catalog description, same rule as a New Purchase Order line.
      p_description: (document.getElementById('poAddDescriptionInput').value.trim() || poAddCatalogDescription()) || null,
      // Blank means "use the item's catalog cost" server-side, so it is sent as null, not 0.
      // Typed per the line's unit, stored per BASE unit - same division as a New PO line.
      p_unit_cost: document.getElementById('poAddItemCost').value.trim() === ''
        ? null
        : Number(document.getElementById('poAddItemCost').value) / poAddQtyPer
    });
    if (error) throw error;

    await openReceiveModal(currentReceivePoNo);
    await loadPurchaseOrders();
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to add item to Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

async function removePurchaseOrderLine(entryNo, itemCode) {
  if (!window.confirm(`Remove ${itemCode} from this Purchase Order?`)) return;

  const errorEl = document.getElementById('receiveModalError');
  errorEl.classList.add('hidden');

  const { error } = await supabaseClient.rpc('staff_remove_purchase_order_line', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_entry_no: entryNo
  });

  if (error) {
    errorEl.textContent = describeSupabaseError(error, 'Failed to remove item.');
    errorEl.classList.remove('hidden');
    return;
  }

  await openReceiveModal(currentReceivePoNo);
  await loadPurchaseOrders();
}

// New Purchase Order modal - manual entry, independent of Stock On Hand's cache (so an item
// missing a warehouse row there - see supabase_stock_on_hand_missing_warehouse_diagnostic.sql -
// can still be ordered directly). Calls the same staff_create_purchase_order RPC Stock On Hand's
// own "Create Purchase Order" button uses (supabase_purchase_orders.sql) - no new backend needed.
let newPoWarehouseOptionsHtml = '<option value="">No warehouse</option>';

async function loadNewPoVendorOptions() {
  const select = document.getElementById('newPoVendor');
  const { data, error } = await supabaseClient.rpc('staff_search_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;

  select.innerHTML = '<option value="">Select a vendor...</option>' +
    data.map((v) => `<option value="${escapeHtml(v.vendor_code)}">${escapeHtml(v.name)}</option>`).join('');
}

async function loadNewPoWarehouseOptionsHtml() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_limit: 100
  });
  if (error || !data) return;

  newPoWarehouseOptionsHtml = '<option value="">No warehouse</option>' +
    data.map((w) => `<option value="${escapeHtml(w.id)}" data-name="${escapeHtml(w.name)}">${escapeHtml(w.name)}</option>`).join('');
}

// Per "if user doing PO can you default the warehouse into their designated warehouse" - the
// warehouse a user is assigned to in User Setup (StaffUsers."WarehouseName", carried on the
// session by auth.js). The session only ever carries the NAME, so it is matched to an option by
// name, trimmed and case-insensitively - the same match Online Orders and Serial Tracker already
// use to scope a user to their own warehouse. Returns '' when the user has no warehouse assigned
// (super users typically don't) or when the name matches nothing, which leaves the picker on
// "No warehouse" rather than guessing at one.
function sessionDefaultWarehouseId(select) {
  const wanted = (currentSession?.warehouseName || '').trim().toLowerCase();
  if (!wanted || !select) return '';

  const match = Array.from(select.options)
    .find((o) => o.value && (o.dataset.name || '').trim().toLowerCase() === wanted);
  return match ? match.value : '';
}

function newPoHeaderWarehouseId() {
  return document.getElementById('newPoWarehouse')?.value || '';
}

function newPoHeaderWarehouseName() {
  const select = document.getElementById('newPoWarehouse');
  return select?.value ? (select.selectedOptions[0].dataset.name || null) : null;
}

// Re-points every line that is still following the header. A line whose warehouse was set by hand
// keeps it - switching the header must not silently redirect a line someone deliberately sent
// somewhere else.
function applyHeaderWarehouseToNewPoLines() {
  const headerId = newPoHeaderWarehouseId();
  document.querySelectorAll('#newPoLinesBody tr').forEach((row) => {
    if (row.dataset.warehouseAuto === '0') return;
    const select = row.querySelector('.new-po-line-warehouse');
    if (select) select.value = headerId;
  });
}

// Per "can you validate the description base on the actual description of the item / variant" -
// a line's Description is free text, but it should START as the catalog's own description of what
// was picked rather than as an empty box someone retypes (or leaves blank) on every line.
//
// Source of truth: Items."Description" (what Item Setup edits, returned by staff_search_items as
// of supabase_po_line_description_from_catalog.sql), falling back to the item Name for a catalog
// row that has no description filled in. Variants carry no description column of their own -
// Variants."VariantName" IS the variant's description - so a picked variant is appended to the
// item's, unless the variant name already spells the item out ("A-029 - RUBBER-MATTING (6MM)"),
// in which case repeating it would only produce a stutter.
function composeLineDescription(itemDescription, itemName, variantName) {
  const base = (itemDescription || '').trim() || (itemName || '').trim();
  const variant = (variantName || '').trim();

  if (!variant) return base;
  if (!base) return variant;
  if (variant.toLowerCase().includes(base.toLowerCase())) return variant;
  return `${base} - ${variant}`;
}

// What this row's Description WOULD be from the catalog, whether or not the box currently shows
// it - used both to prefill the box and, in createNewPurchaseOrder, to fill in a line whose
// Description was deleted rather than replaced.
function newPoLineCatalogDescription(row) {
  return composeLineDescription(row.dataset.itemDescription, row.dataset.itemName, row.dataset.variantDescription);
}

// Rewrites the Description box from the catalog, but only while it is still "auto" - once someone
// types their own wording, changing the item must not throw it away. Clearing the box puts the
// row back into auto (see the input handler in addNewPoLineRow), which is how you ask for the
// catalog text back.
function refreshNewPoLineDescription(row) {
  if (row.dataset.descriptionAuto === '0') return;

  const input = row.querySelector('.new-po-line-description');
  if (input) input.value = newPoLineCatalogDescription(row);
}

// Units of Measure (supabase_units_of_measure.sql) - a line is ordered in one of the item's units
// and its Quantity and Unit Cost are both PER that unit, exactly as BC's document lines work. What
// gets stored is the base quantity (quantity x qty-per) and the base unit cost, because that is
// what stock, costing and the GL downstream all count in - see the header of that migration.
//
// row.dataset.qtyPer is the conversion currently in force on the row; '1' until an item with a
// non-base buying unit is picked.
function newPoLineQtyPer(row) {
  return Number(row.dataset.qtyPer || 1) || 1;
}

// "= 60 PCS" under the unit picker, so what actually lands in stock is never a mental calculation.
// Hidden when the line is in its base unit and the two numbers are the same.
function refreshNewPoLineBaseQty(row) {
  const hint = row.querySelector('.new-po-line-base-qty');
  if (!hint) return;

  const qtyPer = newPoLineQtyPer(row);
  const qty = parseFloat(row.querySelector('.new-po-line-qty')?.value) || 0;

  hint.textContent = qtyPer === 1
    ? ''
    : `= ${(qty * qtyPer).toLocaleString()} ${row.dataset.baseUom || ''}`.trim();
}

// Loads the item's units, defaults the picker to its purchase unit (BC's Purch. Unit of Measure),
// and restates the Unit Cost in that unit. Called on every item pick; an item with nothing but its
// base unit ends up with a single-entry picker, which is the common case.
async function applyNewPoLineUnits(row, itemCode) {
  const select = row.querySelector('.new-po-line-uom');

  const { data, error } = await supabaseClient.rpc('staff_list_item_units_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: itemCode
  });

  // The row may have moved on to a different item while this was in flight.
  if (row.dataset.itemCode !== itemCode) return;

  if (error) {
    console.error('staff_list_item_units_of_measure failed:', error);
    return;
  }

  const units = data || [];
  select.innerHTML = units
    .map((u) => `<option value="${escapeHtml(u.unit_of_measure_code)}" data-qty-per="${Number(u.qty_per_unit_of_measure)}">${escapeHtml(u.unit_of_measure_code)}</option>`)
    .join('');

  row.dataset.baseUom = units.find((u) => u.is_base)?.unit_of_measure_code || '';

  const preferred = units.find((u) => u.is_purch) || units.find((u) => u.is_base) || units[0];
  if (preferred) {
    select.value = preferred.unit_of_measure_code;
    setNewPoLineQtyPer(row, Number(preferred.qty_per_unit_of_measure) || 1);
  }
}

// Re-bases the row on a new conversion, carrying the Unit Cost across with it: the cost shown is
// per unit, so switching PCS -> BOX(12) turns 40 into 480 rather than leaving a piece price
// labelled as a box price. Going through the base cost means a hand-typed price converts the same
// way as a prefilled one.
function setNewPoLineQtyPer(row, nextQtyPer) {
  const previous = newPoLineQtyPer(row);
  const costInput = row.querySelector('.new-po-line-cost');
  const raw = costInput ? costInput.value.trim() : '';

  row.dataset.qtyPer = String(nextQtyPer);

  if (costInput && raw !== '') {
    const baseCost = Number(raw) / previous;
    // 4dp matches Items."Cost" - the extra places matter on a per-piece price inside a big box.
    costInput.value = Number((baseCost * nextQtyPer).toFixed(4));
  }

  refreshNewPoCostTotals();
}

function applyNewPoItemSelection(row, code, name, cost, description) {
  row.querySelector('.new-po-line-item').value = code;
  row.dataset.itemCode = code;
  row.dataset.itemName = name || '';
  row.dataset.itemDescription = description || '';

  // Prefill from the item's catalog cost - this is the "auto compute cost on what we are
  // ordering" part. Left blank for an uncosted item rather than filled with 0, so a missing cost
  // stays visibly missing instead of quietly totalling as free. Still editable: the vendor may
  // quote something different, and what is typed here is what gets snapshot onto the line.
  // staff_search_items returns a BASE unit cost, so the row is put back on a 1:1 conversion before
  // it lands - applyNewPoLineUnits then restates it in whichever unit this item is bought in.
  row.dataset.qtyPer = '1';
  const costInput = row.querySelector('.new-po-line-cost');
  if (costInput) {
    costInput.value = cost === null || cost === undefined || cost === '' ? '' : Number(cost);
  }

  // A different item invalidates any variant already picked for the previous item.
  clearNewPoVariantSelection(row);
  refreshNewPoLineDescription(row);
  refreshNewPoCostTotals();
  applyNewPoLineUnits(row, code);
}

function clearNewPoVariantSelection(row) {
  row.dataset.variantCode = '';
  row.dataset.variantName = '';
  row.dataset.variantDescription = '';
  row.dataset.variantId = '';
  row.dataset.variantLabel = '';
  const variantInput = row.querySelector('.new-po-line-variant');
  if (variantInput) variantInput.value = '';
}

async function searchItemsForNewPoRow(row, searchText) {
  const dropdown = row.querySelector('.item-suggest-dropdown');

  // Mirrors Transfer Orders' own "Select a From Warehouse first" gate (transferOrders.js) - a
  // Purchase Order belongs to one vendor, so items are scoped to that vendor's own catalog
  // (Items."VendorCode") rather than showing the whole item list before a vendor is even picked.
  const vendorCode = document.getElementById('newPoVendor').value;
  if (!vendorCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">Select a Vendor first.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: searchText || null,
    p_limit: 20,
    p_vendor_code: vendorCode
  });

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${describeSupabaseError(error, 'Search failed.')}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const items = data || [];
  if (items.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No items found for this vendor.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = items
    .map((it) => `
      <div class="item-suggest-option" data-code="${encodeURIComponent(it.code)}" data-name="${encodeURIComponent(it.name || '')}" data-cost="${it.cost === null || it.cost === undefined ? '' : it.cost}" data-description="${encodeURIComponent(it.description || '')}">
        <span class="item-suggest-code">${escapeHtml(it.code)}</span><span class="item-suggest-name">${escapeHtml(it.name || '')}</span>
      </div>
    `)
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      applyNewPoItemSelection(
        row,
        decodeURIComponent(opt.dataset.code),
        decodeURIComponent(opt.dataset.name),
        opt.dataset.cost,
        decodeURIComponent(opt.dataset.description || '')
      );
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
}

// Variant lookup for a New PO row - scoped to whichever Item that row already has selected
// (row.dataset.itemCode), same staff_search_variants RPC Transfer Orders' own variant field uses
// (transferOrders.js). Picking a variant here overrides that line's effective order code/name
// (see createNewPurchaseOrder) without disturbing the Item field's own display value, so switching
// variants back and forth never requires re-picking the Item.
async function searchVariantsForNewPoRow(row, searchText) {
  const dropdown = row.querySelector('.variant-suggest-dropdown');

  if (!row.dataset.itemCode) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">Select an Item first.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('staff_search_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: row.dataset.itemCode,
    p_search: searchText || null,
    p_limit: 20
  });

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${describeSupabaseError(error, 'Search failed.')}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const variants = data || [];
  if (variants.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">This item has no variants.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = variants
    .map((v) => {
      const code = v.item_code || v.main_item_code || '';
      const label = variantDisplayName(v.sku, v.variant_name) || v.variation_id;
      const combinedName = `${row.dataset.itemName || v.item_name || ''} - ${label}`;
      // data-variant-name is the variant's own descriptive text, kept separate from data-name
      // (which is already "Item - Variant" and is what gets stored as the line's ItemName) so the
      // Description can be composed without the item name landing in it twice.
      const variantDescription = label;
      return `
        <div class="item-suggest-option" data-code="${encodeURIComponent(code)}" data-name="${encodeURIComponent(combinedName)}" data-label="${encodeURIComponent(label)}" data-variant-name="${encodeURIComponent(variantDescription)}" data-variation-id="${encodeURIComponent(v.variation_id || '')}">
          <span class="item-suggest-code">${escapeHtml(v.sku || v.variation_id || '')}</span><span class="item-suggest-name">${escapeHtml(v.variant_name || '')}</span>
        </div>
      `;
    })
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      row.dataset.variantCode = decodeURIComponent(opt.dataset.code);
      row.dataset.variantName = decodeURIComponent(opt.dataset.name);
      row.dataset.variantDescription = decodeURIComponent(opt.dataset.variantName || '');
      // The variation id itself - what the line stores as its VariantCode, distinct from
      // variantCode above, which is the ITEM code the variant resolves to.
      row.dataset.variantId = decodeURIComponent(opt.dataset.variationId || '');
      row.dataset.variantLabel = decodeURIComponent(opt.dataset.variantName || '');
      row.querySelector('.new-po-line-variant').value = decodeURIComponent(opt.dataset.label);
      refreshNewPoLineDescription(row);
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
    });
  });
}

// Recomputes every line's cost and the PO total. Costs are shown to 2dp even though Items."Cost"
// is numeric(18,4) - the extra places matter for per-unit accuracy on cheap parts, but a PO total
// is money and reads as money.
//
// A line with no unit cost contributes 0 rather than blocking: not every item is costed yet, and
// a partially-costed PO is still worth raising. The blank cell says as much.
function refreshNewPoCostTotals() {
  let total = 0;

  document.querySelectorAll('#newPoLinesBody tr').forEach((row) => {
    const quantity = parseFloat(row.querySelector('.new-po-line-qty')?.value) || 0;
    const costInput = row.querySelector('.new-po-line-cost');
    const rawCost = costInput ? costInput.value.trim() : '';
    const totalCell = row.querySelector('.new-po-line-total');

    // Quantity and Unit Cost are both per the line's unit, so their product is the line total
    // whatever the unit is - the conversion cancels out and only shows up in the base-qty hint.
    refreshNewPoLineBaseQty(row);

    if (rawCost === '') {
      if (totalCell) totalCell.innerHTML = '<span class="muted">-</span>';
      return;
    }

    const lineCost = (parseFloat(rawCost) || 0) * quantity;
    total += lineCost;
    if (totalCell) totalCell.textContent = lineCost.toFixed(2);
  });

  const totalEl = document.getElementById('newPoTotalCost');
  if (totalEl) totalEl.textContent = total.toFixed(2);
}

// BC numbers every document line, so the row you are on can be named ("line 3") rather than
// pointed at. Positional, not stored - re-run whenever a row is added or removed.
function renumberNewPoLines() {
  document.querySelectorAll('#newPoLinesBody tr').forEach((row, i) => {
    const cell = row.querySelector('.doc-line-no');
    if (cell) cell.textContent = i + 1;
  });
}

function addNewPoLineRow() {
  const tbody = document.getElementById('newPoLinesBody');
  const row = document.createElement('tr');
  // Widths live in the table's colgroup (purchase-orders.html) rather than on each input, so the
  // header, the rows and the totals all line up on one set of column widths.
  row.innerHTML = `
    <td class="doc-line-no"></td>
    <td class="item-search-cell">
      <input type="text" class="new-po-line-item" placeholder="Search item code or name..." autocomplete="off" />
      <div class="item-suggest-dropdown hidden"></div>
    </td>
    <td class="item-search-cell">
      <input type="text" class="new-po-line-variant" placeholder="Select an item first..." autocomplete="off" />
      <div class="variant-suggest-dropdown hidden"></div>
    </td>
    <td><input type="text" class="new-po-line-description" placeholder="From the item" title="Filled in from the item's catalog description - type over it to word this line differently, or clear it to get the catalog text back." /></td>
    <td><select class="new-po-line-warehouse">${newPoWarehouseOptionsHtml}</select></td>
    <td><input type="number" class="new-po-line-qty" min="0" step="0.01" value="1" /></td>
    <td>
      <select class="new-po-line-uom" title="The unit this line is ordered in - Quantity and Unit Cost are both per one of these"></select>
      <div class="new-po-line-base-qty muted"></div>
    </td>
    <td><input type="number" class="new-po-line-cost" min="0" step="0.01" placeholder="-" /></td>
    <td class="new-po-line-total doc-num">0.00</td>
    <td><button type="button" class="btn btn-danger btn-sm" title="Remove this line">Remove</button></td>
  `;
  row.querySelector('button.btn-danger').addEventListener('click', () => {
    row.remove();
    renumberNewPoLines();
    refreshNewPoCostTotals();
  });

  // A new line starts on the header's warehouse (which itself starts on the user's own), and
  // stays tied to it until someone points this line somewhere else. Setting it back to the
  // header's value re-ties it, so a mis-click is undone by simply re-picking.
  const lineWarehouseSelect = row.querySelector('.new-po-line-warehouse');
  lineWarehouseSelect.value = newPoHeaderWarehouseId();
  row.dataset.warehouseAuto = '1';
  lineWarehouseSelect.addEventListener('change', () => {
    row.dataset.warehouseAuto = lineWarehouseSelect.value === newPoHeaderWarehouseId() ? '1' : '0';
  });

  // Until an item is picked there is nothing to convert, so the line sits on its base unit at 1:1.
  row.dataset.qtyPer = '1';
  const uomSelect = row.querySelector('.new-po-line-uom');
  uomSelect.addEventListener('change', () => {
    const option = uomSelect.selectedOptions[0];
    setNewPoLineQtyPer(row, Number(option?.dataset.qtyPer) || 1);
  });

  row.querySelector('.new-po-line-qty').addEventListener('input', refreshNewPoCostTotals);
  row.querySelector('.new-po-line-cost').addEventListener('input', refreshNewPoCostTotals);

  // A row starts out following the catalog. Typing your own wording detaches it (so re-picking
  // the item or a variant no longer overwrites what you wrote); emptying the box re-attaches it,
  // which is the "give me the real description back" gesture.
  row.dataset.descriptionAuto = '1';
  const descriptionInput = row.querySelector('.new-po-line-description');
  descriptionInput.addEventListener('input', () => {
    row.dataset.descriptionAuto = descriptionInput.value.trim() === '' ? '1' : '0';
  });

  const itemInput = row.querySelector('.new-po-line-item');
  let debounceHandle = null;
  itemInput.addEventListener('input', (e) => {
    row.dataset.itemCode = '';
    row.dataset.itemName = '';
    row.dataset.itemDescription = '';
    clearNewPoVariantSelection(row);
    refreshNewPoLineDescription(row);
    clearTimeout(debounceHandle);
    const value = e.target.value;
    debounceHandle = setTimeout(() => searchItemsForNewPoRow(row, value), 250);
  });
  itemInput.addEventListener('focus', () => searchItemsForNewPoRow(row, itemInput.value));
  itemInput.addEventListener('blur', () => {
    setTimeout(() => row.querySelector('.item-suggest-dropdown').classList.add('hidden'), 150);
  });

  const variantInput = row.querySelector('.new-po-line-variant');
  let variantDebounceHandle = null;
  variantInput.addEventListener('input', (e) => {
    row.dataset.variantCode = '';
    row.dataset.variantName = '';
    row.dataset.variantDescription = '';
    row.dataset.variantId = '';
    row.dataset.variantLabel = '';
    refreshNewPoLineDescription(row);
    clearTimeout(variantDebounceHandle);
    const value = e.target.value;
    variantDebounceHandle = setTimeout(() => searchVariantsForNewPoRow(row, value), 250);
  });
  variantInput.addEventListener('focus', () => searchVariantsForNewPoRow(row, variantInput.value));
  variantInput.addEventListener('blur', () => {
    setTimeout(() => row.querySelector('.variant-suggest-dropdown').classList.add('hidden'), 150);
  });

  tbody.appendChild(row);
  renumberNewPoLines();
}

function resetNewPoModal() {
  document.getElementById('newPoVendor').value = '';
  document.getElementById('newPoNotes').value = '';
  document.getElementById('newPoModalError').classList.add('hidden');

  // Filled before the lines are added, since each new line reads its warehouse from here.
  const warehouseSelect = document.getElementById('newPoWarehouse');
  warehouseSelect.innerHTML = newPoWarehouseOptionsHtml;
  warehouseSelect.value = sessionDefaultWarehouseId(warehouseSelect);

  document.getElementById('newPoLinesBody').innerHTML = '';
  addNewPoLineRow();
  addNewPoLineRow();
  refreshNewPoCostTotals();
  refreshNewPoGeneralSummary();
}

async function openNewPoModal() {
  resetNewPoModal();

  // Restore the layout this browser last used before the panel is seen, same as the Receive
  // document - someone who works maximized should not have to click Maximize on every order.
  // Unlike Receive, the default here is maximized: this is a nine-column entry grid with two
  // type-ahead pickers in it, and it was the cramped 900px card that prompted the change.
  applyNewPoMaximized(readStoredFlag(PO_NEW_MAXIMIZED_KEY, true));
  document.getElementById('newPoGeneralTab').open = readStoredFlag(PO_NEW_GENERAL_TAB_KEY, true);

  document.getElementById('newPoModal').classList.remove('hidden');
}

async function createNewPurchaseOrder() {
  const errorEl = document.getElementById('newPoModalError');
  errorEl.classList.add('hidden');

  const vendorCode = document.getElementById('newPoVendor').value;
  if (!vendorCode) {
    errorEl.textContent = 'Select a Vendor first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const rows = Array.from(document.getElementById('newPoLinesBody').querySelectorAll('tr'));
  const lines = rows
    .map((row) => {
      const warehouseSelect = row.querySelector('.new-po-line-warehouse');
      const warehouseOption = warehouseSelect.selectedOptions[0];
      // The quantity as typed, in the line's own unit. staff_create_purchase_order multiplies it
      // by qty_per_uom to get the base quantity it stores - the conversion has one home, and it
      // is not this file.
      const quantityUom = parseFloat(row.querySelector('.new-po-line-qty')?.value) || 0;
      const qtyPer = newPoLineQtyPer(row);
      // Blank is sent as null, NOT 0 - the server then falls back to the item's current catalog
      // cost, so a line left alone still costs itself. Sending 0 would instead assert "this is
      // free" and defeat that fallback.
      const rawCost = row.querySelector('.new-po-line-cost')?.value.trim() || '';
      return {
        item_code: row.dataset.variantCode || row.dataset.itemCode || '',
        item_name: row.dataset.variantName || row.dataset.itemName || '',
        // A Description left empty is filled from the catalog rather than saved as null - the
        // whole point of basing it on the item's real description is that a line is never
        // recorded without one. Anything typed here wins, exactly as entered.
        description: (row.querySelector('.new-po-line-description')?.value.trim() || newPoLineCatalogDescription(row)) || null,
        warehouse_id: warehouseSelect.value || null,
        warehouse_name: warehouseSelect.value ? warehouseOption.dataset.name : null,
        quantity_uom: quantityUom,
        qty_per_uom: qtyPer,
        uom_code: row.querySelector('.new-po-line-uom')?.value || null,
        // Which variant was picked, recorded in its own right rather than only as part of
        // item_name - that is what lets the Receive document show and change it later.
        variant_code: row.dataset.variantId || null,
        variant_name: row.dataset.variantLabel || null,
        // Typed per the line's unit, stored per BASE unit - Items."Cost", the per-vendor cost and
        // the GL all count in base units, so the division happens once, here, on the way in.
        unit_cost: rawCost === '' ? null : String(Number(rawCost) / qtyPer)
      };
    })
    .filter((l) => l.item_code && l.quantity_uom > 0);

  if (lines.length === 0) {
    errorEl.textContent = 'Pick an item (from the suggestions) and a Quantity greater than 0 for at least one line.';
    errorEl.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('createNewPoBtn');
  btn.disabled = true;
  try {
    const { data, error } = await supabaseClient.rpc('staff_create_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendor_code: vendorCode,
      p_notes: document.getElementById('newPoNotes').value.trim() || null,
      p_lines: lines,
      // Header warehouse - lines that named none inherit it server-side too
      // (supabase_purchase_order_header_warehouse.sql), so the two can never disagree.
      p_warehouse_id: newPoHeaderWarehouseId() || null,
      p_warehouse_name: newPoHeaderWarehouseName()
    });
    if (error) throw error;

    document.getElementById('newPoModal').classList.add('hidden');
    window.alert(`Purchase Order ${data} created.`);
    window.location.href = `purchase-order-print.html?po=${encodeURIComponent(data)}`;
  } catch (err) {
    errorEl.textContent = describeSupabaseError(err, 'Failed to create Purchase Order.');
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Purchase Orders');

  document.getElementById('poSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadPurchaseOrders();
    }, 300);
  });

  document.getElementById('poTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-delete-po]');
    if (!btn) return;
    deletePurchaseOrder(decodeURIComponent(btn.dataset.deletePo), Number(btn.dataset.receivedQty || 0));
  });

  document.getElementById('closeReceiveModalBtn').addEventListener('click', () =>
    document.getElementById('receiveModal').classList.add('hidden')
  );
  document.getElementById('receiveMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('receiveModal').classList.contains('modal-maximized');
    applyReceiveMaximized(nowMaximized);
    writeStoredFlag(PO_MAXIMIZED_KEY, nowMaximized);
  });

  document.getElementById('receiveGeneralTab').addEventListener('toggle', (e) => {
    writeStoredFlag(PO_GENERAL_TAB_KEY, e.target.open);
  });

  document.getElementById('receiveQtyBtn').addEventListener('click', receivePurchaseOrderQuantities);
  document.getElementById('postPoBtn').addEventListener('click', postPurchaseOrder);

  document.getElementById('receiveLinesBody').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-remove-entry-no]');
    if (!btn) return;
    removePurchaseOrderLine(Number(btn.dataset.removeEntryNo), btn.dataset.removeItemCode);
  });

  // A unit change is a committed choice the moment it is picked, so it saves on change rather
  // than waiting for focus to leave the way the typed fields below do.
  document.getElementById('receiveLinesBody').addEventListener('change', (e) => {
    const uomSelect = e.target.closest('select.line-uom-select');
    if (uomSelect) {
      savePurchaseOrderLineUom(uomSelect);
      return;
    }
    const variantSelect = e.target.closest('select.line-variant-select');
    if (variantSelect) savePurchaseOrderLineVariant(variantSelect);
  });

  // Delegated with capture because 'blur' does not bubble - the inputs are re-created on every
  // renderReceiveLines, so per-element listeners would be lost on each reload.
  document.getElementById('receiveLinesBody').addEventListener('focusout', (e) => {
    const costInput = e.target.closest('input.line-cost-input');
    if (costInput) {
      savePurchaseOrderLineCost(costInput);
      return;
    }
    const descriptionInput = e.target.closest('input.line-description-input');
    if (descriptionInput) {
      savePurchaseOrderLineDescription(descriptionInput);
      return;
    }
    const qtyInput = e.target.closest('input.line-qty-input');
    if (qtyInput) savePurchaseOrderLineQuantity(qtyInput);
  });

  // Enter commits the cell the way it would in a spreadsheet - blur() rather than saving directly,
  // so the save still goes through the single focusout path above and can't fire twice.
  document.getElementById('receiveLinesBody').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const input = e.target.closest('input.line-cost-input, input.line-description-input, input.line-qty-input');
    if (!input) return;
    e.preventDefault();
    input.blur();
  });

  let poAddItemDebounceHandle = null;
  const poAddItemInput = document.getElementById('poAddItemInput');
  poAddItemInput.addEventListener('input', (e) => {
    poAddItemSelectedCode = '';
    poAddItemSelectedName = '';
    poAddItemSelectedDescription = '';
    poAddVariantSelectedCode = '';
    poAddVariantSelectedName = '';
    poAddVariantSelectedDescription = '';
    poAddVariantSelectedId = '';
    document.getElementById('poAddVariantInput').value = '';
    refreshPoAddDescription();
    clearTimeout(poAddItemDebounceHandle);
    const value = e.target.value;
    poAddItemDebounceHandle = setTimeout(() => searchItemsForAddToPo(value), 250);
  });
  poAddItemInput.addEventListener('focus', () => searchItemsForAddToPo(poAddItemInput.value));
  poAddItemInput.addEventListener('blur', () => {
    setTimeout(() => document.getElementById('poAddItemDropdown').classList.add('hidden'), 150);
  });

  let poAddVariantDebounceHandle = null;
  const poAddVariantInput = document.getElementById('poAddVariantInput');
  poAddVariantInput.addEventListener('input', (e) => {
    poAddVariantSelectedCode = '';
    poAddVariantSelectedName = '';
    poAddVariantSelectedDescription = '';
    poAddVariantSelectedId = '';
    refreshPoAddDescription();
    clearTimeout(poAddVariantDebounceHandle);
    const value = e.target.value;
    poAddVariantDebounceHandle = setTimeout(() => searchVariantsForAddToPo(value), 250);
  });
  poAddVariantInput.addEventListener('focus', () => searchVariantsForAddToPo(poAddVariantInput.value));
  poAddVariantInput.addEventListener('blur', () => {
    setTimeout(() => document.getElementById('poAddVariantDropdown').classList.add('hidden'), 150);
  });

  // Same "auto until you type, auto again once you clear it" rule as a New PO line's Description.
  const poAddDescriptionInput = document.getElementById('poAddDescriptionInput');
  poAddDescriptionInput.addEventListener('input', () => {
    poAddDescriptionAuto = poAddDescriptionInput.value.trim() === '';
  });

  const poAddItemUom = document.getElementById('poAddItemUom');
  poAddItemUom.addEventListener('change', () => {
    setPoAddQtyPer(Number(poAddItemUom.selectedOptions[0]?.dataset.qtyPer) || 1);
  });

  document.getElementById('poAddItemBtn').addEventListener('click', addItemToExistingPurchaseOrder);

  document.getElementById('newPoBtn').addEventListener('click', openNewPoModal);
  document.getElementById('closeNewPoModalBtn').addEventListener('click', () =>
    document.getElementById('newPoModal').classList.add('hidden')
  );
  document.getElementById('newPoMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('newPoModal').classList.contains('modal-maximized');
    applyNewPoMaximized(nowMaximized);
    writeStoredFlag(PO_NEW_MAXIMIZED_KEY, nowMaximized);
  });

  document.getElementById('newPoGeneralTab').addEventListener('toggle', (e) => {
    writeStoredFlag(PO_NEW_GENERAL_TAB_KEY, e.target.open);
  });

  // Keeps the collapsed FastTab's summary honest as the header is filled in.
  document.getElementById('newPoVendor').addEventListener('change', refreshNewPoGeneralSummary);
  document.getElementById('newPoNotes').addEventListener('input', refreshNewPoGeneralSummary);

  document.getElementById('newPoWarehouse').addEventListener('change', () => {
    applyHeaderWarehouseToNewPoLines();
    refreshNewPoGeneralSummary();
  });

  document.getElementById('addNewPoLineBtn').addEventListener('click', addNewPoLineRow);
  document.getElementById('createNewPoBtn').addEventListener('click', createNewPurchaseOrder);

  await Promise.all([loadNewPoVendorOptions(), loadNewPoWarehouseOptionsHtml()]);
  await loadPurchaseOrders();
})();
