// Video Ad Builder page (super users) - build 1080x1920 Reels ads from scenes (animation or your own
// photo/video + text), preview them live and export an MP4 in the browser. Drawing/encoding is in
// js/videoAdRenderer.js; saved ads and uploaded media: sql/supabase_video_ads.sql.
let currentSession = null;
let ads = [];
let current = null;           // { id, name, config }
let dirty = false;
let uploading = 0;
let exporting = false;
let renderer = null;
let playing = true;
let cur = 0;
let t0 = 0;
let rafId = null;
let activeSceneIndex = -1;

const MAX_SCENES = 12;
const MAX_VIDEO_BYTES = 50 * 1024 * 1024;
const ACCENTS = ['#3fe0d0', '#ffd166', '#ff7a59', '#7cc8ff', '#a3e635'];
const STYLES = [
  { key: 'logo', label: '⭐ Logo' },
  { key: 'tank', label: '📐 Tank drawing' },
  { key: 'stand', label: '🔩 Stand drawing' },
  { key: 'sump', label: '🌀 Sump drawing' },
  { key: 'payments', label: '💳 Payments' },
  { key: 'delivery', label: '🚚 Delivery' },
  { key: 'photo', label: '📷 Photo / video' },
  { key: 'water', label: '🌊 Text only' },
  { key: 'cta', label: '📣 End card' }
];

// Google voices for the voice-over (supabase/functions/video-ad-voice).
const VOICES = [
  { name: 'fil-PH-Wavenet-A', label: 'Filipino - female 1' },
  { name: 'fil-PH-Wavenet-B', label: 'Filipino - female 2' },
  { name: 'fil-PH-Wavenet-C', label: 'Filipino - male 1' },
  { name: 'fil-PH-Wavenet-D', label: 'Filipino - male 2' },
  { name: 'en-US-Neural2-F', label: 'English - female 1' },
  { name: 'en-US-Neural2-C', label: 'English - female 2' },
  { name: 'en-US-Neural2-J', label: 'English - male 1' },
  { name: 'en-US-Neural2-D', label: 'English - male 2' }
];
const VOICE_SAMPLE = 'Hi! Welcome to RS Pet Stop - custom aquariums, made to your size.';

const $ = (id) => document.getElementById(id);

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

function templateCustomAquarium() {
  return {
    version: 1,
    accent: '#3fe0d0',
    brand: { name: 'RS Pet Stop', logo: 'icons/icon-512.png' },
    music: { track: 'upbeat', volume: 0.8 },
    scenes: [
      { style: 'logo', duration: 3, headline: 'Dream tank?', sub: "We'll build it - any size you want.", bullets: [] },
      { style: 'tank', duration: 3.2, headline: 'Made to order', sub: 'Your exact length, width & height', bullets: [], dims: [48, 18, 20],
        options: { rimless: true, lowIron: true, light: true, aquascape: true, cabinet: true } },
      { style: 'photo', duration: 3, headline: 'Built your way', sub: '', media: 'icons/Aio sample1.jpg', mediaType: 'image',
        bullets: ['Rimless or with rim', '3mm-12mm or tempered glass', 'Black or clear sealant'] },
      { style: 'stand', duration: 3, headline: 'Matching stands', sub: "Built to your tank's size", bullets: [], dims: [48, 18, 30], layers: 2, paint: 'black' },
      { style: 'sump', duration: 3, headline: 'Sump filtration too', sub: 'Filter, bio media & return pump', bullets: [], dims: [36, 14, 16] },
      { style: 'payments', duration: 3.2, headline: 'Pay your way', sub: 'Cards, e-wallets, bank transfer or cash', bullets: [] },
      { style: 'delivery', duration: 3.8, headline: 'We deliver it safely', sub: 'Our own team - we handle the rest at your home', bullets: [] },
      { style: 'cta', duration: 3.2, headline: 'Get your quote today', button: 'rspetstop.com',
        bullets: ['Message us on Facebook', 'or chat with Alice on our website'], footer: 'Amaya & GMA branches' }
    ]
  };
}

function templateBlank() {
  return {
    version: 1,
    accent: '#3fe0d0',
    brand: { name: 'RS Pet Stop', logo: 'icons/icon-512.png' },
    music: { track: 'upbeat', volume: 0.8 },
    scenes: [
      { style: 'logo', duration: 3, headline: 'Your headline here', sub: 'A short line under it', bullets: [] },
      { style: 'cta', duration: 3, headline: 'Message us today', button: 'rspetstop.com', bullets: [], footer: 'Amaya & GMA branches' }
    ]
  };
}

// The swimming-fish scene became the Logo scene - ads saved (or AI-written) before that say 'fish'.
function renameOldStyles(scenes) {
  scenes.forEach((s) => { if (s.style === 'fish') s.style = 'logo'; });
  return scenes;
}

// Default sizes (inches) for the drawn styles - same as js/videoAdRenderer.js DEFAULT_DIMS.
const BUILD_DIMS = { tank: [48, 18, 20], stand: [48, 18, 30], sump: [30, 14, 16] };

function newScene(style) {
  const base = { style, duration: 3, headline: 'New scene', sub: '', bullets: [] };
  if (BUILD_DIMS[style]) base.dims = BUILD_DIMS[style].slice();
  if (style === 'stand') Object.assign(base, { layers: 2, paint: 'black' });
  if (style === 'cta') Object.assign(base, { headline: 'Message us today', button: 'rspetstop.com', footer: '' });
  if (style === 'payments') Object.assign(base, { headline: 'Pay your way', sub: 'Cards, e-wallets, bank transfer or cash' });
  if (style === 'delivery') Object.assign(base, { duration: 3.8, headline: 'We deliver it safely', sub: 'Our own team - we handle the rest at your home' });
  return base;
}

// ---------------------------------------------------------------------------
// Small UI helpers
// ---------------------------------------------------------------------------

let toastTimer = null;
function toast(message, isError = false) {
  const el = $('vaToast');
  el.textContent = message;
  el.classList.toggle('va-toast-error', isError);
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), isError ? 8000 : 4000);
}

function vaConfirm(title, message, yesLabel = 'OK') {
  return new Promise((resolve) => {
    const modal = $('vaConfirmModal');
    $('vaConfirmTitle').textContent = title;
    $('vaConfirmMessage').textContent = message;
    $('vaConfirmYesBtn').textContent = yesLabel;
    const done = (value) => {
      modal.classList.add('hidden');
      $('vaConfirmYesBtn').onclick = null; $('vaConfirmNoBtn').onclick = null; modal.onclick = null;
      resolve(value);
    };
    $('vaConfirmYesBtn').onclick = () => done(true);
    $('vaConfirmNoBtn').onclick = () => done(false);
    modal.onclick = (e) => { if (e.target === modal) done(false); };
    modal.classList.remove('hidden');
  });
}

