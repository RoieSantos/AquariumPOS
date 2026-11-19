// New Arrivals page (super users) - sql/supabase_new_arrivals.sql + supabase/functions/new-arrivals-post.
// Builds and saves the "📣 NEW ARRIVALS" banner (company logo + name, drawn on a canvas here and
// uploaded to portal-assets/new-arrivals/banner.png), edits the settings (on/off, announced
// categories, website days), previews the caption, and lists every announcement with Retry / Skip.
// Posting itself is automatic on Receive (js/transferOrders.js kicks the Edge Function; pg_cron is
// the 5-minute backup) - nothing on this page has to be tapped for a post to go out, except saving
// the banner once (the first visit does that by itself if no banner is saved yet).
let currentSession = null;
let settings = null;
let pendingBannerBlob = null;

const SAMPLE_ITEMS = [
  { name: 'Fancy Guppy', category: 'FISH' },
  { name: 'Halfmoon Betta', category: 'FISH' },
  { name: 'Tiger Oscar', category: 'FISH' },
  { name: 'Java Fern', category: 'PLANTS' }
];

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function showError(message) {
  const el = document.getElementById('naError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function authArgs() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

// ---- Banner (1080 x 1080, Facebook square) ----

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('Could not load the logo image.'));
    img.src = url;
  });
}

function drawBubbles(ctx, size) {
  // Fixed positions (not random) so every rebuild looks the same.
  const bubbles = [[90, 160, 26], [150, 300, 14], [960, 120, 34], [1000, 330, 16], [70, 760, 20], [1010, 700, 24],
    [180, 980, 12], [880, 960, 18], [930, 520, 10], [120, 520, 9], [820, 230, 11], [260, 120, 10]];
  ctx.save();
  for (const [x, y, r] of bubbles) {
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255,255,255,0.10)';
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = 'rgba(255,255,255,0.35)';
    ctx.stroke();
  }
  // Light rays from the top.
  ctx.globalAlpha = 0.07;
  ctx.fillStyle = '#ffffff';
  for (let i = 0; i < 5; i++) {
    ctx.beginPath();
    const x = 160 + i * 190;
    ctx.moveTo(x, 0);
    ctx.lineTo(x + 90, 0);
    ctx.lineTo(x - 60 + 40 * i, size);
    ctx.lineTo(x - 180 + 40 * i, size);
    ctx.closePath();
    ctx.fill();
  }
  ctx.restore();
}

async function buildBanner() {
  const info = await fetchCompanyInfo();
  const companyName = (info?.CompanyName || 'RS Pet Stop').toUpperCase();
  const size = 1080;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');

  // Ocean background.
  const bg = ctx.createLinearGradient(0, 0, 0, size);
  bg.addColorStop(0, '#0b3d6e');
  bg.addColorStop(0.55, '#0a6f9c');
  bg.addColorStop(1, '#0fa3b9');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, size, size);
  drawBubbles(ctx, size);

  // Logo in a white circle.
  const cx = size / 2;
  const logoY = 210;
  const logoR = 140;
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,0.35)';
  ctx.shadowBlur = 24;
  ctx.beginPath();
  ctx.arc(cx, logoY, logoR, 0, Math.PI * 2);
  ctx.fillStyle = '#ffffff';
  ctx.fill();
  ctx.restore();
  if (info?.LogoUrl) {
    try {
      const logo = await loadImage(info.LogoUrl);
      const inner = logoR - 12;
      const scale = Math.min((inner * 2) / logo.width, (inner * 2) / logo.height) * 0.95;
      const w = logo.width * scale;
      const h = logo.height * scale;
      ctx.save();
      ctx.beginPath();
      ctx.arc(cx, logoY, inner, 0, Math.PI * 2);
      ctx.clip();
      ctx.drawImage(logo, cx - w / 2, logoY - h / 2, w, h);
      ctx.restore();
    } catch (err) {
      console.warn(err);
    }
  }

  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  // Company name.
  ctx.fillStyle = '#ffffff';
  ctx.font = '800 64px "Segoe UI", Arial, sans-serif';
  ctx.fillText(companyName, cx, 420);

  // Megaphone.
  ctx.font = '190px "Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji", sans-serif';
  ctx.fillText('📣', cx, 595);

  // NEW ARRIVALS.
  ctx.font = '900 140px "Arial Black", "Segoe UI", Arial, sans-serif';
  ctx.lineJoin = 'round';
  ctx.lineWidth = 18;
  ctx.strokeStyle = '#0b2a4a';
  ctx.strokeText('NEW', cx, 765);
  ctx.strokeText('ARRIVALS', cx, 900);
  ctx.fillStyle = '#ffd23f';
  ctx.fillText('NEW', cx, 765);
  ctx.fillText('ARRIVALS', cx, 900);

  // Footer strip.
  ctx.fillStyle = 'rgba(0,0,0,0.28)';
  ctx.fillRect(0, size - 90, size, 90);
  ctx.fillStyle = '#ffffff';
  ctx.font = '600 36px "Segoe UI", Arial, sans-serif';
  ctx.fillText('Fresh fish & aquatic plants · Visit us today!', cx, size - 45);

  return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
}

