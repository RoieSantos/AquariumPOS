// Repair Returns - a store sends a damaged item to our makers for repair and gets it back
// (supabase_repair_returns.sql). Sending takes the stock out of the store (Item Ledger "Repair
// Shipment"); Return puts it back in at a store ("Repair Return"). Every action goes through an RPC
// that re-checks who is calling - the buttons shown here are convenience, not the control.
let currentSession = null;
let selectedItem = null; // { code, name }
let currentStatus = 'Open';
let currentPage = 1;
const PAGE_SIZE = 25;
let searchDebounceHandle = null;
let itemSearchDebounceHandle = null;
let photoBlob = null;
let photoFileName = 'photo.jpg';
let allWarehouses = [];
let makers = []; // Tank / Stand Makers - who production can assign a repair to

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

function formatDate(value) {
  return value ? new Date(value).toLocaleString() : '';
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

function canSend() {
  return currentSession.isSuperUser || currentSession.isStoreManager;
}

function isProduction() {
  return currentSession.isSuperUser || currentSession.isProductionManager;
}

function isMaker() {
  return (currentSession.staffRoles || []).some((r) => r === 'TankMaker' || r === 'StandMaker');
}

// Same list Online Orders assigns from; Dispatchers left out - repairs go to a Tank / Stand Maker.
async function loadMakers() {
  const { data, error } = await supabaseClient.rpc('staff_list_order_makers', creds());
  makers = (error || !data ? [] : data).filter((m) => (m.staff_roles || []).some((r) => r === 'TankMaker' || r === 'StandMaker'));
}

function makerOptions(selected) {
  return '<option value="">Maker...</option>' + makers.map((m) =>
    `<option value="${escapeHtml(m.username)}"${m.username === selected ? ' selected' : ''}>${escapeHtml(m.display_name)}</option>`
  ).join('');
}

// ---------------------------------------------------------------- locations

async function loadWarehouses() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', { ...creds(), p_search: null, p_limit: 100 });
  allWarehouses = error || !data ? [] : data;

  const repairSelect = document.getElementById('repairSelect');
  const production = allWarehouses.filter((w) => w.is_production_warehouse);
  repairSelect.innerHTML = production.length
    ? production.map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('')
    : '<option value="">No production warehouse set up</option>';

  const fromSelect = document.getElementById('fromSelect');
  const own = allWarehouses.find((w) => (w.name || '').toLowerCase() === (currentSession.warehouseName || '').toLowerCase());
  if (currentSession.isSuperUser) {
    fromSelect.innerHTML = allWarehouses.map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
    if (own) fromSelect.value = own.id;
    return;
  }

  // A store manager sends only from their own store.
  fromSelect.innerHTML = own
    ? `<option value="${escapeHtml(own.id)}">${escapeHtml(own.name)}</option>`
    : '<option value="">No location assigned to your account</option>';
  fromSelect.disabled = true;
}

// ---------------------------------------------------------------- item, variant, serials

async function searchItems(term) {
  const { data, error } = await supabaseClient.rpc('staff_search_items', { ...creds(), p_search: term, p_limit: 15 });
  return error ? [] : (data || []);
}

function renderItemHits(hits) {
  const box = document.getElementById('itemHits');
  box.innerHTML = hits.length === 0
    ? '<div class="item-hit muted">No items found.</div>'
    : hits.map((h) =>
      `<div class="item-hit" data-code="${escapeHtml(h.code)}" data-name="${escapeHtml(h.name)}">${escapeHtml(h.code)} - ${escapeHtml(h.name)}</div>`
    ).join('');
  box.classList.remove('hidden');
}

async function chooseItem(code, name) {
  selectedItem = { code, name };
  document.getElementById('itemHits').classList.add('hidden');
  document.getElementById('itemSearchInput').value = '';
  document.getElementById('itemChosen').textContent = `Selected: ${code} - ${name}`;

  // Same rule as Defect Items: several variants -> pick one; one -> used as-is; none -> the item itself.
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
  await loadSerials();
}