function setDirty(value) {
  dirty = value;
  $('dirtyNote').classList.toggle('hidden', !dirty);
}

function fmtDate(value) {
  if (!value) return '';
  return new Date(value).toLocaleString('en-PH', { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function adSeconds(config) {
  return (config.scenes || []).reduce((a, s) => a + Math.max(0.5, Number(s.duration) || 3), 0);
}

function slug(text) {
  return String(text || 'video-ad').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'video-ad';
}

// ---------------------------------------------------------------------------
// Saved ads list
// ---------------------------------------------------------------------------

async function loadAds() {
  $('adList').innerHTML = '<p class="muted">Loading...</p>';
  const { data, error } = await supabaseClient.rpc('admin_video_ad_list', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) {
    $('adList').innerHTML = `<p class="error-text">Could not load ads: ${escapeHtml(error.message)}</p>`;
    return;
  }
  ads = data || [];
  renderAdList();
}

function renderAdList() {
  if (!ads.length) {
    $('adList').innerHTML = '<div class="va-empty"><b>No saved ads yet</b>Start from the Custom Aquarium template - it is a finished ad you can change.</div>';
    return;
  }
  $('adList').innerHTML = ads.map((ad) => {
    const scenes = (ad.config.scenes || []).length;
    return `<div class="va-ad" data-id="${ad.ad_id}">
      <div class="va-ad-main">
        <div class="va-ad-title">${escapeHtml(ad.name)}</div>
        <div class="va-ad-meta">${scenes} scene${scenes === 1 ? '' : 's'} &middot; ${adSeconds(ad.config).toFixed(1)}s &middot;
          updated ${escapeHtml(fmtDate(ad.updated_at_utc))}${ad.updated_by ? ' by ' + escapeHtml(ad.updated_by) : ''}</div>
      </div>
      <div class="va-ad-actions">
        <button class="btn btn-primary btn-sm" data-act="open" type="button">Open</button>
        <button class="btn btn-secondary btn-sm" data-act="copy" type="button">Duplicate</button>
        <button class="btn btn-danger btn-sm" data-act="delete" type="button">Delete</button>
      </div>
    </div>`;
  }).join('');
}

async function onAdListClick(e) {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const ad = ads.find((a) => String(a.ad_id) === btn.closest('.va-ad').dataset.id);
  if (!ad) return;
  if (btn.dataset.act === 'open') {
    openEditor(ad.ad_id, ad.name, JSON.parse(JSON.stringify(ad.config)));
  } else if (btn.dataset.act === 'copy') {
    const { error } = await supabaseClient.rpc('admin_video_ad_save', {
      p_admin_username: currentSession.username, p_admin_password: currentSession.password,
      p_ad_id: null, p_name: ad.name + ' (copy)', p_config: ad.config
    });
    if (error) { toast('Could not duplicate: ' + error.message, true); return; }
    toast('Duplicated.');
    loadAds();
  } else if (btn.dataset.act === 'delete') {
    if (!(await vaConfirm('Delete ad?', `"${ad.name}" will be deleted. Videos you already exported are not affected.`, 'Delete'))) return;
    const { error } = await supabaseClient.rpc('admin_video_ad_delete', {
      p_admin_username: currentSession.username, p_admin_password: currentSession.password, p_ad_id: ad.ad_id
    });
    if (error) { toast('Could not delete: ' + error.message, true); return; }
    toast('Deleted.');
    loadAds();
  }
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

async function openEditor(id, name, config) {
  config.scenes = renameOldStyles(config.scenes || []);
  config.brand = config.brand || { name: '', logo: '' };
  config.accent = config.accent || '#3fe0d0';
  config.music = config.music || { track: 'none', volume: 0.8 };
  config.voice = config.voice || { name: '', rate: 1, volume: 1 };
  previewAudioStop();
  musicBuffer = null;
  musicKey = '';
  current = { id, name, config };
  setDirty(id == null);
  activeSceneIndex = -1;
  $('listView').classList.add('hidden');
  $('editorView').classList.remove('hidden');
  $('exportStatus').textContent = '';
  $('aiReviseStatus').textContent = '';
  renderAdFields();
  renderMusic();
  renderVoice();
  renderAiResult();
  renderScenes();
  await renderer.setAd(config);
  renderScenes(); // media thumbnails/failed states are known now
  cur = 0; t0 = performance.now(); playing = true; $('playBtn').textContent = 'Pause';
  if (!rafId) rafId = requestAnimationFrame(tick);
  window.scrollTo(0, 0);
}

async function closeEditor() {
  if (exporting) return;
  if (dirty && !(await vaConfirm('Leave without saving?', 'Your changes to this ad have not been saved.', 'Leave'))) return;
  if (rafId) cancelAnimationFrame(rafId);
  rafId = null;
  renderer.pauseVideos();
  previewAudioStop();
  current = null;
  setDirty(false);
  $('editorView').classList.add('hidden');
  $('listView').classList.remove('hidden');
  loadAds();
}

function renderAdFields() {
  const c = current.config;
  $('adName').value = current.name || '';
  $('brandName').value = c.brand.name || '';
  $('accent').value = c.accent;
  $('logoThumb').src = c.brand.logo || '';
  $('logoThumb').classList.toggle('hidden', !c.brand.logo);
  $('showLogo').checked = c.brand.showLogo !== false;
  const row = $('accentRow');
  row.querySelectorAll('.va-swatch').forEach((el) => el.remove());
  ACCENTS.forEach((hex) => {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'va-swatch'; b.style.background = hex; b.title = hex;
    b.onclick = () => { c.accent = hex; $('accent').value = hex; setDirty(true); };
    row.appendChild(b);
  });
}

function sceneStart(index) {
  return renderer.timeline()[index]?.visStart ?? 0;
}

function renderScenes() {
  const scenes = current.config.scenes;
  $('sceneList').innerHTML = scenes.map((s, i) => sceneCardHtml(s, i, scenes.length)).join('');
  $('addSceneBtn').disabled = scenes.length >= MAX_SCENES;
  activeSceneIndex = -1;
}

function sceneCardHtml(s, i, count) {
  const isCta = s.style === 'cta';
  const styles = STYLES.map((st) => `<button type="button" class="va-style${st.key === s.style ? ' active' : ''}" data-style="${st.key}">${st.label}</button>`).join('');
  const lines = (s.bullets || []).join('\n');
  let fields = `
    <div class="va-grid">
      <label class="va-label">Headline <input type="text" data-k="headline" maxlength="60" value="${escapeHtml(s.headline)}" /></label>
      <label class="va-label">Seconds <input type="number" data-k="duration" min="1" max="10" step="0.1" value="${escapeHtml(s.duration)}" /></label>
    </div>`;
  if (isCta) {
    fields += `
      <label class="va-label">Button text (website, phone or "Message us") <input type="text" data-k="button" maxlength="30" value="${escapeHtml(s.button)}" /></label>
      <label class="va-label">Lines under the button (one per line) <textarea data-k="bullets" rows="2">${escapeHtml(lines)}</textarea></label>
      <label class="va-label">Bottom line (e.g. branches, promo dates) <input type="text" data-k="footer" maxlength="50" value="${escapeHtml(s.footer)}" /></label>`;
  } else {
    fields += `
      <label class="va-label">Sub-text <input type="text" data-k="sub" maxlength="70" value="${escapeHtml(s.sub)}" /></label>
      <label class="va-label">Checklist - up to 4 short lines, one per line (optional) <textarea data-k="bullets" rows="2">${escapeHtml(lines)}</textarea></label>`;
  }
  fields += `
      <label class="va-label">🎙 Voice-over - what the voice says during this scene (optional) <span class="va-say-status">${sayStatus(s)}</span>
        <input type="text" data-k="say" maxlength="300" value="${escapeHtml(s.say)}" placeholder="e.g. Gawa namin, kahit anong size!" /></label>`;
  if (BUILD_DIMS[s.style]) {
    const d = s.dims || BUILD_DIMS[s.style];
    const what = { tank: 'Tank', stand: 'Stand', sump: 'Sump' }[s.style];
    fields += `
      <div class="va-label">${what} size in inches - length x width x height (drawn to this shape)
        <div class="va-dims">
          <input type="number" data-dim="0" min="1" max="200" value="${escapeHtml(d[0])}" aria-label="Length" placeholder="Length" />
          <input type="number" data-dim="1" min="1" max="100" value="${escapeHtml(d[1])}" aria-label="Width" placeholder="Width" />
          <input type="number" data-dim="2" min="1" max="100" value="${escapeHtml(d[2])}" aria-label="Height" placeholder="Height" />
        </div>
      </div>`;
  }
  if (s.style === 'tank') {
    const o = s.options || {};
    const checks = VideoAdRenderer.TANK_OPTIONS.map(([k, label]) =>
      `<label class="va-opt"><input type="checkbox" data-opt="${k}"${o[k] ? ' checked' : ''} /> ${label}</label>`).join('');
    const count = (k, max) => Array.from({ length: max + 1 }, (_, n) => `<option value="${n}"${n === (Number(o[k]) || 0) ? ' selected' : ''}>${n || 'None'}</option>`).join('');
    fields += `
      <div class="va-label">Tank options - each shows on the drawing and as a tag under it
        <div class="va-opts">${checks}</div>
      </div>
      <div class="va-grid">
        <label class="va-label">Holes (drilled) <select data-opt="holes">${count('holes', 4)}</select></label>
        <label class="va-label">Dividers <select data-opt="dividers">${count('dividers', 3)}</select></label>
      </div>
      <label class="va-label">Other accessories, comma separated (e.g. Filter, Heater, Chiller) <input type="text" data-opt="extras" maxlength="120" value="${escapeHtml(o.extras)}" /></label>`;
  }
  if (s.style === 'payments') {
    const on = (k) => !Array.isArray(s.methods) || !s.methods.length || s.methods.includes(k);
    const checks = VideoAdRenderer.PAY_METHODS.map(([k, label]) =>
      `<label class="va-opt"><input type="checkbox" data-method="${k}"${on(k) ? ' checked' : ''} /> ${label}</label>`).join('');
    fields += `
      <div class="va-label">Payment methods to show (each drops in as a card)
        <div class="va-opts">${checks}</div>
      </div>`;
  }
  if (s.style === 'delivery') {
    fields += `<p class="muted" style="margin:0; font-size:12.5px;">Our truck (with your logo and shop name) drives up to a house and the wrapped aquarium goes to the door. The animation takes about 3 seconds - keep this scene at least 3.5 seconds long.</p>`;
  }
  if (s.style === 'stand') {
    const layers = s.layers || 2;
    fields += `
      <div class="va-grid">
        <label class="va-label">Layers
          <select data-k="layers">${[1, 2, 3, 4].map((n) => `<option value="${n}"${n === layers ? ' selected' : ''}>${n} layer${n > 1 ? 's' : ''}</option>`).join('')}</select>
        </label>
        <label class="va-label">Paint
          <select data-k="paint">
            <option value="black"${s.paint !== 'white' ? ' selected' : ''}>Black</option>
            <option value="white"${s.paint === 'white' ? ' selected' : ''}>White</option>
          </select>
        </label>
      </div>`;
  }
  if (s.style === 'photo') {
    const isVid = s.media && VideoAdRenderer.isVideo(s.media, s.mediaType);
    const failed = s.media && renderer.isMediaFailed(s.media);
    const busy = s.media && s.media.startsWith('blob:');
    const thumb = !s.media ? '<div class="va-media-thumb"></div>'
      : isVid ? `<video class="va-media-thumb" src="${escapeHtml(s.media)}" muted playsinline preload="metadata" crossorigin="anonymous"></video>`
      : `<img class="va-media-thumb" src="${escapeHtml(s.media)}" alt="" crossorigin="anonymous" />`;
    fields += `
      <div class="va-media">
        ${thumb}
        <div class="va-media-info">
          <b>${!s.media ? 'No photo or video yet' : busy ? 'Uploading...' : failed ? 'Could not load this file' : isVid ? 'Your video' : 'Your photo'}</b>
          ${!s.media ? 'Until you add one, this scene shows the water background.' : isVid ? 'Plays muted; loops if shorter than the scene.' : 'Slow zoom while it shows.'}
        </div>
        <label class="btn btn-secondary btn-sm" for="media${i}">${s.media ? 'Change' : 'Choose photo / video'}</label>
        <input type="file" id="media${i}" data-media="${i}" accept="image/*,video/mp4,video/webm,video/quicktime" />
      </div>`;
  }
  return `<div class="va-scene" data-i="${i}">
    <div class="va-scene-head">
      <span class="va-scene-num" data-jump="${i}" title="Preview from here">${i + 1}</span>
      <span class="va-scene-title" data-jump="${i}" title="Preview from here">${escapeHtml(s.headline || 'Scene ' + (i + 1))}</span>
      <span class="va-scene-tools">
        <button class="va-icon-btn" data-move="-1" type="button" title="Move up" ${i === 0 ? 'disabled' : ''}>&uarr;</button>
        <button class="va-icon-btn" data-move="1" type="button" title="Move down" ${i === count - 1 ? 'disabled' : ''}>&darr;</button>
        <button class="va-icon-btn" data-dup type="button" title="Duplicate" ${count >= MAX_SCENES ? 'disabled' : ''}>&#x2398;</button>
        <button class="va-icon-btn" data-del type="button" title="Delete" ${count <= 1 ? 'disabled' : ''}>&times;</button>
      </span>
    </div>
    <div class="va-styles">${styles}</div>
    <div class="va-fields">${fields}</div>
  </div>`;
}

function onSceneInput(e) {
  const card = e.target.closest('.va-scene');
  if (!card) return;
  const s = current.config.scenes[Number(card.dataset.i)];
  const k = e.target.dataset.k;
  if (k === 'bullets') {
    s.bullets = e.target.value.split('\n').map((x) => x.trim()).filter(Boolean).slice(0, s.style === 'cta' ? 3 : 4);
  } else if (k === 'duration') {
    const n = Number(e.target.value);
    if (!n) return;
    s.duration = Math.min(10, Math.max(1, n));
  } else if (k === 'layers') {
    s.layers = Number(e.target.value) || 2;
  } else if (k) {
    s[k] = e.target.value;
    if (k === 'headline') card.querySelector('.va-scene-title').textContent = s.headline || 'Scene ' + (Number(card.dataset.i) + 1);
    if (k === 'say') { card.querySelector('.va-say-status').textContent = sayStatus(s); renderVoice(); }
  } else if (e.target.dataset.method) {
    s.methods = [...card.querySelectorAll('input[data-method]')].filter((el) => el.checked).map((el) => el.dataset.method);
  } else if (e.target.dataset.opt) {
    const opt = e.target.dataset.opt;
    s.options = s.options || {};
    s.options[opt] = e.target.type === 'checkbox' ? e.target.checked
      : e.target.tagName === 'SELECT' ? Number(e.target.value) || 0 : e.target.value;
  } else if (e.target.dataset.dim != null) {
    s.dims = s.dims || [48, 18, 20];
    s.dims[Number(e.target.dataset.dim)] = Math.max(0, Number(e.target.value) || 0);
  } else {
    return;
  }
  setDirty(true);
}

function onSceneClick(e) {
  const card = e.target.closest('.va-scene');
  if (!card) return;
  const i = Number(card.dataset.i);
  const scenes = current.config.scenes;
  const s = scenes[i];

  const jump = e.target.closest('[data-jump]');
  if (jump) { seekTo(sceneStart(i) + 0.05); return; }

  const styleBtn = e.target.closest('[data-style]');
  if (styleBtn && styleBtn.dataset.style !== s.style) {
    const style = styleBtn.dataset.style;
    const from = s.style;
    s.style = style;
    if (BUILD_DIMS[style]) {
      const d = Array.isArray(s.dims) ? s.dims : null;
      // A stand for a tank keeps the tank's footprint; otherwise start from that style's usual size.
      if (style === 'stand' && from === 'tank' && d) s.dims = [d[0], d[1], BUILD_DIMS.stand[2]];
      else if (!d || (from !== style && BUILD_DIMS[from])) s.dims = BUILD_DIMS[style].slice();
    }
    if (style === 'stand') { s.layers = s.layers || 2; s.paint = s.paint || 'black'; }
    if (style === 'cta' && s.button == null) s.button = 'rspetstop.com';
    if (style === 'delivery' && s.duration < 3.6) s.duration = 3.8;
    finishStructuralChange(i);
    return;
  }

  const move = e.target.closest('[data-move]');
  if (move) {
    const j = i + Number(move.dataset.move);
    if (j < 0 || j >= scenes.length) return;
    [scenes[i], scenes[j]] = [scenes[j], scenes[i]];
    finishStructuralChange(j);
    return;
  }
  if (e.target.closest('[data-dup]')) {
    if (scenes.length >= MAX_SCENES) return;
    scenes.splice(i + 1, 0, JSON.parse(JSON.stringify(s)));
    finishStructuralChange(i + 1);
    return;
  }
  if (e.target.closest('[data-del]')) {
    if (scenes.length <= 1) return;
    scenes.splice(i, 1);
    finishStructuralChange(Math.min(i, scenes.length - 1));
  }
}

function finishStructuralChange(focusIndex) {
  setDirty(true);
  renderScenes();
  renderer.loadAll();
  seekTo(sceneStart(focusIndex) + 0.05);
}

function seekTo(t) {
  cur = Math.max(0, Math.min(t, renderer.totalDuration() - 0.01));
  t0 = performance.now() - cur * 1000;
}

// ---------------------------------------------------------------------------
// Music (js/videoAdMusic.js) - picker, preview playback, soundtrack for export
// ---------------------------------------------------------------------------

let musicBuffer = null;   // finished soundtrack for the current ad length/settings
let musicKey = '';        // settings musicBuffer was built for
let musicBuildId = 0;
let musicTimer = null;
let soundOn = false;
let audioCtx = null;
let audioSrc = null;
let audioStartedAt = 0;
let audioOffset = 0;

const MUSIC_NOTES = {
  none: 'No music. You can still add a song in the Facebook/Instagram Reels editor when you post.',
  custom: 'Only use a song you have the rights to. Facebook and Instagram may mute or block videos with copyrighted music.',
  builtin: 'Made by the portal, so it is free to use and safe to post. It is built to fit the exact length of your ad.'
};

function renderMusic() {
  const m = current.config.music;
  const choices = [{ key: 'none', label: '🔇 None' }, ...VideoAdMusic.MOODS, { key: 'custom', label: '🎤 Your own song' }];
  $('musicChoices').innerHTML = choices.map((c) =>
    `<button type="button" class="va-style${c.key === m.track ? ' active' : ''}" data-track="${c.key}">${c.label}</button>`).join('');
  const custom = m.track === 'custom';
  $('customSongRow').classList.toggle('hidden', !custom);
  $('musicVolumeRow').classList.toggle('hidden', m.track === 'none');
  $('songName').textContent = m.src && m.src.startsWith('blob:') ? 'Uploading...' : (m.name || 'No song chosen');
  $('songPickLabel').textContent = m.src ? 'Change song' : 'Choose song';
  $('songStart').value = m.start || 0;
  $('musicVolume').value = Math.round((m.volume == null ? 0.8 : m.volume) * 100);
  $('musicNote').textContent = m.track === 'none' ? MUSIC_NOTES.none : custom ? MUSIC_NOTES.custom : MUSIC_NOTES.builtin;
}

// The soundtrack = music + voice-over clips; 'none' when there is neither.
function currentMusicKey() {
  const m = current.config.music;
  const clips = voiceClips();
  const noMusic = !m || m.track === 'none' || (m.track === 'custom' && !m.src);
  if (noMusic && !clips.length) return 'none';
  return JSON.stringify([noMusic ? 'none' : m.track, m.src || '', Number(m.start) || 0, m.volume, renderer.totalDuration().toFixed(2),
    clips, current.config.voice.volume]);
}

function buildSoundtrack() {
  return VideoAdMusic.buildTrack(current.config.music, renderer.totalDuration(), voiceClips(), current.config.voice.volume);
}

// Rebuilds the soundtrack a moment after the settings or the ad's length stop changing.
function scheduleMusicBuild() {
  clearTimeout(musicTimer);
  musicTimer = setTimeout(async () => {
    const id = ++musicBuildId;
    const key = currentMusicKey();
    if (key === 'none') { musicBuffer = null; previewAudioStop(); $('musicStatus').textContent = ''; return; }
    $('musicStatus').textContent = 'Preparing sound...';
    try {
      const buffer = await buildSoundtrack();
      if (id !== musicBuildId) return;
      musicBuffer = buffer;
      previewAudioStop(); // tick() restarts it at the right spot
      $('musicStatus').textContent = soundOn ? '' : 'Tap 🔇 under the preview to hear it.';
    } catch (err) {
      if (id !== musicBuildId) return;
      musicBuffer = null;
      $('musicStatus').textContent = 'Could not play this song: ' + err.message;
    }
  }, 300);
}

function previewAudioStop() {
  if (!audioSrc) return;
  try { audioSrc.stop(); } catch (e) { /* already stopped */ }
  audioSrc.disconnect();
  audioSrc = null;
}

function previewAudioStart(offset) {
  previewAudioStop();
  if (!musicBuffer || !soundOn || offset >= musicBuffer.duration) return;
  audioSrc = audioCtx.createBufferSource();
  audioSrc.buffer = musicBuffer;
  audioSrc.connect(audioCtx.destination);
  audioOffset = offset;
  audioStartedAt = audioCtx.currentTime;
  audioSrc.start(0, offset);
}

// Called every frame: keeps the music where the preview is (restarts after a seek or the loop).
function syncPreviewAudio() {
  if (!soundOn || !playing || !musicBuffer || exporting) { previewAudioStop(); return; }
  const heard = audioSrc ? audioOffset + (audioCtx.currentTime - audioStartedAt) : -1;
  if (!audioSrc || Math.abs(heard - cur) > 0.2) previewAudioStart(cur);
}

function toggleSound() {
  soundOn = !soundOn;
  if (soundOn) {
    audioCtx = audioCtx || new AudioContext({ sampleRate: VideoAdMusic.SR });
    audioCtx.resume();
    $('musicStatus').textContent = '';
  }
  $('soundBtn').textContent = soundOn ? '🔊' : '🔇';
  if (!soundOn) previewAudioStop();
}

async function onSongPicked(e) {
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!file) return;
  if (!file.type.startsWith('audio/') && !/\.(mp3|m4a|wav|aac|ogg)$/i.test(file.name)) { toast('Choose a music file (MP3, M4A or WAV).', true); return; }
  if (file.size > MAX_VIDEO_BYTES) { toast('That song is over 50 MB.', true); return; }
  const m = current.config.music;
  const previous = { src: m.src, name: m.name };
  const blobUrl = URL.createObjectURL(file);
  Object.assign(m, { track: 'custom', src: blobUrl, name: file.name, start: 0 });
  renderMusic();
  uploading++;
  try {
    const url = await uploadMedia(file);
    if (m.src === blobUrl) m.src = url;
    setDirty(true);
  } catch (err) {
    if (m.src === blobUrl) Object.assign(m, previous);
    toast(err.message, true);
  } finally {
    uploading--;
    URL.revokeObjectURL(blobUrl);
    renderMusic();
  }
}

// ---------------------------------------------------------------------------
// Voice-over: each scene's line is spoken by a Google voice (supabase/functions/video-ad-voice), saved
// as an MP3 and mixed into the soundtrack at the scene's start (js/videoAdMusic.js).
// Scene fields: say (the line), sayUrl (the clip), sayKey (voice|speed|line the clip was made with -
// when it no longer matches, the clip is out of date and is left out until it is made again).
// ---------------------------------------------------------------------------

function sayKey(s) {
  const v = current.config.voice;
  return [v.name, v.rate, (s.say || '').trim()].join('|');
}
const hasVoice = (s) => !!(s.say && s.say.trim() && s.sayUrl && s.sayKey === sayKey(s));

function sayStatus(s) {
  if (!s.say || !s.say.trim()) return '';
  return hasVoice(s) ? '✓ voice ready' : '• needs Make voice-over';
}

// Clips to mix: each scene's line starts once its scene has risen in.
function voiceClips() {
  if (!current || !current.config.voice.name) return [];
  return renderer.timeline().filter((x) => hasVoice(x.s)).map((x) => ({ url: x.s.sayUrl, start: x.i === 0 ? 0.3 : x.start }));
}

function renderVoice() {
  const v = current.config.voice;
  $('voiceName').innerHTML = '<option value="">Off - no voice-over</option>'
    + VOICES.map((x) => `<option value="${x.name}"${x.name === v.name ? ' selected' : ''}>${x.label}</option>`).join('');
  $('voiceRate').value = String(v.rate || 1);
  $('voiceVolume').value = Math.round((v.volume == null ? 1 : v.volume) * 100);
  const lines = current.config.scenes.filter((s) => s.say && s.say.trim());
  const ready = lines.filter(hasVoice).length;
  $('voiceMakeBtn').disabled = !v.name || !lines.length || ready === lines.length;
  $('voiceStatus').textContent = !lines.length ? 'Write a voice-over line on the scenes below first.'
    : !v.name ? 'Pick a voice.'
    : ready === lines.length ? `All ${lines.length} line${lines.length > 1 ? 's' : ''} ready.`
    : `${ready} of ${lines.length} lines ready - click Make voice-over.`;
}

function onVoiceSettingChange() {
  const v = current.config.voice;
  v.name = $('voiceName').value;
  v.rate = Number($('voiceRate').value) || 1;
  v.volume = Number($('voiceVolume').value) / 100;
  setDirty(true);
  renderVoice();
  document.querySelectorAll('.va-scene').forEach((card) => {
    card.querySelector('.va-say-status').textContent = sayStatus(current.config.scenes[Number(card.dataset.i)]);
  });
}

async function tryVoice() {
  const v = current.config.voice;
  if (!v.name) { toast('Pick a voice first.', true); return; }
  const first = current.config.scenes.find((s) => s.say && s.say.trim());
  $('voiceTryBtn').disabled = true;
  $('voiceStatus').textContent = 'Getting a sample...';
  try {
    const { audio_base64 } = await callVideoAdFunction({ text: first ? first.say.trim() : VOICE_SAMPLE, voice: v.name, rate: v.rate, preview: true }, 'video-ad-voice');
    await new Audio('data:audio/mpeg;base64,' + audio_base64).play();
    renderVoice();
  } catch (err) {
    $('voiceStatus').textContent = err.message;
  } finally {
    $('voiceTryBtn').disabled = false;
  }
}

async function makeVoiceOver() {
  const v = current.config.voice;
  const todo = current.config.scenes.filter((s) => s.say && s.say.trim() && !hasVoice(s));
  $('voiceMakeBtn').disabled = true;
  let failed = null;
  try {
    for (let i = 0; i < todo.length; i++) {
      $('voiceStatus').textContent = `Making line ${i + 1} of ${todo.length}...`;
      const s = todo[i];
      const key = sayKey(s);
      const { url } = await callVideoAdFunction({ text: s.say.trim(), voice: v.name, rate: v.rate }, 'video-ad-voice');
      s.sayUrl = url; s.sayKey = key;
      setDirty(true);
    }
  } catch (err) {
    failed = err;
  }
  // Give every scene time to finish its line before the next one rises in.
  let longer = 0;
  for (const s of current.config.scenes) {
    if (!hasVoice(s)) continue;
    try {
      const need = Math.ceil((await VideoAdMusic.clipSeconds(s.sayUrl) + 0.6) * 10) / 10;
      if (need > s.duration) { s.duration = Math.min(10, need); longer++; setDirty(true); }
    } catch (e) { /* the soundtrack build reports a clip that won't load */ }
  }
  renderScenes();
  renderVoice();
  if (failed) toast(failed.message, true);
  else toast(longer ? `Voice-over ready. ${longer} scene${longer > 1 ? 's were' : ' was'} made longer to fit the voice.` : 'Voice-over ready.');
  if (!soundOn) toggleSound();
}

// ---------------------------------------------------------------------------
// Media upload
// ---------------------------------------------------------------------------

// Photos are shrunk to 1920px on the long side (the video is 1080x1920) before upload.
function compressImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 1920 / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not process the picture.'))), 'image/jpeg', 0.88);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('That file is not a readable image.')); };
    img.src = url;
  });
}

