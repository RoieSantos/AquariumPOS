// Variant Setup page logic (super users only, read-only view).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js).
//
// Supports navigating here from Item Setup with ?item=<Code> in the URL to drill down
// into just that item's linked variants (admin_list_variants' p_main_item_code exact
// filter); with no query param it behaves as a general searchable Variants browser.
let currentSession = null;
let variantSearchDebounceHandle = null;
let filterItemCode = null;
let currentSearch = '';
let currentPage = 1;
let currentPageSize = 50;
let loadGeneration = 0;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function renderVariantRows(variants) {
  const tbody = document.getElementById('variantTableBody');

  if (!variants || variants.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No variants found.</td></tr>';
    return;
  }

  tbody.innerHTML = variants
    .map((v) => `
      <tr>
        <td><a href="item-setup.html">${v.main_item_code || ''}</a></td>
        <td>${v.item_code || ''}</td>
        <td>${v.variant_name || ''}</td>
        <td>${v.sku || ''}</td>
        <td>${v.category_code || ''}</td>
        <td>${formatMoney(v.price)}</td>
        <td>${v.synced_at_utc ? new Date(v.synced_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
      </tr>
    `)
    .join('');
}

function renderFilterNote() {
  const note = document.getElementById('filterNote');
  const searchInput = document.getElementById('variantSearchInput');

  if (filterItemCode) {
    note.innerHTML = `Showing variants linked to item <strong>${filterItemCode}</strong> - <a href="variant-setup.html">Clear filter</a>`;
    searchInput.disabled = true;
    searchInput.value = '';
  } else {
    note.textContent = '';
    searchInput.disabled = false;
  }
}

async function loadVariants() {
  const tbody = document.getElementById('variantTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_variants', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: filterItemCode ? null : (currentSearch || null),
    p_main_item_code: filterItemCode || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (thisGeneration !== loadGeneration) return; // a newer search/page request superseded this one

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderVariantRows(data);

  renderPaginationBar(
    document.getElementById('variantPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadVariants(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadVariants(); }
    }
  );
}

function wireVariantSearch() {
  document.getElementById('variantSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(variantSearchDebounceHandle);
    variantSearchDebounceHandle = setTimeout(() => {
      currentSearch = value;
      currentPage = 1;
      loadVariants();
    }, 300);
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Variants');

  const params = new URLSearchParams(window.location.search);
  filterItemCode = params.get('item');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Variant Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  renderFilterNote();
  wireVariantSearch();
  await loadVariants();
})();
