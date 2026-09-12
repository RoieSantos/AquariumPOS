// Item Setup page logic (super users only, read-only view of the persisted Items table).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js).
//
// SIMPLIFIED to a plain persisted-table read (per "now that the items and variants are
// syncing over via cron, can we remove any manual sync over in the portal") - this page used
// to live-fetch from Pancake on every page load/search (throttled to once per 3 minutes,
// auto-persisting each product as it fetched, admin_list_items_live), because nothing else
// kept Items/Variants fresh unless the desktop app happened to be running. Now that
// cron_sync_items_from_pancake (supabase_pancake_manual_sync.sql) keeps both tables fresh
// every 5 minutes in the background regardless of anyone browsing this page, that live-fetch
// complexity is redundant - this just reads admin_list_items directly, same as every other
// portal list page.
//
// ITEM CARD (per "can you show the item setup as card same as business central too"): clicking a
// row opens the item as a Business Central-style card document - collapsible FastTabs for
// General/Prices/Cost & Vendors/Units of Measure/Variants, Maximize, the picture where BC keeps
// its FactBox. It replaces the side factbox this page used to have (per the earlier "a section on
// the side like a factbox to show Variants/Images"), which had run out of room once vendors and
// units of measure joined it; the list underneath is full width again as a result.
//
// The element ids are still the factbox's, so nothing about how each field saves changed - only
// where it sits. Variants are still fetched per click (admin_list_variants) rather than preloaded
// for every row, since only one item is open at a time.
let currentSession = null;
let itemSearchDebounceHandle = null;
let itemsByCode = new Map();
let openFactboxCode = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;

// Vendor names and a vendor's own item number are free text - escaped before going into
// innerHTML. Same local helper the other list pages keep (purchaseOrders.js, itemSetup's sibling
// pages) rather than a shared script this page does not load.
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

async function loadVariantCounts() {
  const { data, error } = await supabaseClient.rpc('admin_count_variants_by_item', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error || !data) {
    variantCountsByItemCode = new Map();
    return;
  }

  variantCountsByItemCode = new Map(data.map((r) => [r.main_item_code, r.variant_count]));
}

let variantCountsByItemCode = new Map();

// Vendor tagging (factbox) - per "tag the item" to a vendor, see supabase_vendor_tables.sql /
// docs/vendor-setup.html. Vendor counts are expected to be small, so a plain <select> loaded
// once at page load is enough - no need for the debounced search-dropdown pattern Transfer
// Orders uses for large item/variant lookups.
let vendorOptions = []; // [{ code, name }]

async function loadVendorOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_page: 1,
    p_page_size: 500
  });

  if (error || !data) {
    vendorOptions = [];
    return;
  }

  vendorOptions = data.filter((v) => v.vendor_code).map((v) => ({ code: v.vendor_code, name: v.name }));
}

function populateFactboxVendorSelect(selectedCode) {
  const select = document.getElementById('factboxVendorSelect');
  const options = vendorOptions
    .map((v) => `<option value="${v.code}">${v.code} - ${v.name}</option>`)
    .join('');
  select.innerHTML = '<option value="">(No vendor tagged)</option>' + options;
  select.value = selectedCode || '';
}

// Item Vendor catalog (supabase_item_vendors_catalog.sql) - BC's Item Vendor Catalog: every
// vendor who can supply this item, with that vendor's own item number, price and lead time. The
// primary vendor (Items."VendorCode", the select above) always appears here too, badged and
// non-removable - removing it would leave the item tagged to a vendor its own catalog denies.
let factboxItemVendors = [];

function itemVendorRowHtml(v) {
  const cost = v.cost === null || v.cost === undefined ? '' : Number(v.cost);
  return `
    <div class="item-vendor-row" data-vendor-code="${escapeHtml(v.vendor_code)}">
      <div class="item-vendor-row-header">
        <span>${escapeHtml(v.vendor_name || v.vendor_code)}</span>
        ${v.is_primary ? '<span class="badge badge-primary">Primary</span>' : ''}
        ${v.is_primary ? '' : '<button type="button" class="item-vendor-remove" title="Remove this vendor">&times;</button>'}
      </div>
      <div class="item-vendor-row-fields">
        <input type="text" class="item-vendor-no" value="${escapeHtml(v.vendor_item_no || '')}" placeholder="Vendor's item no." title="This vendor's own code for the item - printed on the Purchase Order" />
        <input type="number" class="item-vendor-cost" step="0.01" min="0" value="${cost}" placeholder="Cost" title="This vendor's price - leave blank to use the item's own cost" />
        <input type="number" class="item-vendor-lead" step="1" min="0" value="${v.lead_time_days ?? ''}" placeholder="Days" title="Lead time in days" />
        <button type="button" class="btn btn-secondary btn-sm item-vendor-save">Save</button>
      </div>
    </div>
  `;
}

// Only vendors not already on the item are offerable - adding one twice is the same row.
function populateFactboxAddVendorSelect() {
  const taken = new Set(factboxItemVendors.map((v) => v.vendor_code));
  const available = vendorOptions.filter((v) => !taken.has(v.code));
  const select = document.getElementById('factboxAddVendorSelect');

  select.innerHTML = available.length === 0
    ? '<option value="">All vendors already added</option>'
    : available.map((v) => `<option value="${v.code}">${v.code} - ${v.name}</option>`).join('');

  document.getElementById('factboxAddVendorBtn').disabled = available.length === 0;
}