async function rebuildBanner() {
  const btn = document.getElementById('naRebuildBtn');
  btn.disabled = true;
  showError('');
  try {
    pendingBannerBlob = await buildBanner();
    document.getElementById('naBanner').src = URL.createObjectURL(pendingBannerBlob);
    document.getElementById('naBannerStatus').textContent = 'New banner, not saved yet. Tap Save banner to use it for posts.';
    document.getElementById('naSaveBannerBtn').disabled = false;
  } catch (err) {
    showError(err.message || 'Could not build the banner.');
  } finally {
    btn.disabled = false;
  }
}

// "Upload your own banner" - a finished design (e.g. from Canva) used as-is. Anything over ~4 MB or
// larger than 2048 px is re-encoded to a high-quality JPEG (the portal-assets bucket caps files at
// 5 MB, and Facebook downsizes bigger photos anyway); smaller JPEG/PNG files are kept untouched.
const MAX_UPLOAD_BYTES = 4 * 1024 * 1024;
const MAX_UPLOAD_SIDE = 2048;

async function shrinkForUpload(file) {
  const url = URL.createObjectURL(file);
  try {
    const img = await loadImage(url);
    const longest = Math.max(img.width, img.height);
    if (file.size <= MAX_UPLOAD_BYTES && longest <= MAX_UPLOAD_SIDE && /image\/(png|jpeg)/.test(file.type)) return file;
    const scale = Math.min(1, MAX_UPLOAD_SIDE / longest);
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(img.width * scale);
    canvas.height = Math.round(img.height * scale);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff'; // JPEG has no transparency
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    for (const quality of [0.92, 0.85, 0.75]) {
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality));
      if (blob && blob.size <= MAX_UPLOAD_BYTES) return blob;
    }
    throw new Error('That image is too large even after shrinking - try a smaller file.');
  } finally {
    URL.revokeObjectURL(url);
  }
}

async function onBannerFilePicked(e) {
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!file) return;
  showError('');
  try {
    pendingBannerBlob = await shrinkForUpload(file);
    document.getElementById('naBanner').src = URL.createObjectURL(pendingBannerBlob);
    document.getElementById('naBannerStatus').textContent = `Your banner (${(pendingBannerBlob.size / 1024 / 1024).toFixed(1)} MB), not saved yet. Tap Save banner to use it for posts.`;
    document.getElementById('naSaveBannerBtn').disabled = false;
  } catch (err) {
    showError(err.message || 'Could not read that image.');
  }
}