const AUDIO_TYPES = { mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', wav: 'audio/wav', ogg: 'audio/ogg' };

// Photos are shrunk to JPEG; videos and songs go up as they are.
async function uploadMedia(file) {
  const ext = (file.name.split('.').pop() || '').toLowerCase();
  const isAudio = file.type.startsWith('audio/') || !!AUDIO_TYPES[ext];
  const isVid = file.type.startsWith('video/');
  const body = isVid || isAudio ? file : await compressImage(file);
  const contentType = isAudio ? (AUDIO_TYPES[ext] || file.type) : isVid ? file.type : 'image/jpeg';
  const fileName = isAudio ? 'song.' + (ext || 'mp3') : isVid ? 'clip.' + (ext || 'mp4') : 'photo.jpg';
  const { data, error } = await supabaseClient.rpc('admin_create_video_ad_media_upload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_file_name: fileName
  });
  if (error || !data || !data[0]) throw new Error('Could not prepare the upload: ' + (error ? error.message : 'unknown error'));
  const { storage_path, upload_token, public_url } = data[0];
  const { error: uploadError } = await supabaseClient.storage.from('video-ad-media')
    .uploadToSignedUrl(storage_path, upload_token, body, { contentType });
  if (uploadError) throw new Error('Upload failed: ' + uploadError.message);
  return public_url;
}

