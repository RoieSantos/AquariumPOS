// General Setup page logic (super users only). Four separate things live here:
//   - Company Info / Letterhead (public.CompanyInfo, see supabase_company_info_table.sql) - logo
//     + name/Facebook/address/contact/DTI no., shown on printable pages and the Login page/
//     Dashboard (js/companyBranding.js).
//   - No. Series (public.NoSeries/NoSeriesLine, see supabase_no_series_tables.sql) - running-
//     number formats (Prefix/Padding/Starting No.) used to generate document numbers, e.g. the
//     Transfer Order Document No. (staff_next_transfer_no delegates to these).
//   - Secure API Keys (Supabase Vault, see supabase_secure_pancake_credentials.sql) - write-only:
//     admin_set_pancake_api_key never returns the value, admin_get_pancake_api_key_status only
//     ever returns whether it's set and when. Deliberately separate from the plain Settings table
//     below, which DOES send its raw values to the browser (see loadSettings/renderSettingsRows) -
//     fine for things meant to be public like GOOGLE_MAPS_API_KEY, wrong for a real secret.
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
  document.getElementById('companyEmailInput').value = info['Email'] || '';
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
    p_email: document.getElementById('companyEmailInput').value.trim() || null,
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

// Promotion banner shown on Order Now - public."PromotionSettings" (see
// supabase_promotion_setting.sql), same single-row shape/access model as CompanyInfo above.
async function loadPromotionSetting() {
  const { data, error } = await supabaseClient
    .from('PromotionSettings')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  const info = !error && data && data[0];
  document.getElementById('promoTextInput').value = (info && info['PromoText']) || '';
  document.getElementById('promoActiveInput').checked = !!(info && info['IsActive']);
}

