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
        <td style="text-align:right;">${formatMoney(i.price)}</td>
        <td>${variantsCell}</td>
      </tr>
    `;
    })
    .join('');
}

async function loadItems() {
  const tbody = document.getElementById('itemTableBody');
  tbody.innerHTML = '<tr><td colspan="5" class="muted">Loading items...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return; // a newer search/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="5" class="error-text">${error.message}</td></tr>`;
    return;
  }

  const rows = data || [];
  itemsByCode = new Map(rows.map((i) => [i.code, i]));

  tbody.innerHTML = rows.length === 0
    ? '<tr><td colspan="5" class="muted">No items found.</td></tr>'
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

function wireFactbox() {
  document.getElementById('itemTableBody').addEventListener('click', (e) => {
    const row = e.target.closest('tr[data-code]');
    if (!row) return;
    if (e.target.closest('a')) return; // let the existing "View (N)" variants link navigate normally
    openFactbox(row.dataset.code);
  });

  document.getElementById('factboxCloseBtn').addEventListener('click', closeFactbox);
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
  await loadVariantCounts();
  await loadItems();
})();
