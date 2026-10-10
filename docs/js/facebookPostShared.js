// Shared Facebook posting helpers for facebook-post-test.html and the mobile quick-post.html:
// the logo watermark (drawn on a canvas in the browser) and the call to the facebook-page-post
// Edge Function. Saved defaults live in js/facebookPostSettings.js.

// public.CompanyInfo.LogoUrl (General Setup), drawn in the watermark; null if unset or it fails to load.
let logoImg = null;
// The same logo with its white/near-white background made transparent (see knockOutWhite), so a
// logo saved on a white square doesn't show as a faint white box over the photo.
let logoKnockout = null;

const MAX_PHOTO_SIDE = 2048;

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

// Saved settings (loadFacebookPostSettings) -> the options drawWatermark takes.
function watermarkOptionsFromSettings(s) {
  return {
    enabled: s.watermarkEnabled,
    style: s.watermarkStyle,
    text: (s.watermarkText || '').trim(),
    position: s.watermarkPosition,
    size: Number(s.watermarkSize) / 100,
    opacity: Number(s.watermarkOpacity) / 100,
    knockout: s.watermarkKnockout
  };
}

// Phone photos can be 5-10MB; shrink to MAX_PHOTO_SIDE as JPEG so the upload stays small
// (Facebook re-compresses anyway), and stamp the watermark on the same canvas. Returns a
// data:image/jpeg URL.
function renderWatermarkedPhoto(sourceImg, options) {
  const scale = Math.min(1, MAX_PHOTO_SIDE / Math.max(sourceImg.width, sourceImg.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(sourceImg.width * scale);
  canvas.height = Math.round(sourceImg.height * scale);
  const ctx = canvas.getContext('2d');
  ctx.drawImage(sourceImg, 0, 0, canvas.width, canvas.height);
  if (options.enabled) drawWatermark(ctx, canvas.width, canvas.height, options);
  return canvas.toDataURL('image/jpeg', 0.88);
}

// action 'caption' -> { caption }; action 'post' -> { scheduled, photo_id, post_id, post_url }.
async function callFacebookPostFunction(session, imageBase64, payload) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/facebook-page-post`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({
      admin_username: session.username,
      admin_password: session.password,
      image_base64: imageBase64,
      media_type: 'image/jpeg',
      ...payload
    })
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || `Request failed (${response.status}).`);
  return result;
}