// Shows the file straight away from a local blob: URL, then swaps in the uploaded URL when it's done.
// target = { get() -> url, getType() -> type, set(url, type) } so the same flow serves scene media and the logo.
async function pickMedia(file, target) {
  if (!file) return;
  const isVid = file.type.startsWith('video/');
  if (!isVid && !file.type.startsWith('image/')) { toast('Choose a photo or a video.', true); return; }
  if (isVid && file.size > MAX_VIDEO_BYTES) { toast('That video is over 50 MB. Trim it on your phone first (a 3-5 second clip is plenty).', true); return; }

  const previous = { url: target.get(), type: target.getType() };
  const blobUrl = URL.createObjectURL(file);
  target.set(blobUrl, isVid ? 'video' : 'image');
  await renderer.loadMedia(blobUrl, isVid ? 'video' : 'image');
  renderAfterMedia();

  uploading++;
  try {
    const url = await uploadMedia(file);
    await renderer.loadMedia(url, isVid ? 'video' : 'image');
    if (target.get() === blobUrl) target.set(url, isVid ? 'video' : 'image');
    setDirty(true);
  } catch (err) {
    if (target.get() === blobUrl) target.set(previous.url, previous.type);
    toast(err.message, true);
  } finally {
    uploading--;
    renderAfterMedia();
  }
}

