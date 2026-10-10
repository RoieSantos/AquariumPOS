// Facebook Post Test page logic (super users only) - PROTOTYPE for automated Facebook Page
// posting, via the facebook-page-post Edge Function (supabase/functions/facebook-page-post).
// Upload a photo -> Claude writes a caption -> staff edit it -> post to the GMA Page now, or
// schedule it (the safe way to test: scheduled posts wait in Meta Business Suite > Planner).
let currentSession = null;
// The photo as sent to the function: downscaled + watermarked JPEG, base64 without the data: prefix.
let photoBase64 = null;
// The decoded original photo, kept so changing a watermark option re-renders from the clean image.
let sourceImg = null;
// public.CompanyInfo.LogoUrl (General Setup), drawn in the watermark; null if unset or it fails to load.
let logoImg = null;
// The same logo with its white/near-white background made transparent (see knockOutWhite), so a
// logo saved on a white square doesn't show as a faint white box over the photo.
let logoKnockout = null;

const MAX_PHOTO_SIDE = 2048;

function showError(message) {
  const errorEl = document.getElementById('fbErrorEl');
  errorEl.textContent = message;
  errorEl.classList.remove('hidden');
}

function clearMessages() {
  document.getElementById('fbErrorEl').classList.add('hidden');
  document.getElementById('fbResultEl').classList.add('hidden');
}

function loadImage(src, crossOrigin) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    // Same as delivery.js loadImageElement: the logo is on Supabase Storage, and without this the
    // canvas is "tainted" and toDataURL() throws.
    if (crossOrigin) img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('Could not read that image.'));
    img.src = src;
  });
}

async function loadCompanyLogo() {
  const { data } = await supabaseClient.from('CompanyInfo').select('"LogoUrl"').eq('"Id"', 1).limit(1);
  const url = data && data[0] && data[0].LogoUrl;
  if (!url) return;
  try {
    logoImg = await loadImage(url, true);
    logoKnockout = knockOutWhite(logoImg);
  } catch (err) {
    console.error('Could not load the company logo for the watermark - using text only.', err);
  }
}

// Pixels brighter than KNOCKOUT_FULL become fully transparent, with a soft fade down to
// KNOCKOUT_START so the logo's edges don't look jagged.
const KNOCKOUT_START = 205;
const KNOCKOUT_FULL = 240;

function knockOutWhite(img) {
  const canvas = document.createElement('canvas');
  canvas.width = img.naturalWidth || img.width;
  canvas.height = img.naturalHeight || img.height;
  const ctx = canvas.getContext('2d');
  ctx.drawImage(img, 0, 0);
  const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const d = pixels.data;
  for (let i = 0; i < d.length; i += 4) {
    const lightness = Math.min(d[i], d[i + 1], d[i + 2]);
    if (lightness >= KNOCKOUT_FULL) d[i + 3] = 0;
    else if (lightness > KNOCKOUT_START) {
      d[i + 3] = Math.round(d[i + 3] * (KNOCKOUT_FULL - lightness) / (KNOCKOUT_FULL - KNOCKOUT_START));
    }
  }
  ctx.putImageData(pixels, 0, 0);
  return canvas;
}

function getWatermarkOptions() {
  return {
    enabled: document.getElementById('fbWatermarkOn').checked,
    style: document.getElementById('fbWatermarkStyle').value,
    text: document.getElementById('fbWatermarkText').value.trim(),
    position: document.getElementById('fbWatermarkPosition').value,
    size: Number(document.getElementById('fbWatermarkSize').value) / 100,
    opacity: Number(document.getElementById('fbWatermarkOpacity').value) / 100,
    knockout: document.getElementById('fbWatermarkKnockout').checked
  };
}

