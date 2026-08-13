// General Setup page logic (super users only). Three separate things live here:
//   - Company Info / Letterhead (public.CompanyInfo, see supabase_company_info_table.sql) - logo
//     + name/Facebook/address/contact/DTI no., shown on printable pages and the Login page/
//     Dashboard (js/companyBranding.js).
//   - No. Series (public.NoSeries/NoSeriesLine, see supabase_no_series_tables.sql) - running-
//     number formats (Prefix/Padding/Starting No.) used to generate document numbers, e.g. the
//     Transfer Order Document No. (staff_next_transfer_no delegates to these).
//   - Generic key/value settings (public.PortalSettings, e.g. GOOGLE_MAPS_API_KEY).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Online Orders/Expenses (reuses the password captured at login, session.password, see
// auth.js).
let currentSession = null;
let editingKey = null; // non-null while the form is editing an existing row rather than adding
let currentPage = 1;
let currentPageSize = 50;
let editingSeriesCode = null; // non-null while the No. Series form is editing an existing row

const COMPANY_ASSET_MAX_BYTES = 5 * 1024 * 1024;
let currentLogoUrl = null; // null until loaded from/uploaded to CompanyInfo
let currentBackgroundUrl = null; // same, for the Login page background image

// Company Info / Letterhead: public."CompanyInfo" (see supabase_company_info_table.sql), read
// directly here (RLS allows any authenticated caller, same as the anon-readable pattern used for
// Login/Dashboard/print pages - see js/companyBranding.js) and written through the
// is_admin_authorized-gated admin_upsert_company_info() RPC.
function setAssetPreview(imgId, emptyId, url) {
  const img = document.getElementById(imgId);
  const empty = document.getElementById(emptyId);
  if (url) {
    img.src = url;
    img.classList.remove('hidden');
    empty.classList.add('hidden');
  } else {
    img.classList.add('hidden');
    empty.classList.remove('hidden');
  }
}

async function loadCompanyInfo() {
  const { data, error } = await supabaseClient
    .from('CompanyInfo')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  if (error || !data || data.length === 0) {
    currentLogoUrl = null;
    currentBackgroundUrl = null;
    setAssetPreview('logoPreview', 'logoPreviewEmpty', null);
    setAssetPreview('backgroundPreview', 'backgroundPreviewEmpty', null);
    return;
  }

  const info = data[0];
  currentLogoUrl = info['LogoUrl'] || null;
  currentBackgroundUrl = info['BackgroundImageUrl'] || null;
  setAssetPreview('logoPreview', 'logoPreviewEmpty', currentLogoUrl);
  setAssetPreview('backgroundPreview', 'backgroundPreviewEmpty', currentBackgroundUrl);

  document.getElementById('companyNameInput').value = info['CompanyName'] || '';
  document.getElementById('companyFacebookInput').value = info['FacebookUrl'] || '';
  document.getElementById('companyAddressInput').value = info['Address'] || '';
  document.getElementById('companyContactNoInput').value = info['ContactNo'] || '';
  document.getElementById('companyDtiNoInput').value = info['DtiNo'] || '';
  document.getElementById('companyTinNoInput').value = info['TinNo'] || '';
}