function renderAfterMedia() {
  if (!current) return;
  renderScenes();
  $('logoThumb').src = current.config.brand.logo || '';
  $('logoThumb').classList.toggle('hidden', !current.config.brand.logo);
}

function onSceneFileChange(e) {
  const input = e.target.closest('input[data-media]');
  if (!input) return;
  const s = current.config.scenes[Number(input.dataset.media)];
  const file = input.files && input.files[0];
  input.value = '';
  pickMedia(file, {
    get: () => s.media || null,
    getType: () => s.mediaType || null,
    set: (url, type) => { s.media = url; s.mediaType = type; }
  });
}

// ---------------------------------------------------------------------------
// AI: "Describe your ad" (new ad) and "Change with AI" (current ad) - supabase/functions/video-ad-generate
// ---------------------------------------------------------------------------

const MAX_AI_PHOTOS = 8;

// A row of picked files with remove buttons. Returns { files() , clear() }.
function makePicker(listId, inputId) {
  let picks = [];
  const render = () => {
    $(listId).innerHTML = picks.map((p, i) => `<div class="va-pick">
      ${p.file.type.startsWith('video/') ? `<video src="${p.url}" muted playsinline preload="metadata"></video><span>video</span>` : `<img src="${p.url}" alt="" />`}
      <button type="button" data-rm="${i}" title="Remove">&times;</button></div>`).join('');
  };
  $(inputId).addEventListener('change', (e) => {
    for (const file of e.target.files) {
      const isVid = file.type.startsWith('video/');
      if (!isVid && !file.type.startsWith('image/')) continue;
      if (isVid && file.size > MAX_VIDEO_BYTES) { toast(`${file.name} is over 50 MB - trim it first.`, true); continue; }
      if (picks.length >= MAX_AI_PHOTOS) { toast(`Up to ${MAX_AI_PHOTOS} photos/clips.`, true); break; }
      picks.push({ file, url: URL.createObjectURL(file) });
    }
    e.target.value = '';
    render();
  });
  $(listId).addEventListener('click', (e) => {
    const btn = e.target.closest('[data-rm]');
    if (!btn) return;
    URL.revokeObjectURL(picks[Number(btn.dataset.rm)].url);
    picks.splice(Number(btn.dataset.rm), 1);
    render();
  });
  return {
    files: () => picks.map((p) => p.file),
    clear: () => { picks.forEach((p) => URL.revokeObjectURL(p.url)); picks = []; render(); }
  };
}