async function loadFactboxItemVendors(code) {
  const container = document.getElementById('factboxItemVendors');
  container.innerHTML = '<p class="muted">Loading vendors...</p>';

  const { data, error } = await supabaseClient.rpc('staff_list_item_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: code
  });

  // The factbox may have moved to another item while this was in flight.
  if (openFactboxCode !== code) return;

  if (error) {
    container.innerHTML = `<p class="error-text">${error.message}</p>`;
    return;
  }

  factboxItemVendors = data || [];
  container.innerHTML = factboxItemVendors.length === 0
    ? '<p class="muted">No vendors linked to this item yet.</p>'
    : factboxItemVendors.map(itemVendorRowHtml).join('');

  populateFactboxAddVendorSelect();
}

async function saveItemVendor(rowEl) {
  const vendorCode = rowEl.dataset.vendorCode;
  const costRaw = rowEl.querySelector('.item-vendor-cost').value.trim();
  const leadRaw = rowEl.querySelector('.item-vendor-lead').value.trim();
  const btn = rowEl.querySelector('.item-vendor-save');

  btn.disabled = true;
  btn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_upsert_item_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_vendor_code: vendorCode,
    p_vendor_item_no: rowEl.querySelector('.item-vendor-no').value.trim() || null,
    // Blank cost means "no separate price for this vendor" - it falls back to the item's own
    // cost, which is not the same as agreeing a price of zero.
    p_cost: costRaw === '' ? null : Number(costRaw),
    p_lead_time_days: leadRaw === '' ? null : Number(leadRaw)
  });

  btn.disabled = false;
  btn.textContent = error ? 'Save' : 'Saved';

  if (error) {
    window.alert(error.message || 'Failed to save this vendor.');
    return;
  }

  setTimeout(() => { btn.textContent = 'Save'; }, 1500);
}

async function addItemVendor() {
  const vendorCode = document.getElementById('factboxAddVendorSelect').value;
  if (!vendorCode || !openFactboxCode) return;

  const { error } = await supabaseClient.rpc('admin_upsert_item_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_vendor_code: vendorCode
  });

  if (error) {
    window.alert(error.message || 'Failed to add this vendor.');
    return;
  }

  await loadFactboxItemVendors(openFactboxCode);
}

async function removeItemVendor(vendorCode) {
  if (!window.confirm(`Remove this vendor from ${openFactboxCode}? Purchase Orders already raised are not affected.`)) return;

  const { error } = await supabaseClient.rpc('admin_remove_item_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_vendor_code: vendorCode
  });

  if (error) {
    window.alert(error.message || 'Failed to remove this vendor.');
    return;
  }

  await loadFactboxItemVendors(openFactboxCode);
}

// Units of Measure (supabase_units_of_measure.sql) - BC's Item Unit of Measure. The base unit is
// what stock and cost are counted in; every other unit carries its conversion into base, which is
// what lets a Purchase Order be raised in boxes and still stock in pieces.
let unitOfMeasureOptions = []; // the global code list, loaded once
let factboxItemUoms = [];

async function loadUnitOfMeasureOptions() {
  const { data, error } = await supabaseClient.rpc('staff_list_units_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    console.error('staff_list_units_of_measure failed:', error);
    return;
  }

  unitOfMeasureOptions = data || [];
  // Suggestions for the "add a unit" box - typing a code that is not on the list creates it, so
  // this is a datalist rather than a select.
  document.getElementById('uomCodeList').innerHTML = unitOfMeasureOptions
    .map((u) => `<option value="${escapeHtml(u.code)}">${escapeHtml(u.description || '')}</option>`)
    .join('');
}

function itemUomRowHtml(u) {
  const label = [u.unit_of_measure_code, u.description].filter(Boolean).join(' - ');
  return `
    <div class="item-uom-row" data-uom-code="${escapeHtml(u.unit_of_measure_code)}">
      <span class="item-uom-code" title="${escapeHtml(label)}">${escapeHtml(u.unit_of_measure_code)}</span>
      ${u.is_base ? '<span class="badge badge-primary">Base</span>' : ''}
      ${u.is_purch ? '<span class="badge badge-glass">Buy</span>' : ''}
      <input type="number" class="item-uom-qty" step="0.0001" min="0" value="${Number(u.qty_per_unit_of_measure)}" ${u.is_base ? 'disabled title="The base unit is always 1 of itself"' : 'title="How many base units one of these contains"'} />
      ${u.is_base || u.is_purch ? '' : '<button type="button" class="item-uom-remove" title="Remove this unit">&times;</button>'}
    </div>
  `;
}

// Which unit is base and which is the buying default are read back off the item's own unit list
// (staff_list_item_units_of_measure derives both from the Items row), so admin_list_items does not
// have to grow two more columns just to fill these two pickers.
function populateFactboxUomSelects() {
  const baseSelect = document.getElementById('factboxBaseUomSelect');
  const purchSelect = document.getElementById('factboxPurchUomSelect');

  // Base may be switched to a unit the item does not have yet (that is how a brand-new item gets
  // off PCS), so it offers the whole master list.
  baseSelect.innerHTML = unitOfMeasureOptions
    .map((u) => `<option value="${escapeHtml(u.code)}">${escapeHtml(u.code)}</option>`)
    .join('');
  baseSelect.value = factboxItemUoms.find((u) => u.is_base)?.unit_of_measure_code || 'PCS';

  // The buying unit must be one the item has a conversion for - anything else would leave a
  // quantity that cannot be converted to stock.
  purchSelect.innerHTML = '<option value="">(Same as base)</option>' + factboxItemUoms
    .map((u) => `<option value="${escapeHtml(u.unit_of_measure_code)}">${escapeHtml(u.unit_of_measure_code)}</option>`)
    .join('');
  purchSelect.value = factboxItemUoms.find((u) => u.is_purch)?.unit_of_measure_code || '';
}