async function savePromotionSetting() {
  const errorEl = document.getElementById('promoError');
  errorEl.classList.add('hidden');

  const { error } = await supabaseClient.rpc('admin_upsert_promotion_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_promo_text: document.getElementById('promoTextInput').value.trim() || null,
    p_is_active: document.getElementById('promoActiveInput').checked
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  await loadPromotionSetting();
}

// Item Ledger: Transfer Order posting on/off switch (supabase_item_ledger_transfer_posting_toggle.
// sql) - a real toggle for what was previously only reachable by disabling the underlying trigger
// by hand in the SQL editor.
async function loadTransferPostingSetting() {
  const { data, error } = await supabaseClient.rpc('admin_get_item_ledger_transfer_posting_enabled', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  // Not found (SQL not run yet) shouldn't block the rest of the page - default the checkbox to
  // checked (the feature's own default) and let Save surface the real error if they try to use it.
  document.getElementById('transferPostingEnabledInput').checked = error ? true : !!data;
}

async function saveTransferPostingSetting() {
  const errorEl = document.getElementById('transferPostingError');
  errorEl.classList.add('hidden');

  const { error } = await supabaseClient.rpc('admin_set_item_ledger_transfer_posting_enabled', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_enabled: document.getElementById('transferPostingEnabledInput').checked
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  await loadTransferPostingSetting();
}

// Online Orders proof photos on/off (read by onlineOrders.js proofPhotoRequired). Never saved -> on.
const PROOF_PHOTO_SETTINGS = {
  PROOF_PHOTO_PRODUCTION_DONE: { input: 'proofPhotoProductionInput', description: 'true = makers must take a photo on Production Done (Online Orders). Set from General Setup -> Online Orders - Proof Photos.' },
  PROOF_PHOTO_RELEASE: { input: 'proofPhotoReleaseInput', description: 'true = dispatchers must take a photo on Release / Mark Shipped (Online Orders). Set from General Setup -> Online Orders - Proof Photos.' }
};

async function loadProofPhotoSettings() {
  await Promise.all(Object.entries(PROOF_PHOTO_SETTINGS).map(async ([key, s]) => {
    const value = await getPublicSetting(key);
    document.getElementById(s.input).checked = String(value).trim().toLowerCase() !== 'false';
  }));
}

async function saveProofPhotoSettings() {
  const errorEl = document.getElementById('proofPhotoError');
  const noticeEl = document.getElementById('proofPhotoNotice');
  errorEl.classList.add('hidden');
  noticeEl.classList.add('hidden');
  const results = await Promise.all(Object.entries(PROOF_PHOTO_SETTINGS).map(([key, s]) =>
    supabaseClient.rpc('admin_upsert_portal_setting', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_setting_key: key,
      p_setting_value: document.getElementById(s.input).checked ? 'true' : 'false',
      p_description: s.description,
      p_is_public_to_staff: true
    })));
  const failed = results.find((r) => r.error);
  if (failed) {
    errorEl.textContent = failed.error.message;
    errorEl.classList.remove('hidden');
    return;
  }
  noticeEl.textContent = 'Saved. Applies to the next Production Done / Release - no reload needed.';
  noticeEl.classList.remove('hidden');
  await loadProofPhotoSettings();
  loadSettings();
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

// Barcode Printer - per "i have a barcode printer.. can we add a setup in the general setup? so
// everytime we print a barcode it will print on the barcode printer". Two PortalSettings rows
// (sql/supabase_barcode_printer_settings.sql), staff-readable so whoever prints can use them:
// BARCODE_PRINTER_NAME and QZ_CERTIFICATE (public cert - the private key is the qz-sign Edge Function's
// QZ_PRIVATE_KEY secret, never on this page). Printing itself is js/labelPrinter.js.
function showBarcodePrinterMessage(error, notice) {
  const errorEl = document.getElementById('barcodePrinterError');
  const noticeEl = document.getElementById('barcodePrinterNotice');
  errorEl.textContent = error || '';
  errorEl.classList.toggle('hidden', !error);
  noticeEl.textContent = notice || '';
  noticeEl.classList.toggle('hidden', !notice);
}

async function getPublicSetting(key) {
  const { data } = await supabaseClient.rpc('admin_get_public_portal_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_setting_key: key
  });
  return data || '';
}

async function loadBarcodePrinter() {
  LabelPrinter.init(currentSession);
  const [printer, certificate] = await Promise.all([getPublicSetting('BARCODE_PRINTER_NAME'), getPublicSetting('QZ_CERTIFICATE')]);
  document.getElementById('barcodePrinterInput').value = printer;
  document.getElementById('qzCertificateInput').value = certificate;
  fillLabelLayoutForm(await LabelPrinter.getLayout());
  refreshQzStatus(printer);
}

// ---- Label layout - per "how can we adjust the barcode printout?". Saved as JSON in PortalSettings
// BARCODE_LABEL_LAYOUT; js/labelPrinter.js applies it to every serial label (QZ Tray and dialog).
const LABEL_LAYOUT_FIELDS = {
  widthMm: 'llWidth', heightMm: 'llHeight', offsetXMm: 'llOffsetX', offsetYMm: 'llOffsetY',
  textScale: 'llTextScale', rotation: 'llRotation', barcodeHeightPct: 'llBarcodeHeight',
  barcodeWidthPct: 'llBarcodeWidth', descriptionLines: 'llDescLines', copies: 'llCopies'
};
const PREVIEW_LABEL = { serialNo: 'RS-AQ-042-26-000001', itemCode: 'AQ-042', sku: 'AQ-042-BLK', description: 'TEST AQUARIUM ONLY - Black' };

function fillLabelLayoutForm(layout) {
  Object.entries(LABEL_LAYOUT_FIELDS).forEach(([key, id]) => { document.getElementById(id).value = String(layout[key]); });
  document.getElementById('llShowItemCode').checked = layout.showItemCode;
  document.getElementById('llShowSku').checked = layout.showSku;
  document.getElementById('llShowDescription').checked = layout.showDescription;
  refreshLabelPreview();
}

function readLabelLayoutForm() {
  const layout = {};
  Object.entries(LABEL_LAYOUT_FIELDS).forEach(([key, id]) => { layout[key] = Number(document.getElementById(id).value); });
  layout.showItemCode = document.getElementById('llShowItemCode').checked;
  layout.showSku = document.getElementById('llShowSku').checked;
  layout.showDescription = document.getElementById('llShowDescription').checked;
  return LabelPrinter.normalizeLayout(layout);
}

let labelPreviewTimer = null;
function refreshLabelPreview() {
  clearTimeout(labelPreviewTimer);
  labelPreviewTimer = setTimeout(async () => {
    try {
      document.getElementById('labelPreview').src = await LabelPrinter.preview(PREVIEW_LABEL, readLabelLayoutForm());
    } catch (err) {
      console.error('Label preview failed:', err);
    }
  }, 150);
}

async function refreshQzStatus(printer) {
  const status = document.getElementById('qzStatus');
  const available = await LabelPrinter.isQzAvailable();
  status.textContent = available
    ? `QZ Tray is running on this PC.${printer ? ` Labels go to: ${printer}` : ' Pick the barcode printer below.'}`
    : 'QZ Tray is not running on this PC - install / start it (qz.io/download), then reload this page. Until then labels use the print dialog.';
  status.style.color = available ? 'var(--success)' : 'var(--danger, #b42318)';
}

async function findBarcodePrinters() {
  showBarcodePrinterMessage('', '');
  const printers = await LabelPrinter.listPrinters();
  if (!printers) { showBarcodePrinterMessage('QZ Tray is not running on this PC, so the printer list can\'t be read. Type the printer name instead.'); return; }
  const select = document.getElementById('barcodePrinterSelect');
  const current = document.getElementById('barcodePrinterInput').value.trim();
  select.innerHTML = '<option value="">(pick a printer)</option>';
  printers.forEach((p) => {
    const option = document.createElement('option');
    option.value = p;
    option.textContent = p;
    select.appendChild(option);
  });
  if (printers.includes(current)) select.value = current;
  showBarcodePrinterMessage('', `Found ${printers.length} printer(s) on this PC.`);
}

async function saveBarcodePrinter() {
  showBarcodePrinterMessage('', '');
  const printer = document.getElementById('barcodePrinterInput').value.trim();
  const certificate = document.getElementById('qzCertificateInput').value.trim();
  if (certificate && !certificate.includes('BEGIN CERTIFICATE')) {
    showBarcodePrinterMessage('That doesn\'t look like a certificate - paste the whole digital-certificate.txt (-----BEGIN CERTIFICATE----- ...). Never paste the private key here.');
    return;
  }
  const save = (key, value, description) => supabaseClient.rpc('admin_upsert_portal_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_setting_key: key,
    p_setting_value: value,
    p_description: description,
    p_is_public_to_staff: true
  });
  const results = await Promise.all([
    save('BARCODE_PRINTER_NAME', printer, 'Barcode / label printer name for serial labels (QZ Tray). Set from General Setup -> Barcode Printer.'),
    save('QZ_CERTIFICATE', certificate, 'Public certificate (PEM) QZ Tray trusts for silent printing. Its private key is the qz-sign Edge Function secret QZ_PRIVATE_KEY.'),
    save('BARCODE_LABEL_LAYOUT', JSON.stringify(readLabelLayoutForm()), 'Serial label layout (size, offset, rotation, text size...) as JSON. Edit from General Setup -> Barcode Printer -> Label layout.')
  ]);
  const failed = results.find((r) => r.error);
  if (failed) { showBarcodePrinterMessage(failed.error.message); return; }
  await LabelPrinter.reloadSettings();
  showBarcodePrinterMessage('', 'Saved. Serial labels will print to this printer.');
  refreshQzStatus(printer);
  loadSettings();
}

async function testBarcodePrinter() {
  showBarcodePrinterMessage('', '');
  await LabelPrinter.reloadSettings();
  // Uses the layout on screen (saved or not), so it can be tuned before saving.
  const result = await LabelPrinter.printSerialLabels([PREVIEW_LABEL], { layout: readLabelLayoutForm() });
  if (result.via === 'qz') showBarcodePrinterMessage('', result.message);
  else showBarcodePrinterMessage(result.message);
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

// ---- Secure API Keys (Supabase Vault) ----
// Deliberately the opposite shape of the plain Settings section below: status only ever reports
// whether a key is configured and when it was last set, never the key itself - see
// supabase_secure_pancake_credentials.sql's admin_get_pancake_api_key_status/admin_set_pancake_api_key.

async function loadPancakeApiKeyStatus() {
  const statusEl = document.getElementById('pancakeApiKeyStatus');
  statusEl.textContent = 'Loading status...';

  const { data, error } = await supabaseClient.rpc('admin_get_pancake_api_key_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    statusEl.textContent = `Could not load status - ${error.message}`;
    return;
  }

  const result = (data && data[0]) || {};
  statusEl.textContent = result.is_configured
    ? `Configured - last set ${new Date(result.updated_at_utc).toLocaleString()}`
    : 'Not configured yet.';
}

async function savePancakeApiKey() {
  const errorEl = document.getElementById('pancakeApiKeyError');
  const input = document.getElementById('pancakeApiKeyInput');
  const saveBtn = document.getElementById('savePancakeApiKeyBtn');
  errorEl.classList.add('hidden');

  const newKey = input.value.trim();
  if (!newKey) {
    errorEl.textContent = 'Paste the new key before saving.';
    errorEl.classList.remove('hidden');
    return;
  }

  if (!window.confirm('Save this as the new Pancake API key? Every Supabase function that talks to Pancake will use it immediately - make sure it\'s already active in Pancake\'s Partner Portal first.')) {
    return;
  }

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_set_pancake_api_key', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_new_key: newKey
    });

    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }

    // Clear the typed value right away - nothing should linger in the DOM/memory once it's saved.
    input.value = '';
    await loadPancakeApiKeyStatus();
  } finally {
    saveBtn.disabled = false;
  }
}

