// Daily Branch Checklist - Opening / Closing / Store Cleaning with a photo each, for the Manager KPI's SOP
// Compliance (sql/supabase_manager_kpi_capture.sql). Store Managers tick their own branch for today; Super Users
// can pick a branch and remove a wrong entry. Photo upload: staff_create_checklist_photo_upload gives a signed
// upload URL, the shrunk JPEG goes straight to the "branch-checklist-photos" bucket, then
// staff_submit_branch_checklist records it (same flow as Defect Items).
let currentSession = null;
let sheet = null;
const photos = {}; // type -> { blob, name }

const TYPES = [
  ['Opening', '🔓 Opening', 'Store opened: lights, displays, tanks checked, cash float ready'],
  ['Cleaning', '🧽 Store Cleaning', 'Floor, glass, tanks and counters cleaned'],
  ['Closing', '🔒 Closing', 'Store closed: tanks/filters on, cash counted, doors locked']
];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function creds() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

function manilaToday() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

function shiftMonthKey(key, months) {
  const [y, m] = key.split('-').map(Number);
  const d = new Date(y, m - 1 + months, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function selectedMonthKey() {
  return document.getElementById('bcMonthInput').value || manilaToday().slice(0, 7);
}

function dayLabel(key) {
  const [y, m, d] = key.split('-').map(Number);
  return `${new Date(y, m - 1, d).toLocaleDateString('en-US', { weekday: 'short' })} ${MONTHS[m - 1]} ${d}`;
}

function entry(date, type) {
  return sheet.entries.find((e) => e.date === date && e.type === type);
}

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

function renderToday() {
  const today = sheet.today;
  const isThisMonth = today.slice(0, 7) === selectedMonthKey();
  document.getElementById('todayHeading').textContent = `Today - ${dayLabel(today)}`;
  const box = document.getElementById('todayItems');
  if (!isThisMonth) {
    box.innerHTML = '<p class="muted">Checklists can only be done for today - switch to this month.</p>';
    return;
  }
  box.innerHTML = TYPES.map(([type, label, hint]) => {
    const done = entry(today, type);
    const pending = photos[type];
    return `
      <div class="bc-item${done ? ' is-done' : ''}" data-type="${type}">
        <h3><span>${label}</span>${done ? '<span class="badge badge-success">Done</span>' : '<span class="badge badge-warning">To do</span>'}</h3>
        <div class="muted" style="font-size:13px;">${hint}</div>
        ${done ? `<a href="${escapeHtml(done.photo_url)}" target="_blank" rel="noopener"><img src="${escapeHtml(done.photo_url)}" alt="${escapeHtml(type)} photo" /></a>
          <div class="muted" style="font-size:12px;">${escapeHtml(done.done_by)} · ${new Date(done.done_at).toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' })}${done.note ? ' · ' + escapeHtml(done.note) : ''}</div>` : ''}
        ${pending ? `<img src="${pending.preview}" alt="New photo preview" />` : ''}
        <label class="btn btn-secondary btn-sm bc-pick">📷 ${done ? 'Replace photo' : 'Take photo'}
          <input type="file" accept="image/*" capture="environment" data-type="${type}" />
        </label>
        <textarea rows="2" placeholder="Note (optional)" data-note="${type}"></textarea>
        <button class="btn btn-primary btn-sm" type="button" data-submit="${type}" ${pending ? '' : 'disabled'}>${done ? 'Save new photo' : 'Mark done'}</button>
        <div class="error-text hidden" data-err="${type}"></div>
        ${done && sheet.can_pick_branch ? `<button class="btn btn-secondary btn-sm" type="button" data-remove="${type}">Remove (Super User)</button>` : ''}
      </div>`;
  }).join('');

  box.querySelectorAll('input[type=file]').forEach((inp) => inp.addEventListener('change', async (e) => {
    const type = e.target.dataset.type;
    const file = e.target.files && e.target.files[0];
    if (!file) return;
    try {
      const blob = await compressImage(file);
      photos[type] = { blob, name: (file.name || type).replace(/\.[^.]+$/, '') + '.jpg', preview: URL.createObjectURL(blob) };
      renderToday();
    } catch (err) {
      showItemError(type, err.message);
    }
  }));
  box.querySelectorAll('[data-submit]').forEach((btn) => btn.addEventListener('click', () => submit(btn.dataset.submit, btn)));
  box.querySelectorAll('[data-remove]').forEach((btn) => btn.addEventListener('click', () => removeEntry(btn.dataset.remove)));
}

function showItemError(type, message) {
  const el = document.querySelector(`[data-err="${type}"]`);
  if (!el) return;
  el.textContent = message;
  el.classList.remove('hidden');
}

async function submit(type, btn) {
  const photo = photos[type];
  if (!photo) return;
  btn.disabled = true;
  btn.textContent = 'Uploading...';
  try {
    const { data, error } = await supabaseClient.rpc('staff_create_checklist_photo_upload', { ...creds(), p_file_name: `${sheet.branch}_${type}_${photo.name}` });
    if (error || !data || !data[0]) throw new Error('Could not prepare the photo upload: ' + (error ? error.message : 'unknown error'));
    const { storage_path, upload_token, public_url } = data[0];
    const up = await supabaseClient.storage.from('branch-checklist-photos').uploadToSignedUrl(storage_path, upload_token, photo.blob);
    if (up.error) throw new Error('Photo upload failed: ' + up.error.message);
    const note = document.querySelector(`[data-note="${type}"]`).value;
    const { error: saveError } = await supabaseClient.rpc('staff_submit_branch_checklist', {
      ...creds(), p_warehouse: sheet.branch, p_type: type, p_photo_path: storage_path, p_photo_url: public_url, p_note: note
    });
    if (saveError) throw new Error(saveError.message);
    delete photos[type];
    await loadSheet();
  } catch (err) {
    btn.disabled = false;
    btn.textContent = 'Try again';
    showItemError(type, err.message);
  }
}

async function removeEntry(type) {
  if (!confirm(`Remove today's ${type} checklist for ${sheet.branch}?`)) return;
  const { error } = await supabaseClient.rpc('admin_delete_branch_checklist', { ...creds(), p_warehouse: sheet.branch, p_date: sheet.today, p_type: type });
  if (error) { showItemError(type, error.message); return; }
  await loadSheet();
}

function renderMonth() {
  const today = sheet.today;
  const start = sheet.checklist_start || today;
  const open = new Set(sheet.open_days || []);
  const eod = new Set(sheet.eod_days || []);
  const days = [...open].filter((d) => d <= today).sort().reverse();
  let req = 0; let done = 0;
  const mark = (ok, url) => ok ? `<span class="bc-yes">${url ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener" title="Open photo">✓</a>` : '✓'}</span>` : '<span class="bc-no">✗</span>';
  const rows = days.map((d) => {
    const counts = d < today; // today is still in progress
    const chk = TYPES.map(([type]) => {
      if (d < start) return '<span class="muted">-</span>';
      const e = entry(d, type);
      if (counts) { req += 1; if (e) done += 1; }
      return counts || e ? mark(!!e, e && e.photo_url) : '<span class="muted">…</span>';
    });
    if (counts) { req += 1; if (eod.has(d)) done += 1; }
    return `<tr><td>${dayLabel(d)}${d === today ? ' <span class="muted">(today)</span>' : ''}</td>
      ${chk.map((c) => `<td class="c">${c}</td>`).join('')}
      <td class="c">${counts || eod.has(d) ? mark(eod.has(d)) : '<span class="muted">…</span>'}</td></tr>`;
  });
  document.getElementById('monthRows').innerHTML = rows.length ? rows.join('') : '<tr><td colspan="5" class="muted">No open days yet this month.</td></tr>';
  document.getElementById('monthSummary').textContent = req
    ? `${done} of ${req} daily tasks done (${Math.round((done / req) * 100)}%) over the open days before today. Checklists count from ${start}.`
    : `Nothing due yet. Checklists count from ${start}.`;
}

async function loadSheet() {
  const loadingEl = document.getElementById('bcLoading');
  const errorEl = document.getElementById('bcError');
  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  const branchSelect = document.getElementById('branchSelect');
  const key = selectedMonthKey();
  document.getElementById('nextMonthBtn').disabled = key >= manilaToday().slice(0, 7);
  const { data, error } = await supabaseClient.rpc('staff_get_branch_checklist', {
    ...creds(), p_month: `${key}-01`, p_warehouse: branchSelect.value || null
  });
  loadingEl.classList.add('hidden');
  if (error) {
    errorEl.textContent = /staff_get_branch_checklist/.test(error.message) ? 'Run supabase_manager_kpi_capture.sql in Supabase first.' : error.message;
    errorEl.classList.remove('hidden');
    document.getElementById('bcResults').classList.add('hidden');
    return;
  }
  sheet = data;
  if (sheet.can_pick_branch) {
    branchSelect.innerHTML = sheet.branches.map((b) => `<option value="${escapeHtml(b)}">${escapeHtml(b)}</option>`).join('');
    branchSelect.value = sheet.branch;
    branchSelect.classList.remove('hidden');
  }
  document.getElementById('bcTitle').textContent = `Daily Branch Checklist - ${sheet.branch}`;
  document.getElementById('bcResults').classList.remove('hidden');
  renderToday();
  renderMonth();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Daily Checklist');

  if (!session.isSuperUser && !session.isStoreManager) {
    document.getElementById('bcLoading').classList.add('hidden');
    const errorEl = document.getElementById('bcError');
    errorEl.textContent = 'Only Store Managers and Super Users can use the branch checklist.';
    errorEl.classList.remove('hidden');
    return;
  }

  const monthInput = document.getElementById('bcMonthInput');
  monthInput.max = manilaToday().slice(0, 7);
  monthInput.value = manilaToday().slice(0, 7);
  monthInput.addEventListener('change', loadSheet);
  document.getElementById('prevMonthBtn').addEventListener('click', () => { monthInput.value = shiftMonthKey(selectedMonthKey(), -1); loadSheet(); });
  document.getElementById('nextMonthBtn').addEventListener('click', () => { monthInput.value = shiftMonthKey(selectedMonthKey(), 1); loadSheet(); });
  document.getElementById('branchSelect').addEventListener('change', loadSheet);

  await loadSheet();
})();