async function loadFactboxItemUoms(code) {
  const container = document.getElementById('factboxItemUoms');
  container.innerHTML = '<p class="muted">Loading units...</p>';

  const { data, error } = await supabaseClient.rpc('staff_list_item_units_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: code
  });

  if (openFactboxCode !== code) return;

  if (error) {
    container.innerHTML = `<p class="error-text">${error.message}</p>`;
    return;
  }

  factboxItemUoms = data || [];
  container.innerHTML = factboxItemUoms.length === 0
    ? '<p class="muted">No units defined.</p>'
    : factboxItemUoms.map(itemUomRowHtml).join('');

  populateFactboxUomSelects();

  const base = factboxItemUoms.find((u) => u.is_base)?.unit_of_measure_code;
  const purch = factboxItemUoms.find((u) => u.is_purch)?.unit_of_measure_code;
  document.getElementById('itemCardUomSummary').textContent =
    [base ? `Base ${base}` : null, purch ? `Buy ${purch}` : null].filter(Boolean).join(' · ');
}

async function saveItemUom(uomCode, qtyPer) {
  const { error } = await supabaseClient.rpc('admin_upsert_item_unit_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_unit_of_measure_code: uomCode,
    p_qty_per_unit_of_measure: qtyPer
  });

  if (error) {
    window.alert(error.message || 'Failed to save this unit.');
    return false;
  }

  return true;
}

async function addItemUom() {
  const codeInput = document.getElementById('factboxAddUomCode');
  const qtyInput = document.getElementById('factboxAddUomQty');
  const code = codeInput.value.trim().toUpperCase();
  const qty = Number(qtyInput.value);

  if (!code || !openFactboxCode) return;
  if (!qty || qty <= 0) {
    window.alert('Enter how many base units one of these contains.');
    return;
  }

  if (!(await saveItemUom(code, qty))) return;

  codeInput.value = '';
  qtyInput.value = '';
  await loadUnitOfMeasureOptions();
  await loadFactboxItemUoms(openFactboxCode);
}

async function removeItemUom(uomCode) {
  const { error } = await supabaseClient.rpc('admin_remove_item_unit_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_unit_of_measure_code: uomCode
  });

  if (error) {
    window.alert(error.message || 'Failed to remove this unit.');
    return;
  }

  await loadFactboxItemUoms(openFactboxCode);
}

async function saveFactboxUnitsOfMeasure() {
  if (!openFactboxCode) return;

  const savedEl = document.getElementById('factboxUomSaved');
  savedEl.classList.add('hidden');

  const btn = document.getElementById('factboxUomSaveBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_set_item_units_of_measure', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_base_unit_of_measure: document.getElementById('factboxBaseUomSelect').value,
    p_purch_unit_of_measure: document.getElementById('factboxPurchUomSelect').value || null
  });

  btn.disabled = false;
  btn.textContent = 'Save';

  if (error) {
    window.alert(error.message || 'Failed to save the units of measure.');
    return;
  }

  await loadFactboxItemUoms(openFactboxCode);
  savedEl.classList.remove('hidden');
}

async function saveFactboxVendor() {
  if (!openFactboxCode) return;

  const savedEl = document.getElementById('factboxVendorSaved');
  savedEl.classList.add('hidden');

  const saveBtn = document.getElementById('factboxVendorSaveBtn');
  const vendorCode = document.getElementById('factboxVendorSelect').value;
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_set_item_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_vendor_code: vendorCode || null
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save';

  if (error) {
    window.alert(error.message);
    return;
  }

  // Keep the cached row in sync so re-opening the factbox (or a later render) shows the tag
  // without a full list reload.
  const item = itemsByCode.get(openFactboxCode);
  if (item) {
    item.vendor_code = vendorCode || null;
    item.vendor_name = vendorOptions.find((v) => v.code === vendorCode)?.name || null;
  }

  // Per "once i update the vendor on the item setup can you auto update the item list so I can
  // see the vendor updated" - patches just the Vendor cell of this item's row in place (4th <td>,
  // matching itemRowsHtml's column order) rather than a full loadItems() reload, which would also
  // reset scroll position/pagination for no reason.
  const row = document.querySelector(`#itemTableBody tr[data-code="${openFactboxCode}"]`);
  if (row) {
    row.children[3].innerHTML = item?.vendor_name || '<span class="muted">-</span>';
  }

  if (item) renderItemCardGeneral(item);

  // The primary is also a catalog entry (admin_set_item_vendor files it there), and which row
  // wears the "Primary" badge has just changed - so the list below is reloaded, not patched.
  await loadFactboxItemVendors(openFactboxCode);

  savedEl.classList.remove('hidden');
}