// PANCAKE_PUBLIC_API_KEY - the page_access_token used to send the automatic order-confirmation
// Messenger message (supabase_automated_orders_tables.sql's _send_order_confirmation_message).
// Same write-only/status-only shape as the Pancake Cloud API Key above - see
// supabase_secure_pancake_credentials.sql's admin_get_pancake_public_api_key_status/
// admin_set_pancake_public_api_key.

async function loadPancakePublicApiKeyStatus() {
  const statusEl = document.getElementById('pancakePublicApiKeyStatus');
  statusEl.textContent = 'Loading status...';

  const { data, error } = await supabaseClient.rpc('admin_get_pancake_public_api_key_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    statusEl.textContent = `Could not load status - ${error.message}`;
    return;
  }

  const result = (data && data[0]) || {};
  statusEl.textContent = result.is_configured
    ? `Configured - last set ${new Date(result.updated_at_utc).toLocaleString()}`
    : 'Not configured yet.';
}

async function savePancakePublicApiKey() {
  const errorEl = document.getElementById('pancakePublicApiKeyError');
  const input = document.getElementById('pancakePublicApiKeyInput');
  const saveBtn = document.getElementById('savePancakePublicApiKeyBtn');
  errorEl.classList.add('hidden');

  const newKey = input.value.trim();
  if (!newKey) {
    errorEl.textContent = 'Paste the new key before saving.';
    errorEl.classList.remove('hidden');
    return;
  }

  // This key is a JWT (header.payload.signature, e.g. matching the desktop app's
  // GlobalSettings.PublicApiKey) - real-world mistake already hit once: pasting only up to the
  // first "." saved just the 36-char header segment, which Pancake then rejected with
  // "Invalid access_token" even though the request/endpoint were otherwise correct. A valid JWT
  // always has exactly 2 dots and is well over 100 characters, so catch a truncated paste here
  // instead of silently saving a fragment.
  const dotCount = (newKey.match(/\./g) || []).length;
  if (dotCount !== 2 || newKey.length < 100) {
    errorEl.textContent = `That doesn't look like a complete JWT (expected header.payload.signature, ~150+ characters with 2 dots - got ${newKey.length} characters and ${dotCount} dot${dotCount === 1 ? '' : 's'}). Make sure you copied the ENTIRE token, not just part of it, then try again.`;
    errorEl.classList.remove('hidden');
    return;
  }

  if (!window.confirm('Save this as the new Pancake Messenger API key? The automatic order-confirmation message will use it immediately.')) {
    return;
  }

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_set_pancake_public_api_key', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_new_key: newKey
    });

    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }

    input.value = '';
    await loadPancakePublicApiKeyStatus();
  } finally {
    saveBtn.disabled = false;
  }
}

