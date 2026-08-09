// Category Setup page logic (super users only).
// Portal-only mirror of the local dbo.Category.IsProductionCategory flag - see the column
// comment in supabase_warehouses_items_tables.sql for why this isn't synced from the desktop.
let currentSession = null;

function renderCategoryRows(categories) {
  const tbody = document.getElementById('categoryTableBody');

  if (!categories || categories.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No categories found on any items yet.</td></tr>';
    return;
  }

  tbody.innerHTML = categories
    .map((c) => `
      <tr data-code="${encodeURIComponent(c.code)}">
        <td>${c.code}</td>
        <td>
          <input type="text" class="category-description-input" data-code="${encodeURIComponent(c.code)}" value="${c.description || ''}" style="width:220px;" />
        </td>
        <td>${c.item_count ?? 0}</td>
        <td><input type="checkbox" class="category-production-input" data-code="${encodeURIComponent(c.code)}" ${c.is_production_category ? 'checked' : ''} /></td>
        <td><input type="checkbox" class="category-exclude-input" data-code="${encodeURIComponent(c.code)}" ${c.exclude_in_transfer_orders ? 'checked' : ''} /></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('.category-production-input, .category-exclude-input').forEach((cb) => {
    cb.addEventListener('change', () => saveCategoryFlags(decodeURIComponent(cb.dataset.code)));
  });
  // Auto-saves on blur (not every keystroke) - the description field is free text, unlike the
  // checkbox which has an unambiguous "changed" event.
  tbody.querySelectorAll('.category-description-input').forEach((input) => {
    input.addEventListener('blur', () => saveCategoryFlags(decodeURIComponent(input.dataset.code)));
  });
}

async function saveCategoryFlags(code) {
  const row = document.querySelector(`tr[data-code="${encodeURIComponent(code)}"]`);
  const descriptionInput = row.querySelector('.category-description-input');
  const productionCb = row.querySelector('.category-production-input');
  const excludeCb = row.querySelector('.category-exclude-input');

  const { error } = await supabaseClient.rpc('admin_update_category_flags', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_code: code,
    p_description: descriptionInput.value.trim() || null,
    p_is_production_category: productionCb.checked,
    p_exclude_in_transfer_orders: excludeCb.checked
  });

  if (error) {
    window.alert(`Failed to save category: ${error.message}`);
    await loadCategories();
  }
}

async function loadCategories() {
  const tbody = document.getElementById('categoryTableBody');
  tbody.innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_categories', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="5" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderCategoryRows(data);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Category Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Category Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('refreshBtn').addEventListener('click', loadCategories);
  await loadCategories();
})();
