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
const MAX_MONTAGE = 30; // photos in one 🎞️ Our builds scene
const MAX_VIDEO_BYTES = 50 * 1024 * 1024;
const ACCENTS = ['#3fe0d0', '#ffd166', '#ff7a59', '#7cc8ff', '#a3e635'];
const STYLES = [
  { key: 'logo', label: '⭐ Logo' },
  { key: 'tank', label: '📐 Tank drawing' },
  { key: 'stand', label: '🔩 Stand drawing' },
  { key: 'sump', label: '🌀 Sump drawing' },
  { key: 'reviews', label: '💬 Reviews' },
  { key: 'payments', label: '💳 Payments' },
  { key: 'delivery', label: '🚚 Delivery' },
  { key: 'photo', label: '📷 Photo / video' },
  { key: 'montage', label: '🎞️ Our builds' },
  { key: 'stickman', label: '🧍 Stickman' },
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

// 🧍 Stickman scenes (js/videoAdRenderer.js drawStickman).
const STICKMAN_DEFAULTS = { action: 'walk', prop: 'phone', tag: 'Free quote', room: 'shop', shirt: '#5f7180', caption: '' };
const STICKMAN_OPTIONS = {
  action: [['walk', 'Walks in, looking at what he holds'], ['wave', 'Waves hello'], ['point', 'Points up at the headline, talking'],
    ['think', 'Thinks (hand on chin, "?" bubble)'], ['happy', 'Jumps for joy'], ['shrug', 'Shrugs, confused']],
  prop: [['phone', 'Phone (your logo on it)'], ['fishbag', 'Bag with a fish'], ['tank', 'Small aquarium'], ['sign', 'Sign (tag text on it)'], ['none', 'Nothing']],
  room: [['shop', 'Our shop - shelves of tanks'], ['room', 'A room with a door']],
  shirt: [['#5f7180', 'Grey'], ['#2f6fb5', 'Blue'], ['#d9534f', 'Red'], ['#3a9a5b', 'Green'], ['#f0b429', 'Yellow']]
};
// Styles the AI can't write (supabase/functions/video-ad-generate STYLES) - kept out of a revise and put back after.
const NOT_AI_STYLES = new Set(['montage', 'stickman']);

// Default sizes (inches) for the drawn styles - same as js/videoAdRenderer.js DEFAULT_DIMS.
const BUILD_DIMS = { tank: [48, 18, 20], stand: [48, 18, 30], sump: [30, 14, 16] };

function newScene(style) {
  const base = { style, duration: 3, headline: 'New scene', sub: '', bullets: [] };
  if (BUILD_DIMS[style]) base.dims = BUILD_DIMS[style].slice();
  if (style === 'stand') Object.assign(base, { layers: 2, paint: 'black' });
  if (style === 'cta') Object.assign(base, { headline: 'Message us today', button: 'rspetstop.com', footer: '' });
  if (style === 'reviews') Object.assign(base, { duration: 4, headline: 'Our customers say', reviews: [] });
  if (style === 'montage') Object.assign(base, { duration: 5, headline: 'Setups we built', photos: [] });
  if (style === 'stickman') Object.assign(base, STICKMAN_DEFAULTS, { duration: 4, headline: 'Still looking for the right tank?' });
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
  config.cover = config.cover || defaultCover(config);
  coverView = false;
  $('coverViewBtn').textContent = '🖼 Show cover';
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
  renderCover();
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
  $('safeZones').checked = !!c.safeZones;
  $('adLook').value = c.look === 'classic' ? 'classic' : 'cinematic';
  const row = $('accentRow');
  row.querySelectorAll('.va-swatch').forEach((el) => el.remove());
  ACCENTS.forEach((hex) => {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'va-swatch'; b.style.background = hex; b.title = hex;
    b.onclick = () => { c.accent = hex; $('accent').value = hex; setDirty(true); };
    row.appendChild(b);
  });
}

// ---------------------------------------------------------------------------
// Cover - the still thumbnail (drawn by VideoAdRenderer drawCover), downloaded as a JPEG
// ---------------------------------------------------------------------------

let coverView = false; // the stage shows the cover instead of playing the ad

// A new cover borrows the ad's own words: the first scene's headline (its last word in yellow) and the
// middle scenes' headlines as the topics row.
function defaultCover(config) {
  const scenes = config.scenes || [];
  const headline = (scenes[0] && scenes[0].headline) || 'Still worrying what setup to buy?';
  const topics = scenes.filter((s) => s.style !== 'logo' && s.style !== 'cta' && s.headline)
    .map((s) => s.headline.slice(0, 24)).slice(0, 4);
  return { headline, highlight: headline.split(/\s+/).pop(), tag: 'Watch our video now!', button: 'Click to watch now!', topics, media: '', mediaType: '' };
}

function renderCover() {
  const c = current.config.cover;
  document.querySelectorAll('[data-cover]').forEach((el) => { el.value = c[el.dataset.cover] || ''; });
  document.querySelectorAll('[data-cover-topic]').forEach((el) => { el.value = (c.topics || [])[Number(el.dataset.coverTopic)] || ''; });
  renderCoverMedia();
}

function renderCoverMedia() {
  const c = current.config.cover;
  const isVid = c.media && VideoAdRenderer.isVideo(c.media, c.mediaType);
  const failed = c.media && renderer.isMediaFailed(c.media);
  const busy = c.media && c.media.startsWith('blob:');
  const thumb = !c.media ? '<div class="va-media-thumb"></div>'
    : isVid ? `<video class="va-media-thumb" src="${escapeHtml(c.media)}" muted playsinline preload="metadata" crossorigin="anonymous"></video>`
    : `<img class="va-media-thumb" src="${escapeHtml(c.media)}" alt="" crossorigin="anonymous" />`;
  $('coverMediaRow').innerHTML = `
    ${thumb}
    <div class="va-media-info">
      <b>${!c.media ? 'Photo in the phone' : busy ? 'Uploading...' : failed ? 'Could not load this file' : isVid ? 'Your video' : 'Your photo'}</b>
      ${!c.media ? "Uses the ad's first photo or clip until you choose one." : isVid ? 'Shows the frame 1 second in.' : ''}
    </div>
    <label class="btn btn-secondary btn-sm" for="coverFile">${c.media ? 'Change' : 'Choose photo / video'}</label>
    <input type="file" id="coverFile" accept="image/*,video/mp4,video/webm,video/quicktime" />
    <button class="btn btn-secondary btn-sm" id="coverFbBtn" type="button" ${fbMediaBusy ? 'disabled' : ''}>📘 From our Facebook page</button>
    ${c.media ? '<button class="btn btn-secondary btn-sm" id="coverMediaClear" type="button">Remove</button>' : ''}`;
  if (coverView) renderer.prepareCover();
}

function onCoverInput(e) {
  const c = current.config.cover;
  if (e.target.dataset.cover) c[e.target.dataset.cover] = e.target.value;
  else if (e.target.dataset.coverTopic != null) {
    c.topics = [0, 1, 2, 3].map((i) => (c.topics || [])[i] || '');
    c.topics[Number(e.target.dataset.coverTopic)] = e.target.value;
  } else return;
  setDirty(true);
  if (!coverView) setCoverView(true);
}

function onCoverClick(e) {
  const c = current.config.cover;
  if (e.target.id === 'coverFbBtn') {
    openFbPicker({
      title: 'Pick the photo or video for the cover',
      multi: false, imagesOnly: false,
      room: () => 1, used: () => new Set(),
      apply: ([p]) => { c.media = p.url; c.mediaType = p.kind; setCoverView(true); }
    });
  } else if (e.target.id === 'coverMediaClear') {
    c.media = ''; c.mediaType = '';
    setDirty(true);
    renderCoverMedia();
  }
}

function onCoverFileChange(e) {
  if (e.target.id !== 'coverFile') return;
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  const c = current.config.cover;
  setCoverView(true);
  pickMedia(file, { get: () => c.media || null, getType: () => c.mediaType, set: (url, type) => { c.media = url; c.mediaType = type; } });
}

async function setCoverView(on) {
  coverView = on;
  $('coverViewBtn').textContent = on ? '▶ Show video' : '🖼 Show cover';
  if (on) {
    renderer.pauseVideos();
    await renderer.prepareCover();
  } else {
    t0 = performance.now() - cur * 1000;
  }
}

async function downloadCover() {
  if (!current || exporting) return;
  if (uploading) { toast('Wait for the upload to finish first.', true); return; }
  await setCoverView(true);
  renderer.drawCover();
  try {
    $('stage').toBlob((blob) => {
      if (!blob) { toast('Could not make the cover picture.', true); return; }
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = slug($('adName').value) + '-cover.jpg';
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 60000);
      toast('Cover downloaded - choose it as the thumbnail when you post.');
    }, 'image/jpeg', 0.92);
  } catch (err) {
    toast(err.name === 'SecurityError' ? 'One of the photos could not be used. Choose it again and retry.' : 'Could not make the cover: ' + err.message, true);
  }
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
  if (s.style === 'reviews') {
    const list = Array.isArray(s.reviews) ? s.reviews : [];
    const wall = s.layout === 'wall';
    const max = maxReviews(s);
    const rows = list.map((r, j) => `
      <div class="va-review">
        <textarea data-review-text="${j}" rows="2" maxlength="220" placeholder="The customer's review, word for word">${escapeHtml(r.text)}</textarea>
        <div class="va-review-foot">
          ${wall ? '' : r.photo
            ? `<span class="va-review-photo"><img src="${escapeHtml(r.photo)}" alt="" crossorigin="anonymous" /><button type="button" data-review-photo-del="${j}" title="Remove the photo">&times;</button></span>`
            : `<button class="btn btn-secondary btn-sm" data-review-photo="${j}" type="button" title="This customer's own setup, from our Facebook page">📷 Their setup</button>`}
          <input type="text" data-review-name="${j}" maxlength="30" value="${escapeHtml(r.name)}" placeholder="Name shown (optional, e.g. Mark D.)" />
          <button class="va-icon-btn" data-review-del="${j}" type="button" title="Remove this review">&times;</button>
        </div>
      </div>`).join('');
    const picks = fbReviews ? fbReviews.map((r, k) => `
      <div class="va-fb-review">
        <div><b>${r.name ? escapeHtml(r.name) + ' · ' : ''}${escapeHtml(r.page)}</b>${r.recommends ? '' : ' <span class="va-error">(does not recommend)</span>'}<br>${escapeHtml(r.text.length > 220 ? r.text.slice(0, 220) + '…' : r.text)}</div>
        <button class="btn btn-secondary btn-sm" data-review-use="${k}" type="button" ${list.length >= max || !r.recommends || list.some((x) => x.text === r.text) ? 'disabled' : ''}>Use</button>
      </div>`).join('') : '';
    fields += `
      <div class="va-grid">
        <label class="va-label">Layout
          <select data-k="layout">
            <option value="bubbles"${wall ? '' : ' selected'}>Big bubbles - up to 3 reviews</option>
            <option value="wall"${wall ? ' selected' : ''}>Review wall - up to 15 scrolling by</option>
          </select>
        </label>
        <label class="va-label">Recommendations count (optional)
          <input type="number" data-k="reviewCount" min="0" step="1" value="${escapeHtml(s.reviewCount || '')}" placeholder="${fbRecommendsTotal ? 'Your Pages: ' + fbRecommendsTotal : 'e.g. 120'}" />
        </label>
      </div>
      <div class="va-label">${wall ? 'Reviews on the wall (up to 15 - long ones are cut to a short snippet)' : 'Reviews shown in bubbles (up to 3 - short ones work best)'} - ${list.length} of ${max}${rows || '<span class="muted" style="font-weight:500;">No reviews yet - load them from Facebook or add one.</span>'}</div>
      <div class="va-ai-row">
        <button class="btn btn-primary btn-sm" data-review-load type="button">📥 Load reviews from Facebook</button>
        <button class="btn btn-secondary btn-sm" data-review-add type="button" ${list.length >= max ? 'disabled' : ''}>+ Type a review</button>
        ${fbReviews && fbReviews.length ? `<button class="btn btn-secondary btn-sm" data-review-useall type="button" ${list.length >= max ? 'disabled' : ''}>Use all (up to ${max})</button>` : ''}
        <span class="va-ai-status">${escapeHtml(fbReviewsStatus)}</span>
      </div>
      ${picks ? `<div class="va-fb-reviews">${picks}</div>` : ''}
      <p class="muted" style="margin:0; font-size:12.5px;">Use real reviews only: you may shorten one with "…" but don't reword it. Only show a customer's name if they're OK with it (first name + initial is safest). The count shows as "120+ recommendations on Facebook" - only enter a number your Pages really have. Move this scene to the top (↑) - reviews make a strong opening.${wall ? ' Give the wall about 6 seconds so people catch a few.' : ' 📷 Their setup puts a photo beside the quote - only use a photo of the setup that customer really got from us.'}</p>`;
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
  if (s.style === 'stickman') {
    const select = (k, label) => `<label class="va-label">${label}
        <select data-k="${k}">${STICKMAN_OPTIONS[k].map(([v, text]) =>
          `<option value="${v}"${v === (s[k] || STICKMAN_DEFAULTS[k]) ? ' selected' : ''}>${text}</option>`).join('')}</select></label>`;
    fields += `
      <div class="va-grid">
        ${select('action', 'What he does')}
        ${select('prop', 'Holding')}
        ${select('room', 'Background')}
        ${select('shirt', 'Shirt')}
      </div>
      <label class="va-label">Price tag text (on a sign: the sign's text) <input type="text" data-k="tag" maxlength="30" value="${escapeHtml(s.tag)}" placeholder="e.g. FREE, ₱999, 20% off" /></label>
      <label class="va-label">Captions - big words popping in a few at a time (empty = the voice-over line) <input type="text" data-k="caption" maxlength="160" value="${escapeHtml(s.caption)}" placeholder="e.g. So there's a free aquarium calculator" /></label>
      <p class="muted" style="margin:0; font-size:12.5px;">A cartoon explainer scene. "Walks in" takes about 2 seconds, so give it 4 seconds or more. Captions are spread evenly over the scene - fill in the voice-over and leave captions empty to show what the voice says.</p>`;
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
        <button class="btn btn-secondary btn-sm" data-fbmedia-load type="button" ${fbMediaBusy ? 'disabled' : ''}>📘 From our Facebook page</button>
      </div>`;
  }
  if (s.style === 'montage') {
    const photos = Array.isArray(s.photos) ? s.photos : [];
    const showcase = s.layout === 'showcase';
    const shown = Math.min(photos.length, Math.floor((Number(s.duration) || 3) / (showcase ? 0.6 : 0.25)));
    const strip = photos.map((url, j) => `<div class="va-pick">
      <img src="${escapeHtml(url)}" alt="" crossorigin="anonymous" />
      <button type="button" data-montage-del="${j}" title="Remove">&times;</button></div>`).join('');
    fields += `
      <label class="va-label">Layout
        <select data-k="layout">
          <option value="cuts"${showcase ? '' : ' selected'}>Quick cuts - fast flashes, lots of builds</option>
          <option value="showcase"${showcase ? ' selected' : ''}>Showcase - framed prints sliding in and stacking</option>
        </select>
      </label>
      <div class="va-label">Setup photos - ${photos.length} of ${MAX_MONTAGE}${photos.length ? ` (about ${(s.duration / Math.max(1, shown)).toFixed(2)} s each${shown < photos.length ? `; only the first ${shown} fit in ${s.duration} s - make the scene longer to show all` : ''})` : ''}
        ${strip ? `<div class="va-ai-picks">${strip}</div>` : '<span class="muted" style="font-weight:500;">No photos yet - add your finished setups from Facebook or upload them. Until then this scene shows the water background.</span>'}</div>
      <div class="va-ai-row">
        <button class="btn btn-primary btn-sm" data-fbmedia-load type="button" ${fbMediaBusy || photos.length >= MAX_MONTAGE ? 'disabled' : ''}>📘 Add from our Facebook page</button>
        <label class="btn btn-secondary btn-sm" for="montage${i}">+ Upload photos</label>
        <input type="file" id="montage${i}" data-montage="${i}" accept="image/*" multiple style="display:none;" />
        ${photos.length ? `<button class="btn btn-secondary btn-sm" data-montage-clear type="button">Remove all</button>` : ''}
      </div>`;
    fields += `<p class="muted" style="margin:0; font-size:12.5px;">${showcase
      ? 'Each photo slides in as a framed print and stays on the pile - 6-8 photos over 5 seconds lets people really look. Use the Posts view in the picker to take all the angles of one setup.'
      : 'Each photo flashes in for a moment - 12-20 photos over 4-5 seconds feels fast but readable.'} Pick photos of setups you really built.</p>`;
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
  } else if (k === 'layout') {
    s.layout = e.target.value;
    if (s.layout === 'wall' && s.duration < 6) s.duration = 6;
    if (s.layout === 'showcase' && s.duration < 5) s.duration = 5;
    if (Array.isArray(s.reviews)) s.reviews = s.reviews.slice(0, maxReviews(s));
    setDirty(true);
    renderScenes();
    return;
  } else if (k) {
    s[k] = e.target.value;
    if (k === 'headline') card.querySelector('.va-scene-title').textContent = s.headline || 'Scene ' + (Number(card.dataset.i) + 1);
    if (k === 'say') { card.querySelector('.va-say-status').textContent = sayStatus(s); renderVoice(); }
  } else if (e.target.dataset.reviewText != null || e.target.dataset.reviewName != null) {
    const j = Number(e.target.dataset.reviewText ?? e.target.dataset.reviewName);
    s.reviews = s.reviews || [];
    if (!s.reviews[j]) return;
    if (e.target.dataset.reviewText != null) s.reviews[j].text = e.target.value; else s.reviews[j].name = e.target.value;
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
    if (style === 'reviews') { s.reviews = s.reviews || []; if (s.duration < 4) s.duration = 4; }
    if (style === 'montage') { s.photos = s.photos || []; if (s.duration < 4) s.duration = 5; }
    if (style === 'stickman') {
      for (const [k, v] of Object.entries(STICKMAN_DEFAULTS)) if (s[k] == null) s[k] = v;
      if (s.duration < 4) s.duration = 4;
    }
    finishStructuralChange(i);
    return;
  }

  if (e.target.closest('[data-fbmedia-load]')) { openFacebookMedia(i); return; }
  const reviewPhoto = e.target.closest('[data-review-photo]');
  if (reviewPhoto) { openFacebookMedia(i, Number(reviewPhoto.dataset.reviewPhoto)); return; }
  const reviewPhotoDel = e.target.closest('[data-review-photo-del]');
  if (reviewPhotoDel) { delete s.reviews[Number(reviewPhotoDel.dataset.reviewPhotoDel)].photo; finishStructuralChange(i); return; }
  const montageDel = e.target.closest('[data-montage-del]');
  if (montageDel || e.target.closest('[data-montage-clear]')) {
    if (montageDel) s.photos.splice(Number(montageDel.dataset.montageDel), 1); else s.photos = [];
    finishStructuralChange(i);
    return;
  }

  if (e.target.closest('[data-review-load]')) { loadFacebookReviews(i); return; }
  const reviewAdd = e.target.closest('[data-review-add]');
  const reviewUse = e.target.closest('[data-review-use]');
  const reviewDel = e.target.closest('[data-review-del]');
  const reviewAll = e.target.closest('[data-review-useall]');
  if (reviewAdd || reviewUse || reviewDel || reviewAll) {
    s.reviews = Array.isArray(s.reviews) ? s.reviews : [];
    if (reviewDel) s.reviews.splice(Number(reviewDel.dataset.reviewDel), 1);
    else if (reviewAll) {
      for (const r of fbReviews) {
        if (s.reviews.length >= maxReviews(s)) break;
        if (r.recommends && !s.reviews.some((x) => x.text === r.text)) s.reviews.push(reviewFromFacebook(r));
      }
    } else if (s.reviews.length < maxReviews(s)) {
      const r = reviewUse ? fbReviews[Number(reviewUse.dataset.reviewUse)] : null;
      s.reviews.push(r ? reviewFromFacebook(r) : { text: '', name: '' });
    }
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
// Facebook reviews for the 💬 Reviews scene (supabase/functions/video-ad-reviews) - loaded once per
// visit, then picked per scene.
// ---------------------------------------------------------------------------

let fbReviews = null;
let fbReviewsStatus = '';
let fbRecommendsTotal = 0;

const maxReviews = (s) => (s.layout === 'wall' ? 15 : 3);
const reviewFromFacebook = (r) => ({
  text: r.text.length > 220 ? r.text.slice(0, 219).replace(/\s*\S*$/, '') + '…' : r.text,
  name: shortName(r.name)
});

// "Mark Dela Cruz" -> "Mark D.", "Ana Reyes" -> "Ana R." (customers' full names don't belong in an ad).
function shortName(name) {
  const parts = String(name || '').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return '';
  if (parts.length < 2) return parts[0];
  // Compound surnames (Dela Cruz, De los Santos, San Jose, Sta. Maria) start at the particle.
  const at = parts.findIndex((p, i) => i > 0 && /^(de|del|dela|delos|san|santa|sta\.?|sto\.?)$/i.test(p));
  return `${parts[0]} ${parts[at > 0 ? at : parts.length - 1][0].toUpperCase()}.`;
}

async function loadFacebookReviews(sceneIndex) {
  fbReviewsStatus = 'Loading reviews from Facebook...';
  renderScenes();
  try {
    const result = await callVideoAdFunction({}, 'video-ad-reviews');
    fbReviews = result.reviews || [];
    fbRecommendsTotal = Number(result.recommends_total) || 0;
    const failed = (result.pages || []).filter((p) => !p.ok);
    fbReviewsStatus = (fbReviews.length ? `${fbReviews.length} review${fbReviews.length > 1 ? 's' : ''} found. Click Use on the ones you want.`
      : 'No written reviews were found.')
      + (fbRecommendsTotal ? ` Your Pages have ${fbRecommendsTotal} recommendations in total.` : '')
      + (failed.length ? ` Could not read: ${failed.map((p) => p.name + ' (' + p.error + ')').join('; ')}` : '');
  } catch (err) {
    fbReviewsStatus = err.message + ' You can still type reviews in with + Type a review.';
  }
  renderScenes();
  const card = document.querySelector(`.va-scene[data-i="${sceneIndex}"]`);
  if (card) card.scrollIntoView({ block: 'nearest' });
}

// ---------------------------------------------------------------------------
// Photos/videos posted on our Facebook Pages (supabase/functions/video-ad-page-media), picked in the
// #fbPickModal pop-up - one for a 📷 scene or a review's setup photo, many for a 🎞️ Our builds scene
// (by photo, or a whole post's photos at once). The list loads once per visit; picked files are copied
// into video-ad-media (Facebook's links expire and can't be drawn into the export).
// ---------------------------------------------------------------------------

const FB_PICK_PAGE_SIZE = 60;
let fbMedia = null;
let fbMediaBusy = false;
// { title, multi, imagesOnly, room() -> how many more fit, used() -> Set of Facebook srcs already in,
//   apply([{ url, kind }]), kind, view: 'photos'|'posts', page, q, show, selected: Set of fbMedia indexes }
let fbPick = null;

// Our copy's URL -> the Facebook file it came from, so the picker can tick off ones already added.
const fbImported = new Map();
const fbSources = (urls) => new Set((urls || []).map((u) => fbImported.get(u)).filter(Boolean));

async function importFacebookMedia(m) {
  const { url } = await callVideoAdFunction({ import: { kind: m.kind, src: m.src } }, 'video-ad-page-media');
  fbImported.set(url, m.src);
  await renderer.loadMedia(url, m.kind);
  return url;
}

function fbPickStatus(text, isError = false) {
  $('fbPickStatus').textContent = text;
  $('fbPickStatus').classList.toggle('va-error', isError);
}

// From a scene's 📘 button (data-fbmedia-load), or a review's 📷 button (reviewIndex).
function openFacebookMedia(sceneIndex, reviewIndex = null) {
  const s = current.config.scenes[sceneIndex];
  if (reviewIndex != null) {
    const r = s.reviews[reviewIndex];
    openFbPicker({
      title: 'Pick this customer\'s setup photo',
      multi: false, imagesOnly: true,
      room: () => 1, used: () => fbSources([r.photo]),
      apply: ([p]) => { r.photo = p.url; }
    });
  } else if (s.style === 'montage') {
    openFbPicker({
      title: 'Add setup photos from our Facebook page',
      multi: true, imagesOnly: true,
      room: () => MAX_MONTAGE - (s.photos || []).length, used: () => fbSources(s.photos),
      apply: (picked) => { s.photos = s.photos || []; for (const p of picked) if (s.photos.length < MAX_MONTAGE) s.photos.push(p.url); }
    });
  } else {
    openFbPicker({
      title: 'Pick a photo or video from our Facebook page',
      multi: false, imagesOnly: false,
      room: () => 1, used: () => new Set(),
      apply: ([p]) => { s.media = p.url; s.mediaType = p.kind; }
    });
  }
}

async function openFbPicker(opts) {
  fbPick = { ...opts, kind: opts.imagesOnly ? 'image' : 'all', view: 'photos', page: '', q: '', show: FB_PICK_PAGE_SIZE, selected: new Set() };
  $('fbPickTitle').textContent = opts.title;
  $('fbPickKinds').classList.toggle('hidden', opts.imagesOnly);
  $('fbPickViews').classList.toggle('hidden', !opts.multi);
  $('fbPickSearch').value = '';
  $('fbPickModal').classList.remove('hidden');
  fbPickStatus('');
  renderFbPick();
  if (fbMedia) return;
  fbPickStatus('Loading photos and videos from Facebook...');
  try {
    const result = await callVideoAdFunction({}, 'video-ad-page-media');
    fbMedia = result.items || [];
    const failed = (result.pages || []).filter((p) => !p.ok);
    fbPickStatus((fbMedia.length ? '' : 'No photos or videos were found. ')
      + (failed.length ? `Could not read: ${failed.map((p) => p.name + ' (' + p.error + ')').join('; ')}` : ''), failed.length > 0);
  } catch (err) {
    fbPickStatus(err.message, true);
  }
  if (fbPick) renderFbPick();
}

function closeFbPick() {
  if (fbMediaBusy) return;
  fbPick = null;
  $('fbPickModal').classList.add('hidden');
}

// [{ m, idx }] after the kind / Page / search filters.
function fbPickList() {
  const q = fbPick.q.toLowerCase();
  return (fbMedia || []).map((m, idx) => ({ m, idx })).filter(({ m }) =>
    (fbPick.kind === 'all' || m.kind === fbPick.kind)
    && (!fbPick.page || m.page === fbPick.page)
    && (!q || m.caption.toLowerCase().includes(q)));
}

// Posts view: one tile per Facebook post with all its photos (a photo with no known post is its own).
function fbPickGroups(list) {
  const groups = new Map();
  for (const it of list) {
    const key = it.m.post || 'photo:' + it.idx;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(it);
  }
  return [...groups.values()];
}

function fbTileHtml(cover, idxs, used, count) {
  const m = cover.m;
  const isUsed = idxs.every((idx) => used.has(fbMedia[idx].src));
  const date = m.created ? new Date(m.created).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) : '';
  return `<button class="va-fbp-tile${isUsed ? ' used' : ''}" data-pick="${idxs.join(',')}" type="button" title="${escapeHtml(m.caption || m.page)}" ${isUsed || fbMediaBusy ? 'disabled' : ''}>
    <img src="${escapeHtml(m.thumb)}" alt="" loading="lazy" referrerpolicy="no-referrer" />
    ${m.kind === 'video' ? '<span class="va-fbp-badge">▶ Video</span>' : count > 1 ? `<span class="va-fbp-badge">📑 ${count} photos</span>` : ''}
    ${isUsed ? '<span class="va-fbp-added">✓ added</span>' : ''}
    ${date ? `<span class="va-fbp-date">${escapeHtml(date)}</span>` : ''}
  </button>`;
}

function renderFbPick() {
  if (!fbPick) return;
  const list = fbPickList();
  const used = fbPick.used();

  for (const b of $('fbPickKinds').querySelectorAll('[data-kind]')) b.classList.toggle('active', b.dataset.kind === fbPick.kind);
  for (const b of $('fbPickViews').querySelectorAll('[data-view]')) b.classList.toggle('active', b.dataset.view === fbPick.view);
  const pages = [...new Set((fbMedia || []).map((m) => m.page))];
  $('fbPickPage').classList.toggle('hidden', pages.length < 2);
  $('fbPickPage').innerHTML = `<option value="">All Pages</option>` + pages.map((p) => `<option value="${escapeHtml(p)}"${p === fbPick.page ? ' selected' : ''}>${escapeHtml(p)}</option>`).join('');

  const tiles = fbPick.view === 'posts'
    ? fbPickGroups(list).map((g) => fbTileHtml(g[0], g.map((x) => x.idx), used, g.length))
    : list.map((it) => fbTileHtml(it, [it.idx], used, 1));
  $('fbPickGrid').innerHTML = tiles.slice(0, fbPick.show).join('')
    || (fbMedia ? '<p class="muted" style="grid-column:1/-1; text-align:center;">Nothing matches.</p>' : '');
  $('fbPickMore').classList.toggle('hidden', tiles.length <= fbPick.show);
  $('fbPickMore').textContent = `Show more (${tiles.length - fbPick.show} left)`;
  fbPick.tileCount = tiles.length;
  markFbPickSelection();
  renderFbPickFoot(list, used);
}

// Selection classes only (no re-render), so the grid keeps its scroll and a double-click still lands.
function markFbPickSelection() {
  for (const el of $('fbPickGrid').querySelectorAll('[data-pick]')) {
    const idxs = el.dataset.pick.split(',').map(Number);
    const n = idxs.filter((idx) => fbPick.selected.has(idx)).length;
    el.classList.toggle('selected', n > 0 && n === idxs.length);
    el.classList.toggle('partial', n > 0 && n < idxs.length);
  }
}

function renderFbPickFoot(list = fbPickList(), used = fbPick.used()) {
  const n = fbPick.selected.size;
  const room = fbPick.room();
  const shown = `${fbPick.tileCount} ${fbPick.view === 'posts' ? 'posts' : 'shown'}`;
  $('fbPickCount').textContent = !fbMedia ? '' : fbPick.multi
    ? `${shown} · ${n} selected · room for ${room - n} more in this scene`
    : shown;
  $('fbPickSelectAll').classList.toggle('hidden', !fbPick.multi || !fbMedia);
  $('fbPickSelectAll').textContent = `Select the newest ${Math.min(room, list.filter(({ m }) => !used.has(m.src)).length)}`;
  $('fbPickOk').disabled = !n || fbMediaBusy;
  $('fbPickOk').textContent = fbPick.multi ? (n ? `Add ${n} photo${n === 1 ? '' : 's'}` : 'Add photos')
    : n && fbMedia[[...fbPick.selected][0]].kind === 'video' ? 'Use this video' : 'Use this photo';
}

function onFbPickGridClick(e) {
  const tile = e.target.closest('[data-pick]');
  if (!tile || !fbPick || fbMediaBusy) return;
  const used = fbPick.used();
  const idxs = tile.dataset.pick.split(',').map(Number).filter((idx) => !used.has(fbMedia[idx].src));
  if (!fbPick.multi) {
    fbPick.selected = new Set(idxs.slice(0, 1));
  } else if (idxs.every((idx) => fbPick.selected.has(idx))) {
    idxs.forEach((idx) => fbPick.selected.delete(idx));
  } else {
    const room = fbPick.room() - fbPick.selected.size;
    const add = idxs.filter((idx) => !fbPick.selected.has(idx));
    if (room <= 0) {
      fbPickStatus(`This scene is full (up to ${MAX_MONTAGE} photos) - unselect some first.`, true);
      return;
    }
    add.slice(0, room).forEach((idx) => fbPick.selected.add(idx));
    fbPickStatus(add.length > room ? `Only ${room} of this post's ${add.length} photos fit in the scene.` : '', add.length > room);
    markFbPickSelection();
    renderFbPickFoot();
    return;
  }
  fbPickStatus('');
  markFbPickSelection();
  renderFbPickFoot();
}

function fbPickSelectNewest() {
  const used = fbPick.used();
  fbPick.selected = new Set(fbPickList().filter(({ m }) => !used.has(m.src)).slice(0, fbPick.room()).map(({ idx }) => idx));
  markFbPickSelection();
  renderFbPickFoot();
}

// Copies the picked files a few at a time, then hands them to the target in the order they were listed.
async function confirmFbPick() {
  if (!fbPick || !fbPick.selected.size || fbMediaBusy) return;
  const pick = fbPick;
  const todo = [...pick.selected].sort((a, b) => a - b).map((idx) => fbMedia[idx]);
  fbMediaBusy = true;
  uploading++;
  renderFbPick();
  const urls = new Array(todo.length);
  let done = 0, failed = 0, next = 0, lastError = '';
  const progress = () => fbPickStatus(todo.length === 1
    ? (todo[0].kind === 'video' ? 'Copying the video from Facebook (big ones take a while)...' : 'Copying the photo from Facebook...')
    : `Copying photos from Facebook... ${done} of ${todo.length}`);
  progress();
  const worker = async () => {
    while (next < todo.length) {
      const j = next++;
      try { urls[j] = await importFacebookMedia(todo[j]); } catch (err) { failed++; lastError = err.message; }
      done++;
      progress();
    }
  };
  await Promise.all([worker(), worker(), worker(), worker()]);
  fbMediaBusy = false;
  uploading--;

  const got = todo.map((m, j) => ({ url: urls[j], kind: m.kind })).filter((p) => p.url);
  if (got.length) { pick.apply(got); setDirty(true); }
  renderAfterMedia();
  if (!failed) {
    closeFbPick();
    if (pick.multi) toast(`Added ${got.length} photo${got.length === 1 ? '' : 's'} - remove any that aren't setups with ×.`);
    return;
  }
  pick.selected = new Set();
  fbPickStatus(got.length ? `${got.length} added, ${failed} could not be copied: ${lastError}` : lastError, true);
  renderFbPick();
}

function initFbPick() {
  $('fbPickGrid').addEventListener('click', onFbPickGridClick);
  $('fbPickGrid').addEventListener('dblclick', (e) => { if (fbPick && !fbPick.multi && e.target.closest('[data-pick]')) confirmFbPick(); });
  $('fbPickKinds').addEventListener('click', (e) => {
    const b = e.target.closest('[data-kind]');
    if (!b || !fbPick) return;
    fbPick.kind = b.dataset.kind; fbPick.show = FB_PICK_PAGE_SIZE; fbPick.selected = new Set();
    renderFbPick();
  });
  $('fbPickViews').addEventListener('click', (e) => {
    const b = e.target.closest('[data-view]');
    if (!b || !fbPick) return;
    fbPick.view = b.dataset.view; fbPick.show = FB_PICK_PAGE_SIZE;
    renderFbPick();
  });
  $('fbPickPage').addEventListener('change', (e) => { fbPick.page = e.target.value; fbPick.show = FB_PICK_PAGE_SIZE; renderFbPick(); });
  $('fbPickSearch').addEventListener('input', (e) => { fbPick.q = e.target.value.trim(); fbPick.show = FB_PICK_PAGE_SIZE; renderFbPick(); });
  $('fbPickMore').addEventListener('click', () => { fbPick.show += FB_PICK_PAGE_SIZE; renderFbPick(); });
  $('fbPickSelectAll').addEventListener('click', fbPickSelectNewest);
  $('fbPickOk').addEventListener('click', confirmFbPick);
  $('fbPickCancel').addEventListener('click', closeFbPick);
  $('fbPickClose').addEventListener('click', closeFbPick);
  $('fbPickModal').addEventListener('click', (e) => { if (e.target === $('fbPickModal')) closeFbPick(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && fbPick) closeFbPick(); });
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
  renderCoverMedia();
  $('logoThumb').src = current.config.brand.logo || '';
  $('logoThumb').classList.toggle('hidden', !current.config.brand.logo);
}

async function onMontageFiles(input) {
  const s = current.config.scenes[Number(input.dataset.montage)];
  const files = [...(input.files || [])].filter((f) => f.type.startsWith('image/'));
  input.value = '';
  s.photos = s.photos || [];
  const room = MAX_MONTAGE - s.photos.length;
  if (files.length > room) toast(`Up to ${MAX_MONTAGE} photos in this scene - only the first ${Math.max(0, room)} were added.`, true);
  uploading++;
  try {
    for (const file of files.slice(0, Math.max(0, room))) {
      const url = await uploadMedia(file);
      await renderer.loadMedia(url, 'image');
      s.photos.push(url);
      setDirty(true);
      renderScenes();
    }
  } catch (err) {
    toast(err.message, true);
  } finally {
    uploading--;
    renderAfterMedia();
  }
}

function onSceneFileChange(e) {
  const montageInput = e.target.closest('input[data-montage]');
  if (montageInput) { onMontageFiles(montageInput); return; }
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
      // 🎞️ Our builds / 🧍 Stickman scenes aren't AI styles - onAiRevise puts them back afterwards.
      scenes: baseConfig.scenes.filter((s) => !NOT_AI_STYLES.has(s.style)).map((s) => ({
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
    config.scenes = config.scenes.filter((s) => s.style !== 'reviews'); // only staff-picked real reviews
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
    const oldReviews = c.scenes.filter((s) => s.style === 'reviews' && Array.isArray(s.reviews) && s.reviews.length);
    result.config.scenes = result.config.scenes.filter((s) => {
      if (s.style !== 'reviews') return true;
      const old = oldReviews.shift();
      if (!old) return false; // the AI can't invent reviews
      s.reviews = old.reviews;
      return true;
    });
    const scenes = renameOldStyles(result.config.scenes);
    c.scenes.forEach((s, at) => { if (NOT_AI_STYLES.has(s.style)) scenes.splice(Math.min(at, scenes.length), 0, s); });
    c.scenes = scenes.slice(0, MAX_SCENES);
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
  if ([c.brand.logo, c.music && c.music.src, c.cover && c.cover.media, ...c.scenes.map((s) => s.media)].some((u) => u && u.startsWith('blob:'))) {
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
  if (coverView) { previewAudioStop(); renderer.drawCover(); return; }
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
  document.fonts.load('800 100px Montserrat').then(() => document.fonts.load('600 50px Montserrat'))
    .then(() => document.fonts.load('italic 600 56px "Playfair Display"')).then(() => document.fonts.load('700 100px Poppins')).catch(() => {});

  $('listView').classList.remove('hidden');
  $('newTemplateBtn').addEventListener('click', () => openEditor(null, 'Custom aquarium ad', templateCustomAquarium()));
  $('newBlankBtn').addEventListener('click', () => openEditor(null, '', templateBlank()));
  $('refreshBtn').addEventListener('click', loadAds);
  $('adList').addEventListener('click', onAdListClick);

  $('backBtn').addEventListener('click', closeEditor);
  $('saveBtn').addEventListener('click', saveAd);
  $('exportBtn').addEventListener('click', exportVideo);
  $('coverViewBtn').addEventListener('click', () => setCoverView(!coverView));
  $('coverDownloadBtn').addEventListener('click', downloadCover);
  $('coverBox').addEventListener('input', onCoverInput);
  $('coverBox').addEventListener('click', onCoverClick);
  $('coverBox').addEventListener('change', onCoverFileChange);
  $('playBtn').addEventListener('click', () => {
    if (coverView) { setCoverView(false); playing = true; $('playBtn').textContent = 'Pause'; return; }
    playing = !playing;
    if (playing) t0 = performance.now() - cur * 1000;
    $('playBtn').textContent = playing ? 'Pause' : 'Play';
  });
  $('scrub').addEventListener('input', () => {
    if (coverView) setCoverView(false);
    playing = false;
    $('playBtn').textContent = 'Play';
    cur = ($('scrub').value / 1000) * renderer.totalDuration();
  });

  $('adName').addEventListener('input', () => setDirty(true));
  $('brandName').addEventListener('input', (e) => { current.config.brand.name = e.target.value; setDirty(true); });
  $('accent').addEventListener('input', (e) => { current.config.accent = e.target.value; setDirty(true); });
  $('showLogo').addEventListener('change', (e) => { current.config.brand.showLogo = e.target.checked; setDirty(true); });
  $('safeZones').addEventListener('change', (e) => { current.config.safeZones = e.target.checked; setDirty(true); });
  $('adLook').addEventListener('change', (e) => { current.config.look = e.target.value; setDirty(true); });
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
  initFbPick();
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
