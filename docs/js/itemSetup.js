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
// FACTBOX (per "restructure the products/items page... a section on the side like a factbox
// to show Variants/Images"): clicking any item row opens a side panel showing that item's own
// image (Items.Images, admin_list_items) and its full variant list, each with the variant's own
// image (Variants.Images, admin_list_variants) - fetched on demand per click rather than
// preloaded for every row, since only one item's detail is visible at a time.
let currentSession = null;
let itemSearchDebounceHandle = null;
let itemsByCode = new Map();
let openFactboxCode = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;

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
        <td style="text-align:right;">${formatMoney(i.price)}</td>
        <td>${variantsCell}</td>
      </tr>
    `;
    })
    .join('');
}

async function loadItems() {
  const tbody = document.getElementById('itemTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="muted">Loading items...</td></tr>';

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
    tbody.innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  itemsByCode = new Map(rows.map((i) => [i.code, i]));

  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="6" class="muted">No items found.</td></tr>'
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

  if (!variants || variants.length === 0) {
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

async function openFactbox(code) {
  const item = itemsByCode.get(code);
  if (!item) return;

  openFactboxCode = code;
  document.getElementById('factboxPlaceholder').classList.add('hidden');
  document.getElementById('factboxContent').classList.remove('hidden');
  document.getElementById('factboxTitle').textContent = `${item.code || ''} - ${item.name || ''}`;

  const imageSection = document.getElementById('factboxImage');
  imageSection.innerHTML = item.images
    ? imageHtml(item.images, 'factbox-image-thumb')
    : '<p class="muted">No image available.</p>';

  document.getElementById('factboxVendorSaved').classList.add('hidden');
  populateFactboxVendorSelect(item.vendor_code);

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
  document.getElementById('factboxContent').classList.add('hidden');
  document.getElementById('factboxPlaceholder').classList.remove('hidden');
}

// Export to Excel / Import from Excel - per "so in the item setup can we export to excel so I can
// add the vendor". Plain CSV, same convention as Vendor Setup's own Export/Import
// (docs/js/vendorSetup.js) - Excel opens it natively, no extra library. Import only ever applies
// the Vendor Code column (via admin_bulk_set_item_vendors, supabase_item_bulk_set_vendor.sql) -
// Name/Category/Price are exported purely as read-only context so whoever's editing can see which
// item is which, not meant to be edited/re-imported.

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

// Exports every item matching the CURRENT search, not just the page on screen - loops
// admin_list_items at a large page size until exhausted, same pattern as vendorSetup.js's export.
async function exportItemsToExcel() {
  const btn = document.getElementById('exportItemsExcelBtn');
  const exportPageSize = 500;
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
        p_search: currentSearch || null,
        p_page: page,
        p_page_size: exportPageSize,
        p_category_code: document.getElementById('itemCategoryFilter').value || null
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
      alert('No items to export for the current search.');
      return;
    }

    const headers = ['Item Code', 'Item Name', 'Category', 'Vendor Code', 'Vendor Name', 'Price'];
    const csvLines = [headers.map(escapeCsvValue).join(',')];
    allRows.forEach((i) => {
      csvLines.push([
        i.code, i.name, i.category_code, i.vendor_code, i.vendor_name, i.price
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

async function importItemsFromExcel(file) {
  const btn = document.getElementById('importItemsExcelBtn');
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Importing...';

  try {
    const text = await file.text();
    let items;
    try {
      items = csvRowsToItemVendorObjects(parseCsv(text));
    } catch (err) {
      alert(err.message);
      return;
    }

    if (items.length === 0) {
      alert('No item rows found in that file.');
      return;
    }

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
    const errorNote = result?.errors?.length ? `\n\nSkipped:\n${result.errors.join('\n')}` : '';
    alert(`Import complete.\nUpdated: ${result?.updated_count ?? 0}\nSkipped: ${result?.skipped_count ?? 0}${errorNote}`);

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

  document.getElementById('factboxCloseBtn').addEventListener('click', closeFactbox);
  document.getElementById('factboxVendorSaveBtn').addEventListener('click', saveFactboxVendor);
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
  await loadItemCategoryFilterOptions();
  await loadItems();
})();