// Item cost (factbox) - per "in the items can we add cost per item?". Has its own Save button
// rather than saving on blur, matching the Vendor picker: a mistyped cost silently overwriting the
// old one would be hard to notice, and this is the figure Purchase Orders total from.
//
// Note the cost can also change WITHOUT anyone editing it here: posting a Purchase Order writes
// the cost actually paid back onto the item (see staff_post_purchase_order in
// supabase_item_cost_and_po_line_cost.sql), so a value shown here may be a PO's doing.
async function saveFactboxCost() {
  if (!openFactboxCode) return;

  const savedEl = document.getElementById('factboxCostSaved');
  const input = document.getElementById('factboxCostInput');
  const saveBtn = document.getElementById('factboxCostSaveBtn');
  savedEl.classList.add('hidden');

  const raw = input.value.trim();
  const cost = raw === '' ? null : Number(raw);

  if (cost !== null && (!Number.isFinite(cost) || cost < 0)) {
    window.alert('Enter a cost of 0 or more, or leave it blank if the item is not costed yet.');
    return;
  }

  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_set_item_cost', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_cost: cost
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save';

  if (error) {
    window.alert(error.message);
    return;
  }

  // Same in-place patch the Vendor save does - keeps the cached row and the visible Cost cell
  // (5th <td>, matching itemRowsHtml's column order) in step without a full reload.
  const item = itemsByCode.get(openFactboxCode);
  if (item) item.cost = cost;

  const row = document.querySelector(`#itemTableBody tr[data-code="${openFactboxCode}"]`);
  if (row) {
    row.children[4].innerHTML = cost === null ? '<span class="muted">-</span>' : formatMoney(cost);
  }

  if (item) renderItemCardGeneral(item);

  savedEl.classList.remove('hidden');
}

async function saveFactboxWholesalePrice() {
  if (!openFactboxCode) return;

  const savedEl = document.getElementById('factboxWholesalePriceSaved');
  const input = document.getElementById('factboxWholesalePriceInput');
  const saveBtn = document.getElementById('factboxWholesalePriceSaveBtn');
  savedEl.classList.add('hidden');

  const raw = input.value.trim();
  const wholesalePrice = raw === '' ? null : Number(raw);

  if (wholesalePrice !== null && (!Number.isFinite(wholesalePrice) || wholesalePrice < 0)) {
    window.alert('Enter a wholesale price of 0 or more, or leave it blank if not set.');
    return;
  }

  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_set_item_wholesale_price', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_wholesale_price: wholesalePrice
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save';

  if (error) {
    window.alert(error.message);
    return;
  }

  const item = itemsByCode.get(openFactboxCode);
  if (item) item.wholesale_price = wholesalePrice;

  // Same in-place patch the Cost save does - keeps the cached row and the visible Wholesale
  // Price cell (7th <td>, matching itemRowsHtml's column order) in step without a full reload.
  const row = document.querySelector(`#itemTableBody tr[data-code="${openFactboxCode}"]`);
  if (row) {
    row.children[6].innerHTML = wholesalePrice === null ? '<span class="muted">-</span>' : formatMoney(wholesalePrice);
  }

  savedEl.classList.remove('hidden');
}

// "Hide from Order Now SET" toggle (factbox) - per "add a field to not show in the SET" request,
// see supabase_item_hide_from_set.sql. Saves immediately on check/uncheck (no separate Save
// button - a single checkbox doesn't need the confirm-before-save step the Vendor picker has).
async function saveFactboxHideFromSet() {
  if (!openFactboxCode) return;

  const savedEl = document.getElementById('factboxHideFromSetSaved');
  const checkbox = document.getElementById('factboxHideFromSetCheckbox');
  savedEl.classList.add('hidden');
  checkbox.disabled = true;

  const { error } = await supabaseClient.rpc('admin_set_item_hide_from_set', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_code: openFactboxCode,
    p_hide_from_set: checkbox.checked
  });

  checkbox.disabled = false;

  if (error) {
    window.alert(error.message);
    checkbox.checked = !checkbox.checked; // revert the optimistic UI change
    return;
  }

  const item = itemsByCode.get(openFactboxCode);
  if (item) {
    item.hide_from_set = checkbox.checked;
  }

  savedEl.classList.remove('hidden');
}

function itemRowsHtml(items) {
  return items
    .map((i) => {
      const variantCount = variantCountsByItemCode.get(i.code);
      const variantsCell = variantCount
        ? `<a href="variant-setup.html?item=${encodeURIComponent(i.code)}">View (${variantCount})</a>`
        : '<span class="muted">-</span>';
      return `
      <tr class="clickable-row" data-code="${i.code || ''}">
        <td>${i.code || ''}</td>
        <td>${i.name || ''}</td>
        <td>${i.category_code || ''}</td>
        <td>${i.vendor_name || '<span class="muted">-</span>'}</td>
        <td style="text-align:right;">${i.cost === null || i.cost === undefined ? '<span class="muted">-</span>' : formatMoney(i.cost)}</td>
        <td style="text-align:right;">${formatMoney(i.price)}</td>
        <td style="text-align:right;">${i.wholesale_price === null || i.wholesale_price === undefined ? '<span class="muted">-</span>' : formatMoney(i.wholesale_price)}</td>
        <td>${variantsCell}</td>
      </tr>
    `;
    })
    .join('');
}

