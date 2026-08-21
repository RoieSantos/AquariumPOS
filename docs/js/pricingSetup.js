// Pricing Setup page logic (super users only). Edits the three tables that centralize Glass/
// Stand-Tubular/Sticker pricing (see supabase_pricing_setup_tables.sql) - these used to be
// hardcoded/duplicated across the desktop app and two separate web files that had drifted apart
// (e.g. 3mm glass was priced 4 different ways before this). A save here shows up immediately in
// Order Now and the Portal calculators (both read the public_get_*_pricing RPCs live), and will
// show up in the desktop app too once it's updated to read the same tables instead of its own
// hardcoded constants.
let currentSession = null;

function formatUpdated(row) {
  if (!row.updated_at_utc) return '<span class="muted">Never</span>';
  return new Date(row.updated_at_utc).toLocaleString();
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ---- Glass Thickness Pricing ----

async function loadGlassPricing() {
  const tbody = document.getElementById('glassPricingTableBody');
  tbody.innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_glass_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="5" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No rows yet.</td></tr>';
    return;
  }

  tbody.innerHTML = data
    .map((row) => `
      <tr data-thickness="${escapeHtml(row.thickness)}">
        <td>${escapeHtml(row.thickness)}mm</td>
        <td><input type="number" min="0" step="0.01" value="${row.price_per_sqft}" class="pricing-input" style="max-width:120px;" /></td>
        <td>${formatUpdated(row)}</td>
        <td>${escapeHtml(row.updated_by) || '<span class="muted">-</span>'}</td>
        <td><button class="btn btn-success btn-sm" type="button" data-action="save">Save</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('button[data-action="save"]').forEach((btn) => {
    btn.addEventListener('click', () => saveGlassPricing(btn.closest('tr')));
  });
}

async function saveGlassPricing(row) {
  const thickness = row.dataset.thickness;
  const input = row.querySelector('.pricing-input');
  const price = Number(input.value);
  if (!(price >= 0)) {
    alert('Enter a valid non-negative price.');
    return;
  }

  const btn = row.querySelector('button[data-action="save"]');
  btn.disabled = true;
  btn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_upsert_glass_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_thickness: thickness,
    p_price_per_sqft: price
  });

  if (error) {
    alert(`Failed to save: ${error.message}`);
    btn.disabled = false;
    btn.textContent = 'Save';
    return;
  }

  await loadGlassPricing();
}

// ---- Stand Tubular Pricing ----

async function loadTubularPricing() {
  const tbody = document.getElementById('tubularPricingTableBody');
  tbody.innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_tubular_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="5" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No rows yet.</td></tr>';
    return;
  }

  tbody.innerHTML = data
    .map((row) => `
      <tr data-size="${escapeHtml(row.tubular_size)}">
        <td>${escapeHtml(row.tubular_size)}</td>
        <td><input type="number" min="0" step="0.01" value="${row.price_per_ft}" class="pricing-input" style="max-width:120px;" /></td>
        <td>${formatUpdated(row)}</td>
        <td>${escapeHtml(row.updated_by) || '<span class="muted">-</span>'}</td>
        <td><button class="btn btn-success btn-sm" type="button" data-action="save">Save</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('button[data-action="save"]').forEach((btn) => {
    btn.addEventListener('click', () => saveTubularPricing(btn.closest('tr')));
  });
}

async function saveTubularPricing(row) {
  const size = row.dataset.size;
  const input = row.querySelector('.pricing-input');
  const price = Number(input.value);
  if (!(price >= 0)) {
    alert('Enter a valid non-negative price.');
    return;
  }

  const btn = row.querySelector('button[data-action="save"]');
  btn.disabled = true;
  btn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_upsert_tubular_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_tubular_size: size,
    p_price_per_ft: price
  });

  if (error) {
    alert(`Failed to save: ${error.message}`);
    btn.disabled = false;
    btn.textContent = 'Save';
    return;
  }

  await loadTubularPricing();
}

// ---- Accessory / Sticker Pricing ----

function stickerThicknessLabel(row) {
  if (row.sticker_type === 'Rubber Matting') {
    return row.thickness ? `${row.thickness}mm` : 'Base / fallback';
  }
  return '<span class="muted">-</span>';
}

async function loadStickerPricing() {
  const tbody = document.getElementById('stickerPricingTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_sticker_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="6" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No rows yet.</td></tr>';
    return;
  }

  tbody.innerHTML = data
    .map((row, index) => `
      <tr data-index="${index}" data-type="${escapeHtml(row.sticker_type)}" data-thickness="${escapeHtml(row.thickness || '')}">
        <td>${escapeHtml(row.sticker_type)}</td>
        <td>${stickerThicknessLabel(row)}</td>
        <td><input type="number" min="0" step="0.01" value="${row.price_per_sqft}" class="pricing-input" style="max-width:120px;" /></td>
        <td>${formatUpdated(row)}</td>
        <td>${escapeHtml(row.updated_by) || '<span class="muted">-</span>'}</td>
        <td><button class="btn btn-success btn-sm" type="button" data-action="save">Save</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('button[data-action="save"]').forEach((btn) => {
    btn.addEventListener('click', () => saveStickerPricing(btn.closest('tr')));
  });
}

async function saveStickerPricing(row) {
  const type = row.dataset.type;
  const thickness = row.dataset.thickness || null;
  const input = row.querySelector('.pricing-input');
  const price = Number(input.value);
  if (!(price >= 0)) {
    alert('Enter a valid non-negative price.');
    return;
  }

  const btn = row.querySelector('button[data-action="save"]');
  btn.disabled = true;
  btn.textContent = 'Saving...';

  const { error } = await supabaseClient.rpc('admin_upsert_sticker_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_sticker_type: type,
    p_thickness: thickness,
    p_price_per_sqft: price
  });

  if (error) {
    alert(`Failed to save: ${error.message}`);
    btn.disabled = false;
    btn.textContent = 'Save';
    return;
  }

  await loadStickerPricing();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Pricing Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for anyone
    // already logged in before this update) - a fresh login resolves it, same as General Setup.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Pricing Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('refreshGlassBtn').addEventListener('click', loadGlassPricing);
  document.getElementById('refreshTubularBtn').addEventListener('click', loadTubularPricing);
  document.getElementById('refreshStickerBtn').addEventListener('click', loadStickerPricing);

  await loadGlassPricing();
  await loadTubularPricing();
  await loadStickerPricing();
})();