// The logo (+ optional text under it) drawn once at full opacity onto its own canvas, `width` px
// wide. drawWatermark then stamps this with globalAlpha, so overlapping logo/text parts don't
// double up in darkness the way drawing each piece at low alpha would.
function buildMark(width, { text, knockout }) {
  const logo = logoImg ? (knockout && logoKnockout ? logoKnockout : logoImg) : null;
  const logoW = logo ? width : 0;
  const logoH = logo ? Math.round(width * (logo.height / logo.width)) : 0;
  const fontSize = Math.max(12, Math.round(width * (logo ? 0.11 : 0.16)));
  const gap = logo && text ? Math.round(fontSize * 0.4) : 0;

  const measure = document.createElement('canvas').getContext('2d');
  measure.font = `bold ${fontSize}px "Segoe UI", Arial, sans-serif`;
  const textW = text ? Math.ceil(measure.measureText(text).width) : 0;
  const markW = Math.max(logoW, textW) + 4;
  const markH = logoH + gap + (text ? Math.round(fontSize * 1.3) : 0) + 4;
  if (!logo && !text) return null;

  const canvas = document.createElement('canvas');
  canvas.width = markW;
  canvas.height = markH;
  const ctx = canvas.getContext('2d');
  if (logo) ctx.drawImage(logo, (markW - logoW) / 2, 2, logoW, logoH);
  if (text) {
    // White text with a dark outline reads on both light and dark photos.
    ctx.font = measure.font;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.lineJoin = 'round';
    ctx.lineWidth = Math.max(2, fontSize * 0.14);
    ctx.strokeStyle = 'rgba(0, 0, 0, 0.7)';
    ctx.strokeText(text, markW / 2, logoH + gap + 2);
    ctx.fillStyle = '#ffffff';
    ctx.fillText(text, markW / 2, logoH + gap + 2);
  }
  return canvas;
}

function drawWatermark(ctx, width, height, options) {
  if (options.style === 'badge') {
    drawBadge(ctx, width, height, options);
    return;
  }

  if (options.style === 'tiled') {
    // Repeated, rotated marks across the whole photo - cropping any one out still leaves others.
    const mark = buildMark(Math.round(width * options.size * 0.4), options);
    if (!mark) return;
    const stepX = mark.width * 1.7;
    const stepY = mark.height * 1.9;
    const diagonal = Math.hypot(width, height);
    ctx.save();
    ctx.globalAlpha = options.opacity;
    ctx.translate(width / 2, height / 2);
    ctx.rotate(-Math.PI / 6);
    let row = 0;
    for (let y = -diagonal / 2; y < diagonal / 2; y += stepY, row++) {
      // Every other row shifted half a step, brick-style, so there are no clean gaps to crop along.
      const offset = row % 2 ? stepX / 2 : 0;
      for (let x = -diagonal / 2 - offset; x < diagonal / 2; x += stepX) {
        ctx.drawImage(mark, x, y);
      }
    }
    ctx.restore();
    return;
  }

  // 'center': one large mark over the middle of the photo, kept inside 85% of its height.
  let mark = buildMark(Math.round(width * options.size), options);
  if (!mark) return;
  if (mark.height > height * 0.85) mark = buildMark(Math.round(width * options.size * (height * 0.85) / mark.height), options);
  ctx.save();
  ctx.globalAlpha = options.opacity;
  ctx.drawImage(mark, (width - mark.width) / 2, (height - mark.height) / 2);
  ctx.restore();
}

// Small corner badge: a semi-transparent white pill with the logo + text, sized relative to the
// photo so it looks the same on a small or a large picture.
function drawBadge(ctx, width, height, { text, position }) {
  const unit = Math.min(width, height);
  const logoSize = logoImg ? Math.round(unit * 0.09) : 0;
  const fontSize = Math.max(14, Math.round(unit * 0.035));
  const pad = Math.round(unit * 0.018);
  const gap = logoImg && text ? Math.round(pad * 0.8) : 0;
  const margin = Math.round(unit * 0.03);

  ctx.font = `bold ${fontSize}px "Segoe UI", Arial, sans-serif`;
  const textWidth = text ? ctx.measureText(text).width : 0;
  const boxW = pad * 2 + logoSize + gap + textWidth;
  const boxH = pad * 2 + Math.max(logoSize, fontSize * 1.3);
  if (boxW <= pad * 2) return;

  let x = width - boxW - margin;
  let y = height - boxH - margin;
  if (position === 'bottom-left') x = margin;
  if (position === 'top-left') { x = margin; y = margin; }
  if (position === 'top-right') y = margin;
  if (position === 'center') { x = (width - boxW) / 2; y = (height - boxH) / 2; }

  ctx.save();
  ctx.globalAlpha = 0.82;
  ctx.fillStyle = '#ffffff';
  ctx.beginPath();
  if (ctx.roundRect) ctx.roundRect(x, y, boxW, boxH, boxH / 2);
  else ctx.rect(x, y, boxW, boxH);
  ctx.fill();
  ctx.globalAlpha = 1;

  if (logoImg) {
    const ratio = logoImg.width / logoImg.height;
    const drawW = ratio >= 1 ? logoSize : logoSize * ratio;
    const drawH = ratio >= 1 ? logoSize / ratio : logoSize;
    ctx.drawImage(logoImg, x + pad + (logoSize - drawW) / 2, y + (boxH - drawH) / 2, drawW, drawH);
  }
  if (text) {
    ctx.fillStyle = '#1d4f91';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, x + pad + logoSize + gap, y + boxH / 2);
  }
  ctx.restore();
}