async function loadItems() {
  const tbody = document.getElementById('itemTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading items...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize,
    p_category_code: document.getElementById('itemCategoryFilter').value || null
  });

  if (thisGeneration !== loadGeneration) return; // a newer search/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  itemsByCode = new Map(rows.map((i) => [i.code, i]));

  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="8" class="muted">No items found.</td></tr>'
    : itemRowsHtml(rows);

  renderPaginationBar(
    document.getElementById('itemPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: rows[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadItems(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadItems(); }
    }
  );

  // If the factbox was open for an item that's still in this refreshed result set, keep it
  // open and refresh its contents; otherwise close it (the item scrolled out of view/search).
  if (openFactboxCode && itemsByCode.has(openFactboxCode)) {
    openFactbox(openFactboxCode);
  } else {
    closeFactbox();
  }
}

function wireItemSearch() {
  document.getElementById('itemSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(itemSearchDebounceHandle);
    itemSearchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadItems();
    }, 300);
  });

  // Per "in the item setup can we filter by category" - reuses admin_list_categories (already
  // admin-gated, same trust level as this page) rather than a new RPC.
  document.getElementById('itemCategoryFilter').addEventListener('change', () => {
    currentPage = 1;
    loadItems();
  });
}

async function loadItemCategoryFilterOptions() {
  const { data, error } = await supabaseClient.rpc('admin_list_categories', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error || !data) return;

  const select = document.getElementById('itemCategoryFilter');
  data.forEach((c) => {
    const option = document.createElement('option');
    option.value = c.code;
    option.textContent = c.description || c.code;
    select.appendChild(option);
  });
}

function imageHtml(url, thumbClass) {
  if (!url) return '';
  const safeUrl = encodeURI(url);
  return `<img src="${safeUrl}" class="${thumbClass}" alt="" loading="lazy" onerror="this.remove();" />`;
}

function renderFactboxVariants(variants) {
  const container = document.getElementById('factboxVariants');
  const count = variants ? variants.length : 0;

  // The Variants tab starts collapsed, so its count goes on the tab itself - otherwise you would
  // have to open it just to find out there are none.
  document.getElementById('itemCardVariantsSummary').textContent =
    count === 0 ? 'None' : `${count} variant${count === 1 ? '' : 's'}`;

  if (count === 0) {
    container.innerHTML = '<p class="muted">No variants for this item.</p>';
    return;
  }

  container.innerHTML = variants
    .map((v) => {
      const thumb = v.images
        ? imageHtml(v.images, 'factbox-variant-thumb')
        : '<div class="factbox-variant-thumb-placeholder"></div>';
      const priceText = v.price !== null && v.price !== undefined ? formatMoney(v.price) : '';
      return `
        <div class="factbox-variant-row">
          ${thumb}
          <div class="factbox-variant-info">
            <div class="factbox-variant-name">${v.variant_name || v.sku || v.variation_id || 'Unnamed variant'}</div>
            <div class="factbox-variant-meta">${v.sku ? 'SKU ' + v.sku : ''}${v.sku && priceText ? ' - ' : ''}${priceText ? '₱' + priceText : ''}</div>
          </div>
        </div>
      `;
    })
    .join('');
}

// Item Card layout state, remembered per browser the same way the Purchase Order document's is
// (js/purchaseOrders.js) - someone who works maximized should not have to click Maximize on every
// item. localStorage is wrapped because it throws outright in some privacy modes.
const ITEM_CARD_MAXIMIZED_KEY = 'item-card-maximized';

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

function applyItemCardMaximized(maximized) {
  document.getElementById('itemCardModal').classList.toggle('modal-maximized', maximized);
  document.getElementById('itemCardModal').querySelector('.modal-panel')
    .classList.toggle('modal-maximized', maximized);

  const btn = document.getElementById('itemCardMaximizeBtn');
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized ? 'Restore this card to a window' : 'Maximize this card to fill the window';
}

function itemCardText(value) {
  return value === null || value === undefined || value === '' ? '-' : String(value);
}

// The read-only half of the card - everything here is Pancake's, refreshed by the background sync.
function renderItemCardGeneral(item) {
  document.getElementById('itemCardCode').textContent = itemCardText(item.code);
  document.getElementById('itemCardName').textContent = itemCardText(item.name);
  document.getElementById('itemCardDescription').textContent = itemCardText(item.description);
  document.getElementById('itemCardCategory').textContent = itemCardText(item.category_code);
  document.getElementById('itemCardBrand').textContent = itemCardText(item.brand);
  document.getElementById('itemCardSku').textContent = itemCardText(item.sku);
  document.getElementById('itemCardStock').textContent =
    item.quantity_in_stock === null || item.quantity_in_stock === undefined
      ? '-'
      : Number(item.quantity_in_stock).toLocaleString();
  document.getElementById('itemCardStatus').textContent = item.is_active === false ? 'Inactive' : 'Active';

  document.getElementById('itemCardPrice').textContent = formatMoney(item.price);
  document.getElementById('itemCardRetailPrice').textContent = formatMoney(item.retail_price);
  document.getElementById('itemCardPromoPrice').textContent = formatMoney(item.promo_price);

  // Collapsed-tab summaries, so folding a tab away never costs you the figure you were after -
  // the same trick the Purchase Order document's General tab uses.
  document.getElementById('itemCardGeneralSummary').textContent =
    [item.category_code, item.is_active === false ? 'Inactive' : null].filter(Boolean).join(' · ');
  document.getElementById('itemCardPricesSummary').textContent = `Price ${formatMoney(item.price)}`;
  document.getElementById('itemCardCostSummary').textContent =
    [item.cost === null || item.cost === undefined ? 'Not costed' : `Cost ${formatMoney(item.cost)}`,
      item.vendor_name].filter(Boolean).join(' · ');
}

