// Livestock Losses - store staff record dead fish / plants themselves (several lines per report,
// optional photo). Posting takes the stock out of the Item Ledger straight away - no approval step,
// per "dont rely on the superuser.. i want them to do it themselves". A mistake is undone with
// Reverse (reporter / Store Manager within 3 days, Super User any time). The Summary tab (Super
// User / Store Manager) groups losses by item, cause, category, supplier or location against what
// was received. See supabase_livestock_losses.sql - every RPC re-checks who is calling, including
// that non-super users can only report at their own location.
let currentSession = null;
let lines = []; // { key, code, name, onHand, variants, variantId, quantity, cause, note }
let lineSeq = 0;
let ownWarehouse = null;
let currentStatus = '';
let currentPage = 1;
const PAGE_SIZE = 20;
let searchDebounceHandle = null;
let itemSearchDebounceHandle = null;
let photoBlob = null;
let photoFileName = 'photo.jpg';
let summaryGroup = 'item';
let summaryPeriod = '30';
let lastCause = '';

const CAUSES = [
  'Died in tank',
  'Died in quarantine',
  'Dead on arrival',
  'Disease / parasites',
  'Water quality',
  'Eaten / attacked by tankmates',
  'Jumped out',
  'Transport stress',
  'Plant melted / rotted',
  'Unknown',
  'Other'
];