// overrides.logoUrl/backgroundUrl are passed right after a fresh upload (uploadCompanyAsset) so
// the new asset saves immediately without requiring a separate "Save" click; the Save Company
// Info button calls this with no overrides, persisting whatever's already loaded plus the text
// fields.
async function saveCompanyInfo(overrides) {
  overrides = overrides || {};
  const errorEl = document.getElementById('logoError');
  errorEl.classList.add('hidden');

  const { error } = await supabaseClient.rpc('admin_upsert_company_info', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_logo_url: 'logoUrl' in overrides ? overrides.logoUrl : currentLogoUrl,
    p_background_image_url: 'backgroundUrl' in overrides ? overrides.backgroundUrl : currentBackgroundUrl,
    p_company_name: document.getElementById('companyNameInput').value.trim() || null,
    p_facebook_url: document.getElementById('companyFacebookInput').value.trim() || null,
    p_address: document.getElementById('companyAddressInput').value.trim() || null,
    p_contact_no: document.getElementById('companyContactNoInput').value.trim() || null,
    p_dti_no: document.getElementById('companyDtiNoInput').value.trim() || null,
    p_tin_no: document.getElementById('companyTinNoInput').value.trim() || null
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  await loadCompanyInfo();
}

// Shared upload flow for both the logo and the Login page background image - only the RPC name,
// which CompanyInfo field the result overrides, and which UI elements to update differ.
async function uploadCompanyAsset({ fileInputId, uploadBtnId, uploadBtnLabel, rpcName, overrideKey, assetLabel }) {
  const errorEl = document.getElementById('logoError');
  errorEl.classList.add('hidden');

  const fileInput = document.getElementById(fileInputId);
  const file = fileInput.files && fileInput.files[0];
  if (!file) {
    errorEl.textContent = 'Choose an image file first.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (file.size > COMPANY_ASSET_MAX_BYTES) {
    errorEl.textContent = 'That file is too large - max 5 MB.';
    errorEl.classList.remove('hidden');
    return;
  }

  const uploadBtn = document.getElementById(uploadBtnId);
  uploadBtn.disabled = true;
  uploadBtn.textContent = 'Uploading...';

  try {
    const { data: uploadRows, error: signError } = await supabaseClient.rpc(rpcName, {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_file_name: file.name
    });

    const uploadInfo = uploadRows && uploadRows[0];
    if (signError || !uploadInfo) {
      throw signError || new Error('Could not prepare upload.');
    }

    const { error: uploadError } = await supabaseClient.storage
      .from('portal-assets')
      .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, file, { upsert: true });
    if (uploadError) throw uploadError;

    // Cache-bust: the object path never changes between uploads (upsert=true), so without this
    // every page that already cached the old image at that same URL would keep showing it.
    const cacheBustedUrl = `${uploadInfo.public_url}?v=${Date.now()}`;

    fileInput.value = '';
    await saveCompanyInfo({ [overrideKey]: cacheBustedUrl });
  } catch (err) {
    errorEl.textContent = err?.message || `Failed to upload ${assetLabel}.`;
    errorEl.classList.remove('hidden');
  } finally {
    uploadBtn.disabled = false;
    uploadBtn.textContent = uploadBtnLabel;
  }
}

function handleUploadLogo() {
  return uploadCompanyAsset({
    fileInputId: 'logoFileInput',
    uploadBtnId: 'uploadLogoBtn',
    uploadBtnLabel: 'Upload Logo',
    rpcName: 'admin_create_portal_logo_upload',
    overrideKey: 'logoUrl',
    assetLabel: 'logo'
  });
}

function handleUploadBackground() {
  return uploadCompanyAsset({
    fileInputId: 'backgroundFileInput',
    uploadBtnId: 'uploadBackgroundBtn',
    uploadBtnLabel: 'Upload Background',
    rpcName: 'admin_create_portal_background_upload',
    overrideKey: 'backgroundUrl',
    assetLabel: 'background image'
  });
}

// No. Series - running-number setups. No pagination (a handful of rows expected), unlike
// Settings below which can grow large.
//
// Document Table picker: deliberately a curated list, not a live query against the database's
// table list - a No. Series row is only useful if some RPC actually reads it (right now, only
// staff_next_transfer_no reads the 'TRANSFER-ORDER' series - see supabase_no_series_tables.sql /
// supabase_warehouses_items_tables.sql). Add an entry here only once a matching document type is
// actually wired up to pull its number from NoSeries, so the dropdown never offers a code that
// silently does nothing.
const NO_SERIES_TABLE_OPTIONS = [
  { code: 'TRANSFER-ORDER', label: 'Transfer Order (Transfer_Header)' }
];

function noSeriesTableLabel(code) {
  const known = NO_SERIES_TABLE_OPTIONS.find((o) => o.code === code);
  return known ? known.label : code;
}

function populateNoSeriesCodeOptions() {
  const select = document.getElementById('noSeriesCodeInput');
  select.innerHTML = NO_SERIES_TABLE_OPTIONS
    .map((o) => `<option value="${o.code}">${o.label}</option>`)
    .join('');
}