async function openFactbox(code) {
  const item = itemsByCode.get(code);
  if (!item) return;

  openFactboxCode = code;
  document.getElementById('itemCardTitle').textContent = `${item.code || ''} - ${item.name || ''}`;
  document.getElementById('itemCardModal').classList.remove('hidden');
  applyItemCardMaximized(readStoredFlag(ITEM_CARD_MAXIMIZED_KEY, false));

  renderItemCardGeneral(item);

  const imageSection = document.getElementById('factboxImage');
  imageSection.innerHTML = item.images
    ? imageHtml(item.images, 'factbox-image-thumb')
    : '<p class="muted">No image available.</p>';

  document.getElementById('factboxVendorSaved').classList.add('hidden');
  populateFactboxVendorSelect(item.vendor_code);
  loadFactboxItemVendors(code);

  document.getElementById('factboxUomSaved').classList.add('hidden');
  loadFactboxItemUoms(code);

  document.getElementById('factboxCostSaved').classList.add('hidden');
  // Blank rather than 0 when uncosted - "not costed yet" and "costs nothing" are different, and
  // only a blank makes a PO line fall back to asking (see admin_set_item_cost).
  document.getElementById('factboxCostInput').value =
    item.cost === null || item.cost === undefined ? '' : Number(item.cost);

  document.getElementById('factboxWholesalePriceSaved').classList.add('hidden');
  document.getElementById('factboxWholesalePriceInput').value =
    item.wholesale_price === null || item.wholesale_price === undefined ? '' : Number(item.wholesale_price);

  document.getElementById('factboxHideFromSetSaved').classList.add('hidden');
  document.getElementById('factboxHideFromSetCheckbox').checked = Boolean(item.hide_from_set);

  const variantsSection = document.getElementById('factboxVariants');
  variantsSection.innerHTML = '<p class="muted">Loading variants...</p>';

  const { data, error } = await supabaseClient.rpc('admin_list_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_main_item_code: code
  });

  // The factbox may have been closed or switched to a different item while this call was
  // in flight - only render if it's still showing the item this response is for.
  if (openFactboxCode !== code) return;

  if (error) {
    variantsSection.innerHTML = `<p class="error-text">${error.message}</p>`;
    return;
  }

  renderFactboxVariants(data);
}

function closeFactbox() {
  openFactboxCode = null;
  document.getElementById('itemCardModal').classList.add('hidden');
}

// Export to Excel / Import from Excel - per "so in the item setup can we export to excel so I can
// add the vendor". Plain CSV, same convention as Vendor Setup's own Export/Import
// (docs/js/vendorSetup.js) - Excel opens it natively, no extra library. Import applies Vendor Code
// (admin_bulk_set_item_vendors, supabase_item_bulk_set_vendor.sql), Cost, and Wholesale Price
// (admin_bulk_set_item_costs / admin_bulk_set_item_wholesale_prices,
// supabase_item_cost_and_po_line_cost.sql / supabase_item_wholesale_price.sql) - Name/Category/
// Price are exported purely as read-only context so whoever's editing can see which item is which,
// not meant to be edited/re-imported.