// TELEGRAM_BOT_TOKEN - sends a Telegram message when an online order gets confirmed (see
// supabase_telegram_notifications.sql's trigger on OnlineOrders). Same write-only/status-only
// shape as the Pancake keys above. The other half of setup - TELEGRAM_CHAT_ID - isn't a secret,
// so it's just a normal row in the plain Settings table further down this page, not handled here.

async function loadTelegramBotTokenStatus() {
  const statusEl = document.getElementById('telegramBotTokenStatus');
  statusEl.textContent = 'Loading status...';

  const { data, error } = await supabaseClient.rpc('admin_get_telegram_bot_token_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    statusEl.textContent = `Could not load status - ${error.message}`;
    return;
  }

  const result = (data && data[0]) || {};
  statusEl.textContent = result.is_configured
    ? `Configured - last set ${new Date(result.updated_at_utc).toLocaleString()}`
    : 'Not configured yet.';
}

async function saveTelegramBotToken() {
  const errorEl = document.getElementById('telegramBotTokenError');
  const input = document.getElementById('telegramBotTokenInput');
  const saveBtn = document.getElementById('saveTelegramBotTokenBtn');
  errorEl.classList.add('hidden');

  const newToken = input.value.trim();
  if (!newToken) {
    errorEl.textContent = 'Paste the new bot token before saving.';
    errorEl.classList.remove('hidden');
    return;
  }

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_set_telegram_bot_token', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_new_token: newToken
    });

    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }

    input.value = '';
    await loadTelegramBotTokenStatus();
  } finally {
    saveBtn.disabled = false;
  }
}