function renderNoSeriesRows(seriesList) {
  const tbody = document.getElementById('noSeriesTableBody');

  if (!seriesList || seriesList.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No series set up yet.</td></tr>';
    return;
  }

  tbody.innerHTML = seriesList
    .map((s) => `
      <tr data-code="${s.series_code}">
        <td>${noSeriesTableLabel(s.series_code)}</td>
        <td>${s.description || ''}</td>
        <td>${s.prefix || ''}</td>
        <td>${s.padding}</td>
        <td>${s.starting_no}</td>
        <td><span class="badge ${s.warehouse_scoped ? 'badge-success' : 'badge-neutral'}">${s.warehouse_scoped ? 'Yes' : 'No'}</span></td>
        <td><button class="btn btn-secondary btn-sm" data-action="edit" type="button">Edit</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('button[data-action="edit"]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const row = btn.closest('tr');
      const series = seriesList.find((s) => s.series_code === row.dataset.code);
      startEditNoSeries(series);
    });
  });
}

async function loadNoSeries() {
  const tbody = document.getElementById('noSeriesTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_no_series', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderNoSeriesRows(data);
}

function startEditNoSeries(series) {
  editingSeriesCode = series.series_code;
  document.getElementById('noSeriesFormTitle').textContent = `Edit No. Series: ${noSeriesTableLabel(series.series_code)}`;

  const codeSelect = document.getElementById('noSeriesCodeInput');
  populateNoSeriesCodeOptions();
  if (!NO_SERIES_TABLE_OPTIONS.some((o) => o.code === series.series_code)) {
    // Legacy/no-longer-listed code - keep it selectable so editing an existing row never looks
    // broken, even though it can't be picked again from Add mode.
    codeSelect.insertAdjacentHTML('beforeend', `<option value="${series.series_code}">${series.series_code}</option>`);
  }
  codeSelect.value = series.series_code;
  codeSelect.disabled = true;
  document.getElementById('noSeriesDescriptionInput').value = series.description || '';
  document.getElementById('noSeriesPrefixInput').value = series.prefix || '';
  document.getElementById('noSeriesPaddingInput').value = series.padding;
  document.getElementById('noSeriesStartingNoInput').value = series.starting_no;
  document.getElementById('noSeriesWarehouseScopedInput').checked = !!series.warehouse_scoped;
  document.getElementById('cancelNoSeriesEditBtn').classList.remove('hidden');
  document.getElementById('noSeriesFormError').classList.add('hidden');
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function resetNoSeriesForm() {
  editingSeriesCode = null;
  document.getElementById('noSeriesFormTitle').textContent = 'Add No. Series';
  populateNoSeriesCodeOptions();
  document.getElementById('noSeriesCodeInput').disabled = false;
  document.getElementById('noSeriesDescriptionInput').value = '';
  document.getElementById('noSeriesPrefixInput').value = '';
  document.getElementById('noSeriesPaddingInput').value = '4';
  document.getElementById('noSeriesStartingNoInput').value = '1';
  document.getElementById('noSeriesWarehouseScopedInput').checked = false;
  document.getElementById('cancelNoSeriesEditBtn').classList.add('hidden');
  document.getElementById('noSeriesFormError').classList.add('hidden');
}

async function saveNoSeries() {
  const errorEl = document.getElementById('noSeriesFormError');
  errorEl.classList.add('hidden');

  const seriesCode = editingSeriesCode || document.getElementById('noSeriesCodeInput').value;
  if (!seriesCode) {
    errorEl.textContent = 'Choose a Document Table.';
    errorEl.classList.remove('hidden');
    return;
  }

  const { error } = await supabaseClient.rpc('admin_upsert_no_series', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_series_code: seriesCode,
    p_description: document.getElementById('noSeriesDescriptionInput').value.trim() || null,
    p_prefix: document.getElementById('noSeriesPrefixInput').value.trim() || '',
    p_padding: Number(document.getElementById('noSeriesPaddingInput').value) || 4,
    p_starting_no: Number(document.getElementById('noSeriesStartingNoInput').value) || 0,
    p_warehouse_scoped: document.getElementById('noSeriesWarehouseScopedInput').checked
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  resetNoSeriesForm();
  await loadNoSeries();
}

function maskValue(value) {
  if (!value) return '<span class="muted">(empty)</span>';
  if (value.length <= 4) return '&bull;'.repeat(value.length);
  return '&bull;'.repeat(value.length - 4) + value.slice(-4);
}

function renderSettingsRows(settings) {
  const tbody = document.getElementById('settingsTableBody');

  if (!settings || settings.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No settings yet.</td></tr>';
    return;
  }

  tbody.innerHTML = settings
    .map((s) => `
      <tr data-key="${s.setting_key}">
        <td>${s.setting_key}</td>
        <td>
          <span class="setting-value-masked">${maskValue(s.setting_value)}</span>
          <span class="setting-value-plain hidden"></span>
          <button class="btn btn-secondary btn-sm" data-action="toggle-reveal" type="button">Show</button>
        </td>
        <td>${s.description || ''}</td>
        <td><span class="badge ${s.is_public_to_staff ? 'badge-success' : 'badge-neutral'}">${s.is_public_to_staff ? 'Yes' : 'No'}</span></td>
        <td>${s.updated_at_utc ? new Date(s.updated_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
        <td>
          <button class="btn btn-secondary btn-sm" data-action="edit" type="button">Edit</button>
          <button class="btn btn-danger btn-sm" data-action="delete" type="button">Delete</button>
        </td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('button[data-action="toggle-reveal"]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const row = btn.closest('tr');
      const setting = settings.find((s) => s.setting_key === row.dataset.key);
      const maskedEl = row.querySelector('.setting-value-masked');
      const plainEl = row.querySelector('.setting-value-plain');
      const revealed = !plainEl.classList.contains('hidden');
      if (revealed) {
        plainEl.classList.add('hidden');
        maskedEl.classList.remove('hidden');
        btn.textContent = 'Show';
      } else {
        plainEl.textContent = setting.setting_value || '(empty)';
        plainEl.classList.remove('hidden');
        maskedEl.classList.add('hidden');
        btn.textContent = 'Hide';
      }
    });
  });

  tbody.querySelectorAll('button[data-action="edit"]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const row = btn.closest('tr');
      const setting = settings.find((s) => s.setting_key === row.dataset.key);
      startEdit(setting);
    });
  });

  tbody.querySelectorAll('button[data-action="delete"]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const row = btn.closest('tr');
      deleteSetting(row.dataset.key);
    });
  });
}