async function saveBanner() {
  if (!pendingBannerBlob) return;
  const btn = document.getElementById('naSaveBannerBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';
  showError('');
  try {
    const { data: rows, error } = await supabaseClient.rpc('admin_create_new_arrivals_banner_upload', authArgs());
    const info = rows && rows[0];
    if (error || !info) throw error || new Error('Could not prepare the upload.');
    const { error: upErr } = await supabaseClient.storage.from('portal-assets')
      .uploadToSignedUrl(info.storage_path, info.upload_token, pendingBannerBlob, { upsert: true, contentType: pendingBannerBlob.type || 'image/png' });
    if (upErr) throw upErr;
    const url = `${info.public_url}?v=${Date.now()}`;
    const { error: setErr } = await supabaseClient.rpc('admin_set_new_arrival_banner', { ...authArgs(), p_url: url });
    if (setErr) throw setErr;
    settings.banner_url = url;
    pendingBannerBlob = null;
    document.getElementById('naBanner').src = url;
    document.getElementById('naBannerStatus').textContent = 'Saved. This banner is used for every New Arrivals post.';
  } catch (err) {
    showError(err.message || 'Could not save the banner.');
    btn.disabled = false;
  } finally {
    btn.textContent = 'Save banner';
  }
}

// ---- Settings ----

function renderSettings() {
  document.getElementById('naEnabled').checked = !!settings.enabled;
  document.getElementById('naWebsiteDays').value = settings.website_days || 7;
  const chosen = new Set((settings.category_codes || []).map((c) => String(c).toUpperCase()));
  document.getElementById('naCategories').innerHTML = (settings.categories || [])
    .map((c) => `<label><input type="checkbox" value="${escapeHtml(c.code)}" ${chosen.has(String(c.code).toUpperCase()) ? 'checked' : ''} />
      ${escapeHtml(c.code)}${c.description && c.description !== c.code ? ` <span class="muted">(${escapeHtml(c.description)})</span>` : ''}</label>`)
    .join('');
}

async function saveSettings() {
  const status = document.getElementById('naSettingsStatus');
  showError('');
  const codes = Array.from(document.querySelectorAll('#naCategories input:checked')).map((el) => el.value);
  const { error } = await supabaseClient.rpc('admin_save_new_arrival_settings', {
    ...authArgs(),
    p_enabled: document.getElementById('naEnabled').checked,
    p_category_codes: codes,
    p_website_days: Number(document.getElementById('naWebsiteDays').value) || 7
  });
  if (error) {
    showError(error.message);
    return;
  }
  status.textContent = 'Saved.';
  setTimeout(() => { status.textContent = ''; }, 2500);
}

async function previewCaption() {
  const box = document.getElementById('naCaptionPreview');
  box.classList.remove('hidden');
  box.textContent = 'Loading...';
  const { data, error } = await supabaseClient.functions.invoke('new-arrivals-post', {
    body: { action: 'preview', warehouse: document.getElementById('naPreviewStore').value, items: SAMPLE_ITEMS }
  });
  box.textContent = error ? `Preview failed: ${error.message}` : (data?.caption || data?.error || '');
}

// ---- Announcements list ----

const STATUS_BADGE = { Posted: 'badge-success', Pending: 'badge-warning', Posting: 'badge-primary', Failed: 'badge-danger', Skipped: 'badge-neutral' };

function formatWhen(value) {
  if (!value) return '';
  return new Date(value).toLocaleString('en-PH', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

async function loadPosts() {
  const body = document.getElementById('naPostsBody');
  const { data, error } = await supabaseClient.rpc('admin_list_new_arrival_posts', { ...authArgs(), p_limit: 100 });
  if (error) {
    body.innerHTML = `<tr><td colspan="6" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  if (!data || data.length === 0) {
    body.innerHTML = '<tr><td colspan="6" class="muted">No announcements yet. One appears here when a transfer with fish or plants is received at a store.</td></tr>';
    return;
  }
  body.innerHTML = data.map((p) => {
    const items = (p.Items || []).map((i) => escapeHtml(i.name)).join(', ');
    const badge = STATUS_BADGE[p.Status] || 'badge-neutral';
    const link = p.PostUrl ? ` <a href="${escapeHtml(p.PostUrl)}" target="_blank" rel="noopener">View post</a>` : '';
    const err = p.Error ? `<div class="na-err">${escapeHtml(p.Error)}</div>` : '';
    const actions = [];
    if ((p.Status === 'Failed' || p.Status === 'Skipped') && p.Page) actions.push(`<button class="btn btn-secondary btn-sm" data-act="retry" data-id="${p.Id}">Retry</button>`);
    if (p.Status === 'Pending' || p.Status === 'Failed') actions.push(`<button class="btn btn-secondary btn-sm" data-act="skip" data-id="${p.Id}">Skip</button>`);
    return `<tr>
      <td>${escapeHtml(formatWhen(p.CreatedAtUtc))}</td>
      <td>${escapeHtml(p.DocumentNo)}</td>
      <td>${escapeHtml(p.Warehouse || '')}</td>
      <td class="na-items">${items}</td>
      <td><span class="badge ${badge}">${escapeHtml(p.Status)}</span>${link}${err}</td>
      <td style="white-space:nowrap;">${actions.join(' ')}</td>
    </tr>`;
  }).join('');
}

async function onPostAction(e) {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const act = btn.dataset.act;
  if (act === 'retry' && !window.confirm('Post this New Arrivals announcement to Facebook again? If the earlier try may have gone through, check the Page first so it is not posted twice.')) return;
  btn.disabled = true;
  showError('');
  const { error } = await supabaseClient.rpc('admin_set_new_arrival_post_status', { ...authArgs(), p_id: Number(btn.dataset.id), p_action: act });
  if (error) {
    showError(error.message);
    btn.disabled = false;
    return;
  }
  if (act === 'retry') await dispatchNow();
  else await loadPosts();
}

async function dispatchNow() {
  const btn = document.getElementById('naDispatchBtn');
  btn.disabled = true;
  showError('');
  try {
    const { data, error } = await supabaseClient.functions.invoke('new-arrivals-post', { body: { action: 'dispatch' } });
    if (error) throw error;
    if (data?.error) throw new Error(data.error);
  } catch (err) {
    showError(err.message || 'Posting failed.');
  } finally {
    btn.disabled = false;
    await loadPosts();
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('New Arrivals');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  const { data, error } = await supabaseClient.rpc('admin_get_new_arrival_settings', authArgs());
  document.getElementById('naContent').classList.remove('hidden');
  if (error || !data) {
    showError(error?.message || 'Could not load the New Arrivals settings - has supabase_new_arrivals.sql been run?');
    return;
  }
  settings = data;
  renderSettings();

  document.getElementById('naUploadInput').addEventListener('change', onBannerFilePicked);
  document.getElementById('naRebuildBtn').addEventListener('click', rebuildBanner);
  document.getElementById('naSaveBannerBtn').addEventListener('click', saveBanner);
  document.getElementById('naSaveSettingsBtn').addEventListener('click', saveSettings);
  document.getElementById('naPreviewBtn').addEventListener('click', previewCaption);
  document.getElementById('naDispatchBtn').addEventListener('click', dispatchNow);
  document.getElementById('naRefreshBtn').addEventListener('click', loadPosts);
  document.getElementById('naPostsBody').addEventListener('click', onPostAction);

  if (settings.banner_url) {
    document.getElementById('naBanner').src = settings.banner_url;
    document.getElementById('naBannerStatus').textContent = 'Saved. This banner is used for every New Arrivals post.';
  } else {
    // First visit: build and save the banner straight away so the first auto-post has its photo.
    await rebuildBanner();
    await saveBanner();
  }

  loadPosts();
})();
