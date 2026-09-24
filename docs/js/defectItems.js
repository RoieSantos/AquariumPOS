// Defect Items - a store manager (or super user) reports a broken/defective item with a photo; a
// super user approves or rejects it, and only an approved report removes the stock from the Item
// Ledger (supabase_defect_reports.sql). Nothing here writes the ledger directly - every action goes
// through an RPC that re-checks who is calling.
let currentSession = null;
let selectedItem = null; // { code, name }
let currentStatus = 'Pending';
let currentPage = 1;
const PAGE_SIZE = 25;
let searchDebounceHandle = null;
let itemSearchDebounceHandle = null;
let photoBlob = null;
let photoFileName = 'photo.jpg';

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatQty(value) {
  return Number(value).toLocaleString(undefined, { maximumFractionDigits: 4 });
}

function showFormError(message) {
  const el = document.getElementById('formError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function showListError(message) {
  const el = document.getElementById('listError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function creds() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

// ---------------------------------------------------------------- location

async function loadLocations() {
  const select = document.getElementById('locationSelect');
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', { ...creds(), p_search: null, p_limit: 100 });
  const warehouses = error || !data ? [] : data;

  if (currentSession.isSuperUser) {
    select.innerHTML = warehouses.map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
    const own = warehouses.find((w) => (w.name || '').toLowerCase() === (currentSession.warehouseName || '').toLowerCase());
    if (own) select.value = own.id;
    return;
  }

  // A store manager reports only against their own location.
  const own = warehouses.find((w) => (w.name || '').toLowerCase() === (currentSession.warehouseName || '').toLowerCase());
  if (own) {
    select.innerHTML = `<option value="${escapeHtml(own.id)}">${escapeHtml(own.name)}</option>`;
  } else {
    select.innerHTML = '<option value="">No location assigned to your account</option>';
  }
  select.disabled = true;
}

// ---------------------------------------------------------------- item + variant pickers

async function searchItems(term) {
  const { data, error } = await supabaseClient.rpc('staff_search_items', { ...creds(), p_search: term, p_limit: 15 });
  return error ? [] : (data || []);
}

function renderItemHits(hits) {
  const box = document.getElementById('itemHits');
  if (hits.length === 0) {
    box.innerHTML = '<div class="item-hit muted">No items found.</div>';
  } else {
    box.innerHTML = hits.map((h) =>
      `<div class="item-hit" data-code="${escapeHtml(h.code)}" data-name="${escapeHtml(h.name)}">${escapeHtml(h.code)} - ${escapeHtml(h.name)}</div>`
    ).join('');
  }
  box.classList.remove('hidden');
}

async function chooseItem(code, name) {
  selectedItem = { code, name };
  document.getElementById('itemHits').classList.add('hidden');
  document.getElementById('itemSearchInput').value = '';
  document.getElementById('itemChosen').textContent = `Selected: ${code} - ${name}`;

  // A transfer/ledger movement must name the variant when an item has several; one variant is used
  // as-is, none means the item itself.
  const variantField = document.getElementById('variantField');
  const variantSelect = document.getElementById('variantSelect');
  variantSelect.innerHTML = '';
  variantField.classList.add('hidden');
  const { data } = await supabaseClient.rpc('staff_search_variants', { ...creds(), p_item_code: code, p_page: 1 });
  const variants = data || [];
  if (variants.length > 1) {
    variantSelect.innerHTML = '<option value="">Select a variant...</option>' + variants.map((v) =>
      `<option value="${escapeHtml(v.variation_id)}">${escapeHtml(v.sku || v.variant_name || v.variation_id)}${v.variant_name && v.sku ? ' | ' + escapeHtml(v.variant_name) : ''}</option>`
    ).join('');
    variantField.classList.remove('hidden');
  } else if (variants.length === 1) {
    variantSelect.innerHTML = `<option value="${escapeHtml(variants[0].variation_id)}" selected>${escapeHtml(variants[0].sku || variants[0].variant_name || variants[0].variation_id)}</option>`;
  }
}

// ---------------------------------------------------------------- photo

// Phone photos are several MB; shrunk to at most 1280px on the long side and re-encoded as JPEG
// before upload - plenty to see the damage, and quick over a shop connection.
function compressImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 1280 / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not process the photo.'))), 'image/jpeg', 0.82);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('That file is not a readable image.')); };
    img.src = url;
  });
}