// Small JPEG (768px long side) for the AI to look at - base64 without the data: prefix.
function thumbBase64(src) {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      try {
        const scale = Math.min(1, 768 / Math.max(img.width, img.height));
        const canvas = document.createElement('canvas');
        canvas.width = Math.round(img.width * scale);
        canvas.height = Math.round(img.height * scale);
        canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
        resolve(canvas.toDataURL('image/jpeg', 0.8).split(',')[1]);
      } catch (e) {
        resolve(null);
      }
    };
    img.onerror = () => resolve(null);
    img.src = src;
  });
}

async function callVideoAdFunction(payload, fn = 'video-ad-generate') {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ admin_username: currentSession.username, admin_password: currentSession.password, ...payload })
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || `Request failed (${response.status}).`);
  return result;
}

// Uploads the picked files, numbers every photo for the AI ("upload:N"), and asks for a new ad -
// or, with baseConfig, a changed version of it (its own photos come first in the numbering).
async function runAi(prompt, files, baseConfig, setStatus) {
  const photos = [];
  let current = null;
  if (baseConfig) {
    const index = new Map();
    for (const s of baseConfig.scenes) {
      if (s.style !== 'photo' || !s.media || s.media.startsWith('blob:') || index.has(s.media)) continue;
      if (photos.length >= MAX_AI_PHOTOS) break;
      const kind = VideoAdRenderer.isVideo(s.media, s.mediaType) ? 'video' : 'image';
      index.set(s.media, photos.length + 1);
      photos.push({ url: s.media, kind, image_base64: kind === 'image' ? await thumbBase64(s.media) : undefined });
    }
    current = {
      accent: baseConfig.accent,
      // Same field names the AI answers with (supabase/functions/video-ad-generate OUTPUT_SCHEMA).
      scenes: baseConfig.scenes.map((s) => ({
        style: s.style,
        seconds: s.duration,
        headline: s.headline || '',
        sub: s.sub || '',
        checklist: s.bullets || [],
        size_inches: s.dims || [],
        tank_options: s.options || {},
        stand_layers: s.layers || 2,
        voiceover: s.say || '',
        payment_methods: s.methods || [],
        stand_paint: s.paint || 'black',
        photo: s.media && index.has(s.media) ? 'upload:' + index.get(s.media) : '',
        button: s.button || '',
        footer: s.footer || ''
      }))
    };
  }
  if (photos.length + files.length > MAX_AI_PHOTOS) throw new Error(`Up to ${MAX_AI_PHOTOS} photos/clips in total - remove some first.`);

  for (let i = 0; i < files.length; i++) {
    setStatus(`Uploading photo ${i + 1} of ${files.length}...`);
    const file = files[i];
    const kind = file.type.startsWith('video/') ? 'video' : 'image';
    const localUrl = URL.createObjectURL(file);
    const image_base64 = kind === 'image' ? await thumbBase64(localUrl) : undefined;
    URL.revokeObjectURL(localUrl);
    photos.push({ url: await uploadMedia(file), kind, image_base64 });
  }

  setStatus('The AI is writing your ad... this takes about 20-60 seconds.');
  return callVideoAdFunction({ prompt, photos, current });
}