async function loadSettings() {
  const tbody = document.getElementById('settingsTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_portal_settings', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderSettingsRows(data);

  renderPaginationBar(
    document.getElementById('settingsPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadSettings(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadSettings(); }
    }
  );
}

function startEdit(setting) {
  editingKey = setting.setting_key;
  document.getElementById('formTitle').textContent = `Edit Setting: ${setting.setting_key}`;
  document.getElementById('settingKeyInput').value = setting.setting_key;
  document.getElementById('settingKeyInput').disabled = true;
  document.getElementById('settingValueInput').value = setting.setting_value || '';
  document.getElementById('settingDescriptionInput').value = setting.description || '';
  document.getElementById('settingPublicInput').checked = !!setting.is_public_to_staff;
  document.getElementById('cancelEditBtn').classList.remove('hidden');
  document.getElementById('settingFormError').classList.add('hidden');
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function resetForm() {
  editingKey = null;
  document.getElementById('formTitle').textContent = 'Add Setting';
  document.getElementById('settingKeyInput').value = '';
  document.getElementById('settingKeyInput').disabled = false;
  document.getElementById('settingValueInput').value = '';
  document.getElementById('settingDescriptionInput').value = '';
  document.getElementById('settingPublicInput').checked = false;
  document.getElementById('cancelEditBtn').classList.add('hidden');
  document.getElementById('settingFormError').classList.add('hidden');
}

async function saveSetting() {
  const errorEl = document.getElementById('settingFormError');
  errorEl.classList.add('hidden');

  const key = editingKey || document.getElementById('settingKeyInput').value.trim();
  const value = document.getElementById('settingValueInput').value;
  const description = document.getElementById('settingDescriptionInput').value.trim();
  const isPublic = document.getElementById('settingPublicInput').checked;

  if (!key) {
    errorEl.textContent = 'Setting key is required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const { error } = await supabaseClient.rpc('admin_upsert_portal_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_setting_key: key,
    p_setting_value: value,
    p_description: description || null,
    p_is_public_to_staff: isPublic
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  resetForm();
  await loadSettings();
}

async function deleteSetting(key) {
  if (!window.confirm(`Delete setting "${key}"? Any page relying on it will stop working.`)) return;

  const { error } = await supabaseClient.rpc('admin_delete_portal_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_setting_key: key
  });

  if (error) {
    console.error('admin_delete_portal_setting failed:', error);
    return;
  }

  if (editingKey === key) resetForm();
  await loadSettings();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('General Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view General Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('saveSettingBtn').addEventListener('click', saveSetting);
  document.getElementById('cancelEditBtn').addEventListener('click', resetForm);
  document.getElementById('uploadLogoBtn').addEventListener('click', handleUploadLogo);
  document.getElementById('uploadBackgroundBtn').addEventListener('click', handleUploadBackground);
  document.getElementById('saveCompanyInfoBtn').addEventListener('click', () => saveCompanyInfo());
  document.getElementById('saveNoSeriesBtn').addEventListener('click', saveNoSeries);
  document.getElementById('cancelNoSeriesEditBtn').addEventListener('click', resetNoSeriesForm);
  populateNoSeriesCodeOptions();

  await loadCompanyInfo();
  await loadNoSeries();
  await loadSettings();
})();