async function onPhotoChosen(event) {
  const file = event.target.files && event.target.files[0];
  const preview = document.getElementById('photoPreview');
  photoBlob = null;
  preview.classList.add('hidden');
  if (!file) return;
  try {
    photoBlob = await compressImage(file);
    photoFileName = (file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg';
    preview.src = URL.createObjectURL(photoBlob);
    preview.classList.remove('hidden');
  } catch (err) {
    showFormError(err.message);
  }
}

async function uploadPhoto() {
  const { data, error } = await supabaseClient.rpc('staff_create_defect_photo_upload', { ...creds(), p_file_name: photoFileName });
  if (error || !data || !data[0]) throw new Error('Could not prepare the photo upload: ' + (error ? error.message : 'unknown error'));
  const { storage_path, upload_token, public_url } = data[0];
  const { error: uploadError } = await supabaseClient.storage.from('defect-photos').uploadToSignedUrl(storage_path, upload_token, photoBlob);
  if (uploadError) throw new Error('Photo upload failed: ' + uploadError.message);
  return { path: storage_path, url: public_url };
}

// ---------------------------------------------------------------- submit

async function submitReport() {
  showFormError('');
  document.getElementById('formSuccess').classList.add('hidden');

  const warehouseId = document.getElementById('locationSelect').value;
  const variantSelect = document.getElementById('variantSelect');
  const variantRequired = !document.getElementById('variantField').classList.contains('hidden');
  const quantity = parseFloat(document.getElementById('quantityInput').value);
  const reason = document.getElementById('reasonSelect').value;

  if (!selectedItem) return showFormError('Pick the item first.');
  if (variantRequired && !variantSelect.value) return showFormError('Pick which variant is defective.');
  if (!warehouseId) return showFormError('No location - ask a super user to assign one to your account.');
  if (!(quantity > 0)) return showFormError('Enter how many are defective.');
  if (!reason) return showFormError('Pick a reason.');
  if (!photoBlob) return showFormError('Add a photo of the defective item.');

  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Submitting...';
  try {
    const photo = await uploadPhoto();
    const { data, error } = await supabaseClient.rpc('staff_submit_defect_report', {
      ...creds(),
      p_item_code: selectedItem.code,
      p_variant_id: variantSelect.value || null,
      p_warehouse_id: warehouseId,
      p_quantity: quantity,
      p_reason: reason,
      p_note: document.getElementById('noteInput').value.trim() || null,
      p_photo_path: photo.path,
      p_photo_url: photo.url
    });
    if (error) throw error;

    const success = document.getElementById('formSuccess');
    success.textContent = `Report ${data && data[0] ? data[0].report_no : ''} submitted - waiting for a super user to approve it.`;
    success.classList.remove('hidden');
    resetForm();
    currentStatus = 'Pending';
    setActiveTab();
    currentPage = 1;
    await loadReports();
  } catch (err) {
    showFormError(err.message || 'Failed to submit the report.');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Submit for approval';
  }
}

function resetForm() {
  selectedItem = null;
  photoBlob = null;
  document.getElementById('itemChosen').textContent = '';
  document.getElementById('variantField').classList.add('hidden');
  document.getElementById('variantSelect').innerHTML = '';
  document.getElementById('quantityInput').value = '1';
  document.getElementById('reasonSelect').value = '';
  document.getElementById('noteInput').value = '';
  document.getElementById('photoInput').value = '';
  document.getElementById('photoPreview').classList.add('hidden');
}

// ---------------------------------------------------------------- list

function statusBadge(status) {
  const cls = status === 'Approved' ? 'badge-success' : (status === 'Rejected' ? 'badge-danger' : 'badge-neutral');
  return `<span class="badge ${cls}">${escapeHtml(status)}</span>`;
}

function setActiveTab() {
  document.querySelectorAll('#statusTabs button').forEach((b) => b.classList.toggle('active', b.dataset.status === currentStatus));
}

async function loadReports() {
  showListError('');
  const body = document.getElementById('reportsBody');
  body.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_defect_reports', {
    ...creds(),
    p_status: currentStatus || null,
    p_search: document.getElementById('searchInput').value.trim() || null,
    p_page: currentPage,
    p_page_size: PAGE_SIZE
  });
  if (error) {
    body.innerHTML = '';
    showListError(error.message);
    return;
  }

  const rows = data || [];
  const total = rows.length ? Number(rows[0].total_count) : 0;
  document.getElementById('pageInfo').textContent = total ? `Page ${currentPage} of ${Math.max(1, Math.ceil(total / PAGE_SIZE))} (${total} report${total === 1 ? '' : 's'})` : '';
  document.getElementById('prevPageBtn').disabled = currentPage <= 1;
  document.getElementById('nextPageBtn').disabled = currentPage * PAGE_SIZE >= total;

  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="9" class="muted">No reports.</td></tr>';
    return;
  }

  body.innerHTML = rows.map((r) => {
    const canDecide = currentSession.isSuperUser && r.status === 'Pending';
    const canWithdraw = r.status === 'Pending' && (currentSession.isSuperUser || r.reported_by === currentSession.username);
    const actions = [
      canDecide ? `<button class="btn btn-success btn-sm" data-approve="${r.id}" data-no="${escapeHtml(r.report_no)}" data-qty="${escapeHtml(formatQty(r.quantity))}" data-item="${escapeHtml(r.item_code)}" data-loc="${escapeHtml(r.warehouse_name || '')}" type="button">Approve</button>` : '',
      canDecide ? `<button class="btn btn-danger btn-sm" data-reject="${r.id}" data-no="${escapeHtml(r.report_no)}" type="button">Reject</button>` : '',
      canWithdraw ? `<button class="btn btn-secondary btn-sm" data-withdraw="${r.id}" data-no="${escapeHtml(r.report_no)}" type="button">Withdraw</button>` : ''
    ].join('');
    const decided = r.decided_by
      ? `<div class="defect-note">${escapeHtml(r.status)} by ${escapeHtml(r.decided_by)}${r.decision_note ? ' - ' + escapeHtml(r.decision_note) : ''}</div>`
      : '';
    const onHandNote = r.status === 'Pending'
      ? `<div class="defect-note">On hand there: ${escapeHtml(formatQty(r.on_hand))}</div>`
      : '';
    const item = `${escapeHtml(r.item_code)}${r.item_name ? ' - ' + escapeHtml(r.item_name) : ''}${r.variant_name || r.variant_id ? `<div class="defect-note">${escapeHtml(r.variant_name || r.variant_id)}</div>` : ''}`;
    return `
      <tr>
        <td>${r.photo_url ? `<a href="${escapeHtml(r.photo_url)}" target="_blank" rel="noopener"><img class="defect-thumb" src="${escapeHtml(r.photo_url)}" alt="Defect photo" loading="lazy" /></a>` : ''}</td>
        <td>${escapeHtml(r.report_no)}</td>
        <td>${item}</td>
        <td>${escapeHtml(r.warehouse_name || '')}</td>
        <td>${escapeHtml(formatQty(r.quantity))}${onHandNote}</td>
        <td>${escapeHtml(r.reason)}${r.note ? `<div class="defect-note">${escapeHtml(r.note)}</div>` : ''}</td>
        <td>${escapeHtml(new Date(r.reported_at_utc).toLocaleString())}<div class="defect-note">${escapeHtml(r.reported_by)}</div></td>
        <td>${statusBadge(r.status)}${decided}</td>
        <td><div class="defect-actions">${actions}</div></td>
      </tr>`;
  }).join('');
}