const GROUP_LABELS = { item: 'Fish / plant', cause: 'Cause', category: 'Category', vendor: 'Supplier', warehouse: 'Location' };

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatQty(value) {
  return Number(value || 0).toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function formatMoney(value) {
  return '₱' + Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// The shop's day (Manila), as yyyy-mm-dd, for date inputs.
function manilaToday(offsetDays = 0) {
  return new Date(Date.now() + offsetDays * 86400000).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

function friendlyDate(isoDate) {
  if (!isoDate) return '';
  if (isoDate === manilaToday()) return 'Today';
  if (isoDate === manilaToday(-1)) return 'Yesterday';
  return new Date(isoDate + 'T00:00:00').toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
}

function showMsg(id, message, ok) {
  const el = document.getElementById(id);
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
  el.classList.toggle('ll-msg-ok', !!ok);
  el.classList.toggle('ll-msg-err', !ok);
}

function creds() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

function currentWarehouseId() {
  return currentSession.isSuperUser ? document.getElementById('locationSelect').value : (ownWarehouse ? ownWarehouse.id : '');
}

// ---------------------------------------------------------------- tabs

function switchTab(name) {
  document.querySelectorAll('#tabs .ll-tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  ['report', 'history', 'summary'].forEach((t) => document.getElementById('tab-' + t).classList.toggle('hidden', t !== name));
  if (name === 'history') loadReports();
  if (name === 'summary') loadSummary();
}

// ---------------------------------------------------------------- location

// Non-super users are fixed to the location on their account (shown as a chip, no picker). The
// server refuses any other location for them too, so this is convenience, not the control.
async function loadLocations() {
  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', { ...creds(), p_search: null, p_limit: 100 });
  const warehouses = error || !data ? [] : data;
  ownWarehouse = warehouses.find((w) => (w.name || '').toLowerCase() === (currentSession.warehouseName || '').toLowerCase()) || null;

  const chip = document.getElementById('locationChip');
  const select = document.getElementById('locationSelect');
  if (currentSession.isSuperUser) {
    select.innerHTML = warehouses.map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
    if (ownWarehouse) select.value = ownWarehouse.id;
    select.classList.remove('hidden');

    const sumSelect = document.getElementById('sumLocationSelect');
    sumSelect.innerHTML = '<option value="">All locations</option>' +
      warehouses.map((w) => `<option value="${escapeHtml(w.id)}">${escapeHtml(w.name)}</option>`).join('');
    sumSelect.classList.remove('hidden');
  } else {
    chip.innerHTML = ownWarehouse
      ? `&#128205; ${escapeHtml(ownWarehouse.name)}`
      : 'No location on your account - ask a super user to set one';
    chip.classList.remove('hidden');
    document.querySelectorAll('#groupChips [data-super-only]').forEach((b) => b.remove());
  }
}

// ---------------------------------------------------------------- item search + lines

async function searchItems(term) {
  const { data, error } = await supabaseClient.rpc('staff_search_livestock_items', {
    ...creds(), p_search: term, p_warehouse_id: currentWarehouseId() || null, p_limit: 15
  });
  return error ? [] : (data || []);
}

function renderItemHits(hits) {
  const box = document.getElementById('itemHits');
  box.innerHTML = hits.length === 0
    ? '<div class="item-hit"><span class="ll-muted">No fish or plants match. Only categories ticked "Livestock" in Category Setup are listed.</span></div>'
    : hits.map((h) => `
        <div class="item-hit" tabindex="0" data-code="${escapeHtml(h.code)}" data-name="${escapeHtml(h.name)}" data-onhand="${escapeHtml(h.on_hand)}">
          <div><div class="item-hit-name">${escapeHtml(h.name)}</div><div class="item-hit-code">${escapeHtml(h.code)}</div></div>
          <div class="item-hit-stock">${escapeHtml(formatQty(h.on_hand))} in stock</div>
        </div>`).join('');
  box.classList.remove('hidden');
}

async function addLine(code, name, onHand) {
  document.getElementById('itemHits').classList.add('hidden');
  const search = document.getElementById('itemSearchInput');
  search.value = '';

  // Same item already on the list (and no variant choice to make): just add one more dead.
  const existing = lines.find((l) => l.code === code && l.variants.length <= 1);
  if (existing) {
    existing.quantity += 1;
    renderLines();
    return;
  }

  // Same variant rule as Defect Items: several -> pick one; one -> used as-is; none -> the item itself.
  const { data } = await supabaseClient.rpc('staff_search_variants', { ...creds(), p_item_code: code, p_page: 1 });
  const variants = data || [];
  lines.push({
    key: ++lineSeq, code, name, onHand: Number(onHand || 0), variants,
    variantId: variants.length === 1 ? variants[0].variation_id : '',
    // Usually several fish died of the same thing - start with the cause picked last.
    quantity: 1, cause: lastCause, note: ''
  });
  renderLines();
  search.focus();
}

function variantLabel(v) {
  const main = v.sku || v.variant_name || v.variation_id;
  return v.variant_name && v.sku ? `${main} | ${v.variant_name}` : main;
}

// Stock at this location before / after. When the system already shows none, say so plainly - it
// still posts (the fish are gone), it just means the count is off.
function stockNote(l) {
  if (l.onHand <= 0) {
    return `<span class="ll-stock-warn">&#9888; System shows no stock here - it still posts; the count needs checking.</span>`;
  }
  if (l.quantity > l.onHand) {
    return `<span class="ll-stock-warn">&#9888; Only ${escapeHtml(formatQty(l.onHand))} in stock - it still posts; the count needs checking.</span>`;
  }
  return `<span class="ll-stock-ok">${escapeHtml(formatQty(l.onHand))} in stock &rarr; ${escapeHtml(formatQty(l.onHand - l.quantity))} after</span>`;
}

function renderLines() {
  const list = document.getElementById('linesList');
  document.getElementById('linesHead').classList.toggle('hidden', lines.length === 0);
  if (lines.length === 0) {
    list.innerHTML = '<div class="ll-empty"><span class="ll-empty-icon">&#128031;</span><strong>No fish or plants added yet.</strong><br />Type a name in the search box above to start.</div>';
  } else {
    list.innerHTML = lines.map((l) => {
      const variant = l.variants.length > 1
        ? `<select class="ll-variant" data-field="variantId" data-key="${l.key}"><option value="">Which size / variant?</option>${l.variants.map((v) =>
            `<option value="${escapeHtml(v.variation_id)}" ${v.variation_id === l.variantId ? 'selected' : ''}>${escapeHtml(variantLabel(v))}</option>`).join('')}</select>`
        : '';
      return `
        <div class="ll-line ll-panel">
          <div class="ll-c-name">
            <div class="ll-line-name">${escapeHtml(l.name)}</div>
            <div class="ll-muted">${escapeHtml(l.code)}</div>
            ${variant}
            <div class="ll-stock" data-stock="${l.key}">${stockNote(l)}</div>
          </div>
          <div class="ll-c-qty">
            <div class="ll-stepper">
              <button type="button" data-step="-1" data-key="${l.key}" aria-label="One less">&minus;</button>
              <input type="number" min="1" max="500" step="1" inputmode="numeric" data-field="quantity" data-key="${l.key}" value="${escapeHtml(l.quantity)}" aria-label="How many died" />
              <button type="button" data-step="1" data-key="${l.key}" aria-label="One more">+</button>
            </div>
          </div>
          <div class="ll-c-cause">
            <select data-field="cause" data-key="${l.key}" aria-label="What happened">
              <option value="">What happened?</option>
              ${CAUSES.map((c) => `<option ${c === l.cause ? 'selected' : ''}>${escapeHtml(c)}</option>`).join('')}
            </select>
          </div>
          <div class="ll-c-note">
            <input type="text" data-field="note" data-key="${l.key}" value="${escapeHtml(l.note)}" placeholder="Note (optional)" maxlength="500" />
          </div>
          <button class="ll-line-remove" data-remove="${l.key}" type="button" title="Remove" aria-label="Remove ${escapeHtml(l.name)}">&times;</button>
        </div>`;
    }).join('');
  }
  updateSubmitBar();
}

function updateSubmitBar() {
  const total = lines.reduce((s, l) => s + (Number(l.quantity) || 0), 0);
  document.getElementById('totalDead').textContent = formatQty(total);
  document.getElementById('submitTotal').textContent = lines.length
    ? `dead · ${lines.length} fish / plant${lines.length === 1 ? '' : 's'}`
    : 'No items added yet';
  document.getElementById('submitBtn').disabled = lines.length === 0;
}

function lineByKey(key) {
  return lines.find((l) => l.key === Number(key));
}

function onLineInput(e) {
  const el = e.target.closest('[data-field]');
  if (!el) return;
  const line = lineByKey(el.dataset.key);
  if (!line) return;
  if (el.dataset.field === 'quantity') {
    line.quantity = Math.max(0, parseInt(el.value, 10) || 0);
    const stock = document.querySelector(`[data-stock="${line.key}"]`);
    if (stock) stock.innerHTML = stockNote(line);
    updateSubmitBar();
  } else {
    line[el.dataset.field] = el.value;
    if (el.dataset.field === 'cause' && el.value) lastCause = el.value;
  }
}

function onLineClick(e) {
  const remove = e.target.closest('[data-remove]');
  const step = e.target.closest('[data-step]');
  if (remove) {
    lines = lines.filter((l) => l.key !== Number(remove.dataset.remove));
    renderLines();
  } else if (step) {
    const line = lineByKey(step.dataset.key);
    if (!line) return;
    line.quantity = Math.min(500, Math.max(1, (Number(line.quantity) || 0) + Number(step.dataset.step)));
    const input = document.querySelector(`input[data-field="quantity"][data-key="${line.key}"]`);
    if (input) input.value = line.quantity;
    const stock = document.querySelector(`[data-stock="${line.key}"]`);
    if (stock) stock.innerHTML = stockNote(line);
    updateSubmitBar();
  }
}

// ---------------------------------------------------------------- photo

// Phone photos are several MB - shrink to 1280px JPEG before upload (same as Defect Items).
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
    showMsg('formMsg', err.message, false);
  }
}

async function uploadPhoto() {
  const { data, error } = await supabaseClient.rpc('staff_create_livestock_loss_photo_upload', { ...creds(), p_file_name: photoFileName });
  if (error || !data || !data[0]) throw new Error('Could not prepare the photo upload: ' + (error ? error.message : 'unknown error'));
  const { storage_path, upload_token, public_url } = data[0];
  const { error: uploadError } = await supabaseClient.storage.from('livestock-loss-photos').uploadToSignedUrl(storage_path, upload_token, photoBlob);
  if (uploadError) throw new Error('Photo upload failed: ' + uploadError.message);
  return { path: storage_path, url: public_url };
}

// ---------------------------------------------------------------- submit

async function submitReport() {
  showMsg('formMsg', '');
  const warehouseId = currentWarehouseId();
  const lossDate = document.getElementById('lossDateInput').value;

  if (!warehouseId) return showMsg('formMsg', 'Your account has no location - ask a super user to set one in User Setup.', false);
  if (!lossDate) return showMsg('formMsg', 'Pick the date the losses were found.', false);
  if (lines.length === 0) return showMsg('formMsg', 'Add at least one fish or plant.', false);
  for (const l of lines) {
    if (l.variants.length > 1 && !l.variantId) return showMsg('formMsg', `${l.name}: pick which size / variant.`, false);
    if (!(l.quantity > 0)) return showMsg('formMsg', `${l.name}: enter how many died.`, false);
    if (!l.cause) return showMsg('formMsg', `${l.name}: pick what happened.`, false);
  }

  const total = lines.reduce((s, l) => s + l.quantity, 0);
  const where = currentSession.isSuperUser
    ? document.getElementById('locationSelect').selectedOptions[0]?.textContent
    : ownWarehouse?.name;
  if (!window.confirm(`Post ${formatQty(total)} dead (${lines.length} item${lines.length === 1 ? '' : 's'}) at ${where}?\n\nThis takes them out of stock now.`)) return;

  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';
  try {
    const photo = photoBlob ? await uploadPhoto() : null;
    const { data, error } = await supabaseClient.rpc('staff_submit_livestock_loss', {
      ...creds(),
      p_warehouse_id: warehouseId,
      p_loss_date: lossDate,
      p_note: document.getElementById('noteInput').value.trim() || null,
      p_photo_path: photo ? photo.path : null,
      p_photo_url: photo ? photo.url : null,
      p_lines: lines.map((l) => ({
        item_code: l.code, variant_id: l.variantId || null, quantity: l.quantity, cause: l.cause, note: l.note.trim() || null
      }))
    });
    if (error) throw error;

    resetForm();
    showMsg('formMsg', `Posted ${data && data[0] ? data[0].report_no : ''} - ${formatQty(total)} taken out of stock. You can undo it from History if it was a mistake.`, true);
  } catch (err) {
    showMsg('formMsg', err.message || 'Failed to post the losses.', false);
  } finally {
    btn.textContent = 'Post losses';
    updateSubmitBar();
  }
}

function resetForm() {
  lines = [];
  photoBlob = null;
  document.getElementById('noteInput').value = '';
  document.getElementById('photoInput').value = '';
  document.getElementById('photoPreview').classList.add('hidden');
  document.getElementById('lossDateInput').value = manilaToday();
  document.querySelector('.ll-side details').open = false;
  lastCause = '';
  renderLines();
}

// ---------------------------------------------------------------- history

function renderReport(r) {
  const reversed = r.status === 'Reversed';
  const items = (r.lines || []).map((l) => {
    const variant = l.variant_name || l.variant_id ? ` <span class="ll-muted">(${escapeHtml(l.variant_name || l.variant_id)})</span>` : '';
    const gap = l.on_hand_before != null && Number(l.quantity) > Number(l.on_hand_before)
      ? `<div class="ll-warn">Stock showed only ${escapeHtml(formatQty(l.on_hand_before))} - count needs checking</div>` : '';
    const cost = l.unit_cost != null ? ` · ${escapeHtml(formatMoney(Number(l.unit_cost) * Number(l.quantity)))}` : '';
    return `<li><span class="ll-qty">${escapeHtml(formatQty(l.quantity))}&times;</span> ${escapeHtml(l.item_name || l.item_code)}${variant}
      <div class="ll-muted">${escapeHtml(l.cause)}${l.note ? ' - ' + escapeHtml(l.note) : ''}${cost}</div>${gap}</li>`;
  }).join('');
  const badge = reversed ? '<span class="badge badge-neutral">Reversed</span>' : '<span class="badge badge-success">Posted</span>';
  const reverseInfo = reversed
    ? `<div class="ll-muted">Reversed by ${escapeHtml(r.reversed_by)}${r.reverse_reason ? ' - ' + escapeHtml(r.reverse_reason) : ''}</div>`
    : '<span></span>';
  const reverseBtn = r.can_reverse
    ? `<button class="btn btn-secondary btn-sm" data-reverse="${r.id}" data-no="${escapeHtml(r.report_no)}" type="button">Undo (reverse)</button>` : '';
  return `
    <div class="ll-report ll-panel${reversed ? ' reversed' : ''}">
      <div class="ll-report-top">
        <div>
          <div class="ll-report-no">${escapeHtml(friendlyDate(r.loss_date))} · ${escapeHtml(formatQty(r.total_qty))} dead</div>
          <div class="ll-report-meta">${escapeHtml(r.report_no)} · ${escapeHtml(r.warehouse_name || '')} · by ${escapeHtml(r.reported_by)} at ${escapeHtml(new Date(r.reported_at_utc).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }))}</div>
        </div>
        ${badge}
      </div>
      <div class="ll-report-body">
        ${r.photo_url ? `<a href="${escapeHtml(r.photo_url)}" target="_blank" rel="noopener"><img class="ll-thumb" src="${escapeHtml(r.photo_url)}" alt="Photo" loading="lazy" /></a>` : ''}
        <ul class="ll-report-items">${items}</ul>
      </div>
      ${r.note ? `<div class="ll-muted" style="margin-top:6px;">&#128221; ${escapeHtml(r.note)}</div>` : ''}
      <div class="ll-report-foot">${reverseInfo}${reverseBtn}</div>
    </div>`;
}

async function loadReports() {
  showMsg('listMsg', '');
  const list = document.getElementById('reportsList');
  list.innerHTML = '<p class="ll-muted">Loading...</p>';

  const { data, error } = await supabaseClient.rpc('staff_list_livestock_losses', {
    ...creds(),
    p_status: currentStatus || null,
    p_search: document.getElementById('searchInput').value.trim() || null,
    p_page: currentPage,
    p_page_size: PAGE_SIZE
  });
  if (error) {
    list.innerHTML = '';
    showMsg('listMsg', error.message, false);
    return;
  }

  const rows = data || [];
  const total = rows.length ? Number(rows[0].total_count) : 0;
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  document.getElementById('pageInfo').textContent = total ? `Page ${currentPage} of ${pages} · ${total} report${total === 1 ? '' : 's'}` : '';
  document.getElementById('prevPageBtn').disabled = currentPage <= 1;
  document.getElementById('nextPageBtn').disabled = currentPage >= pages;

  list.innerHTML = rows.length
    ? `<div class="ll-report-grid">${rows.map(renderReport).join('')}</div>`
    : '<div class="ll-empty"><span class="ll-empty-icon">&#128203;</span>No reports yet.</div>';
}

async function onReportsClick(e) {
  const btn = e.target.closest('[data-reverse]');
  if (!btn) return;
  const reason = window.prompt(`Undo ${btn.dataset.no}? The fish / plants go back into stock.\n\nWhy is it being reversed?`);
  if (reason === null) return;
  if (!reason.trim()) { window.alert('Give a reason for the reversal.'); return; }
  btn.disabled = true;
  const { error } = await supabaseClient.rpc('staff_reverse_livestock_loss', { ...creds(), p_id: Number(btn.dataset.reverse), p_reason: reason.trim() });
  if (error) { window.alert(error.message); btn.disabled = false; return; }
  await loadReports();
}

// ---------------------------------------------------------------- summary

function summaryRange() {
  if (summaryPeriod === 'custom') {
    return { from: document.getElementById('sumFromInput').value || null, to: document.getElementById('sumToInput').value || null };
  }
  if (summaryPeriod === 'month') return { from: manilaToday().slice(0, 8) + '01', to: manilaToday() };
  return { from: manilaToday(-(Number(summaryPeriod) - 1)), to: manilaToday() };
}

function statTile(label, value, sub) {
  return `<div class="ll-stat ll-panel"><div class="ll-stat-label">${escapeHtml(label)}</div><div class="ll-stat-value">${value}</div>${sub ? `<div class="ll-stat-sub">${sub}</div>` : ''}</div>`;
}

async function loadSummary() {
  showMsg('sumMsg', '');
  const { from, to } = summaryRange();
  const showValue = currentSession.isSuperUser;
  const showReceived = summaryGroup !== 'cause';
  const head = document.getElementById('summaryHead');
  const body = document.getElementById('summaryBody');
  const stats = document.getElementById('summaryStats');
  const cols = 3 + (showValue ? 1 : 0) + (showReceived ? 2 : 0);

  head.innerHTML = `<tr><th>${escapeHtml(GROUP_LABELS[summaryGroup])}</th><th class="num">Dead</th><th class="num">Reports</th>${showValue ? '<th class="num">Loss value</th>' : ''}${showReceived ? '<th class="num">Received</th><th class="num">Loss %</th>' : ''}</tr>`;
  body.innerHTML = `<tr><td colspan="${cols}" class="ll-muted">Loading...</td></tr>`;

  const warehouseId = currentSession.isSuperUser ? (document.getElementById('sumLocationSelect').value || null) : null;
  const args = { ...creds(), p_from: from, p_to: to, p_warehouse_id: warehouseId };
  // The headline tiles always come from the by-cause and by-item views, whatever grouping is shown.
  const [main, byCause, byItem] = await Promise.all([
    supabaseClient.rpc('staff_livestock_loss_summary', { ...args, p_group_by: summaryGroup }),
    supabaseClient.rpc('staff_livestock_loss_summary', { ...args, p_group_by: 'cause' }),
    supabaseClient.rpc('staff_livestock_loss_summary', { ...args, p_group_by: 'item' })
  ]);
  if (main.error) {
    body.innerHTML = '';
    stats.innerHTML = '';
    showMsg('sumMsg', main.error.message, false);
    return;
  }

  const rows = main.data || [];
  const causes = byCause.data || [];
  const items = byItem.data || [];
  const totalDead = causes.reduce((s, r) => s + Number(r.dead_qty || 0), 0);
  const totalValue = causes.reduce((s, r) => s + Number(r.loss_value || 0), 0);
  const topCause = causes[0];
  const topItem = items[0];
  stats.innerHTML = [
    statTile('Total dead', escapeHtml(formatQty(totalDead)), `${escapeHtml(friendlyDate(from))} - ${escapeHtml(friendlyDate(to))}`),
    showValue ? statTile('Loss value', escapeHtml(formatMoney(totalValue)), 'at cost') : '',
    statTile('Top cause', topCause ? escapeHtml(topCause.group_key) : '-', topCause ? `${escapeHtml(formatQty(topCause.dead_qty))} dead` : ''),
    statTile('Most lost', topItem ? escapeHtml(topItem.group_label || topItem.group_key) : '-', topItem ? `${escapeHtml(formatQty(topItem.dead_qty))} dead${topItem.loss_pct != null ? ' · ' + escapeHtml(topItem.loss_pct) + '% of received' : ''}` : '')
  ].join('');

  if (rows.length === 0) {
    body.innerHTML = `<tr><td colspan="${cols}"><div class="ll-empty"><span class="ll-empty-icon">&#127881;</span>No losses recorded in this period.</div></td></tr>`;
    return;
  }

  const maxDead = Math.max(...rows.map((r) => Number(r.dead_qty || 0)), 1);
  body.innerHTML = rows.map((r) => {
    const name = summaryGroup === 'cause'
      ? escapeHtml(r.group_key)
      : `${escapeHtml(r.group_label || r.group_key)}${r.group_label && r.group_label !== r.group_key ? `<div class="ll-muted">${escapeHtml(r.group_key)}</div>` : ''}`;
    const pct = r.loss_pct != null
      ? `<span class="${Number(r.loss_pct) >= 20 ? 'll-pct-high' : ''}">${escapeHtml(r.loss_pct)}%</span>`
      : '<span class="ll-muted">-</span>';
    return `
      <tr>
        <td>${name}<div class="ll-bar" style="width:${Math.round((Number(r.dead_qty || 0) / maxDead) * 100)}%"></div></td>
        <td class="num"><strong>${escapeHtml(formatQty(r.dead_qty))}</strong></td>
        <td class="num">${escapeHtml(formatQty(r.reports))}</td>
        ${showValue ? `<td class="num">${escapeHtml(formatMoney(r.loss_value))}</td>` : ''}
        ${showReceived ? `<td class="num">${escapeHtml(formatQty(r.received_qty))}</td><td class="num">${pct}</td>` : ''}
      </tr>`;
  }).join('');
}

function setActiveChip(containerId, attr, value) {
  document.querySelectorAll(`#${containerId} .ll-chip`).forEach((c) => c.classList.toggle('active', c.dataset[attr] === value));
}

// ---------------------------------------------------------------- init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Livestock Losses');

  if (!canOpenStaffExceptMakersPage(session, 'livestock-losses.html')) {
    window.location.href = 'dashboard.html';
    return;
  }

  const dateInput = document.getElementById('lossDateInput');
  dateInput.value = manilaToday();
  dateInput.max = manilaToday();
  dateInput.min = manilaToday(-14);

  await loadLocations();
  renderLines();

  document.getElementById('tabs').addEventListener('click', (e) => {
    const tab = e.target.closest('.ll-tab');
    if (tab) switchTab(tab.dataset.tab);
  });

  // Report tab
  const search = document.getElementById('itemSearchInput');
  search.addEventListener('input', (e) => {
    clearTimeout(itemSearchDebounceHandle);
    const term = e.target.value.trim();
    if (!term) { document.getElementById('itemHits').classList.add('hidden'); return; }
    itemSearchDebounceHandle = setTimeout(async () => renderItemHits(await searchItems(term)), 250);
  });
  const hits = document.getElementById('itemHits');
  const pickHit = (e) => {
    const hit = e.target.closest('.item-hit[data-code]');
    if (hit) addLine(hit.dataset.code, hit.dataset.name, hit.dataset.onhand);
  };
  hits.addEventListener('click', pickHit);
  hits.addEventListener('keydown', (e) => { if (e.key === 'Enter') pickHit(e); });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('.ll-search-wrap')) hits.classList.add('hidden');
  });

  const linesList = document.getElementById('linesList');
  linesList.addEventListener('input', onLineInput);
  linesList.addEventListener('change', onLineInput);
  linesList.addEventListener('click', onLineClick);

  // Super users only: stock shown per line is for the chosen location, so switching starts over.
  const locationSelect = document.getElementById('locationSelect');
  let previousLocation = locationSelect.value;
  locationSelect.addEventListener('change', () => {
    if (lines.length && !window.confirm('Changing the location clears the items added so far. Continue?')) {
      locationSelect.value = previousLocation;
      return;
    }
    previousLocation = locationSelect.value;
    lines = [];
    renderLines();
  });
  document.getElementById('photoInput').addEventListener('change', onPhotoChosen);
  document.getElementById('submitBtn').addEventListener('click', submitReport);

  // History tab
  document.getElementById('statusChips').addEventListener('click', (e) => {
    const chip = e.target.closest('.ll-chip');
    if (!chip) return;
    currentStatus = chip.dataset.status;
    currentPage = 1;
    setActiveChip('statusChips', 'status', currentStatus);
    loadReports();
  });
  document.getElementById('searchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(() => { currentPage = 1; loadReports(); }, 300);
  });
  document.getElementById('prevPageBtn').addEventListener('click', () => { if (currentPage > 1) { currentPage -= 1; loadReports(); } });
  document.getElementById('nextPageBtn').addEventListener('click', () => { currentPage += 1; loadReports(); });
  document.getElementById('reportsList').addEventListener('click', onReportsClick);

  // Summary tab (Super User / Store Manager)
  if (session.isSuperUser || session.isStoreManager) {
    document.getElementById('summaryTabBtn').classList.remove('hidden');
    document.getElementById('sumFromInput').value = manilaToday(-29);
    document.getElementById('sumToInput').value = manilaToday();
    document.getElementById('periodChips').addEventListener('click', (e) => {
      const chip = e.target.closest('.ll-chip');
      if (!chip) return;
      summaryPeriod = chip.dataset.period;
      setActiveChip('periodChips', 'period', summaryPeriod);
      document.getElementById('customDates').classList.toggle('hidden', summaryPeriod !== 'custom');
      loadSummary();
    });
    document.getElementById('groupChips').addEventListener('click', (e) => {
      const chip = e.target.closest('.ll-chip');
      if (!chip) return;
      summaryGroup = chip.dataset.group;
      setActiveChip('groupChips', 'group', summaryGroup);
      loadSummary();
    });
    ['sumFromInput', 'sumToInput', 'sumLocationSelect'].forEach((id) => document.getElementById(id).addEventListener('change', loadSummary));
  }

  // Deep link from Item Ledger Entries' Show Document (?search=LL-000001): open History on it.
  const searchParam = new URLSearchParams(window.location.search).get('search');
  if (searchParam) {
    document.getElementById('searchInput').value = searchParam;
    switchTab('history');
  }
})();