async function onAiGenerate(picker) {
  const prompt = $('aiPrompt').value.trim();
  if (!prompt) { toast('Describe the ad first.', true); $('aiPrompt').focus(); return; }
  const btn = $('aiGenerateBtn');
  const setStatus = (text, isError = false) => { $('aiStatus').textContent = text; $('aiStatus').classList.toggle('va-error', isError); };
  btn.disabled = true;
  try {
    const result = await runAi(prompt, picker.files(), null, setStatus);
    const template = templateCustomAquarium();
    const config = { ...result.config, brand: template.brand, music: template.music, caption: result.caption, aiSummary: result.summary };
    setStatus('');
    picker.clear();
    $('aiPrompt').value = '';
    await openEditor(null, result.name, config);
  } catch (err) {
    setStatus(err.message, true);
  } finally {
    btn.disabled = false;
  }
}

async function onAiRevise(picker) {
  if (!current || exporting) return;
  const prompt = $('aiRevisePrompt').value.trim();
  if (!prompt) { toast('Say what to change first.', true); $('aiRevisePrompt').focus(); return; }
  if (uploading) { toast('Wait for the upload to finish first.', true); return; }
  const btn = $('aiReviseBtn');
  const setStatus = (text, isError = false) => { $('aiReviseStatus').textContent = text; $('aiReviseStatus').classList.toggle('va-error', isError); };
  btn.disabled = true;
  try {
    const result = await runAi(prompt, picker.files(), current.config, setStatus);
    const c = current.config;
    // Lines the AI left as they were keep their voice clip, so they don't need making again.
    const madeClips = new Map(c.scenes.filter((s) => s.sayUrl && s.say).map((s) => [s.say.trim(), s]));
    for (const s of result.config.scenes) {
      const old = s.say && madeClips.get(s.say.trim());
      if (old) { s.sayUrl = old.sayUrl; s.sayKey = old.sayKey; }
    }
    c.scenes = renameOldStyles(result.config.scenes);
    c.accent = result.config.accent;
    c.caption = result.caption;
    c.aiSummary = result.summary;
    setStatus('');
    picker.clear();
    $('aiRevisePrompt').value = '';
    setDirty(true);
    renderAdFields();
    renderScenes();
    renderAiResult();
    renderVoice();
    await renderer.loadAll();
    renderScenes();
    seekTo(0);
    toast('Updated - check it over, then Save.');
  } catch (err) {
    setStatus(err.message, true);
  } finally {
    btn.disabled = false;
  }
}

function renderAiResult() {
  const c = current.config;
  $('aiResultBox').classList.toggle('hidden', !c.caption && !c.aiSummary);
  $('aiSummary').textContent = c.aiSummary || '';
  $('aiSummary').classList.toggle('hidden', !c.aiSummary);
  $('aiCaption').value = c.caption || '';
}

// ---------------------------------------------------------------------------
// Save / export
// ---------------------------------------------------------------------------

async function saveAd() {
  if (!current) return;
  if (uploading) { toast('Wait for the upload to finish, then save.', true); return; }
  const name = $('adName').value.trim();
  if (!name) { toast('Give the ad a name first.', true); $('adName').focus(); return; }
  const c = current.config;
  if ([c.brand.logo, c.music && c.music.src, ...c.scenes.map((s) => s.media)].some((u) => u && u.startsWith('blob:'))) {
    toast('A photo/video did not finish uploading. Choose it again, then save.', true);
    return;
  }
  $('saveBtn').disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_video_ad_save', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_ad_id: current.id,
    p_name: name,
    p_config: c
  });
  $('saveBtn').disabled = false;
  if (error) { toast('Could not save: ' + error.message, true); return; }
  current.id = data;
  current.name = name;
  setDirty(false);
  toast('Saved.');
}