// Phone photos can be 5-10MB; shrink to MAX_PHOTO_SIDE as JPEG so the upload stays small
// (Facebook re-compresses anyway), and stamp the watermark on the same canvas.
function renderPhoto() {
  if (!sourceImg) return;
  const scale = Math.min(1, MAX_PHOTO_SIDE / Math.max(sourceImg.width, sourceImg.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(sourceImg.width * scale);
  canvas.height = Math.round(sourceImg.height * scale);
  const ctx = canvas.getContext('2d');
  ctx.drawImage(sourceImg, 0, 0, canvas.width, canvas.height);

  const watermark = getWatermarkOptions();
  if (watermark.enabled) drawWatermark(ctx, canvas.width, canvas.height, watermark);

  const dataUrl = canvas.toDataURL('image/jpeg', 0.88);
  photoBase64 = dataUrl.split(',')[1];
  const preview = document.getElementById('fbPhotoPreview');
  preview.src = dataUrl;
  preview.classList.remove('hidden');
}

async function callPostFunction(payload) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/facebook-page-post`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({
      admin_username: currentSession.username,
      admin_password: currentSession.password,
      image_base64: photoBase64,
      media_type: 'image/jpeg',
      ...payload
    })
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || `Request failed (${response.status}).`);
  return result;
}

async function onPhotoSelected(e) {
  clearMessages();
  const file = e.target.files && e.target.files[0];
  photoBase64 = null;
  sourceImg = null;
  document.getElementById('fbPhotoPreview').classList.add('hidden');
  if (!file) return;

  const objectUrl = URL.createObjectURL(file);
  try {
    sourceImg = await loadImage(objectUrl, false);
    renderPhoto();
  } catch (err) {
    showError(err.message);
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

async function writeCaption() {
  clearMessages();
  if (!photoBase64) {
    showError('Choose a photo first.');
    return;
  }

  const btn = document.getElementById('fbCaptionBtn');
  btn.disabled = true;
  btn.textContent = 'Writing...';
  try {
    const result = await callPostFunction({
      action: 'caption',
      notes: document.getElementById('fbNotesInput').value.trim()
    });
    document.getElementById('fbCaptionInput').value = result.caption || '';
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Write Caption with AI';
  }
}

async function postToFacebook() {
  clearMessages();
  const caption = document.getElementById('fbCaptionInput').value.trim();
  if (!photoBase64) {
    showError('Choose a photo first.');
    return;
  }
  if (!caption) {
    showError('Write a caption first.');
    return;
  }

  const mode = document.querySelector('input[name="fbMode"]:checked').value;
  let scheduledAtUnix = null;
  if (mode === 'schedule') {
    const value = document.getElementById('fbScheduleInput').value;
    if (!value) {
      showError('Pick a date and time to schedule the post.');
      return;
    }
    scheduledAtUnix = Math.floor(new Date(value).getTime() / 1000);
  } else if (!confirm('Publish this post on the GMA Facebook Page right now? Everyone following the Page will see it.')) {
    return;
  }

  const btn = document.getElementById('fbPostBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';
  try {
    const result = await callPostFunction({ action: 'post', caption, scheduled_at_unix: scheduledAtUnix });
    const resultEl = document.getElementById('fbResultEl');
    if (result.scheduled) {
      resultEl.textContent = `Scheduled for ${new Date(scheduledAtUnix * 1000).toLocaleString()}. Check it in Meta Business Suite > Planner (photo id ${result.photo_id}).`;
    } else {
      resultEl.innerHTML = 'Posted! ';
      if (result.post_url) {
        const link = document.createElement('a');
        link.href = result.post_url;
        link.target = '_blank';
        link.rel = 'noopener';
        link.textContent = 'View the post on Facebook';
        resultEl.appendChild(link);
      }
    }
    resultEl.classList.remove('hidden');
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Post to Facebook';
  }
}

// Saved defaults (js/facebookPostSettings.js), kept so Save as Default can write the watermark
// back without touching the caption directions that live in AI Bot Setup.
let savedSettings = null;

function applyWatermarkSettings(s) {
  document.getElementById('fbWatermarkOn').checked = s.watermarkEnabled;
  document.getElementById('fbWatermarkStyle').value = s.watermarkStyle;
  document.getElementById('fbWatermarkPosition').value = s.watermarkPosition;
  document.getElementById('fbWatermarkPosition').classList.toggle('hidden', s.watermarkStyle !== 'badge');
  document.getElementById('fbWatermarkSize').value = s.watermarkSize;
  document.getElementById('fbWatermarkOpacity').value = s.watermarkOpacity;
  document.getElementById('fbWatermarkKnockout').checked = s.watermarkKnockout;
  document.getElementById('fbWatermarkText').value = s.watermarkText;
}

async function saveWatermarkAsDefault() {
  const btn = document.getElementById('fbSaveDefaultBtn');
  const msgEl = document.getElementById('fbSaveDefaultMsg');
  // Not loaded yet - saving now would blank the caption directions.
  if (!savedSettings) return;
  const o = getWatermarkOptions();
  btn.disabled = true;
  msgEl.textContent = '';
  try {
    const settings = {
      ...savedSettings,
      watermarkEnabled: o.enabled,
      watermarkStyle: o.style,
      watermarkPosition: o.position,
      watermarkSize: Math.round(o.size * 100),
      watermarkOpacity: Math.round(o.opacity * 100),
      watermarkKnockout: o.knockout,
      watermarkText: o.text
    };
    const message = await saveFacebookPostSettings(currentSession, settings);
    if (message) {
      showError(message);
      return;
    }
    savedSettings = settings;
    msgEl.textContent = 'Saved.';
  } finally {
    btn.disabled = false;
  }
}

function toLocalInputValue(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Facebook Post Test');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to use Facebook Post Test.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  // Default the schedule to tomorrow 9:00 AM - far enough out to review/delete it in Planner.
  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  tomorrow.setHours(9, 0, 0, 0);
  document.getElementById('fbScheduleInput').value = toLocalInputValue(tomorrow);

  document.querySelectorAll('input[name="fbMode"]').forEach((radio) => {
    radio.addEventListener('change', () => {
      const isSchedule = document.querySelector('input[name="fbMode"]:checked').value === 'schedule';
      document.getElementById('fbScheduleRow').classList.toggle('hidden', !isSchedule);
    });
  });

  document.getElementById('fbPostContent').classList.remove('hidden');
  document.getElementById('fbPhotoInput').addEventListener('change', onPhotoSelected);
  ['fbWatermarkOn', 'fbWatermarkPosition', 'fbWatermarkKnockout'].forEach((id) => document.getElementById(id).addEventListener('change', renderPhoto));
  // Sliders fire many input events per second; redraw at most once per frame.
  let renderQueued = false;
  const queueRender = () => {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => { renderQueued = false; renderPhoto(); });
  };
  ['fbWatermarkText', 'fbWatermarkSize', 'fbWatermarkOpacity'].forEach((id) => document.getElementById(id).addEventListener('input', queueRender));
  document.getElementById('fbWatermarkStyle').addEventListener('change', () => {
    // Corner position only applies to the small badge.
    document.getElementById('fbWatermarkPosition').classList.toggle('hidden', document.getElementById('fbWatermarkStyle').value !== 'badge');
    renderPhoto();
  });
  document.getElementById('fbSaveDefaultBtn').addEventListener('click', saveWatermarkAsDefault);
  loadFacebookPostSettings().then((s) => {
    savedSettings = s;
    applyWatermarkSettings(s);
    renderPhoto();
  });
  loadCompanyLogo().then(renderPhoto);
  document.getElementById('fbCaptionBtn').addEventListener('click', writeCaption);
  document.getElementById('fbPostBtn').addEventListener('click', postToFacebook);
})();