async function decide(id, approve, note) {
  const { error } = await supabaseClient.rpc('admin_decide_defect_report', { ...creds(), p_id: id, p_approve: approve, p_decision_note: note || null });
  if (error) {
    window.alert(error.message);
    return;
  }
  await loadReports();
}

async function onReportsClick(e) {
  const approve = e.target.closest('[data-approve]');
  const reject = e.target.closest('[data-reject]');
  const withdraw = e.target.closest('[data-withdraw]');

  if (approve) {
    const d = approve.dataset;
    if (!window.confirm(`Approve ${d.no}? This removes ${d.qty} of ${d.item} from stock at ${d.loc}.`)) return;
    approve.disabled = true;
    await decide(Number(d.approve), true, null);
  } else if (reject) {
    const note = window.prompt(`Why is ${reject.dataset.no} being rejected?`);
    if (note === null) return;
    if (!note.trim()) { window.alert('Give a reason for rejecting.'); return; }
    reject.disabled = true;
    await decide(Number(reject.dataset.reject), false, note.trim());
  } else if (withdraw) {
    if (!window.confirm(`Withdraw ${withdraw.dataset.no}? Nothing is removed from stock.`)) return;
    withdraw.disabled = true;
    const { error } = await supabaseClient.rpc('staff_withdraw_defect_report', { ...creds(), p_id: Number(withdraw.dataset.withdraw) });
    if (error) { window.alert(error.message); return; }
    await loadReports();
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Defect Items');

  if (!session.isSuperUser && !session.isStoreManager) {
    window.location.href = 'dashboard.html';
    return;
  }

  await loadLocations();

  document.getElementById('itemSearchInput').addEventListener('input', (e) => {
    clearTimeout(itemSearchDebounceHandle);
    const term = e.target.value.trim();
    if (!term) { document.getElementById('itemHits').classList.add('hidden'); return; }
    itemSearchDebounceHandle = setTimeout(async () => renderItemHits(await searchItems(term)), 250);
  });
  document.getElementById('itemHits').addEventListener('click', (e) => {
    const hit = e.target.closest('.item-hit[data-code]');
    if (hit) chooseItem(hit.dataset.code, hit.dataset.name);
  });
  document.getElementById('photoInput').addEventListener('change', onPhotoChosen);
  document.getElementById('submitBtn').addEventListener('click', submitReport);

  document.getElementById('statusTabs').addEventListener('click', (e) => {
    const tab = e.target.closest('button[data-status]');
    if (!tab) return;
    currentStatus = tab.dataset.status;
    currentPage = 1;
    setActiveTab();
    loadReports();
  });
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => { currentPage = 1; loadReports(); }, 300);
  });
  document.getElementById('refreshBtn').addEventListener('click', loadReports);
  document.getElementById('prevPageBtn').addEventListener('click', () => { if (currentPage > 1) { currentPage -= 1; loadReports(); } });
  document.getElementById('nextPageBtn').addEventListener('click', () => { currentPage += 1; loadReports(); });
  document.getElementById('reportsBody').addEventListener('click', onReportsClick);

  // Deep link from Item Ledger Entries' Show Document (?search=DEF-000001): show every status.
  const searchParam = new URLSearchParams(window.location.search).get('search');
  if (searchParam) {
    document.getElementById('searchInput').value = searchParam;
    currentStatus = '';
    setActiveTab();
  }

  await loadReports();
})();