async function exportVideo() {
  if (!current || exporting) return;
  if (uploading) { toast('Wait for the upload to finish first.', true); return; }
  exporting = true;
  $('exportBtn').disabled = true;
  $('exportProgress').classList.remove('hidden');
  const bar = $('exportProgress').firstElementChild;
  bar.style.width = '0%';
  $('exportStatus').textContent = 'Making your video... keep this page open.';
  previewAudioStop();
  try {
    const audio = currentMusicKey() === 'none' ? null : await buildSoundtrack();
    const blob = await renderer.exportMp4((p) => { bar.style.width = Math.round(p * 100) + '%'; }, audio);
    bar.style.width = '100%';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = slug($('adName').value) + '.mp4';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    $('exportStatus').textContent = `Done - ${(blob.size / 1e6).toFixed(1)} MB MP4 downloaded. Upload it as a Reel or ad on Facebook/Instagram.`;
  } catch (err) {
    console.error(err);
    $('exportStatus').textContent = err.name === 'SecurityError'
      ? 'Export failed: one of the photos/videos could not be used. Choose it again and retry.'
      : 'Export failed: ' + err.message;
  } finally {
    exporting = false;
    $('exportBtn').disabled = false;
    setTimeout(() => $('exportProgress').classList.add('hidden'), 1500);
    t0 = performance.now() - cur * 1000;
  }
}

// ---------------------------------------------------------------------------
// Preview loop (runs only while the editor is open)
// ---------------------------------------------------------------------------

function tick() {
  rafId = requestAnimationFrame(tick);
  if (exporting || !current) return;
  const total = renderer.totalDuration();
  if (!total) return;
  if (playing) cur = ((performance.now() - t0) / 1000) % total;
  renderer.syncVideos(cur, playing);
  renderer.drawFrame(cur);
  const key = currentMusicKey();
  if (key !== musicKey) { musicKey = key; scheduleMusicBuild(); }
  syncPreviewAudio();
  $('scrub').value = Math.round((cur / total) * 1000);
  $('clock').textContent = `${cur.toFixed(1)} / ${total.toFixed(1)}s`;

  const tl = renderer.timeline();
  const idx = tl.findIndex((x) => cur < x.end);
  if (idx !== activeSceneIndex) {
    activeSceneIndex = idx;
    document.querySelectorAll('.va-scene').forEach((el) => el.classList.toggle('va-scene-active', Number(el.dataset.i) === idx));
  }
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Video Ad Builder');

  if (!session.isSuperUser) {
    $('notAuthorizedBox').classList.remove('hidden');
    return;
  }
  if (!session.password) {
    $('unlockBox').classList.remove('hidden');
    $('unlockError').textContent = 'Please log out and log back in to use the Video Ad Builder.';
    $('unlockBtn').addEventListener('click', logout);
    return;
  }

  renderer = VideoAdRenderer.create($('stage'));
  document.fonts.load('800 100px Montserrat').then(() => document.fonts.load('600 50px Montserrat')).catch(() => {});

  $('listView').classList.remove('hidden');
  $('newTemplateBtn').addEventListener('click', () => openEditor(null, 'Custom aquarium ad', templateCustomAquarium()));
  $('newBlankBtn').addEventListener('click', () => openEditor(null, '', templateBlank()));
  $('refreshBtn').addEventListener('click', loadAds);
  $('adList').addEventListener('click', onAdListClick);

  $('backBtn').addEventListener('click', closeEditor);
  $('saveBtn').addEventListener('click', saveAd);
  $('exportBtn').addEventListener('click', exportVideo);
  $('playBtn').addEventListener('click', () => {
    playing = !playing;
    if (playing) t0 = performance.now() - cur * 1000;
    $('playBtn').textContent = playing ? 'Pause' : 'Play';
  });
  $('scrub').addEventListener('input', () => {
    playing = false;
    $('playBtn').textContent = 'Play';
    cur = ($('scrub').value / 1000) * renderer.totalDuration();
  });

  $('adName').addEventListener('input', () => setDirty(true));
  $('brandName').addEventListener('input', (e) => { current.config.brand.name = e.target.value; setDirty(true); });
  $('accent').addEventListener('input', (e) => { current.config.accent = e.target.value; setDirty(true); });
  $('showLogo').addEventListener('change', (e) => { current.config.brand.showLogo = e.target.checked; setDirty(true); });
  $('logoInput').addEventListener('change', (e) => {
    const file = e.target.files && e.target.files[0];
    e.target.value = '';
    if (file && !file.type.startsWith('image/')) { toast('The logo has to be a picture.', true); return; }
    const brand = current.config.brand;
    pickMedia(file, { get: () => brand.logo || null, getType: () => 'image', set: (url) => { brand.logo = url; } });
  });

  const newAdPicker = makePicker('aiPicks', 'aiPhotoInput');
  const revisePicker = makePicker('aiRevisePicks', 'aiRevisePhotoInput');
  $('aiGenerateBtn').addEventListener('click', () => onAiGenerate(newAdPicker));
  $('aiReviseBtn').addEventListener('click', () => onAiRevise(revisePicker));
  $('aiCaption').addEventListener('input', (e) => { current.config.caption = e.target.value; setDirty(true); });
  $('copyCaptionBtn').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('aiCaption').value); toast('Caption copied.'); }
    catch (e) { $('aiCaption').select(); toast('Select the caption and copy it.', true); }
  });

  $('soundBtn').addEventListener('click', toggleSound);
  $('musicChoices').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-track]');
    if (!btn) return;
    const m = current.config.music;
    m.track = btn.dataset.track;
    setDirty(true);
    renderMusic();
    if (m.track === 'custom' && !m.src) $('songInput').click();
    if (m.track !== 'none' && !soundOn) toggleSound(); // picking music means they want to hear it
  });
  $('songInput').addEventListener('change', onSongPicked);
  $('voiceName').addEventListener('change', onVoiceSettingChange);
  $('voiceRate').addEventListener('change', onVoiceSettingChange);
  $('voiceVolume').addEventListener('input', onVoiceSettingChange);
  $('voiceTryBtn').addEventListener('click', tryVoice);
  $('voiceMakeBtn').addEventListener('click', makeVoiceOver);
  $('songStart').addEventListener('input', (e) => { current.config.music.start = Math.max(0, Number(e.target.value) || 0); setDirty(true); });
  $('musicVolume').addEventListener('input', (e) => { current.config.music.volume = Number(e.target.value) / 100; setDirty(true); });

  $('sceneList').addEventListener('input', onSceneInput);
  $('sceneList').addEventListener('click', onSceneClick);
  $('sceneList').addEventListener('change', onSceneFileChange);
  $('addSceneBtn').addEventListener('click', () => {
    const scenes = current.config.scenes;
    if (scenes.length >= MAX_SCENES) return;
    // New scenes go before the end card, so the call to action stays last.
    const at = scenes.length && scenes[scenes.length - 1].style === 'cta' ? scenes.length - 1 : scenes.length;
    scenes.splice(at, 0, newScene('photo'));
    finishStructuralChange(at);
  });

  window.addEventListener('beforeunload', (e) => {
    if (dirty || exporting) { e.preventDefault(); e.returnValue = ''; }
  });

  loadAds();
})();