function escapeCsvValue(value) {
  const str = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(str) ? '"' + str.replace(/"/g, '""') + '"' : str;
}

// RFC4180-ish CSV parser (handles quoted fields containing commas/newlines/escaped "" quotes) -
// same parser as vendorSetup.js's, copied rather than shared since these are separate page
// bundles with no common utils module.
function parseCsv(text) {
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1); // strip UTF-8 BOM if present

  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (inQuotes) {
      if (char === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else {
        field += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ',') {
      row.push(field); field = '';
    } else if (char === '\r') {
      // ignore - a following \n (CRLF) closes the row on its own
    } else if (char === '\n') {
      row.push(field); field = '';
      rows.push(row); row = [];
    } else {
      field += char;
    }
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }

  return rows.filter((r) => !(r.length === 1 && r[0].trim() === ''));
}

// Exports every item in the catalog, ignoring whatever search/category filter is currently on
// screen - per "can we export everything on the table", the on-screen search box was silently
// scoping the export down to a filtered subset, which read as rows going missing. Loops
// admin_list_items at a large page size until exhausted, same pattern as vendorSetup.js's export.
//
// Page size is 200, not some larger round number - admin_list_items
// (supabase_item_setup_category_filter.sql) silently clamps p_page_size to 200 server-side, and
// the loop below decides it has reached the last page by checking whether a page came back
// SHORTER than what it asked for. Asking for more than 200 meant every page came back "short"
// (200 < requested), so the loop stopped after page 1 and any items past the first 200
// (alphabetically by Name) never got exported - including, apparently, Stand/Sump. Matching the
// actual server cap here makes that comparison correct again.
async function exportItemsToExcel() {
  const btn = document.getElementById('exportItemsExcelBtn');
  const exportPageSize = 200;
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Exporting...';

  try {
    const allRows = [];
    let page = 1;
    for (;;) {
      const { data, error } = await supabaseClient.rpc('admin_list_items', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_search: null,
        p_page: page,
        p_page_size: exportPageSize,
        p_category_code: null
      });

      if (error) {
        alert('Export failed: ' + error.message);
        return;
      }

      allRows.push(...(data || []));
      if (!data || data.length < exportPageSize) break;
      page += 1;
    }

    if (allRows.length === 0) {
      alert('No items to export.');
      return;
    }

    // Cost and Wholesale Price sit next to Vendor Code because those are the editable/re-importable
    // columns - Name/Category/Price around them are read-only context. An uncosted/unset item
    // exports as an empty cell, not 0, so a round-trip re-import doesn't turn "not set" into
    // "is zero".
    const headers = ['Item Code', 'Item Name', 'Category', 'Vendor Code', 'Vendor Name', 'Cost', 'Price', 'Wholesale Price'];
    const csvLines = [headers.map(escapeCsvValue).join(',')];
    allRows.forEach((i) => {
      csvLines.push([
        i.code, i.name, i.category_code, i.vendor_code, i.vendor_name,
        i.cost === null || i.cost === undefined ? '' : i.cost,
        i.price,
        i.wholesale_price === null || i.wholesale_price === undefined ? '' : i.wholesale_price
      ].map(escapeCsvValue).join(','));
    });

    const blob = new Blob(['﻿' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    const link = document.createElement('a');
    link.href = url;
    link.download = `items-${stamp}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

// Maps parsed CSV rows to admin_bulk_set_item_vendors' expected shape by header NAME
// (case-insensitive), not position - a re-ordered/trimmed-down re-import still works as long as
// "Item Code" is present. "Vendor Code" is optional per row - a blank value clears that item's tag.
function csvRowsToItemVendorObjects(rows) {
  if (rows.length === 0) return [];

  const headers = rows[0].map((h) => h.trim().toLowerCase());
  const col = (label) => headers.indexOf(label);
  const idx = { item_code: col('item code'), vendor_code: col('vendor code') };

  if (idx.item_code === -1) {
    throw new Error('That file must have an "Item Code" column (matching Export to Excel\'s headers).');
  }

  const at = (r, i) => (i > -1 ? (r[i] || '').trim() : '');

  return rows.slice(1)
    .filter((r) => r.some((v) => v.trim() !== ''))
    .map((r) => ({ item_code: at(r, idx.item_code), vendor_code: at(r, idx.vendor_code) }));
}

// Same header-name mapping for Cost, but with one deliberate difference from the vendor mapping
// above: this returns null when the file has NO "Cost" column at all, and the caller then skips
// the cost import entirely rather than sending blanks.
//
// That matters because a missing column and an empty cell both read as '' - so treating them the
// same (as the vendor mapping does) would mean re-importing a trimmed Item Code + Vendor Code
// sheet silently wiped the cost off every item in it. Within a file that DOES carry the column, a
// blank cell keeps its natural meaning: clear this item's cost.
function csvRowsToItemCostObjects(rows) {
  if (rows.length === 0) return null;

  const headers = rows[0].map((h) => h.trim().toLowerCase());
  const itemCodeIdx = headers.indexOf('item code');
  const costIdx = headers.indexOf('cost');

  if (itemCodeIdx === -1 || costIdx === -1) return null;

  const at = (r, i) => (i > -1 ? (r[i] || '').trim() : '');

  return rows.slice(1)
    .filter((r) => r.some((v) => v.trim() !== ''))
    .map((r) => ({ item_code: at(r, itemCodeIdx), cost: at(r, costIdx) }));
}

// Same header-name mapping and "missing column vs blank cell" contract as the Cost mapper above,
// for Wholesale Price.
function csvRowsToItemWholesalePriceObjects(rows) {
  if (rows.length === 0) return null;

  const headers = rows[0].map((h) => h.trim().toLowerCase());
  const itemCodeIdx = headers.indexOf('item code');
  const priceIdx = headers.indexOf('wholesale price');

  if (itemCodeIdx === -1 || priceIdx === -1) return null;

  const at = (r, i) => (i > -1 ? (r[i] || '').trim() : '');

  return rows.slice(1)
    .filter((r) => r.some((v) => v.trim() !== ''))
    .map((r) => ({ item_code: at(r, itemCodeIdx), wholesale_price: at(r, priceIdx) }));
}

async function importItemsFromExcel(file) {
  const btn = document.getElementById('importItemsExcelBtn');
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Importing...';

  try {
    const text = await file.text();
    const rows = parseCsv(text);

    let items;
    try {
      items = csvRowsToItemVendorObjects(rows);
    } catch (err) {
      alert(err.message);
      return;
    }

    if (items.length === 0) {
      alert('No item rows found in that file.');
      return;
    }

    // Null when the file has no "Cost"/"Wholesale Price" column - that field is then left
    // completely alone.
    const costItems = csvRowsToItemCostObjects(rows);
    const wholesalePriceItems = csvRowsToItemWholesalePriceObjects(rows);

    const { data, error } = await supabaseClient.rpc('admin_bulk_set_item_vendors', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_items: items
    });

    if (error) {
      alert('Import failed: ' + error.message);
      return;
    }

    const result = Array.isArray(data) ? data[0] : data;
    const messages = [
      `Vendors - updated: ${result?.updated_count ?? 0}, skipped: ${result?.skipped_count ?? 0}`
    ];
    const skipped = [...(result?.errors || [])];

    // Vendors are already applied by this point, so a cost failure is reported alongside them
    // rather than thrown - saying nothing would leave the impression the whole import failed.
    if (costItems) {
      const { data: costData, error: costError } = await supabaseClient.rpc('admin_bulk_set_item_costs', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_items: costItems
      });

      if (costError) {
        messages.push(`Costs - FAILED: ${costError.message}`);
      } else {
        const costResult = Array.isArray(costData) ? costData[0] : costData;
        messages.push(`Costs - updated: ${costResult?.updated_count ?? 0}, skipped: ${costResult?.skipped_count ?? 0}`);
        skipped.push(...(costResult?.errors || []));
      }
    } else {
      messages.push('Costs - no "Cost" column in that file, so costs were left unchanged.');
    }

    // Same append-not-throw treatment as Costs - Vendors (and possibly Costs) are already applied
    // by this point, so a Wholesale Price failure is reported alongside them, not thrown.
    if (wholesalePriceItems) {
      const { data: wholesaleData, error: wholesaleError } = await supabaseClient.rpc('admin_bulk_set_item_wholesale_prices', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_items: wholesalePriceItems
      });

      if (wholesaleError) {
        messages.push(`Wholesale Prices - FAILED: ${wholesaleError.message}`);
      } else {
        const wholesaleResult = Array.isArray(wholesaleData) ? wholesaleData[0] : wholesaleData;
        messages.push(`Wholesale Prices - updated: ${wholesaleResult?.updated_count ?? 0}, skipped: ${wholesaleResult?.skipped_count ?? 0}`);
        skipped.push(...(wholesaleResult?.errors || []));
      }
    } else {
      messages.push('Wholesale Prices - no "Wholesale Price" column in that file, so wholesale prices were left unchanged.');
    }

    const errorNote = skipped.length ? `\n\nSkipped:\n${skipped.join('\n')}` : '';
    alert(`Import complete.\n${messages.join('\n')}${errorNote}`);

    await loadItems();
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

function wireFactbox() {
  document.getElementById('itemTableBody').addEventListener('click', (e) => {
    const row = e.target.closest('tr[data-code]');
    if (!row) return;
    if (e.target.closest('a')) return; // let the existing "View (N)" variants link navigate normally
    openFactbox(row.dataset.code);
  });

  document.getElementById('itemCardCloseBtn').addEventListener('click', closeFactbox);

  document.getElementById('itemCardMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('itemCardModal').classList.contains('modal-maximized');
    applyItemCardMaximized(nowMaximized);
    writeStoredFlag(ITEM_CARD_MAXIMIZED_KEY, nowMaximized);
  });
  document.getElementById('factboxVendorSaveBtn').addEventListener('click', saveFactboxVendor);

  // Delegated - the vendor rows are re-rendered on every load, so per-element listeners would be
  // lost each time.
  document.getElementById('factboxItemVendors').addEventListener('click', (e) => {
    const removeBtn = e.target.closest('.item-vendor-remove');
    if (removeBtn) {
      removeItemVendor(removeBtn.closest('.item-vendor-row').dataset.vendorCode);
      return;
    }
    const saveBtn = e.target.closest('.item-vendor-save');
    if (saveBtn) saveItemVendor(saveBtn.closest('.item-vendor-row'));
  });

  document.getElementById('factboxAddVendorBtn').addEventListener('click', addItemVendor);

  document.getElementById('factboxUomSaveBtn').addEventListener('click', saveFactboxUnitsOfMeasure);
  document.getElementById('factboxAddUomBtn').addEventListener('click', addItemUom);

  // Delegated, same as the vendor rows - these are re-rendered on every load. A conversion saves
  // when you leave the box: it is a single number, and a Save button per row would crowd a panel
  // this narrow.
  const uomsEl = document.getElementById('factboxItemUoms');
  uomsEl.addEventListener('click', (e) => {
    const removeBtn = e.target.closest('.item-uom-remove');
    if (removeBtn) removeItemUom(removeBtn.closest('.item-uom-row').dataset.uomCode);
  });

  uomsEl.addEventListener('change', async (e) => {
    const input = e.target.closest('.item-uom-qty');
    if (!input) return;
    const qty = Number(input.value);
    if (!qty || qty <= 0) {
      window.alert('Qty per unit must be greater than 0.');
      await loadFactboxItemUoms(openFactboxCode);
      return;
    }
    await saveItemUom(input.closest('.item-uom-row').dataset.uomCode, qty);
  });
  document.getElementById('factboxCostSaveBtn').addEventListener('click', saveFactboxCost);
  document.getElementById('factboxWholesalePriceSaveBtn').addEventListener('click', saveFactboxWholesalePrice);
  document.getElementById('factboxHideFromSetCheckbox').addEventListener('change', saveFactboxHideFromSet);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Item Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Item Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  wireItemSearch();
  wireFactbox();

  document.getElementById('exportItemsExcelBtn').addEventListener('click', exportItemsToExcel);
  document.getElementById('importItemsExcelBtn').addEventListener('click', () => {
    document.getElementById('importItemsExcelFileInput').click();
  });
  document.getElementById('importItemsExcelFileInput').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    e.target.value = ''; // allow re-selecting the same file next time
    if (file) await importItemsFromExcel(file);
  });

  await loadVariantCounts();
  await loadVendorOptionsOnce();
  await loadUnitOfMeasureOptions();
  await loadItemCategoryFilterOptions();
  await loadItems();
})();