async function testTelegramNotification() {
  const resultEl = document.getElementById('telegramTestResult');
  const testBtn = document.getElementById('testTelegramNotificationBtn');
  resultEl.classList.remove('hidden');
  resultEl.textContent = 'Sending...';
  testBtn.disabled = true;

  try {
    const { data, error } = await supabaseClient.rpc('admin_test_telegram_notification', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password
    });

    if (error) {
      resultEl.textContent = `Failed: ${error.message}`;
      return;
    }

    const result = (data && data[0]) || {};
    resultEl.textContent = result.ok
      ? 'Sent - check your Telegram chat.'
      : `Failed (HTTP ${result.http_status ?? 'n/a'}): ${result.response_body || 'no response'}`;
  } finally {
    testBtn.disabled = false;
  }
}

// Web Push - shows how many devices are subscribed (admin_list_push_subscriptions) and offers a
// test send (admin_test_web_push) - see supabase_web_push_subscriptions.sql /
// supabase_web_push_order_confirmed_trigger.sql. Enabling/disabling itself happens per-device from
// the Dashboard's "Enable Order Notifications" button (js/pushNotifications.js), not here.

async function loadWebPushSubscriberCount() {
  const el = document.getElementById('webPushSubscriberCount');
  el.textContent = 'Loading...';

  const { data, error } = await supabaseClient.rpc('admin_list_push_subscriptions', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    el.textContent = `Could not load status - ${error.message}`;
    return;
  }

  const count = (data || []).length;
  el.textContent = count === 0
    ? 'No devices subscribed yet.'
    : `${count} device${count === 1 ? '' : 's'} subscribed.`;
}

async function testWebPush() {
  const resultEl = document.getElementById('webPushTestResult');
  const testBtn = document.getElementById('testWebPushBtn');
  resultEl.classList.remove('hidden');
  resultEl.textContent = 'Sending...';
  testBtn.disabled = true;

  try {
    const { data, error } = await supabaseClient.rpc('admin_test_web_push', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password
    });

    if (error) {
      resultEl.textContent = `Failed: ${error.message}`;
      return;
    }

    const result = (data && data[0]) || {};
    resultEl.textContent = result.ok
      ? 'Sent - check the subscribed device(s).'
      : `Failed (HTTP ${result.http_status ?? 'n/a'}): ${result.response_body || 'no response'}`;
  } finally {
    testBtn.disabled = false;
  }
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
  document.getElementById('savePromoBtn').addEventListener('click', savePromotionSetting);
  document.getElementById('saveTransferPostingBtn').addEventListener('click', saveTransferPostingSetting);
  document.getElementById('saveProofPhotoBtn').addEventListener('click', saveProofPhotoSettings);
  document.getElementById('saveNoSeriesBtn').addEventListener('click', saveNoSeries);
  document.getElementById('cancelNoSeriesEditBtn').addEventListener('click', resetNoSeriesForm);
  document.getElementById('savePancakeApiKeyBtn').addEventListener('click', savePancakeApiKey);
  document.getElementById('savePancakePublicApiKeyBtn').addEventListener('click', savePancakePublicApiKey);
  document.getElementById('saveTelegramBotTokenBtn').addEventListener('click', saveTelegramBotToken);
  document.getElementById('testTelegramNotificationBtn').addEventListener('click', testTelegramNotification);
  document.getElementById('testWebPushBtn').addEventListener('click', testWebPush);
  document.getElementById('findPrintersBtn').addEventListener('click', findBarcodePrinters);
  document.getElementById('barcodePrinterSelect').addEventListener('change', (e) => {
    if (e.target.value) document.getElementById('barcodePrinterInput').value = e.target.value;
  });
  document.getElementById('saveBarcodePrinterBtn').addEventListener('click', saveBarcodePrinter);
  document.getElementById('testBarcodePrinterBtn').addEventListener('click', testBarcodePrinter);
  [...Object.values(LABEL_LAYOUT_FIELDS), 'llShowItemCode', 'llShowSku', 'llShowDescription'].forEach((id) => {
    document.getElementById(id).addEventListener('input', refreshLabelPreview);
    document.getElementById(id).addEventListener('change', refreshLabelPreview);
  });
  document.getElementById('resetLabelLayoutBtn').addEventListener('click', () => fillLabelLayoutForm(LabelPrinter.normalizeLayout({})));
  populateNoSeriesCodeOptions();

  await loadCompanyInfo();
  await loadPromotionSetting();
  await loadTransferPostingSetting();
  await loadProofPhotoSettings();
  await loadNoSeries();
  await loadPancakeApiKeyStatus();
  await loadPancakePublicApiKeyStatus();
  await loadTelegramBotTokenStatus();
  await loadWebPushSubscriberCount();
  await loadBarcodePrinter();
  await loadSettings();
})();