// In Stock serials of the item at the From store - optional to tick (older units may have none).
async function loadSerials() {
  const field = document.getElementById('serialField');
  const list = document.getElementById('serialList');
  list.innerHTML = '';
  field.classList.add('hidden');
  const fromId = document.getElementById('fromSelect').value;
  if (!selectedItem || !fromId) return;

  const { data, error } = await supabaseClient.rpc('staff_list_repair_serials', {
    ...creds(),
    p_item_code: selectedItem.code,
    p_variant_id: document.getElementById('variantSelect').value || null,
    p_warehouse_id: fromId
  });
  const serials = error ? [] : (data || []);
  if (serials.length === 0) return;
  list.innerHTML = serials.map((s) =>
    `<label><input type="checkbox" value="${escapeHtml(s.running_serial_no)}" /> ${escapeHtml(s.serial_no)}</label>`
  ).join('');
  field.classList.remove('hidden');
}

function pickedSerials() {
  return [...document.querySelectorAll('#serialList input:checked')].map((c) => Number(c.value));
}

// ---------------------------------------------------------------- photo (same flow as Defect Items)

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
    photoFileName = 'repair_' + (file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg';
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

// ---------------------------------------------------------------- send

async function submitRepair() {
  showFormError('');
  document.getElementById('formSuccess').classList.add('hidden');

  const fromId = document.getElementById('fromSelect').value;
  const repairId = document.getElementById('repairSelect').value;
  const variantSelect = document.getElementById('variantSelect');
  const variantRequired = !document.getElementById('variantField').classList.contains('hidden');
  const quantity = parseFloat(document.getElementById('quantityInput').value);
  const problem = document.getElementById('problemSelect').value;
  const serials = pickedSerials();

  if (!selectedItem) return showFormError('Pick the item first.');
  if (variantRequired && !variantSelect.value) return showFormError('Pick which variant is going.');
  if (!fromId) return showFormError('No store - ask a super user to assign one to your account.');
  if (!repairId) return showFormError('No production warehouse is set up (Warehouse Setup).');
  if (!(quantity > 0)) return showFormError('Enter how many are going for repair.');
  if (serials.length > quantity) return showFormError(`You ticked ${serials.length} serials for ${quantity} unit(s).`);
  if (!problem) return showFormError("Pick what's wrong with it.");
  if (!photoBlob) return showFormError('Add a photo of the damage.');

  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Sending...';
  try {
    const photo = await uploadPhoto();
    const { data, error } = await supabaseClient.rpc('staff_create_repair_return', {
      ...creds(),
      p_item_code: selectedItem.code,
      p_variant_id: variantSelect.value || null,
      p_from_warehouse_id: fromId,
      p_repair_warehouse_id: repairId,
      p_quantity: quantity,
      p_problem: problem,
      p_note: document.getElementById('noteInput').value.trim() || null,
      p_photo_path: photo.path,
      p_photo_url: photo.url,
      p_running_serial_nos: serials.length ? serials : null
    });
    if (error) throw error;

    const success = document.getElementById('formSuccess');
    success.textContent = `${data && data[0] ? data[0].repair_no : 'Repair'} sent - taken out of the store's stock until it comes back.`;
    success.classList.remove('hidden');
    resetForm();
    currentStatus = 'Open';
    setActiveTab();
    currentPage = 1;
    await loadRepairs();
  } catch (err) {
    showFormError(err.message || 'Failed to send for repair.');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Send for repair';
  }
}

function resetForm() {
  selectedItem = null;
  photoBlob = null;
  document.getElementById('itemChosen').textContent = '';
  document.getElementById('variantField').classList.add('hidden');
  document.getElementById('variantSelect').innerHTML = '';
  document.getElementById('serialField').classList.add('hidden');
  document.getElementById('serialList').innerHTML = '';
  document.getElementById('quantityInput').value = '1';
  document.getElementById('problemSelect').value = '';
  document.getElementById('noteInput').value = '';
  document.getElementById('photoInput').value = '';
  document.getElementById('photoPreview').classList.add('hidden');
}

// ---------------------------------------------------------------- list

function statusBadge(status) {
  const cls = {
    Sent: 'badge-warning', 'In Repair': 'badge-primary', Repaired: 'badge-purple',
    Returned: 'badge-success', Scrapped: 'badge-danger'
  }[status] || 'badge-neutral';
  return `<span class="badge ${cls}">${escapeHtml(status)}</span>`;
}

function setActiveTab() {
  document.querySelectorAll('#statusTabs button').forEach((b) => b.classList.toggle('active', b.dataset.status === currentStatus));
}

function returnStoreOptions(defaultId) {
  return allWarehouses.map((w) =>
    `<option value="${escapeHtml(w.id)}"${w.id === defaultId ? ' selected' : ''}>${escapeHtml(w.name)}</option>`
  ).join('');
}

function rowActions(r) {
  const btn = (action, label, cls) =>
    `<button class="btn ${cls} btn-sm" data-action="${action}" data-id="${r.id}" data-no="${escapeHtml(r.repair_no)}" type="button">${label}</button>`;
  const out = [];
  const makerSelect = `<select data-maker-for="${r.id}" title="Maker doing the repair">${makerOptions(r.maker)}</select>`;
  if (r.status === 'Sent') {
    if (isProduction()) out.push(makerSelect, btn('receive', 'Receive', 'btn-primary'));
    if (currentSession.isSuperUser || r.sent_by === currentSession.username) out.push(btn('cancel', 'Cancel', 'btn-secondary'));
  } else if (r.status === 'In Repair') {
    if (isProduction()) out.push(makerSelect, btn('assign', 'Change maker', 'btn-secondary'));
    if (isProduction() || (isMaker() && r.maker === currentSession.username)) out.push(btn('repaired', 'Mark repaired', 'btn-success'));
    if (currentSession.isSuperUser) out.push(btn('scrap', 'Scrap', 'btn-danger'));
  } else if (r.status === 'Repaired') {
    if (isProduction()) {
      out.push(`<select data-return-to="${r.id}" title="Return to store">${returnStoreOptions(r.from_warehouse_id)}</select>`);
      out.push(btn('return', 'Return to store', 'btn-success'));
    }
    if (currentSession.isSuperUser) out.push(btn('scrap', 'Scrap', 'btn-danger'));
  }
  return out.join('');
}

function historyNotes(r) {
  const lines = [];
  if (r.received_by) lines.push(`Received by ${r.received_by}, ${formatDate(r.received_at_utc)}`);
  if (r.maker) lines.push(`Maker: ${r.maker_name || r.maker}`);
  if (r.repaired_by) lines.push(`Repaired by ${r.repaired_by}${r.repair_note ? ': ' + r.repair_note : ''}`);
  if (r.status === 'Returned') lines.push(`Returned to ${r.return_warehouse_name || '?'} by ${r.returned_by}, ${formatDate(r.returned_at_utc)}`);
  if (r.closed_by) lines.push(`${r.status} by ${r.closed_by}${r.closed_note ? ' - ' + r.closed_note : ''}`);
  return lines.map((l) => `<div class="repair-note">${escapeHtml(l)}</div>`).join('');
}

async function loadRepairs() {
  showListError('');
  const body = document.getElementById('repairsBody');
  body.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('staff_list_repair_returns', {
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
  document.getElementById('pageInfo').textContent = total ? `Page ${currentPage} of ${Math.max(1, Math.ceil(total / PAGE_SIZE))} (${total} repair${total === 1 ? '' : 's'})` : '';
  document.getElementById('prevPageBtn').disabled = currentPage <= 1;
  document.getElementById('nextPageBtn').disabled = currentPage * PAGE_SIZE >= total;

  if (rows.length === 0) {
    body.innerHTML = '<tr><td colspan="9" class="muted">No repairs.</td></tr>';
    return;
  }

  body.innerHTML = rows.map((r) => {
    const item = `${escapeHtml(r.item_code)}${r.item_name ? ' - ' + escapeHtml(r.item_name) : ''}`
      + (r.variant_name || r.variant_id ? `<div class="repair-note">${escapeHtml(r.variant_name || r.variant_id)}</div>` : '')
      + (r.serial_nos ? `<div class="repair-note">S/N ${escapeHtml(r.serial_nos)}</div>` : '');
    return `
      <tr>
        <td>${r.photo_url ? `<a href="${escapeHtml(r.photo_url)}" target="_blank" rel="noopener"><img class="repair-thumb" src="${escapeHtml(r.photo_url)}" alt="Damage photo" loading="lazy" /></a>` : ''}</td>
        <td>${escapeHtml(r.repair_no)}</td>
        <td>${item}</td>
        <td>${escapeHtml(r.from_warehouse_name || '')} &rarr; ${escapeHtml(r.repair_warehouse_name || '')}</td>
        <td>${escapeHtml(formatQty(r.quantity))}</td>
        <td>${escapeHtml(r.problem)}${r.note ? `<div class="repair-note">${escapeHtml(r.note)}</div>` : ''}</td>
        <td>${escapeHtml(formatDate(r.sent_at_utc))}<div class="repair-note">${escapeHtml(r.sent_by)}</div></td>
        <td>${statusBadge(r.status)}${historyNotes(r)}</td>
        <td><div class="repair-actions">${rowActions(r)}</div></td>
      </tr>`;
  }).join('');
}

async function runAction(id, action, returnWarehouseId, note, maker) {
  const { error } = await supabaseClient.rpc('staff_repair_return_action', {
    ...creds(), p_id: id, p_action: action, p_return_warehouse_id: returnWarehouseId || null, p_note: note || null, p_maker: maker || null
  });
  if (error) {
    window.alert(error.message);
    return;
  }
  await loadRepairs();
}

async function onRepairsClick(e) {
  const button = e.target.closest('button[data-action]');
  if (!button) return;
  const { action, no } = button.dataset;
  const id = Number(button.dataset.id);
  let note = null;
  let returnTo = null;
  let maker = null;

  if (action === 'receive' || action === 'assign') {
    const select = document.querySelector(`select[data-maker-for="${id}"]`);
    maker = select ? select.value : '';
    if (!maker) { window.alert('Pick the maker doing the repair.'); return; }
    const makerName = select.options[select.selectedIndex].text;
    const question = action === 'receive' ? `Received ${no} at production - assign to ${makerName}?` : `Give ${no} to ${makerName}?`;
    if (!window.confirm(question)) return;
  } else if (action === 'repaired') {
    note = window.prompt(`What was repaired on ${no}?`);
    if (note === null) return;
    if (!note.trim()) { window.alert('Say what was repaired.'); return; }
  } else if (action === 'return') {
    const select = document.querySelector(`select[data-return-to="${id}"]`);
    returnTo = select ? select.value : null;
    const storeName = select ? select.options[select.selectedIndex].text : 'the store';
    if (!window.confirm(`Return ${no} to ${storeName}? This puts it back in stock there.`)) return;
  } else if (action === 'scrap') {
    note = window.prompt(`Why can't ${no} be repaired? Scrapping writes it off - it stays out of stock.`);
    if (note === null) return;
    if (!note.trim()) { window.alert('Give a reason for scrapping.'); return; }
  } else if (action === 'cancel') {
    if (!window.confirm(`Cancel ${no}? It goes back into the store's stock.`)) return;
  }

  button.disabled = true;
  await runAction(id, action, returnTo, note ? note.trim() : null, maker);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Repair Returns');

  if (!session.isSuperUser && !session.isStoreManager && !session.isProductionManager && !isMaker()) {
    window.location.href = 'dashboard.html';
    return;
  }

  await Promise.all([loadWarehouses(), isProduction() ? loadMakers() : Promise.resolve()]);

  if (canSend()) {
    document.getElementById('sendCard').classList.remove('hidden');
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
    document.getElementById('variantSelect').addEventListener('change', loadSerials);
    document.getElementById('fromSelect').addEventListener('change', loadSerials);
    document.getElementById('photoInput').addEventListener('change', onPhotoChosen);
    document.getElementById('submitBtn').addEventListener('click', submitRepair);
  }

  document.getElementById('statusTabs').addEventListener('click', (e) => {
    const tab = e.target.closest('button[data-status]');
    if (!tab) return;
    currentStatus = tab.dataset.status;
    currentPage = 1;
    setActiveTab();
    loadRepairs();
  });
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => { currentPage = 1; loadRepairs(); }, 300);
  });
  document.getElementById('refreshBtn').addEventListener('click', loadRepairs);
  document.getElementById('prevPageBtn').addEventListener('click', () => { if (currentPage > 1) { currentPage -= 1; loadRepairs(); } });
  document.getElementById('nextPageBtn').addEventListener('click', () => { currentPage += 1; loadRepairs(); });
  document.getElementById('repairsBody').addEventListener('click', onRepairsClick);

  // Deep link from Item Ledger Entries' Show Document (?search=RPR-000001): show every status.
  const searchParam = new URLSearchParams(window.location.search).get('search');
  if (searchParam) {
    document.getElementById('searchInput').value = searchParam;
    currentStatus = '';
    setActiveTab();
  }

  await loadRepairs();
})();
